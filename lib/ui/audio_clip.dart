import 'dart:async';

import 'package:flutter/material.dart';

import '../app/clip_player.dart';
import 'theme.dart';

/// One recorded clip, playable in place.
///
/// **Why a widget and not a link.** A voice memo that the note only points at
/// is a voice memo the user has to go and find. The whole point of putting
/// the file in the vault is that the note keeps it; playing it where it is
/// referenced is what makes the reference worth having.
///
/// The player is created through a factory rather than handed in, so the
/// widget can own its lifecycle: a clip that is scrolled out of view must
/// release its player, or a long note leaks one platform player per clip.
class AudioClip extends StatefulWidget {
  const AudioClip({
    super.key,
    required this.path,
    required this.playerFactory,
    this.label = '录音',
  });

  /// Absolute path of the file on disk.
  final String path;

  /// Builds the player. Called once, in [State.initState].
  final ClipPlayer Function() playerFactory;

  /// What the clip is called on screen.
  final String label;

  @override
  State<AudioClip> createState() => _AudioClipState();
}

class _AudioClipState extends State<AudioClip> {
  ClipPlayer? _player;

  StreamSubscription<ClipPlayback>? _playbackSub;
  StreamSubscription<ClipProgress>? _progressSub;

  ClipPlayback _state = ClipPlayback.idle;
  ClipProgress _progress = const ClipProgress.zero();
  String? _error;

  @override
  void initState() {
    super.initState();

    // A player that cannot be built is a clip that cannot be played, and
    // that is a fact about the clip — not a reason to take the whole page
    // down with it. The preview renders a note that happens to contain a
    // recording; a note with one unplayable recording in it is still a note
    // worth reading.
    try {
      _player = widget.playerFactory();
    } on Object catch (e) {
      _error = '这个录音放不出来：$e';
      return;
    }
    final player = _player!;

    _playbackSub = player.playback.listen((s) {
      if (!mounted) return;
      setState(() => _state = s);
    });
    _progressSub = player.progress.listen((p) {
      if (!mounted) return;
      setState(() => _progress = p);
    });
    // The duration is worth knowing before the user presses play, so the
    // clip is opened right away. A file that cannot be opened is reported
    // here rather than at the first press — the failure is about the file,
    // and finding that out later is how a person ends up pressing play
    // twice wondering why nothing happens.
    unawaited(_open());
  }

  Future<void> _open() async {
    final player = _player;
    if (player == null) return;
    try {
      await player.open(widget.path);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '这个录音打不开：$e');
    }
  }

  @override
  void dispose() {
    _playbackSub?.cancel();
    _progressSub?.cancel();
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
    super.dispose();
  }

  bool get _playing => _state == ClipPlayback.playing;

  Future<void> _toggle() async {
    final player = _player;
    if (player == null) return;
    try {
      if (_playing) {
        await player.pause();
      } else {
        // Replaying a finished clip has to start from the beginning: the
        // player is stopped at the end, and "play" on a stopped clip does
        // not rewind it.
        if (_state == ClipPlayback.completed) {
          await player.seek(Duration.zero);
        }
        await player.play();
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '播放失败：$e');
    }
  }

  Future<void> _seekTo(double fraction) async {
    final player = _player;
    final total = _progress.duration;
    if (player == null || total <= Duration.zero) return;
    final target = Duration(
      milliseconds: (total.inMilliseconds * fraction).round(),
    );
    try {
      await player.seek(target);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _error = '定位失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _error;
    if (error != null) {
      return _frame(
        theme,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 18, color: theme.colorScheme.error),
            const SizedBox(width: JotItTokens.s2),
            Flexible(
              child: Text(
                error,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return _frame(
      theme,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: const ValueKey('audio-clip-play'),
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: _playing ? '暂停' : '播放',
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: _toggle,
          ),
          const SizedBox(width: JotItTokens.s1),
          Icon(Icons.mic_none, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: JotItTokens.s1),
          Flexible(
            child: Text(
              widget.label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: JotItTokens.s3),
          SizedBox(
            width: 120,
            child: Slider(
              key: const ValueKey('audio-clip-slider'),
              value: _progress.fraction,
              onChanged: _seekTo,
            ),
          ),
          const SizedBox(width: JotItTokens.s1),
          Text(
            '${_format(_progress.position)} / ${_format(_progress.duration)}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }

  /// A clip sits on the page like a quotation: a hairline edge, no shadow.
  Widget _frame(ThemeData theme, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(JotItTokens.rSm),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(JotItTokens.rSm),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: JotItTokens.s2,
                vertical: JotItTokens.s1,
              ),
              child: child,
            ),
          ),
        ),
      );

  /// `m:ss`, and `h:mm:ss` for anything longer than an hour.
  static String _format(Duration d) {
    final total = d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '$m:${two(s)}';
  }
}
