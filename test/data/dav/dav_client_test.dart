import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';
import 'package:jotit/data/dav/dav_exception.dart';
import 'package:jotit/data/dav/dav_multistatus.dart';

import '../../support/dav_harness.dart';

const _note = '--- uid: u-1\ntitle: Hello\n---\n\nbody\n';

void main() {
  late DavHarness dav;
  late DavClient client;

  setUp(() async {
    dav = await DavHarness.start();
    client = dav.client();
  });

  tearDown(() async {
    // `late` fields are uninitialised when setUp itself failed. Touching
    // them here would replace the real failure with a LateInitializationError
    // that points nowhere, which cost a whole debugging cycle once already.
    try {
      await client.close();
    } on Object catch (_) {
      /* the test body already reported the real problem */
    }
    await dav.dispose();
  });

  Future<DavResource> seed(String path, String body) async {
    final put = await client.put(path, utf8.encode(body));
    expect(put.statusCode, anyOf(201, 204));
    final stat = await client.stat(path);
    expect(stat, isNotNull, reason: 'seeded $path but stat returned nothing');
    return stat!;
  }

  group('authentication', () {
    test('wrong password is a 401, and the client says so', () async {
      final bad = dav.client(password: 'wrong');
      await expectLater(
        bad.listCollection(''),
        throwsA(isA<DavException>()
            .having((e) => e.statusCode, 'statusCode', 401)
            .having((e) => e.isAuth, 'isAuth', isTrue)
            .having((e) => e.isPermanentClientError, 'isPermanentClientError',
                isFalse)),
      );
      await bad.close();
    });

    test('a colon inside the password does not confuse the split', () async {
      // RFC 7617 splits on the *first* colon; a password containing one
      // must still authenticate. Base64-encoding username:password verbatim
      // is what makes this work. Real-world passwords often contain colons, so
      // this is not a hypothetical.
      final oddServer = await DavHarness.start(password: ':with:colons:');
      addTearDown(oddServer.dispose);
      final odd = oddServer.client(password: ':with:colons:');
      await expectLater(odd.probe(), completes);
      await odd.close();

      final wrong = oddServer.client(password: ':with:colons');
      await expectLater(
          wrong.probe(), throwsA(isA<DavException>().having((e) => e.statusCode, 'status', 401)));
      await wrong.close();
    });
  });

  group('capability probe', () {
    test('reports the advertised DAV classes and server', () async {
      final probed = await client.probe();
      expect(probed.davClasses, containsAll(<String>['1', '2']));
      expect(probed.server, contains('JotItTestDAV'));
      expect(probed.supportsCtag, isTrue, reason: 'this profile serves getctag');
      expect(probed.supportsIfMatch, isTrue,
          reason: 'If-Match support is a configured property, not probed');
    });

    test('a server with no getctag is detected from a 404 propstat', () async {
      final noCtag = DavHarness.start(extraArgs: <String>['--no-ctag']);
      final h = await noCtag;
      addTearDown(h.dispose);
      final c = h.client();
      addTearDown(c.close);
      final probed = await c.probe();
      expect(probed.supportsCtag, isFalse);
    });
  });

  group('listing', () {
    test('depth 1 lists direct children and reports a collection ctag', () async {
      await seed('a.md', _note);
      await seed('sub/b.md', _note);

      final listing = await client.listCollection('');
      expect(listing, isNotNull);
      expect(listing!.self?.isCollection, isTrue);
      expect(listing.collectionCtag, isNotNull);
      expect(listing.files.map((r) => r.path), contains('a.md'));
      expect(listing.children.map((r) => r.path), containsAll(<String>['a.md', 'sub']));
      expect(listing.files.map((r) => r.path), isNot(contains('b.md')),
          reason: 'depth 1 must not recurse');
    });

    test('depth 0 returns only the collection', () async {
      await seed('a.md', _note);
      final listing = await client.propfind('', depth: 0);
      expect(listing.resources, hasLength(1));
      expect(listing.resources.single.path, '');
    });

    test('depth infinity is refused client-side', () async {
      // Most servers answer 403 and none answer it consistently; asking is
      // never correct.
      expect(() => client.propfind('', depth: 2),
          throwsA(isA<ArgumentError>()));
    });

    test('a missing collection is null, not an exception', () async {
      expect(await client.listCollection('nope'), isNull);
    });

    test('CJK paths survive the round trip', () async {
      final res = await seed('同步/引擎.md', _note);
      expect(res.path, '同步/引擎.md');
      final listing = await client.listCollection('同步');
      // DAV-root relative, not collection relative — see DavListing.
      expect(listing!.files.map((r) => r.path), contains('同步/引擎.md'));
      final bytes = await client.get('同步/引擎.md');
      expect(utf8.decode(bytes!), _note);
    });
  });

  group('If-Match — the property the whole sync design rests on', () {
    test('a correct tag is accepted and the write succeeds', () async {
      // This is the case curl could not exercise: PowerShell strips the
      // quotes out of an ETag on its way to the wire, and the server then
      // correctly 412s a tag that arrived unquoted. Dart has no shell
      // between here and the socket, so the token goes out verbatim.
      final seeded = await seed('a.md', _note);
      expect(seeded.etag, isNotNull);
      expect(seeded.etag, startsWith('"'),
          reason: 'an ETag is quoted; the parser must not strip that');

      final result = await client.put('a.md', utf8.encode('${_note}changed'),
          condition: DavIfMatch(seeded.etag!));
      expect(result.statusCode, anyOf(200, 204));
    });

    test('a stale tag is refused with 412 and the file is untouched', () async {
      final first = await seed('a.md', _note);
      await client.put('a.md', utf8.encode('${_note}second'));

      // 412 comes back as a status, not as an exception. Throwing it is what
      // made §5.3 row 10 unreachable: the engine's branch existed and the
      // exception unwound past it before it could run.
      final result = await client.put('a.md', utf8.encode('${_note}third'),
          condition: DavIfMatch(first.etag!));
      expect(result.statusCode, 412);
      // The losing writer must still be able to tell it lost.
      expect(utf8.decode((await client.get('a.md'))!), '${_note}second');
    });

    test('If-Match is refused locally when the server does not evaluate it', () async {
      // nginx-dav ignores the precondition and accepts the write. Sending
      // one would produce a 204 that reads as "protected" while actually
      // being a silent overwrite — exactly the bug ADR-8 exists to prevent.
      final naive = dav.client(capabilities: const DavCapabilities());
      addTearDown(naive.close);
      expect(
        () => naive.put('a.md', utf8.encode('x'),
            condition: DavIfMatch('"anything"')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('If-Match is refused locally when the server returns weak tags', () async {
      // RFC 7232 If-Match uses strong comparison, so a weak tag can never
      // match and every write would 412 forever.
      final weak = dav.client(
          capabilities: const DavCapabilities(
              supportsIfMatch: true, etagIsWeak: true));
      addTearDown(weak.close);
      expect(
        () => weak.put('a.md', utf8.encode('x'), condition: DavIfMatch('W/"w"')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('a DELETE with a stale tag is refused', () async {
      final first = await seed('a.md', _note);
      await client.put('a.md', utf8.encode('${_note}second'));
      await expectLater(
        client.delete('a.md', ifMatch: first.etag!),
        throwsA(isA<DavException>().having((e) => e.statusCode, 'status', 412)),
      );
      expect(await client.get('a.md'), isNotNull);
    });

    test('a DELETE with a fresh tag succeeds', () async {
      final seeded = await seed('a.md', _note);
      expect(await client.delete('a.md', ifMatch: seeded.etag!), isTrue);
      expect(await client.get('a.md'), isNull);
    });
  });

  group('If-None-Match — atomic create', () {
    test('creating an absent file succeeds', () async {
      final r = await client.put('new.md', utf8.encode(_note),
          condition: const DavIfAbsent());
      expect(r.statusCode, 201);
    });

    test('creating an existing file is refused, so two devices cannot both win',
        () async {
      await seed('taken.md', _note);
      final result = await client.put('taken.md', utf8.encode('${_note}mine'),
          condition: const DavIfAbsent());
      expect(result.statusCode, 412,
          reason: 'If-None-Match: * on an existing resource is a 412, and it '
              'is returned so the caller can classify it as row 10');
      expect(utf8.decode((await client.get('taken.md'))!), _note);
    });
  });

  group('deletes', () {
    test('deleting something already gone is success', () async {
      // The postcondition the caller cares about is "it is gone", so a 404
      // is an acceptable answer to a delete.
      expect(await client.delete('never-existed.md'), isTrue);
    });
  });

  group('rename', () {
    test('MOVE keeps the file reachable at the new path only', () async {
      await seed('old.md', _note);
      await client.move('old.md', 'new.md');
      expect(await client.get('old.md'), isNull);
      expect(utf8.decode((await client.get('new.md'))!), _note);
    });

    test('MOVE onto an existing path without overwrite is refused', () async {
      await seed('a.md', _note);
      await seed('b.md', '${_note}b');
      await expectLater(
        client.move('a.md', 'b.md'),
        throwsA(isA<DavException>()),
      );
      expect(await client.get('a.md'), isNotNull,
          reason: 'a refused MOVE must not delete the source');
    });
  });

  group('transport failures', () {
    test('an unreachable server is retryable, not a permanent error', () async {
      final dead = DavClient(
        baseUri: Uri.parse('http://127.0.0.1:1/dav/'),
        username: 'testuser',
        password: 'test',
        timeout: const Duration(seconds: 2),
      );
      addTearDown(dead.close);
      await expectLater(
        dead.listCollection(''),
        throwsA(isA<DavException>()
            .having((e) => e.isTransport, 'isTransport', isTrue)
            .having((e) => e.isPermanentClientError, 'isPermanentClientError',
                isFalse)),
      );
    });

    test('a timeout is reported as a timeout, not as an HTTP status', () async {
      final slow = DavClient(
        baseUri: dav.baseUri(),
        username: 'testuser',
        password: 'test',
        timeout: const Duration(microseconds: 1),
      );
      addTearDown(slow.close);
      await expectLater(
        slow.listCollection(''),
        throwsA(isA<DavException>()
            .having((e) => e.isTimeout, 'isTimeout', isTrue)),
      );
    });
  });

  group('capability degradation', () {
    test('against a server with no If-Match the profile says so', () async {
      final weakServer = await DavHarness.start(
          extraArgs: <String>['--no-if-match']);
      addTearDown(weakServer.dispose);
      final c = DavClient(
        baseUri: weakServer.baseUri(),
        username: 'testuser',
        password: 'test',
        capabilities: const DavCapabilities(),
      );
      addTearDown(c.close);
      // The write still succeeds — that is the trap. The client cannot stop
      // the lost update; all it can do is refuse to *claim* the write was
      // protected, which is what the local ArgumentError does.
      final r = await c.put('a.md', utf8.encode(_note));
      expect(r.statusCode, 201);
      expect(
        () => c.put('a.md', utf8.encode('x'), condition: DavIfMatch('"e"')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('against a server with no CTag the client still lists everything',
        () async {
      final weakServer =
          await DavHarness.start(extraArgs: <String>['--no-ctag']);
      addTearDown(weakServer.dispose);
      final c = weakServer.client();
      addTearDown(c.close);
      await c.put('a.md', utf8.encode(_note));
      final probed = await c.probe();
      expect(probed.supportsCtag, isFalse);
      final listing = await c.listCollection('');
      expect(listing!.files.map((r) => r.path), contains('a.md'),
          reason: 'no CTag must degrade to a full listing, never to nothing');
    });
  });

  group('url building', () {
    test('the base URI is normalised to end with a slash', () {
      // Without this, Uri.resolve drops the last segment and every note is
      // written one directory too high.
      final c = DavClient(
        baseUri: Uri.parse('http://h/webDAV'),
        username: 'u',
        password: 'p',
      );
      addTearDown(c.close);
      expect(c.baseUri.toString(), 'http://h/webDAV/');
      // No trailing slash on a file: `.../a.md/` addresses a *collection*
      // named a.md, not the file. The trailing slash survives on the
      // collection helper, which is why they are separate methods.
      expect(c.urlFor('notes/a.md').toString(), 'http://h/webDAV/notes/a.md');
      expect(c.collectionUrlFor('notes').toString(),
          'http://h/webDAV/notes/');
    });

    test('segments are encoded individually', () {
      final c = DavClient(
          baseUri: Uri.parse('http://h/dav/'), username: 'u', password: 'p');
      addTearDown(c.close);
      expect(c.urlFor('my note.md').toString(), 'http://h/dav/my%20note.md');
      expect(c.collectionUrlFor('我的 笔记').toString(),
          'http://h/dav/%E6%88%91%E7%9A%84%20%E7%AC%94%E8%AE%B0/');
    });
  });

  group('Retry-After', () {
    test('parses delay-seconds', () {
      expect(DavClient.parseRetryAfter('120'), const Duration(seconds: 120));
    });

    test('parses an HTTP-date', () {
      final when = DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 5))
          .toIso8601String();
      final parsed = DavClient.parseRetryAfter(when);
      expect(parsed, isNotNull);
      expect(parsed!.inSeconds, greaterThan(200));
    });

    test('an unparseable value is absent, not zero', () {
      // Treating a garbled value as 0 turns "come back later" into a hot loop.
      expect(DavClient.parseRetryAfter('soon'), isNull);
      expect(DavClient.parseRetryAfter(''), isNull);
      expect(DavClient.parseRetryAfter(null), isNull);
    });

    test('a past date clamps to zero', () {
      final past = DateTime.now()
          .toUtc()
          .subtract(const Duration(minutes: 5))
          .toIso8601String();
      expect(DavClient.parseRetryAfter(past), Duration.zero);
    });
  });
}
