# Changelog（gx0404/gx_ghostty fork）

本文件只记录 fork 层面的可观察变更：Ghostty GX 的产品功能、构建补丁、发布链与开发框架。上游 Ghostty 不维护 CHANGELOG；Ghostty 产品版本以 `build.zig.zon` 的 `.version` 为真源，本文件不复述上游产品变更，也不与产品版本同步。

版本规则：

- fork 版本取本文件 `## X.Y.Z(YYYY-MM-DD|TBD)` 标题中数值最大的 SemVer；`just version` 查询，`just version-check` 校验标题格式。
- 未发布的版本写 `(TBD)`，发版时改为发布当天的日期。发布 tag 为 `gx-vX.Y.Z`，构建版本串为 `<build.zig.zon 的 X.Y.Z>-gx.<X.Y.Z>`（0.0.1 即 tag `gx-v0.0.1`、版本串 `<build.zig.zon 的 X.Y.Z>-gx.0.0.1`），流程见 `docs/RELEASE.md`。
- 每个版本按 `### Added` / `### Changed` / `### Fixed` 分节（没有条目的节省略），只写使用者能观察到的效果。
- 本文件开头 6000 字符是知识库语料：每次修改后运行 `just kb`，把 `docs/kb/chunks.json` 与本文件放进同一个提交，否则 `gx-ci` 的 `framework` job 失败。

## 0.0.3(TBD)

### Added

- Windows 性能工具增加逐次缩放截图和 C7 光标/动画状态矩阵，保留 PDH 线程计数、真实 IME 与输出刺激的取证结果；缩放通过成功呈现序号、尺寸与身份查询确认捕获边界，并以独有 Job 限制阻塞等待和清理范围。旧构建缺接口时仍保留未验证状态，不能仅凭截图签收性能。
- GTK 性能工具增加 `gtk --case p2|p4`：采集空闲进程扫描和菜单/设置热打开，核对构建身份、GUI 响应及完整无障碍状态；缺失指标或读取失败不再被当成零事件，标准 GTK 负载入口保持不变。
- 性能与 GUI 工具增加弹层、空闲扫描、GPU 显存、提交量和远程日志取证；性能批次独占验证槽，区分环境无效、指标失败与产品崩溃，保留每轮身份和原始数据。GUI 截图默认加隐私遮罩，宿主缺少键盘布局时明确报告前置未满足。
- Windows 远程窗格：把标签拖到同一用户、权限与配置隔离域内另一个 Ghostty GX 进程的窗口时，其中的终端以远程窗格显示在目标窗口。原进程在后台继续持有终端、PTY 与子进程，目标窗口显示画面并转发键盘、鼠标、输入法与粘贴；关闭原来的普通窗口不会结束这些终端。远程窗格旁可以新建目标进程的本地分屏。只含远程窗格的标签可以拖回原进程，同时含本地与远程窗格的标签不能再跨进程移动（会提示原因），快速终端不接收远程窗格。目标退出或断开后原进程收回仍存活的终端；原进程故障时窗格显示「不可用」，不重放命令。远程粘贴单次最多 16 MiB，不自动追加回车。
- 会话恢复（Windows 与 GTK，`gx-session-restore`，默认关闭，改动后需完全重启）：普通启动时恢复上次的普通窗口、标签、分屏比例、放大状态、字号、手动标题与工作目录。会话只记启动配置的稳定 ID，恢复时按当前配置解析：自定义启动配置每次恢复前确认，已不存在的跳过并提示；临时命令与来源不明的终端不恢复。不保存命令、参数、环境变量、终端输入或滚屏内容；命令行指定了启动命令或工作目录时不恢复，命令行的字号与标题优先。快速终端与远程窗格不进入会话。
- Windows 单实例（`gx-single-instance`，默认开）：普通启动在同一用户、登录会话、权限、配置目录、程序构建、安装位置与 `class` 的已运行实例里新开窗口；`-e`、无法转交的命令行参数或 `--gx-single-instance=false` 启动独立进程。转交结果不明时报错退出，不会另开一份终端。`+toggle-quick-terminal`（支持 `--class`）在 Windows 上经同一认证通道切换已运行实例的快速终端，目标未运行时返回错误。
- Windows 拖放：终端改用 OLE 拖放，除文件外也接受拖入的文本与链接，路径按当前 shell 引用；拖入内容按终端的粘贴确认规则处理，确认后也不自动发送回车。以管理员身份运行的窗口收不到普通权限程序的拖放，此时可为它打开一个普通权限的「拖入提权终端」接收窗口：拖到其中的内容在提权窗口里预览并经「允许粘贴」后才粘贴，接收窗口显示已粘贴、已取消、被拒绝、目标已关闭、已过期或结果未知。提权窗口的主菜单提供「拖入管理员终端…」入口，接收窗口以同一用户、同一会话的关联普通权限令牌启动并与提权窗口配对。Win11 安装版已实测普通权限程序把文本拖入提权窗口：预览后取消、允许后粘贴且不追加回车、多行内容经保护提示后取消，接收窗口都显示对应结果；同一用户下普通权限与管理员权限窗口之间四个方向的文本拖放都已实测，均不自动追加回车，文件、链接与多 DPI 场景尚未逐项验收。
- Windows 无障碍：窗口、标签、终端窗格与自绘弹层（命令面板、菜单、设置、对话框）向 UI Automation 公开名称与角色，并提供调用、选择、切换与展开等操作和通知。
- Windows 系统通知与跳转列表（跳转列表已在安装版实测；系统通知已能显示，程序运行时激活通知会回到原终端；早期三次未显示的原因尚未定位；程序退出后激活通知会在前台提示原终端已不可用，关闭提示后进程正常退出）：安装版使用安装程序登记的 Shell 身份发送 Windows 系统通知（点击回到对应终端；程序已退出时点击只提示原终端不可用，不另开 shell）并在任务栏跳转列表列出启动配置；便携版不做任何注册。系统通知后端不可用时退回托盘气泡，被系统勿扰或用户关闭的通知不改用气泡。
- GX 模糊搜索增加全拼匹配（例如 `zhongwen` 找到「中文」，ü 用 v 输入，原文字母仍优先），数据来自钉版 pinyin-data 0.15.0 离线生成。
- Windows 设置浮层选中分区的图标改用 Microsoft Fluent UI System Icons 的实心图形（钉版官方 SVG 离线生成，许可随包）；未选中的分区与图形不可用时仍用系统字形。
- Windows 弹层可以试用 DirectComposition 呈现：设环境变量 `GHOSTTY_GX_POPUP_DCOMP=1`（只认这个值，默认关闭）；初始化或设备重置失败时退回原来的绘制方式，终端渲染不受影响。
- GTK：快捷键编辑器（键表、按键序列、标志与动作链）与启动配置管理器（新建、编辑、改名、删除自定义启动配置并设默认），都只写 `gui-settings.ghostty`，命令行与其他配置文件提供的条目只读，保存失败保留草稿；`gx:move_split_to_tab`、`gx:move_split_to_window` 把现有分屏连同其终端移到新标签或新窗口，不重启 shell；第一个普通窗口按上次正常关闭时的大小打开，并恢复最大化（`window-save-state = never`、显式的 `window-width`/`window-height`、`maximize` 或 `fullscreen` 优先，不记屏幕位置）。
- Windows 弹层输入框（查找栏、命令面板、快捷键速查表与设置浮层的搜索框）的编辑能力：撤销与重做（Ctrl+Z、Alt+Backspace 撤销，Ctrl+Y、Ctrl+Shift+Z 重做）、按词移动与删除（Ctrl+←/→、Ctrl+Backspace、Ctrl+Delete，连续的汉字算一个词）、Shift+Insert / Ctrl+Insert / Shift+Delete、双击选词与三击全选；插入符按系统频率闪烁，且只在输入框获得焦点时显示。
- Windows 命令面板与设置浮层（主题、字体列表）的过滤支持拼音首字母（例如输入 `zt` 能找到「主题」），多个词按任意顺序匹配，全角字母数字按半角匹配；名称以输入开头或完全相同的条目排在前面。
- 新配置键 `gx-prompt-cursor`（`config` 默认、`bar`）：选择 shell 集成在提示符处显示配置的光标样式，还是像上游一样显示竖线；只影响之后启动的 shell。
- 开发框架：`just win-gui`（Windows GUI 场景回放与截图取证，场景在 `test/gui/win32/`）、`just wsl scenario`（GTK 场景，在 `test/gui/gtk/`）、`just perf`（新旧构建交替测启动、新建标签、分屏与缩放耗时，报中位数与 p90）、`just pinyin` / `just pinyin-check`（拼音首字母表的生成与校验，`pinyin-check` 并入 `framework-check` 与 `generated-check`）；设 `GHOSTTY_GX_PERF=1` 时日志输出 `info(gx_perf)` 耗时打点；`gx-ci` 的 `windows-app` 与 `gtk-smoke` 增跑 GX 层单测。

### Changed

- Windows 主菜单与设置弹层按窗口隐藏复用；首帧、配置、语言、DPI 或启动配置变化后，在消息队列空闲时按界面单元逐个预排版，单元之间检查输入并让出，预排版不主动读文件。配置变化会重建隐藏宿主，启动配置探测结果变化只刷新数据；主题预览期间不逐步重建所有隐藏宿主。
- Windows 窗口最小宽度为 510 DIP，进程提权且显示管理员标记时为 538 DIP，以容纳活动标签与溢出控件；较窄的已保存窗口和较小的 `window-width` 会被放宽，可能减少可用贴靠分栏组合。控件按 DPI 逐项取整，会话恢复先放宽尺寸再移入工作区。
- GTK 设置对话框关闭后按窗口保留并在下次打开时复用；配置、语言或主题变化时重新构建，重开主题子页与 Shell 页会重新发现新增条目。
- Windows 上 `click-repeat-interval` 为 0（默认）时，双击与三击的判定间隔改用系统鼠标设置里的双击速度（以前固定 500 ms；改了系统设置后重载配置生效）；显式设置的值仍然优先，写 `click-repeat-interval = 500` 可恢复以前的行为。
- Windows 标签页标题：`set_tab_title` 与双击改名设的名字不再被程序标题（OSC 0/2）冲掉，改名留空或 `set_tab_title:`（空值）即恢复显示程序标题；标签页显示其中聚焦分屏的标题，切换分屏时随之更新。
- Windows 子进程退出：只有命令启动即失败（在 `abnormal-command-exit-runtime` 内以非零码退出）时才在窗口底部显示「命令失败」提示，它不抢焦点、不阻塞窗口，在该终端按任意键关闭终端（以前是模态对话框）；正常退出不再提示，终端里显示 “Process exited…”，再按 `wait-after-command` 决定是否关闭（与 Linux、macOS 版一致）。
- Windows 切换标签页：`goto_tab:N` 从 1 计数、超出标签数时到最后一个（以前差一，`goto_tab:1` 跳到第 2 个）；目标已是当前标签时，带 `performable` 的按键（如默认的 Alt+9 `last_tab`）交给 shell；`move_tab` 改为移动当前标签（以前只是切换过去）。
- Windows 分屏：关闭聚焦的分屏后，焦点落到它前一个分屏，没有时落到后一个（与 Linux、macOS 版一致）；放大（zoom）状态下切换分屏遵守 `split-preserve-zoom`；上一个、下一个分屏到头后回绕。
- Windows 命令面板：空查询打开时不再自动预览主题（哪怕第一项是最近用过的主题），用方向键移动选择或输入筛选后才预览；按 Esc、关闭面板或面板所在终端关闭时恢复已保存的主题。
- Windows 鼠标与编辑框：鼠标侧键报告为第 8、9 键（SGR 128/129），横向滚轮方向与 Linux 版一致并累积高精度滚动；查找栏、命令面板等弹层输入框里未绑定的 Ctrl 组合键不再漏进 shell，已绑定的动作（含 `chain`）照常执行。
- Windows 界面配色：强调色改为依次从光标色、palette 4、palette 12 中挑第一个彩度与对比度都合格的颜色（GX Mocha 下由玫瑰白变为蓝色 `#89b4fa`，此前 657 个内置主题里有 362 个的强调色近乎灰色）；次要文字、占位符与边框按 WCAG 保证对比度；控件按下态比悬停态更淡；界面小字改用 Segoe UI Variable 的光学尺寸。
- 关闭确认里列出的进程名不再带 `.exe`；终端里只剩 `wslrelay.exe` 时视为空闲，关闭 WSL 标签不再多问一次（`gx-idle-processes` 的内置名单同步写明）。
- 启动配置不再列出 Docker Desktop、Rancher Desktop 的内部 WSL 发行版（名称以 `docker-desktop`、`rancher-desktop` 开头）。
- Windows 标签栏每次刷新只拍一次系统进程快照（原来每个标签拍一次），标签多时 CPU 占用更低。
- 配置诊断：`language` 填了不支持的值、`gui-settings.ghostty` 读不出来时会报告配置错误，`ghostty +validate-config` 因此返回 1。
- GTK 切换界面语言与重新加载配置时在内存里重建配置，不再重新读盘。
- Windows 便携包、安装包、Linux deb 与 debian13 GTK 压缩包附带拼音数据（pinyin-data，MIT）与 Unicode License V3 的许可文本（压缩包在 `usr/share/doc/ghostty-gx/`，另附 Ghostty 的 MIT 许可）。
- shell 集成的光标特性在提示符处显示配置的 `cursor-style` 与闪烁设置（GX 默认为闪烁块状），程序留下的光标形状在下一个提示符复位；程序运行期间仍可用 DECSCUSR 改变光标。zsh 与 fish 的 vi 绑定保持插入竖线、命令模式块状。想要上游的“提示符竖线、程序用配置样式”设 `gx-prompt-cursor = bar`；`no-cursor` 行为不变。

### Fixed

- Windows VM 验证工具：`queue-args` 在 Python 3.12 下也能正确区分主机选项与 `--` 后的客机参数，保留引号和额外分隔符的字面含义，不改变危险字符拒绝与队列写入范围。
- 开发工具：从不同版本的 Python 启动图谱命令时，仓内 graphify 虚拟环境不再继承外层 `PYTHONHOME`，避免标准库版本冲突及误报工具版本未知；自定义 graphify 命令的环境保持不变。
- GTK 性能采集使用原始单调时钟纳秒端点计算窗口与负载耗时，避免系统墙钟调整造成负耗时或虚增；新证据校验版本、单位、端点顺序及耗时一致性，旧记录保留原判，不回填或补样。
- Windows 弹层所需系统状态变化时才作废缓存，不再因无关系统广播关闭进行中的菜单、命令面板与设置；语言变化与窗口销毁仍取消活动菜单。菜单动画从关闭改为开启后可重新淡入。
- Windows 模态确认框首帧绘制失败时仍显示并保留操作能力，随后按 100、200、400、800、1000 ms 间隔重试，间隔封顶、总次数不限，不自动代替用户作答；输入弹层各显示路径可点击激活，设置布局变化会使旧无障碍节点失效。
- Windows 拖放管道的访问权限同时校验当前用户和实际登录 SID，其他本地账户不能仅凭共享登录会话打开管道；同用户关联普通/提权令牌继续按各自登录 SID 授权。
- Windows 安装版启动时为指向当前程序、尚无应用标识的旧固定快捷方式补齐 AUMID，保留参数、工作目录和图标等属性；已有标识、其他目标和便携版不迁移。扫描根是重解析点时跳过，失败只记日志，不阻断启动；真实升级后的任务栏归组仍需随最终构建验收。
- Windows 默认集成标题栏的最小化、关闭与主菜单按钮在取消按下后可快速再次点击；取消按下或结束标签拖动后，无需移动鼠标即可恢复指针下按钮的悬停与提示。取消模式仍清空悬停；本项不改变 DWM 原生按钮、原生标题栏、无边框或全屏主菜单的处理。
- Windows 查找栏放行已绑定且不带 Ctrl 的 F1–F24（含 Shift、Alt、Win 组合）；F3、Shift+F3、Enter、上下箭头与 Esc 仍优先用于查找。默认 Alt+F4 关闭窗口前不再结束搜索，取消关闭后查找文本、计数与匹配保留；解绑 Alt+F4 时仍先结束搜索再请求关窗。
- Windows 窄窗格的查找栏横向夹在窗口客户区内，保留可点击的完整关闭按钮；纵向极小窗格、常显滚动条遮挡与相邻查找栏重叠仍是已知限制。
- Linux GTK 隔离随程序构建的 Fontconfig 静态符号，避免 Pango 与终端混用两份 Fontconfig；系统库构建模式和其他平台不变。
- GTK 设置重开不再积累字体、默认命令与主题预览的临时字符串；保存失败时跨窗口打开会回到原对话框，保留未保存值与重试提示；主题还原会丢弃待保存改动，还原后的重新应用失败提示仍然保留。
- GTK 的快捷键、命令面板及菜单执行“关闭其他/右侧标签”时保留固定标签；选中固定页后新建或收养普通标签可正常插入，移动标签按固定/普通分组循环，大位移不再越界。
- Windows 启动子进程时保留空命令行参数（中间、末尾与连续的空参数，例如 `command = prog "" x`），以前空参数会丢失、后面的参数前移。
- Windows 跳转列表（JumpList）提交失败后，下一次配置变化（重新加载配置、保存设置、预览主题等）会再尝试提交一次；每次配置变化最多尝试一次，失败时保留原列表，不在后台反复重试（以前同一份配置重载后不再尝试，旧列表一直留着）。
- Windows 铃声的原生 WinMM 测试在托管 CI 机器上偶发等待回调超时：等待上限改为 15 秒，超时仍判失败并记录播放器与 Windows Audio 服务状态。
- `alpha-blending = native` 时（Windows 与 GTK），不透明颜色不再被重复做 sRGB 编码而整体发白（例如 #808080 显示成 #bcbcbc）；自定义着色器的中间画面也用相同的颜色空间。默认的 `linear-corrected` 与 `linear` 不受影响。
- Windows 显卡驱动重置（或测试钩子模拟的重置）后恢复绘制时，日志不再多出一次 `InvalidValue` 绘制错误：旧上下文的着色器等资源改在旧上下文里释放后，才换上新上下文重建（以前在新上下文里删除旧对象，名字若被复用还可能误删新对象）；新上下文建不起来时终端保持不绘制，不会误报恢复。
- Windows 上 `ghostty +validate-config` 的标准输出接到管道或 NUL 时（被脚本、`findstr` 或 PowerShell 捕获，或 `> NUL`），合法配置不再返回 1；有诊断时仍输出诊断并返回 1。
- GTK 设置里主题保存失败后点「重试」成功时，对话框结束预览并显示已保存的主题（以前仍停在预览状态，「应用」「还原」仍可点，外观页显示旧主题）。
- GTK 标签页菜单的「关闭其他标签页」不再关闭固定标签。
- Windows 上程序用 OSC 52 读取剪贴板、而剪贴板里没有文本时，终端回复空内容，不再让等待回复的程序一直挂起，也不为空内容弹出读取确认；某个分屏勾选“记住”并拒绝读取后，之后的读取请求同样得到空回复（与当次点“拒绝”一致）。
- `-Dapp-runtime=none` 核心测试不再因远程一次性键表续延引用窗口动作分派而编译失败；保留无界面运行时下的键表代次回归测试，真实 apprt 的动作处理不变。
- Linux 框架测试等待已 join 的工作线程从 `/proc` 消失后再核对 CPU 统计，避免内核线程尚未清理时偶发误报线程集合变化；超时仍失败，保留退出线程 CPU 累计与线程集合断言。
- GTK 分屏迁移与会话恢复不再留下焦点引用，关闭旧窗口或恢复后退出时能完整销毁终端，避免退出断言失败。
- Windows 远程粘贴在 ReleaseFast 构建中保留正确事务身份，复制等操作之后的粘贴不再卡住后续输入。
- Windows 取消远程受保护粘贴后不再把触发按键发送到终端；分屏或缩放时保留旧帧映射直到目标接收新映射，避免偶发断连；回收远程终端后关闭源窗口不再因退出消息清理而崩溃。
- Windows 关闭窗格、切换标签或移动窗格后立即收起旧尺寸提示；从键盘打开主菜单时首项保持可见选中状态。
- Windows 命令面板输入主题名称后正确预览所选主题；失败终端关闭时清除其自己的命令失败提示。
- Windows 上 Ctrl+点击链接（包括 OSC 8 超链接）后整个程序卡死无响应：链接改在独立线程打开，浏览器照常打开；超长链接（如 5000 个字符）不再被截断或越界。
- Windows 上启动即失败的命令（如 `command = cmd.exe /c exit 3`）的「命令失败」提示不再一闪而过、看不到：启动时不再产生多余的退出请求，对话框与菜单也会忽略已经撤回的退出请求。
- Windows 上 RustDesk、ToDesk 等工具同步剪贴板时，复制或粘贴偶尔没反应：剪贴板被短暂占用时会重试，最终失败写入日志。
- Windows 上超长标签标题、输入法上屏文本与托盘通知文字不再越界写内存，截断时不拆开代理对。
- Windows 分屏：拖动嵌套的分隔线不再跳动或卡住；拖动中失去鼠标捕获会结束拖动；只有一个标签或一个分屏时，`goto_split`、`resize_split` 等带 `performable` 的按键交给 shell；关闭分屏时焦点不再交给正在拆除的终端；实现 `goto_window`。
- Windows 标签页：切换标签时焦点不再来回跳，终端程序不再收到多余的焦点进出报告；右键菜单打开期间标签变化时，菜单命令仍作用于原来那个标签；关闭后台标签时取消进行中的标签拖动。
- Windows 鼠标：拖动中鼠标捕获被对话框等夺走时，向终端补发松开，按键不再卡在按下状态，之后的物理松开也不再重复报告。
- Windows 上 `toggle_background_opacity` 切到不透明后，预览主题或从设置界面、命令面板重新加载配置不再把窗口变回半透明。
- Windows 查找栏关闭后搜索高亮不再残留；新建窗口失败时不再留下不可见的窗口；设置浮层被页眉、页脚遮住的行不再能点中；`scrollbar = never` 生效，滚动条跟随系统「自动隐藏滚动条」设置，拖动中失去捕获时结束拖动；快速终端滑入时立即获得键盘焦点，创建失败不再崩溃。
- Windows 对话框（关闭确认、关于等）被外部程序关闭（不带 `/F` 的 `taskkill`、UI 自动化的「关闭」等）时整个程序卡死、所有窗口点不动：现在按「取消」处理。
- 外部程序批量发送关闭消息时，「关闭窗口？」确认框会弹两次。
- 弹层输入框粘贴超长单行文本（MB 级）时明显卡顿：粘贴上限为 4096 个 UTF-16 单元，超出部分截断。
- 界面里路径与标题的中间省略不再把组合字符、emoji 序列或国旗拆开。

## 0.0.2(2026-10-10)

### Added

- Windows 应用检测被占用的快捷键。GX Shell 的 Windows 用户常遇到快捷键按了没反应：组合键被其他程序注册成全局热键（如 bilibili 客户端「老板键」的 Ctrl+Shift+C、AMD Software 性能指标叠加层的 Ctrl+Shift+O）或被输入法先吃掉，Ghostty GX 收不到按键，以前也不会提示。现在第一个窗口显示约 1 秒后与每次重载配置后，检查每个带修饰键的绑定是否被其他程序注册为全局快捷键，以及是否是当前输入法经 TSF 保留的按键（微软拼音简繁切换的 Ctrl+Shift+F 不是保留键，检测不到）。每个受影响的绑定在日志里记一条警告；快捷键速查表（Ctrl+Shift+/）在这些按键前加警告标记并说明原因；右键菜单、主菜单与命令面板改为提示同一动作的其他可用按键，没有就不提示；默认的复制、粘贴、查找或分屏键受影响时，每次运行在窗口底部提示一次（约 20 秒后消失），列出被占用的键与替代方式（Ctrl+Insert / Shift+Insert、右键菜单、命令面板），并可直接打开速查表。实机上遇到的冲突程序（bilibili、AMD Software、微软拼音、Kimi Code、微信、NVIDIA App）与各自的解除办法见 `docs/GX_FEATURES.md`「快捷键冲突」。
- 写明 Ghostty GX 是非官方分支：Windows 的「关于」对话框与设置的「关于」页、Linux GTK 设置对话框的「关于」页、安装包的欢迎页与「应用和功能」里的说明、便携包的 `README.txt`、GitHub 发布说明的结尾与仓库首页 README 的开头，都写明「Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书」（英文界面显示英文）。
- Linux GTK 主菜单的「关于 Ghostty GX」打开 Ghostty GX 自己的关于对话框：名称、版本、项目主页与问题反馈都指向 gx0404/gx_ghostty，首页写明「gx0404 维护的 Ghostty 非官方分支」，不再显示把本构建说成 Ghostty 开发者出品的上游关于对话框。

### Changed

- Windows 窗口材质透到整个终端区：`gx-window-material = mica|acrylic|tabbed` 不再只透在标题栏，终端背景按 `background-opacity` 透出材质，文字、光标、选区与图片保持不透明，分屏间隙一样透出。没设 `background-opacity` 时材质自带默认值（同 WezTerm GX）：Mica、Tabbed 为 0.3，Acrylic 为 0.75；显式设置（包括 `background-opacity = 1`，只在标题栏透出材质）优先。`solid` 配 `background-opacity` 小于 1 时改为只有终端背景透明、桌面透过来，文字不再随整窗变淡，`background-blur` 照常模糊透出的桌面；`toggle_background_opacity` 改为所有窗口一起在配置的不透明度与不透明之间切换（同 macOS）。需要 Windows 11 22H2（build 22621）及以上与硬件 OpenGL 驱动；更早的系统、Mesa 软件渲染（`GHOSTTY_GX_OPENGL=software`）或像素格式没有 alpha 时保持 0.0.1 的行为，日志记一行原因。`background-opacity` 的配置文档（`+explain-config background-opacity`）写明了 Windows 上的这些行为（GX-0024）。
- Ghostty GX 的 Windows 应用与安装包改用自己的图标（GX Mocha 配色的深色圆角方块加蓝色 `>_` 提示符，48 像素起加 `GX` 字样），不再使用 Ghostty 的幽灵图标；标题栏、任务栏、资源管理器、通知区域、安装程序与 GX Shell 的 Windows 安装包都显示它（GX-0026）。`ghostty.exe` 的文件属性显示产品名 Ghostty GX、发行者 gx0404 与非官方分支声明。Linux GTK 应用仍用上游图标。
- Windows「关于」对话框的第二个链接改为「上游 Ghostty」，指向 ghostty.org。
- 知识库产物 `docs/kb/chunks.json` 改为 schema 2，体积从约 2.3 MiB 降到约 1.8 MiB（预算仍是 2.5 MiB）：每个文档一行头（路径与逐文档的 `source_sha256`），其后每片一行，diff 按行对应小节；Markdown 正文不变，Zig 结构省略 `pub` 前缀、超长模块文档截断，Zig 与 C 头文件的文档注释只留摘要句。`just kb-query --json` 的 `id` 改为 `path#anchor`；旧格式的产物由 `just kb-check` 报「格式或 schema 变化」，运行 `just kb` 重建即可。

### Fixed

- Windows 上 Shift+Insert 粘贴剪贴板。Windows 没有选择剪贴板，上游默认的 `shift+insert=paste_from_selection` 按下后什么也不做；GX 的 Windows 默认值改为 `paste_from_clipboard`，与 Ctrl+Insert 复制配对，Ctrl+Shift+C / Ctrl+Shift+V 被其他程序占用时仍可复制粘贴。
- GTK 应用（GX-0023）：GTK 4.20 以前（如 Ubuntu 24.04 的 GTK 4.14）启动时不再记录 `Theme parser error: style.css:…`。拖动分屏时，目标终端靠近指针的那一半重新显示蓝色高亮；只读提示的文字恢复浅橙色；`window-theme = ghostty` 时 GTK 4.14 不再报 `css parsing failed`，失焦窗口的标题栏略微变暗；GTK 4.16–4.18 上拖放高亮的运行时 CSS 也不再报错。

## 0.0.1(2026-10-10)

Ghostty GX 的首个版本：新增 Windows 原生应用，改进 Linux GTK 应用，两端共用 GX 核心与默认配置，并有 fork 自己的发布链与开发框架。括号里的 GX-NNNN 是 `docs/FORK_PATCHES.md` 登记的上游源码补丁。

### Added

**Windows 原生应用**（新运行时 `src/apprt/win32`，移植自 MIT 许可的 shiweis/ghostty-windows 后重构）

- 运行：Windows 上 `just build` 产出 `zig-out/bin/ghostty.exe`。OpenGL 4.3 经 WGL 在渲染线程绘制，系统驱动不可用时改用 exe 旁 `mesa\` 里的 Mesa llvmpipe（发布包自带；`GHOSTTY_GX_OPENGL=software` 强制），GPU 重置、休眠恢复与显示器变化后自动恢复绘制。exe 旁有 `conpty.dll` 与 `OpenConsole.exe`（发布包自带 ConPTY 1.24）时优先使用（GX-0007，`GHOSTTY_GX_CONPTY=system` 改用系统自带）；`TERM=xterm-256color`、`COLORTERM=truecolor`；shell 经 OSC 7 报告的工作目录由新标签页、分屏与窗口继承（GX-0008）。日志在 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`（上次运行的为 `.log.1`）。
- 窗口：标签页并入自绘标题栏（Windows Terminal 式），同一行有「+」新建标签页、「▾」启动配置与 ☰ 主菜单按钮，支持 Snap 布局与窗口菜单（Alt+Space）。标签页显示「程序 ~ 标题」、后台输出或响铃的圆点、管理员盾牌与 WSL 图标，可拖动排序、双击重命名、中键关闭。`gx-window-material = mica|acrylic|tabbed` 在 Windows 11 22H2 及以上让标题栏透出系统材质。新窗口占所在显示器工作区约 80% 并居中、依次错开，画出第一帧前不显示，不闪白。
- 菜单、命令面板与对话框：界面文字随 `language` 显示中文或英文，重载配置即切换。主菜单、启动配置菜单、标签页与终端右键菜单都是跟随主题的 Windows 11 风格弹出菜单，含分屏、界面语言、复制标签页、移到新窗口、在资源管理器中打开当前目录等。命令面板按最近使用、标签页、启动配置、命令、设置、主题分组，中英文模糊匹配，停在主题上即预览；`gx:keybinds`（Ctrl+Shift+/）打开可搜索的快捷键速查表。关闭确认（列出仍在运行的进程）、剪贴板授权（带预览）、不安全粘贴、子进程退出与关于都是主题化对话框；查找栏显示「当前/总数」，滚动条为细胶囊。
- 设置：`gx:settings`、主菜单「设置…」与 `open_config`（Ctrl+,）打开 Direct2D 模态设置浮层：语言、外观（窗口材质，带配色样例、移动即预览的主题列表）、字体、交互（右键菜单、滚动条、关闭确认、响铃）、Shell（默认启动配置；选 GX Zsh 时同时设为 herdr 的默认 shell）、关于。改动在 300 ms 内合并写入 `gui-settings.ghostty` 后重新加载配置，从不改写 `config.ghostty`。
- 输入与 shell 集成：ConPTY 开启 win32-input-mode 后按键以 KEY_EVENT_RECORD 发送（GX-0006），PowerShell、herdr 等能区分 Shift+Enter、Ctrl+Shift+字母与 Alt+方向键；输入法组字内联显示、候选窗跟随光标；拖放文件的路径按目标 shell 加引号。未配置 `command` 时依次尝试 GX Zsh、PowerShell 7、Windows PowerShell、命令提示符，启动配置另外探测 herdr、Git Bash、MSYS2 UCRT64、Nushell 与各 WSL 发行版；herdr 应用模式下隐藏标签、保留标题栏按钮。关闭与退出按核心的 `needsConfirmQuit` 确认；OSC 9/777 通知显示为托盘气泡，点击回到对应终端；响铃遵循 `bell-features`；资源管理器「在此处打开」在盘符根目录也可用。

**Linux GTK 应用**

- 界面语言（GX-0011）：`LANG=C.UTF-8`（WSL 默认）下也能显示中文；改 `language`（配置文件、`gui-settings.ghostty` 或 ☰ 菜单「语言」）后菜单、按钮提示、命令面板与之后打开的对话框立即换语言，终端里的 shell 仍用启动时的语言环境。上游 GTK 文字要系统装有 `zh_CN.UTF-8` 或 `en_US.UTF-8` 之一才跟随切换。
- ☰ 菜单新增「设置…」「键盘快捷键」「语言」；新建标签页按钮的下拉列出启动配置（GX Zsh、herdr、登录 Shell、zsh、bash、fish 与 `gx-launch-profile`），可在新标签页或新窗口启动；可搜索的快捷键速查对话框；执行 `gx:` 动作；窗口与标签页的默认标题为 `Ghostty GX`。
- 设置对话框（GX-0015）：`ctrl+,` 与「打开配置」打开它，页面与 Windows 相同（外观页的材质为纯色 / 半透明 / 毛玻璃），主题列表移动即预览、应用才写入，改动只写 `gui-settings.ghostty`。
- herdr 应用模式与 GX 外观（GX-0016）：唯一的标签页运行 herdr 时隐藏标签栏；圆角标签、1 px 分屏线、更细的滚动条，`window-theme` 为 `auto` 或 `ghostty` 时标题栏与标签配色取自终端主题，重载配置即更新。

**GX 共享核心与配置**（`src/gx`，Windows 与 GTK 应用共用）

- 配置分层（GX-0010）：GX 默认值 < 用户配置（含 `config-file` 引入的文件）< 设置界面写的 `gui-settings.ghostty`（与 `config.ghostty` 同目录）< 命令行；用户的 `theme` 与显式颜色照常覆盖默认值，`GHOSTTY_GX_DEFAULTS=0` 恢复上游加载方式。
- 新配置键 `gx-launch-profile`（`名称=命令` 的自定义启动配置）、`gx-herdr-app-mode`、`gx-window-material`（仅 Windows）、`gx-idle-processes`、`gx-open-config-ui`（默认 `settings` 打开设置界面，`editor` 照上游打开配置文件）；`language` 只认 `zh-CN` 与 `en`，可在运行时切换。
- `gx:` 绑定动作（GX-0014）：`keybind` 与 `command-palette-entry` 可用 `gx:settings`、`gx:main_menu`（默认 Ctrl+Shift+M）、`gx:keybinds`（默认 Ctrl+Shift+/）、`gx:new_tab_profile:<id>`、`gx:new_window_profile:<id>`（`<id>` 如 `pwsh`、`wsl:Ubuntu`、`custom:<名称>`）；默认命令面板追加「设置」「键盘快捷键」「主菜单」，Windows 与 GTK 的命令面板都列出并执行 `gx:` 条目，这三条的标题与描述随界面语言显示，切换语言后即更新。
- 关闭确认识别空闲进程（GX-0012）：`confirm-close-surface = true` 时，终端里只有 shell、shell 启动器与控制台辅助进程（`gx-idle-processes` 或内置列表）就直接关闭，运行 `vim`、`herdr` 或后台任务时照常确认；Linux 与 Windows 之外保持上游行为。
- 内置主题 `GX Mocha`（Catppuccin Mocha 调色板，`#1f1f28` 背景），加载时写入用户主题目录。

**打包与发布**

- Windows：`just package-windows` 产出便携包 `ghostty-gx-<VS>-x86_64-windows.zip` 与安装包 `ghostty-gx-<VS>-x86_64-windows-setup.exe`，都带 ConPTY、Mesa 与第三方许可证。安装包要求 Windows 10 1809 及以上，默认按用户安装到 `%LOCALAPPDATA%\Programs\Ghostty GX`（可选为所有用户），提供开始菜单、可选的桌面图标、App Paths 与资源管理器「在此处打开 Ghostty GX」，并安装随附的 JetBrainsMono Nerd Font 与 Noto Sans CJK 字体（范围与程序相同；已有则跳过，卸载时保留），卸载不动用户配置。
- `gx-release` 资产：libghostty-vt 预编译库（Linux x86_64/aarch64 glibc、x86_64 musl、wasm32、Windows MSVC）与源码包、完整源码包、实验性的 Linux GTK 包（Debian 13）、Windows 便携包与安装包，`macos` 输入为真时另有 libghostty-vt XCFramework 与未签名的 macOS app；附 `SHA256SUMS` 与 `manifest.json`。
- GX Shell 组件 stage：`scripts/gx_package.py windows|deb` 生成并复核 schema 3 的 stage；deb 用 Ubuntu 24.04 构建配方 `scripts/gx_linux_build.py`（随包带 `libgtk4-layer-shell.so`），`gx-release` 的 `linux-gtk-noble` job 在全新 `ubuntu:24.04` 容器里构建、安装并截图验证。

**开发框架与工具**

- AI 协作框架：根 `AGENTS.md` 的 fork 段、`docs/AGENT_RULES/` 的 22 份领域规则与 `just rules`；Claude Code、Codex、ZCode 的 PreToolUse hook 共用一份危险操作策略，真实接入状态见 `docs/AI_TOOLS.md`。
- `just` 命令入口（Windows 与 Linux/macOS 用法相同）：`just setup` 把钉版 Zig 0.16.0 与 graphify 装进仓库内的 `.local/`（`--innosetup` 另装 Inno Setup 7.1），不做系统级安装；并行测试运行器 `scripts/zig_test.py`（`just test-vt`、`just test`，运行期 `--filter` 不重新编译，失败时打印复现命令）与 `scripts/run_unittests.py`（`just framework-test`），测试二进制由 `test-lib-vt-bin`、`test-bin` 步骤构建（GX-0002）；另有代码图谱与知识库（`just graph*`、`just kb*`）、GX 翻译表（`just i18n`）、WSL 入口 `just wsl` 与提交规范 `type(scope): 中文描述`。

### Changed

- 默认配置（GX 默认值，用于 Windows 与 GTK 应用及 `ghostty +show-config` 等命令行动作）：主题 `GX Mocha`、界面语言 `zh-CN`、字体 JetBrainsMono Nerd Font（中日韩字符经 `font-codepoint-map` 用 Noto Sans CJK SC，缺失时走系统回退）、12 号字、内边距 10/8 并居中、闪烁的块光标、`gx-herdr-app-mode = true`，Alt+1..Alt+8 留给 shell；Windows 上关闭最后一个窗口即退出。
- Windows 上的构建与测试：Windows 目标的 `-Dapp-runtime` 默认为 `win32`（GX-0003）；`just build` 在未给 `-Dtarget` 时补 `-Dtarget=x86_64-windows-gnu`，用 Zig 自带的 MinGW 构建 win32 应用，不需要 Visual Studio；`just test` 以同一组合构建并运行完整单测 `ghostty-test`。libghostty-vt 仍用 `just build-vt` 与 `just test-vt`。
- CI：上游 15 个 GitHub Actions workflow 原样归档到 `.github/workflows-archive/`，只启用 `gx-ci.yml` 与 `gx-release.yml`。`gx-ci` 在 push 与 PR 到 `gx_ghostty` 时运行 `framework`（规则路由、CHANGELOG 版本标题、框架单测、知识库新鲜度、首父链提交标题）、`zig-fmt`、`linux-vt`、`linux-main`（无 app runtime 的完整单测）、`lib-vt-cross`（6 个目标）、`windows`（libghostty-vt 测试、构建与静态链接示例）与 `windows-app`（构建 win32 应用）；GTK 截图（`gtk_smoke`）、Windows 截图（`win_smoke`，Mesa 软件渲染）、macOS 测试与缓存探针需手动触发。测试 job 与本机用同一套并行运行器，结果与缓存诊断作为 artifact 上传。
- 发布：`gx-release` 只能手动触发，默认只构建与校验；`publish=true` 时以 tag `gx-vX.Y.Z` 发布正式 release `Ghostty GX X.Y.Z`（不是 prerelease），说明以本文件对应版本节开头、后附资产表。资产都未签名，完整性靠 `SHA256SUMS`、`manifest.json` 与 GitHub 资产摘要。

### Fixed

- 版本推导（GX-0001）：HEAD 打了非 `v` 前缀 tag（如 `gx-v0.0.1`）时，未传 `-Dversion-string` 的 `zig build`（包括 `zig build --help`）不再 panic，版本回退为分支预发布版本 `X.Y.Z-<branch>+<hash>`；`tip` 与 `vX.Y.Z` tag 的行为与上游一致。
- 配置诊断（GX-0010）：设置了 `theme` 时，明暗切换与 `ghostty +validate-config` 再次重放配置不再丢掉 `config-file` 打不开、循环引用等诊断，`+validate-config` 不再漏报缺失的 include；`GHOSTTY_GX_DEFAULTS=0` 时同样生效。
- Windows 字体发现改用 DirectWrite（GX-0009）：粗体、斜体、粗斜体使用字体族里真实的字面（此前粗体常显示为常规体）；`微软雅黑` 等本地化族名、注册表登记在其他目录的字体与 `AddFontResourceEx` 加载的字体都能找到；按码位回退改用系统字体回退并按区域设置选字（`中` 在 zh-CN 下用 Microsoft YaHei UI），首个 CJK 字符不再逐个打开字体文件；`ghostty +list-fonts` 列出各字面的样式名。
- 输入法预编辑（GX-0021，各平台共用的渲染器）：在 herdr 这类铺满背景色的 TUI 里开始组字时，渲染线程不再因字形游标越界而崩溃。
- Windows 上终端与 ConPTY 的屏幕同步（GX-0022）：输出滚进回滚区后再放大窗口，不再把历史行拉回屏幕，而是在提示符下方补空行；之后的命令与输出紧接在提示符后面，不再写到旧行上、与旧行交错或留下多余的提示符，使用系统自带 ConPTY 时也不再丢掉被拉回的那段历史，滚轮能翻回全部输出。shell 在提示符前发 OSC 133（如 GX Zsh 的 powerlevel10k）时，使用系统自带 ConPTY（开发构建、`GHOSTTY_GX_CONPTY=system` 或随包 ConPTY 不可用时）不再每执行一条命令就把上一条折叠后的命令行滚出屏幕、在顶部留下空行；Windows 上 OSC 133 不再做 fresh-line，与 ConPTY 和 Windows Terminal 一致。
- Windows 上的上游 termio 缺陷（GX-0005）：终端输出能及时重绘，子进程退出时进程不再崩溃，带引号且含空格的 `command` 路径可以启动，`https://…` 这类链接不再被当作路径解析而触发断言。
