import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../core/vault_paths.dart';

/// The result of putting one file into a note.
class AttachmentInsertion {
  const AttachmentInsertion({
    required this.attachmentPath,
    required this.linkTarget,
    required this.markdown,
    required this.size,
  });

  /// Vault-relative, `notes/`-prefixed — the path the scanner will index and
  /// the sync engine will transfer.
  final String attachmentPath;

  /// The text to write between the brackets, normalised relative to the note's
  /// own directory (v3.0 §9.3 rule 1).
  final String linkTarget;

  /// Ready to insert at the cursor: `![[attachments/6f1a.png]]`.
  final String markdown;

  final int size;

  @override
  String toString() =>
      'AttachmentInsertion($attachmentPath as "$markdown", $size bytes)';
}

/// Thrown when a file cannot become an attachment, carrying a reason a person
/// can act on.
///
/// Every case here is something the user did that the app can explain. "Failed
/// to copy file" is not.
class AttachmentRefused implements Exception {
  const AttachmentRefused(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Copies files into the vault as attachments and writes the link that points
/// at them (v3.0 §9.3 rules 1–3, ADR-11).
///
/// **Why this is not a one-liner.** §9.3 exists because v2.0's "reject any
/// `../`" rule broke the moment a note lived in a subfolder: a note at
/// `projects/jotit/design.md` linking to its picture legitimately needs
/// `../../attachments/x.png`. v3.0 replaces the ban with "normalise, then
/// check", so the work here is producing the *normalised* relative link and
/// then validating the resolved path against the vault root — in that order.
/// Validating first and normalising after would reject every attachment in
/// every subfolder, which is precisely the bug v2.0 shipped.
///
/// **ADR-11 shapes the naming.** `{uuid}.{ext}`, never the user's original
/// filename. Two devices that both paste `IMG_0042.png` into the same note
/// must not collide, and — more importantly — an attachment's content is never
/// rewritten in place. "Replacing the image" is a new uuid, a new link, and a
/// delete of the old file, which is exactly what §5.5 says and exactly what
/// makes "attachment content conflict" a state that cannot arise.
class AttachmentWriter {
  AttachmentWriter({
    required this.vaultRoot,
    this.uuid = const Uuid(),
    Uuid? uu,
  }) : _uu = uu ?? uuid;

  final String vaultRoot;

  /// Exposed so a test can pin the generated name.
  final Uuid uuid;
  final Uuid _uu;

  /// The directory [notePath]'s attachments live in.
  String directoryFor(String notePath) =>
      VaultPaths.attachmentsDirForNote(notePath);

  /// The filename a given source would get. Pure, so the naming rule can be
  /// tested without touching a disk.
  String fileNameFor(String sourcePath) {
    final ext = p.extension(sourcePath).toLowerCase();
    return '${_uu.v4()}$ext';
  }

  /// The link text a note at [notePath] should contain for a file at
  /// [attachmentPath] (v3.0 §9.3 rule 1).
  ///
  /// Relative to the note's directory, and forward-slashed: a Windows-authored
  /// `attachments\x.png` is not portable and the note syncs to other devices.
  String linkTargetFor({
    required String notePath,
    required String attachmentPath,
  }) {
    final relative = VaultPaths.relativeLinkFromNote(
      notePath: notePath,
      targetVaultPath: attachmentPath,
    );
    return relative.replaceAll(r'\', '/');
  }

  /// Copies [source] into the vault and returns what to write into [notePath].
  ///
  /// [bytes] may be supplied instead of reading the file, for a source that is
  /// already in memory (a paste, a download) — the bytes written are identical
  /// either way, and going through the same path in both cases is what keeps
  /// "paste an image" and "attach a file" from drifting apart.
  Future<AttachmentInsertion> attach({
    required String notePath,
    required String sourcePath,
    Uint8List? bytes,
  }) async {
    final normalisedNote = VaultPaths.normalizeRelative(notePath);
    if (normalisedNote == null || !VaultPaths.isInsideNotes(normalisedNote)) {
      throw const AttachmentRefused('只能给 notes/ 里的笔记添加附件');
    }

    final dir = directoryFor(normalisedNote);
    final name = fileNameFor(sourcePath);
    final vaultPath = '$dir/$name';

    // §9.3 rule 3, second half: even after normalising, the result must not
    // escape the vault. A `notePath` that survived normalisation can still
    // carry a directory name that walks out, and this is the last gate before
    // a write.
    if (!VaultPaths.isInsideNotes(vaultPath)) {
      throw const AttachmentRefused('附件路径超出了库的范围');
    }

    final payload = bytes ?? await _read(sourcePath);

    // `joinAll` takes a single Iterable. Dropping `vaultRoot` to satisfy the
    // signature does not fail loudly — it silently resolves every path against
    // the process working directory, so every attachment lands in a folder
    // next to the executable instead of in the vault. `NoteFileStore`
    // documents the same trap for the same reason.
    final target = File(p.joinAll([vaultRoot, ...p.split(vaultPath)]));
    await target.parent.create(recursive: true);

    // ADR-11 排他语义，显式检查而不是依赖 writeAsBytes 的默认参数：目标
    // 已存在必须失败并告知用户，而不是静默覆盖一个不可变文件。
    if (await target.exists()) {
      throw const AttachmentRefused('已存在同名附件，拒绝覆盖（附件内容不可变）');
    }

    // tmp + rename 原子写。直写 `target.writeAsBytes` 的话，复制中途崩溃
    // 会留下一个截断的附件——它随后会被索引进索引、被同步推给所有设备，
    // 而路径不可变意味着这个损坏永远无法修正。
    final token = Random.secure().nextInt(1 << 30).toRadixString(36);
    final tmp = File('${target.path}.jotit-tmp.$token');
    try {
      await tmp.writeAsBytes(payload, flush: true);
      await tmp.rename(target.path);
    } on Object {
      // 失败不留下残骸：一个半截附件和截断附件一样糟。
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    }

    final linkTarget = linkTargetFor(
      notePath: normalisedNote,
      attachmentPath: vaultPath,
    );

    return AttachmentInsertion(
      attachmentPath: vaultPath,
      linkTarget: linkTarget,
      markdown: '![[$linkTarget]]',
      size: payload.length,
    );
  }

  /// Inserts [insertion] into [text] at [offset], on its own line.
  ///
  /// Own line, and not glued onto whatever word the cursor happened to be
  /// parked in: a Markdown image link glued to the end of a sentence renders
  /// as an image mid-sentence, and the user then has to know Markdown to fix
  /// it. A blank line before it is the difference between "inserted a
  /// picture" and "inserted something and now my paragraph is wrong".
  static String spliceInto(
    String text,
    int offset,
    AttachmentInsertion insertion,
  ) {
    final at = offset.clamp(0, text.length);
    var before = text.substring(0, at);
    final after = text.substring(at);

    if (before.isNotEmpty && !before.endsWith('\n')) before += '\n';
    if (before.isNotEmpty) before += '\n';
    return '$before${insertion.markdown}\n\n$after';
  }

  Future<Uint8List> _read(String sourcePath) async {
    final file = File(sourcePath);
    if (!await file.exists()) {
      throw const AttachmentRefused('找不到这个文件');
    }
    final data = await file.readAsBytes();
    if (data.isEmpty) {
      throw const AttachmentRefused('这个文件是空的');
    }
    return data;
  }
}
