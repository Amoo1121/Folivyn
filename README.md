# macos-file-editor

面向 macOS 的轻量文件查看与编辑器。这是暂定项目名，正式品牌尚未确定。

代码仓库：[Amoo1121/macos-file-editor](https://github.com/Amoo1121/macos-file-editor)（私有，名称暂定）。

**当前已有可构建的 P0 原型。** 使用 Swift、AppKit 和系统文本组件，零第三方包依赖；全部逻辑在本机运行，无账号、语法下载、遥测或自动更新。已完成编译和 16 项自动测试；同一组测试在禁止网络的环境中也全部通过。真实窗口操作尚待人工验收，详见[原型验证记录](docs/prototype-validation.zh-CN.md)。

当前 arm64 Release 应用包内文件总大小 **242,093 bytes（236.42 KiB）**，文件系统分配空间为 **244 KiB**。这是小型 P0 的实测结果，不代表完整 V1 的最终体积。

原型先做好打开与修改单个文件，支持多个文件以 tab 切换。完整 V1 仍面向用户确认的 **代码文本 + CSV/JSON 专用视图**，另计划提供 Finder Quick Look。

## 运行原型

需要 Apple Silicon Mac 和本地 Swift/Xcode 开发工具。应用的部署目标为 macOS 14+，目前只在开发机 macOS 26.5.1 构建和运行自动测试，最低系统兼容性尚待实机验证。

在项目根目录执行：

```sh
./scripts/build-app.sh
open "build/File Editor.app"
```

脚本构建 arm64 Release 应用、进行 ad hoc 签名并输出应用包路径和磁盘占用；本机存在 `/Applications/Xcode.app` 时自动选用其中的工具链。当前没有 Developer ID 签名或 Apple 公证，产物用于本地原型试用。

## 当前能力与边界

| 能力 | P0 行为 |
| --- | --- |
| 文件编辑 | 新建、打开、保存、另存；单文件最多 10 MiB |
| 多文件 tab | 独立文本、未保存标记、撤销/重做、选区与滚动位置；重复打开定位已有 tab |
| Reload | 从磁盘重读；有本地修改时选择取消、放弃后重载或另存副本后重载；读失败保留原文，成功后清除该 tab 的旧撤销记录 |
| 外部修改 | 应用重新激活时检查，保存前再次核验；提示冲突，不静默覆盖；无持续监听或日志追踪 |
| 语法着色 | Python、Java、JavaScript/TypeScript、JSON/JSONC、Shell 的本地基础着色；超过 200 KiB 或 20,000 行退为纯文本 |
| 编码 | UTF-8（含 BOM）、带 BOM 的 UTF-16 LE/BE；严格解码，保留编码与原有换行，不自动格式化 |
| 离线与体积 | 无第三方包或网络功能，动态链接系统库；当前应用包磁盘占用 244 KiB，低于 P0 的 15 MiB 预算 |

保存通过内容摘要识别外部变更，使用 Foundation 原子写入。符号链接保存到目标，多个硬链接的文件可读但拒绝直接保存并提示另存。跨进程同时写入仍可能发生最后检查与替换之间的竞态；文件系统可靠性边界见验证记录。

CSV 当前按文本编辑，JSON 当前仅有文本编辑与基础着色。CSV 表格、JSON 树、Quick Look、查找替换、行号、草稿恢复和更完整的语法支持留在后续阶段。基础着色不提供编译诊断、智能补全或代码执行。

常用快捷键：`⌘O` 打开、`⌘S` 保存、`⇧⌘S` 另存、`⌘R` 重载、`⌘W` 关闭标签、`⇧⌘[` / `⇧⌘]` 切换标签。未保存的标签名后显示 `•`。

## 自动测试

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path build/TestBuild
```

当前共 16 项测试：12 项文件核心测试与 4 项 AppKit 会话测试，覆盖编码/换行保真、冲突与失败保护、多 tab 撤销隔离、重载和 Unicode 未保存状态。禁网运行命令与未验证项目见[原型验证记录](docs/prototype-validation.zh-CN.md)。

## 设计文档

| 文档 | 内容 |
| --- | --- |
| [产品定义](docs/product-spec.zh-CN.md) | 小型 P0 范围、离线/体积约束与完整 V1 愿景 |
| [技术方案](docs/technical-plan.zh-CN.md) | 实际 P0 与 V1 架构规划、编辑引擎、多视图一致性、文件可靠性 |
| [验证与实施计划](docs/validation-roadmap.zh-CN.md) | 验收门槛、性能目标、语料和后续里程碑 |
| [原型验证记录](docs/prototype-validation.zh-CN.md) | 已执行测试、复现命令、产物信息与待验收事项 |
