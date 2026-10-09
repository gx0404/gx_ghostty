# support-libs：通用支撑库与叶子工具

## 范围

- `src/lib/**`：跨产物共用的 ABI 工具与运行时小件（`lib.Enum`、`TaggedUnion`、`Struct`、`Packed`、C 分配器接口、`TinyIo`、Windows DLL 初始化、`compat/`）。该目录同属 libghostty-vt 域，C API 导出流程以 `docs/AGENT_RULES/libghostty-vt.md` 为准。
- `src/datastruct/**`：线程间消息、池、链表、缓存、分屏树等通用数据结构。
- `src/stb/**`：vendored stb 头文件、实现单元与 Zig 包装。
- 叶子模块：`src/crc32c.zig`、`src/fastmem.zig`、`src/fastprint.zig`、`src/math.zig`、`src/file_type.zig`、`src/quirks.zig`、`src/quirks_memset.zig`、`src/tripwire.zig`。
- 这些模块被 terminal-core、renderer、font、termio、apprt 等多域共用。改公开语义前先搜出全部调用方，并按调用方所在域的「验证」段补跑。

## 符号真源

ABI 与运行时小件（汇总导出在 `src/lib/main.zig`）：

- `src/lib/target.zig::Target`（`.c` / `.zig`）；终端模块的取值是 `src/terminal/lib.zig::target`，`c_abi` 构建时为 `.c`。
- `src/lib/enum.zig::Enum`：值等于 `keys` 下标；`.c` 用 `c_int`，`.zig` 用能容纳全部下标（含空洞）的最小无符号整数；`null` 键删去名字、保留整数空洞。
- `src/lib/enum.zig::checkGhosttyHEnum`：逐项比对枚举与 `include/ghostty.h` 中 `GHOSTTY_<PREFIX><NAME>` 的值，并要求不缺项。
- `src/lib/union.zig::TaggedUnion`：为 Zig tagged union 生成 C 侧 `extern struct { tag, value }`，值联合固定带 `_padding`；`field_renames` 改 C 字段名，载荷类型可自带 `C` / `cval`。
- `src/lib/struct.zig::Struct`（`.c` 时转为 extern 布局，packed 中的 bool 变成整字节）与 `src/lib/struct.zig::sizedFieldFits`（导出名 `structSizedFieldFits`）。
- `src/lib/packed.zig::Packed` / `PackedTaggedUnion`：packed 结构的公开布局元数据（如 `src/terminal/page.zig::Cell.CLayout`），由 `src/terminal/c/types.zig` 生成 ABI 类型清单。
- `src/lib/types.zig::String`（借用字符串）与 `src/lib/types.zig::Buffer`。
- `src/lib/allocator.zig::Allocator` / `VTable`（C 的 `GhosttyAllocator`，形状照搬 Zig 分配器接口）与 `src/lib/allocator.zig::default`；wasm 便捷分配在 `src/lib/allocator/wasm.zig`，对齐取 `src/lib/c_abi.zig::max_alignment`。
- `src/lib/TinyIo.zig`：体积优化的阻塞 `std.Io`；平台分支在 `src/lib/tinyio/posix.zig` 与 `src/lib/tinyio/windows.zig`，共享测试在 `src/lib/tinyio/test.zig`。
- `src/lib/windows_dll.zig::DllMain`：libghostty-vt Windows DLL 的 C++ 全局构造，由 `src/lib_vt.zig::DllMain` 引用。
- `src/lib/parse_int.zig::parseInt`：终端协议用的整数解析。
- `src/lib/compat/`：从其他版本 Zig std 搬来的过渡代码，来源与 MIT 许可记录在 `src/lib/compat/README.md`。

数据结构（汇总导出在 `src/datastruct/main.zig`）：

- `BlockingQueue`：定长线程间 mailbox（App、渲染线程、termio、搜索线程、`src/os/cf_release_thread.zig` 等使用）；`MessageData`：消息载荷三态 `small` / `stable` / `alloc`。
- `SplitTree`：不可变分屏树，GTK 用作 `src/apprt/gtk/class/surface.zig` 的 `Tree`。
- `IntrusiveDoublyLinkedList`、`UntouchedPool`、`WasmPagePool`：`PageList` 的页链表与节点、页池。
- `CircBuf`、`CacheTable`（字体 shaper 缓存）、`ComptimeIntSet`（`src/terminal/modes.zig` 查表）、`LimitedAllocator`。
- 不经 `main.zig` 导出、按路径直接引用的：`src/datastruct/segmented_list.zig::SegmentedList`、`src/datastruct/comparison.zig::deepEqual`。

叶子模块与 stb：

- `src/crc32c.zig::Crc32c`：iSCSI 参数集，aarch64 CRC 与 x86_64 SSE4.2 硬件后端加软件后端；快照记录校验依赖它。
- `src/fastmem.zig`（链接 libc 时走 libc 的 `memmove` / `memcpy`）、`src/fastprint.zig::printDecimal`（只支持已用到的整数类型）。
- `src/math.zig::ortho2d`（渲染器投影矩阵）、`src/file_type.zig::FileType`（先按魔数、再按扩展名识别背景图格式）。
- `src/quirks.zig`：环境 hack 的集中处，以及全仓热路径断言 `src/quirks.zig::inlineAssert`。
- `src/quirks_memset.zig`：覆盖 Zig 0.16 compiler_rt 标量 `memset` 的导出实现。
- `src/tripwire.zig::module`：测试期错误注入。
- stb：`src/stb/stb.c` 编译实现（只启用 PNG，限制 `STBI_MAX_DIMENSIONS`），`src/stb/main.zig` 只转出用到的符号；`stb_c` 导入由 `src/build/SharedDeps.zig::add` 注入，只进 app 与 libghostty，不进 libghostty-vt。

## 不变量

ABI 工具：

- `lib.Enum` 的声明顺序就是整数值。进入 C ABI 或序列化格式的枚举只在末尾追加；删除用 `null` 占位，不得重排或在中间插入。
- `TaggedUnion` 的 `padding` 决定 C 联合大小，发布后不得改；编译期断言 `@sizeOf(CValue) == @sizeOf(padding)`。标签类型应由 `lib.Enum` 生成。
- `checkGhosttyHEnum` 只能在 test 块里调用：`ghostty.h` 模块只由 `build.zig::addGhosttyH` 注入 `zig build test` 的测试 exe。会被 libghostty-vt 编译的调用方要在 `artifact == .lib` 时返回 `error.SkipZigTest`（如 `src/terminal/mouse.zig`）。
- sized struct 读字段前先用 `structSizedFieldFits` 判断调用方给的 `size` 是否覆盖该字段（如 `src/terminal/c/render.zig`）。
- C 出口的借用字符串用 `String.init`：空切片也给出指向 `""` 的非空指针，因为外部运行时会拒绝 Zig 的零长度哨兵指针。

分配与 IO：

- `allocator.default` 依次选择：调用方分配器 → 测试中的 `testing.allocator` → libc → wasm → freestanding 的 `failing` → `smp_allocator`。freestanding 缺分配器时表现为 OOM，不得改成静默的全局堆。
- `Allocator.fromZig` 要求被包装的 Zig 分配器在 C 分配器存活期间地址稳定；`test_allocator` 在测试外引用即编译错误。
- `TinyIo` 无取消、无并发，只实现终端需要的操作；`TinyIo.supported` 为 false 时整张 vtable 换成失败桩，对嵌入方的影响见 `libghostty-vt.md`。各平台分支导出同一组操作且只分析选中的一支，新增操作要同时实现 posix 与 windows 分支并补共享测试。
- `DllMain` 是工具链缺陷的绕行，不能顺手删（删掉的后果见 `libghostty-vt.md`）。MSVC 分支靠 `.CRT$XCA` / `.CRT$XCZ` 段标记界定构造器，MinGW 分支遍历 `__CTOR_LIST__`，两支都要保留；移除条件见 `src/lib/windows_dll.zig` 文件头：Zig 自己为 Windows 动态库运行全局构造。
- `src/lib/compat/` 中的代码应逐步淘汰。`compat/file.zig` 依赖 `src/global.zig`，只能在 app 侧使用；`compat/thread.zig` 标注 Zig 0.17.0 后移除。

数据结构：

- `BlockingQueue` 定长、按 SPSC 场景设计，没有阻塞 pop：生产者 push 后要另行唤醒消费者（如 xev `Async.notify`）。`push` 返回入队后的长度，0 表示失败（`.instant` 时已满、超时或被中断），失败时由调用方释放消息持有的资源。
- 持有消费者也需要的锁时不能直接 `.forever` push：先 `.instant`，失败再释放锁、唤醒消费者，然后 `.forever`（范式见 `src/termio/mailbox.zig::Mailbox.send`）。`drain` 在 `DrainIterator.deinit` 之前一直持有队列锁。
- `MessageData.init` 只产出 `small` 或 `alloc`，从不推断 `stable`；接收方处理完要调用 `deinit`。
- `SplitTree` 不可变：所有操作返回新树，每棵树一个 arena；`View` 必须实现 `ref` / `unref` / `eql`。
- `UntouchedPool` 从不读写、也不清零 item 内存（保持按需分页）；调用方要在 `destroy` 前清零或 decommit，并在 `reset` / `deinit` 前归还全部 item。
- `WasmPagePool` 与 `UntouchedPool` 接口一致，`PageList` 据此在编译期切换；它的空闲链表按 Item 类型在整个 wasm 模块内共享，依赖单线程目标。
- `LimitedAllocator` 限制的是单次分配或 resize 的大小，不是累计用量。

叶子模块：

- `Crc32c` 各后端结果必须一致，并与 `std.hash.crc.Crc32Iscsi` 相同；它属于快照线格式，参数不得改。
- `inlineAssert` 在 Debug 是 `std.debug.assert`，release 下展开为内联 `unreachable`，ReleaseFast 会把条件当作优化前提，所以条件里不得有副作用。
- `src/quirks.zig` 顶层 import 了 `font/main.zig`，libghostty-vt 只用到 `inlineAssert`，靠 Zig 惰性分析才不把字体代码带进来；不要在该文件加 `comptime` 块，也不要让 `inlineAssert` 依赖 app 模块。
- `src/quirks_memset.zig` 只能从产物根引用：`src/main.zig`、`src/main_c.zig`、`src/main_bench.zig`、`src/main_gen.zig`，以及 `src/lib_vt.zig` 的根模块守卫块。导出可见性为 hidden；无 SIMD 目标、C 目标格式、weak COFF 下不导出。删除条件见文件头：compiler_rt 的 `memset` 恢复向量化，并用 ReleaseFast 反汇编核实。
- `tripwire` 模块只在测试中生效，其他构建零开销；`check` 放在要测试的 `try` 之前。期望配置是模块级全局状态，每个用例结尾都要 `try tw.end(.reset)`。
- `printDecimal` 要求调用方给足缓冲区，新增整数类型要补实现与测试。
- `src/stb/stb.c` 里关于 kitty 图像的注释已过时：kitty 的 PNG 解码现在走 `src/terminal/sys.zig::decode_png`（wuffs），`stbi_*` 目前没有 Zig 调用方，实际在用的只有 `src/font/face/freetype.zig` 调用的 `stbir_resize_uint8`。

## 禁止项

- 不用 `std.fmt.parseInt` 替换 `lib.parseInt`：前者接受 `_` 分隔符和无符号数的正负号，会与其他终端的行为分叉（`src/lib/parse_int.zig` 文件头）。
- 不在共享代码中 import `src/quirks_memset.zig`，否则下游 Zig 模块使用者会被注入 `memset` 导出。
- 不手改 `src/stb/stb_image.h`、`src/stb/stb_image_resize.h`；升级时整文件替换，`src/stb/main.zig` 仍只转出实际用到的符号。
- 不让 `src/lib/`（`compat/file.zig` 除外）或会被 libghostty-vt 编译的 datastruct 依赖 `src/global.zig`、apprt 或 renderer；`src/datastruct/split_tree.zig` 的 GObject 类型按 `build_config.app_runtime` 门控，新增平台相关代码照此办理。
- 不在消费者线程里对自己的 `BlockingQueue` 做 `.forever` push；持有消费者也要的锁时，不得无条件 `.forever` push。

## 验证

- `src/lib/**`：`just test-vt --filter <名称>`（libghostty-vt 的测试根引用 `src/lib/main.zig`）。涉及 `checkGhosttyHEnum`、`compat/` 或 app 侧用法时，再跑 `just test --filter <名称>`。
- `src/datastruct/**`、`src/tripwire.zig`、`src/quirks_memset.zig`：`just test --filter <名称>`（由 `src/main_ghostty.zig` 与 `src/main.zig` 的 test 块引用）；被 `PageList` 等终端代码使用的部分再跑 `just test-vt`。Windows 上的 `just test` 只编译 Windows 分支，POSIX 分支以 `just wsl test` 或 gx-ci 的 `linux-main` job 为准。
- 定向运行要核对运行器计数表里实际运行的用例数（零命中时运行器退出 2，不论是 `--filter` 没命中还是 `-Dtest-filter` 裁空；走上游 `zig build` 的 `-Dtest-filter` 时零命中照样退出 0）：`src/crc32c.zig`、`src/fastprint.zig` 等叶子模块没有被任何测试根显式 `_ = @import`，自测试是否被收集以实际输出为准，可先用 `just test-vt --list --filter <名称>` 只列不跑。`crc32c` 另用 `just test-vt --filter snapshot` 覆盖快照路径。
- 改 `TinyIo`、分配器或 `WasmPagePool`：再跑 `just vt-wasm` 与 `just build-vt`。本机是 Windows，`just test-vt` 跑 `src/lib/tinyio/test.zig` 的共享测试时走的是 windows 分支；posix 分支以 gx-ci 为准。
- 改 Zig 跑 `just fmt-check`；改 `src/quirks_memset.zig`、`src/fastmem.zig` 这类性能件，按 `src/benchmark/AGENTS.md` 的流程做基准对比。

## 上游指令

- `src/terminal/c/AGENTS.md` 规定 C API 里的 Zig tagged union 必须经 `lib.TaggedUnion` 转换，并给出 opaque handle 与 sized struct 的 ABI 设计。resolver 不会为 `src/lib/**` 自动列出这份文件，改 `union.zig`、`struct.zig`、`enum.zig` 前要读。
