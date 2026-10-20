import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

/// What a clip is doing right now.
enum ClipPlayback { idle, playing, paused, completed }

/// Where the playhead is, and how long the clip is.
class ClipProgress {
  const ClipProgress({required this.position, required this.duration});

  const ClipProgress.zero()
      : position = Duration.zero,
        duration = Duration.zero;

  final Duration position;
  final Duration duration;

  /// 0..1, or 0 when the duration is not known yet.
  ///
  /// A clip whose length is unknown has no meaningful fraction, and dividing
  /// by zero here would put a NaN into a `Slider`'s value — which Flutter
  /// rejects outright rather than clamping.
  double get fraction {
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final done = position.inMilliseconds.clamp(0, total);
    return done / total;
  }

  @override
  String toString() => 'ClipProgress($position/$duration)';
}

/// JotIt's own player for one recorded clip.
///
/// The same seam as [VoiceRecorder], for the same reason: `audioplayers` is a
/// platform channel, and a widget that cannot be built without one cannot be
/// tested. The interface is also where the "one clip, one player" rule lives,
/// so the widget does not have to manage the plugin's global state.
abstract interface class ClipPlayer {
  /// Emits whenever the clip starts, pauses, or finishes.
  Stream<ClipPlayback> get playback;

  /// Emits as the playhead moves.
  Stream<ClipProgress> get progress;

  /// Load [path] and prepare it for playback. Does not start playing.
  Future<void> open(String path);

  Future<void> play();

  Future<void> pause();

  /// Move the playhead to [to].
  Future<void> seek(Duration to);

  Future<void> dispose();
}

/// A player that does nothing, for a build with no audio backend.
///
/// **Why it exists.** The player plugin keeps a periodic timer alive for as
/// long as a player exists, and a widget test refuses to finish while a
/// timer is pending — so rendering a clip with the real player inside
/// `flutter test` hangs the test for its full timeout instead of failing it.
/// The app never uses this: it is what the default factory hands out when
/// there is no platform behind it.
class SilentClipPlayer implements ClipPlayer {
  @override
  Stream<ClipPlayback> get playback => const Stream<ClipPlayback>.empty();

  @override
  Stream<ClipProgress> get progress => const Stream<ClipProgress>.empty();

  @override
  Future<void> open(String path) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration to) async {}

  @override
  Future<void> dispose() async {}
}

/// The real player, on top of the `audioplayers` plugin.
///
/// The release mode is `stop` rather than the plugin's default `release`:
/// a voice memo that keeps looping after it ends is a small, persistent
/// annoyance, and a clip the user pressed play on is not a music track.
class PluginClipPlayer implements ClipPlayer {
  PluginClipPlayer({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _stateSub = _player.onPlayerStateChanged.listen(_onState);
    _positionSub = _player.onPositionChanged.listen(_onPosition);
    _durationSub = _player.onDurationChanged.listen(_onDuration);
  }

  final AudioPlayer _player;
  late final StreamSubscription<PlayerState> _stateSub;
  late final StreamSubscription<Duration> _positionSub;
  late final StreamSubscription<Duration> _durationSub;

  final _playback = StreamController<ClipPlayback>.broadcast();
  final _progress = StreamController<ClipProgress>.broadcast();

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  Stream<ClipPlayback> get playback => _playback.stream;

  @override
  Stream<ClipProgress> get progress => _progress.stream;

  void _onState(PlayerState state) {
    switch (state) {
      case PlayerState.playing:
        _emit(ClipPlayback.playing);
      case PlayerState.paused:
        _emit(ClipPlayback.paused);
      case PlayerState.completed:
        _emit(ClipPlayback.completed);
      case PlayerState.stopped:
        _emit(ClipPlayback.idle);
      case PlayerState.disposed:
        // The player is gone; there is nothing left to play and nothing to
        // report but "not playing".
        _emit(ClipPlayback.idle);
    }
  }

  void _onPosition(Duration position) {
    _position = position;
    _emitProgress();
  }

  void _onDuration(Duration duration) {
    _duration = duration;
    _emitProgress();
  }

  void _emit(ClipPlayback state) {
    if (_playback.isClosed) return;
    _playback.add(state);
  }

  void _emitProgress() {
    if (_progress.isClosed) return;
    _progress.add(ClipProgress(position: _position, duration: _duration));
  }

  @override
  Future<void> open(String path) async {
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setSourceDeviceFile(path);
  }

  @override
  Future<void> play() async {
    await _player.resume();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> seek(Duration to) async {
    await _player.seek(to);
    _position = to;
    _emitProgress();
  }

  @override
  Future<void> dispose() async {
    await _stateSub.cancel();
    await _positionSub.cancel();
    await _durationSub.cancel();
    await _player.dispose();
    if (!_playback.isClosed) await _playback.close();
    if (!_progress.isClosed) await _progress.close();
  }
}
