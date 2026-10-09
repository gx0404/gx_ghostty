# gx_ghostty fork 文档索引

`docs/` 整个目录由 GX fork 新增，上游 `ghostty-org/ghostty` 没有这个目录。这里的文档写给在本仓工作的人和 AI agent，不面向 Ghostty 终端用户；用户文档仍由上游在 ghostty.org 维护。每轮必读的启动协议在根 [`AGENTS.md`](../AGENTS.md) 的 fork 段，本页只做导航。

## fork 文档

| 文档 | 用途 |
|---|---|
| [GX_FEATURES.md](GX_FEATURES.md) | 产品功能清单：WezTerm GX 与 Ghostty GX（Windows、Linux GTK、macOS）逐项对照，借鉴的社区做法，没有实现的功能 |
| [ARCHITECTURE.md](ARCHITECTURE.md) | 代码架构：产物与平台矩阵、仓库布局、入口、核心对象与状态所有者、线程与数据流（含 WGL 与 EGL/DMABUF 两条呈现路径）、win32 apprt 的模块与自绘界面、GX 共享核心与配置分层、GTK 的 GX 层、跨语言契约、关键不变量、生成物、版本推导、打包与发布产物、上游同步面 |
| [DEVELOPMENT.md](DEVELOPMENT.md) | 开发流程：首次准备、九步日常闭环、Windows 开发（构建运行、隔离配置、日志、随包 ConPTY 与 Mesa、打包）、WSL 上的 Linux GTK、分支模型、上游同步与补丁热点、提交规范、生成物重建时机 |
| [MAKE_COMMANDS.md](MAKE_COMMANDS.md) | 命令手册：每个 `just` 配方的作用、前置、副作用与退出码（含 `just package-windows`、`just stage`、`just wsl`），环境变量，上游 `Makefile` 目标 |
| [TESTING.md](TESTING.md) | 测试与证据：分层（能证明 / 不能代证）、Windows GUI 验证、并行运行器与耗时、CI 与本机的覆盖差异、Windows 本机与 WSL 的限制、故障注入、PASS / FAIL / PENDING / N/A 规则 |
| [RELEASE.md](RELEASE.md) | 版本与发布：产品版本与 fork 版本两套体系、`gx-vX.Y.Z` tag 与构建版本串、0.0.1 的发版步骤、`gx-release` 的 job、资产清单与 `manifest.json`、校验、回滚、GX Shell 的跟进、在 fork 上首次启用 Actions |
| [AI_TOOLS.md](AI_TOOLS.md) | AI 工具面：Claude Code、Codex、ZCode 等客户端的规则加载、共享的 hook 安全门策略，以及逐客户端验证账本 |
| [FORK_PATCHES.md](FORK_PATCHES.md) | fork 对上游源码的补丁登记（GX-0001～GX-0022，未用的编号不复用）：补丁 ID、文件与标记、原因、行为、同步冲突处理、移除条件、验证与锁定测试 |
| [AGENT_RULES/README.md](AGENT_RULES/README.md) | 领域规则的加载方式与维护方法；机器真源是 [AGENT_RULES/routes.toml](AGENT_RULES/routes.toml)（路径与任务到领域文档的路由，以及上游嵌套 `AGENTS.md` 的登记） |
| `kb/chunks.json` | agent 知识库，生成物：`just kb` 生成，`just kb-check` 校验，`just kb-query <词>` 检索；不要手改 |

代码图谱产物在仓库根的 `graphify-out/`：只入库 `GRAPH_REPORT.md` 与 `source-fingerprint.json`，约 20 MB 的 `graph.json` 由 `just graph` 在本机重建、不入库。两类生成物的输入与重建时机见 DEVELOPMENT.md「生成物重建时机」。

## 从哪里开始

- 第一次进入本仓：先读 GX_FEATURES.md 了解 Ghostty GX 做了什么，再按 DEVELOPMENT.md「首次准备」依次运行 `just setup`、`just doctor`、`just install-hooks`。
- agent 每轮任务：读根 `AGENTS.md`，再 `just rules <本轮路径…>` 加载领域规则与适用的上游嵌套 `AGENTS.md`，然后按 DEVELOPMENT.md 的九步闭环交付。
- 找命令用 `just --list` 或 MAKE_COMMANDS.md；判断某项验证属于哪一层、本机能否证明，看 TESTING.md。

## 上游文档（权威来源，fork 不修改）

| 文档 | 用途 |
|---|---|
| [HACKING.md](../HACKING.md) | 上游开发手册：从 Git checkout 构建，`zig build` 常用步骤（run、test、dist、distcheck、update-translations），各平台额外依赖，日志，lint，内存泄漏检查，输入栈手测，Nix VM |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | 上游贡献流程：vouch 制度、issue 与 PR 规则、AI 披露要求；agent 不创建 issue 或 PR，对上游和本 fork 都一样 |
| [PACKAGING.md](../PACKAGING.md) | 上游打包指南：源码 tarball、所需 Zig 版本、离线构建参数、libghostty-vt 的 WebAssembly 打包要点 |
| [AI_POLICY.md](../AI_POLICY.md) | 上游 AI 使用政策：披露 AI 参与、人类完全理解代码、禁止 AI 生成的媒体；约束回馈上游的贡献 |
| [README.md](../README.md) | 上游产品说明、路线图与崩溃报告说明 |
| [po/README_CONTRIBUTORS.md](../po/README_CONTRIBUTORS.md) | 上游翻译贡献指南，与 `zig build update-translations` 配套 |

上游自带 9 份嵌套 `AGENTS.md`：`example/`、`macos/`、`src/benchmark/`、`src/inspector/`、`src/terminal/apc/glyph/`、`src/terminal/c/`、`src/terminal/compress/`、`src/terminal/snapshot/`、`test/fuzz-libghostty/`。它们保持上游原样，登记在 `routes.toml` 的 `nested_agents`；`just rules` 按路径的祖先目录把适用的几份随领域文档一起列出。

## 约定

- 事实以源码、配置和测试为准；长期引用写 `path::symbol`，不写行号；命令只写 `justfile` 里真实存在的配方或上游真实命令。
- fork 文档用中文，标识符、命令、路径保持英文。
- 新增 fork 文档时在上表登记；`docs/**` 归 `development` 领域（见 `routes.toml`）。
- 本目录的 `*.md` 都是知识库语料：改完跑 `just kb` 并审 diff，否则 `just framework-check` 里的 `kb-check` 会失败。
