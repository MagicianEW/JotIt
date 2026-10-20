import 'package:flutter/material.dart';

import '../domain/vault/mention_index.dart';
import 'theme.dart';

/// 「提到本篇的笔记」——反向关联的面板。
///
/// 正面是「我在这篇里点了另一个词」，反面是「别的笔记点了这篇的名」。
/// 两个方向都要有：一个只认得自己写下的双链，另一个只认得自动提及，
/// 用户都得能看见**整张库**是怎么互相关联的。
///
/// 面板本身不查数据：它拿到的 [backlinks] 已经算好了。查询慢（全库扫描），
/// 那是数据层的事，不该让一个弹层来承担。
class RelatedNotesPanel extends StatelessWidget {
  const RelatedNotesPanel({
    super.key,
    required this.backlinks,
    required this.onOpen,
  });

  /// 谁提到了这一篇。
  final List<Backlink> backlinks;

  /// 点一条就跳到那篇笔记。
  final void Function(String sourcePath) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (backlinks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: JotItTokens.s5,
          vertical: JotItTokens.s6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.hub_outlined,
              size: 28,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: JotItTokens.s3),
            Text(
              '还没有笔记提到这一篇',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(
        JotItTokens.s5,
        JotItTokens.s3,
        JotItTokens.s5,
        JotItTokens.s5,
      ),
      itemCount: backlinks.length,
      itemBuilder: (context, i) => _row(context, backlinks[i]),
    );
  }

  Widget _row(BuildContext context, Backlink link) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('related-note-${link.sourcePath}'),
      onTap: () => onOpen(link.sourcePath),
      borderRadius: BorderRadius.circular(JotItTokens.rSm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: JotItTokens.s2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 15,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: JotItTokens.s2),
                Expanded(
                  child: Text(
                    link.sourceTitle,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: JotItTokens.s1),
            // 摘出来的那一行，命中词标出来：用户要能一眼看出「它是在哪儿
            // 提到我的」，而不是只看到一个标题。
            Padding(
              padding: const EdgeInsets.only(left: 23),
              child: _excerpt(context, link),
            ),
          ],
        ),
      ),
    );
  }

  Widget _excerpt(BuildContext context, Backlink link) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.5,
    );
    if (base == null) return const SizedBox.shrink();

    final start = link.excerptKeywordStart;
    final end = start + link.keyword.length;
    final text = link.excerpt;
    // 摘录被改过（截断过）时，命中词可能已经不在摘录里了。那时整行照常
    // 显示，不标高亮——标一个错的位置比不标更糟。
    if (start < 0 || end > text.length || start > end) {
      return Text(text, style: base, maxLines: 2, overflow: TextOverflow.ellipsis);
    }

    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, start)),
          TextSpan(
            text: text.substring(start, end),
            style: base.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          TextSpan(text: text.substring(end)),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 打开「提到本篇的笔记」面板。
///
/// 弹层而不是新页面：这是看一眼的列表，不是要停留的地方。返回键和
/// 桌面上的 Esc 都自然地把它关掉。
Future<void> showRelatedNotesPanel(
  BuildContext context, {
  required List<Backlink> backlinks,
  required void Function(String sourcePath) onOpen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => RelatedNotesPanel(
      backlinks: backlinks,
      onOpen: (path) {
        Navigator.of(context).pop();
        onOpen(path);
      },
    ),
  );
}
