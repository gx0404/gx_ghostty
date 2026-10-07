# font：字体发现、栅格化与 shaping

## 范围

- `src/font/**`：后端选择与字体发现、`Collection`/`CodepointResolver`/`SharedGrid`/`SharedGridSet`、face（FreeType、CoreText、web canvas）、shaper（HarfBuzz、CoreText、web canvas、noop）、`Atlas`、sprite 内建字形、OpenType 表解析与 `glyf_rasterize`、Nerd Font 约束表、`res/` 字体与许可证、测试基线。
- `pkg/freetype/**`、`pkg/harfbuzz/**`、`pkg/fontconfig/**`（C 库的封装与构建，同归 `build-system.md`），`vendor/nerd-fonts/**`（上游 `font-patcher.py` 的拷贝）。
- 相邻域：GPU 上传、绘制与 `font_grid` 切换协议见 `renderer.md`；`font-*`、`adjust-*` 配置字段见 `config.md`；`+list-fonts`、`+show-face` 见 `cli-inspector.md`。

## 符号真源

- 后端（编译期唯一）：`src/font/backend.zig::Backend`。`Backend.default`：wasm32 为 `web_canvas`；Windows 为 `freetype_windows`（FreeType 栅格化、HarfBuzz shaping、自带字体目录扫描）；Darwin 为 `coretext`；其余为 `fontconfig_freetype`。`-Dfont-backend` 在 `src/build/Config.zig` 覆盖；`hasFreetype`/`hasCoretext`/`hasFontconfig`/`hasHarfbuzz` 决定 `src/build/SharedDeps.zig::add` 链接哪些库（FreeType 总会链接，Dear ImGui 也用它）。
- 按后端分派：`src/font/face.zig::Face`、`src/font/library.zig::Library`、`src/font/shape.zig::Shaper`、`src/font/discovery.zig::Discover`（`freetype` 与 `web_canvas` 无发现，`freetype_windows` 用 `Windows`，`fontconfig_freetype` 用 `Fontconfig`，CoreText 系用 `CoreText`）。wasm 目标下 `src/font/main.zig::options` 强制 `web_canvas`。
- 共享链：
  - `src/font/SharedGridSet.zig`：由 `App.font_grid_set` 持有；`Key` 由 `DerivedConfig`（字体相关配置）加字号与 DPI 构成，`ref`/`deref` 做引用计数。
  - `src/font/SharedGrid.zig`：codepoint→font index 与字形渲染两级缓存、灰度与彩色两张 `Atlas`、`metrics`、读写锁 `lock`。
  - `src/font/CodepointResolver.zig`：`getIndex` 的七步回退算法写在它的 doc comment 里；`src/font/Collection.zig` 按样式与优先级存放 face（含 deferred face 和 sprite 特殊 index）；`src/font/DeferredFace.zig` 延迟加载发现结果。
- 回退链（`SharedGridSet.ref` 内的 `collection`）：配置的四种样式 family 经发现加入 → `completeStyles`（受 `font-synthetic-style` 控制）→ 内嵌 JetBrains Mono 可变字体（粗体经 `wght` 轴实现）→ Symbols Nerd Font → Darwin 且有发现时加入 Apple Color Emoji，否则加入内嵌的 Noto Color Emoji 与 Noto Emoji。
- 内嵌字体 `src/font/embedded.zig`：JetBrains Mono 与 Symbols Nerd Font 来自 `build.zig.zon` 的 lazy 依赖（`jetbrains_mono`、`nerd_fonts_symbols_only`，由 `SharedDeps` 以匿名 import 注入）；两款 emoji 字体在 `src/font/res/`；`res/` 其余字体只供测试，许可证汇总在 `src/font/res/README.md` 与同目录的 OFL、MIT、BSD 文本。
- shaping：每个渲染器持有一个 `font.Shaper`（读 `font-feature`）和一个 `font.ShaperCache`（`src/font/shaper/Cache.zig`）；`src/font/shape.zig::RunOptions` 与 `src/font/shaper/run.zig::RunIterator` 负责切分 run。
- sprite：`src/font/sprite.zig::Sprite` 占用 U+10FFFF 以上的码位（下划线各式、删除线、上划线、光标）；`src/font/sprite/Face.zig` 在编译期收集 `draw/` 下各文件的 `draw<CP>`/`draw<MIN>_<MAX>` 函数（box drawing、块元素、盲文、powerline、旧式计算机符号等），约定见 `src/font/sprite/draw/README.md`。
- Nerd Font：`src/font/nerd_font_attributes.zig::getConstraint`（手写的三级查表包装，带编译期布局断言）读取生成文件 `src/font/nerd_font_tables.zig`；生成器 `src/font/nerd_font_codegen.py` 解析 `vendor/nerd-fonts/font-patcher.py`，缓存表 `src/font/nerd_font_codepoint_tables.py` 记录 nerd-fonts 版本。渲染器在 `src/renderer/generic.zig::Renderer.addGlyph` 用它约束图标的尺寸与对齐。
- 其它：`src/font/Atlas.zig`（方形装箱，原子计数 `modified`/`resized`）、`src/font/Glyph.zig::RenderOptions`、`src/font/Metrics.zig`（含 `adjust-*` 修饰）、`src/font/opentype/`（表解析）、`src/font/glyf_rasterize.zig`（不依赖外部库的 glyf 轮廓栅格化）。

## 不变量

- **grid 共享且不可变**：同配置的 surface 共享一个 `SharedGrid`，它不支持就地改字号、换字体或删 face。字体配置或字号变化一律 `ref` 新 grid，交渲染器切换后 `deref` 旧 key（协议见 `renderer.md`）。`metrics` 初始化后不再变化，渲染器可以不加锁读取。
- **锁**：
  - `SharedGrid.lock` 保护缓存与 atlas：先持共享锁查缓存，未命中再取独占锁并复查；外部直接读 atlas（渲染器同步纹理）必须持共享锁。
  - `SharedGridSet.lock` 保护 map；`deref` 也会在渲染线程被调用。
  - FreeType：创建、销毁 face 要持 `src/font/library.zig::FreetypeLibrary.mutex`；face 可能被多个 surface 共享，凡动到 glyph slot（`loadGlyph`）都要持 `src/font/face/freetype.zig::Face.ft_mutex`。它们是 `SharedGrid.lock` 之下的叶子锁。
- **缓存键完整**：
  - `SharedGridSet.Map` 判等只比较 `Key.hashcode()`。新增影响 grid 构建的配置，必须同时进入 `DerivedConfig`、`Key` 与 `Key.hash`，否则不同配置会错误地共享同一 grid。现状：`font-synthetic-style` 与 `font-style-*=false` 参与构建却不在 hash 中，属上游既有行为。
  - `SharedGrid.GlyphKey` 是 packed u64，只含 glyph、font index 与 `RenderOptions` 里的 `cell_width`、`thicken`、`thicken_strength`、`constraint_width`；新增会改变栅格结果的选项必须扩键，否则命中旧缓存。
- **回退与发现**：发现实例在 `SharedGridSet` 生命周期内只初始化一次（fontconfig 不能重复 init）。`CodepointResolver.getIndex` 不报错、尽力返回，改算法要同步 doc comment；sprite 码位总由 sprite face 提供；emoji 一律按 cover 加居中约束渲染（`SharedGrid.renderGlyph`）。
- **shaper 契约**：四种 shaper 提供同一组方法（`init`、`deinit`、`runIterator`、`shape`、`endFrame`）。`shape` 返回的 cells 归 shaper 所有，只到下一次 shape 前有效；渲染器每次 `updateFrame` 结束都调 `endFrame`，CoreText 借此释放帧内积压的对象。
- **Atlas**：写满时 `grow` 成两倍再重试；每次写入递增 `modified`，渲染器据此决定是否重传纹理；同一 atlas 内格式统一（灰度 1 字节，彩色 BGRA）。
- **Windows 发现**：`src/font/discovery.zig::Windows` 每次 `discover` 都遍历 `%SYSTEMROOT%\Fonts` 与 `%LOCALAPPDATA%\Microsoft\Windows\Fonts`，没有索引，按 FreeType family 名或 SFNT name 表匹配；按 codepoint 回退要逐个打开候选字体，开销大。它读 `global.environ()`，依赖全局状态已初始化。
- **生成物**：
  - `src/font/nerd_font_tables.zig` 与 `src/font/nerd_font_codepoint_tables.py` 只经 `src/font/nerd_font_codegen.py` 重建：Python 版本与 fontTools 依赖见脚本 docstring，第一个参数是 SymbolsNerdFont（非 Mono）字体路径。脚本以当前目录相对路径读写 `nerd_font_codepoint_tables.py`，缓存缺失或版本不符时把源符号字体联网下载到当前目录的 `nerd_font_symbol_fonts/`，所以要在 `src/font/` 下运行。
  - `vendor/nerd-fonts/font-patcher.py` 是上游原样拷贝（README 记录取自的 commit），更新时同步 README 并重新生成表。
  - `pkg/fontconfig/override/` 是按 `pkg/fontconfig/build.zig` 头注释的流程从 fontconfig 构建中提取的头文件，随钉版升级重新提取。
- **字体资源**：新增 `src/font/res/` 字体必须可再分发，并在 `src/font/res/README.md` 登记、附许可证；`src/font/embedded.zig` 里只有被代码引用的字体才进二进制。`spleen-8x16.bdf` 未在 `.gitattributes` 固定 eol，本机 `core.autocrlf=true` 下检出为 CRLF。
- **测试基线**：`src/font/sprite/testdata/*.png` 是 sprite 绘制的金标准，测试先比 PNG 字节再比像素（防止夹带二进制），不一致时在当前目录写出 `sprite_face_test-*` 与 `sprite_face_diff-*`；`glyf_rasterize` 的基线是 `src/font/testdata/glyf_rasterize.png`；`src/font/shaper/testdata/arabic.txt` 被 HarfBuzz 用例嵌入。基线变化必须逐张审阅后再替换。

## 禁止项

- 不手改 `src/font/nerd_font_tables.zig` 与 `src/font/nerd_font_codepoint_tables.py`（头注释 DO NOT EDIT BY HAND），不给 `vendor/nerd-fonts/` 打补丁。
- 平台差异只放进 `Backend` 选出的 face、discovery、shaper 实现，不在共享层写平台分支。
- 不在 grid 上就地修改；不在持 `SharedGrid.lock` 时回调渲染器或获取 `renderer_state.mutex`、`draw_mutex`；不在渲染热路径做全盘字体扫描，不新增运行时联网下载字体。
- 不引入许可证不明的字体，不把测试字体接入产品回退链；`Sprite` 码位只用于渲染，不写进文本或任何导出格式。
- 不新增未登记到 `src/font/sprite/Face.zig` 中 `structs` 列表的 `src/font/sprite/draw/` 文件（未登记就不生效），也不让 draw 函数的码位范围重叠（重叠会编译报错）。

## 验证

- 路由：`just rules src/font/SharedGrid.zig`；改本文档后跑 `just framework-check`。
- 定向单测（本机默认 `freetype_windows`，`src/font/discovery.zig` 里的 fontconfig、CoreText 用例按后端自动 skip；`-Dtest-filter` 可重复；Windows 上编出完整测试二进制属尽力而为，结果如实记 PASS 或 FAIL）：
  - `just test -Dtest-filter=windows`：含在系统字体目录查找 Arial 的发现用例。
  - `just test -Dtest-filter=Key -Dtest-filter=getIndex`：grid 键与回退解析。
  - `just test -Dtest-filter=shape -Dtest-filter=Constraints`：HarfBuzz 整形与 Nerd Font 约束。
  - `just test -Dtest-filter=sprite -Dtest-filter=glyf`：sprite 与 glyf 金标准比对。
- 编译与格式：`just build`（Windows 产出 `ghostty-internal`，结果尽力而为）；改 Zig 跑 `just fmt-check`。
- 改 `pkg/freetype`、`pkg/harfbuzz`、`pkg/fontconfig`：各包的 `build.zig` 自带 `test` 步骤，在包目录运行 `zig build test`；gx-ci 未覆盖，需手动补跑并记录结果。
- PENDING：CoreText 系后端只能在 macOS 验证（上游跑过 `-Drenderer=metal -Dfont-backend=coretext_freetype`，可交 gx-ci 的 `macos` 输入）；`fontconfig_freetype` 由 gx-ci `linux` job 覆盖；字形视觉效果要读回 gx-ci `gtk-smoke` 截图才算通过；`ghostty +list-fonts`、`ghostty +show-face --cp=0x41` 需要可执行文件，只能在 Linux 或 macOS 构建上运行。
