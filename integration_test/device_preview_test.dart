import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jotit/app/providers.dart';
import 'package:jotit/app/vault_session.dart';
import 'package:jotit/core/vault_paths.dart';
import 'package:jotit/domain/vault/attachment_writer.dart';
import 'package:jotit/ui/audio_clip.dart';
import 'package:jotit/ui/editor_page.dart';
import 'package:path/path.dart' as p;

/// 从库里回到页面：附件存进去，还得渲染得出来。
///
/// 前面两个测试分别证明了「拍照」和「选图」能拿到文件，这一个问的是另一半：
/// 文件进了库之后，它在页面上还是不是一张图、一段录音。
///
/// 这一段值得单独测，因为它要过的东西比文件搬运多得多——路径要能从笔记
/// 相对解析出来，图片要真的解码得开，录音要认得出是录音而不是图片，
/// 而索引还得把这两个文件记成附件而不是笔记。哪一环错了，用户看到的
/// 都是同一句「无法显示的图片」。
class _FixedNote extends OpenNote {
  _FixedNote(this.path);

  final String path;

  @override
  String? build() => path;
}

/// 一张真的 JPEG。1x1 像素，但字节是真的 JPEG——解码器要是不认这个格式，
/// 预览里就会出现那个「无法显示的图片」的占位符。
const String _tinyJpegBase64 =
    '/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAA'
    'GgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAA8KADAAQAAAABAAAA8AAAAAD/7QA4'
    'UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs'
    '+EJ+/8AAEQgA8ADwAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYH'
    'CAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNC'
    'scEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm'
    'Z2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TF'
    'xsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEA'
    'AAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEH'
    'YXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJ'
    'SlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ip'
    'qrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMA'
    'AgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4O'
    'Dg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQEBAQEBAQEBAQEBAQ'
    'EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAD//aAAwDAQACEQMRAD8A'
    '/EZIqtJFVlIatJDX94zrHzGGxBWSKrSRVZSGrSQ1yTrH0WGxBWSKraRVZSH2q0kNcc6x'
    '9HhcQVkiq0kVWUh9qtJDXJOsfRYXEFZIqtJFVlIatpDXHOsfRYXEFVIqtpFVlIatJDXJ'
    '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'
    'SQmraRVaSKuOdY+iwtc//9Hlkhq0kNWkiq0kVehOsf5d4bEFVIatJDVpIqtJFXHOsfQ4'
    'XEFZIatJDVpIqtJFXHOufR4XEFVITVpITVpIqtJFXJUrn0WFxBVSE1aSGrSRVbSKuOdY'
    '+iwuIKiQ1bSGrSRVaSKuSpWPosLiCqkNWkhq0kVW0irjqVz6LC4gqJDVtIaspFVtIq5J'
    '1j6LC4gqpDVpIatJFVtIq46lY+iwuIKiQ1bSE1ZSKraRVyTrn0eFxBVSGrSQmrSRVaSK'
    'uOdY+iwuIKqQ1aSGrSRVbSKuOpWPosLiCqkNWkhq0kVWkirknWPosNiCqkNWkhq0kVWk'
    'irjnXPosLiCskNWUhq2kVWkirknXPosNiD//0kSGrSQ1aSKrSRVhOsf5PYbEFVIatJDV'
    'pIqtJFXHOsfRYbEFZIatJDVpIqtJFXHOsfRYXEFVIatJDVpIqtJFXJOsfRYXEFVIatpD'
    'VlIqtpFXHOsfRYXEFVIatJDVpIqtJFXJUrn0WFxBVSGraQ1ZSKraRVxzrH0eFxBUSGra'
    'Q1ZSKraRVyTrH0WFxBVSGraQ1ZSKrSRVx1K59FhcQVUhq2kNWUiq2kVck6x9FhcQVUhq'
    '0kNWkiq0kVcc6x9FhcQVUhq2kNWUiq0kVck6x9FhcQVkhq0kNWkiq0kVcc6x9FhsQVUh'
    'q0kNWkiq0kVck6x9FhsQVkhq0kNWkiq0kVck6x9HhsQf/9Pp0hq0kNWkiq0kVeDOuf5A'
    '4WuVkhqykNWkiq0kVcc6x9FhsSVkhq0kNWkiq0kVclSsfRYXEFVIRVpIatJFVpIq46lY'
    '+iwuJKyQirSQirKRVbSKuSdc+iwuIKqQ1aSGrSRVaSKuSpWPo8LiSqkNW0hqykVW0irj'
    'nWPosLiCqkNWkhqykVW0irkqVj6LC4gqpDVtIRVlIqtJFXHUrH0WFxJWSEVaSGrKRVbS'
    'KuOdY+iwuIKqQirSQ1aSKrSRVyVK59FhcSVkhq0kNWUiq0kVck659FhcQVkhq0kNWkiq'
    '0kVcc6x9HhcSVkhqykNWkiq0kVcc6x9Dhq5WSGrSQ1aSKrKRVyTrH0eGxJ//1PUEh9qs'
    'pCKtJFVpIq+KnWP8ZcNXKyQirSQirKRVaSKuSdY+iw2IKyQirSQj0q0kVWkirkqVj6LC'
    '1yqkIq2kI9KspFVpIq451j6LC4grJCPSrSQirKRVbSKuOdY+iwuIKqQ1bSGrKRVaSKuS'
    'pWPosLiCskIq0kIqykVWkirjnWPo8LiCskIq2kIqwkVW0irkqVj6LC4gqpCKtpCKspFV'
    'pIq451j6LC4grJCKtJDVlIqtpFXJOsfRYXEFVIR6VbSEVZSKrSRVx1Kx9FhcQVkhFWkh'
    'qykVWkirknWPosLXKyQ1aSGrSRVaSKuOdY+iw2IKyQirSQirKRVaSKuSdY+iw1crJCKt'
    'JCKtJFVlIq451j6PDYg//9X3hIaspDVpIatJDX5pOsf4kYbEFZIatJD7VZSGrSQ+1cc6'
    'x9Fha5WSGrSQ+1Wkhq0kPtXJOsfRYXEFZIatJD7VZSH2q0kJrjnWPosLXKyQ1aSGrKQn'
    '0q2kNclSsfR4XEFVIatpDVlIatJDXHUrH0OFrlZIatJCKspDVtIa5J1j6PC4gqpD7VbS'
    'GrCQ1bSH2rjqVj6LC4grJD7VaSH2qykNWkhPpXJOsfRYWuVkhq2kPtVhIatpCfSuOdY+'
    'iwuIKqQ1bSGrKQ1aSGuOdY+iwtcrJDVpIaspDVpIa5J1j6LC4grJDVpIatJDVpIa451j'
    '6LDVyskIq0kNWUhq0kPtXLOsfR4XEFZIfarSQ1aSGrSQ+1cU6x9Fhq5//9k=';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a photo and a recording come back out as an image and a clip',
      (tester) async {
    final root = await Directory.systemTemp.createTemp('jotit_device_preview_');
    final vault = await VaultSession.open(root.path);
    addTearDown(() async {
      await vault.close();
      if (root.existsSync()) await root.delete(recursive: true);
    });
    await vault.writeRaw(
      'notes/a.md',
      utf8.encode('---\nuid: u-a\ntitle: 真机回归\n---\n\n第一段。\n\n第二段。\n'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultProvider.overrideWith((ref) async => vault),
          openNoteProvider.overrideWith(() => _FixedNote('notes/a.md')),
        ],
        child: const MaterialApp(home: EditorPage()),
      ),
    );
    await _settle(tester);

    // The source view, because that is where the text can be read and
    // written.
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await _settle(tester);
    await tester.tap(find.text('源码'));
    await _settle(tester);

    // ---- 一段真的录音 ---------------------------------------------------
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await _settle(tester);
    await Future<void>.delayed(const Duration(seconds: 4));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('editor-record')));
    await _settle(tester, rounds: 40);

    final TextEditingController controller = tester
        .widget<TextField>(find.byKey(const ValueKey('editor-body')))
        .controller!;
    final afterRecording = controller.text;
    expect(afterRecording, contains('![[attachments/'),
        reason: '录完音，链接就该在正文里了');
    expect(afterRecording, contains('.m4a]]'));

    // ---- 一张真的照片，走的是编辑器用的那条路 --------------------------
    // 选图和拍照的入口在别的测试里已经验过了；这里要问的是「进了库之后
    // 还认不认得出来」，所以直接调编辑器用的那两个函数。
    final staged = File(p.join(root.path, 'staged.jpg'))
      ..writeAsBytesSync(base64Decode(_tinyJpegBase64));
    final insertion = await vault.insertAttachment(
      notePath: 'notes/a.md',
      sourcePath: staged.path,
    );
    expect(insertion.size, greaterThan(0));
    expect(insertion.markdown, startsWith('![[attachments/'));

    final spliced =
        AttachmentWriter.spliceInto(afterRecording, afterRecording.length, insertion);
    controller.value = TextEditingValue(
      text: spliced,
      selection: TextSelection.collapsed(offset: spliced.length),
    );
    await _settle(tester, rounds: 20);

    // ---- 保存：链接要落到磁盘上，索引才认得出这两个附件 ------------------
    // 编辑器没有自动保存——它只把笔记标成「脏」，等用户按保存。而附件行
    // 是扫描器写进去的，条件是「这篇笔记引用了它」，所以链接没落盘之前，
    // 同步引擎眼里这两个文件还不存在。
    await tester.state<EditorPageState>(find.byType(EditorPage)).saveForTesting();
    await _settle(tester, rounds: 40);

    // ---- 索引：两个都是附件，不是笔记 -----------------------------------
    expect(VaultPaths.isAttachmentPath(insertion.attachmentPath), isTrue,
        reason: '同步引擎靠「路径里有没有 attachments 这一段」来认附件');
    final rows = await vault.db.query('attachments', columns: <String>['path']);
    final indexed = rows.map((Map<String, Object?> r) => r['path'] as String);
    expect(indexed, contains(insertion.attachmentPath));
    expect(indexed.any((String p) => p.endsWith('.m4a')), isTrue,
        reason: '录音也得在附件表里，否则同步的时候它不会被带走');
    expect(indexed.any((String p) => p.endsWith('.jpg')), isTrue);

    // 笔记本身不能被当成附件——那是反过来的错误。
    expect(indexed.any((String p) => p.endsWith('.md')), isFalse);

    // ---- 预览里该出现的是图和播放器，不是占位符 -------------------------
    await tester.tap(find.byKey(const ValueKey('editor-view-menu')));
    await _settle(tester);
    await tester.tap(find.text('预览'));
    await _settle(tester, rounds: 40);

    expect(find.byIcon(Icons.broken_image_outlined), findsNothing,
        reason: '照片解码失败的话，预览里会出现那个碎图的占位符');
    expect(find.text('无法显示的图片'), findsNothing);

    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    final fileImages = images
        .map((Image i) => i.image)
        .whereType<FileImage>()
        .toList();
    expect(fileImages, hasLength(1),
        reason: '预览里该有一张从库里读出来的照片');
    final photoPath = fileImages.single.file.path;
    expect(File(photoPath).existsSync(), isTrue,
        reason: '图片得是真的在磁盘上');
    expect(File(photoPath).lengthSync(), greaterThan(0));

    expect(find.byType(AudioClip), findsOneWidget,
        reason: '录音在预览里是一个播放器，不是一张图片');

    // ---- 落盘：两个链接都得在 -------------------------------------------
    final onDisk = await File(p.join(root.path, 'notes', 'a.md')).readAsString();
    expect(onDisk, contains('.m4a]]'));
    expect(onDisk, contains('.jpg]]'));
    expect(onDisk, contains('第一段'));
    expect(onDisk, contains('第二段'),
        reason: '插入附件不该把正文吃掉');

    // ---- 取证：把真机上这一页留在屏幕上，交给主机去拍 -------------------
    // 不在测试里调 takeScreenshot：Android 上那套要把 Flutter 的 surface
    // 换成 ImageView 再等一帧，在 Impeller/Vulkan 下这一帧永远不来，测试
    // 就死在那儿了。主机直接用 adb 截屏截到的是同一个画面，还带系统 UI。
    // ignore: avoid_print
    print('READY FOR SCREENSHOT');
    await Future<void>.delayed(const Duration(seconds: 30));
  });
}

/// Pumps for a while without `pumpAndSettle`.
///
/// The status line ticks once a second while a recording is running, so
/// there is always a frame coming: `pumpAndSettle` would wait for a quiet
/// moment that never arrives.
Future<void> _settle(WidgetTester tester, {int rounds = 25}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
