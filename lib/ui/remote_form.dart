import 'package:uuid/uuid.dart';

import '../data/db/sync_root_store.dart';

/// Validates a WebDAV base URL at the form layer, so a malformed address is
/// rejected with a readable sentence before a single byte goes on the wire.
///
/// `Uri.tryParse` alone is far too permissive to be a form validator: the
/// user-typed `http://http//nas.example.com/...` parses happily with host
/// `http`, passes every structural check, and only fails later as an opaque
/// "transport failure" pointing at a server that does not exist. The rules
/// here are deliberately narrow — a WebDAV base is
/// `http(s)://host[:port]/path`, and a host is a domain (contains a dot), an
/// IP or IPv6 literal, or `localhost`.
///
/// Returns the error message, or null when the address is acceptable.
String? validateWebDavUrl(String? value) {
  final text = (value ?? '').trim();
  final u = Uri.tryParse(text);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) {
    return '地址格式不对：需要以 http:// 或 https:// 开头';
  }
  if (u.host.isEmpty) {
    return '地址格式不对：缺少主机名';
  }
  if (u.host == 'http' || u.host == 'https') {
    return '地址格式不对：开头多写了一个 http(s)://，主机名应是域名或 IP';
  }
  final hostPlausible =
      u.host.contains('.') || u.host == 'localhost' || u.host.contains(':');
  if (!hostPlausible) {
    return '地址格式不对：主机名应为域名或 IP（例如 nas.example.com、'
        '192.168.1.100 或 localhost）';
  }
  return null;
}

/// Builds the record that one save of the remote dialog persists.
///
/// Editing must not rebuild the record from scratch. Constructing a fresh
/// `SyncRootRecord` — no `credentialBlob`, no CTag, no backoff deadline, no
/// last error — turned every edit into "wipe the saved password and forget
/// everything the engine ever learned about this server", while the dialog's
/// own helper text promised 留空表示不改动已保存的密码. [SyncRootRecord.copyWith]
/// keeps whatever the dialog did not touch; that is what "leave it alone" has
/// to mean. For the same reason an empty username now keeps the saved one: a
/// user fixing a typo in the URL is not trying to go anonymous as a side
/// effect. (A new remote with no username is still anonymous — there is
/// nothing to keep.)
SyncRootRecord buildRemoteRecord({
  required SyncRootRecord? existing,
  required String name,
  required String url,
  required String? username,
}) {
  // Normalised here rather than at use: a base without a trailing slash makes
  // `Uri.resolve` drop the last segment, which silently writes every note one
  // directory too high.
  final normalised = url.endsWith('/') ? url : '$url/';
  return existing == null
      ? SyncRootRecord(
          id: const Uuid().v4(),
          name: name,
          baseUrl: normalised,
          username: username,
        )
      : existing.copyWith(name: name, baseUrl: normalised, username: username);
}
