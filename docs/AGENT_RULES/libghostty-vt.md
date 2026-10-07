# libghostty-vt：对外 C ABI 终端库

## 范围

- 头文件 `include/ghostty/vt.h`（汇总包含与 Doxygen 首页）与 `include/ghostty/vt/**/*.h`；C API 实现 `src/terminal/c/**`；库根 `src/lib_vt.zig`；构建 `src/build/GhosttyLibVt.zig`（模块组装 `src/build/GhosttyZig.zig` 归 `build-system.md`）。
- 随库编译、同样登记在本域路由里的共享代码（改动时两边规则都要满足）：`src/input/` 的编码器 `{key,key_encode,mouse,mouse_encode,paste}.zig` 及其传递导入 `{config,function_keys,key_mods,kitty}.zig`（另见 `input.md`）；`src/os/{mach,stderr,string_encoding,windows}.zig` 与 `src/os/wasm/**`（另见 `termio-pty-os.md`）；鼠标编码用到的 `src/renderer/size.zig`（另见 `renderer.md`）；`src/lib/**`（另见 `support-libs.md`）。
- 消费与发布面：`example/**`、CMake（`CMakeLists.txt`、`dist/cmake/**`）、Doxygen（`Doxyfile`、`DoxygenLayout.xml`、`dist/doxygen/**`、`src/build/docker/lib-c-docs/**`），以及 nix 包、wasm 与 fuzz 测试、Apple/Android 构建辅助（清单见 `routes.toml`）。
- 终端状态机见 `terminal-core.md`，`include/ghostty.h` 见 `libghostty-embedding.md`，源码包机制见 `packaging-dist.md`。
- 下游背景（只读）：herdr（`gx0404/herdr`，见其 `vendor/libghostty-vt.vendor.json`）vendor 的是 lib-vt 源码包，并用 bindgen 从 `vt.h` 生成绑定，目前取自上游；本仓不改 herdr，但 C ABI、工件名与源码包内容的变化会传导过去。

## 符号真源

- Zig 公开面 `src/lib_vt.zig`：`sys` 即 `src/terminal/sys.zig`（启动时可替换的 `decode_png`、`random_secure`），`TinyIo` 即 `src/lib/TinyIo.zig`，`input`、`unicode` 只挑具体文件导入。C 侧 sys 为 `src/terminal/c/sys.zig::Option`，经 `ghostty_sys_set` 安装；C ABI 构建的 std.log 经 `src/terminal/c/sys.zig::logFn` 交给嵌入方回调。
- C 导出表：`src/lib_vt.zig` 顶层 `comptime` 的 `@import("root") == lib` 守卫块，按 `terminal.options` 的 feature 位分组 `@export`；实现别名集中在 `src/terminal/c/main.zig`。
- feature 门：`src/terminal/build_options.zig::Options.Features`（`-Dvt-features`，app 恒为全开）；`Options.kittyGraphics` 在 freestanding 上恒关。
- ABI 工具：`src/terminal/lib.zig` 转出 `calling_conv`、`Enum`、`TaggedUnion`、`Struct`、`structSizedFieldFits`、`alloc`；返回码 `src/terminal/c/result.zig::Result` 即 `GhosttyResult`；头文件宏 `GHOSTTY_API`、`GHOSTTY_ENUM_TYPED`、`GHOSTTY_ENUM_MAX_VALUE`、`GHOSTTY_INIT_SIZED` 在 `include/ghostty/vt/types.h`。
- ABI 清单：`src/terminal/c/types.zig::type_decls` 生成 `ghostty_type_json`，格式真源 `src/terminal/c/types.schema.json`（`schema` 恒为 1）；`build.zig` 的 `test-lib-vt-schema` 用 `python3` 跑 `types-schema-verify.py` 校验刚构建的库（原生走 ctypes，`.wasm` 走 wasmtime）。
- 版本：`build.zig::lib_version`（当前 `0.1.0-dev`，`-Dlib-version-string` 可覆盖）决定 so/dylib 版本名、pkg-config `Version` 与清单的 `library_version`。
- 工件：`src/build/GhosttyLibVt.zig` 的 `initShared`、`initStatic`、`initWasm`、`initStaticAppleUniversal`、`xcframework`，安装规则在 `build.zig::build`；CMake 入口 `CMakeLists.txt`（`ghostty-vt`、`ghostty-vt-static` 目标与 `ghostty_vt_add_target()`）；源码包 `src/build/GhosttyDist.zig::init` 与 `lib_vt_excludes`。

## 不变量

### ABI 形状

- API 尚未承诺稳定，但必须 ABI 友好：长寿命对象用不透明句柄（`typedef struct GhosttyXxxImpl* GhosttyXxx`）配 `_free`；可增长结构用 sized struct；确定不再增长的结构可留定长 `_padding`；Zig tagged union 经 `lib.TaggedUnion` 转成 C 联合，`options.padding` 定死尺寸，不符即编译失败。
- sized struct 首字段为 `size: usize = @sizeOf(Self)`，C 调用方用 `GHOSTTY_INIT_SIZED(T)` 初始化；实现先用 `lib.structSizedFieldFits` 判断调用方的 `size` 是否覆盖某字段，所以新字段只能追加在末尾。
- `include/ghostty/vt/` 的 C 枚举写成 `typedef enum GHOSTTY_ENUM_TYPED { … }`，末项 `<前缀>MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE`（`INT_MAX`），保证 pre-C23 编译器按 int 布局；Zig 侧 tag 为 `c_int`，`lib.Enum(.c, keys)` 以下标为值、删除项用 `null` 占位。清单的哨兵名取 `TypeDecl.sentinel_suffix`，前缀拼不出时用 `initEnumSentinel`（如 `GHOSTTY_RESULT_MAX_VALUE`）。
- 头文件手写，没有测试逐项比对 Zig（`checkGhosttyHEnum` 只查 `ghostty.h`），清单则由 Zig 生成；改枚举值或结构布局要人工对照头文件。
- 函数用 `callconv(lib.calling_conv)` 返回 `Result`；分配器参数可传 NULL（原生 freestanding 上默认分配器恒失败，嵌入方须自带）；构造失败时 out 句柄置 NULL。库分配的内存用 `ghostty_free` 配同一分配器释放，Windows 上不能用 C `free()`。
- `src/input/key.zig::Key`、`Action` 与 `src/input/mouse.zig::Button` 同时决定 vt 的 `GhosttyKey`、`GhosttyKeyAction`、`GhosttyMouseButton` 与 `ghostty.h` 的同类枚举，改它们就是同时改两套 ABI。

### 导出链

新增或改名 C 函数，四步缺一不可（原文见 `src/terminal/c/AGENTS.md`）：① `src/terminal/c/<module>.zig` 实现；② `src/terminal/c/main.zig` 加 `pub const <module>_<name>`；③ `src/lib_vt.zig` 守卫块中所属 feature 分组 `@export(&c.<alias>, .{ .name = "ghostty_<…>" })`，跨 feature 照现有组合条件（如 `features.formatter and features.selection`）；④ `include/ghostty/vt/<module>.h` 用 `GHOSTTY_API` 声明并写 Doxygen 注释（`Doxyfile` 设了 `HIDE_UNDOC_MEMBERS`），新头文件加进 `vt.h` 汇总。新公开类型同时登记到 `src/terminal/c/types.zig::type_decls`：清单测试要求条目一一对应、字段引用的类型都已登记。

### 构建边界

- C 导出、MSVC 静态库的 `_fltused`、对 `quirks_memset.zig` 的引用只在 root 守卫内，以 `dep.module("ghostty-vt")` 消费的 Zig 项目不会被注入这些符号。
- lib 模块只能用 `src/build/GhosttyZig.zig::initVt` 注册的依赖，oniguruma 恒关（因而没有 tmux control mode）。`src/global.zig` 在 lib 工件里直接 `@compileError`；apprt、font、整个 renderer 包都不得进入引用链（只依赖 `src/terminal/size.zig` 的 `src/renderer/size.zig` 除外）。
- freestanding 与 wasm 默认 `-Dsimd=false`：不链接 libc，不构建 highway、simdutf 与 `src/simd/*.cpp`，`src/simd/main.zig` 仍被导入但走纯 Zig 回退；wasm 默认开 simd128（`-Dcpu=generic` 退出）。原生 freestanding 不产动态库，静态库不开 PIC，也没有 `test-lib-vt-schema`。
- 体积门：ReleaseFast、ReleaseSmall 与原生 freestanding 关闭 std 调试机制，触达 `std.debug.print`、`std.debug.lockStderr` 或默认 std.log 处理器即撞上 `src/lib_vt.zig::std_options_debug_io` 的 `@compileError`；诊断走 `std.log` 或 `src/os/stderr.zig`。
- wasm：`GhosttyLibVt.initWasm` 产出无入口的 `ghostty-vt.wasm`，由 `src/build/wasm_patch_growable_table.zig` 去掉函数表上限，另导出 `ghostty_wasm_*`；Debug 版日志调用宿主导入 `env.log`，其余优化级别为空操作。
- `std.Io` 由嵌入方注入；`TinyIo` 在 wasi、freestanding 上退化为 `std.Io.failing`，安全随机数改由 `sys.random_secure` 提供。sys 选项是进程级全局，须在用到相关功能前设置，传 NULL 即关闭对应能力。
- Windows：动态库靠 `src/lib/windows_dll.zig` 的 `DllMain` 手工跑全局构造器，否则 simdutf 遇多字节 UTF-8 即空指针崩溃；静态库消费方要链接 `ntdll`、`kernel32` 并定义 `GHOSTTY_STATIC`；未指定 ABI 时默认 MSVC，需要 VS BuildTools 与 Windows SDK。

### 工件、版本与源码包

- 工件名是下游契约：Zig 工件 `ghostty-vt`、`ghostty-vt-static`；Windows 为 `bin/ghostty-vt.dll`、导入库 `lib/ghostty-vt.lib`、静态库 `ghostty-vt-static.lib`（避免与导入库重名），其他平台 `libghostty-vt.{so,dylib,a}`；`libghostty-vt.pc`、`libghostty-vt-static.pc`；`bin/ghostty-vt.wasm`；`lib/ghostty-vt.xcframework`（Swift 模块 `GhosttyVt`，不复用 `include/module.modulemap`）。作为 Zig 依赖被引用时 `-Demit-lib-vt` 默认开启。
- `lib_version` 独立于 app 版本，fork 的 `-Dversion-string` 只影响 app 版本与源码包名。`CMakeLists.txt` 写死了 `0.1.0`（`project` 版本与 `.so.0.1.0`、`.0.1.0.dylib` 实名），`nix/libghostty-vt.nix` 也写死版本串，lib 版本变化须同步这些位置。
- `just dist-vt` 产出 `zig-out/dist/libghostty-vt-<app 版本>.tar.gz`：内容取自 `git archive HEAD`（未提交改动不进包），附 `VERSION` 文件，按 `lib_vt_excludes` 排除 `example`、`test`、`vendor`、`po`、`macos`、`images`、`dist/doxygen` 等；lib-vt 构建、`test-lib-vt` 与 CMake 包装都不能依赖被排除的路径。distcheck 在解包目录跑 `zig build test-lib-vt -Demit-lib-vt=true` 与 cmake 构建，上游 CI 另卡 5 MiB 上限。
- 改清单格式要同时改 `types.schema.json`、`types.h` 的文档示例与校验脚本；该 schema 还被 `Doxyfile` 的 `HTML_EXTRA_FILES` 与 lib-c-docs 的 Dockerfile 引用。

### 示例与 CMake

- 示例是独立工程；上游 CI（已归档）按 `example/*/build.zig.zon`、`CMakeLists.txt`、`Package.swift` 自动发现，fork 的 `gx-ci.yml` 只在 windows job 构建 `example/c-vt-static`，其余要本地验证。
- 新示例换新的随机 `.fingerprint`，`.minimum_zig_version` 跟现有示例一致（不随根 `build.zig.zon` 变），可执行名用下划线；静态链接示例链接 `ghostty-vt-static` 并定义 `GHOSTTY_STATIC`。
- 头文件只用 `@snippet <dir>/src/main.c <name>` 引用示例，源码用成对的 `//! [name]` 标记界定；改示例时同步标记与引用它的头文件。
- `CMakeLists.txt` 用 `find_program` 调 PATH 上的 zig，不经过 `scripts/zigw.py`；`dist/cmake/GhosttyZigCompiler.cmake` 必须在 `project()` 之前 include，不能经 FetchContent 使用。

## 禁止项

- 不跳过导出链任何一步，不把导出写在守卫外或放错 feature 分组，不用 `export fn` 绕开导出表。
- 不重排、不中间插入、不改动已有枚举值，不删或改名 `_MAX_VALUE` 哨兵；不改 sized struct 已有字段的顺序与类型，不改 `_padding` 尺寸。
- 不让 `src/global.zig`、apprt、font、oniguruma、libc 硬依赖或 `std.debug.print` 进入 lib-vt 引用链。
- 不在头文件内联复制示例代码；vt 头与 `include/ghostty.h` 不互相包含，同一翻译单元也不同时包含两者（`GHOSTTY_SUCCESS`、`GHOSTTY_KEY_*` 等常量同名）。
- 不为 fork 发布改 `build.zig::lib_version`、工件名、pkg-config 名或 CMake 目标名；确需改上游源码时按 `docs/FORK_PATCHES.md` 登记 `fork(gx)` 补丁。
- 不修改 herdr，也不在本仓为它写定制逻辑。

## 验证

- 定向：`just test-vt -Dtest-filter=<filter>`，同时跑 `ghostty-vt`（Zig API）与 `ghostty-vt-c`（C ABI）两个模块，清单测试也在内；全量 `just test-vt` 属于 `just ci-check`。
- Windows 环境前置：未开开发者模式（也不是管理员）时，全量 `just test-vt` 固定有 4 处失败，都是 `src/lib/tinyio` 的符号链接用例报 `PermissionDenied`。这不是回归：记 FAIL 并写明原因，不跳过、不修改这些上游用例，开启开发者模式后重跑（见 `docs/TESTING.md`「Windows 本机限制」）。
- 构建：`just build-vt`；交叉 `just build-vt -Dtarget=<triple>`（同 gx-ci 的 `lib-vt-cross` 矩阵）；freestanding 抽查 `just build-vt -Dtarget=thumb-freestanding-eabi -Dcpu=cortex_m4 -Doptimize=ReleaseSafe`。
- wasm：`just vt-wasm`；有 Node 时加跑上游的 `node test/wasm-alloc.mjs zig-out/bin/ghostty-vt.wasm`。
- feature 组合：`just zig build test-lib-vt-build "-Dvt-features=-all,+render-state"` 只编译；覆盖导出块再跑 `just build-vt "-Dvt-features=-all,+render-state" -Dtarget=wasm32-freestanding`。
- ABI 清单：`just zig build test-lib-vt-schema`，需要 `python3` 与 `jsonschema`（wasm 另需 `wasmtime`，上游由 `nix develop` 提供）；本机缺依赖时如实记 FAIL 或 PENDING，CI 由 `gx-ci.yml` 的 linux job 运行。
- 源码包：`just dist-vt`；完整校验 `just zig build distcheck -Demit-lib-vt=true`，其内层构建按 PATH 查找 zig 与 cmake（见 `packaging-dist.md`）。
- 改与 app 共用的 `src/input/` 编码文件时再加 `just test -Dtest-filter=<name>`（Windows 上完整 `just test` 只是尽力而为）。
- 改示例：在 `example/<dir>` 内运行 `python ../../scripts/zigw.py build`（用钉版 Zig 执行上游的 `zig build`；Linux/macOS 用 `python3`）；改头文件注释或示例标记：仓库根运行 `doxygen`（本机未装记 PENDING）；改 Zig 源码一律 `just fmt-check`。

## 上游指令

- `src/terminal/c/AGENTS.md`：C API 的 ABI 设计与四步导出（权威原文）。
- `example/AGENTS.md`：示例工程模板、fingerprint 与 `@snippet` 约定。
- `test/fuzz-libghostty/AGENTS.md`：AFL++ fuzz 的构建、语料与崩溃复现。
- 根 `AGENTS.md` 上游段「libghostty-vt」小节：构建、wasm、测试命令与 `_MAX_VALUE` 哨兵规则。
