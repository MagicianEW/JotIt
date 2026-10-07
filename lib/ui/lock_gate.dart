import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/app_lock.dart';
import '../app/providers.dart';

/// The PIN gate (§8.3).
///
/// A lock that is not in front of the vault is not a lock. This screen owns
/// three things the rest of the app must not: the unlock decision, the countdown
/// while a lockout is armed, and the rule that a failed attempt never says
/// anything except "not now".
///
/// No PIN means no gate. Forcing one on a first launch would be the app
/// demanding a secret before it has shown the user anything, and a gate people
/// were forced through is a gate they turn off. Setting one is a choice, made
/// in Settings.
///
/// The PIN is the only way in. Biometric, where a platform has it, is a
/// shortcut to the same state — never a second factor, never a requirement,
/// because §8.3 says a device with a broken sensor must still be able to open
/// the app.
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate> {
  final _pin = TextEditingController();

  bool _checking = true;
  bool _locked = false;
  String? _error;

  Timer? _ticker;
  Duration _remaining = Duration.zero;

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final session = await ref.read(vaultProvider.future);
    final configured = await session.lock.isConfigured();
    // §8.3: the same read that decides whether to show this gate is what tells
    // Android to protect the screen. Doing it here rather than in the settings
    // screen means the recents thumbnail is already blanked on the very first
    // launch after a restart, which is exactly when the flag is otherwise
    // lost — the process that set it may not be running any more.
    await session.syncScreenSecurity();
    if (!mounted) return;
    setState(() {
      _locked = configured;
      _checking = false;
    });
  }

  /// Re-arms the countdown from the persisted deadline, so a lockout started
  /// before the process died is still honoured after the restart — which is
  /// the entire point of storing it.
  void _startCountdown(DateTime until) {
    _ticker?.cancel();
    _tick(until);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick(until));
  }

  void _tick(DateTime until) {
    final left = until.difference(DateTime.now());
    if (left.isNegative) {
      _ticker?.cancel();
      if (mounted) setState(() => _remaining = Duration.zero);
      return;
    }
    if (mounted) setState(() => _remaining = left);
  }

  Future<void> _submit() async {
    final session = await ref.read(vaultProvider.future);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    setState(() => _error = null);

    final result = await session.lock.unlock(_pin.text, nowMs: nowMs);
    if (!mounted) return;

    switch (result.outcome) {
      case UnlockOutcome.ok:
      case UnlockOutcome.notConfigured:
        _pin.clear();
        _ticker?.cancel();
        setState(() => _locked = false);
      case UnlockOutcome.wrongPin:
        _pin.clear();
        final left = result.retryAfter;
        if (left != null) {
          _startCountdown(
              DateTime.fromMillisecondsSinceEpoch(nowMs + left.inMilliseconds));
        }
        setState(() => _error = left == null
            ? 'PIN 不对'
            : 'PIN 不对，${left.inSeconds} 秒后可再试');
      case UnlockOutcome.lockedOut:
        _pin.clear();
        if (result.lockedUntil > 0) {
          _startCountdown(
              DateTime.fromMillisecondsSinceEpoch(result.lockedUntil));
        }
        setState(() {
          _error = '已锁定，请 ${result.retryAfter?.inSeconds ?? 0} 秒后再试';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!_locked) return widget.child;

    final cooling = _remaining > Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    'JotIt 已锁定',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    maxLength: 32,
                    enabled: !cooling,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'PIN',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: cooling ? null : _submit,
                    child: Text(cooling ? '请稍候 ${_remaining.inSeconds}s' : '解锁'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}