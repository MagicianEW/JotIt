import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_exception.dart';

import '../../support/dav_harness.dart';

/// The precondition policy of `DavClient.delete` (P1-1).
///
/// The sync engine is the only conditional caller of `delete`, and these are
/// the profiles v3.0 §6.3 names: a server that evaluates `If-Match` with
/// strong tags (Nextcloud), one whose tags are weak (Synology), and one that
/// does not evaluate the header at all (nginx-dav). The bug being pinned
/// down: `delete` used to consult only `supportsIfMatch`, so a weak-tag
/// server was sent an `If-Match` that could never match (412 forever), and a
/// server without support was sent an `ArgumentError` that escaped every
/// `on DavException` handler in the engine and killed the round.
void main() {
  late DavHarness dav;

  setUp(() async {
    dav = await DavHarness.start();
  });

  tearDown(() async {
    await dav.dispose();
  });

  test('a weak-ETag server gets an unconditional delete, not a 412 loop',
      () async {
    final client = dav.client(capabilities: const DavCapabilities(
      supportsIfMatch: true,
      etagIsWeak: true,
    ));
    addTearDown(client.close);
    await client.put('a.md', utf8.encode('x'));

    // A weak tag can never satisfy If-Match (RFC 7232 compares strongly),
    // so the client must not send one at all. The old implementation did,
    // and every delete was refused forever.
    expect(await client.delete('a.md', ifMatch: 'W/"never-matches"'), isTrue);
    expect(await client.get('a.md'), isNull);
  });

  test('a server that does not evaluate If-Match is not thrown at', () async {
    final client = dav.client(capabilities: const DavCapabilities());
    addTearDown(client.close);
    await client.put('a.md', utf8.encode('x'));

    // The old implementation raised ArgumentError here. It is not a
    // DavException, so it escaped the engine's handler and took the whole
    // round down — on a delete that was perfectly safe to perform.
    expect(await client.delete('a.md', ifMatch: '"anything"'), isTrue);
    expect(await client.get('a.md'), isNull);
  });

  test('a strong stale token is still refused', () async {
    // The protection itself must survive: degrading is only for servers
    // that cannot honour the precondition, not for a base that moved.
    final seeded = await dav.client().put('a.md', utf8.encode('x'));
    await dav.client().put('a.md', utf8.encode('y'));
    await expectLater(
      dav.client().delete('a.md', ifMatch: seeded.etag!),
      throwsA(isA<DavException>()
          .having((e) => e.statusCode, 'status', 412)),
    );
    expect(await dav.client().get('a.md'), isNotNull,
        reason: 'a refused delete must leave the file exactly where it was');
  });

  test('a strong fresh token still deletes', () async {
    await dav.client().put('a.md', utf8.encode('x'));
    final stat = await dav.client().stat('a.md');
    expect(await dav.client().delete('a.md', ifMatch: stat!.etag!), isTrue);
    expect(await dav.client().get('a.md'), isNull);
  });

  test('a delete with no token is unconditional on every profile', () async {
    for (final profile in const <DavCapabilities>[
      DavCapabilities(),
      DavCapabilities(supportsIfMatch: true),
      DavCapabilities(supportsIfMatch: true, etagIsWeak: true),
    ]) {
      final client = dav.client(capabilities: profile);
      addTearDown(client.close);
      await client.put('gone.md', utf8.encode('x'));
      expect(await client.delete('gone.md'), isTrue);
      expect(await client.get('gone.md'), isNull);
    }
  });
}
