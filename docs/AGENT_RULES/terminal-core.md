# terminal-core：终端仿真核心、SIMD 与 Unicode

## 范围

- `src/terminal/**`：VT 解析与分派、终端状态与页存储、协议子系统（OSC、kitty、APC/glyph、DCS、tmux 控制模式）、渲染读路径、搜索、快照序列化、页压缩、formatter 与选区。`src/terminal/c/**` 同属 libghostty-vt 域，C ABI 以 `docs/AGENT_RULES/libghostty-vt.md` 为准。
- `src/simd/**`、`src/unicode/**`，以及 vendored C++ 依赖的构建包装 `pkg/highway/**`、`pkg/simdutf/**`（同时命中 build-system 域）。
- 本域同时编进 Ghostty app（`artifact = .ghostty`）与 libghostty-vt（`artifact = .lib`，另有 `c_abi` 变体），改动要按两种产物评估。

数据流：PTY 字节 → `Stream`（`Parser` 状态机、UTF-8 解码、SIMD 快路径）→ handler 的 `vt(comptime action, value)` → `Terminal` → `Screen` / `PageList` / `Page` → `RenderState` 供渲染器读取。

## 符号真源

- 模块根：`src/terminal/main.zig` 是 app 使用面；libghostty-vt 的 Zig 公开面在 `src/lib_vt.zig`，两者分开维护，新增公开符号要决定是否进入 lib 面。
- 构建开关：`src/terminal/build_options.zig::Options`（经 `terminal_options` 模块注入）含 `artifact`、`oniguruma`、`simd`、`slow_runtime_safety`、`c_abi`、`features`（`-Dvt-features`，只作用于 lib）。`tmux_control_mode` 由 `oniguruma` 合成，`Options.kittyGraphics` 在 freestanding 上关闭 kitty graphics。取值见 `src/build/Config.zig::terminalOptions`；`src/build/GhosttyZig.zig::initInner` 为 lib 关闭 oniguruma 并派生 `c_abi` 变体。
- 解析：`src/terminal/Parser.zig::Parser`（vt100.net 状态机，转移表 `src/terminal/parse_table.zig::table` 编译期生成）→ `src/terminal/stream.zig::Stream` 与 `src/terminal/stream.zig::Action`；子解析在 `src/terminal/osc/parsers/`、`src/terminal/apc.zig::Handler`、`src/terminal/dcs.zig::Handler`。
- handler：`src/terminal/stream_terminal.zig::Handler` 供 libghostty-vt 与 `Terminal.vtStream` 使用，默认只读，副作用走 `Handler.Effects`；app 用 termio 域的 `src/termio/stream_handler.zig::StreamHandler`。
- 状态链：`src/terminal/Terminal.zig::Terminal` → `src/terminal/ScreenSet.zig::ScreenSet`（primary 常驻，alternate 按需创建，`generations` 区分重建）→ `src/terminal/Screen.zig::Screen` → `src/terminal/PageList.zig::PageList`（页链表、viewport、tracked pin、scrollback 上限、压缩策略）→ `src/terminal/page.zig::Page` / `Row` / `Cell`。
- 坐标：`src/terminal/point.zig::Point`、`src/terminal/PageList.zig::Pin`、`src/terminal/highlight.zig::Untracked` / `Tracked` / `Flattened`。
- 渲染读路径 `src/terminal/render.zig::RenderState`；搜索器汇总在 `src/terminal/search.zig`，搜索线程 `src/terminal/search/Thread.zig::Thread` 只在 `artifact == .ghostty` 时存在（依赖 xev）。
- 压缩：策略 `src/terminal/PageList.zig::compress`，入口 `src/terminal/Terminal.zig::compress` 与 `compressionActivity`，codec 在 `src/terminal/compress.zig`，虚拟内存原语在 `src/terminal/mem.zig`。
- 快照：格式说明在 `src/terminal/snapshot/main.zig`，入口 `src/terminal/snapshot/snapshot.zig::encode` / `decode` / `Decoder`，schema `src/terminal/snapshot/snapshot.ksy`，金样 `src/terminal/snapshot/testdata/*-v1.hex`（工具 `src/terminal/snapshot/fixture.zig`）。
- 外部钩子：`src/terminal/sys.zig::decode_png`（app 默认 wuffs，lib 默认 null）、`src/terminal/sys.zig::random_secure`。
- SIMD 入口 `src/simd/main.zig`，C++ 源 `src/simd/*.cpp` 由 `src/build/SharedDeps.zig::addSimd` 编译。
- Unicode 入口 `src/unicode/main.zig`、`src/unicode/props.zig::Properties`；查找表由 `src/unicode/props_uucode.zig::main` 与 `src/unicode/symbols_uucode.zig::main` 在构建期生成，经 `src/build/UnicodeTables.zig` 注入为 `unicode_tables` / `symbols_tables` 模块，uucode 字段在 `src/build/uucode_config.zig`。

## 不变量

页与内存：

- `Page` 是一块页对齐、清零的连续内存，内部引用一律是相对页基址的 `src/terminal/size.zig::Offset`，所以整页可以浅拷贝、压缩、原地恢复。
- `Cell`、`Row` 是 `packed struct(u64)`，`Cell` 零值必须是合法空单元格；字素、样式、超链接、字符串都在页内，搬移单元格要同步 `grapheme_map` 与 `hyperlink_map`。
- 页内容量不足（如 `StyleSetOutOfMemory`）走 `PageList.increaseCapacity`，它换新节点，旧节点指针失效。
- `Row` 的 `styled`、`hyperlink`、`grapheme`、`semantic_prompt`、`dirty` 允许假阳性，不允许假阴性。
- 节点的 `owned`（pool 或 heap）显式记录，不得从内存长度推断；页回池前必须清零。页分配器见 `src/terminal/PageList.zig::pageAllocator`：wasm 非测试构建用 `WasmPagePool`，native freestanding 用嵌入方分配器。
- `Node.page()` 会解压已压缩页；只要行列或容量用 `rows()` / `cols()` / `capacity()`，只读且不改存储形态用 `pagePreservingState`。

Pin 与代际：

- 未 tracked 的 `Pin` 只在 PageList 未修改期间有效；跨修改用 `trackPin` / `untrackPin` 成对管理。tracked pin 有维护成本，数量要少；所指页被裁剪且无处可挪时置 `garbage`。
- `Screen.selection` 必须是 tracked 选区，只经 `Screen.select` 设置。
- 页代际（`List.Node.serial`、`page_serial_epoch`、`PageList.nodeIsValid`）判断旧引用是否仍指同一代页；`RenderState.Row` 的 `pin` 在释放终端锁后只能比较值，不能解引用 `pin.node`。
- `Screen.Cursor` 缓存 `page_row` / `page_cell` 指针，页结构变化后用 `Screen.cursorReload` 刷新；光标 `style_id` 是页内 ID，换页要重新登记样式。

线程与锁：

- `Terminal` 及其子结构不是线程安全的。app 中 termio、渲染、搜索线程共用 `renderer_state.mutex`，锁协议见 `termio-pty-os.md` 与 `renderer.md`。
- `RenderState.beginUpdate` 必须持锁，`endUpdate` 只碰 RenderState 自有内存、应在锁外调用。`beginUpdate` 读取并清零 Terminal、Screen、Page、Row 的 dirty 标志，所以一个 Terminal 只挂一个增量渲染消费者。
- 搜索线程只在 `feedLocked`、`select`、`changeNeedle` 等处持 `Thread.Options.mutex`；事件回调跑在搜索线程上，`viewport_matches` 切片只在回调期间有效。
- `src/Surface.zig::searchCallback` 先用 arena 复制 `highlight.Flattened`，再转成渲染线程消息 `search_viewport_matches` / `search_selected_match` 和 surface 消息 `search_total` / `search_selected`。`Terminal.flags.search_viewport_dirty` 由渲染器在 render state 变脏时置位、搜索线程消费。

解析与协议：

- `Stream.Action` 新增 tag 时，两个 handler 的 `vtFallible` 都是穷举 switch，都要处理（或显式归入无副作用分支）。
- `Terminal.vtStream` 每次返回全新解析状态，跨写入要复用同一个 stream；不传 allocator 的 `Stream` 不分配内存，并丢弃 OSC 52 这类需要堆的操作。
- handler 是 best-effort：出错只置 `Handler.semantic_failure` 并继续，流不能停在半途。
- 安全默认：`Handler.title_report`（CSI 21 t）与 `Handler.xt_checksum_report`（DECRQCRA、XTCHECKSUM）默认关闭，打开会把攻击者可控内容回写 PTY，或允许逐格读出屏幕。
- 来自 PTY 的变长输入都要有上限：APC handler 的 `max_bytes` / `unknown_max_bytes`、OSC 的 `unknown_max_bytes`、`src/terminal/tmux/control.zig::Parser.max_bytes`、kitty 剪贴板写入上限、kitty 图像存储上限与 `LimitedAllocator`。
- `Terminal.printSlice` 快路径必须与逐码点 `print` 结果一致；流式打印的宽度与 `graphemeWidth` 一致，宽度决策集中在 `src/unicode/grapheme.zig::graphemeWidthEffect`。
- 行为对齐主流终端：协议数字用 `src/lib/parse_int.zig::parseInt`（理由见 `support-libs.md`）；kitty 剪贴板以 kitty 参考实现为准（`src/terminal/kitty/clipboard.zig` 文件头）。
- `src/terminal/osc.zig::Command` 有编译期尺寸断言（64 位目标为 64 字节）；`src/terminal/modes.zig` 的 `entries` 新增 mode 时同步 `include/ghostty/vt/modes.h` 的 `GHOSTTY_MODE_*`。
- 本域已进入 C ABI 的 `lib.Enum` 枚举（如 `Terminal.CompressionMode`、`RenderState.Dirty`、`ScreenSet.Key`）受 `support-libs.md` 的枚举序号规则约束，只能追加，删除留 `null` 空洞。

构建与 freestanding：

- 本域代码必须满足 libghostty-vt 的产物级约束：可构建到 `wasm32-freestanding`、lib 不启用 oniguruma、`src/global.zig` 不进引用链、release 体积门禁止 std 调试 IO，细节见 `libghostty-vt.md`。落到本域的含义：tmux 控制模式与 `StringMap` 正则只存在于 app 产物；依赖 `src/global.zig` 的代码只能放在按 `artifact == .ghostty` 门控的文件里（如搜索线程）；日志一律用 `std.log.scoped`。
- `src/simd` 每个例程都要有同语义的纯 Zig 回退，`simd` 构建选项关闭时走回退；回退仍可用 `@Vector`，`simd.lanes` 返回 null 时退到标量循环。
- SIMD 路径依赖 libc；vendored 的 Highway 与 simdutf 以 `HWY_NO_LIBCXX` / `SIMDUTF_NO_LIBCXX` 编译，不得引入 libc++ 运行时依赖。
- 慢速校验（`Page.verifyIntegrity`、`PageList.pinIsValid`）只在 `slow_runtime_safety`（Debug）下运行。

压缩、快照与 Unicode：

- 压缩策略只放在 `PageList`，`src/terminal/compress/lz4.zig` 只依赖 std；只压缩 active 边界之前、且不与 viewport 相交的完整历史页。
- `src/terminal/mem.zig::canReclaim` 的 strict 模式只在 64 位 Linux、Darwin、Windows 上为真（测试构建恒真），否则 `compress` 返回 `unsupported`；恢复不可失败，解码错误按内部损坏 panic。调用方以 `compressionActivity` 变化为调度信号，app 由渲染线程调用 `compress(.incremental)`。
- 快照格式 v1 仍在演进，不承诺二进制兼容；每条记录各带 CRC32C（`src/crc32c.zig`），READY 之前是可渲染状态与 continuation，之后是历史页。改线格式要同步 `snapshot.ksy` 与对应金样，必要时升 `src/terminal/snapshot/envelope.zig::version` 并为新版本另建金样，不覆盖旧版本。
- `Decoded.toOwned` 会移动 Terminal：先放到最终地址，再建持久 Stream，continuation 只重放一次。
- Unicode 查找表是构建产物，不手写、不入库；改属性走 `src/unicode/props_uucode.zig::get`、`Properties` 或 `uucode_config.zig`，由测试 `unicode props: tables match uucode` 守住一致性。`Properties` 是 `packed struct(u16)`，加属性影响查表效率，要跑基准（流程见 `src/benchmark/AGENTS.md`）。

## 禁止项

- 不在本域引入 app 依赖（apprt、renderer、config、`src/global.zig`）；确实需要时按 `artifact` 门控，平台能力走 `sys.zig` 钩子或 build options。
- 不直接写 `Screen.selection`；不跨修改持有未 tracked 的 pin；不在锁外解引用 RenderState 的 pin。
- 不手改 vendored 或生成内容：`pkg/simdutf/vendor/`（自动生成的 amalgamation）、`src/terminal/res/`（X11 `rgb.txt` 等）、构建期生成的 Unicode 表。
- 不在 `pkg/highway/src/detect.zig` 重新引入 `std.zig.system.resolveTargetQuery`（文件头写明它会带进约 300 KB 目标表并拖慢热路径）。
- 不为让测试通过而改快照金样。失配时测试在工作目录写出 `snapshot_fixture-*.hex` 候选，审阅后人工替换基准，候选不入库。本机 `core.autocrlf=true` 下 `.hex` / `.ksy` 检出为 CRLF（上游 `.gitattributes` 未覆盖），解析器容忍，不要为此改写基准。
- 不给不可信输入加无上限缓冲；不在 `compress/` codec 里引入 libc、`src/simd` 或 PageList 策略。

## 验证

- 首选 `just test-vt --filter <名称>`：分片运行 `test-lib-vt` 的同一对测试二进制，Zig ABI 与 C ABI 两套模块都测；收尾去掉 filter 再跑一次 `just test-vt`。
- 只在 app 产物中编译的代码不被 `test-vt` 覆盖（`tmux/`、`StringMap.zig`、`search/Thread.zig`、调用 `checkGhosttyHEnum` 的测试），用 `just test --filter <名称>`；`just test` 只在 Linux/macOS 可跑（Windows 上直接退出 2），以 gx-ci 的 `linux-main` job 为准。
- 触及 freestanding 路径（分配器、页分配、`sys`、`simd` 回退、feature gate）跑 `just vt-wasm`，它是 ReleaseSmall 构建，也能发现误用的 std 调试 IO；改 build options 或 lib 公开面跑 `just build-vt`。改 Zig 跑 `just fmt-check`。
- 现成的差分守护：`Terminal: printSlice differential fuzz vs print`、`Terminal: graphemeWidth parity`、render 的 `incremental updates match full rebuild`。
- 快照线格式：`just test-vt --filter snapshot`；Kaitai 交叉校验用上游脚本 `src/terminal/snapshot/verify-kaitai.py`，它要求 nix 开发环境，本机缺失时记 PENDING。
- 压缩 codec：按 `src/terminal/compress/AGENTS.md` 跑 `lz4 differential`，这组用例随 libghostty-vt 编译、在 vt 套件里；穷举版先设环境变量 `GHOSTTY_LZ4_SLOW=1`（运行器把环境原样传给测试进程），再运行 `python scripts/zig_test.py --suite vt --filter "lz4 differential"`：过滤串含空格，不经 just（Linux/macOS 用 `python3`），单条超过默认 600 s 时加 `--timeout <秒>`。
- 改 `src/simd/codepoint_width.*`：按该文件注释临时启用被注释掉的逐码点比对测试。

## 上游指令

- `src/terminal/c/AGENTS.md`：C API 的 ABI 设计、`lib.TaggedUnion` 转换与四步导出（与 `libghostty-vt.md` 共用）。
- `src/terminal/compress/AGENTS.md`：压缩取舍优先级、codec 正确性论证、差分测试与基准方法。
- `src/terminal/snapshot/AGENTS.md`：编码时严格校验，解码时优雅降级。
- `src/terminal/apc/glyph/AGENTS.md`：Glyph 协议的规范真源与本地摘要位置。

resolver 按路径祖先自动列出这些文件；本文只做索引，不复述正文。
