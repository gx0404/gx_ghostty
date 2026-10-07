# ci-release：CI、发版、版本与上游治理文件

## 范围

- `.github/**`：两个启用的 workflow、归档目录 `workflows-archive/`，以及其余上游文件（`VOUCHED.td`、`dependabot.yml`、`pinact.yml`、`DISCUSSION_TEMPLATE/` 等；`scripts/` 里的翻译与 Apple 检查脚本另属 `apprt-gtk`、`libghostty-vt`）。
- 版本与发版：`CHANGELOG.md`、`docs/RELEASE.md`、`scripts/version.py`、`scripts/gx_release.py`、`scripts/conventional_commits.py`，锁定测试 `scripts/test_gx_release.py`、`scripts/test_gx_workflows.py`。
- 原样保留的上游治理与 lint 配置：`CODEOWNERS`、`CONTRIBUTING.md`、`HACKING.md`、`typos.toml`、`.prettierignore`、`.editorconfig`、`.shellcheckrc`、`.clang-format`、`.swiftlint.yml`；上游 Debian 13 构建镜像 `src/build/docker/debian/**`（GTK 构建依赖的参考）。
- `--task release` 加载本文档；`--task sync` 同时加载本文档与 `development.md`。

## 符号真源

- `scripts/test_gx_workflows.py`：锁定 `.github/workflows/` 恰为两个 `gx-*.yml`，并锁定触发器、权限、SHA 钉版、env 传参等形状。
- `scripts/gx_release.py`：`prepare` 解析干净的源提交并跑发版门，输出 `sha`、`version`、`tag`、`version_string`、`zig`；`verify` 按预期资产集合核对产物并写出 `manifest.json` 与 `SHA256SUMS`；`publish` 只在 `gx-release` 内执行。契约由 `scripts/test_gx_release.py` 锁定。
- `scripts/version.py`：从根 `CHANGELOG.md` 解析 fork 版本；`--check` 要求所有版本标题合法且至少一个，`--release` 另要求最大版本已带日期。
- 产品版本：`build.zig.zon` 的 `.version`。`src/build/Config.zig::init` 推导最终版本，优先级 `-Dversion-string` > 作为依赖构建 > `src/build/GitVersion.zig::detect`。
- `scripts/conventional_commits.py`：提交信息校验，输入为 `--message-file`、`--range A..B` 或直接给 subject；`.githooks/commit-msg` 调用同一脚本。
- `docs/RELEASE.md`：发版操作手册（步骤、资产清单、排障）。

## 不变量

### 启用集合与归档

- `.github/workflows/` 只允许 `gx-ci.yml` 与 `gx-release.yml`。上游 15 个 workflow 经 `git mv` 原样存放在 `.github/workflows-archive/`，GitHub 不从该目录加载；归档目录里只有 `README.md` 是 fork 自有文件。
- 归档理由可复核：上游 job 跑在 `namespace-profile-ghostty-*` runner 上，依赖 `CACHIX_AUTH_TOKEN`、`VOUCH_APP_*`、R2、Apple 公证等上游 secrets，另有定时任务；`test.yml` 的 `required` job 以 `if: always()` 挂在 namespace runner 上，在 fork 上只会一直排队。
- 同步上游时：新 workflow 会出现在 `.github/workflows/`，原样 `git mv` 进归档；上游改了已归档的文件，就把上游内容落在归档路径（Git 的重命名检测通常自动完成），不手改正文；上游删除的 workflow，归档副本跟着 `git rm`。归档集合有增删时同步更新 `scripts/test_gx_workflows.py::ARCHIVED` 与归档 `README.md` 的表。归档文件永不移回或重新启用；启用集合多出文件会让 `test_gx_workflows.py` 失败，`just framework-check` 即可发现。

### workflow 安全形状

- 每个 `uses:` 钉完整 40 位提交 SHA 并附版本注释，且必须复用归档上游 workflow 里已钉的同一个 SHA（如 `actions/checkout`、`mlugg/setup-zig`），同一 action 只用一个 SHA；不用 `@main`、`@vN` 之类可变引用。所有 checkout 设 `persist-credentials: false`，每个 job 设 `timeout-minutes`。
- 顶层 `permissions: contents: read`；只有 `gx-release` 的 `publish` job 有 `contents: write`。只用临时 `GITHUB_TOKEN`，且只交给 `prepare` 与 `publish`；不引入 PAT 或上游 secrets，不用 `pull_request_target`。
- `inputs`、`github.event` 字段与 step 输出先放进 `env:`，脚本里用 `"$VAR"` 引用，不在 `run:` 中内插 `${{ }}`；pwsh 步骤每条原生命令后检查 `$LASTEXITCODE`。形状测试之外，本机有 actionlint（`just doctor` 的可选项）时再对两个 `gx-*.yml` 做静态检查，没有就记 PENDING。
- `gx-ci`：push 与 PR 到 `gx_ghostty`，以及 `workflow_dispatch`（可选 `gtk_smoke`、`macos`、`cache_probe`，均默认 false）；concurrency 只让同一 PR 的新运行取消旧运行；push 与手动运行按 `github.run_id` 各占一组、互不取消，保证每次 push 的提交标题都被校验。Zig 由 `mlugg/setup-zig` 按 `minimum_zig_version` 提供。
- `gx-ci` 的 job：`framework`（resolver、version、`scripts/run_unittests.py`、kb-check、首父链提交校验，不跑 graph-check）、`zig-fmt`、`linux-vt`（装 `python3-jsonschema`，跑 `scripts/zig_test.py --suite vt` 与 `test-lib-vt-schema`）、`linux-main`（`scripts/zig_test.py --suite main -Dapp-runtime=none`）、`lib-vt-cross` 矩阵（`x86_64-linux-gnu`、`aarch64-linux-gnu`、`x86_64-linux-musl`、`x86_64-windows-gnu`、`aarch64-macos`、`wasm32-freestanding`）、`windows`（windows-2025 上 `scripts/zig_test.py --suite vt`、`-Demit-lib-vt` 与 `example/c-vt-static`）；`gtk-smoke`、`macos`（`zig build test-lib-vt`）只在手动触发且对应输入为真时运行。测试 job 与本机走同一套运行器（`docs/TESTING.md`「并行运行器与耗时」），运行器经 `scripts/zigw.py` 用上 `mlugg/setup-zig` 放在 PATH 的 Zig；三个测试 job 用 `--json` 写结果，成功或失败都以 `always()` 上传 artifact `gx-zig-test-<job>`（保留 14 天）。
- 耗时不能越过证据范围：只有本机热缓存全量实测在 2 min 内，用户「所有测试 ≤2 min」要求尚未完全达成；不能擅自排除冷编译。4 vCPU runner 的新布局首跑约 14.4 min。2026-10-07 run 37587736223 的 `linux-vt` 缓存达 5,078,327,232 字节，超过 4096 MiB 后被清空，下一轮只恢复 186 字节。translate-c 的 `--zig-lib` 路径直接入 hash 已由钉版源码证实，随机工具链路径会改变输入；CPU 型号切换仍是待证猜测。
- 三个测试 job 用 `use-tool-cache: true` 固定工具链路径，以 `cache-key: stable-toolchain-v1` 隔离旧变体，不删除旧 cache，`cache-size-limit: 4096` 不变；`lib-vt-cross` 仍按 target 分 key。测试构建传 `--summary all`，`scripts/ci_cache.py` 按白名单报告 CPU、Zig 路径、缓存分区大小和 timings 条数，不导出任意环境变量。手动输入 `cache_probe` 默认 false，仅为 true 时在同一 runner 重复同套件的安装构建、不重跑用例；普通 push/PR 不多编译。恢复后及 job 结束快照与可选复建 JSON 随 `gx-zig-test-<job>` 以 `always()` 上传，finished 快照早于 action post，不能代证最终保存。新实现真实 CI 效果 PENDING，补验见 `docs/TESTING.md`。不得删 job、ABI 校验、默认加 `--dedupe` 或缩小 filter 来换取提速。
- GUI 复测：本机 Windows 没有 Ghostty GUI，GUI 可见变更本机记 PENDING。`gtk-smoke` 在 debian:13 容器构建、用 `xvfb-run` 截图并把证据作为 artifact 上传，读回截图后才记 PASS。
- `gx-release` 只能 `workflow_dispatch`（`ref` 默认 `gx_ghostty`，`publish`、`macos` 默认 false），带仓库守卫 `github.repository == 'gx0404/gx_ghostty'`；同一仓库的运行串行排队、不互相取消。prepare 把 `ref` 解析成完整 SHA，后续 job 只构建这个 SHA。

### 版本与 tag

- fork 版本是 `CHANGELOG.md` 中数值最大的 SemVer；tag `gx-vX.Y.Z`，release 名 `Ghostty GX X.Y.Z`。
- 构建版本串 `VS = <build.zig.zon 的 X.Y.Z>-gx.<fork 版本>`（如 `1.3.2-gx.0.1.0`），所有 release 构建都传 `-Dversion-string=$VS`。产品版本仍以 `build.zig.zon` 为真源：fork 不改 `.version`，也不在两套版本之间做同步。
- 不传 `-Dversion-string` 时版本来自 Git：分支构建得到 `<X.Y.Z>-<分支名>+<短 hash>`，分支名里 `[0-9A-Za-z-]` 以外的字符换成 `-`（`gx_ghostty` 成为 `gx-ghostty`）。HEAD 恰有 tag 时，上游只接受 `tip` 或与 `build.zig.zon` 一致的 `vX.Y.Z`，其余 `@panic`；补丁 GX-0001 让 `gx-v*` 这类非 `v` 前缀 tag 与 `tip` 一样跳过发布校验，回退到分支预发布版本，登记在 `docs/FORK_PATCHES.md`。
- libghostty-vt 的库版本走 `-Dlib-version-string`，默认取 `build.zig` 的常量 `lib_version`，fork 不改；发版资产名统一用 `$VS`。

### CHANGELOG

- 根 `CHANGELOG.md` 只记 fork 版本；上游没有这个文件，这里也不转述上游产品变更。
- 二级标题只能是版本标题，形如 `## X.Y.Z(YYYY-MM-DD)` 或 `## X.Y.Z(TBD)`，版本不重复、不带前导零，其他小节一律用 `###`（`version.py --check` 校验）。数值最大的标题就是当前 fork 版本，新条目写在它下面；它已定版时先加新的 `(TBD)` 标题。
- 每个版本下按 `### Added` / `### Changed` / `### Fixed` 分组（没有条目的组省略），写可观察行为：用户或开发者能看到什么变化、影响范围、怎样验证；不写提交列表，也不写内部重构细节。
- 要记：fork 的产品行为、构建与发版产物、命令入口与开发流程的可观察变化。可不记：纯措辞修改、没有行为变化的重构。上游同步本身不逐条记，只记它给 fork 带来的可观察影响（例如钉版 Zig 随之升级）。

### 发版流程（操作细节见 `docs/RELEASE.md`）

1. 把最大版本的 `(TBD)` 改成当天日期，跑 `just graph`、`just kb`，再跑 `just generated-check`；三者一起提交为 `chore(release): 定版 X.Y.Z`。
2. 用户 push。
3. 用户在 Actions 手动运行 `gx-release`，先用 `publish=false` 做完整构建验收（`verify` 在只构建模式下也运行）。
4. 再用 `publish=true` 发布。
5. 新增下一个 `## X.Y.Z(TBD)` 标题，跑 `just version-check` 与 `just kb`，把 `docs/kb/chunks.json` 与 CHANGELOG 一起提交。

- prepare 前置门：检出必须干净，resolver `--check`、`version.py --check`、kb-check、graph-check 全部通过，图谱或 KB 不新鲜就拒绝发版；`publish=true` 时还要求最大版本已带日期，且同名 tag 与 release 都不存在。
- 资产名一律带 `$VS`：`source` 用 `zig build distcheck -Demit-lib-vt=true` 产出 `libghostty-vt-$VS.tar.gz`（≤5 MiB）；`libvt` 矩阵产出 `libghostty-vt-$VS-<target>.tar.gz|zip`（`x86_64-windows-msvc` 在 windows-2025 原生构建）；`linux-gtk` 在 debian:13 容器先 `zig build dist` 得到 `ghostty-$VS.tar.gz`，再从它构建 `ghostty-gx-$VS-x86_64-linux-debian13.tar.gz`，`+version` 必须等于 `$VS`；`macos` 输入为真时另有 xcframework 与未签名 app 的 zip。完整清单见 `docs/RELEASE.md`。
- `verify` 校验资产集合、SHA256、`manifest.json` 与 `SHA256SUMS`。`publish` 依次 draft → 上传 → 复核远端大小与 digest → 以 prerelease 发布；拒绝覆盖已有 release，拒绝移动 tag。
- agent 可以准备定版提交并在本地验证；push、运行 workflow 与发布由用户决定。agent 不能触发发版：`gx-release` 只由人类在 GitHub 上手动运行（Actions 页面，或人类自己执行 `docs/RELEASE.md` 给出的等价命令）。策略要求拒绝 agent 执行 `gh workflow run … gx-release`、`gh release create|edit|delete|upload` 及对 releases、dispatches、git/refs、actions/workflows 的写型 `gh api`；`gh run rerun` 需人工确认，因为重跑 `publish=true` 就会发版。这些约束不依赖 hook 是否生效，agent 都须遵守；hook 只有加载并受信任后才参与拦截，不能拿离线测试作保证（真实验收见 `docs/AI_TOOLS.md`）。不手工建 tag 或 release。`.githooks/commit-msg` 首次提交时用 `git add --chmod=+x`，否则 POSIX 上的 git 不执行它。

### 提交规范的强制

- 格式 `type(scope): 中文描述`，type 取 `feat fix perf docs ci test refactor chore build revert style release`，校验正则 `^type(\(scope\))?!?: \S`。
- 本地可选：`just install-hooks` 把 `core.hooksPath` 设为 `.githooks`，`commit-msg` 钩子调用 `conventional_commits.py --message-file`。
- CI 的 `framework` job 只沿首父链校验：push 用 `before..after`（`before` 全零时只校验 head），PR 用 `base..head`；`--range` 内部带 `--first-parent`。同步合并带进来的上游提交（`<subsystem>: <summary>` 风格）因此不受检，但合并提交自身必须合规，所以同步一律 `--no-ff` 并用 `chore(sync): …` 消息。

### 原样保留的上游治理

- lint 配置 `typos.toml`、`.editorconfig`、`.shellcheckrc`、`.clang-format`、`.swiftlint.yml` 保持上游原样；`.prettierignore` 只在末尾追加 fork 段（忽略 `docs/kb/`、`graphify-out/`）。fork CI 只跑 `zig fmt --check`，不跑 typos、prettier、shellcheck、swiftlint（也不跑 alejandra、pinact）；需要时由人类按 `HACKING.md` 的 Linting 一节在本机运行，没跑过就不得声称通过。
- `CODEOWNERS` 与 `.github/VOUCHED.td` 由上游 vouch 机器人维护，vouch 系列 workflow 已归档；fork 不编辑它们，同步时一律取上游版本。`DISCUSSION_TEMPLATE/`、`issue-unvouched-message`、`pinact.yml` 同样只随上游变化。
- `.github/dependabot.yml` 原样保留。fork 里存在该文件并不会自动开启 Dependabot version updates（GitHub 对 fork 默认关闭），所以 fork 默认收不到 action 升级 PR。钉版跟随上游：同步带来新的 action SHA 时，把 `gx-*.yml` 改成同一个值和版本注释，形状测试会检查两边一致。

## 禁止项

- 不启用、不移回、不编辑归档 workflow（编辑工具写 `.github/workflows-archive/*.yml` 会被 hook 拒绝，归档 `README.md` 除外）；不在 `.github/workflows/` 新增第三个文件。
- 不擅自扩大触发面：契约外的事件要先改 `test_gx_workflows.py` 的契约并说明理由；不用 `pull_request_target`。
- 不用可变 action 引用，不在 `run:` 里内插 `${{ }}`，不给 `publish` 以外的 job 写权限，不引入 PAT 或上游 secrets，不开启 `persist-credentials`。
- 不覆盖已发布的 release，不移动或删除 tag，不发布未经 `verify` 的构建；不 force push，不推送 `upstream`。
- 不为 fork 发版改 `build.zig.zon` 的 `.version`；不把上游变更或提交列表写进 `CHANGELOG.md`。
- 不编辑 `CODEOWNERS`、`VOUCHED.td`、`dependabot.yml` 与上游 lint 配置（`.prettierignore` 的 fork 段除外）。
- 不把 graph-check 加进 push CI。

## 验证

- 改 workflow、`scripts/gx_release.py`、`scripts/version.py` 或 `scripts/conventional_commits.py`：`just framework-test`，再 `just framework-check`。
- 改 `CHANGELOG.md`：先 `just version-check`，再 `just kb`，把 `docs/kb/chunks.json` 与 CHANGELOG 一起提交。CHANGELOG 前 6000 字符是 KB 语料（`scripts/build_agent_kb.py::CHANGELOG_HEAD_CHARS`），漏跑会让 `gx-ci` 的 `framework` job 在 kb-check 失败，其余 job 都依赖它。查看当前 fork 版本：`just version`。
- 校验一段提交：`just commit-check --range <base>..HEAD`。
- 发版前：`just generated-check`。workflow 的首跑结果要等用户 push 并在 fork 启用 Actions 后才能取得，在此之前记 PENDING。
