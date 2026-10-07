import 'dart:async';

/// A WebDAV operation failed at the transport or protocol layer.
///
/// [body] is deliberately truncated: a PROPFIND 207 that fails to parse is
/// worth seeing, a 30 MB HTML page from a reverse proxy in front of the NAS
/// is not.
class DavException implements Exception {
  DavException({
    required this.method,
    required this.uri,
    required this.reason,
    this.statusCode,
    this.body,
    this.retryAfter,
    this.cause,
  });

  final String method;
  final Uri uri;

  /// Short, stable, log-friendly. Never put user data in here.
  final String reason;

  /// Null means the request never produced an HTTP status: DNS failure,
  /// connection refused, TLS error, or [timeout].
  final int? statusCode;

  final String? body;

  /// Parsed `Retry-After`, honoured by the session state machine.
  final Duration? retryAfter;

  final Object? cause;

  /// The request took longer than the client timeout.
  bool get isTimeout => statusCode == null && cause is TimeoutException;

  /// No HTTP status at all — the request never landed. Retryable.
  bool get isTransport => statusCode == null;

  /// True when the server understood and refused the request because a
  /// precondition failed. ADR-8 leans on exactly this status to detect a
  /// lost-update race without ever overwriting somebody else's write.
  bool get isPreconditionFailed => statusCode == 412;

  /// 409 Conflict: another sync session got there first, or the collection
  /// state changed under us. Recoverable next round.
  bool get isConflict => statusCode == 409;

  /// The server is rate limiting or briefly overloaded. Recoverable, and the
  /// caller must honour [retryAfter].
  bool get isOverloaded => statusCode == 429 || statusCode == 503;

  /// 401/403 will not fix themselves by retrying; they need a credential or
  /// a permission change. [retryAfter] is irrelevant here.
  bool get isAuth => statusCode == 401 || statusCode == 403;

  /// 5xx is the server's fault and is usually transient.
  bool get isServerFault => statusCode != null && statusCode! >= 500;

  /// A 4xx that is not auth, precondition, conflict or overload. Retrying it
  /// unchanged only burns the retry budget — this is how the queue reaches
  /// its dead-letter state instead of looping forever.
  bool get isPermanentClientError =>
      statusCode != null &&
      statusCode! >= 400 &&
      statusCode! < 500 &&
      !isAuth &&
      !isPreconditionFailed &&
      !isConflict &&
      !isOverloaded;

  @override
  String toString() {
    final code = statusCode == null ? '' : ' $statusCode';
    final raw = body;
    final tail = raw == null || raw.isEmpty
        ? ''
        : ' | ${raw.length > 300 ? '${raw.substring(0, 300)}…' : raw}';
    return 'DavException: $method $uri$code — $reason$tail';
  }
}