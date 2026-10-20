import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jotit/app/camera_session.dart';
import 'package:jotit/ui/camera_capture_page.dart';

/// The desktop camera screen.
///
/// The camera is a platform channel, so the screen is driven through
/// [CameraSession] — the same seam the app uses. What is worth testing here
/// is not the preview (that is the plugin's job) but the three things the
/// screen is responsible for: what it says when the camera will not open,
/// what it hands back when the shutter is pressed, and whether it lets go of
/// the camera when it goes away.
class _FakeSession implements CameraSession {
  int shots = 0;
  int disposals = 0;

  /// Thrown instead of taking a picture, to stand in for a capture that
  /// fails halfway.
  Object? failure;

  @override
  Widget buildPreview() => const ColoredBox(color: Color(0xFF222222));

  @override
  Future<String> takePicture() async {
    shots++;
    final f = failure;
    if (f != null) throw f;
    return '/tmp/shot.jpg';
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// Opens the camera screen from a button, so the test can see what the
/// screen hands back.
Future<void> pumpHost(
  WidgetTester tester, {
  required Future<CameraSession> Function() factory,
  String? result,
  void Function(String? value)? onResult,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              final value = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => CameraCapturePage(sessionFactory: factory),
                ),
              );
              onResult?.call(value);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the shutter hands the picture back to the caller',
      (tester) async {
    final session = _FakeSession();
    String? result;
    await pumpHost(
      tester,
      factory: () async => session,
      onResult: (value) => result = value,
    );

    expect(find.byKey(const ValueKey('camera-capture-shutter')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('camera-capture-shutter')));
    await tester.pumpAndSettle();

    expect(session.shots, 1);
    expect(result, '/tmp/shot.jpg',
        reason: 'the path is what the caller needs in order to copy the file '
            'into the vault');
  });

  testWidgets('backing out hands back nothing at all', (tester) async {
    final session = _FakeSession();
    String? result = 'untouched';
    await pumpHost(
      tester,
      factory: () async => session,
      onResult: (value) => result = value,
    );

    await tester.tap(find.byKey(const ValueKey('camera-capture-close')));
    await tester.pumpAndSettle();

    expect(result, isNull,
        reason: 'null is what says "the user did not want a picture" — the '
            'caller must not read it as an empty file');
    expect(session.shots, 0, reason: 'nothing may be taken');
  });

  testWidgets('a camera that will not open says why', (tester) async {
    await pumpHost(
      tester,
      factory: () async => throw const CameraUnavailable(
          '这台机器上没有找到可用的相机'),
    );

    expect(find.textContaining('没有找到可用的相机'), findsOneWidget,
        reason: 'a screen that shows nothing but a spinner is a broken app, '
            'not a missing camera');
    expect(find.byKey(const ValueKey('camera-capture-dismiss')), findsOneWidget,
        reason: 'the user has to be able to get out of it');
  });

  testWidgets('a failed capture keeps the screen open', (tester) async {
    final session = _FakeSession()..failure = StateError('镜头被占用');
    String? result = 'untouched';
    await pumpHost(
      tester,
      factory: () async => session,
      onResult: (value) => result = value,
    );

    await tester.tap(find.byKey(const ValueKey('camera-capture-shutter')));
    await tester.pumpAndSettle();

    expect(result, 'untouched',
        reason: 'a failed capture is not a cancelled one — the user is still '
            'standing in front of the camera');
    expect(find.byKey(const ValueKey('camera-capture-shutter')), findsOneWidget,
        reason: 'the user has to be able to try again');
  });

  testWidgets('the camera is let go of when the screen goes away',
      (tester) async {
    final session = _FakeSession();
    await pumpHost(tester, factory: () async => session);

    // Take the whole app away, the way closing the window would. The key
    // matters: `pumpWidget` reuses the root element when the widget type
    // and key match, so without a different key the camera screen is never
    // unmounted and the test would pass for the wrong reason.
    await tester.pumpWidget(
      const MaterialApp(key: ValueKey('replaced'), home: SizedBox()),
    );
    await tester.pumpAndSettle();

    expect(session.disposals, 1,
        reason: 'a camera that is never released stays busy, and the next '
            'capture gets a camera that is already taken');
  });
}
