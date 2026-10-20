import 'package:flutter/services.dart';

/// Android's `FLAG_SECURE`, as required by v3.0 §8.3: *"Android 设置
/// FLAG_SECURE 禁用截图与最近任务预览"*.
///
/// **Why it is bound to the PIN and not switched on unconditionally.** The
/// flag does two things: it blacks out screenshots, and it leaves the recents
/// thumbnail blank. Both are answers to one question — *can somebody see these
/// notes without entering the PIN?* — and until the user has set a PIN the
/// answer is yes, on purpose, the same way an unlocked phone shows its
/// notifications. Turning it on for a user who never asked for a lock would
/// hand them a note app whose screenshots silently produce a black rectangle,
/// with no setting anywhere to turn it back off. That is the same class of
/// silent breakage this project has been spending the last several commits
/// removing.
///
/// So the rule is: a configured PIN means a protected screen, and removing the
/// PIN gives screenshots back. Nothing else moves.
///
/// **The Dart side is the source of truth; the native side caches it.** This
/// matters because the recents screenshot is taken *after* the process has
/// often already been killed — by the time Dart could ask, the flag would have
/// been read from an intent, not from us. `MainActivity` therefore persists
/// the last value the Dart side pushed into `SharedPreferences` and re-applies
/// it in `onCreate` and `onResume`, so the very first frame — the launch
/// screen, before Flutter has drawn anything — is already protected.
class ScreenSecurity {
  ScreenSecurity({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const String channelName = 'com.jotit/screen_security';

  static const String _method = 'setFlagSecure';

  final MethodChannel _channel;

  /// Whether [applyForLock] has already pushed the current lock state.
  ///
  /// Native reads this back on every `onResume`, so a single push at startup
  /// and one per settings change is genuinely enough; this exists to keep the
  /// startup path and the settings path from drifting apart when one of them
  /// is called twice.
  bool? _applied;

  /// Protects the screen when [lockConfigured] is true, and unprotects it
  /// otherwise.
  ///
  /// Never throws. A gate in front of a user's own notes must not be the thing
  /// that stops them reading them, and the same argument the vault-location
  /// gate makes applies here: if the platform will not take the flag, the app
  /// opens anyway. [onUnavailable] exists so the caller can still report it.
  Future<void> applyForLock({
    required bool lockConfigured,
    void Function(Object error)? onUnavailable,
  }) async {
    if (_applied == lockConfigured) return;
    try {
      await _channel.invokeMethod<void>(_method, <String, Object?>{
        'enabled': lockConfigured,
      });
      // Only remembered once the platform has accepted it. Setting the flag
      // before the call would make a failure permanent: the next call with
      // the same value would return early on the `_applied` check and never
      // try again, so a PIN that was set while the platform was refusing the
      // call would leave the screen unprotected forever, with no way to
      // recover short of removing the PIN.
      _applied = lockConfigured;
    } on MissingPluginException {
      // Windows, macOS, and every widget test. The flag has no meaning there;
      // §8.3 only asks Android for it.
      //
      // The value is *not* remembered: the plugin may be registered later
      // (a hot restart, a test that installs the mock after the first call),
      // and remembering "already applied" for a platform that never applied
      // anything would be a lie the next call would act on.
    } on PlatformException catch (e) {
      // Same reason: the flag was not applied, so nothing may be remembered
      // about it. The next call — from the settings page, from the lock
      // gate, from the next app start — tries again.
      _applied = null;
      onUnavailable?.call(e);
    }
  }
}
