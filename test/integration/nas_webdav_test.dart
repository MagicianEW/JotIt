import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';

/// Live integration against the real NAS (Synology DSM over Apache mod_dav).
///
/// Skipped unless `JOTIT_DAV_URL` is set, so `flutter test` stays hermetic:
///
///   $env:JOTIT_DAV_URL='http://192.168.1.100:35115/webDAV/JotIt/'
///   $env:JOTIT_DAV_USER='testuser'
///   $env:JOTIT_DAV_PASS='...'
///   flutter test test/integration/nas_webdav_test.dart
///
/// Why this is worth having when a local harness already covers the protocol:
/// the harness is written to agree with us. This server is not. It has already
/// disagreed twice — it advertises strong quoted ETags in Apache's
/// `inode-size-mtime` shape, it offers no `getctag`, and it names the DAV
/// namespace `lp1:` rather than `D:`. Everything asserted below is something
/// that had to be true for the design to work and could only be found out by
/// asking.
void main() {
  final baseUrl = Platform.environment['JOTIT_DAV_URL'];
  final user = Platform.environment['JOTIT_DAV_USER'] ?? 'testuser';
  final pass = Platform.environment['JOTIT_DAV_PASS'] ?? '';

  if (baseUrl == null || baseUrl.isEmpty) {
    test('live NAS integration', () {}, skip: 'JOTIT_DAV_URL is not set');
    return;
  }

  late DavClient client;
  late Uri base;

  // Everything the suite creates lives under one scratch collection so a
  // half-finished run cannot scatter files across the user's notes/.
  final scratch = '_selftest-${DateTime.now().millisecondsSinceEpoch}';

  String note(String body) => '---\nuid: $scratch\ntitle: T\n---\n\n$body\n';

  setUpAll(() async {
    base = Uri.parse(baseUrl);
    client = DavClient(
      baseUri: base,
      username: user,
      password: pass,
      capabilities: DavCapabilities(
        supportsCtag: false,
        supportsIfMatch: true,
        supportsIfNoneMatch: true,
      ),
    );
    // The base collection may legitimately not exist until the app creates
    // it; JotIt's own contract is that it creates its directory.
    await _mkcol(base, scratch, user, pass);
  });

  tearDownAll(() async {
    try {
      await _rmtree(base, scratch, user, pass);
    } on Object catch (e) {
      // Leaving a scratch directory behind is untidy, not dangerous. Say so.
      // ignore: avoid_print
      print('could not remove $scratch: $e');
    }
    await client.close();
  });

  test('the credential works and the server answers 207', () async {
    final listing = await client.propfind(scratch, depth: 1);
    expect(listing.resources, isNotEmpty);
    expect(listing.self?.isCollection, isTrue);
  });

  test('capabilities match what ADR-8 depends on', () async {
    final caps = await client.probe();

    // Measured on the real box, not assumed. Apache mod_dav hands out
    // `W/"31-65d403f887398"` for every file, so `supportsIfMatch` is a lie
    // here: If-Match needs strong comparison and can never succeed. The
    // engine has to degrade to hash comparison, and this is the assertion
    // that will fail loudly the day DSM is reconfigured.
    expect(caps.server, isNotNull);
    expect(caps.etagIsWeak, isTrue,
        reason: 'if this flips to false the engine starts sending If-Match '
            'again and the degraded path stops being exercised');
    expect(caps.supportsCtag, isFalse,
        reason: '§6.3 Synology profile; a CTag here would mean rounds may skip '
            'the walk entirely');
  });

  test('a file round-trips byte for byte', () async {
    final bytes = utf8.encode(note('hello from the NAS'));
    final put = await client.put('$scratch/a.md', bytes);
    expect(put.statusCode, anyOf(200, 201, 204));

    final back = await client.get('$scratch/a.md');
    expect(back, isNotNull);
    expect(back, bytes,
        reason: 'the hash the sync base records is taken over these bytes; '
            'a server that rewrites them breaks every later comparison');
  });

  test('a PUT returns no ETag, so the base must be re-read', () async {
    // The engine compensates with a stat after every such write. Without that,
    // base_etag stays null forever and each round re-downloads its own upload.
    final put = await client.put('$scratch/b.md', utf8.encode(note('b')));
    expect(put.etag, isNull,
        reason: 'if DSM ever starts returning one, the stat after write is '
            'redundant but harmless');

    final listing = await client.propfind(scratch, depth: 1);
    final entry =
        listing.resources.where((r) => r.path.endsWith('/b.md')).firstOrNull;
    expect(entry, isNotNull);
    expect(entry!.etag, isNotNull, reason: 'PROPFIND does report one');
    expect(entry.etag, startsWith('W/'),
        reason: 'weak tags are why the engine cannot use If-Match here');
    expect(entry.strongForm, isNotNull);
    expect(entry.strongForm, isNot(entry.etag),
        reason: 'strongForm strips the W/ and is display-only — it must never '
            'be sent back in a conditional header');
  });

  test('If-Match can never succeed here, which is why the engine degrades',
      () async {
    final path = '$scratch/c.md';
    await client.put(path, utf8.encode(note('v1')));

    final listing = await client.propfind(scratch, depth: 1);
    final current = listing.resources
        .where((r) => r.path.endsWith('/c.md'))
        .firstOrNull!;

    // The decisive experiment. RFC 7232 requires strong comparison for
    // If-Match, so a weak tag can never match — not even the *current* one.
    // Apache evaluates it anyway and answers 412, meaning a client that sent
    // If-Match here would be permanently locked out of updating any note.
    final refused = await client.put(path, utf8.encode(note('v2')),
        condition: DavIfMatch(current.etag!));
    expect(refused.statusCode, 412);
    expect(utf8.decode((await client.get(path))!), contains('v1'),
        reason: 'nothing was written');
  });

  test('If-None-Match still gives atomic create on a weak-ETag server',
      () async {
    // This is what keeps two devices from both creating the same path
    // (matrix row 2) when If-Match is off the table. `If-None-Match: *`
    // compares nothing, so weak ETags do not affect it.
    final path = '$scratch/d.md';
    final first = await client.put(path, utf8.encode(note('mine')),
        condition: const DavIfAbsent());
    expect(first.statusCode, anyOf(201, 204));

    final again = await client.put(path, utf8.encode(note('theirs')),
        condition: const DavIfAbsent());
    expect(again.statusCode, 412);
    expect(utf8.decode((await client.get(path))!), contains('mine'));
  });

  test('MOVE renames and the identity inside the file survives', () async {
    final from = '$scratch/e.md';
    final to = '$scratch/e-renamed.md';
    await client.put(from, utf8.encode(note('carries a uid')));

    await client.move(from, to);
    expect(await client.get(from), isNull);
    expect(utf8.decode((await client.get(to))!), contains('uid: $scratch'),
        reason: 'ADR-2: a rename keeps the logical identity');
  });

  test('the collection advertises no CTag, so rounds must full-scan',
      () async {
    final listing = await client.propfind(scratch, depth: 0);
    expect(listing.self?.ctag, isNull,
        reason: 'if this ever changes, the Synology profile in §6.3 is stale');
  });
}

/// Minimal MKCOL / recursive DELETE.
///
/// `DavClient` has neither: the vault layout is created locally, and a sync
/// round never removes a collection. A self-test against a real server needs
/// both, so it speaks HTTP directly for them and keeps the client under test
/// focused on the parts that matter.
Future<void> _raw(String method, Uri uri, String user, String pass) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, uri);
    req.headers.set(
      HttpHeaders.authorizationHeader,
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}',
    );
    final resp = await req.close();
    await resp.drain<void>();
  } finally {
    client.close(force: true);
  }
}

Future<void> _mkcol(Uri base, String name, String user, String pass) =>
    _raw('MKCOL', base.resolve('$name/'), user, pass);

Future<void> _rmtree(Uri base, String name, String user, String pass) =>
    _raw('DELETE', base.resolve('$name/'), user, pass);