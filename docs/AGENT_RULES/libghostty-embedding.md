# libghostty-embedding：只供 macOS app 的 libghostty-internal

## 范围

- `include/ghostty.h`：libghostty-internal 的 C 头。头注释写明唯一消费者是 macOS app，API 按它的需要裁剪、多数无文档、部分与 macOS/Metal 绑定；外部嵌入方应使用 libghostty-vt（`libghostty-vt.md`）。
- `include/module.modulemap`：Xcode 模块 `GhosttyKit`，umbrella header 为 `ghostty.h`。
- `src/main_c.zig`：库根，导出 `ghostty_init`、`ghostty_cli_try_action`、`ghostty_info`、`ghostty_translate`、`ghostty_string_free`，Windows 上另有 `DllMain`。
- `src/apprt/embedded.zig`：embedded apprt（`App`、`Surface`、`Inspector`、`Platform`）及 `CAPI`（`ghostty_app_*`、`ghostty_surface_*`、`ghostty_inspector_*`，Darwin 专用部分在 `CAPI.Darwin`）。
- `src/config/CApi.zig` 与 `src/config/c_get.zig`（`ghostty_config_*`）；`src/benchmark/CApi.zig`（`ghostty_benchmark_cli`）。
- `src/build/GhosttyLib.zig`：动态库、静态库、macOS universal 静态库与 `ghostty-internal` pkg-config。
- 相邻域：Swift 侧与 `src/build/GhosttyXCFramework.zig` 归 `macos-app.md`；`src/global.zig` 归 `app-core.md`；`test/windows/` 归 `testing.md`；与头文件逐项对应的 Zig 类型分散在 app-core、input、config、renderer、terminal-core 各域（清单见下）。

## 符号真源

- 构建分派：`build.zig::build` 在 `app_runtime == .none` 且未设 `-Demit-lib-vt` 时调用 `GhosttyLib.initShared`/`initStatic`；非 Darwin 目标安装 `include/ghostty.h` 与 `ghostty-internal.{dll,so}`、`ghostty-internal-static.lib`/`ghostty-internal.a`（Windows 上这两条链目前编译不过，见「不变量」的 Windows 条），Darwin 改由 XCFramework 打包。`src/apprt/runtime.zig::Runtime.default` 让 Windows、macOS 默认 `none`，Linux、FreeBSD 默认 `gtk`。
- apprt 选择：`src/build_config.zig::Artifact.detect` 把 `Lib` 输出判为 `.lib`，`src/apprt.zig::runtime` 随之取 `embedded`。
- 导出收集：`src/main_c.zig` 第二个 `comptime` 块引用 `config.CApi`、`apprt.runtime.CAPI`、`src/benchmark/main.zig::CApi` 与 `src/quirks_memset.zig`；不在这条引用链上的 `export fn` 不会进库。
- 运行时选项：`src/apprt/embedded.zig::App.Options`（即 `ghostty_runtime_config_s`，含 wakeup、action、剪贴板、close_surface 回调）、`Surface.Options`（即 `ghostty_surface_config_s`）、`PlatformTag`（0 保留为无效，macOS=1，iOS=2）。
- 配置读取：`src/config/c_get.zig::get` 规定字段写入方式：可空字符串（`?[:0]const u8`）写 `const char*`，值为 null 时写入 NULL 并返回 true，这是唯一不返回 false 的空值；`bool` 原样，`u8`/`u32` 写 `c_uint`，`i16` 写 `c_short`，浮点原样，枚举写 tag 名字符串，带 `cval()` 的 struct/union 写其 `C` 类型，不超过 `c_uint` 的 packed struct 写位模式；未知键、不支持的类型或空 optional 返回 false。
- 枚举同步检查：`src/lib/enum.zig::checkGhosttyHEnum`。`zig build test` 经 `build.zig::addGhosttyH` 用 translate-c 把头文件导入为 `@import("ghostty.h")`；现有调用点在 `src/apprt/action.zig`、`src/apprt/ipc.zig`、`src/renderer.zig`、`src/terminal/osc.zig`、`src/terminal/mouse.zig`。
- 只能人工同步的定义（源码注释写着 "update ghostty.h" 或 "Sync with"）：`src/apprt/action.zig` 中 `Action`、`Target` 的 `C`/`CValue` 及各值类型，`src/apprt/ipc.zig`，`src/apprt/structs.zig` 的剪贴板枚举，`src/input/key.zig::Key`、`Action`，`src/input/key_mods.zig::Mods`，`src/input/mouse.zig`，`src/input/Binding.zig::Trigger`，`src/config/Config.zig` 中标注的 `enum(c_int)`。
- Swift 消费点：`macos/Sources/App/main.swift`（`ghostty_init` 后 `ghostty_cli_try_action`）、`macos/Sources/Ghostty/Ghostty.App.swift::Ghostty.App`（填 `ghostty_runtime_config_s` 后调用 `ghostty_app_new`）、`macos/Sources/Ghostty/Ghostty.Config.swift::Ghostty.Config`（按键名调用 `ghostty_config_get`）。

## 不变量

- 定位：这是为 macOS app 服务的内部嵌入层，不是通用嵌入 API，也不承诺 ABI 稳定；但头文件与 Zig 必须在同一变更里保持一致，Swift 侧随之调整。
- 一一对应：枚举的顺序与取值、`extern struct` 的字段顺序与类型、函数签名在 `ghostty.h` 与 Zig 中逐项相同。新增 action 只追加到 `Action.Key` 末尾，并按 `src/apprt/action.zig::Action` 注释里的四步补齐 C 值类型与头文件。
- 检查覆盖面：`checkGhosttyHEnum` 要求 Zig 枚举是 `c_int` 且穷尽，每个成员都能在头文件中按「前缀 + 大写名」找到同值常量；头文件多出的常量查不出来，结构体布局与函数签名也没有自动检查，只能人工核对。
- `ghostty.h` 必须能被 translate-c 解析（`zig build test` 导入它；`_MSC_VER` 分支用 `SSIZE_T` 提供 `ssize_t`）。它的枚举不写 `_MAX_VALUE` 哨兵，那条规则只适用于 `include/ghostty/vt/`。
- 导出方式：本层用 `export fn ghostty_*` 直接导出（不同于 lib-vt 的 `@export` 表），所在文件必须在 `main_c.zig` 的引用链上；Darwin 专用函数放进 `CAPI.Darwin`，头文件里放在 `#ifdef __APPLE__` 下；每个声明带 `GHOSTTY_API`。
- 运行时断言：`src/main_c.zig` 在非测试编译时 comptime 断言 `apprt.runtime == apprt.embedded`，所以它只能作为库根编译；测试允许引用它，以便对 C API 做单测。
- 生命周期：宿主先调用 `ghostty_init` 初始化 `src/global.zig` 的全局状态（config、app、benchmark 各 API 都经 `global.alloc()` 分配），再按 config → app → surface 创建；`wakeup` 回调触发后调用 `ghostty_app_tick`。库分配的 `ghostty_string_s` 用 `ghostty_string_free` 释放，`ghostty_text_s` 用 `ghostty_surface_free_text`。
- 平台：surface 只能建在 Darwin 视图上（其他目标的 `Platform.MacOS`、`Platform.IOS` 为 `void`，`Platform.init` 返回 `UnsupportedPlatform`）；完整构建已不支持 iOS 目标，iOS 标签只为 ABI 保留。
- 头文件隔离：`src/build/GhosttyXCFramework.zig` 只拷贝 `ghostty.h` 与 `module.modulemap`，避免 vt 头触发 umbrella 告警；`ghostty.h` 不包含 `include/ghostty/vt/` 的任何头，`src/input/key.zig::Key` 等共享枚举同时决定两套头文件的取值。
- Windows：默认 `app-runtime=none`，构建图因此注册 `ghostty-internal.dll` 与 `ghostty-internal-static.lib`，但两条链目前都编译不过：`GhosttyLib.initShared`/`initStatic` 经 `src/build/SharedDeps.zig::add` 无条件加入 translate-c 导入 `posix_c`，MSVC 目标找不到其中的 `pwd.h`（`build-system.md`「平台」）。构建脚本里的 Windows 处理仍在：`GhosttyLib.initShared` 在 MSVC ABI 下链接 `libvcruntime`、`libucrt` 并探测 Windows SDK 的 ucrt 目录，`src/main_c.zig::DllMain` 手工初始化静态 CRT（Zig 未处理 MSVC DLL 的 CRT 启动，属临时绕过）。C API 本身在 Windows 上也尚不受支持：`global.init` 的 `.c` 分支返回 `error.UnsupportedOSForCApi`，`ghostty_init` 因此失败，只有不依赖全局状态的函数（如 `ghostty_info`）可用。
- 版本：`ghostty_info` 与 `ghostty-internal` 的 pkg-config 用 app 版本，与 lib-vt 的 `lib_version` 无关。`ghostty_benchmark_cli` 目前总是导出（源码注释说将来可能按构建选项门控）。

## 禁止项

- 不把 `ghostty.h` 当对外 API 推广：示例、CMake、pkg-config 说明与发布物都不引导第三方使用它，外部需求一律指向 libghostty-vt。
- 不单改头文件或单改 Zig；不在枚举、action 列表或 extern struct 中间插入、重排或改值。
- 不改 `include/module.modulemap` 的模块名 `GhosttyKit`，不把 vt 头加进它，也不让 `ghostty.h` 与 vt 头互相包含。
- 不在 `main_c.zig` 引用链之外放 `export fn`，不另起导出收集方式。
- 不声称在 Windows 上构建或验证过 `ghostty-internal.dll`（目前编译不过），也不把它当可运行的终端交付；为在 Windows 编出它或启用 C API 而改上游源码，必须先按 `docs/FORK_PATCHES.md` 登记 `fork(gx)` 补丁。

## 验证

- 枚举同步：`just test --filter ghostty.h`，跑全部 `test "ghostty.h …"`（需要 translate-c 能解析头文件）；CI 上由 gx-ci `linux-main` job（`-Dapp-runtime=none` 的完整主测试）覆盖。
- 配置读取与字符串所有权：`just test --filter ghostty_config_get`、`just test --filter c_get`、`just test --filter ghostty_string_s`。
- Windows 本机：没有本域的编译检查。`just build` 构建 `ghostty-internal.dll`、`ghostty-internal-static.lib` 时停在 `translate-c posix_c.h`（`'pwd.h' not found`），以退出码 1 结束；`ghostty-test` 同样编不过，`just test` 直接退出 2。主测试交 gx-ci `linux-main`，本机记 PENDING；DLL 装载回归 `test/windows/test_dll_init.c`（步骤见 `test/windows/README.md`）要先有 DLL，目前无法执行，记 PENDING 并注明受阻。
- Linux：`just build -Dapp-runtime=none` 产出 `ghostty-internal.so`（与上游 `build-linux-libghostty` job 同款）。
- macOS：XCFramework 与 app 只能在 Mac 上按 `macos/AGENTS.md` 用 `macos/build.nu` 构建，本机 Windows 记 PENDING。gx-ci 手动触发的 `macos` job 只跑 `test-lib-vt`，覆盖不到 `ghostty.h`；端到端构建 app 的只有 `gx-release` 的可选 `macos` job（见 `ci-release.md`）。
- 改 Zig 源码一律跑 `just fmt-check`；改 Swift 按 `macos/AGENTS.md` 跑 swiftlint。

## 上游指令

- `macos/AGENTS.md`：唯一消费方 macOS app 的构建、测试与 AppleScript 约定。
- `src/benchmark/AGENTS.md`：`ghostty_benchmark_cli` 背后的 benchmark 工具与测量纪律。
