# Folivyn：命名前的 P0 验证记录

本文保留加入国际化及确定 Folivyn 品牌之前的初始测试结果。改名后的国际化构建已重新验证，22 项测试及当前 292 KiB 的磁盘占用见[本地化验证记录](localization-validation.md)。本文下方的测试数量、名称和体积仅代表初始构建。

日期：2026-10-26。测试时项目使用临时名称 `macos-file-editor`；正式品牌现已确定为 **Folivyn**，仓库为 [Amoo1121/Folivyn](https://github.com/Amoo1121/Folivyn)。下文保留测试当时的应用、可执行文件和测试 bundle 名称，以便追溯；当前构建与测试命令见 [README](../README.md) 和[本地化验证记录](localization-validation.md)。

原型已实现并编译，通过文件核心与 AppKit 会话自动测试。本轮测试环境未提供可交互桌面，因此没有完成真实窗口交互验收；自动测试通过不能替代界面、输入法或性能验证。

## 构建与产物

| 项目 | 本轮结果 |
| --- | --- |
| 开发环境 | Apple M4、16 GiB、macOS 26.5.1；Xcode 26.6、Apple Swift 6.3.3 |
| 实现 | Swift + AppKit，手工窗口/`EditorSession`，`NSTextView(usingTextLayoutManager: true)`；未采用 `NSDocument` |
| 包依赖 | `Package.swift` 的 `dependencies` 为空；无第三方包下载或网络服务 |
| 目标平台 | arm64，部署目标 macOS 14+；最低系统与 Intel 尚未验证 |
| 构建入口 | `./scripts/build-app.sh`，生成 `build/File Editor.app` |
| 签名 | ad hoc 本地签名；`codesign --verify --deep --strict --verbose=2` 通过；无 Developer ID、无 Apple 公证 |
| 应用体积 | 3 个文件总逻辑大小 242,093 bytes（236.42 KiB）；`du -sh` 分配空间为 244 KiB，低于 P0 的 15 MiB 预算 |
| 可执行文件 | `FileEditor` 为 arm64，238,544 bytes |
| 动态链接 | `otool -L` 中均为 `/System/Library/Frameworks` 或 `/usr/lib` 系统库；无内嵌 Swift 运行时或第三方 framework |

上述体积仅对应当时的小型 P0，不外推到含结构视图、更多语法和扩展的完整 V1，也不包含开发工具、构建缓存或测试产物。

本轮测试的语法着色是本地有界扫描器，覆盖 Python、Java、JavaScript/TypeScript、JSON/JSONC、Shell。文件读写上限为 10 MiB；着色上限为 200 KiB 或 20,000 行，超出后保留纯文本编辑。CSV/JSON 结构视图和 Quick Look 尚未实现。

## 已执行的自动验证

以下测试由本轮开发执行，两次均为 **16 项通过、0 项失败**：

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
```

随后直接运行已构建的测试 bundle，并禁止该进程树访问网络：

```sh
sandbox-exec -p '(version 1) (allow default) (deny network*)' \
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun xctest \
  build/TestBuild/arm64-apple-macosx/debug/MacOSFileEditorPackageTests.xctest
```

禁网结果证明这些文件和会话操作不需要网络；结合空依赖列表及没有网络功能的实现，支持 P0 的离线设计。尚未完成禁网条件下的全部真实窗口流程，不将测试覆盖范围扩大为整机界面验收。

| 测试组 | 数量 | 已覆盖内容 |
| --- | --- | --- |
| `DocumentFileTests` | 12 | UTF-8/BOM/UTF-16 的原字节与换行往返、空文件/BOM 空文件、严格拒绝非法编码、内容变化冲突及仅时间变化无冲突、删除检测、既有目标覆盖保护、大小限制、POSIX 权限、符号链接、硬链接保护、写入失败保留原文件 |
| `EditorSessionTests` | 4 | 不同 tab 的撤销/重做隔离、重载使用磁盘内容且只清当前 tab 的 undo、Unicode 等价但字节不同的编辑仍标记 dirty、另存后更新基线并保留撤销与原文件 |

重载测试还覆盖文本缩短后选区夹紧、磁盘快照更新及 dirty/外部变化状态清理。另存测试检验会话和文件结果，不等同于实际操作另存面板或 Reload 的三种对话框路径。

## 已知实现边界

- 保存前使用内容摘要核验磁盘版本，再原子写入；这不是跨进程的比较并交换，其他写入者仍可能在最终检查与替换之间介入。
- 权限保持在本机文件系统测试通过；ACL、扩展属性、磁盘满、掉电/进程终止、网络盘与云盘行为未全面验证。
- 应用激活时异步检查外部修改，保存时再核验；没有持续 watcher、自动重载或日志 tail。外部变化通过状态栏提示，实际交互待测。
- 当前没有草稿恢复；关闭未保存文件的确认逻辑已经实现，对话框与应用退出链路仍需人工操作验收。
- 语法着色是阅读辅助，不进行完整语法校验或语义分析；着色正确性、输入中取消旧任务和长文件响应尚未完成系统验收。

## 下一轮人工与性能验收

1. 在可交互桌面打开至少三个文件，切换 tab，验证选区、滚动、焦点、独立撤销和关闭提示；从 Finder“打开方式”和菜单打开文件。
2. 外部修改同一文件后返回应用，检查提示；分别执行 Reload 的取消、放弃、另存副本路径，并验证文件删除/读取失败/另存取消时原文仍保留。
3. 使用系统拼音真实组合输入与选词，覆盖切 tab、撤销、Emoji 和组合音标；验证高亮不打断输入或污染撤销记录。
4. 在禁网环境重复新建、打开、编辑、保存、另存、Reload、基础着色的窗口操作。
5. 按[验证计划](validation-roadmap.zh-CN.md)测启动 P50/P95、输入延迟和 physical footprint。当前没有可用的性能达标结论；后续每次加入语法或结构视图时重测包体积。
6. 在 macOS 14 实机或合适测试环境验证兼容性，再安排正式分发签名与公证。签名/公证属于发布流程，不作为用户运行功能的网络依赖。

CSV/JSON 专用视图、Finder Quick Look 及完整 V1 的其他验收在后续阶段开展，不计入本次 16 项测试。
