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
