# code-review：审核任务（`--task review`）

## 范围

- 由 `--task review` 触发，不按路径路由；`just rules-review <paths>` 会同时带出改动路径对应的领域文档。适用于审核本仓任何改动：工作区与暂存区 diff、分支上的 fork 提交、上游同步合并、CI 与发版改动。
- 审核者只读：不改文件，不跑会改仓库状态的命令（`just setup`、`just fmt`、`just graph`、`just kb`、`just install-hooks`、任何 git 写操作），也不在 GitHub 上评论、批准或开 issue / PR。
- 两种运行方式：专用 reviewer（Claude 的 code-reviewer、Codex 的只读沙箱 reviewer）只跑 resolver 与只读 git 命令，构建、测试写成建议命令并标 PENDING；在有完整权限的会话里审核时可以实跑构建与测试，它们留在 `.zig-cache/`、`.local/zig-cache/`、`zig-out/` 的缓存不算改状态。

## 符号真源

- 必读集合：根 `AGENTS.md`，加上 `just rules-review <改动路径>` 列出的领域文档与上游嵌套 AGENTS。
- 审核对象：`git diff`、`git diff --cached`，以及 `git diff <base>...HEAD`（分支相对合并基的改动）与对应提交；同步合并以合并前的 `gx_ghostty` 头为基准。
- reviewer 适配器：`.claude/agents/code-reviewer.md`、`.codex/agents/gx-ghostty-reviewer.toml`，只把审核者指向本文档与 resolver，不复制清单。
- 上游提示词：`.agents/commands/review-branch`（Nushell 脚本；可选的 issue / PR 编号经 `gh issue view` 只读拉取上下文）。
- 对照真源：`docs/FORK_PATCHES.md`、`CHANGELOG.md`、`docs/TESTING.md`（各测试层能证明什么、不能代证什么）、`docs/ARCHITECTURE.md`（所有者、线程与数据流）。

## 不变量

### 输出格式

固定四段，按严重度排列；某一级没有发现时写「无」，不省略标题；最后给结论。

```text
严重：
- <path::symbol> 触发：<条件>；后果：<影响>；证据：<命令与输出 / 代码 / 测试>；建议：<修法>
中：
- 无
轻：
- …
结论：需修改后复审（一句理由）
```

- 严重：合入就会造成错误行为、崩溃或内存不安全、ABI / C API 破坏、数据或安全问题、CI 与发版的提权或注入、构建或测试失败、未登记的上游补丁。
- 中：应在合入前修，或有明确理由延后：可测试的改动缺测试、验证声明与实际运行不符、缺 CHANGELOG、安全门描述与实际行为不一致、无谓扩大上游同步冲突面。
- 轻：可读性、命名、文档措辞与非关键的描述漂移。
- 结论三选一：可合入 / 需修改后复审 / 拒绝。有「严重」项时不能给「可合入」；「拒绝」留给方向性问题（违反硬边界、应由上游解决、设计上无法修补）。
- 每条发现必须同时写出触发条件、后果和证据。只有可证明的矛盾才算缺陷：规范里的「必须 / 不得」本身不是问题，拿不出证据的只能作为待确认问题列出。定位用 `path::symbol`，需要时附当前 diff 的行号。
- 审核中被作者当场修掉的问题仍要列出并注明修法；修后复审只验证修复本身及其影响面，不重开范围。

### 检查清单

1. 规则：对全部改动路径跑 `just rules-review`，读完列出的领域文档与上游嵌套 AGENTS（嵌套文件对其所在目录树同样有效）；scope 变化后重跑。
2. ABI / C API：libghostty-vt 函数是否走完四步导出（`src/terminal/c/<module>.zig` → `src/terminal/c/main.zig` → `src/lib_vt.zig` 的 `@export` → `include/ghostty/vt/` 头文件）；新 C 枚举是否以 `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` 收尾；已发布的枚举值与结构体字段有没有被重排或改义；sized struct 是否保持 `size` 首字段并配 `GHOSTTY_INIT_SIZED`；是否仍能构建到 `wasm32-freestanding`。改 `include/ghostty.h` 时同时核对 `src/main_c.zig`、`src/apprt/embedded.zig` 与 macOS 调用方。细则见 `libghostty-vt.md`、`libghostty-embedding.md`。
3. 线程与锁：读写终端状态是否持有 `renderer_state.mutex`（入口 `src/termio/Termio.zig::processOutput`）；不能被饿死的一方是否用 `src/renderer/State.zig::lockDemand` / `unlockDemand`；跨线程是否只经 mailbox 传消息（如 `src/App.zig::drainMailbox`），没有直接改其他线程拥有的状态；OpenGL context 是否只在一个线程上 current；是否引入了 C API 之外的全局状态。细则见 `app-core.md`、`renderer.md`、`termio-pty-os.md`。
4. 生成物：`build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json`、`po/*.pot`、`vendor/glad/`、`graphify-out/**`、`docs/kb/chunks.json` 有没有被手改；生成源变了是否已按对应领域文档重建，或说明了为何无影响。
5. 测试是否真的跑过：每个「已验证」都要对得上命令与结果，层级要匹配（lib-vt 用 `just test-vt`，核心用 `just test --filter <name>`，框架用 `just framework-test`）。Windows 上的 `just test` 不编译 POSIX 分支，Linux 侧要 `just wsl test` 或 CI 的 `linux-main`；GUI 改动要有读过的截图（win32 本机，GTK 经 `just wsl smoke` 或 `gtk-smoke`），macOS 记 PENDING；跳过、`|| true` 或截断输出造成的「静默绿」至少记「中」。
6. CHANGELOG：fork 可观察行为变了，却没在最大版本下记 Added / Changed / Fixed，记「中」（规则见 `ci-release.md`）。
7. fork 补丁：对上游源码（`src/`、`include/`、`pkg/`、`macos/`、`build.zig`）的改动是否带 `fork(gx): GX-NNNN` 标记并在 `docs/FORK_PATCHES.md` 登记；范围外的上游文件除既定追加段与 workflow 归档外是否被改动；能放进新路径的改动有没有被写成上游补丁。
8. 上游同步影响：有没有无谓地重排、重格式化或改名上游代码；有没有碰归档 workflow、嵌套 AGENTS、`CODEOWNERS`、`VOUCHED.td`。审同步合并时核对：根 AGENTS 标记之前与上游一致、新 workflow 已归档、新嵌套 AGENTS 已登记，以及 `just framework-check`、`just ci-check`、`just generated-check` 的实际结果。
9. CI 与发版：SHA 钉版、最小权限、env 传参、首父链提交校验是否仍符合 `ci-release.md`。
10. 提交信息：`type(scope): 中文描述`。

### 与上游 review-branch 的关系

- `.agents/commands/review-branch` 生成「只写总结、不写代码」的分支审核提示，关注代码质量、风格一致、潜在 bug、边界情况、性能、安全、向后兼容与测试覆盖；它与本清单互补，可直接作为任务描述。
- 一起使用时仍先跑 resolver，结论改用上面的四段格式；它拉取的 issue 上下文只读，不在 GitHub 回帖。脚本需要 `nu`，带编号时还需要 `gh`；本机缺失时直接按本清单审核，并在报告里说明。

## 禁止项

- 不修改任何文件，不代作者修复（只给修法），不维护规则清单或白名单副本。
- 不跑 `just setup`、`just fmt`、`just graph`、`just kb`、`just install-hooks`，不做 git 写操作，不 push。
- 不在 GitHub 上发表评论、提交 review 或开 issue / PR。
- 不凭记忆审核：没跑 resolver、没读必读文档就下结论，本身就是流程缺陷。
- 不把没有证据的猜测定级为缺陷，也不把未运行的验证写成通过。

## 验证

resolver 在任何方式下都要实跑；其余命令在只读 reviewer 里写成建议命令并标 PENDING。

- 审核开始：`just rules-review <paths>`；改动涉及路由或领域文档时加跑 `just rules-check`。
- 框架改动：`just framework-check`。
- 产品改动：`just test-vt --filter <filter>`、`just test --filter <name>`，合并前 `just ci-check`（需要钉版 Zig；缺失时记 PENDING，并提示用户运行 `just setup`）。
- 同步与发版改动：`just generated-check`、`just version-check`、`just commit-check --range <base>..HEAD`。
