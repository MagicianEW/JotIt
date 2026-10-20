import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/voice_recorder.dart';
import 'package:record/record.dart';

/// What the recorder negotiates with the platform before it records.
///
/// The microphone is a platform channel, so the recorder talks to a
/// [RecorderBackend] — the same seam the app uses. What is under test here
/// is the decision, not the microphone: which encoder the platform can
/// actually produce, and what the file that comes out is called.
class _FakeBackend implements RecorderBackend {
  _FakeBackend({this.supported = const <AudioEncoder>{}, this.probeThrows = false});

  /// The encoders this pretend platform can produce.
  final Set<AudioEncoder> supported;

  /// Whether asking the platform throws — the shape of a plugin update that
  /// dropped the method.
  final bool probeThrows;

  bool permitted = true;
  RecordConfig? lastConfig;
  String? lastPath;
  int stops = 0;
  int cancels = 0;

  @override
  Future<bool> hasPermission() async => permitted;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async {
    if (probeThrows) throw StateError('no such method');
    return supported.contains(encoder);
  }

  @override
  Future<void> start(RecordConfig config, {required String path}) async {
    lastConfig = config;
    lastPath = path;
  }

  @override
  Future<String?> stop() async {
    stops++;
    return lastPath;
  }

  @override
  Future<void> cancel() async {
    cancels++;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  test('a platform with AAC records in AAC, into an m4a', () async {
    final backend = _FakeBackend(supported: <AudioEncoder>{AudioEncoder.aacLc});
    final recorder = PluginVoiceRecorder(backend: backend);

    await recorder.start(path: '/tmp/rec/recording.m4a');

    expect(backend.lastConfig!.encoder, AudioEncoder.aacLc);
    expect(backend.lastConfig!.bitRate, 64000,
        reason: 'the bit rate is part of the promise the vault makes about '
            'how big a voice memo is');
    expect(backend.lastPath, endsWith('.m4a'));
  });

  test('a platform without AAC falls back to WAV, and says so in the name',
      () async {
    // Windows needs a *system* AAC encoder; a machine without one cannot
    // encode AAC at all. Failing there with a message about an encoder the
    // user has never heard of would be a dead end.
    final backend = _FakeBackend(supported: <AudioEncoder>{AudioEncoder.wav});
    final recorder = PluginVoiceRecorder(backend: backend);

    await recorder.start(path: '/tmp/rec/recording.m4a');

    expect(backend.lastConfig!.encoder, AudioEncoder.wav);
    expect(backend.lastPath, endsWith('.wav'),
        reason: 'the extension has to match what is actually inside the '
            'file: the attachment writer names the vault file after it, and '
            'the sync engine sends the Content-Type the MIME table gives '
            'for that extension');
  });

  test('a platform that cannot answer the question keeps AAC', () async {
    // Not answering is not the same as saying no. Treating it as a "no"
    // would quietly turn every recording on that platform into a WAV.
    final backend = _FakeBackend(probeThrows: true);
    final recorder = PluginVoiceRecorder(backend: backend);

    await recorder.start(path: '/tmp/rec/recording.m4a');

    expect(backend.lastConfig!.encoder, AudioEncoder.aacLc);
    expect(backend.lastPath, endsWith('.m4a'));
  });

  test('the recording keeps the bit rate promise in either format', () async {
    final backend = _FakeBackend(supported: <AudioEncoder>{AudioEncoder.wav});
    final recorder = PluginVoiceRecorder(backend: backend);

    await recorder.start(path: '/tmp/rec/recording.m4a');

    expect(backend.lastConfig!.sampleRate, 44100);
    expect(backend.lastConfig!.numChannels, 1,
        reason: 'a voice memo is one person talking');
  });

  test('a refused microphone is a refusal, not a crash', () async {
    final backend = _FakeBackend()..permitted = false;
    final recorder = PluginVoiceRecorder(backend: backend);

    expect(await recorder.requestPermission(), isFalse,
        reason: 'the editor turns this into a sentence; a stack trace would '
            'be no help at all');
  });

  test('a platform that cannot answer about permission counts as a refusal',
      () async {
    // Not answering is not the same as saying yes. Reporting "yes" would
    // send the user into a recording that can never start.
    final backend = _ThrowingBackend();
    final recorder = PluginVoiceRecorder(backend: backend);

    expect(await recorder.requestPermission(), isFalse);
  });

  test('a microphone that will not open says so in words', () async {
    final recorder = PluginVoiceRecorder(backend: _FailingStartBackend());

    await expectLater(
      recorder.start(path: '/tmp/rec/recording.m4a'),
      throwsA(isA<RecordingRefused>()),
    );
  });

  test('a recording that fell back to WAV is still found by the workspace',
      () async {
    // The workspace and the recorder have to agree about where the file is:
    // the recorder may write a different name than it was handed, and the
    // workspace is what looks the file up afterwards.
    final backend = _FakeBackend(supported: <AudioEncoder>{AudioEncoder.wav});
    final recorder = PluginVoiceRecorder(backend: backend);
    final workspace = await RecordingWorkspace.create();
    addTearDown(workspace.dispose);

    await recorder.start(path: workspace.filePath);
    // The platform wrote the file it was told to write.
    File(backend.lastPath!).writeAsBytesSync(<int>[0x52, 0x49, 0x46, 0x46]);

    final produced = await workspace.producedFile(preferred: await recorder.stop());

    expect(produced, isNotNull,
        reason: 'a recording that exists but cannot be found is a recording '
            'the user cannot insert');
    expect(produced!.path, endsWith('.wav'));
    expect(produced.path, isNot(endsWith('.m4a')),
        reason: 'the name has to match the bytes; the vault sends the file '
            'with the Content-Type its extension implies');
  });
}

/// A backend whose every question throws — the shape of a platform that
/// cannot answer at all.
class _ThrowingBackend implements RecorderBackend {
  @override
  Future<bool> hasPermission() async => throw StateError('no channel');

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async =>
      throw StateError('no channel');

  @override
  Future<void> start(RecordConfig config, {required String path}) async =>
      throw StateError('no channel');

  @override
  Future<String?> stop() async => throw StateError('no channel');

  @override
  Future<void> cancel() async {}

  @override
  Future<void> dispose() async {}
}

/// A backend whose microphone refuses to open.
class _FailingStartBackend extends _ThrowingBackend {
  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> isEncoderSupported(AudioEncoder encoder) async => true;

  @override
  Future<void> start(RecordConfig config, {required String path}) async =>
      throw StateError('device is busy');
}

