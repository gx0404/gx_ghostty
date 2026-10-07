# Changelog（gx0404/gx_ghostty fork）

本文件只记录 fork 层面的可观察变更：AI 协作框架、开发流程、构建补丁与发布链。上游 Ghostty 不维护 CHANGELOG；Ghostty 产品版本以 `build.zig.zon` 的 `.version` 为真源，本文件不复述上游产品变更，也不与产品版本同步。

版本规则：

- fork 版本取本文件 `## X.Y.Z(YYYY-MM-DD|TBD)` 标题中数值最大的 SemVer；`just version` 查询，`just version-check` 校验标题格式。
- 未发布的版本写 `(TBD)`，发版时改为发布当天的日期。发布 tag 为 `gx-vX.Y.Z`，构建版本串为 `<build.zig.zon 的 X.Y.Z>-gx.<X.Y.Z>`，流程见 `docs/RELEASE.md`。
- 每个版本按 `### Added` / `### Changed` / `### Fixed` 分节（没有条目的节省略），只写使用者能观察到的效果。
- 本文件开头 6000 字符是知识库语料：每次修改后运行 `just kb`，把 `docs/kb/chunks.json` 与本文件放进同一个提交，否则 `gx-ci` 的 `framework` job 失败。

## 0.1.0(TBD)

### Added

- AI 协作框架：根 `AGENTS.md` 在上游原文之后追加 fork 协作协议，`CLAUDE.md` 是薄入口；20 份领域规则放在 `docs/AGENT_RULES/`。`just rules <paths>` 按路径列出必读的领域文档和适用的上游嵌套 `AGENTS.md`，`just rules-check` 守住路由闭集、根文件体积与嵌套 `AGENTS.md` 登记。Claude Code、Codex、ZCode 的 PreToolUse hook 共用同一份危险操作策略（Codex 拦 Bash 与 `apply_patch`，后者按补丁头里的路径尽力判定；hook 命令失败或输入异常时按拒绝处理；各客户端真实会话内的生效情况尚待验证，见 `docs/AI_TOOLS.md`）。
- just 命令入口：根 `justfile` 覆盖环境安装与诊断（`just setup`、`just doctor`）、构建与测试（`just build`、`just test`、`just test-vt`、`just build-vt`、`just vt-wasm`、`just dist-vt`）、格式化（`just fmt`、`just fmt-check`）和框架门（`just framework-check`、`just ci-check`）。配方都是单条命令，Windows（cmd、PowerShell、Git Bash）与 Linux/macOS 用法相同；参数不加引号地交给配方 shell，含空格或 `&`、`>` 等 shell 元字符的文本改为直接调用脚本（见 `docs/MAKE_COMMANDS.md`）。上游 `Makefile` 不变。
- 工具链本地性：`just setup` 把钉版 Zig 0.16.0（sha256 校验）和 graphify 装进仓库内 gitignored 的 `.local/`，zig 全局缓存默认也放在 `.local/`；不做任何系统级安装。`just doctor` 只读报告必需与可选前置，Windows 上包括 MSVC，以及能否创建符号链接（未开启开发者模式时 `just test-vt` 的 tinyio 符号链接用例会失败，只作可选项提示）。
- 代码图谱与知识库：`just graph` / `just graph-check` / `just graph-query` 重建、校验和查询 graphify 图谱（只入库 `GRAPH_REPORT.md` 与源码指纹，`graph.json` 在本机重建）；`just kb` / `just kb-check` / `just kb-query` 构建、校验和检索 `docs/kb/chunks.json`；该文件标为 `export-ignore`，不进 `git archive` 打出的源码包与 GitHub 自动生成的源码压缩包，为 libghostty-vt 源码包的 5 MiB 上限留出余量。
- CI：`gx-ci` 在 push 与 PR 到 `gx_ghostty` 时运行框架检查（规则路由、CHANGELOG 版本标题、框架单测、知识库新鲜度、首父链提交标题）与 `zig fmt` 检查；两者通过后，Linux 上跑无 app runtime 的核心测试、libghostty-vt 测试与 ABI 清单校验，为 6 个目标（含 `wasm32-freestanding`）构建 libghostty-vt，Windows（windows-2025）上跑 `test-lib-vt`、构建 libghostty-vt，并构建、运行 `example/c-vt-static` 静态链接示例。GTK 截图冒烟与 macOS 上的 libghostty-vt 测试需手动触发。同一 PR 的新运行会取消旧运行；push 与手动触发的运行互不取消，每次 push 的提交标题都会被检查。
- 发布：`gx-release` 只能手动触发，默认只构建并校验，产物从该次运行的 Artifacts 下载：libghostty-vt 各平台预编译库、libghostty-vt 源码包、完整源码包和实验性的 Linux GTK 包，附 `SHA256SUMS` 与 `manifest.json`；macOS 产物（libghostty-vt XCFramework 与未签名 app）需另开 `macos` 输入。只有 `publish=true` 时才以 `gx-vX.Y.Z` tag 发布为 prerelease。
- 提交规范：提交信息使用 `type(scope): 中文描述`；`just install-hooks` 启用本地 commit-msg 校验，`gx-ci` 校验首父链上的提交。

### Changed

- 上游的 15 个 GitHub Actions workflow 原样归档到 `.github/workflows-archive/`，在本 fork 上不再运行；启用的只有 `gx-ci.yml` 与 `gx-release.yml`。
- 版本推导（fork 补丁 GX-0001，见 `docs/FORK_PATCHES.md`）：构建打了非 `v` 前缀 tag（如 `gx-v0.1.0`）的提交时不再 panic。此前在这样的提交上，未传 `-Dversion-string` 的任何 `zig build`（包括 `zig build --help`）都会因 “tagged releases must be in vX.Y.Z format matching build.zig” 中止；现在版本回退为分支预发布版本 `X.Y.Z-<branch>+<hash>`。`tip` 与 `vX.Y.Z` tag 的行为与上游一致。
