import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/data/db/sync_root_store.dart';
import 'package:jotit/ui/remote_form.dart';

/// The two form-layer contracts of the remote dialog, both born from real
/// misfires:
///
/// - The URL validator, after a user-typed `http://http//nas...` sailed past
///   the old "has a scheme, has a host" check and only died later as an
///   opaque transport failure.
/// - [buildRemoteRecord]'s edit path, which must keep everything the dialog
///   does not touch. The fresh-constructor version wiped the saved password —
///   and the CTag, the backoff deadline and the last error with it — on every
///   edit, while the dialog's helper text promised the opposite.
void main() {
  group('validateWebDavUrl', () {
    test('accepts the shapes a real deployment uses', () {
      expect(validateWebDavUrl('http://nas.example.com:35115/webDAV'), isNull);
      expect(validateWebDavUrl('http://192.168.1.100:35115/webDAV/JotIt/'), isNull);
      expect(validateWebDavUrl('https://dav.example.com/'), isNull);
      expect(validateWebDavUrl('http://localhost:35116'), isNull);
      // Trimmed before parsing — a pasted URL with a trailing space is not
      // the user's mistake to debug.
      expect(validateWebDavUrl('  http://dav.example.com  '), isNull);
    });

    test('rejects a doubled scheme with a sentence that names the mistake', () {
      final error = validateWebDavUrl('http://http//nas.example.com:35115/webDAV');
      expect(error, isNotNull);
      expect(error, contains('多写'));
    });

    test('rejects a missing scheme', () {
      expect(validateWebDavUrl('http//nas.example.com:35115/webDAV'), isNotNull);
      expect(validateWebDavUrl('nas.example.com:35115/webDAV'), isNotNull);
    });

    test('rejects schemes a WebDAV base cannot use', () {
      expect(validateWebDavUrl('ftp://dav.example.com/'), isNotNull);
      expect(validateWebDavUrl('file:///C:/notes'), isNotNull);
    });

    test('rejects hosts that cannot be reached', () {
      expect(validateWebDavUrl('http://nas/webDAV'), isNotNull,
          reason: 'a single label without a dot is almost always the doubled-'
              'scheme mistake wearing a different coat');
      expect(validateWebDavUrl('http:///webDAV'), isNotNull);
    });

    test('rejects nothing-input shapes without crashing', () {
      expect(validateWebDavUrl(null), isNotNull);
      expect(validateWebDavUrl(''), isNotNull);
      expect(validateWebDavUrl('   '), isNotNull);
    });
  });

  group('buildRemoteRecord', () {
    const existing = SyncRootRecord(
      id: 'root-1',
      name: '旧名字',
      baseUrl: 'http://old.example.com/dav/',
      username: 'testuser',
      capabilities: {'server': 'SYNO'},
      credentialBlob: 'sealed-blob',
      lastSyncAt: 1234,
      nextAttemptAt: 5678,
      lastError: '上次失败原因',
    );

    test('editing keeps the credential and the sync state', () {
      final r = buildRemoteRecord(
        existing: existing,
        name: '新名字',
        url: 'http://nas.example.com:35115/webDAV',
        username: 'testuser',
      );

      expect(r.id, 'root-1', reason: 'an edit is an edit, not a new remote');
      expect(r.name, '新名字');
      expect(r.baseUrl, 'http://nas.example.com:35115/webDAV/');
      expect(r.credentialBlob, 'sealed-blob',
          reason: 'editing a URL must not wipe the saved password');
      expect(r.collectionCtag, isNull, reason: 'the fixture never had one');
      expect(r.lastSyncAt, 1234);
      expect(r.nextAttemptAt, 5678, reason: 'a URL edit must not cancel a '
          'backoff the engine deliberately armed');
      expect(r.lastError, '上次失败原因');
      expect(r.capabilities, {'server': 'SYNO'});
    });

    test('a blank username keeps the saved one', () {
      final r = buildRemoteRecord(
        existing: existing,
        name: '旧名字',
        url: 'http://nas.example.com:35115/webDAV',
        username: null,
      );
      expect(r.username, 'testuser');
    });

    test('a filled username replaces the saved one', () {
      final r = buildRemoteRecord(
        existing: existing,
        name: '旧名字',
        url: 'http://nas.example.com:35115/webDAV',
        username: 'other',
      );
      expect(r.username, 'other');
    });

    test('a new remote is anonymous when no username is given', () {
      final r = buildRemoteRecord(
        existing: null,
        name: '新',
        url: 'http://dav.example.com/',
        username: null,
      );
      expect(r.username, isNull);
      expect(r.credentialBlob, isNull);
      expect(r.baseUrl.endsWith('/'), isTrue,
          reason: 'a base without a trailing slash makes Uri.resolve drop '
              'the last segment');
    });
  });
}
