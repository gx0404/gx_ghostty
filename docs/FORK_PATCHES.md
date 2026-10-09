# fork 补丁登记

本文件登记 gx_ghostty 对上游源码的全部修改（fork 补丁），也是 `scripts/test_fork_patches.py` 解析的机器可读真源。fork 自有的新路径，以及根 `AGENTS.md`、`.gitignore`、`.prettierignore` 末尾带标记的追加段，不是源码补丁，不在此登记。

## 规则

- 范围：`src/`、`include/`、`pkg/`、`macos/` 下的文件与 `build.zig`。改动这些上游文件必须登记；能用新路径或构建参数解决的问题，不改上游源码。
- 编号：`GX-NNNN`，四位数字，按登记顺序递增，永不复用。GX-0013 与 GX-0017～GX-0020 没有对应补丁：这些号已跳过，不补登、不回收；GX-0023～GX-0025 预留给并行开发的分支，合入后各自登记；新补丁取当前最大编号（GX-0026）之后的号。在册的 18 个 ID 是 GX-0001～GX-0012、GX-0014～GX-0016、GX-0021、GX-0022 与 GX-0026，每个 ID 在下文都有一节，写明文件、标记方式、状态、原因、移除条件与验证。
- 标记：每处改动紧邻处写英文注释 `fork(gx): GX-NNNN <说明>`（Zig、C、Swift 用 `//`）。纯新增的多行代码用独占一行的 `// fork(gx): GX-NNNN begin: <说明>` 与 `// fork(gx): GX-NNNN end`（`end` 行不带说明）整块包住，块外不改上游行：删掉这些块就得到上游原文，测试据此校验最小化。一个补丁改多个文件时，每个文件都要有标记，并在登记表中各占一行。
- 最小化：只改必要的行，不重排、不重新注释上游正文，让上游同步时的冲突面最小。
- 提交：补丁单独成一个提交（例如 `fix(build): 非 v 前缀 tag 不再触发版本号 panic`），不与框架或文档改动混在一起。
- 移除：删掉改动与标记，把登记行的状态改为 `removed`，补丁小节保留作历史。

## 登记表

格式约定（`scripts/test_fork_patches.py` 按此解析）：

- 表格位于 `fork-patches:begin` 与 `fork-patches:end` 两行注释之间，表头固定为 `ID | 文件 | 标记 | 状态`。
- `ID` 形如 `GX-0001`；`文件` 是仓库相对的 POSIX 路径；`标记` 必须等于 `fork(gx): <ID>`；`文件` 与 `标记` 写在反引号里。
- `状态` 取 `active`（标记必须存在于该文件）或 `removed`（标记必须已从该文件消失）。
- 同一个 (ID, 文件) 只登记一行；每个 ID 在下文都有以 `## <ID>` 开头的小节。

<!-- fork-patches:begin -->
| ID | 文件 | 标记 | 状态 |
|---|---|---|---|
| GX-0001 | `src/build/Config.zig` | `fork(gx): GX-0001` | active |
| GX-0002 | `build.zig` | `fork(gx): GX-0002` | active |
| GX-0003 | `src/apprt.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/apprt/action.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/apprt/runtime.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/apprt/structs.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/apprt/surface.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/build/SharedDeps.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/config/Config.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/datastruct/split_tree.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/font/face.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/input/Binding.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/main_ghostty.zig` | `fork(gx): GX-0003` | active |
| GX-0003 | `src/terminal/mouse.zig` | `fork(gx): GX-0003` | active |
| GX-0004 | `src/renderer/OpenGL.zig` | `fork(gx): GX-0004` | active |
| GX-0004 | `src/renderer/opengl/Frame.zig` | `fork(gx): GX-0004` | active |
| GX-0005 | `src/Surface.zig` | `fork(gx): GX-0005` | active |
| GX-0005 | `src/termio/Exec.zig` | `fork(gx): GX-0005` | active |
| GX-0005 | `src/termio/Options.zig` | `fork(gx): GX-0005` | active |
| GX-0005 | `src/termio/Termio.zig` | `fork(gx): GX-0005` | active |
| GX-0005 | `src/termio/stream_handler.zig` | `fork(gx): GX-0005` | active |
| GX-0006 | `include/ghostty/vt/modes.h` | `fork(gx): GX-0006` | active |
| GX-0006 | `src/Surface.zig` | `fork(gx): GX-0006` | active |
| GX-0006 | `src/terminal/modes.zig` | `fork(gx): GX-0006` | active |
| GX-0006 | `src/terminal/snapshot/snapshot.ksy` | `fork(gx): GX-0006` | active |
| GX-0006 | `src/terminal/snapshot/terminal.zig` | `fork(gx): GX-0006` | active |
| GX-0006 | `src/terminal/stream_terminal.zig` | `fork(gx): GX-0006` | active |
| GX-0007 | `src/pty.zig` | `fork(gx): GX-0007` | active |
| GX-0008 | `src/os/hostname.zig` | `fork(gx): GX-0008` | active |
| GX-0008 | `src/termio/stream_handler.zig` | `fork(gx): GX-0008` | active |
| GX-0009 | `src/font/DeferredFace.zig` | `fork(gx): GX-0009` | active |
| GX-0009 | `src/font/backend.zig` | `fork(gx): GX-0009` | active |
| GX-0009 | `src/font/discovery.zig` | `fork(gx): GX-0009` | active |
| GX-0010 | `src/config/Config.zig` | `fork(gx): GX-0010` | active |
| GX-0011 | `src/apprt/gtk/App.zig` | `fork(gx): GX-0011` | active |
| GX-0011 | `src/apprt/gtk/build/gresource.zig` | `fork(gx): GX-0011` | active |
| GX-0011 | `src/apprt/gtk/class/application.zig` | `fork(gx): GX-0011` | active |
| GX-0011 | `src/apprt/gtk/class/surface.zig` | `fork(gx): GX-0011` | active |
| GX-0011 | `src/apprt/gtk/class/tab.zig` | `fork(gx): GX-0011` | active |
| GX-0011 | `src/apprt/gtk/class/window.zig` | `fork(gx): GX-0011` | active |
| GX-0012 | `src/Surface.zig` | `fork(gx): GX-0012` | active |
| GX-0012 | `src/termio/Exec.zig` | `fork(gx): GX-0012` | active |
| GX-0014 | `src/Surface.zig` | `fork(gx): GX-0014` | active |
| GX-0014 | `src/apprt/gtk/class/command_palette.zig` | `fork(gx): GX-0014` | removed |
| GX-0014 | `src/input/Binding.zig` | `fork(gx): GX-0014` | active |
| GX-0014 | `src/input/command.zig` | `fork(gx): GX-0014` | active |
| GX-0015 | `src/apprt/gtk/build/gresource.zig` | `fork(gx): GX-0015` | active |
| GX-0015 | `src/apprt/gtk/class/application.zig` | `fork(gx): GX-0015` | active |
| GX-0016 | `src/apprt/gtk/class/application.zig` | `fork(gx): GX-0016` | active |
| GX-0016 | `src/apprt/gtk/class/window.zig` | `fork(gx): GX-0016` | active |
| GX-0021 | `src/renderer/generic.zig` | `fork(gx): GX-0021` | active |
| GX-0022 | `src/terminal/Terminal.zig` | `fork(gx): GX-0022` | active |
| GX-0022 | `src/termio/Exec.zig` | `fork(gx): GX-0022` | active |
| GX-0026 | `src/build/GhosttyExe.zig` | `fork(gx): GX-0026` | active |
<!-- fork-patches:end -->

闭集：范围内的 Git 可见文件（已跟踪的文件，加上未跟踪但未被忽略的文件）中，每个 `fork(gx)` 都必须写成 `fork(gx): GX-NNNN`，且 (ID, 文件) 在表中为 `active`。新增补丁不登记，测试就会失败。

## GX-0001 非 v 前缀 tag 不再触发版本号 panic

- 文件：`src/build/Config.zig`，`Config.init` 版本推导块中检查 `vsn.tag` 的分支。
- 标记：`fork(gx): GX-0001`。
- 状态：active，未回馈上游。
- 改动量：改 1 行判断条件，加 2 行注释。

### 原因

fork 的发布 tag 是 `gx-vX.Y.Z`（见 `docs/RELEASE.md`）。未传 `-Dversion-string`、也不是作为依赖构建时，`src/build/Config.zig::init` 用 `src/build/GitVersion.zig::detect` 读取 HEAD 上的 tag（`git describe --exact-match --tags`）。上游规定：除 `tip` 外，任何 tag 都必须等于 `v<X.Y.Z>`，X.Y.Z 取自 `build.zig.zon`（源码包里取 `VERSION` 文件），否则 `@panic("tagged releases must be in vX.Y.Z format matching build.zig")`。

`build.zig` 的 `build()` 开头就调用 `Config.init`，所以 HEAD 打了 `gx-v*` tag 之后，连 `zig build --help` 都会 panic：开发者与 CI 在发布提交上做的任何未显式传版本串的构建都无法进行。

### 行为

| HEAD 上的 tag | 补丁前 | 补丁后 |
|---|---|---|
| 无，或 `tip` | 分支预发布版本 `X.Y.Z-<branch>+<hash>` | 不变 |
| `vX.Y.Z`，且与产品版本一致 | 正式版本 `X.Y.Z` | 不变 |
| 其他以 `v` 开头的 tag | panic | 不变，仍然 panic |
| 不以 `v` 开头的 tag，如 `gx-v0.0.1` | panic | 分支预发布版本 `X.Y.Z-<branch>+<hash>` |

- 传了 `-Dversion-string` 时直接使用它；作为依赖构建时跳过 git 推导。这两条路径都不受补丁影响，`gx-release` 的构建本来就显式传 `-Dversion-string=<X.Y.Z>-gx.<fork 版本>`。
- `<branch>` 来自 `git rev-parse --abbrev-ref HEAD`，其中不属于 `[0-9A-Za-z-]` 的字符替换为 `-`：在 `gx_ghostty` 分支上是 `gx-ghostty`，分离 HEAD（例如 CI 检出 tag）时是 `HEAD`。

### 上游状态

未回馈上游。上游只使用 `vX.Y.Z` 与 `tip` 两种 tag，这个补丁只服务 fork 的发布命名。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游改动这段版本推导时，先取上游版本，再按同一语义重新施加补丁：`tip` 与以 `v` 开头的 tag 保持上游行为，不以 `v` 开头的 tag 跳过发布校验、回退到分支预发布版本；保留 `fork(gx): GX-0001` 标记。之后跑下方的测试锁定与验证。如果上游已经不会因这类 tag panic，按「移除条件」处理。

### 移除条件

上游版本推导不再因非 `v` 前缀 tag panic（或不再从 tag 推导版本），并且去掉补丁后，下方验证的第一步仍然成功。移除时删除改动与标记，把登记行改为 `removed`，并删掉 `scripts/test_fork_patches.py` 中针对 GX-0001 的形状断言。

### 验证

先用 `just setup` 装好钉版 Zig。在仓库根目录（Git Bash 或 Linux shell；Linux/macOS 把 `python` 换成 `python3`）用临时 clone 加轻量 tag 复现：

```bash
git clone --quiet . .local/tmp/gx0001
cp src/build/Config.zig .local/tmp/gx0001/src/build/Config.zig
git -C .local/tmp/gx0001 tag gx-v0.0.0
(cd .local/tmp/gx0001 && python ../../../scripts/zigw.py build --help)
git show "$(git merge-base HEAD main):src/build/Config.zig" > .local/tmp/gx0001/src/build/Config.zig
(cd .local/tmp/gx0001 && python ../../../scripts/zigw.py build --help)
rm -rf .local/tmp/gx0001
```

- 第一次 `zig build --help` 使用带补丁的 `Config.zig`，应成功并列出构建选项。
- 第二次换回最近一次合入的上游版本（`HEAD` 与 `main` 的 merge-base 上的 `Config.zig`，`main` 只镜像上游），应 panic：`tagged releases must be in vX.Y.Z format matching build.zig`。
- clone 位于 gitignored 的 `.local/` 下，tag 只打在 clone 里，不影响本仓；`scripts/zigw.py` 不改变工作目录，所以构建的是 clone，用的是本仓钉版 Zig 与 `.local/zig-cache/global` 缓存。

### 测试锁定

`scripts/test_fork_patches.py` 随 `just framework-test` 运行；单独运行用 `python -m unittest scripts.test_fork_patches -v`。它锁定：

- 登记表格式合法，每个 active 标记都存在于对应文件；
- 闭集：范围内全部 `fork(gx)` 标记都已登记，所有 `begin`/`end` 分隔行成对出现、不嵌套；
- GX-0001 的形状：`Config.zig` 中只有一行 `std.mem.startsWith(u8, tag, "v")` 守卫，它与 `tip` 判断写在同一个条件里，紧邻其上有标记注释，位置在 `if (vsn.tag) |tag|` 之内、上游 panic 之前；上游的 `vX.Y.Z` 比较、panic 与分支预发布回退都原样保留。

## GX-0002 只安装、不运行测试二进制的构建步骤

- 文件：`build.zig`，`build.zig::build` 中的三个纯新增块：步骤声明区 `test-lib-vt-build` 之后、`// Zig module tests` 块末尾、`if (!config.emit_lib_vt)` 测试块里 `emit_test_exe` 安装之后。
- 标记：`fork(gx): GX-0002`，每块以 `// fork(gx): GX-0002 begin: <说明>` 开头、`// fork(gx): GX-0002 end` 结尾。
- 状态：active，未回馈上游。
- 改动量：新增 30 行（含 8 行注释），不改、不删上游行。

### 原因

上游 `test-lib-vt` 用 `b.addRunArtifact` 让构建系统运行 `ghostty-vt`、`ghostty-vt-c` 两个模块的测试二进制：两者可以并行编译（LLVM 各约 2 分钟），但每个二进制都在单个进程里按 Zig 测试运行器协议逐条串行执行，3559 + 3096 条用例各约 6 分钟单核，全量 `just test-vt` 墙钟 6–8 分钟，20 核基本空闲。`zig build` 不能把一个测试二进制拆到多个进程运行；上游也没有只安装测试二进制的步骤：`test-lib-vt-build` 只编译、不暴露产物路径，`-Demit-test-exe` 只在 `test` 步骤里顺带把 `ghostty-test` 装进 `zig-out/bin/`，仍会运行全部用例。

GX-0002 新增两个只编译并安装、不运行的步骤，把测试二进制放到固定路径，由 fork 的 `scripts/zig_test.py` 按测试运行器协议把用例分片到多个进程并行执行。

### 行为

| 步骤 | 编译 | 安装到（相对 `--prefix`，默认 `zig-out/`） |
|---|---|---|
| `test-lib-vt-bin` | `test-lib-vt` 运行的同两个测试二进制 | `test/vt/test`、`test/vt_c/test` |
| `test-bin` | `test` 运行的 `ghostty-test` | `test/ghostty-test` |

- Windows 上文件名带 `.exe`，旁边另装同名 `.pdb`。两个 lib-vt 测试二进制都叫 `test`，所以各占一个子目录。
- 安装的就是上游步骤运行的那个 `Compile` 产物：`-Dtest-filter`（编译期裁剪用例）、`-Doptimize`、`-Dtarget`、`-Dversion-string` 等选项照常生效，编译缓存与 `test-lib-vt`、`test-lib-vt-build`、`test` 共享。源码与选项不变时再次调用只做缓存校验，约 1 秒。
- 只编译、安装，不运行任何用例：步骤成功不代表测试通过。
- `test-bin` 与 `-Demit-test-exe` 一样对 `ghostty-test` 调 `config.addPatchElf`（只在 `-Dpatch-interp`、`-Dpatch-rpath` 时生效）。
- `-Demit-lib-vt` 时上游不构建 `ghostty-test`，`test` 是空步骤；`test-bin` 则依赖一个 `b.addFail` 步骤，以退出码 1 失败并提示 `ghostty-test is not built with -Demit-lib-vt`，免得调用方误用 `zig-out/test/` 里的旧二进制。这里不用上游惯用的 `Step.addError`：Zig 0.16 中它只打印消息、退出码仍为 0（上游 `update-translations` 在 i18n 关闭时就是这样）。
- 上游已有步骤（`test`、`test-lib-vt`、`test-lib-vt-build`、默认 `install` 等）的行为与产物不变，`zig build` 不会安装这些测试二进制。
- Windows：上游 `src/build/SharedDeps.zig::add` 对所有目标 translate-c `posix_c`（含 `pwd.h`，Zig 自带的 mingw 头文件也没有它），上游 `test` 在 Windows 上失败于 `'pwd.h' not found`。GX-0003 让 Windows 目标跳过这个导入之后，`test-bin` 能为 `x86_64-windows-gnu` 编译出 `zig-out/test/ghostty-test.exe`：2026-10-09 本机以 `-Dapp-runtime=win32` 编译并运行了全部 4133 条用例（结果见 `docs/TESTING.md`），GX-0006～GX-0008 的验证命令用的是 `-Dapp-runtime=none`。未写 ABI 的 Windows 目标（强制 MSVC）能否编译未验证。

调用方约定：先运行 `python scripts/zigw.py build test-lib-vt-bin` 或 `test-bin`（其余 `-D` 选项原样透传，退出码非 0 即失败），再从上表路径取二进制。它们是标准 Zig 测试运行器，只接受 `--listen=-`、`--seed=<n>` 与 `--cache-dir=<dir>`（仅 fuzz 构建需要），其他参数直接 panic：不带参数时串行运行全部用例；带 `--listen=-` 时走 `std.zig.Server` 协议，`query_test_metadata` 返回用例名，`run_test` 按序号运行单条用例。`zig build` 自己运行它们时传的是 `--cache-dir=<.zig-cache> --seed=0x<每次随机> --listen=-`。

### 上游状态

未回馈上游。上游 CI 直接用 `zig build test` 与 `test-lib-vt` 运行测试，这两个步骤只服务 fork 的分片运行器。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

三个块都是纯新增，只有块边界附近的上游行被改动时才会冲突。先取上游版本，再按原语义放回三个块：步骤声明放在 `test_lib_vt_build_step` 声明之后；lib-vt 安装放在 `// Zig module tests` 块里两个 `b.addTest` 之后；`ghostty-test` 安装放在 `if (!config.emit_lib_vt)` 测试块里 `const test_exe = b.addTest(...)` 之后。上游改名或重组这些测试对象（如 `mod_vt_test`、`mod_vt_c_test`、`test_exe`）时，同步调整块内引用与 `scripts/test_fork_patches.py::GX0002_HUNKS`，保持三个安装路径不变；路径非改不可时同步修改 `scripts/zig_test.py`。之后跑下方的测试锁定与验证。

### 移除条件

满足任一条即可移除：上游 `zig build` 能把单个测试二进制分片到多个进程并行运行，`just test-vt` 的墙钟与 `scripts/zig_test.py` 相当；或上游提供等价的「只安装测试二进制」步骤，`scripts/zig_test.py` 改用它。移除时删除三个块，把登记行改为 `removed`，删掉 `scripts/test_fork_patches.py` 中 GX-0002 的形状断言，并确认 `scripts/zig_test.py` 不再引用这两个步骤。

### 验证

在仓库根目录运行（Linux/macOS 用 `python3`）：

```bash
python scripts/zigw.py build --help             # 步骤列表含 test-bin 与 test-lib-vt-bin
python scripts/zigw.py fmt --check build.zig
python scripts/zigw.py build test-lib-vt-bin    # 产出 zig-out/test/vt/、zig-out/test/vt_c/ 下的 test(.exe)
python scripts/zigw.py build test-lib-vt-bin    # 全部命中缓存，约 1 秒
python scripts/zigw.py build test-bin           # Linux/macOS：产出 zig-out/test/ghostty-test
python -m unittest scripts.test_fork_patches -v
```

- 首次 `test-lib-vt-bin` 与 `test-lib-vt-build` 一样要编译两个测试二进制（约 2 分钟），之后只在源码或选项变化时重编。
- 想确认产物可用，就直接运行 `zig-out/test/vt/test`（全量串行），或交给 `scripts/zig_test.py` 分片运行。

### 测试锁定

除上节列出的登记表与闭集检查外，`scripts/test_fork_patches.py` 还锁定：

- 纯新增：删掉三个 GX-0002 块后，`build.zig` 与 `HEAD` 和 `main` 的 merge-base 上的上游版本（LF 归一化）完全相同；没有 `main` 时跳过。
- 形状（`GX0002_HUNKS`）：恰好三个块；`test-bin`、`test-lib-vt-bin` 两个步骤，`mod_vt_test` → `test/vt`、`mod_vt_c_test` → `test/vt_c`、`test_exe` → `test` 三个安装目录，步骤对安装的依赖、`addPatchElf` 与 `-Demit-lib-vt` 时的 `addFail`，都各自只出现在一个块里；三个块分别位于 `test_lib_vt_build_step` 声明之后、`mod_vt_c_test` 之后、`test_exe` 之后，且都在各自的上游区块之内。

## GX-0003 Windows 原生应用（win32 apprt）的构建与接线

- 文件：`src/apprt/runtime.zig`（`Runtime` 新增 `win32`，Windows 目标默认取它）、`src/apprt.zig`（导入并选中 `apprt/win32.zig`）、`src/build/SharedDeps.zig`（Windows 目标不再 translate-c `posix_c`；`.win32` 分支链接 Win32 系统库）、`src/main_ghostty.zig`（`logFn` 末尾把日志另写到文件）、`src/config/Config.zig`（`finalize` 的 apprt 分支、两处 GObject 分支、`quit-after-last-window-closed` 的 Windows 默认值），以及按 `app_runtime` 穷举的 GObject 分支：`src/apprt/action.zig`、`src/apprt/structs.zig`（两处）、`src/apprt/surface.zig`、`src/datastruct/split_tree.zig`、`src/font/face.zig`、`src/input/Binding.zig`、`src/terminal/mouse.zig`。
- 标记：`fork(gx): GX-0003`。纯新增块用 begin/end 包住（`runtime.zig` 两块、`apprt.zig` 两块、`SharedDeps.zig` 的链接块、`main_ghostty.zig` 的日志块）；改动的单行（各处 `.none => void` 改为 `.none, .win32 => void`、`posix_c` 守卫、`quit-after-last-window-closed` 默认值）上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：12 个文件，`git diff --numstat` 合计 +61/−15（含注释）。

### 原因

本 fork 要在 Windows 上产出可运行的原生应用。apprt 本体是新路径 `src/apprt/win32.zig` 与 `src/apprt/win32/**`（移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c，各文件头注明出处），不是源码补丁；但上游代码在三处把 apprt 集合写死，必须改上游文件才能接入：

- `src/apprt/runtime.zig::Runtime` 是 apprt 的闭集，`src/apprt.zig::runtime` 按它编译期选实现；多个类型的 `getGObjectType` 与 `Config.finalize` 对 `app_runtime` 穷举，新增成员不补分支就编译失败。
- `src/build/SharedDeps.zig::add` 对所有目标 translate-c `posix_c`（含 `pwd.h`），Windows 目标找不到该头文件，任何非 vt 产物都编不过；win32 apprt 还要链接 user32、gdi32 等系统库。
- GUI 子系统的 exe 没有控制台，`logFn` 写 stderr 的日志全部丢失；`quit-after-last-window-closed` 上游只在 Linux 默认开启，Windows 上关掉最后一个窗口后进程会无窗口地留在后台。

### 行为

- Windows 目标未给 `-Dapp-runtime` 时默认 `win32`，`zig build -Dtarget=x86_64-windows-gnu` 产出 `zig-out/bin/ghostty.exe`（`just build` 在 Windows 主机上自动补这个目标，见 `scripts/zig_build.py`）。Linux/FreeBSD 仍默认 `gtk`，其余目标仍默认 `none`。
- Windows 目标不再导入 `posix_c` 模块；与上游 PR #14608 的同一行守卫一致。非 Windows 目标不变。
- `.win32` 且目标是 Windows 时链接 opengl32、gdi32、user32、dwmapi、imm32、shell32、ole32、uxtheme、comctl32、comdlg32、advapi32，以及自绘界面（`src/apprt/win32/ui/d2d.zig` 的 Direct2D/DirectWrite 绑定）用的 d2d1、dwrite。
- win32 构建里每条日志额外追加到 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`（实现在 `src/apprt/win32/file_log.zig`，每次运行的首条日志时创建，上一次的日志改名为 `ghostty.log.1`）；Debug 构建写全部级别，其余构建与 stderr 一样不写 debug。其他 apprt 不受影响。
- `quit-after-last-window-closed` 在 Windows 上默认 `true`，与 Linux 一致；文档注释同步写明。其他平台默认值不变。
- 所有 GObject 分支在 win32 下与 `none` 一样取 `void`，`Config.finalize` 不加 win32 专属默认值。

### 上游状态

未回馈上游。上游没有 Windows apprt；`posix_c` 守卫与上游 PR #14608（未合入本次同步的上游 main）逐字相同，PR 合入后该行在同步时会以上游版本为准。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

先取上游版本，再按原语义放回：`Runtime` 的 `win32` 成员与 Windows 默认值；`apprt.zig` 的导入与 `.win32 => win32` 分支；各 `getGObjectType` 与 `Config.finalize` 的 `.none, .win32` 分支（上游新增按 `app_runtime` 穷举的 switch 时，同样补 `.win32`，编译 win32 目标会指出遗漏处）；`SharedDeps.add` 的 `.win32` 链接块；`logFn` 末尾的文件日志块；`quit-after-last-window-closed` 的默认值与文档注释。上游合入 PR #14608 后，`posix_c` 那一行若与本补丁相同，删除该处标记即可。

### 移除条件

上游提供原生 Windows apprt（或接受本 apprt）且其构建默认值、链接库、日志去向满足本 fork 时整体移除；`posix_c` 一处在上游合入相同守卫后单独移除。移除时删除改动与标记，把对应登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu   # 产出 zig-out/bin/ghostty.exe
python scripts/zigw.py build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none       # Linux 核心交叉编译不回归
python scripts/zigw.py build -Demit-lib-vt                                     # libghostty-vt 不回归
python -m unittest scripts.test_fork_patches -v
```

运行 `zig-out/bin/ghostty.exe`，窗口出现后检查 `%LOCALAPPDATA%\ghostty\logs\ghostty.log` 有 `runtime=.win32` 与 `loaded OpenGL` 行；关闭最后一个窗口后进程退出。GTK 构建需在装有 GTK 的 Linux 上验证。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）；没有形状断言。`src/termio/Exec.zig` 等 win32 运行时行为由 GX-0005 与 GUI 冒烟验证。

## GX-0004 OpenGL 渲染器在 Windows 上用 WGL

- 文件：`src/renderer/OpenGL.zig`（导入、`Device` 与 `egl_context` 两处类型、新增 `wgl_context` 字段，`init`、`deinit`、`threadEnter`、`threadExit`、`present` 开头各一个 Windows 分支，`ExportedFrame` 在 Windows 上为 `void`）、`src/renderer/opengl/Frame.zig`（`ExportedFrame` 为 `void` 时不再推送 `.redraw`）。WGL 实现在新路径 `src/renderer/opengl/wgl.zig`。
- 标记：`fork(gx): GX-0004`；纯新增块用 begin/end，三处改动的单行上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：2 个文件，`git diff --numstat` 合计 +51/−4（含注释）。

### 原因

上游的 OpenGL 后端只走 EGL：`opengl/Device.zig` 打开 surfaceless EGL display，每个 surface 的 EGL context 在主线程创建、在渲染线程 make current，帧离屏渲染后导出为 DMABUF 或 CPU 像素交给 GTK 合成，再推 `.redraw` 让 apprt 重绘。Windows 没有 EGL（构建也不编译 `glad_egl.c`），win32 apprt 把帧直接呈现到子窗口，需要 WGL。

### 行为

- Windows 上 `OpenGL.Device` 即 `wgl.Device`：进程启动时用一个隐藏的探测窗口载入 `wglCreateContextAttribsARB`、`wglChoosePixelFormatARB`、`wglSwapIntervalEXT`，并确认能建 OpenGL 4.3 core context；系统驱动不满足时改用 exe 同目录 `mesa\opengl32.dll`（Mesa llvmpipe），环境变量 `GHOSTTY_GX_OPENGL=software` 直接用 Mesa。两者都不可用时弹出说明对话框，`App` 初始化以 `DeviceFailed` 失败。
- apprt 为每个子窗口（`CS_OWNDC`）调用一次 `Device.setPixelFormat`，优先选 sRGB-capable 的双缓冲 RGBA8 格式。
- `OpenGL.init`（主线程）只记录 surface 的 HDC，不调用 GL；`threadEnter`（渲染线程）创建 4.3 core context、make current（NVIDIA 的线程化驱动在主线程显示或移动新窗口时会让 `wglMakeCurrent` 瞬时失败，所以最多重试 20 次、每次间隔 10 ms）、经 `wgl.getProcAddress`（`wglGetProcAddress` 加 DLL 导出回退）载入 glad、设 swap interval 1，并记日志 `loaded OpenGL X.Y vendor=… renderer=… software=…`；`threadExit` 释放并删除 context、卸载 glad。GL 调用仍只发生在渲染线程。
- `present` 关闭 `GL_FRAMEBUFFER_SRGB`，把 render target blit 到默认 framebuffer（尺寸不一致时按左上角对齐，其余区域清为透明黑），再 `SwapBuffers`；没有变化的帧不进入 `Frame.complete`，因而不交换缓冲。Windows 上 `ExportedFrame` 为 `void`，不导出帧、不推 `.redraw`。视口仍由渲染器的 resize 路径（`setViewport`）设置。
- 交换成功后调用 apprt 的 `signalFrameDrawn`（win32 apprt 在拖动改尺寸时最多等 16 ms 新帧）。驱动支持 `WGL_ARB_create_context_robustness` 时上下文按「重置即丢失」创建；GPU 重置（驱动超时恢复、驱动更新）后 `wgl.Context.present` 换上新上下文、调 apprt 的 `gpuContextReset` 让渲染器重建 GPU 资源，本帧以 `error.ContextLost` 放弃。这些都在新路径 `wgl.zig` 与 win32 apprt 里，补丁行不变。
- 非 Windows 目标的行为与产物不变。

### 上游状态

未回馈上游。上游 OpenGL 后端没有 WGL 路径。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

先取上游版本，再把各 Windows 分支放回对应函数开头（`init`、`deinit`、`threadEnter`、`threadExit`、`present`），恢复 `Device`、`egl_context`、`ExportedFrame` 三处类型选择与 `wgl_context` 字段、`Frame.complete` 里 `.redraw` 的守卫。上游改动这些函数的签名、`Device` 接口（`init`/`deinit`）或帧呈现协议时，同步调整 `src/renderer/opengl/wgl.zig`。

### 移除条件

上游提供 Windows 上可用的 OpenGL 呈现路径（WGL 或其他），且 win32 apprt 改用它之后移除；移除时删除改动、标记与 `wgl.zig`，把登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
python scripts/zigw.py build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none
python -m unittest scripts.test_fork_patches -v
```

运行 `zig-out/bin/ghostty.exe`：日志有 `loaded OpenGL 4.x vendor=… renderer=… software=false`，窗口正常渲染、缩放后重绘，Ctrl+Shift+T 新建的标签页同样渲染。把 Mesa 的 `opengl32.dll` 与 `libgallium_wgl.dll` 放进 `zig-out/bin/mesa/` 并以 `GHOSTTY_GX_OPENGL=software` 启动，日志应为 `software=true`、renderer 为 llvmpipe。GTK 的 EGL 路径需在 Linux 上验证。

### 测试锁定

只有登记表与闭集检查；`wgl.zig` 带一个版本串解析的单元测试。

## GX-0005 Windows 下的 termio 与核心修正

- 文件：`src/termio/Options.zig`、`src/termio/Termio.zig`、`src/termio/stream_handler.zig`（`renderer_wakeup` 改为指针）、`src/Surface.zig`（传入渲染线程自己的 `wakeup`；`resolvePathForOpening` 跳过 URL）、`src/termio/Exec.zig`（读线程的退出条件、退出管道的 Win32 句柄、Windows 的 `TERM`、shell 值的 Windows 命令行切分，及一条对应测试）。
- 标记：`fork(gx): GX-0005`；纯新增块用 begin/end，改动的单行上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：5 个文件，`git diff --numstat` 合计 +120/−17（含注释与一条测试）。

### 原因

win32 apprt 第一次让这些 Windows 分支真正运行，暴露出上游从未被执行过的问题：

- libxev 的 IOCP `Async` 把等待者记录在结构体内部；`Surface.init` 把渲染线程的 `wakeup` 按值复制给 termio，副本永远没有等待者，`notify` 只置位、唤不醒渲染线程，终端输出不重绘。
- `Exec` 的读线程遇到 `ReadFile` 的其他错误（子进程退出后 ConPTY 关闭管道）与 `PeekNamedPipe` 失败时执行 `unreachable`；退出管道是 `CreatePipe` 得到的 Win32 句柄，却用 CRT 的 `write`/`close` 操作，UCRT 对无效描述符会触发参数校验并终止进程。
- 找到资源目录时 `TERM` 设为 `xterm-ghostty` 并把 `TERMINFO` 指向 Windows 路径，Windows 上的程序（MSYS2/Git Bash 的 ncurses、各类原生 TUI）没有这个 terminfo 条目。
- 带参数的 shell 值按空白切分，`"C:\Program Files\…\bash.exe" -l` 这类带引号的路径无法使用。
- `resolvePathForOpening` 把 `https://…` 之类的 URL 交给 `std.fs.path.resolve`，Windows 上会命中断言。

### 行为

- `termio.Options`、`Termio`、`StreamHandler` 持有 `*xev.Async`，指向 `Surface.renderer_thread.wakeup`；所有平台语义不变。
- Windows 读线程在 `BROKEN_PIPE`、`HANDLE_EOF`、`PIPE_NOT_CONNECTED` 与零字节读时记 info 后退出，其他读错误与退出管道检查失败记 error 后退出，不再崩溃；子进程退出由 libxev 的进程监视（IOCP job object）照常上报。退出管道在 Windows 上用 `WriteFile`/`CloseHandle`。
- Windows 上 `TERM=xterm-256color`、`COLORTERM=truecolor`，不设 `TERMINFO`；`TERM_PROGRAM`、`TERM_PROGRAM_VERSION` 等不变。用户仍可用 `env` 配置覆盖。
- Windows 上带参数的 shell 值按 C 运行时的命令行规则（`std.process.Args.Iterator.Windows`）切分，支持双引号；不带空白的值与 direct 形式不变。
- 含 `://` 的字符串不再作为相对路径解析。

### 上游状态

未回馈上游。这些分支只在 Windows apprt 存在时才会运行；如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

先取上游版本，再按上述语义放回各处；上游若改用别的唤醒机制、重写读线程或 shell 切分，以上游实现为准并确认 Windows 上同样成立（GUI 冒烟：输出能刷新、`exit` 后窗口关闭、带引号的 `command` 能启动）。

### 移除条件

上游修正同一批问题（按指针传递唤醒句柄、读线程正常退出、Windows 句柄的退出管道、Windows 的 `TERM` 与命令行切分、URL 不按路径解析）后逐项移除，删除改动与标记并把对应登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
python scripts/zigw.py build -Dtarget=x86_64-linux-gnu -Dapp-runtime=none
python -m unittest scripts.test_fork_patches -v
```

运行 `zig-out/bin/ghostty.exe`：输入命令后输出立即刷新；在 cmd 里 `exit` 后日志有 `child process exited` 与 `read thread got quit signal`，窗口关闭且没有崩溃；`ghostty.exe --command="\"C:\Program Files\PowerShell\7\pwsh.exe\" -NoLogo"` 能启动。`execCommand windows:` 用例随 `ghostty-test` 在 Windows 目标上运行。

### 测试锁定

只有登记表与闭集检查；`src/termio/Exec.zig` 新增 `execCommand windows: quoted path with spaces stays one argument` 用例。

## GX-0006 win32-input-mode（DECSET 9001）

- 文件：`src/terminal/modes.zig`（`entries` 末尾追加 `win32_input_mode`，值 9001，另加一条单测）、`include/ghostty/vt/modes.h`（`GHOSTTY_MODE_WIN32_INPUT`）、`src/terminal/snapshot/terminal.zig`（模式位登记表与编码注释改为 44 位，`TERMINAL mode bit layout` 单测改为 44 位并检查第 43 位）、`src/terminal/snapshot/snapshot.ksy`（`mode_set` 的说明、`valid.max` 与新实例）、`src/terminal/stream_terminal.zig`（一条经解析流的 DECSET/DECRQM 单测）、`src/Surface.zig`（导入、`gx_win32_key` 字段、`gxWin32KeyCallback` 入口、`encodeKey` 开头的分流）。编码器、记录构造与 apprt 接入契约在新路径 `src/gx/win32_input.zig`。
- 标记：`fork(gx): GX-0006`；纯新增块用 begin/end 包住，改动的上游行（快照的登记表、编码注释与单测位宽，ksy 的说明与上限）上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：6 个文件，`git diff --numstat` 合计 +136/−13（含注释与单测）。

### 原因

ConPTY 启动时向宿主终端发送 `CSI ? 9001 h`（Windows Terminal 定义的 win32-input-mode），关闭时发送 `CSI ? 9001 l`（microsoft/terminal `src/host/VtIo.cpp`）。终端支持该模式时，每次按下与抬起（修饰键也算）都以完整的 KEY_EVENT_RECORD 交给 ConPTY，控制台程序（PSReadLine、herdr 等）才能区分 Shift+Enter、Ctrl+Space、Ctrl+Break、单独的修饰键与按键抬起；否则 ConPTY 只能从 VT 序列反推，信息有损。上游 Ghostty 不认识 9001：日志记 `unimplemented mode: 9001`，DECRQM 报告未识别。模式表 `entries` 是 `Mode`、`ModePacked`、DECRQM 与 XTSAVE 的唯一来源，只能改上游文件；快照把 `ModePacked` 的位序当作线格式登记表，必须同步；按键编码的入口在 `Surface.encodeKey`。

### 行为

- `CSI ? 9001 h/l` 设置与清除 `win32_input_mode`，DECRQM（`CSI ? 9001 $ p`）报告 1 或 2，XTSAVE/XTRESTORE 与 RIS 与其他模式相同；DECSTR 不改它（Ghostty 的 DECSTR 只复位固定的几个模式）。C API 用 `GHOSTTY_MODE_WIN32_INPUT` 查询与设置；libghostty-vt 只记录模式，不提供 Win32 按键编码。
- 快照：`ModePacked` 由 43 位变为 44 位（仍是 8 字节），新模式占第 43 位，即上游 v1 里恒为 0、解码时被忽略的保留位。第 0–42 位不变，所以上游写的快照在 fork 里解码后该位为 0，上游解码器读 fork 的快照时丢弃该位，现有金样全部不变。上游注释要求新增模式时升快照版本，fork 不升：解码器只认单一版本，升版要为全部 v1 金样另建新版本并在每次同步时冲突，而上面两个方向本来就兼容；快照格式 v1 也明确不承诺稳定，应用本身不持久化快照。
- 编码（`src/gx/win32_input.zig`）：每条记录写成 `CSI Vk;Sc;Uc;Kd;Cs;Rc _`，六个参数总是写全（与 Windows Terminal `TerminalInput::_makeWin32Output` 相同，herdr 的 `parse_win32_input_mode_key_record` 也要求六个）。Uc 是一个 UTF-16 码元，按键产生多个码元时每个码元一条记录；死键 Uc=0；Cs 是 dwControlKeyState 的低 16 位，ENHANCED_KEY 取自 lParam 第 24 位；Sc 取 lParam 第 16–23 位；Rc 取 lParam 低 16 位（0 按 1）。没有按键的文字（WM_CHAR、输入法结果）每个码元一对 VK=0、Sc=0 的按下与抬起记录。kitty 键盘协议标志非 0 时让位给 kitty 编码，与 Windows Terminal 相同（ConPTY 从不关闭 9001）。
- 分流：`Surface.gxWin32KeyCallback(event, message)` 把本次事件的 Win32 消息记进 `gx_win32_key`，再调用原 `keyCallback`；`encodeKey` 开头的 `gx_win32_input.surfaceWriteReq` 只在「事件与记录匹配、子进程未退出、9001 已开且没有 kitty 标志」时用记录替换常规编码，否则照常编码。apprt 只调用 `keyCallback` 时（GTK、macOS 的 embedded apprt）行为与上游完全相同。绑定、按键序列、KAM、只读模式、滚动到底与清除选区都沿用 `keyCallback`；绑定执行期间产生的其他按键事件（例如失焦时补发的抬起）与记录不匹配，走常规编码；关闭表面的绑定返回 `.closed` 后不再触碰表面。
- win32 apprt 已按下述契约接入（新路径 `src/apprt/win32/Surface.zig` 的 `handleKeyEvent`、`handleCharEvent`、`sendImeText`；契约写在 `src/gx/win32_input.zig` 文件头）：`handleKeyEvent` 对每条 WM_KEYDOWN/WM_SYSKEYDOWN/WM_KEYUP/WM_SYSKEYUP（VK_PROCESSKEY、VK_PACKET 仍提前返回）读取 `GetKeyboardState`，构造 `KeyMessage{ .vk = wParam, .lparam, .down, .state = .fromKeyboardState(&keyboard_state), .text, .dead }`，其中 `text` 是 ToUnicode 的原始 UTF-16 输出（含 Ctrl+C 的 0x03 这类控制字符；抬起时用 wFlags 0x4 不消耗死键状态再译一次，或留空），ToUnicode 返回负数时 `dead = true`，然后改调 `core_surface.gxWin32KeyCallback(event, message)`；`handleCharEvent`（WM_CHAR）与 `sendImeText`（输入法结果）改调 `gxWin32KeyCallback(event, null)`；粘贴与拖放文件保持原样发原始文本（与 Windows Terminal 相同）。记录经常规的 `Surface.queueIo` 写入 pty，apprt 不直接写 pty。

### 上游状态

未回馈上游。上游没有 Windows 运行时，也不识别 win32-input-mode。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

- `entries` 里的 fork 块保持在最后：上游在末尾新增模式时，把上游条目放在 fork 块之前，`win32_input_mode` 顺延一位，并同步快照登记表注释、编码注释、ksy 的说明、实例除数与 `valid.max`、`TERMINAL mode bit layout` 单测的位宽与位号（fork 快照里该位随之移动，v1 不承诺兼容）。上游若升了快照版本，按新版本重新检查保留位与金样。
- 上游自己支持 9001 时，删掉 fork 的条目、宏与快照改动，`src/gx/win32_input.zig::active` 改用上游的模式名。
- `Surface.keyCallback`、`encodeKey` 被上游重构时，保持两点：编码前先问 `gx_win32_input.surfaceWriteReq`；`gxWin32KeyCallback` 包住 `keyCallback`，返回 `.closed` 后不碰表面。

### 移除条件

上游实现 win32-input-mode（识别 9001 并在按键编码中输出 KEY_EVENT_RECORD）之后移除：删除各处改动与标记，把登记行改为 `removed`，win32 apprt 改用上游接口。

### 验证

```bash
python scripts/zig_test.py --suite vt --filter 9001 --filter "mode bit layout" --filter modes --filter DECRQM --filter "TERMINAL header"
python scripts/zigw.py build test-bin -Dtarget=x86_64-windows-gnu -Dapp-runtime=none
python scripts/zig_test.py --no-build --binary zig-out/test/ghostty-test.exe --filter gx.win32_input
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
python -m unittest scripts.test_fork_patches -v
```

- 第一条在 `ghostty-vt`、`ghostty-vt-c` 两个模块里运行模式、DECRQM 与快照单测；全量 `just test-vt` 同样覆盖。Linux 上主套件用 `python3 scripts/zig_test.py --suite main -Dapp-runtime=none --filter gx.win32_input`。
- 运行 `ghostty.exe` 并启动任意 shell：日志不再出现 `unimplemented mode: 9001`。按键改走记录要在 GUI 里验证（PSReadLine 的 Shift+Enter、GX Zsh 的 herdr 探针）；Windows 本机也可用 `just test --filter gx.win32_input` 跑编码单测。

### 测试锁定

登记表与闭集检查之外，`src/terminal/modes.zig` 与 `src/terminal/stream_terminal.zig` 各一条单测锁定 9001 的识别、DECRQM 与复位，`TERMINAL mode bit layout` 锁定位序；`src/gx/win32_input.zig` 的单测锁定编码（Ctrl+C 向量 `ESC[67;46;3;1;8;1_ESC[67;46;3;0;8;1_`、规范里的 Shift+A 与 Ctrl+F1、AltGr、ENHANCED_KEY、重复计数、死键、代理对、VK=0 文字）与分流条件。

## GX-0007 优先使用随包 ConPTY

- 文件：`src/pty.zig`（导入与 `WindowsPty.gx_conpty` 字段两个纯新增块；`open`、`deinit`、`setSize` 三处调用改为经 `gx_conpty.Instance`）。实现在新路径 `src/gx/conpty.zig`。
- 标记：`fork(gx): GX-0007`；纯新增块用 begin/end 包住，三处改动的调用上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：1 个文件，`git diff --numstat` 合计 +12/−5（含注释）。

### 原因

Windows 自带的 ConPTY（kernel32 `CreatePseudoConsole` 加 System32 的 conhost.exe）随系统版本冻结，落后 microsoft/terminal 的开源实现多个版本。微软的 NuGet 包 `Microsoft.Windows.Console.ConPTY` 提供新版：`conpty.dll` 以 `ConptyCreatePseudoConsole`、`ConptyResizePseudoConsole`、`ConptyClosePseudoConsole` 导出与 kernel32 同签名的函数，并从自身目录启动 `OpenConsole.exe`（缺失时静默退回系统 conhost.exe）。上游 `WindowsPty` 直接调用 kernel32，而伪控制台必须由创建它的实现缩放和关闭，所以 `WindowsPty` 要记住所用的实现。

### 行为

- `WindowsPty.open` 调 `gx_conpty.Instance.create`：exe 同目录同时存在 `conpty.dll` 与 `OpenConsole.exe`、且环境变量 `GHOSTTY_GX_CONPTY` 不是 `system` 时，以绝对路径 `LoadLibraryExW` 载入 `conpty.dll`（它的依赖只在 DLL 目录与 System32 查找）并取三个导出；缺 `OpenConsole.exe`、载入失败、导出缺失或创建失败时退回 kernel32。`GHOSTTY_GX_CONPTY=system`（不区分大小写）强制用系统 ConPTY；空值或 `bundled` 为默认；其他值记 warning 后按默认处理。
- flags：随包 ConPTY 用 `PSEUDOCONSOLE_RESIZE_QUIRK | PSEUDOCONSOLE_WIN32_INPUT_MODE`（0x6）。1.22 起的 conpty.dll 总是这样工作并忽略这两位（其 `src/winconpty/winconpty.cpp` 只解析 INHERIT_CURSOR 与 GLYPH_WIDTH 的 0x18 两组），所以对 1.24 无害，只对更老的 conpty.dll 生效；系统 ConPTY 保持上游的 0。`PSEUDOCONSOLE_INHERIT_CURSOR`（0x1）不开：宿主会在启动时发 `CSI 6 n` 并等终端回答光标位置。实测临时加上 0x1 时 OpenConsole 以 `--inheritcursor` 启动，Ghostty 正确回答，启动耗时与输入都正常；但每个表面启动时屏幕为空、光标在原点，没有可继承的位置，旧宿主得不到回答时还会无限期阻塞输入，Windows Terminal 默认也不开。
- 每个伪控制台记住创建它的实现（`WindowsPty.gx_conpty`），缩放与关闭都走同一实现，关闭后释放这次 `LoadLibraryExW` 的引用。`HPCON` 照常交给 `src/Command.zig` 的 `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`（conpty.dll 的伪控制台结构与 kernelbase 相同，Windows Terminal 也这样用）。
- 每次创建记一条 info 日志：`ConPTY: bundled <路径> flags=0x6`，或 `ConPTY: system (kernel32) flags=0x0, <原因>`（例如 `conpty.dll is not next to the executable`、`GHOSTTY_GX_CONPTY=system`）；随包实现失败时另记 warning。
- 文件布局：`conpty.dll` 与 `OpenConsole.exe` 成对来自同一个包版本，与 `ghostty.exe` 平铺在同一目录（x64 取包内 `runtimes/win-x64/native/conpty.dll` 与 `build/native/runtimes/x64/OpenConsole.exe`）。本补丁不改构建：`just build` 不放这两个文件，开发构建因此走系统 ConPTY；便携包与安装包由 `scripts/gx_windows_package.py` 按 `PAYLOAD` 里钉死的 sha256 放进去。

### 上游状态

未回馈上游。上游 Windows pty 只用系统 ConPTY。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游改动 `WindowsPty` 的创建、缩放或关闭时，取上游版本后保持：创建由 `gx_conpty.Instance.create` 完成并存进 `gx_conpty`，缩放与关闭用同一实例。上游自己支持可替换的 ConPTY 时按移除条件处理。

### 移除条件

上游 Windows pty 支持随包 ConPTY，或 Ghostty GX 不再随包分发 ConPTY 时移除：删除改动与标记，把登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -p <prefix>
python scripts/zigw.py build test-bin -Dtarget=x86_64-windows-gnu -Dapp-runtime=none
python scripts/zig_test.py --no-build --binary zig-out/test/ghostty-test.exe --filter gx.conpty --filter pty.test
python -m unittest scripts.test_fork_patches -v
```

把 NuGet 包 1.24.261001001 的 x64 `conpty.dll` 与 `OpenConsole.exe`（sha256 钉在 `scripts/gx_windows_package.py::PAYLOAD`；最省事的来源是 `just package-windows` 产出的便携 zip）复制到 `<prefix>\bin\` 后运行 `ghostty.exe`：日志为 `ConPTY: bundled …\conpty.dll flags=0x6`，shell 的父进程是 `OpenConsole.exe`；删掉 `OpenConsole.exe` 或设 `GHOSTTY_GX_CONPTY=system` 后为 `ConPTY: system (kernel32) …`。上游的 `pty.test_0`（open 与 resize）在 Windows 测试二进制里经同一入口走系统 ConPTY。

### 测试锁定

只有登记表与闭集检查；`src/gx/conpty.zig` 的单测锁定 `GHOSTTY_GX_CONPTY` 的解析、同目录路径拼接与 flags 取值。

## GX-0008 Windows 上解析 OSC 7 工作目录

- 文件：`src/termio/stream_handler.zig`（导入；`reportPwd` 去掉 Windows 的提前返回，缺主机名按空主机名处理，解码后的路径经 `gx_osc7.nativePath`）、`src/os/hostname.zig`（`isLocal` 接受空主机名；Windows 上不区分大小写并接受 DNS 主机名；两条单测）。路径转换在新路径 `src/gx/osc7.zig`。
- 标记：`fork(gx): GX-0008`；纯新增块用 begin/end 包住，改动的上游行上一行写单行标记，删去的 Windows 提前返回处留一行单行标记。
- 状态：active，未回馈上游。
- 改动量：2 个文件，`git diff --numstat` 合计 +58/−10（含注释与单测）。

### 原因

`StreamHandler.reportPwd` 在 Windows 上直接返回（日志 `reportPwd unimplemented on windows`），终端从不记录 shell 报告的工作目录，新标签页、分屏与窗口只能继承启动目录。Windows shell 报告的形式也与 POSIX 不同：GX Zsh 发 `file://localhost/C:/…`（百分号编码；本机已安装的旧版发 `file:///cygdrive/c/…`），herdr 发 `file://<大写的 COMPUTERNAME>/C:/…`，MSYS2 系的 shell 可能发 `/c/…`；而 `hostname.isLocal` 区分大小写，并拒绝空主机名（`file:///C:/…`）。

### 行为

- 所有平台：`file:///path`（以及没有 authority 的 `file:/path`）的空主机名视为本机，`isLocal("")` 返回 true；`localhost` 与其他平台上的主机名比较不变。
- Windows：主机名与 `GetComputerNameA`（NetBIOS 名）或 `GetComputerNameExA(ComputerNameDnsHostname)`（DNS 主机名，MSYS2 `hostname` 打印的那个）不区分大小写地比较。
- Windows：URI 路径照常百分号解码（`kitty-shell-cwd://` 照常不解码），再由 `src/gx/osc7.zig::windowsPath` 转成本机路径：`/C:/Users/x`、`/c/Users/x` 与 Cygwin 的 `/cygdrive/c/Users/x` 都变成 `C:\Users\x`，`/C:`、`/c`、`/cygdrive/c` 变成 `C:\`；盘符转大写，`/` 与 `\` 都算分隔符，重复与末尾的分隔符去掉。相对路径、UNC 与设备路径（`//server/share`、`//?/…`）、POSIX 路径（`/home/me`、`/mnt/c/…`）、盘符相对路径（`/C:x`）以及含控制字符或 `<>:"|?*` 的路径记 warning 后忽略，pwd 不变。
- 之后与其他平台相同：`Terminal.setPwd`、`pwd_change` 消息、没有标题时以路径为标题。新表面的继承不需要 apprt 改动：`apprt.surface.newConfig` 取 `App.focusedSurface()` 的 `Surface.pwd`，按 `window-/tab-/split-inherit-working-directory`（默认都开）写进 `working-directory`；`termio.Exec` 能访问该目录时把它作为 `CreateProcessW` 的当前目录并设 `PWD`，不能访问时记 warning 后用默认目录。win32 apprt 新建标签页、分屏与窗口时已用对应的 `context` 调 `newConfig`，并在获得焦点时调 `focusCallback(true)`，所以 OSC 7 报告之后新建的表面直接从该目录启动。
- libghostty-vt 的 `stream_terminal.Handler.reportPwd` 原样保存 URL、由嵌入方解码，不受影响。

### 上游状态

未回馈上游。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游实现 Windows 上的 OSC 7 时以上游为准，确认 `localhost`、空主机名、大写主机名与 `/C:/…`、`/c/…` 的行为后删除对应改动。上游改写 `reportPwd` 的解析步骤时保持：主机检查之后、`setPwd` 之前把解码后的路径交给 `gx_osc7.nativePath`。

### 移除条件

上游在 Windows 上把 OSC 7 路径转成本机路径，且 `isLocal` 接受空主机名并在 Windows 上不区分大小写之后移除：删除改动与标记，把登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build test-bin -Dtarget=x86_64-windows-gnu -Dapp-runtime=none
python scripts/zig_test.py --no-build --binary zig-out/test/ghostty-test.exe --filter gx.osc7 --filter os.hostname
python -m unittest scripts.test_fork_patches -v
```

Linux 上用 `python3 scripts/zig_test.py --suite main -Dapp-runtime=none --filter gx.osc7 --filter os.hostname`。GUI：在 pwsh 中运行 ``Write-Host -NoNewline "`e]7;file://localhost/C:/Windows`a"`` 后按 Ctrl+Shift+T，新标签页从 `C:\Windows` 启动；GX Zsh 与 herdr 的报告同样生效。

### 测试锁定

登记表与闭集检查之外：`src/gx/osc7.zig` 的单测锁定路径转换与拒绝规则，并在 Windows 上把 GX Zsh、herdr、MSYS、kitty 形式的 URL 走一遍与 `reportPwd` 相同的解析、主机检查与转换；`src/os/hostname.zig` 新增空主机名与 Windows 大小写两条单测（`src/os/main.zig` 不引用该文件的单测，由 `src/gx/osc7.zig` 引入）。

## GX-0009 Windows 字体发现改用 DirectWrite

- 文件：`src/font/discovery.zig`（`Discover` 在 `freetype_windows` 下取 `DirectWrite`；纯新增块导出 `DirectWrite` 并把 `src/font/directwrite/match.zig` 的单测接进测试树）、`src/font/DeferredFace.zig`（`familyName`、`name` 的 `freetype_windows` 分支改用 FreeType 解码的族名与样式名）、`src/font/backend.zig`（`freetype_windows` 的文档注释与 `Backend.default` 的注释）。实现在新路径 `src/font/directwrite/`：`com.zig`（DirectWrite COM 与所需 GDI、kernel32 函数的绑定）、`discovery.zig`（发现逻辑）、`match.zig`（与平台无关的样式匹配，带单测）；移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c，文件头注明出处。
- 标记：`fork(gx): GX-0009`。`discovery.zig` 的纯新增块用 begin/end 包住，其余改动的上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：3 个文件，`git diff --numstat` 合计 +21/−9（含注释）。

### 原因

上游 `freetype_windows` 后端的发现是 `src/font/discovery.zig::Windows`：每次 `discover` 都遍历 `%SYSTEMROOT%\Fonts` 与 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`，用 FreeType 打开文件比较族名。

- `matches` 不看粗体、斜体：同一族里按文件名排序第一个命中的文件被用作所有样式。实测 `font-family = "Cascadia Code"` 的四种样式都是可变字体的默认实例（粗体显示为常规），`JetBrainsMono NF` 四种样式都是 `-Bold.ttf`（整屏粗体）；因为每种样式都「找到了」，`completeStyles` 也不会合成，只有常规体的字体（如 Lucida Console）没有粗斜体。
- 族名只比 FreeType 的英文族名与 SFNT 第一条族名记录，`微软雅黑`、`宋体` 这样的本地化族名找不到。
- 只看两个目录：注册表里登记在其他路径的字体（GX Shell 的 `{app}\fonts\*.ttf`、WPS 的 `C:\ProgramData\Kingsoft\...`）、应用包随附的字体（如 Windows Terminal 包里的 `CascadiaCodeItalic.ttf`）、`AddFontResourceEx` 加载的字体都看不到。
- 按码位回退时逐个打开文件直到找到含该码位的字体，按字母序取第一个（`中` 取到 DengXian），找不到的码位要打开全部文件；缺失的族名在启动时每种样式各扫描一遍全部文件。

### 行为

- 族名查找：先用 DirectWrite 系统字体集合 `FindFamilyName`（匹配所有语言的族名；集合包含系统与每用户字体目录、注册表 HKLM/HKCU `Fonts` 中任意路径的字体、应用包字体）；找不到时用 GDI `EnumFontFamiliesExW` 按 GDI 族名查找（覆盖 `AddFontResourceEx` 加载的字体与 `Segoe UI Semibold` 这类 GDI 旧族名），经 `IDWriteGdiInterop::CreateFontFaceFromHdc` 取得字体文件。空族名、非法 WTF-8 视为找不到。
- 样式匹配（`src/font/directwrite/match.zig::select`）：跳过 DirectWrite 模拟出的粗体、斜体变体；只保留宽度最接近 normal 的字面；按 CSS Fonts 4 的顺序比较宽度、倾斜、字重。粗体请求只接受至少 semibold 且比该族常规字面更重的字面，斜体请求只接受 italic 或 oblique 字面；没有真实字面时返回空，由 `Collection.completeStyles` 按 `font-synthetic-style` 合成。`font-style*` 指定样式名时按各语言的字面名精确或包含匹配，忽略粗斜体。
- 可变字体：DirectWrite 把每个命名实例列为同一文件的字面，发现按 `IDWriteFontFace5` 报告的轴值找到坐标相同的 FreeType 命名实例，把实例号编进 `DeferredFace.Windows.face_index` 的高 16 位，`load` 时 FreeType 直接打开该实例；用户的 `font-variation*` 照常叠加。
- 按码位回退：先用系统字体回退 `IDWriteFontFallback::MapCharacters`（按用户区域设置选字，`中` 在 zh-CN 下得到 Microsoft YaHei UI）；该字体被调用方拒绝（例如表现形式不符）或系统回退无结果时，再检查每个族的第一个字面，取覆盖该码位的族的常规字面。`font-codepoint-map` 照常先按族名查找，族不存在时记 warning 后走同一回退。
- `+list-fonts`：不带 `--family` 时列出集合中全部真实字面（同一字体装在多处只列一次）及只有 GDI 知道的字体；`DeferredFace.name` 在本后端返回 FreeType 解码的「族名 样式名」（如 `Cascadia Code Bold`），`familyName` 返回 FreeType 族名，不再输出上游 `Face.name` 原样返回的 UTF-16BE 字节。GUI 子系统的 exe 只在标准输出被重定向或接管道时可见输出（cmd 的 `>`、`|` 与直接运行、Git Bash 均可；PowerShell 需 `| Out-String`，赋值给变量或 `>` 会遇到 `PIPE_CLOSING`，与本补丁无关）。
- 字体文件仍由 FreeType 打开：路径含 ANSI 代码页以外的字符时改用 8.3 短路径（FreeType 在 Windows 上用 `CreateFileA`）；不是本地文件的字体（内存、远程字体）跳过。FreeType 栅格化、HarfBuzz shaping 不变。
- DirectWrite 初始化失败时记 warning，回退到原目录扫描 `discovery.Windows`。非 Windows 后端的行为与产物不变。

### 上游状态

未回馈上游。上游 `freetype_windows` 由 Yasuhiro Matsumoto 的 PR 加入（提交 `61fce4d0a`），注释里提到将来可用 DirectWrite 替换。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

先取上游版本，再放回：`Discover` 的 `.freetype_windows => DirectWrite` 一行与其标记、导出 `DirectWrite` 并引用 `match.zig` 单测的 begin/end 块（放在 `pub const Windows` 之前）、`DeferredFace` 两处 `freetype_windows` 分支、`backend.zig` 的两处注释。上游若改动 `DeferredFace.Windows` 的字段、`Descriptor`、`Discover` 的接口（`init`、`deinit`、`discover`、`discoverFallback`、迭代器的 `next`/`deinit`）或 `discovery.Windows` 的接口，同步调整 `src/font/directwrite/discovery.zig`。上游若自己改用 DirectWrite 发现，按「移除条件」处理。

### 移除条件

上游的 Windows 字体发现满足本补丁的行为（真实粗斜体、本地化族名、注册表与 GDI 字体、系统字体回退）时移除：删除三处改动、标记与 `src/font/directwrite/`，把登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
python scripts/zigw.py test src/font/directwrite/match.zig   # 样式匹配单测，任何平台
python scripts/zigw.py test src/font/directwrite/com.zig     # Windows：COM 绑定的集合查找与系统回退
python -m unittest scripts.test_fork_patches -v
```

用临时 `LOCALAPPDATA` 运行 `zig-out/bin/ghostty.exe --font-family="Cascadia Code"`，在 pwsh 里输出 SGR 1/3 文本（测试进程不要继承 `NO_COLOR`，否则 pwsh 去掉转义序列），粗体、斜体、粗斜体应分别是真实字面，日志有 `font bold: Cascadia Code Bold` 等行；`--font-family=微软雅黑` 应找到 Microsoft YaHei 并合成斜体；`ghostty.exe +list-fonts --family="Cascadia Code" --bold > out.txt` 应列出 Bold、SemiBold。Linux 上 `match.zig` 的单测随 `ghostty-test` 运行，`just wsl test --filter directwrite`。

### 测试锁定

登记表与闭集检查锁定标记；`src/font/directwrite/match.zig` 的单测锁定字重、宽度、倾斜排序，粗斜体真实字面的判定，样式名匹配与命名实例选择，经 `discovery.zig` 的测试块进入所有平台的 `ghostty-test`；`com.zig` 的两条用例只在 Windows 运行；`directwrite/discovery.zig` 的两条端到端用例（Arial 四种样式、按码位回退）随 Windows 上的 `ghostty-test` 运行（`just test --filter directwrite`）。

## GX-0010 Ghostty GX 配置分层与 fork 配置键

- 文件：`src/config/Config.zig`，五处：`language` 字段的文档注释（单行标记，改写上游注释）；字段区末尾 `auto-update-channel` 之后的纯新增块（5 个 `gx-*` 键）；`deinit` 与 `load` 之间的纯新增块（导入 `src/gx/config_layers.zig`、`src/gx/config_types.zig`，`pub fn gxReplay`，引入 `src/gx/**` 单测的 `test` 块）；`Config.load` 函数体开头的纯新增块（启用时转交 `src/gx/config_layers.zig::load`）；`Replay.Iterator.next` 处理 `.diagnostic` 步骤处的纯新增块（把诊断重新记入 `_replay_steps`）。
- 标记：`fork(gx): GX-0010`；四个纯新增块以 `// fork(gx): GX-0010 begin: <说明>` 开头、`// fork(gx): GX-0010 end` 结尾，`language` 注释上方是单行标记。
- 状态：active，未回馈上游。
- 改动量：改写 `language` 的 18 行文档注释为 25 行；新增约 105 行（键与文档约 80 行、钩子、包装与诊断重放约 25 行），不改、不删其他上游行。

### 原因

Ghostty GX 要在上游配置之上加三层：内嵌的 GX 默认值（`src/gx/defaults.ghostty`，Windows 另加 `src/gx/defaults-windows.ghostty`）、设置界面写的覆盖文件 `gui-settings.ghostty`，以及固定的优先级「GX 默认值 < 用户配置（含 `config-file` 引入的文件）< `gui-settings.ghostty` < 命令行」。上游 `Config.load` 依次读默认文件、命令行、再读 `config-file`，引入的文件会盖过命令行；`theme` 的加载与明暗切换（`loadTheme`、`changeConditionalState`）都靠重放 `_replay_steps` 重建配置。要让 `theme = GX Mocha` 这种默认值像普通配置一样被用户的 `theme` 与显式颜色覆盖，并在每次重放后保持层序，只能按层重排重放步骤再重建，而 `Replay` 是 `Config.zig` 的私有类型，所以需要一个公开入口。fork 配置键（`gx-launch-profile`、`gx-herdr-app-mode`、`gx-window-material`、`gx-idle-processes`、`gx-open-config-ui`）必须是 `Config` 的字段，才能走同一套解析、`+show-config`、补全与文档生成；`language` 的语义在 GX 里也变了（只认 `zh-CN`/`en`，默认 `zh-CN`，Windows 与 GTK 可运行时切换），文档注释即用户文档，必须同步改写。

### 行为

- `GHOSTTY_GX_DEFAULTS` 未设置或不是 `0`/`false`/`off`/`no` 时，`Config.load` 改由 `src/gx/config_layers.zig::load` 完成：先按上游顺序读用户默认文件、命令行与 `config-file`，再读覆盖文件（`--config-default-files=false` 时不读用户文件与覆盖文件，但保留 GX 默认值），然后把重放步骤排成「GX 默认值 → 用户文件与全部 include → 覆盖文件 → 命令行 → `-e` 及其命令」，用 `gxReplay` 在空配置上重建，最后 `finalize`。某层设置 `font-family*` 时在该层第一处值前插入重置步骤，高层的字体列表替换低层而不是追加。
- 重放诊断：上游 `Replay.Iterator` 重放 `.diagnostic` 步骤（`config-file` 打不开、循环引用、不是文件）时只把诊断加进新配置，不再记入新配置的 `_replay_steps`，于是设置了 `theme` 后第二次重放（明暗切换的 `changeConditionalState`、`ghostty +validate-config` 在 `Config.load` 之后再调一次 `finalize`）会丢掉这些诊断。GX 默认带主题，这个缺陷会让 `+validate-config` 漏报缺失的 include，所以补丁让重放把诊断步骤一并记回；每次重放都从空配置开始，诊断不会重复。上游路径（`GHOSTTY_GX_DEFAULTS=0`）同样受益。
- 默认值引用内置主题 `GX Mocha` 时，加载前把 `src/gx/themes/GX Mocha` 写进用户主题目录（`<配置目录>/ghostty/themes`；文件首行带 GX 标记，内容变化才原子替换，同名但没有标记的用户文件不动），没有资源目录也能解析主题。
- `GHOSTTY_GX_DEFAULTS=0` 时 `Config.load` 与上游完全一致。`Config.default`、`loadDefaultFiles`、`loadCliArgs`、`loadRecursiveFiles`、`finalize` 等其余入口不变，上游单测不经过 GX 分层。
- 新增 5 个键都有默认值（`gx-herdr-app-mode = true`、`gx-window-material = solid`、`gx-open-config-ui = settings`，两个列表为空）；它们出现在 `+show-config`、shell 补全与生成的配置文档里。C API 按字符串键读取：布尔与枚举照常可读，两个列表类型返回 false（与上游同类键一致）。
- 已知差异：经 GX 分层加载的配置诊断不带文件与行号。上游只要设置了 `theme` 就会在 `loadTheme` 重放时丢掉位置信息，GX 默认带主题，所以总是如此。

### 上游状态

未回馈上游，只服务 Ghostty GX 的产品默认值与设置界面。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

- 字段块是纯新增，放在字段区末尾、`auto-update-channel` 之后；上游在这里加字段时把块挪到新的最后一个字段之后即可，字段区必须留在文件顶部（helpgen 取第一处匹配，见 `docs/AGENT_RULES/config.md`）。
- `language` 注释被上游改写时，取上游版本再按 GX 语义（`zh-CN`/`en`、默认 `zh-CN`、Windows 与 GTK 可运行时切换）重写，保留单行标记。
- `Config.load` 的加载顺序、`Replay`、`loadCliArgs` 的 `config-default-files` 重建、`loadRecursiveFiles` 的 `-e` 后缀处理被上游改动时，核对 `src/gx/config_layers.zig::loadWith` 的分层下标仍然成立，再跑下方验证。上游若自己修好了诊断重放（重放后 `_replay_steps` 已含 `.diagnostic`），删掉第五处的块，否则诊断会被记两次。

### 移除条件

上游提供等价的分层默认值与覆盖文件机制（或 Ghostty GX 不再需要 GX 默认值、设置覆盖文件与 `gx-*` 键）时移除：删除五处改动与标记，把登记行改为 `removed`，删掉 `src/gx/config_layers.zig` 与 `src/gx/config_types.zig` 的引用，并确认 `src/gx/**` 单测另有入口。诊断重放的块可以单独保留到上游修复为止。

### 验证

Linux（或 WSL 克隆）上：

```bash
python3 scripts/zig_test.py --suite main -Dapp-runtime=none --filter gx. --filter config --filter cli.
python3 scripts/zigw.py build -Dapp-runtime=none -Demit-webdata
python3 -m unittest scripts.test_fork_patches -v
```

Windows 本机的第一条用 `just test --filter gx. --filter config --filter cli.`（运行器在 Windows 上按 win32 apprt、`x86_64-windows-gnu` 构建）。

- 第一条覆盖 `src/gx/**` 全部单测（层序、主题覆盖、明暗切换、`-e`、`config-default-files=false`、诊断保留、默认值内容）与上游配置、CLI 单测。
- 第二条运行 helpgen 与 webgen，确认新键的文档注释能生成配置文档。

### 测试锁定

`scripts/test_fork_patches.py` 的登记表与闭集检查覆盖 GX-0010：标记必须存在于 `src/config/Config.zig`，四对 `begin`/`end` 成对且不嵌套。行为由 `src/gx/config_layers.zig` 的单测锁定，其中两条覆盖诊断重放（GX 分层与上游路径各一条）。

## GX-0011 GTK 界面语言运行时切换、GX 菜单、启动配置与快捷键速查

- 文件：`src/apprt/gtk/class/application.zig`（导入 GX GTK 层并引入其单测的纯新增块；`Application.new` 中按 `language` 改写 `LANG` 的 5 行换成一行 `gx_gtk.language.startup`；`startup` 在 `startupActionMap` 之后注册 GX app action；`propConfig` 开头跟随 `language` 变化）、`src/apprt/gtk/class/window.zig`（导入；`init` 与 `propConfig` 末尾重建菜单与提示；`surfaceMenu` 的参数改为具名，在右键菜单弹出前重建它；`closureTitle` 的兜底标题）、`src/apprt/gtk/class/tab.zig`（标签页兜底标题）、`src/apprt/gtk/class/surface.zig`（`defaultTermioEnv` 给子进程还原 `LANGUAGE`）、`src/apprt/gtk/App.zig`（纯新增 `gxAction`）、`src/apprt/gtk/build/gresource.zig`（登记 `gx/menus` Blueprint）。逻辑都在新路径 `src/apprt/gtk/gx/*.zig` 与 `src/apprt/gtk/ui/1.5/gx/menus.blp`。
- 标记：`fork(gx): GX-0011`；纯新增（导入、各钩子调用、`gxAction`、Blueprint 登记）都用 begin/end 包住，删掉这些块即得上游原文；改动的上游行（`Application.new` 的 `LANG` 改写、`surfaceMenu` 的参数名、两处兜底标题）上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：6 个文件，`git diff --numstat` 合计 +46/−8（含注释）。

### 原因

- 上游 `Application.new` 把 `language` 原样写进 `LANG`。GX 默认 `language = zh-CN` 不是 locale 名，GTK 初始化时 `setlocale(LC_ALL, "")` 失败，整个进程退回 `C` locale，界面变成英文。
- glibc 在 `LC_MESSAGES` 为 `C`、`POSIX`、`C.UTF-8` 时忽略 `LANGUAGE`（WSL 默认 `LANG=C.UTF-8`；Ubuntu 24.04 的 glibc 2.39 实测），只设 `LANGUAGE` 不够。
- 上游的 `language` 不能运行时生效：菜单、按钮提示由模板实例化时的 gettext 定稿；命令面板默认条目在 `Config.default` 时翻译（`src/config/Config.zig::RepeatableCommand.init`），而配置要先加载才知道语言，启动时就会按旧语言翻译。
- GX 的菜单项（设置、快捷键速查、语言切换）、新建标签页下拉里的启动配置与 `gx:` 绑定动作的 GTK 处理都要挂在上游的应用与窗口类上。

### 行为

- 启动：`gx.i18n.resolve(language)` 决定界面语言（`zh-CN` 或 `en`，未设或不支持时 `zh-CN`；`GHOSTTY_GX_DEFAULTS=0` 也一样）。该语言的 UTF-8 locale（`zh_CN.UTF-8`、`en_US.UTF-8`）已安装时写进 `LANG`（保持上游语义），否则保留原值并告警；`LANGUAGE` 设为 `zh_CN` 或 `en`；先 `gtk_disable_setlocale` 再自行 `setlocale(LC_ALL, "")`，然后把 `LC_MESSAGES` 设为该语言的 locale，不可用时保留已有的非 C locale，或退到另一种受支持语言的 locale；都没有时只有 `gx.i18n` 的字符串跟随语言，日志提示生成 locale。随后 `bind_textdomain_codeset(bundle_id, "UTF-8")`、`gx.i18n.setCurrent`。默认命令面板条目的译文因此改变时（比较前后哈希），当场重新加载一次配置。
- 运行时：`language` 变化（用户配置加 `reload_config`、`gui-settings.ghostty` 或语言菜单）后，`Application.propConfig` 更新 `LANGUAGE`（`setenv` 加 `global.syncEnviron`，是 GTK apprt 启动后唯一修改进程环境的地方）与 `LC_MESSAGES`，再调一次 `textdomain` 让 gettext 的缓存失效，并切换 `gx.i18n`；命令面板译文变化时在空闲回调里再硬重载一次配置。各窗口的 `propConfig` 随后重建菜单与按钮提示，并弹出 toast「界面语言已切换，重新打开窗口后全部文字才会更新。」：已存在的上游控件与 libadwaita 自带文字只在创建时取译文。之后新开的对话框、命令面板、窗口与标签页的兜底标题（`Ghostty GX`）都用新语言。
- 菜单：`ui/1.5/gx/menus.blp` 复刻上游 `window.blp` 的 `main_menu`、`split_menu`、`tab_context_menu` 与 `surface.blp` 的 `context_menu_model`，标签是不带 `_()` 的英文 msgid，由 `gx.i18n` 翻译（不进上游 pot）；每次重建都生成新的 `GMenu` 设到按钮、`AdwTabView` 与终端右键菜单上（原地改菜单时 GTK 弹出菜单保留旧子菜单页，报 “duplicate child name in GtkStack”）。窗口只在语言、启动配置或 `app.gx-settings` 是否存在变化时重建。☰ 菜单新增一段：设置…（`app.gx-settings`；该 action 不存在时改为 `app.open-config::os-open`）、键盘快捷键（`app.gx-keybinds`）、语言子菜单（有状态的单选 action `app.gx-language`，把 `language` 写进 `gui-settings.ghostty`，先切换语言再硬重载配置）。
- 新建标签页下拉：`gx.profiles.detectSystem` 探测到的启动配置加上 `gx-launch-profile`，名称随界面语言；条目激活 `app.new-tab`，参数为 `(0, ["-e", argv…])`（自定义命令行为 `--command=<值>`，均为 `class/Overrides.zig::parse` 的语法），新标签页照常继承工作目录；另有「用启动配置新建窗口」子菜单（`app.new-window-command`）。下拉按钮提示改为「启动配置与分屏」。
- 快捷键速查：`Adw.Dialog`，按类别列出 `keybind` 根集合的绑定（含前导键序列与链式动作，跳过 `ignore` 与 catch-all），同一动作的多个按键并成一行；标题取命令面板默认条目或 GX 补充标题并经 `gx.i18n` 翻译，副标题是配置语法的动作，按键用 `GtkShortcutLabel`；顶部搜索框按标题、动作、类别与按键过滤。
- `gx:` 绑定动作：`App.gxAction(target, action)` 按标签名分派 `settings`、`main_menu`、`keybinds`、`new_tab_profile`、`new_window_profile`；`action` 是 `anytype`，`src/apprt/gtk/gx/app.zig::request` 只按标签名映射，不依赖 `src/gx/action.zig::Action` 的具体定义，未知标签返回 false。`main_menu` 优先从可见的 ☰ 按钮弹出，否则借用活动终端的右键弹出菜单在其右上角显示，关闭后恢复原菜单。
- 子进程：`Surface.defaultTermioEnv` 在上游恢复 `LANG` 之后把 `LANGUAGE` 恢复为启动时的值（原来没有就删除），终端里的 shell 保持系统语言。

### 上游状态

未回馈上游，只服务 Ghostty GX 的中英界面与菜单。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

- `Application.new` 里 `saved_language` 块被上游改动时，取上游版本，再把按 `language` 写 `LANG` 的部分换回 `gx_gtk.language.startup(alloc, &config)`，它必须在 `adw.init()` 之前、`config` 加载之后执行。
- 上游改 `window.blp` 或 `surface.blp` 的菜单时，同步改 `ui/1.5/gx/menus.blp`（标签写不带 `_()` 的英文 msgid；`po/zh_CN.po` 没有的新 msgid 加进 `src/gx/i18n/gx.zh_CN.po` 后 `just i18n`）。上游改按钮类型或图标名（`open-menu-symbolic`、`view-grid-symbolic`）时同步 `src/apprt/gtk/gx/window.zig::Header.visit`。
- `Window.surfaceMenu` 或 `Surface` 的 `menu` 信号被上游改名、改签名时，把 `syncSurfaceMenu` 挪到新的「右键菜单弹出前」位置；`defaultTermioEnv` 的 `LANG` 恢复逻辑变化时，`restoreChildEnv` 仍放在它之后。
- 其余是单行钩子或纯新增块，按原位置放回即可。

### 移除条件

上游让 `language` 可以运行时切换且接受 `zh-CN` 这类语言标签，并为菜单与新建标签页下拉提供扩展点时，改用上游机制，删除对应钩子与标记，把登记行改为 `removed`。`gxAction` 与 `gx/menus` 的登记只服务 GX 功能，随 GX 菜单一起移除。

### 验证

GTK app 与 GTK apprt 的单测只能在装有 GTK 的 Linux 上构建，以下命令经 WSL（Ubuntu 24.04，`just wsl setup --apt` 已生成 `zh_CN.UTF-8` 与 `en_US.UTF-8`）运行：

```bash
just wsl sync <worktree> --dirty
just wsl build --gtk
just wsl test --gtk --filter apprt
just wsl smoke --out <目录> --lang zh_CN --xdotool <脚本>
python -m unittest scripts.test_fork_patches -v
```

截图核对：默认配置下（含继承 `LANG=C.UTF-8`）界面与命令面板是中文、终端里 `LANG`/`LANGUAGE` 仍是原值；`--config` 写 `language = en` 时为英文；☰ 菜单有设置…、键盘快捷键与语言子菜单；新建标签页下拉列出启动配置，点击后新标签页运行该程序；语言菜单选 English 或改配置后 `reload_config`，菜单、提示与命令面板变成英文并出现 toast。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）。行为由 `src/apprt/gtk/gx/*.zig` 的单测锁定（`just wsl test --gtk --filter apprt.gtk.gx`）：`LANGUAGE` 与 C locale 判定、子进程 `LANGUAGE` 还原、启动配置参数与查找、速查的分组与标题、`gx:` 动作分派与处理函数的编译。

## GX-0012 关闭确认识别空闲进程

- 文件：`src/Surface.zig`，四个纯新增块：`DerivedConfig` 的 `gx_idle_processes` 字段、`DerivedConfig.init` 里对应的赋值、`needsConfirmQuit` 的 `.true` 分支开头、紧随 `needsConfirmQuit` 之后的私有函数 `gxIdleAwayFromPrompt`；`src/termio/Exec.zig`，`Subprocess.getProcessInfo` 开头一个纯新增块。判定逻辑在新路径 `src/gx/confirm.zig`。
- 标记：`fork(gx): GX-0012`，五块都以 `// fork(gx): GX-0012 begin: <说明>` 开头、`// fork(gx): GX-0012 end` 结尾。
- 状态：active，未回馈上游。
- 改动量：2 个文件，新增 37 行（含注释），不改、不删上游行。

### 原因

上游 `confirm-close-surface = true` 时，只要光标不在 shell 提示符上就要确认（`Terminal.cursorIsAtPrompt`，靠 OSC 133 shell 集成）。没有 shell 集成的 shell 光标永远「不在提示符」：Windows 的 `cmd.exe` 与 PowerShell、未注入集成的 shell、`shell-integration = none`，关闭每个空闲终端都会弹确认；win32 apprt 的标题栏关闭按钮因此干脆绕开了 `needsConfirmQuit`。Ghostty GX 要求终端里只剩空闲进程（shell、shell 启动器、控制台辅助进程，即 `gx-idle-processes` 或内置列表）时不确认，运行 `vim`、`herdr`、`sleep` 等程序时照常确认。所有 apprt（GTK、win32、macOS 嵌入库）都经上游的 `Surface.needsConfirmQuit` 判断，只能在这里接入；Windows 上 `WindowsPty.getProcessInfo` 一律返回 null，核心拿不到任何 pid，所以还要在 `Exec.Subprocess.getProcessInfo` 补 Windows 分支。

### 行为

- 只改变 `confirm-close-surface = true` 且光标不在提示符时的结论：`gxIdleAwayFromPrompt` 先按上游检查提示符（在提示符上直接交回上游，不列进程），否则把 `Surface.getProcessInfo(.foreground_pid)` 交给 `src/gx/confirm.zig::terminalNeedsConfirm`，列出该进程及其全部子孙进程；全部空闲（`src/gx/policy.zig::isIdle`，`gx-idle-processes` 为空时用内置列表）就不确认，否则仍按上游确认。`always`、`false`、只读模式与子进程已退出的语义不变。
- 进程来源：Linux 是 pty 的前台进程组组长（`tcgetpgrp`），经 `/proc` 列出；Windows 没有前台进程组，`Subprocess.getProcessInfo(.foreground_pid)` 改为返回子进程（shell）的 pid（`GetProcessId`），经 Toolhelp32 列出。判定看整棵子树，比只看最深的子进程更保守：`gx-zsh.exe → zsh.exe → gitstatusd` 空闲；`pwsh.exe → vim.exe`、`zsh.exe → herdr.exe → zsh.exe`（herdr 里的 shell 不让 herdr 变成空闲）、shell 的后台任务都算忙。
- 读不到进程（pid 未知、组长已退出、`/proc` 打不开，以及 Linux 与 Windows 以外的系统，如 macOS 嵌入库）时按忙处理，即保持上游结论。
- 列进程在主线程同步进行，不持有 `renderer_state.mutex`；只在关闭与退出确认时调用，Linux 一次 `/proc` 扫描约数毫秒。
- Windows 上 `Surface.getProcessInfo(.foreground_pid)` 原本恒为 null，现在返回 shell 的 pid。上游读它的只有 macOS 的 `ghostty_surface_foreground_pid`，Windows 不提供 C API，不受影响；win32 apprt 可直接用这个 pid 做进程判断（如 herdr 应用模式，见 `src/gx/app_mode.zig`）。

### 上游状态

未回馈上游。上游的提示符判断依赖 shell 集成，这个补丁只服务 Ghostty GX 的空闲进程策略；如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

五块都是纯新增。上游改动 `needsConfirmQuit`（提示符判断、加锁方式）时，取上游版本，把 GX 块放回 `.true` 分支开头，并让 `gxIdleAwayFromPrompt` 的提示符检查与上游保持一致；`DerivedConfig` 的字段块放在 `key_remaps` 之后，赋值块放在 `.key_remaps = …` 之后、`.arena = arena` 之前。上游改动 `Subprocess.getProcessInfo` 或 `Subprocess.Process` 时，按同一语义放回 Windows 分支（Windows 上 `.foreground_pid` 返回子进程 pid）；上游自己在 Windows 上实现了 `foreground_pid` 时，删掉 `Exec.zig` 的块。

### 移除条件

上游提供等价的「终端只剩空闲进程时不确认」机制，或 Ghostty GX 不再需要该策略时移除：删除五块与标记、`src/gx/confirm.zig`，把两行登记改为 `removed`。只有 `Exec.zig` 的块可以在上游实现 Windows `foreground_pid` 后单独移除。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu   # Windows 分支能编译
just test --filter gx.confirm                                                    # Windows 本机单测（win32 apprt）
just wsl test --filter gx.confirm                                                # Linux 单测（-Dapp-runtime=none）
just wsl build --gtk
python -m unittest scripts.test_fork_patches -v
```

GTK 冒烟：配置 `shell-integration = none` 与 `command = /bin/bash --noprofile --norc`，开两个标签页，空闲标签页 `Ctrl+Shift+W` 直接关闭，运行 `sleep 100` 的标签页弹出关闭确认；Debug 构建日志里有 `gx_confirm` 的判定行。Windows：`cmd.exe`、`pwsh.exe` 空闲时关闭标签页不确认，运行 `vim` 时确认。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）。判定由 `src/gx/confirm.zig` 的单测锁定，经 GX-0010 的 `test` 块进入 `ghostty-test`。

## GX-0014 gx: 绑定动作分发到应用运行时

- 文件：`src/input/Binding.zig`（导入 `src/gx/action.zig`；`Action` 字段区末尾、`crash` 之后新增 `gx` 字段与文档注释；`scope` 把 `.gx` 归入 surface；`formatValue`、`cloneValue` 各加一个 union 分支）、`src/input/command.zig`（`actionCommands` 的 `.gx` 分支，没有内置命令）、`src/Surface.zig`（`performBindingAction` 的 `.gx` 分支）。动作类型、解析与格式化在新路径 `src/gx/action.zig`。
- 标记：`fork(gx): GX-0014`；全部是纯新增块，用 `begin`/`end` 包住（`Binding.zig` 五块，其余两个文件各一块）。
- 状态：active，未回馈上游。`src/apprt/gtk/class/command_palette.zig` 原有一块（`isActionSupportedOnGtk` 把 `.gx` 归为不支持，GTK 命令面板因此不列出 `gx:` 条目）已在 GTK 实现 `gxAction`（GX-0011）后删除，登记行改为 `removed`，该文件与上游一致。
- 改动量：3 个文件，`git diff --numstat` 合计 +62/−0（含注释与文档注释）。

### 原因

Ghostty GX 的 Windows 界面需要能绑定到键位与命令面板的应用操作：打开设置、主菜单、快捷键速查，按启动配置新建标签页或窗口。上游的绑定动作是 `input.Binding.Action` 闭集，`keybind` 与 `command-palette-entry` 只接受其中的动作；若加进 `src/apprt/action.zig` 的 apprt 动作表，就要改 C ABI（`include/ghostty.h`）并波及 macOS 与 GTK。所以只给 `Binding.Action` 加一个携带 GX 子动作的成员，由核心 Surface 直接交给 apprt 的 `gxAction`，不经过 apprt 动作表。`Binding.Action` 的格式化与克隆只支持标量、字符串和结构体参数，携带 union 需要两个通用分支；`scope`、`actionCommands`、`performBindingAction` 是穷举 switch，不补分支就编译失败。

### 行为

- 语法 `gx:<name>[:<argument>]`：`settings`、`main_menu`、`keybinds`、`new_tab_profile:<id>`、`new_window_profile:<id>`。`<id>` 是 `src/gx/profiles.zig` 的 `Profile.id`（如 `pwsh`、`wsl:Ubuntu`、`custom:<名称>`），取第一个冒号之后的全部内容，可以含冒号。`keybind` 中未知名称报 `InvalidAction`，缺参数、空参数或给无参动作带参数报 `InvalidFormat`；`command-palette-entry` 经 `src/cli/args.zig` 解析，同样的错误报 `InvalidValue`。
- `gx` 动作的作用域是 surface。核心 `Surface.performBindingAction` 在 `apprt.App` 声明了 `gxAction` 时调用 `rt_app.gxAction(.{ .surface = self }, action)` 并返回其结果；否则记一条 warn 日志并返回 false（未执行），带 `performable:` 前缀的绑定因而把按键交给终端。win32 apprt（`src/apprt/win32/App.zig::gxAction`）与 GTK apprt（GX-0011 的 `src/apprt/gtk/App.zig::gxAction`，转到 `src/apprt/gtk/gx/app.zig::performGxAction`）执行全部五个动作；embedded（macOS）与 none 没有实现。
- 命令面板：win32 与 GTK 都列出 `command-palette-entry` 里的 `gx:` 条目（GX 默认值带「设置」「键盘快捷键」「主菜单」三条），选中后同样经 `performBindingAction` 交给 `gxAction`。GTK 用的是未改动的上游命令面板，按标题或动作（如 `gx:settings`）搜索，原样显示配置里的标题与描述：GX 默认值写的是英文 msgid，GTK 构建在加载配置时（fork 路径 `src/gx/config_layers.zig::translatePalette`，不是源码补丁）把默认值层的这些条目按 `language` 换成译文，切换语言重载配置后随之更新；win32 面板在显示时经 `gx.i18n` 翻译。格式化（`+list-keybinds`、`+show-config`、命令面板条目的 C 镜像）输出 `gx:<name>[:<argument>]`，可原样再解析；哈希与比较包含参数。`src/apprt/action.zig` 与 `include/ghostty.h` 不变，其他上游动作的行为不变。

### 上游状态

未回馈上游，只服务 Ghostty GX 的界面。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

先取上游版本，再放回各纯新增块：`Binding.zig` 的导入、`gx` 字段（留在 `Action` 字段区末尾；上游追加动作时把块挪到新的最后一个字段之后，文档注释必须紧贴字段，helpgen 按字段名取文档）、`scope` 的 surface 列表、`formatValue`/`cloneValue` 的 union 分支（上游自己支持 union 参数后删掉这两块）；`command.zig` 与 `Surface.zig` 的 `.gx` 分支。`src/apprt/gtk/class/command_palette.zig` 一律取上游版本，不再放回过滤块。上游给 `Binding.Action` 新增穷举 switch 时，编译会指出缺少 `.gx` 的位置，同样用 `begin`/`end` 块补上并在此登记。

### 移除条件

Ghostty GX 不再需要绑定到键位或命令面板的 GX 操作（或上游提供可由 apprt 扩展的绑定动作）时移除：删除三个文件中的块与 `src/gx/action.zig`，去掉 GX 默认值（`src/gx/defaults.ghostty`）里的 `gx:` 绑定与命令面板条目，把登记行改为 `removed`。原先单独列出的「GTK 实现 `gxAction` 后删掉 GTK 命令面板的过滤块」已经满足并执行，`command_palette.zig` 的登记行为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu
python scripts/zigw.py build -Demit-lib-vt
python -m unittest scripts.test_fork_patches -v
just test --filter Binding --filter gx.action                 # Windows 本机（win32 apprt）
just wsl build --gtk
just wsl test --filter Binding --filter gx.
```

单测在 `src/gx/action.zig`：GX 动作的解析、错误、格式化往返、克隆与比较，`Binding.Action` 的 `parse`/`format`/`hash`/`clone`，`Binding.Set` 解析 `keybind` 语法与反查，以及 `command-palette-entry` 的解析与 C 镜像；GTK 上默认条目按 `language` 翻译由 `src/gx/config_layers.zig` 的单测锁定。Windows 上运行 `ghostty.exe`，`keybind = ctrl+shift+m=gx:main_menu` 打开主菜单，`keybind = ctrl+alt+p=gx:new_tab_profile:pwsh` 打开 PowerShell 7 标签页。GTK 上用 `just wsl smoke --xdotool <脚本>`：Ctrl+Shift+P 打开命令面板，输入 `gx:` 列出三条 GX 条目（默认 zh-CN 为「设置」「键盘快捷键」「主菜单」与中文描述，`language = en` 时为英文），回车后打开对应的对话框；读图后才算通过。

### 测试锁定

`scripts/test_fork_patches.py` 的登记表与闭集检查覆盖 GX-0014：标记必须存在于三个 active 文件，并且已从登记为 `removed` 的 `src/apprt/gtk/class/command_palette.zig` 消失；`begin`/`end` 成对且不嵌套。行为由 `src/gx/action.zig` 的单测锁定。

## GX-0015 GTK 上的 Ghostty GX 设置对话框

- 文件：`src/apprt/gtk/class/application.zig`（三个纯新增块：导入 `../gx/settings_dialog.zig`；`Application.startupActionMap` 的 `actions` 数组末尾登记 `app.gx-settings`；`Action.openConfig` 函数体开头把 `.os_open` 转交设置对话框）、`src/apprt/gtk/build/gresource.zig`（`blueprints` 数组末尾登记 `1.5/gx-settings-dialog`）。对话框本体在新路径 `src/apprt/gtk/gx/settings_dialog.zig` 与 `src/apprt/gtk/ui/1.5/gx-settings-dialog.blp`（模板只能放在 `gresource.zig::ui_path` 的版本目录下），与界面无关的选项映射在 `src/gx/settings_map.zig`，主题预览用的 `src/gx/config_layers.zig::loadWithOverrides` 也是 fork 路径，都不是源码补丁。
- 标记：`fork(gx): GX-0015`；四处都用 `// fork(gx): GX-0015 begin: <说明>` 与 `// fork(gx): GX-0015 end` 整块包住，删掉这些块就是上游原文。
- 状态：active，未回馈上游。
- 改动量：2 个文件，新增 12 行（含标记），不改、不删上游行。

### 原因

`gx-open-config-ui = settings`（默认值，GX-0010 新增）要求「打开配置」显示 Ghostty GX 设置界面而不是编辑器；主菜单的 GX 分区与 `gx:settings` 绑定动作也需要一个固定的 app action 打开它。GTK 的 app action 表（`Application.startupActionMap`）与 `open_config` 的处理（`Action.openConfig`）都在上游 `application.zig` 里；Blueprint 模板必须登记在 `gresource.zig::blueprints` 才会被编译进 gresource（`docs/AGENT_RULES/apprt-gtk.md`「Blueprint 登记」）。所以只能在这两个上游文件里各加入口，其余逻辑全部放在新路径。

### 行为

- `app.gx-settings`（无参数）显示设置对话框，挂在当前活动窗口上（`gtk.Application.getActiveWindow`，没有窗口时独立显示）；对话框已打开时把它提到前面。运行期 libadwaita 低于 1.5（没有 `AdwDialog`）时只记日志。
- `open_config` 的 `.os_open` 目标（默认 `ctrl+,`、主菜单的 `app.open-config::os-open`）：`gx-open-config-ui = settings` 时显示设置对话框；`editor` 或 libadwaita 低于 1.5 时与上游相同，用系统编辑器打开配置文件。`.new_window` 目标（在新窗口里用终端编辑器打开）不受影响。
- 对话框分六页：语言（`language`）；外观（主题列表带搜索，在列表中移动即实时预览，「应用」或回车写入 `theme`，未应用就关闭对话框则恢复；窗口材质纯色 / 半透明 / 毛玻璃分别写 `background-opacity = 1` / `0.9` / `0.85` 与 `background-blur = false` / `false` / `true`，`gx-window-material` 只在 Windows 生效所以不写）；字体（`font-size` 6–100、步进 0.5、恢复默认 12；`font-family`，留空则删除）；交互（`right-click-action`、`scrollbar`、`confirm-close-surface`、`bell-features`）；Shell（`command`，取 `gx.profiles.detectSystem` 探测到的启动配置，参数不含空白时写 `direct:` 形式；选 GX Zsh 且探测到 herdr 时在后台运行 `herdr --gx-set-default-shell <gx-zsh>`，退出码 3 表示用户自管 herdr 配置，只提示不报错）；关于（版本、配置文件与 `gui-settings.ghostty` 的路径，「打开配置文件」按钮走上游 `.os_open` 的编辑器路径）。
- 改动在 300 ms 内合并，经 `gx.gui_settings.Overlay` 写入 `gui-settings.ghostty`（从不写用户的 `config.ghostty`），再重新加载配置；保存、加载失败时在对话框里以 toast 提示。预览不写文件：用内存中的 `--theme=<名称>` 与去掉 `config-reload` 的 `--app-notifications` 覆盖加载配置后调用 `App.updateConfig`，所以不弹出「已重新加载配置」。环境变量 `GHOSTTY_GX_DEFAULTS=0` 关闭 GX 分层时不预览。
- 界面文字用 Ghostty GX 翻译表（`src/gx/i18n.zig`），不经 gettext，`po/` 与 pot 不变；语言取对话框打开时配置的 `language`，每次打开都重新构建，所以切换语言后再打开即生效。

### 上游状态

未回馈上游，只服务 Ghostty GX 的设置界面。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

四个块都是纯新增：导入块放在其他 `class/*.zig` 的导入旁；action 块放在 `startupActionMap` 的 `actions` 数组末尾；`openConfig` 块放在 `Action.openConfig` 函数体开头；登记块放在 `blueprints` 数组末尾。上游改名或重组 `startupActionMap`、`Action.openConfig`、`apprt.action.OpenConfig` 的 `.os_open` 或 `gresource.zig::blueprints` 时，按上述语义放回；上游若自己定义了名为 `gx-settings` 的 action，改 fork 的 action 名并同步主菜单。

### 移除条件

Ghostty GX 不再需要 GTK 设置界面，或上游提供可以挂接的设置界面与 `open_config` 扩展点时移除：删掉四个块与标记，把登记行改为 `removed`，删除 `src/apprt/gtk/gx/settings_dialog.zig` 与 `gx-settings-dialog.blp`。

### 验证

`ghostty-test` 与 GTK 构建都在 Linux（或 WSL）上运行：

```bash
python3 scripts/zigw.py build -Dapp-runtime=gtk                                  # 含 Blueprint 编译
python3 scripts/zig_test.py --suite main -Dapp-runtime=none --filter gx.settings_map --filter gx.config_layers
python3 -m unittest scripts.test_fork_patches -v
```

在 Windows 上经 `just wsl build --gtk` 与 `just wsl smoke --xdotool <脚本>` 截图：脚本把鼠标移进窗口后按 `ctrl+,` 打开对话框，再点选各页；截图须读图后才算通过。

### 测试锁定

只有登记表与闭集检查。选项与配置键的映射由 `src/gx/settings_map.zig` 的单测锁定，预览覆盖的层序由 `src/gx/config_layers.zig` 的 `overrides rank above the command line and below -e` 锁定。

## GX-0016 GTK：herdr 应用模式、GX 样式与 window-theme 随配置重载

- 文件：`src/apprt/gtk/class/window.zig`，十个纯新增块：导入、`Private.gx_app_mode`、公开访问器 `gxAppMode`、`getTabsVisible` 与 `getHeaderbarVisible` 的判断、`connectSurfaceHandlers` 里的标题信号、`tabViewSelectedPage`、`tabViewNPages`、`tabSplitTreeChanged` 的重新判断、`dispose` 里停掉定时器；`src/apprt/gtk/class/application.zig`，四个纯新增块：导入、`Private.gx_style`、`deinit` 移除样式、`propConfig` 应用样式与 `window-theme`。逻辑在新路径 `src/apprt/gtk/gx/app_mode.zig`、`src/apprt/gtk/gx/style.zig`、`src/apprt/gtk/gx/style.css`，与平台无关的部分在共享核心 `src/gx/app_mode.zig`、`src/gx/gtk_css.zig`。
- 标记：`fork(gx): GX-0016`，十四块都以 `// fork(gx): GX-0016 begin: <说明>` 开头、`// fork(gx): GX-0016 end` 结尾。
- 状态：active，未回馈上游。
- 改动量：2 个文件，新增 49 行（含注释），不改、不删上游行。

### 原因

- herdr 应用模式（`gx-herdr-app-mode`）：窗口唯一的标签页运行 herdr 时，窗口应像独立的 herdr 应用一样呈现。标签栏是否显示由上游 `Window.getTabsVisible` 决定，判断入口、重新判断的时机（标签页增减与切换、分屏变化、终端标题变化）与窗口释放都在上游的 `window.zig` 里。
- GX 外观：圆角标签、跟随终端主题的标签与标题栏配色、1 px 分屏线、更细的滚动条、平直的标题栏。上游的运行时 CSS 只覆盖少数配置项，`gtk-custom-css` 属于用户；GX 需要自己的 CSS provider，并在每次配置变化时重新生成颜色，加载入口 `Application.propConfig` 与清理入口 `Application.deinit` 都是上游函数。
- `window-theme`：上游只在 `Application.startupStyleManager` 设置一次 libadwaita 的配色方案，运行时改 `window-theme` 或主题背景要重启才生效；GX 的设置界面会在运行时改配置。

### 行为

- herdr 应用模式：`gx-herdr-app-mode = true`、窗口恰好一个标签页，且该标签页某个终端运行 herdr 时进入。判断由 `src/gx/app_mode.zig` 完成：Linux 取 `Surface.getProcessInfo(.foreground_pid)`（pty 前台进程组组长），名字是 herdr 即命中，是 shell 等内置空闲进程即未命中（herdr 至多是后台或已停止的任务），其他程序（如包装脚本）再经 `/proc` 查它下面有没有 herdr。进入后 `getTabsVisible` 返回 false，即使 `window-show-tab-bar = always` 也隐藏标签栏；退出 herdr、新开第二个标签页或关掉 `gx-herdr-app-mode` 后恢复。
- `gtk-titlebar-style = tabs` 时窗口控制按钮、新建标签与主菜单都在标签栏里，隐藏它会让窗口无法拖动和关闭，所以应用模式下 `getHeaderbarVisible` 改为显示标题栏（启用 CSD 时）顶替标签栏；`native` 风格只隐藏标签栏。最大化且 `gtk-titlebar-hide-when-maximized` 时两者都隐藏，与上游一致。
- 重新判断的时机：标签页数量与选中页变化、标签页分屏变化、任一终端标题变化（只读前台进程名，不扫描 `/proc`），以及窗口恰好一个标签页时每 1.5 s 一次的定时器（可扫描）。定时器在其他标签页数量时停止，`dispose` 时移除；状态变化时通知 `tabs-visible` 与 `headerbar-visible`。
- GX 样式：独立的 CSS provider，优先级 `GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2`，高于 libadwaita 与 Ghostty 的 `style.css`，低于 Ghostty 的运行时 CSS（`+3`）与 `gtk-custom-css`（`USER`），两者仍能覆盖它。静态规则（`style.css`）：标签 8 px 圆角；默认的 `raised` 工具栏风格去掉标题栏与标签栏下方的阴影（`raised-border` 保留边线）；分屏线 1 px；滚动条变细，只作位置指示时更细。`window-theme = auto` 或 `ghostty` 时再追加由终端主题生成的颜色（`src/gx/gtk_css.zig`）：标题栏与标签栏取 `window-titlebar-background`/`-foreground`（缺省为终端背景与前景），标签悬停、按下与选中色由二者混合，选中标签描一圈 palette 4 的半透明边，分屏线取背景与前景的 15% 混合（用户设了 `split-divider-color` 时由运行时 CSS 覆盖）；`system`、`light`、`dark` 不改颜色。每次配置变化重新生成。
- `window-theme`：每次配置变化（含启动时的首次）按 `startupStyleManager` 的同一规则重设 libadwaita 配色方案，运行时修改即时生效。设置放在空闲回调里：配色方案一变，`handleStyleManagerDark` 就同步发起一次软重载，若在 `propConfig` 里直接设置，会在这次配置变化里嵌套另一次，并释放 `propConfig` 正在读的配置。例外：`window-theme` 为 `ghostty`（或 `auto`，上游此时已改成 `system`）且明暗主题不同时，配色方案取决于背景、背景又随配色方案切换，启动后不再重设，以免明暗来回切换；这与上游只在启动时设置一次的行为一致。

### 上游状态

未回馈上游。herdr 应用模式与 GX 外观只服务 Ghostty GX；`window-theme` 运行时重载是上游可接受的改进，如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

十四块都是纯新增，只依赖这些上游接口：`Window.getTabsVisible`、`getHeaderbarVisible`、`connectSurfaceHandlers`（与 `disconnectSurfaceHandlers` 按 `data = self` 断开全部信号）、`tabViewSelectedPage`、`tabViewNPages`、`tabSplitTreeChanged`、`dispose`、`getTabView`、`getConfig`，以及 `Application.propConfig`、`deinit`、`startupStyleManager` 的配色规则。上游重组这些函数时，把对应块放回同一语义的位置；`startupStyleManager` 的配色规则变化时同步 `src/apprt/gtk/gx/style.zig::colorScheme`。上游改动标签栏、工具栏或分屏的 CSS 节点（`tabbar tab`、`toolbarview > .top-bar`、`.split paned > separator`）时，核对 `style.css` 与 `src/gx/gtk_css.zig` 的选择器。

### 移除条件

Ghostty GX 不再需要 GTK 的 herdr 应用模式与 GX 外观时移除：删除全部块与标记、`src/apprt/gtk/gx/`、`src/gx/gtk_css.zig`（`src/gx/app_mode.zig` 仍供 win32 使用时保留），把两行登记改为 `removed`。上游实现运行时重设 `window-theme` 后，删除 `Style.apply` 里的配色方案调用。

### 验证

```bash
just wsl build --gtk
just wsl test --filter gx.app_mode --filter gx.gtk_css    # 共享核心单测（-Dapp-runtime=none）
python -m unittest scripts.test_fork_patches -v
```

GTK 冒烟（Xvfb，`just wsl smoke`）：开 2–3 个标签页与一个分屏，看圆角标签、标签配色、1 px 分屏线；`window-show-tab-bar = always` 时在唯一的标签页运行 `cp /bin/sleep /tmp/herdr && /tmp/herdr 60`，标签栏在 1.5 s 内隐藏，herdr 退出或新开标签页后恢复；`gtk-titlebar-style = tabs` 时应用模式显示标题栏。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）。判定与配色由 `src/gx/app_mode.zig`、`src/gx/gtk_css.zig` 的单测锁定；GTK 胶水代码（`src/apprt/gtk/gx/`）没有单测，靠 GTK 构建与冒烟截图验证。

## GX-0021 输入法预编辑后的字形游标不越界

- 文件：`src/renderer/generic.zig`，`rebuildRow` 中预编辑区之后追赶字形游标的 `while` 条件加上 `shaper_cells_i < shaper_cells_unwrapped.len`。
- 标记：`fork(gx): GX-0021`，改动行上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：1 个文件，改 1 行、加 1 行标记注释。

### 原因

`rebuildRow` 跳过输入法预编辑（preedit）覆盖的格子后，要把字形游标 `shaper_cells_i` 追到当前格子：先找到覆盖该格的 shaping run，再把游标推进到第一个 x 不小于当前格的字形。run 的 `cells` 按格子计数，而 shaping 只为有内容的格子产生字形，带背景色的空格子也在 run 里却没有字形；当前格之后不再有字形时，上游这个循环没有下界检查，读到 `shaper_cells_unwrapped[len]`，Debug 构建 panic（`index out of bounds`），渲染线程崩溃带走整个进程。Windows 上 GX 默认中文界面，系统输入法常为微软拼音，在 herdr 这类整屏铺背景色的 TUI 里只要按下一个字母开始拼音组字就会触发；上游 main（2026-10-08 的 b115e4567）同样如此。

### 行为

游标追到 run 的字形末尾即停；随后本行的主循环本来就会在游标到达末尾时取下一个 run（`shaper_cells_i >= shaper_cells.?.len`），空格子没有字形可画，结果与上游在不越界时完全相同。其余渲染路径不变。

### 上游状态

未回馈上游。这是上游的通用缺陷，适合回馈；如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游改写预编辑追赶逻辑时，取上游版本，确认推进 `shaper_cells_i` 的循环仍有 `< len` 的边界；上游已自带边界时按「移除条件」处理。

### 移除条件

上游修复该越界（循环带上界或改写追赶逻辑）后，删除改动与标记，把登记行改为 `removed`。

### 验证

```bash
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -p <prefix>
python -m unittest scripts.test_fork_patches -v
```

GUI：微软拼音中文模式下，在 Ghostty GX 里运行 herdr，在窗格中按字母开始组字（预编辑内联显示），不再崩溃；上屏后文字到达窗格。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）。

## GX-0022 Windows 上终端与 ConPTY 的屏幕缓冲保持同步

- 文件：`src/terminal/Terminal.zig`（`flags` 新增 `semantic_prompt_fresh_line` 字段的纯新增块；`fullReset` 保留该字段的一行；`semanticPromptFreshLine` 开头的一处早退；两个回归测试的纯新增块）与 `src/termio/Exec.zig`（`initTerminal` 开头在 Windows 上关闭 `resize_pull_scrollback` 与 `semantic_prompt_fresh_line` 的纯新增块；一个回归测试的纯新增块）。
- 标记：`fork(gx): GX-0022`；字段、`initTerminal` 开头的赋值与测试用 begin/end 包住，`fullReset` 与 `semanticPromptFreshLine` 的改动上一行写单行标记。
- 状态：active，未回馈上游。
- 改动量：2 个文件，`git diff --numstat` 合计 +130/−0（含注释与测试）。

### 原因

ConPTY 宿主（conhost 或 OpenConsole）维护自己的屏幕缓冲，缓冲没有回滚区，大小等于窗口；它按这份缓冲用绝对坐标向终端输出。终端对屏幕做了 ConPTY 不做的移动，之后的绝对定位就落在错误的行上。Ghostty 有两处这样的默认行为：OSC 133 的 fresh-line，以及缩放时从回滚区拉回行。

**OSC 133 的 fresh-line。** GX Zsh 在 Ghostty 里启用 powerlevel10k 的 shell 集成，每个提示符前发 `OSC 133;A`。Ghostty 按语义提示符规范把 A、N、L 当作 fresh-line：光标不在左边界时先回车再换行（`Terminal.semanticPromptFreshLine`），在最底行就会滚屏。Windows 上 shell 的输出先经过 ConPTY，ConPTY 宿主（conhost 或 OpenConsole）维护自己的屏幕缓冲，`OSC 133;A` 在它那里只是标记，不移动光标（microsoft/terminal 的 `AdaptDispatch::DoFinalTermAction` 只调用 `StartPrompt`），Windows Terminal 同样不做 fresh-line。

系统自带的 ConPTY（实测 Windows 11 build 26300 的 conhost 10.0.26100.8875）按屏幕差异重绘之后才把透传的 OSC 送出，这时光标停在重绘的最后一行，例如 `\e[K\e[215C\e]133;A\a\e[2;1H❯ `。Ghostty 的 fresh-line 在底行滚动一行，ConPTY 的缓冲却没有滚动；之后 ConPTY 用绝对坐标画的折叠提示符（p10k 的 transient prompt）比 Ghostty 屏幕上的内容高一行，上一条命令折叠后的 `❯ sleep 4` 被滚进回滚区，屏幕顶部留下空行，每执行一条命令错一行。关掉 transient prompt 或 `POWERLEVEL9K_PROMPT_ADD_NEWLINE` 仍会错位，关掉 OSC 133 则不会。

随包 ConPTY（1.22 起）按应用的输出顺序透传，`OSC 133;A` 到达时光标已在列 0，fresh-line 不起作用，所以带随包 ConPTY 的发布包看不到这个问题；开发构建（`just build` 不放 `conpty.dll`）、`GHOSTTY_GX_CONPTY=system` 以及随包 ConPTY 载入失败回退到系统 ConPTY 时都会出现。同样实现 fresh-line 的 WezTerm 在系统 ConPTY 上也会错位。

**缩放时从回滚区拉回行。** 上游的 `Terminal.flags.resize_pull_scrollback` 默认 true：窗口变高且光标在最底行时，`PageList.resize` 把回滚区的行拉回活动区，光标随之下移；列数变化的重排也可能让活动区滑到更早的内容上。ConPTY 的缓冲变高时只在底部补空行，光标行不变。上游在这个字段与 `PageList.Resize.pull_scrollback` 的注释里写明 ConPTY 这类自带屏幕缓冲、没有回滚区的 pty 应设为 false，但上游与 fork 的 Windows termio 都没有设置。实测（80×20 窗口里的 cmd.exe 输出 120 行后把窗口拉高，再缩小、最大化）：

- 随包 ConPTY 1.24 缩放时不输出任何东西，之后回显输入、画提示符都按它自己的缓冲用绝对坐标，例如 `\e[20;66Hecho after-grow`：命令与输出写在被拉回的历史行上，与 `line 103` 等旧行交错，屏幕底部残留一个旧提示符，真正的提示符与光标在屏幕中间。
- 系统 ConPTY（conhost 10.0.26100.8875）缩放后立即用 `\e[H` 加逐行 `\e[K` 重绘整个缓冲：屏幕看起来正常，但被拉回活动区的历史行已被覆盖，滚轮往上翻时这段历史不见了（`line 82` 之后直接是 `line 103`；最大化后从 `line 57` 跳到 `dir` 的输出）。
- GX Zsh 只用 zsh 内建命令时，随包 ConPTY 下看不出错位（ZLE 只用相对移动），但 Ghostty 的光标行已与 ConPTY 不一致，cmd.exe 这类经控制台 API 绘制的程序一运行就会错位；系统 ConPTY 下同样丢失回滚历史（`line 46` 之后直接是 `line 116`）。

### 行为

- `Terminal.flags.semantic_prompt_fresh_line` 默认 true，与上游行为相同；为 false 时 `OSC 133;A`、`133;N` 与 `133;L` 不再移动光标，提示符标记、`redraw`、`click_events` 与 `cl` 等其余语义不变。它与上游的 `resize_pull_scrollback` 一样是随 pty 而定的配置，`fullReset` 保留它。
- `Exec.initTerminal` 在 Windows 上把 `semantic_prompt_fresh_line` 与上游的 `resize_pull_scrollback` 都设为 false，随包与系统 ConPTY 都是。
  - fresh-line：ConPTY 的缓冲从不执行 fresh-line，终端也不做才能与之同步，与 Windows Terminal 一致。zsh 的 `PROMPT_CR`/`PROMPT_SP` 本来就让提示符从行首开始；不以换行结尾的输出之后，提示符接在输出后面，与 Windows Terminal 相同。
  - 缩放：窗口变高时活动区在底部补空行，提示符与光标留在原来的行，与 ConPTY 的缓冲一致；已滚出屏幕的历史留在回滚区，用滚轮查看。列数变化照常重排，活动区顶部保持在原来的内容上，完全在回滚区里的行不会被拉回；仍有一行在活动区的折行可以展开回来（上游 `PageList.Resize.pull_scrollback` 的语义）。只减少行数时行为不变。
- 其他平台与 libghostty-vt 的默认行为不变；C API 没有新增选项（`resize_pull_scrollback` 本来就有 `GHOSTTY_TERMINAL_OPT_RESIZE_PULL_SCROLLBACK`）。

### 上游状态

未回馈上游。上游 Ghostty 的 Windows pty 同样只用 ConPTY：`resize_pull_scrollback` 已是上游字段，只差 Windows termio 设置它；fresh-line 适合作为与之并列的 pty 配置回馈（届时应同时为 libghostty-vt 的 C API 增加选项）。如需回馈，由人类按上游流程处理；agent 不创建 issue 或 PR。

### 同步冲突处理

上游改动 `Terminal.flags`、`fullReset` 或 `semanticPromptFreshLine` 时取上游版本后放回：字段块紧跟 `resize_pull_scrollback`，`fullReset` 保留该字段，`semanticPromptFreshLine` 开头在字段为 false 时返回；`Exec.initTerminal` 开头保留 Windows 上关闭两个字段的块。上游新增 OSC 133 动作且会移动光标时，同样受这个字段控制。上游自己在 Windows 上关闭 `resize_pull_scrollback` 后，从块里删去这一行；上游改了 `PageList.resize` 的拉回语义时，按「测试锁定」的用例核对 ConPTY 的两种输出形状仍然同步。

### 移除条件

上游提供等价的配置（ConPTY 下不做 OSC 133 的 fresh-line），并在 Windows 上同时关闭它与 `resize_pull_scrollback` 后，删除改动与标记，把登记行改为 `removed`。

### 验证

```bash
python scripts/zig_test.py --suite vt --filter "semantic prompt" --filter "scrollback pull"
python scripts/zig_test.py --suite main --filter "semantic prompt" --filter "scrollback pull" --filter initTerminal --filter execCommand --filter pty.test
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -p <prefix>
python -m unittest scripts.test_fork_patches -v
```

GUI：

- fresh-line：设 `GHOSTTY_GX_CONPTY=system` 启动 `<prefix>\bin\ghostty.exe`，以 GX Zsh（p10k 两行提示符、transient prompt、提示符前空行）依次执行 `sleep 4` 与 `false`：折叠后的 `❯ sleep 4` 与 `❯ false` 留在屏幕顶部相邻两行，上方没有空行；补丁之前 `❯ sleep 4` 消失、顶部出现空行。
- 缩放：`<prefix>\bin` 里放好随包的 `conpty.dll` 与 `OpenConsole.exe`，以 `window-width = 80`、`window-height = 20` 启动 cmd.exe，执行 `for /L %i in (1,1,120) do @echo line %i`，把窗口拉高后执行 `echo after-grow` 与 `dir /w`，再缩小、最大化各执行一条命令：命令与输出紧接在提示符之后，没有与旧行交错的内容或残留的提示符，滚轮往上能连续翻回 `line 1`。再设 `GHOSTTY_GX_CONPTY=system`、换 GX Zsh 各做一遍。补丁之前随包 ConPTY 下命令写在被拉回的历史行上，系统 ConPTY 下回滚区缺一段历史。

### 测试锁定

- `Terminal: semantic prompt without fresh-line` 用 ConPTY 的实际输出形状（重绘到底行之后才透传 `OSC 133;A`，再用绝对坐标画提示符）锁定：关闭 fresh-line 后上一条命令行仍在屏幕上，`133;N` 与 `133;L` 也不移动光标，该字段在 `fullReset` 后保留。
- `Terminal: resize without scrollback pull stays in sync with ConPTY` 用两种 ConPTY 缩放后的实际输出形状锁定关闭拉回后的同步：随包 ConPTY 缩放时不输出、之后用绝对坐标回显输入，命令落在提示符所在行；系统 ConPTY 缩放后立即重绘整个缓冲，回滚区的行不被覆盖，光标回到提示符。
- `initTerminal: ConPTY screen buffer sync on Windows` 锁定 `Exec.initTerminal` 在 Windows 上关闭这两个字段，其他平台保持上游默认。
- 另有登记表与闭集检查。

## GX-0026 Windows exe 改用 Ghostty GX 的图标与版本信息

- 文件：`src/build/GhosttyExe.zig`，`init` 的 Windows 分支里 `addWin32ResourceFile` 的 `.file`。
- 标记：`fork(gx): GX-0026`，写在改动行的上一行。
- 状态：active，不回馈上游。
- 改动量：改 1 行路径，加 1 行注释。

### 原因

上游的 `dist/windows/ghostty.rc` 把 Ghostty 官方图标 `dist/windows/ghostty.ico` 编进 `ghostty.exe`，产品名写作 `Ghostty`。Ghostty 维护者要求非官方的构建、移植与分支不使用 Ghostty 的品牌，至少要讲明未获 Ghostty 团队认可（ghostty-org/ghostty discussions #2563）。Ghostty GX 的 Windows app 因此改用 fork 自己的图标与版本信息；资源文件只能经 `addWin32ResourceFile` 选定，没有构建参数可以替换，所以改这一行，资源本身放在 fork 路径。

### 行为

- `ghostty.exe` 编入 `dist/windows/gx/ghostty-gx.rc`：同一份上游 manifest（`../ghostty.manifest`，PerMonitorV2 DPI）与同一个图标 ID 1（`src/apprt/win32/win32.zig::IDI_GHOSTTY`），图标换成 `scripts/gx_icon.py` 生成的 `dist/windows/gx/ghostty-gx.ico`；版本信息的 `ProductName` 与 `FileDescription` 为 `Ghostty GX`，`CompanyName` 为 `gx0404`，`Comments` 是非官方分支声明。上游 rc 里的 `VS_VERSION_INFO` 没有定义成 1（没有包含 `winver.h`），Windows 读不到那份版本信息；fork 的 rc 补上了这个定义。
- 资源管理器、任务栏、标题栏、托盘气泡与安装包（`SetupIconFile` 也换成同一个 ico）都显示 Ghostty GX 图标。非 Windows 目标不受影响；`dist/windows/ghostty.rc` 与 `ghostty.ico` 保持上游原样，不再编进 fork 的 exe。

### 上游状态

不回馈上游：这是 fork 的品牌区分，上游继续使用自己的资源文件。

### 同步冲突处理

上游改动这段 Windows 资源代码时取上游版本，再把 `.file` 指回 `dist/windows/gx/ghostty-gx.rc` 并保留标记。上游改了 `ghostty.rc`（例如新增资源或改 manifest 名）时，把同样的变化搬进 `dist/windows/gx/ghostty-gx.rc`，图标与版本信息保持 fork 的。

### 移除条件

Ghostty GX 不再发布 Windows app，或改由不经过 `src/build/GhosttyExe.zig` 的构建产出 exe 时，删除改动与标记，把登记行改为 `removed`。

### 验证

```bash
python scripts/gx_icon.py --check
python scripts/zigw.py build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu -p <prefix>
python -m unittest scripts.test_fork_patches scripts.test_gx_icon -v
```

PowerShell 里 `[System.Diagnostics.FileVersionInfo]::GetVersionInfo('<prefix>\bin\ghostty.exe')` 的 `ProductName` 为 `Ghostty GX`；`[System.Drawing.Icon]::ExtractAssociatedIcon` 取出的是 `>_` 图标。GUI：启动 `<prefix>\bin\ghostty.exe`，截图读图确认标题栏左侧、任务栏按钮与 Alt+Tab 都是 Ghostty GX 图标。

### 测试锁定

- `scripts/test_fork_patches.py` 锁定标记与登记的闭集。
- `scripts/test_gx_icon.py` 锁定已提交的 ico 与生成器逐像素一致、尺寸齐全（16～256）、只有 256 像素是 PNG。
