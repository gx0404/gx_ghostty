# fork 补丁登记

本文件登记 gx_ghostty 对上游源码的全部修改（fork 补丁），也是 `scripts/test_fork_patches.py` 解析的机器可读真源。fork 自有的新路径，以及根 `AGENTS.md`、`.gitignore`、`.prettierignore` 末尾带标记的追加段，不是源码补丁，不在此登记。

## 规则

- 范围：`src/`、`include/`、`pkg/`、`macos/` 下的文件与 `build.zig`。改动这些上游文件必须登记；能用新路径或构建参数解决的问题，不改上游源码。
- 编号：`GX-NNNN`，四位数字，按登记顺序递增，永不复用。
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
| GX-0010 | `src/config/Config.zig` | `fork(gx): GX-0010` | active |
| GX-0012 | `src/Surface.zig` | `fork(gx): GX-0012` | active |
| GX-0012 | `src/termio/Exec.zig` | `fork(gx): GX-0012` | active |
| GX-0016 | `src/apprt/gtk/class/application.zig` | `fork(gx): GX-0016` | active |
| GX-0016 | `src/apprt/gtk/class/window.zig` | `fork(gx): GX-0016` | active |
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
| 不以 `v` 开头的 tag，如 `gx-v0.1.0` | panic | 分支预发布版本 `X.Y.Z-<branch>+<hash>` |

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
- Windows 原生（MSVC）编译不出 `ghostty-test`：`src/build/SharedDeps.zig::add` 对所有目标 translate-c `posix_c`（含 `pwd.h`，Zig 自带的 mingw 头文件也没有它），上游 `test` 在 Windows 同样失败于 `'pwd.h' not found`；临时跳过 `posix_c` 后，编译又停在 `src/renderer/Dmabuf.zig` 用 `-1` 初始化 `std.posix.fd_t`（Windows 上是句柄指针）。`test-bin` 只在能编译 `ghostty-test` 的平台（Linux、macOS）有产物。

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
- 改动量：12 个文件，`git diff --numstat` 合计 +60/−15（含注释）。

### 原因

本 fork 要在 Windows 上产出可运行的原生应用。apprt 本体是新路径 `src/apprt/win32.zig` 与 `src/apprt/win32/**`（移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c，各文件头注明出处），不是源码补丁；但上游代码在三处把 apprt 集合写死，必须改上游文件才能接入：

- `src/apprt/runtime.zig::Runtime` 是 apprt 的闭集，`src/apprt.zig::runtime` 按它编译期选实现；多个类型的 `getGObjectType` 与 `Config.finalize` 对 `app_runtime` 穷举，新增成员不补分支就编译失败。
- `src/build/SharedDeps.zig::add` 对所有目标 translate-c `posix_c`（含 `pwd.h`），Windows 目标找不到该头文件，任何非 vt 产物都编不过；win32 apprt 还要链接 user32、gdi32 等系统库。
- GUI 子系统的 exe 没有控制台，`logFn` 写 stderr 的日志全部丢失；`quit-after-last-window-closed` 上游只在 Linux 默认开启，Windows 上关掉最后一个窗口后进程会无窗口地留在后台。

### 行为

- Windows 目标未给 `-Dapp-runtime` 时默认 `win32`，`zig build -Dtarget=x86_64-windows-gnu` 产出 `zig-out/bin/ghostty.exe`（`just build` 在 Windows 主机上自动补这个目标，见 `scripts/zig_build.py`）。Linux/FreeBSD 仍默认 `gtk`，其余目标仍默认 `none`。
- Windows 目标不再导入 `posix_c` 模块；与上游 PR #14608 的同一行守卫一致。非 Windows 目标不变。
- `.win32` 且目标是 Windows 时链接 opengl32、gdi32、user32、dwmapi、imm32、shell32、ole32、uxtheme、comctl32、comdlg32、advapi32。
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

`ghostty-test` 在 Windows 上编译不过，以下命令在 Linux（或 WSL）运行：

```bash
python3 scripts/zig_test.py --suite main -Dapp-runtime=none --filter gx. --filter config --filter cli.
python3 scripts/zigw.py build -Dapp-runtime=none -Demit-webdata
python3 -m unittest scripts.test_fork_patches -v
```

- 第一条覆盖 `src/gx/**` 全部单测（层序、主题覆盖、明暗切换、`-e`、`config-default-files=false`、诊断保留、默认值内容）与上游配置、CLI 单测。
- 第二条运行 helpgen 与 webgen，确认新键的文档注释能生成配置文档。

### 测试锁定

`scripts/test_fork_patches.py` 的登记表与闭集检查覆盖 GX-0010：标记必须存在于 `src/config/Config.zig`，四对 `begin`/`end` 成对且不嵌套。行为由 `src/gx/config_layers.zig` 的单测锁定，其中两条覆盖诊断重放（GX 分层与上游路径各一条）。

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
just wsl test --filter gx.confirm                                                # Linux 单测（-Dapp-runtime=none）
just wsl build --gtk
python -m unittest scripts.test_fork_patches -v
```

GTK 冒烟：配置 `shell-integration = none` 与 `command = /bin/bash --noprofile --norc`，开两个标签页，空闲标签页 `Ctrl+Shift+W` 直接关闭，运行 `sleep 100` 的标签页弹出关闭确认；Debug 构建日志里有 `gx_confirm` 的判定行。Windows：`cmd.exe`、`pwsh.exe` 空闲时关闭标签页不确认，运行 `vim` 时确认。

### 测试锁定

只有登记表与闭集检查（见 GX-0001 的「测试锁定」）。判定由 `src/gx/confirm.zig` 的单测锁定，经 GX-0010 的 `test` 块进入 `ghostty-test`。

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
