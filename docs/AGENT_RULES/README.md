# AGENT_RULES：领域规则与路由

本目录存放 gx_ghostty 的 AI 领域规则。根 `AGENTS.md` 每轮常驻加载，只放跨域协议与导航；各领域的不变量、真源符号与验证方式写在本目录的 `<id>.md`，由 resolver 按本轮触及的路径按需加载。

- 机器真源：[`routes.toml`](routes.toml)（schema v3）。它把路径与任务类型映射到领域文档，并登记上游自带的嵌套 `AGENTS.md`。
- 解析与守门：`scripts/resolve_agent_rules.py`；行为测试在 `scripts/test_resolve_agent_rules.py`。
- 本 README 与根 `AGENTS.md` 的「领域规则索引」只做导航，必读集合以 resolver 输出为准。本文件不是领域文档，不参与闭集与重复段落检查。

## 命令

| 命令 | 等价调用 | 作用 |
|---|---|---|
| `just rules <路径…>` | `python scripts/resolve_agent_rules.py <路径…>` | 列出本轮必读的领域文档与适用的上游嵌套 `AGENTS.md` |
| `just rules-review <路径…>` | `python scripts/resolve_agent_rules.py --task review <路径…>` | 同上，追加 `code-review` 审核规程 |
| `just rules-check` | `python scripts/resolve_agent_rules.py --check` | 全仓守门，检查项见下文 |

Linux/macOS 直接调用脚本时用 `python3`。其他参数：

- `--task <类型>` 可重复，也可以不带路径单独使用，例如 `just rules --task sync`。
- `--json` 输出一行 JSON：`version`（等于 schema 版本 3）、`scope`（归一化后的仓库相对路径）、`tasks`、`rules`（`{id, doc}` 列表）、`upstream_agents`。
- `--root <目录>` 指定仓库根；默认取脚本所在的仓库，与当前目录无关。
- 退出码：成功 0。未知路径、未知任务、含 `..` 或位于仓库外的路径、`--check` 发现的任何违规，一律退出 2。

解析语义：

- 路径可以是文件或目录，写成仓库相对路径或仓库内的绝对路径都行；相对路径一律按仓库根解释，与当前目录无关。Windows 反斜杠会归一为 `/`。
- 目录展开为其中的 Git 可见文件，多个路径取并集。尚未创建的文件只要命中路由，也可以直接传入。
- 只命中 `root_only` 的路径合法，但不产生领域文档。
- 输出先列领域文档（按 id 排序），再列适用的上游嵌套 `AGENTS.md`：某份登记文件所在的目录是任一 scope 路径（目录已展开）的祖先，即适用。根 `AGENTS.md` 常驻加载，不出现在输出里。
- 例：`just rules src/terminal/c/terminal.zig` 依次输出 `docs/AGENT_RULES/libghostty-vt.md`、`docs/AGENT_RULES/terminal-core.md`、`src/terminal/c/AGENTS.md` 三行。
- resolver 无状态，不缓存上一次结果；scope 扩大后用完整路径集合重跑。

## 领域文档模板

领域文档用中文写，标识符、命令与路径保持英文。正文按下面五段组织，标题文字固定：

| 段落 | 内容 |
|---|---|
| `## 范围` | 本域负责的目录、文件与职责，以及与相邻域的分界 |
| `## 符号真源` | 关键事实的真源，写成 `path::symbol`；不钉行号，不抄会变的字面值 |
| `## 不变量` | 改动后必须仍然成立的约束，如线程与锁、所有权、ABI、生成物同步 |
| `## 禁止项` | 明确不许做的事 |
| `## 验证` | 改动后要跑的命令，只用 justfile 配方或上游真实命令 |

可选段 `## 上游指令`：链接相关的上游嵌套 `AGENTS.md`，只链接，不复制正文。

体量与去重：

- 单份 ≤16 KiB（`--check` 的硬上限），目标 4–10 KiB。
- 不同领域文档之间不得出现 ≥160 字符的相同段落。`--check` 以空行分段，列表中的每一项也单独比较，比较时忽略全部空白，换行位置不同也算重复；标题、表格行与围栏代码块不参与比较。
- 多个领域共享的事实只写在一份文档里，其他文档写文档名引用，例如「见 `terminal-core.md`」。

## glob 语义

`paths` 与 `root_only` 里的 pattern 按仓库相对路径匹配 Git 可见文件，区分大小写：

- `*` 与 `?` 不跨 `/`：`src/apprt/*.zig` 命中 `src/apprt/gtk.zig`，不命中 `src/apprt/gtk/` 下的文件。
- `**/` 匹配零或多级目录：`**/AGENTS.md` 既命中根 `AGENTS.md`，也命中各级嵌套 `AGENTS.md`。
- `dir/**` 命中 `dir` 下的全部文件，也匹配 `dir` 本身。
- `**` 必须独占一个路径段，且不能连续出现；`**`、`**/*` 这类万能兜底 pattern 会被拒绝。
- 一个文件命中多个领域时取并集，例如 `src/apprt/embedded.zig` 同属 `app-core`、`libghostty-embedding` 与 `macos-app`。
- 每个 pattern 至少要命中 1 个 Git 可见文件；被 `.gitignore` 忽略的文件不算数。

## root_only 策略

`root_only` 只登记确实没有领域约束的仓库级元文件，当前是 `.gitmodules`、`.mailmap`、`LICENSE`、`README.md`。

- 命中 `root_only` 的路径不加载领域文档；同一个文件不得既命中 `root_only` 又命中领域路由。
- 不得用 `root_only` 或宽 pattern 填补覆盖缺口。新文件找不到归属时，扩展最贴近的领域，或新增领域。

## 上游嵌套 AGENTS.md 登记表

上游在子目录里放了 9 份 `AGENTS.md`。它们保持上游原样，登记在 `nested_agents`：

| 文件 | 主题 | 所在领域 |
|---|---|---|
| `example/AGENTS.md` | 新增 libghostty 示例工程的步骤，Doxygen `@snippet` 标记与头文件同步 | `libghostty-vt` |
| `macos/AGENTS.md` | swiftlint；用 `macos/build.nu` 构建与测试 macOS app；AppleScript 约定 | `macos-app` |
| `src/benchmark/AGENTS.md` | `ghostty-gen` 与 `ghostty-bench` 的分工，基准对比方法 | `testing` |
| `src/inspector/AGENTS.md` | inspector 的 dcimgui API 查阅方式；该包没有单元测试 | `cli-inspector` |
| `src/terminal/apc/glyph/AGENTS.md` | Glyph 协议规范的来源 | `terminal-core` |
| `src/terminal/c/AGENTS.md` | libghostty-vt C API 的 ABI 约束与四步导出流程 | `libghostty-vt`、`terminal-core` |
| `src/terminal/compress/AGENTS.md` | 终端页压缩编解码的取舍优先级与测试要求 | `terminal-core` |
| `src/terminal/snapshot/AGENTS.md` | 二进制快照：编码时严格校验，解码时宽容降级 | `terminal-core` |
| `test/fuzz-libghostty/AGENTS.md` | AFL++ fuzzer 的构建、语料与 crash 重放 | `libghostty-vt`、`testing` |

`**/AGENTS.md` 另外把这些文件都归入 `development`。fork 自己的规则只写进本目录，不新增嵌套 `AGENTS.md`。

上游同步后，嵌套文件可能有增删或移动，处理步骤：

1. 运行 `just rules-check`（`just framework-check` 也包含它）。Git 可见的嵌套集合与 `nested_agents` 不一致时退出 2：多出的文件要求登记，缺失的条目要求作为过期项删除。
2. 按字典序更新 `nested_agents`；确认新文件所在目录已被某个领域的 `paths` 覆盖。
3. 在相关领域文档的 `## 上游指令` 段补上链接，或删除失效链接。不复制、不改写上游正文。
4. 重跑 `just rules-check` 直到通过；改了领域文档后运行 `just kb`。

## 根 AGENTS.md 的结构

- 顶部是上游原文，一字不改；同步上游遇到冲突时，这一段取上游版本。
- 其后是唯一一行以 `<!-- gx-fork:` 开头的标记，标记之下是 fork 维护段，同步时整段保留。fork 段依次为：规则加载协议、语言与协作、fork 治理、项目模型、常用命令、跨域硬边界、提交规范、领域规则索引、完成门。
- `--check` 要求根文件是 UTF-8 普通文件，整体不超过 `root_max_bytes`（16384 字节），且标记行在行首恰好出现一次。
- 领域规则正文不写进根文件。根文件的「领域规则索引」只做导航，新增、拆分或删除领域时要同步更新。

## 新增或拆分领域

先运行 `just rules <新路径>`，看新路径是否已有归属。落在已有 glob 下的新文件不需要改路由。

新增领域：

1. 选定 kebab-case 的 `id`，按上面的模板写 `docs/AGENT_RULES/<id>.md`，每条事实回源核实。
2. 在 `routes.toml` 中按 `id` 顺序插入 `[[rules]]`：`doc` 固定为 `docs/AGENT_RULES/<id>.md`，`paths` 与 `tasks` 各自排序。纯任务型规则写 `paths = []`。
3. 新的任务类型直接写进相应规则的 `tasks`。resolver 接受的任务集合就是全部规则 `tasks` 的并集。
4. 更新本 README 的领域索引（任务型规则再更新任务表）与根 `AGENTS.md` 的「领域规则索引」。
5. 运行 `just rules-check` 直到通过，再用 `just rules <代表路径>` 确认输出；改了文档要运行 `just kb`，最后运行 `just framework-check`。

拆分领域：

1. 把迁出的 `paths` 移到新规则，正文随之迁移。旧文档只留一句指向新文档的引用，不保留副本，否则会触发重复段落检查。
2. 被多个领域共享的文件（如 `include/ghostty.h`）可以同时列在多条规则里，resolver 取并集；但同一段说明只写在一份文档里。
3. 同样运行 `just rules-check`、`just kb` 与 `just framework-check`。

删除领域时，同时删除 `[[rules]]` 与文档，并确认原 `paths` 下的文件已由其他领域覆盖。提交信息遵循根 `AGENTS.md`「提交规范」的 `type(scope): 中文描述`。

## --check 检查项

`just rules-check` 一次列出全部违规，有任何违规就退出 2。Git 可见文件指 `git ls-files --cached --others --exclude-standard` 的结果，即已跟踪文件加上未被忽略的新文件。

1. 根 `AGENTS.md`：普通文件、UTF-8、非空、不超过 `root_max_bytes`，fork 段标记行恰好一次。
2. schema：顶层键恰为 `version`、`root_max_bytes`、`root_only`、`nested_agents`、`rules`；`version = 3`，`root_max_bytes = 16384`。每条 `[[rules]]` 恰为 `id`、`doc`、`paths`、`tasks`；`id` 是 kebab-case 且唯一，`doc` 等于 `docs/AGENT_RULES/<id>.md`，`paths` 与 `tasks` 不能同时为空。
3. 排序：`rules` 按 `id` 排序；`paths`、`tasks`、`root_only`、`nested_agents` 各自按 Unicode 码点排序（Python `sorted()`，`*` 与 `.` 开头的条目在前，大写字母先于小写）。
4. 领域文档闭集：本目录下除 `README.md` 以外的每个 `*.md` 都已登记；每份登记的文档存在、非空、不超过 16 KiB、是 UTF-8。
5. 嵌套 AGENTS：Git 可见的 `*/AGENTS.md`（根文件除外）集合与 `nested_agents` 完全相等。
6. 零命中：每个 pattern（含 `root_only`）至少命中 1 个 Git 可见文件。
7. 覆盖：每个 Git 可见文件至少属于一个领域或 `root_only`，且不能两者兼有。
8. 重复段落：不同领域文档之间没有 ≥160 字符的相同段落。

## 领域索引

覆盖范围以 `routes.toml` 为准，下表只是摘要。

| id | 覆盖 |
|---|---|
| `app-core` | `src/App.zig`、`src/Surface.zig`、`src/surface_mouse.zig`、`src/apprt.zig` 与 `src/apprt/*.zig`、入口 `src/main.zig`/`main_ghostty.zig`/`main_wasm.zig`、`src/global.zig`、`src/crash/`、`pkg/{sentry,breakpad}/` |
| `apprt-gtk` | `src/apprt/gtk.zig` 与 `src/apprt/gtk/`（含 GX 层 `src/apprt/gtk/gx/` 与 GX 的 `.blp`）、`po/`、`dist/linux/`、`src/build/{gtk,GhosttyI18n}.zig`、`src/os/` 下的 cgroup/flatpak/i18n、`pkg/{gtk4-layer-shell,libintl}/`、翻译与 Blueprint 检查脚本 |
| `apprt-win32` | `src/apprt/win32.zig` 与 `src/apprt/win32/`、WGL 渲染钩子 `src/renderer/opengl/wgl.zig`、`dist/windows/` 顶层的 rc、ico 与 manifest，以及编进 exe 的 `dist/windows/gx/ghostty-gx.{rc,ico}` |
| `build-system` | `build.zig`、`build.zig.zon` 及其 `.json/.nix/.txt`、`src/build/`、`src/build_config.zig`、`src/helpgen.zig`、`src/main_build_data.zig`、`pkg/`、`vendor/`、`nix/`、flake 与 nix 入口、`Makefile`、`CMakeLists.txt`、`HACKING.md`、`.envrc`、`.gitignore`、`.gitattributes`、`just build` 的入口 `scripts/zig_build.py` |
| `ci-release` | `.github/`、`CHANGELOG.md`、`CODEOWNERS`、`CONTRIBUTING.md`、`HACKING.md`、`typos.toml`、格式与 lint 配置、`src/build/docker/debian/`、`docs/RELEASE.md`、发版/版本/提交校验脚本（`scripts/gx_release.py`、`scripts/version.py`、`scripts/conventional_commits.py` 等）；任务 `release`、`sync` |
| `cli-inspector` | `src/cli.zig`、`src/cli/`、`src/inspector/`、`src/extra/`、`pkg/dcimgui/` |
| `code-review` | 无路径；任务 `review` |
| `config` | `src/config.zig`、`src/config/`、`src/helpgen.zig`，以及 `src/gx/` 的配置分层、`gx-*` 值类型、默认值文件与覆盖文件模块 |
| `development` | 根与嵌套 `AGENTS.md`、`CLAUDE.md`、`README.md`（开头的 fork 声明块）、`AI_POLICY.md`、`HACKING.md`、`.agents/`、`.claude/`、`.codex/`、`.zcode/`、`.githooks/`、`docs/`、`scripts/`、`graphify-out/`、`justfile`、`.graphifyignore`、`.gitignore`、`.prettierignore`；任务 `sync` |
| `font` | `src/font/`（含 DirectWrite 发现 `src/font/directwrite/`）、`pkg/{fontconfig,freetype,harfbuzz}/`、`vendor/nerd-fonts/` |
| `gx-core` | `src/gx/`（GX 共享核心）、翻译表生成器 `scripts/gx_i18n.py`、`po/zh_CN.po` |
| `input` | `src/input.zig`、`src/input/`、`src/surface_mouse.zig`、`src/gx/{action,win32_input}.zig` |
| `libghostty-embedding` | `include/ghostty.h`、`include/module.modulemap`、`src/main_c.zig`、`src/apprt/embedded.zig`、`src/config/{CApi,c_get}.zig`、`src/build/GhosttyLib.zig`、`src/benchmark/CApi.zig` |
| `libghostty-vt` | `include/ghostty/`、`src/terminal/c/`、`src/lib_vt.zig`、`src/lib/`、`src/os/wasm/`、`src/input/` 的 key/mouse/paste 编码器及其传递导入 `{config,function_keys,key_mods,kitty}.zig`、随库编译的 `src/os/{mach,stderr,string_encoding,windows}.zig` 与 `src/renderer/size.zig`、`example/`、`dist/{cmake,doxygen}/`、CMake 与 Doxygen 配置、`test/fuzz-libghostty/` 的顶层文件与 `src/`、`pkg/android-ndk/` 等 |
| `macos-app` | `macos/`、`dist/macos/`、`pkg/{apple-sdk,macos}/`、`.swiftlint.yml`、`include/ghostty.h`、`include/module.modulemap`、`src/apprt/embedded.zig`、`src/os/{macos,cf_release_thread}.zig`、`src/input/KeymapDarwin.zig`、XCFramework 与 Xcodebuild 的构建步骤 |
| `packaging-dist` | `dist/`、`flatpak/`、`snap/`、`images/`、`PACKAGING.md`、`src/build/{GhosttyDist,GhosttyResources}.zig`、`nix/package.nix` |
| `renderer` | `src/renderer.zig`、`src/renderer/`、`pkg/{glslang,opengl,spirv-cross,wuffs}/`、`vendor/glad/`、`passthrough.glsl` |
| `shell-integration` | `src/shell-integration/`、`src/terminfo/`、`src/termio/shell_integration.zig`、`src/os/shell.zig`、`src/extra/{bash,fish,zsh}.zig` |
| `support-libs` | `src/datastruct/`、`src/lib/`、`src/stb/`，以及 `src/` 下的 crc32c、fastmem、fastprint、math、file_type、quirks、tripwire 等小模块 |
| `terminal-core` | `src/terminal/`、`src/simd/`、`src/unicode/`、`pkg/{simdutf,highway}/` |
| `termio-pty-os` | `src/termio.zig`、`src/termio/`、`src/pty.zig`、`src/pty.c`、`src/Command.zig`、`src/os/`、`src/gx/{conpty,osc7}.zig` |
| `testing` | `test/`、`src/benchmark/`、`src/synthetic/`、`src/main_{bench,gen}.zig`、`src/build/GhosttyBench.zig`、`pkg/afl++/`、`nix/tests.nix`、`nix/vm/`、`nix/test-src/`、`valgrind.supp`、测试运行器 `scripts/zig_test.py` 与 WSL 入口 `scripts/gx_wsl.py`；任务 `test` |

## 任务表

| 任务 | 追加的领域文档 | 场景 |
|---|---|---|
| `release` | `ci-release` | 定版、发版、版本号与 tag 相关工作 |
| `review` | `code-review` | 只读审核，通常用 `just rules-review <改动路径>` |
| `sync` | `ci-release`、`development` | 合并上游 `main`、解决同步冲突 |
| `test` | `testing` | 编写或调整测试、选择测试分层 |
