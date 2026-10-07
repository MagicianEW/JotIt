import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Driver for `flutter drive`.
///
/// Writes the screenshots `IntegrationTestWidgetsFlutterBinding` sends back
/// next to the build output, so a failing run leaves behind what the screen
/// actually looked like rather than only what it said.
Future<void> main() async {
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final file = File('build/screenshots/$name.png')
        ..parent.createSync(recursive: true);
      file.writeAsBytesSync(bytes);
      stdout.writeln('screenshot: ${file.path}');
      return true;
    },
  );
}
