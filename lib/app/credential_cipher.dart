import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

/// Seals WebDAV credentials for storage in `sync_roots.credential_blob`
/// (v3.0 §8.3).
///
/// **What this is worth, stated plainly.** The payload is AES-256-GCM with a
/// random per-blob nonce and an authentication tag, so the database alone never
/// yields a password, and a tampered blob is rejected rather than decrypted.
/// What it is *not* yet is §8.3's "keyed by the application master key": today
/// the 32-byte master key sits in the app data directory beside the database it
/// protects, so anyone who can read the profile directory has both. That is a
/// real improvement over a cleartext column and a real gap against the spec.
/// Closing it means DPAPI on Windows, the Keychain on macOS, the Android
/// Keystore — one platform at a time, starting with the one this app is being
/// built for.
///
/// [_loadOrCreateKey] is the only method that knows where the key lives, so
/// that swap is a one-method change rather than an audit of this file.
class CredentialCipher {
  CredentialCipher(this._resolveDirectory);

  /// Resolves the app's private data directory **when a credential is first
  /// touched**, not when the vault is opened.
  ///
  /// That laziness is not a micro-optimisation. `getApplicationSupportDirectory`
  /// is a platform channel call, and putting it on the startup path makes
  /// opening a vault untestable without a plugin implementation — which is
  /// exactly what happened the first time this was written inline in
  /// `VaultSession.open`.
  final Future<Directory> Function() _resolveDirectory;

  static const int _keyBytes = 32;

  final AesGcm _gcm = AesGcm.with256bits();

  SecretKey? _cachedKey;

  /// `nonce || ciphertext || tag`, base64. One blob per sync root.
  ///
  /// The cleartext `String` cannot be wiped — Dart strings are immutable and
  /// the caller's copy lives until it is collected. The bytes handed to the
  /// cipher are ours, and those are cleared.
  Future<String> seal(String plaintext) async {
    final nonce = _randomBytes(12);
    final secret = await _loadOrCreateKey();

    // `utf8.encode` hands back a `Uint8List`, and it holds the password in the
    // clear. `copy` first: the encoder is free to return a view, and wiping
    // through a view of a buffer the cipher is still reading would blank the
    // ciphertext too.
    final clear = Uint8List.fromList(utf8.encode(plaintext));
    final SecretBox box;
    try {
      box = await _gcm.encrypt(clear, secretKey: secret, nonce: nonce);
    } finally {
      _wipe(clear);
    }

    final out = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + box.cipherText.length,
        box.cipherText);
    out.setRange(nonce.length + box.cipherText.length, out.length,
        box.mac.bytes);
    // Encode first, wipe second. `Uint8List` is mutable and `out` *is* the
    // buffer being returned, so clearing it before encoding hands back base64
    // of a row of zeros — a blob that round-trips to an empty password rather
    // than failing.
    final encoded = base64Encode(out);
    _wipe(out);
    return encoded;
  }

  /// Returns null when the blob is missing, truncated, or fails its
  /// authentication tag. A credential that cannot be proven intact is treated
  /// as absent so the UI asks again — never decrypted into garbage, and never
  /// reported as an error the user cannot act on.
  Future<String?> open(String? blob) async {
    if (blob == null || blob.isEmpty) return null;
    try {
      final bytes = base64Decode(blob);
      if (bytes.length < 13) return null;

      final nonce = Uint8List.sublistView(bytes, 0, 12);
      final body = Uint8List.sublistView(bytes, 12);
      final macBytes = Uint8List.sublistView(body, body.length - 16);
      final cipherText =
          Uint8List.sublistView(body, 0, body.length - 16);

      final box = SecretBox(
        cipherText,
        nonce: nonce,
        mac: Mac(macBytes),
      );
      // The one place in this file that ever holds a bare WebDAV password in
      // mutable memory. `utf8.decode` copies out of it and is done before the
      // wipe; after that the only copy left is the `String`, which Dart gives
      // us no way to reach.
      final clear = Uint8List.fromList(
        await _gcm.decrypt(box, secretKey: await _loadOrCreateKey()),
      );
      try {
        return utf8.decode(clear);
      } finally {
        _wipe(clear);
      }
    } on Object {
      return null;
    }
  }

  Future<SecretKey> _loadOrCreateKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;

    // Never the vault itself: the vault is a folder the user is meant to sync
    // and back up, and a key inside it would travel to every one of their
    // devices.
    final directory = await _resolveDirectory();
    final file = File(p.join(directory.path, 'master.key'));
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.length != _keyBytes) {
        // A wrong-length key means a half-written file or a foreign one.
        // Failing loudly beats silently minting a new one, which would orphan
        // every credential already sealed under the old key and present the
        // user with a password dialog that cannot possibly succeed.
        throw StateError('master key at ${file.path} is ${bytes.length} '
            'bytes, expected $_keyBytes');
      }
      return _cachedKey = SecretKey(bytes);
    }

    final key = _randomBytes(_keyBytes);
    await directory.create(recursive: true);
    await file.writeAsBytes(key, flush: true);
    _restrictToOwner(file.path);
    return _cachedKey = SecretKey(key);
  }

  /// Best effort. Windows inherits the profile directory's ACL, which is
  /// already per-user; the other platforms restrict the app data directory
  /// themselves.
  static void _restrictToOwner(String path) {
    if (Platform.isWindows) return;
    try {
      Process.runSync('chmod', <String>['600', path]);
    } on Object {
      // Not fatal: the file lives in a directory the platform already guards.
    }
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = rng.nextInt(256);
    }
    return out;
  }

  static void _wipe(Uint8List bytes) {
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = 0;
    }
  }
}