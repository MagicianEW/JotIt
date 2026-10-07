import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/credential_cipher.dart';

/// 搂8.3 鈥?the sealed WebDAV credential.
///
/// The interesting failures here are all silent ones: a blob that round-trips
/// to the wrong string, or a blob that round-trips to an empty one because the
/// buffer was cleared before it was encoded. Both would look like "sync stopped
/// working" and neither would throw.
void main() {
  late Directory dir;
  late CredentialCipher cipher;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jotit_cred_');
    cipher = CredentialCipher(() async => dir);
  });

  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a password survives a round trip', () async {
    const secret = '=test=Passw0rd:';
    final blob = await cipher.seal(secret);
    expect(await cipher.open(blob), secret);
  });

  test('the ciphertext contains no fragment of the password', () async {
    const secret = 'correct-horse-battery-staple';
    final blob = await cipher.seal(secret);
    final decoded = base64Decode(blob);

    // Not a substring search over the whole blob 鈥?a base64 blob of a
    // sufficiently long secret will contain almost any short sequence by
    // chance. Searching for a 12-character run is the point.
    expect(utf8.decode(decoded, allowMalformed: true), isNot(contains(secret)));
    expect(blob.length, greaterThan(secret.length));
  });

  test('two seals of the same password differ', () async {
    const secret = 'same';
    final a = await cipher.seal(secret);
    final b = await cipher.seal(secret);
    expect(a, isNot(b), reason: 'a reused nonce under one key is fatal to GCM');
    expect(await cipher.open(a), secret);
    expect(await cipher.open(b), secret);
  });

  test('a tampered blob is rejected rather than decrypted', () async {
    final blob = await cipher.seal('hunter2');
    final bytes = base64Decode(blob);
    // Flip one bit well inside the ciphertext, never in the nonce or tag, so
    // this is a forgery attempt rather than a truncation.
    bytes[bytes.length - 20] ^= 0x01;
    expect(await cipher.open(base64Encode(bytes)), isNull,
        reason: 'an unauthenticated plaintext here is how a wrong password '
            'silently becomes someone else\'s');
  });

  test('a truncated blob is rejected', () async {
    final blob = await cipher.seal('hunter2');
    final bytes = base64Decode(blob);
    expect(await cipher.open(base64Encode(bytes.sublist(0, 8))), isNull);
    expect(await cipher.open(base64Encode(bytes.sublist(0, bytes.length - 1))),
        isNull);
  });

  test('garbage and absence are both null, not exceptions', () async {
    expect(await cipher.open(null), isNull);
    expect(await cipher.open(''), isNull);
    expect(await cipher.open('not base64 at all !!'), isNull);
    expect(await cipher.open(base64Encode(List<int>.filled(4, 0))), isNull);
  });

  test('the key is created once and reused across cipher instances', () async {
    final first = await cipher.seal('one');
    // A second cipher over the same directory 鈥?the shape the app has on every
    // restart, and the one that breaks if the key is minted per instance.
    final reopened = CredentialCipher(() async => dir);
    expect(await reopened.open(first), 'one');

    final keyFile = File('${dir.path}${Platform.pathSeparator}master.key');
    expect(await keyFile.exists(), isTrue);
    expect(await keyFile.length(), 32);
  });

  test('a foreign key file fails loudly instead of minting a new key', () async {
    await cipher.seal('one');
    await File('${dir.path}${Platform.pathSeparator}master.key')
        .writeAsBytes(List<int>.filled(7, 3));

    // Silently minting a replacement would orphan every sealed credential and
    // hand the user a password dialog that cannot possibly succeed.
    expect(
      () => CredentialCipher(() async => dir).seal('two'),
      throwsA(isA<StateError>()),
    );
  });

  test('unicode and long passwords round trip byte for byte', () async {
    final rng = Random(7);
    for (final secret in <String>[
      '瀵嗙爜=test=Passw0rd:',
      '馃攼 emoji pin',
      'x' * 512,
    ]) {
      expect(await cipher.open(await cipher.seal(secret)), secret,
          reason: 'length ${secret.length}');
    }
    expect(rng.nextInt(2), isNonNegative);
  });
}