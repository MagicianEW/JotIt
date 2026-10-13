# JotIt

本地优先的 Markdown 笔记应用。文件是唯一真相，数据库只是可丢弃的索引。

> Local-first Markdown notes. Files are the source of truth; the database is a disposable index.

## 功能

- **三态编辑**：渲染预览 / 富文本所见即所得（super_editor）/ Markdown 源码，一键切换
- **富文本工具栏**：加粗、斜体、删除线、行内代码、标题循环、列表、引用——为不熟悉 Markdown 的人准备
- **WebDAV 双向同步**：对接任意 WebDAV 服务（群晖、Alist 等），冲突自动处理，大附件流式上传
- **附件**：图片插入入库、随笔记移动、引用即同步
- **双链与嵌入**：`[[笔记]]` 跳转、`![[图片]]` 渲染（预览态）
- **滚动备份**：富文本保存自动把上一版存入本地备份，单份覆盖不堆积
- **全文搜索**：SQLite FTS 索引，随笔记变更即时更新

## 隐私

- 零遥测、零数据收集；凭据加密存储在本机
- 笔记以纯 Markdown + YAML front matter 存储，随时可用任何编辑器打开
- 同步凭据只在本机，不经过任何第三方

## 下载

前往 [Releases](https://github.com/MagicianEW/JotIt/releases)：

| 平台 | 产物 |
|---|---|
| Windows | `jotit.exe`（debug 版，含运行时目录） |
| Android | `app-debug.apk` / `app-release.apk`（未签名 release） |
| macOS | 计划中（见下方路线） |

## 从源码构建

```bash
flutter pub get
flutter test              # 全量测试
flutter run -d windows    # 或 macos / android
flutter build apk --release
```

- Flutter stable 3.x；Windows 需要 VS2022 桌面工作负载，Android 需要 JDK 17 + Android SDK
- 桌面端 SQLite 走 `sqflite_common_ffi`，Android 走原生 `sqflite`，无需额外配置

## 路线

- ✅ Windows 版（当前主开发平台，687 项测试全绿）
- 🔜 macOS 版（`macos/` 骨架已就绪，迁移进行中）
- 🔜 Android 版完善（`android/` 骨架已就绪，移动端 UI 适配进行中）
- 🔜 富文本接入 `[[双链]]` 与链接按钮

## 架构一瞥

```
lib/
  app/       # 应用装配：vault 会话、providers、凭据加密
  data/      # WebDAV 客户端、同步引擎、SQLite、文件存储
  domain/    # 实体与编解码：Markdown 解析、front matter、富文本编解码
  ui/        # 编辑器三态、预览渲染、设置
```

笔记身份：front matter 中的 UUID（ADR-2）——文件即身份，重命名不丢同步关系。
