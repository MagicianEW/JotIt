import 'dart:convert';
import 'dart:io';

import 'package:jotit/data/dav/dav_capabilities.dart';
import 'package:jotit/data/dav/dav_client.dart';
import 'package:path/path.dart' as p;

/// A live WebDAV server for one test file, in the capability profile the
/// test names.
///
/// Tests run against a real socket rather than a mock on purpose: the single
/// thing that made `If-Match` unusable from a shell is quote fidelity on the
/// wire, and a mocked `http.Client` can never reproduce that. The same applies
/// to `Depth: 1` listings and to a server that answers 412 rather than
/// silently overwriting.
///
/// Capability profiles mirror v3.0 §6.3's matrix:
///  * full — CTag and `If-Match`, i.e. Nextcloud,
///  * `--no-ctag` — Synology DSM,
///  * `--no-if-match` — nginx dav / Apache mod_dav.
class DavHarness {
  DavHarness._(this._proc, this.root, this.port, this.logs);

  final Process _proc;

  /// Where the server keeps the files it serves. Point a [NoteFileStore] at
  /// the same directory to stage the remote side without going over HTTP.
  final Directory root;

  final int port;
  final StringBuffer logs;

  Uri baseUri() => Uri.parse('http://127.0.0.1:$port/dav/');

  DavClient client({
    String username = 'testuser',
    String password = 'test',
    DavCapabilities? capabilities,
  }) =>
      DavClient(
        baseUri: baseUri(),
        username: username,
        password: password,
        capabilities: capabilities ?? fullProfile,
      );

  static const DavCapabilities fullProfile = DavCapabilities(
    supportsCtag: true,
    supportsIfMatch: true,
    supportsIfNoneMatch: true,
  );

  static Future<DavHarness> start({
    List<String> extraArgs = const <String>[],
    String password = 'test',
  }) async {
    final root = await Directory.systemTemp.createTemp('jotit_dav_');
    final logs = StringBuffer();

    // Pick a free port by binding one and immediately releasing it. A fixed
    // port would make the suite fail whenever a previous run's server is
    // still shutting down.
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();

    final script = File(p.join(_repoRoot(), 'tools', 'webdav-test-server.mjs'));
    if (!script.existsSync()) {
      throw StateError('test server script not found at ${script.path}');
    }

    final proc = await Process.start(
      // `Platform.resolvedExecutable` under `flutter test` is the Dart VM,
      // which cannot execute a .mjs file - it would parse it as Dart and
      // exit. Node is what actually runs this.
      'node',
      <String>[
        script.path,
        '--root', root.path,
        '--port', '$port',
        '--pass', password,
        ...extraArgs,
      ],
      includeParentEnvironment: true,
    );
    proc.stdout.transform(utf8.decoder).listen(logs.write);
    proc.stderr.transform(utf8.decoder).listen(logs.write);

    final harness = DavHarness._(proc, root, port, logs);

    // Wait for the listener rather than sleeping a fixed amount: a fixed
    // sleep is either flaky or needlessly slow, and on a loaded CI box it
    // is always both.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect('127.0.0.1', port,
            timeout: const Duration(milliseconds: 400));
        socket.destroy();
        return harness;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    }
    await harness.dispose();
    throw StateError('WebDAV test server did not come up on port $port\n$logs');
  }

  /// Writes a file straight into the server's storage, bypassing HTTP. Used
  /// to stage "the other device edited this" without a second client.
  Future<void> seedRemote(String davRelativePath, List<int> bytes) async {
    final file = File(p.join(root.path, p.joinAll(davRelativePath.split('/'))));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  Future<List<int>?> readRemote(String davRelativePath) async {
    final file = File(p.join(root.path, p.joinAll(davRelativePath.split('/'))));
    return await file.exists() ? file.readAsBytes() : null;
  }

  Future<bool> remoteExists(String davRelativePath) async =>
      File(p.join(root.path, p.joinAll(davRelativePath.split('/')))).existsSync();

  Future<void> dispose() async {
    _proc.kill(ProcessSignal.sigkill);
    await _proc.exitCode.timeout(const Duration(seconds: 5),
        onTimeout: () => -1);
    if (root.existsSync()) {
      await root.delete(recursive: true);
    }
  }

  /// Walks up from the working directory to the package root (the directory
  /// holding pubspec.yaml) and returns its parent. Hardcoding a relative depth
  /// is a trap: `flutter test` runs with the workspace root as the cwd, while
  /// `dart run` uses the package root.
  static String _repoRoot() {
    var dir = Directory.current.absolute;
    while (!File(p.join(dir.path, 'pubspec.yaml')).existsSync()) {
      final parent = dir.parent;
      if (parent.path == dir.path) {
        throw StateError('could not find pubspec.yaml above ${Directory.current}');
      }
      dir = parent;
    }
    return dir.parent.path;
  }
}