# Folivyn

Folivyn 是一款轻量、原生的 macOS 文本与代码编辑器。打开文件，完成修改，继续手头的工作。

[English](README.md) · **简体中文**

Folivyn 是一个由个人开发、持续完善中的项目。欢迎通过 [GitHub Issues](https://github.com/Amoo1121/Folivyn/issues) 反馈问题、提出建议，帮助它变得更好用。

## 功能

- **多文件标签。** 同时打开多个文件，每个标签独立保留撤销记录、选区和滚动位置。
- **从磁盘重新加载。** 读取其他工具修改后的内容；有未保存的编辑时，可以取消、放弃修改，或另存副本后再重载。
- **本地语法着色。** 为 Python、Java、JavaScript、TypeScript、JSON、JSONC 和 Shell 提供基础着色；其他文本格式照常打开。
- **谨慎处理文件。** 保留支持的编码、BOM 与换行。保存前检查外部变更，遇到冲突时提示处理。
- **完全离线。** 编辑与着色无需账号、网络或下载语言包。没有遥测或在线服务。
- **原生、小巧。** 使用 Swift、AppKit 和 macOS 系统框架，无第三方包依赖。

## 构建与运行

需要运行 macOS 14 或更高版本的 Apple Silicon Mac，以及包含 Swift 5.9 或更高版本的 Xcode。macOS 14 实机兼容性验证尚待完成。

```sh
git clone https://github.com/Amoo1121/Folivyn.git
cd Folivyn
./scripts/build-app.sh
open "build/Folivyn.app"
```

脚本构建 arm64 Release 应用并进行本地签名。存在 `/Applications/Xcode.app` 时会自动使用；也可通过 `DEVELOPER_DIR` 指定其他 Xcode 安装位置。本地构建没有经过 Apple 公证。

## 使用

| 操作 | 快捷键 |
| --- | --- |
| 新建文件 | `⌘N` |
| 打开文件 | `⌘O` |
| 保存 | `⌘S` |
| 另存为 | `⇧⌘S` |
| 从磁盘重新加载 | `⌘R` |
| 关闭标签 | `⌘W` |
| 上一个 / 下一个标签 | `⇧⌘[` / `⇧⌘]` |

标签名称旁的圆点表示有未保存的修改。状态栏显示编码、语言、路径及检测到的外部变更。应用重新激活及保存前会检查磁盘文件，重新加载由你手动执行。

### 界面语言

默认语言为英语，内置简体中文。界面跟随 macOS 语言偏好，不支持的语言回退为英语。全部翻译随应用提供。

### 支持的文件

- 最大 **10 MiB** 的文本文件，支持 UTF-8（含或不含 BOM）以及带 BOM 的 UTF-16 LE/BE。
- 不超过 **200 KiB** 且不超过 **20,000 行** 的文本提供基础着色；更大的文档仍可按纯文本编辑。
- CSV 和 JSON 当前按文本编辑；专用 CSV 表格与 JSON 树视图列入后续计划。

不支持或无效的编码会被拒绝，不会用替换字符强行解码。符号链接保存到其目标；存在多个硬链接的文件需要另存。保存前会检查外部修改，但其他进程同时写入仍可能在最终检查与替换之间产生竞态。

## 开发

运行文件处理、编辑会话与本地化测试：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
```

代码分为 `EditorApp`（AppKit 界面与着色）和 `EditorCore`（文件访问与编码）。界面字符串位于各 target 的 `Resources/en.lproj` 与 `Resources/zh-Hans.lproj` 目录。

## 后续计划

CSV 表格、JSON 树、Finder Quick Look、查找替换、行号及草稿恢复均在计划中，当前应用尚未包含这些功能。

## 参与贡献

欢迎提交问题、聚焦的 Pull Request 和翻译改进。报告问题时请附上 macOS 版本与复现步骤；文件处理问题请提供不含敏感信息的小型样例，并说明预期编码与换行格式。
