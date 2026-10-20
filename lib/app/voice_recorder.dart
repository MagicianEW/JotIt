import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:record/record.dart';

/// The slice of the `record` plugin JotIt actually uses.
///
/// The plugin is a platform channel, so a test cannot drive it. This
/// interface is the seam that lets the *decisions* JotIt makes around it be
/// tested without a microphone — above all the one about what to record in
/// when the platform turns out not to have the encoder JotIt asked for.
abstract interface class RecorderBackend {
  Future<bool> hasPermission();

  /// Whether this platform can encode with [encoder].
  ///
  /// Not every platform has every encoder: Windows, for one, needs a system
  /// AAC encoder to be installed, and a machine without it says so here
  /// rather than failing later in the middle of a recording.
  Future<bool> isEncoderSupported(AudioEncoder encoder);

  Future<void> start(RecordConfig config, {required String path});

  Future<String?> stop();

  Future<void> cancel();

  Future<void> dispose();
}

/// The real backend, on top of the `record` plugin.
class PluginRecorderBackend implements RecorderBackend {
  PluginRecorderBackend([AudioRecorder? recorder])
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) =>
      _recorder.isEncoderSupported(encoder);

  @override
  Future<void> start(RecordConfig config, {required String path}) =>
      _recorder.start(config, path: path);

  @override
  Future<String?> stop() => _recorder.stop();

  @override
  Future<void> cancel() => _recorder.cancel();

  @override
  Future<void> dispose() => _recorder.dispose();
}

/// JotIt's own microphone recorder.
///
/// **Why this is an interface and not the `record` plugin directly.** The
/// plugin is a platform channel, and a platform channel is a wall: in a unit
/// test it throws `MissingPluginException`, and every test of the editor's
/// recording flow would have to become a test of the mock. The interface is
/// the seam — a fake in the tests, the plugin in the app — and it is also
/// where the "what does a refusal mean" vocabulary lives, so the editor never
/// has to know that a permission dialog exists.
abstract interface class VoiceRecorder {
  /// Ask the platform for permission to use the microphone.
  ///
  /// Returns false when the user declined, or when the platform has no
  /// microphone at all. The caller has to say something in either case: a
  /// button that does nothing is indistinguishable from a broken app.
  Future<bool> requestPermission();

  /// Start recording into [path].
  ///
  /// The file must not exist yet, and the directory must exist: the plugin
  /// creates the file but not the folder around it.
  Future<void> start({required String path});

  /// Stop recording and return the path of what was recorded.
  ///
  /// Null when the platform produced nothing — a recording that was stopped
  /// before it began, or one the platform discarded. The caller must treat
  /// that as "there is nothing to insert" rather than as an error.
  Future<String?> stop();

  /// Throw the recording away.
  ///
  /// The file the platform wrote is removed. A cancelled recording that
  /// survives on disk is a file the user never asked for and the index will
  /// happily advertise.
  Future<void> cancel();

  /// Release the platform resources. The recorder is not usable afterwards.
  Future<void> dispose();
}

/// A recording that cannot happen, carrying a reason a person can act on.
///
/// Same idea as `AttachmentRefused`: "Failed to record" is not something
/// anybody can act on, and the whole point of the recorder existing is that
/// the user asked for a voice memo and either got one or was told why not.
class RecordingRefused implements Exception {
  const RecordingRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// The real recorder, on top of the `record` plugin.
///
/// AAC in an MPEG-4 container (`.m4a`), mono, 64 kbit/s. The format is not a
/// preference:
///
///  * AAC is the one encoder the plugin supports on **both** macOS
///    (AVFoundation) and Android (MediaCodec) — WAV would mean a different
///    file on every platform, and a note that reads the same on two devices
///    has to name the same file on both.
///  * Mono at 64 kbit/s is about 8 kB per second of speech. A minute of
///    voice memo is half a megabyte, which keeps it inside §5.5's ordinary
///    upload path instead of the streamed one.
///  * The vault already knows the MIME type (`.m4a` → `audio/mp4`), so the
///    sync engine sends the right `Content-Type` without a new rule.
///
/// **WAV is the fallback, not the choice.** Windows needs a *system* AAC
/// encoder to be present, and a machine without one — a server edition, a
/// trimmed install, a machine where the media pack was removed — cannot
/// encode AAC at all. A recorder that only knew one format would fail there
/// with a message about an encoder the user has never heard of. So the
/// recorder asks what the platform can do, and falls back to WAV, which
/// every platform can always do. A bigger file is a much smaller problem
/// than a feature that does not work on one platform.
class PluginVoiceRecorder implements VoiceRecorder {
  PluginVoiceRecorder({RecorderBackend? backend})
      : _backend = backend ?? PluginRecorderBackend();

  final RecorderBackend _backend;

  /// The configuration every recording uses when the platform can do AAC.
  static const RecordConfig aacConfig = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 64000,
    sampleRate: 44100,
    numChannels: 1,
  );

  /// The fallback, for a platform with no AAC encoder.
  ///
  /// The bit rate is left alone: PCM is not a bit-rate format, and a
  /// `bitRate` on it is a number the platform ignores.
  static const RecordConfig wavConfig = RecordConfig(
    encoder: AudioEncoder.wav,
    sampleRate: 44100,
    numChannels: 1,
  );

  /// The file extension each encoder produces, dot included.
  ///
  /// The extension is not decoration: the attachment writer takes the file's
  /// extension to decide what the file in the vault is called, and the sync
  /// engine decides what to do with it by that extension's MIME type. A
  /// recording whose extension lied about its contents would be sent with
  /// the wrong `Content-Type`.
  static const Map<AudioEncoder, String> _extensions = <AudioEncoder, String>{
    AudioEncoder.aacLc: '.m4a',
    AudioEncoder.aacEld: '.m4a',
    AudioEncoder.wav: '.wav',
    AudioEncoder.pcm16bits: '.wav',
  };

  @override
  Future<bool> requestPermission() async {
    try {
      return await _backend.hasPermission();
    } on Object {
      // A platform that cannot answer the question has not granted it.
      // Reporting "no" here produces a sentence the user can act on;
      // letting the exception escape produces a stack trace they cannot.
      return false;
    }
  }

  @override
  Future<void> start({required String path}) async {
    final config = await _chooseConfig();
    final target = _withExtension(path, _extensions[config.encoder] ?? '.m4a');
    try {
      await _backend.start(config, path: target);
    } on Object catch (e) {
      throw RecordingRefused('打不开麦克风：$e');
    }
  }

  /// The path the recording is actually written to.
  ///
  /// The name has to follow the format: a file called `recording.m4a` that
  /// holds WAV bytes is a file the vault will send with the wrong
  /// `Content-Type` and the preview will not recognise. The extension is
  /// replaced rather than appended to, so a path that already carries one
  /// does not end up with two.
  static String _withExtension(String path, String extension) {
    final current = p.extension(path);
    final stem = current.isEmpty
        ? path
        : path.substring(0, path.length - current.length);
    return '$stem$extension';
  }

  /// Picks the format this platform can actually produce.
  Future<RecordConfig> _chooseConfig() async {
    if (await _supports(AudioEncoder.aacLc)) return aacConfig;
    return wavConfig;
  }

  Future<bool> _supports(AudioEncoder encoder) async {
    try {
      return await _backend.isEncoderSupported(encoder);
    } on Object {
      // A platform that cannot answer the question has not refused it. The
      // three platforms JotIt ships on all answer it, but a plugin update
      // that dropped the method would otherwise turn every recording on
      // that platform into a WAV file for no reason anyone asked for.
      return true;
    }
  }

  @override
  Future<String?> stop() async {
    try {
      return await _backend.stop();
    } on Object catch (e) {
      throw RecordingRefused('停止录音失败：$e');
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _backend.cancel();
    } on Object {
      // Cancelling is best-effort by definition: the user has already said
      // they do not want this, and a failure to clean up must not turn into a
      // second error on top of the first.
    }
  }

  @override
  Future<void> dispose() async {
    try {
      await _backend.dispose();
    } on Object {
      // Nothing to do about a recorder that will not release itself, and
      // the process is about to drop it anyway.
    }
  }
}

/// A directory the recording can be written into, and the cleanup that takes
/// it away again.
///
/// The recording never lands in the vault directly. It lands in a temporary
/// directory first, is copied into the vault by the same attachment path
/// every other file takes, and the temporary copy is deleted afterwards —
/// so a cancelled or failed recording leaves nothing behind, and a successful
/// one is subject to exactly the same "the file is the truth" rules as an
/// image picked from disk.
class RecordingWorkspace {
  RecordingWorkspace._(this.directory, this.filePath);

  /// Creates a workspace whose recording file is named [fileName].
  ///
  /// The extension is not decoration: the attachment writer takes the file's
  /// extension to decide what the file in the vault is called, and the
  /// scanner decides what to do with it by looking at that extension's MIME
  /// type.
  static Future<RecordingWorkspace> create({
    String fileName = 'recording.m4a',
  }) async {
    final dir = await Directory.systemTemp.createTemp('jotit_rec_');
    return RecordingWorkspace._(dir, '${dir.path}${Platform.pathSeparator}$fileName');
  }

  final Directory directory;

  /// The absolute path the recorder writes to.
  final String filePath;

  /// The file the platform actually produced, if it produced one.
  ///
  /// The plugin is supposed to write to [filePath] and report the same path
  /// back, but a platform that names the file itself is allowed to: what
  /// matters is the file that exists, not the name it was asked for.
  /// [preferred] is the path the platform reported when it stopped, and it
  /// is consulted first — a platform's own answer about its own file beats a
  /// directory listing.
  Future<File?> producedFile({String? preferred}) async {
    for (final candidate in <String>[?preferred, filePath]) {
      final file = File(candidate);
      if (await file.exists() && await file.length() > 0) return file;
    }

    for (final file in directory.listSync().whereType<File>()) {
      if (await file.length() > 0) return file;
    }
    return null;
  }

  /// Delete the workspace and everything in it.
  Future<void> dispose() async {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    } on Object {
      // The operating system collects the temp directory eventually, and a
      // failure here must not be the last thing the user hears about.
    }
  }
}
