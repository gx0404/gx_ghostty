# GX UI 原计划剩余任务：新对话执行与交接计划

> 交接生成：2026-10-13；事实切点：2026-10-12。旧 goal 已 **paused**，整体 **not_complete**。本文件只交接，不恢复 goal，不实施功能，不运行 build、GUI、性能或下载，不修改配置、状态 JSON、生成物、分支或系统状态。本文中的执行命令全部属于**新对话获得执行授权之后**的计划，不是本轮已执行记录。
>
> 口径：**源码 CLOSED ≠ 最终 GUI PASS ≠ 性能达标 ≠ 全 goal 完成**。不重做原 37 份审计或已集成的 R2/R3 实现。原记录里的旧 `workflows.*.next` 不是当前 pending 真源。

## 0. 一次复制即可授权继续的启动提示

用户在新对话发送下面整段，即是该对话的**执行与本地提交授权**，不必再问“是否执行”。**本文本身、引用提示，以及本轮生成/修订计划都不构成恢复当前paused goal的授权**；当前仍只做文档交接。

```text
请只用 gpt-6.1-sol，读取并执行 E:/gx_projects/gx_ghostty/docs/GX_UI_REMAINING_PLAN.md。我授权按此文件继续全部后续任务，延续本地精确中文commit与--no-ff合入gx_ghostty权限；不push、不移动main镜像、不创建tag/release/Issue/PR。此消息就是执行及上述本地提交授权，无需再问是否执行。
先按H00–H04只读核对模型、AGENTS/rules、分支/HEAD/tree/dirty、worktrees和证据，保护未知改动，不reset/stash/force。GetGoal若发现同session的原目标paused，按此明确授权转active并接续剩余任务；若新session没有目标，用CreateGoal以本plan路径和原完成契约建立目标。不得复活旧模型代理或跨session复用agent/task ID；无法从调度元数据确认6.1-sol时不降级、不读配置或凭据，报告后停止相关调度。
主gx_ghostty冻结98e89ac4e92b3b22284ba8d4256a511e0bc8a9ef，候选R23-int冻结d6f9e1c03587971096ea595cedc614f47a99ef5e。源码已闭合部分不重做；C1优先但不硬锁R5。最新GTK事实是三正常RF build PASS、全机quiet BLOCKED、0/40 loads、DATA_VALID=false、Gate/Pool均INSUFFICIENT、0新截图，不是半跑或已有收益。quiet不满足时推进其他安全任务；真正采样前停重型工作，不控制非owned程序。
执行剩余R4、R2/R3最终叶需求验收、全部R5十一流和R6，不删R5、不降低门槛、不以环境说明冒充完成。重型全机最多三槽，GUI/bench独占桌面串行，quiet采样期间禁止编译/测试。每项绑定source/tree、标准二进制/receipt、命令exit、raw单位+n、真实响应与逐图证据；保留失败和未采纳成果。系统安装/注册、下载、未知进程或未知用户剪贴板操作不在此授权内，按本文边界处理。最终gx实树通过必需门和真实场景后才complete。
```

只想审计划的替代消息：`请读取上述plan，仅只读审阅，不执行、不恢复goal、不提交。`

## 1. 完成契约、授权边界与冻结事实

### 1.1 完成契约

原目标是 Windows 与 GTK 同等投入的 UI 交互、美观、性能优化，保留 D1–D17 产品决策，完成 R0–R6。新对话交付必须同时满足：

- 保留已闭合源历史，完成非条件性功能与最终需求追踪；R5 不得仅交设计或从范围移除。
- 条件性 R4 项逐项给有效实测及“采纳／拒绝／证据不足”决策。拒绝可关闭该**决策**，不等于优化实现或性能 PASS；证据不足仍 pending，保留源分支。
- 标准最终 Windows、GTK/POSIX 构建测试与框架门通过；所有 GUI 可见变更有对应最终树真实、已读图证据；性能按原口径完整新旧各十次，报告 median/p90。
- 最终本地 `gx_ghostty` 集成后再次核实际 HEAD/tree、二进制、场景及检查结果。没有全绿或必需环境仍缺，照实 FAIL/PENDING，不自行豁免、缩小交付或宣布 complete。

**状态定义：** PASS 只用于已执行且身份/验收匹配；FAIL 保留原始失败；PENDING 尚未完成；BLOCKED 是具体前置受阻；CLOSED 是已复审关闭的源码发现；INSUFFICIENT 是不足以作收益决策；REVOKED 是永久撤销的旧数据；N/A 必须解释真正不适用。新任务默认 PENDING，以下表中明确列出的历史 PASS 不自动继承到最终树。

### 1.2 硬限制

- 仅 `gpt-6.1-sol`；不读取凭据、私有模型配置或全层配置 RPC，不更改模型/权限，不复活旧模型代理。
- `src/apprt/win32/`、`src/apprt/gtk/gx/`、`src/gx/` 优先承载业务；上游只留必要 GX 薄钩子，按实际合入顺序分号、标记、登记及闭集测试。不能盲并实验的编号或 registry 摘要。
- 每分屏一子 HWND、一 WGL context；HWND/D2D 只在 GUI 线程，GL context 同时只在一线程 current；终端状态持 `renderer_state.mutex`，不能让外部 COM/模态循环带锁重入。列进程/关闭确认仍在GUI线程同步，只共享快照，不改成worker异步判断。
- 保留防死锁规避：对`WM_GETOBJECT`的lparam经`src/apprt/win32/win32.zig::objectId`取低32位，匹配`OBJID_CLIENT`则**返回0**，不是把常量改成0。保留首帧cloak/300 ms兜底、live resize **全窗共享最多16 ms截止**，不删除等待制造收益。
- 不用 `timeBeginPeriod`、Windows Animation Manager、AnimateWindow；主窗口不上 DirectComposition/UpdateLayeredWindow，不引入 WinUI、XAML Islands、WebView2。
- GTK 构建下限 **4.14 / libadwaita 1.5**；静态 CSS 不写 4.16 专属语法，不加 `ui/1.6+` Blueprint，不修改上游 GTK 命令面板，不做 Linux 系统热键占用探测。现代能力运行期门控、实测。
- 不复制 GPL 实现/CSS；不再分发 Segoe Fluent Icons 字体，不添加 macOS-only `font-thicken`，不做标签悬停缩略图。开源参考只借许可允许的思路、数值或明确钉版的 MIT 资源。
- GX 默认层 < 用户 config/include < `gui-settings.ghostty` < CLI；设置只写 overlay，不改用户 `config.ghostty`。历史、session、窗口状态写状态目录，不写配置。Windows 中键粘贴、GTK 默认 shell 改 GX Zsh仍不做，需另行产品决定。
- 不能绕过 UAC/UIPI、输入保护、桌面点位/前台守门；不解锁、不操作外部遮挡层。未知用户剪贴板不读、不备份、不保存内容；测试必须先建立安全、明确许可的测试剪贴板条件。
- 工具链只经仓库钉版 wrapper，本机安装仅 `.local/`。外部下载、apt/系统依赖、开发者模式、读屏安装、安装注册/通知平台等副作用另获许可；不清未知进程或外部锁来“变绿”。
- 禁止 reset/stash/force、无差别暂存、push、移动 `main` 镜像、手工 tag/release、Issue/PR。无收益不删成果；清理只处理本轮可证明自有对象。

### 1.3 冻结表

路径以 `E:/gx_projects/gx_ghostty` 为主根；源码引用 `src/...::symbol` 默认针对候选 R23-int。`I` 以下简称 `.local/worktrees/R23-int/.local/integration`。表内 SHA/tree 都是完整身份，不是将来的分支定位替代品。

| 对象 | 分支 / HEAD | tree / 事实 |
|---|---|---|
| 主仓 | `gx_ghostty` / `98e89ac4e92b3b22284ba8d4256a511e0bc8a9ef` | `210ddbe9187e2cc68efb9959ecb930a57f10cbcf`；本轮起始 clean，仅允许新增本文，不移动分支 |
| 候选 `.local/worktrees/R23-int` | `wip/R23-integration` / `d6f9e1c03587971096ea595cedc614f47a99ef5e` | `3afa2ffbf3ce2a5a5634b50ddbb370f9c9ee882d`；起始 clean；业务 `src` 与 cfee 零 diff |
| 业务验证切点 | `cfee2c704725128681fcbb0632ac889b101c769b` | `fe087f3caa6d897ad4de3d255ecc9b044a7ce3e4`；R4 Font 已合，历史测试绑定此树 |
| 有限 GUI 切点 | `7911842f29322bad083c13487262f2bdb79bdda5` | `c9d30ff7d38a11d76198005ed66e2805c4152aa4`；不能充作 cfee/d6 最终 Font 图 |
| 最新测量 | `.local/evidence/R4/GTKPipeline/quiet-reviewed/` | 3 正常 RF 构建 PASS；quiet BLOCKED；两组十对实际 **0/40 loads**、新截图 **0**，`data_valid=false` |
| 暂停/任务 | 旧 goal paused；整体 not_complete | 最新测量及 d6 收口记录 TaskList active0、desk free、slots empty；本轮只读 TaskList 也为 active0。这是时间点记录，不保证新会话无其他负载 |

主 `.local/r23-state.json` 仍是 d6 集成状态；最新 quiet 测量事实在上述四份原件，时间较新。`normalharness/VARIANTS.json` 的“393 awaiting review/runtime pending”是旧 stage4 作者快照，已被后续独立复审 CLOSED 和 quiet-reviewed 真构建覆盖；不把它误读为需要重开原发现。后续仍应保存两个时期的记录，不能覆盖历史。

## 2. 已 CLOSED／已集成：不要重做

| 范围 | 当前事实与证据入口 | 仍需什么，不等于什么 |
|---|---|---|
| R0/R1 | 已在主基线及后续候选保留：越界/焦点/模态/编辑键路由、共享 UI/配置/进程缓存、自动化与度量基础；`CHANGELOG.md`、原计划及 R23 集成历史 | 不重跑 37 审计；最终回归/性能不是已有实现的重做理由 |
| R2/R3 初、中、晚批全部固定工作流 | 已合 R23，含 App/Window/Surface/Render、Tabs/Caption、Palette/Settings/Menu/Dialogs/Keybinds/Find/Scrollbar/Quick/Font、GTK 五流及晚接线；`.local/evidence/R23/integration/notes.md` | 旧 `workflows.*.next` 为历史；剩余是下文 V/P/R5，不重开整轮实现 |
| D11/search、CaptionMotion、ChromeAlpha、BellAudio | 最终 search `b0777a5c227a67a6b37bee24405f7225665eb42b`；caption `90c7880565e077922ec477d0cdb8fb3770dd39fc`；alpha `8f93fbb38bace1433e8421f9ed5099bd51664aa0`；audio `e9b7c903122b30cb3e6df6fdaff3da2dc09833f5` 全历史在候选 | 不单合旧 audio `088...`；源码复审/native 不代真实 BEL、DWM、用户搜索动作 |
| BellBorder | 最终 `00ce5d599954a40d0021315e032dd0c87c68311d`，含 idle wake/卸载修复；`I/bell-border/` | 私有 FBO/native PASS；完整 192 DPI 四角、可见 Mesa Swap/DWM、实体 reset 仍缺 |
| 两 helper | ToolCapture `f150734cb1172d9c60015adad1906d8fad5dadd1`、ShortcutTitles `0d1ee2c66cffae91a5d5476706ef06dd3a4904ac` 已核候选祖先 | 不是待合分支；原红灯与修后证据保留。Caption `0x4C/0x4D` 已重号，不是未做 |
| R4 mandatory | Renderer `098c2869fe50a587348cea0120189e0e9d784248`；Defaults `7a6c971740763c0fd70de45af202b737a7f8dfd1`；GTKInput `5adbf36db88b824fc2a3b7916543d8cbf7845899`；Webgen `d29835e95c894b6a669f56dead23f4dce5a26bb5`；Font `e4158541e287fe64037a5c898911a17d2a15b649` 已全历史合入 | GX-0031 blink、32 background、33 vsync doc、34 system blink、35 zoom、36 env append、37 web flush、38 mapped family；32 在册 ID/max38。mandatory source 已闭合，不等于 conditional/GUI/收益完成 |
| Font 旧两发现 | 普通 discovery 的 private index 泄漏、真实 fromDeferred/file/尺度覆盖不足均 CLOSED；e415 是父713的纯重号，完整父3f历史保留；`I/r4-font/` | 真实 100%/96 DPI 中文粗体、默认字体/alpha 视觉验收仍缺 |
| 标准 GTK harness | `2eeea2df46cfbe21654a8d7ee1088966d174b67d` 全四提交合成 d6；7 路径，无业务 src 改动；`I/r46-harness/` | d6 不含 gate/pool/diag/最新 bridge（含 core 跨侧 n 修复）；不要直接拿它执行新比较 |
| 实验源码 | Gate/Pool、共同诊断/FD 所有权及新 bridge 独立 **395/396/393 CLOSED**，最终三测量 SHA 见 C1 | 未采纳到 R23；CLOSED 不代表收益；不重开已修 pool 发布/OOM-FD/独立像素/n 发现 |

### 2.1 历史验证必须绑定原树

- **d6 最新实际定向**：Windows `943 PASS + 11 SKIP = 954`；Windows scripts `215 PASS + 6 SKIP = 221`；Linux scripts `171 PASS + 1 SKIP = 172`。初次脚本临时目录 WinError32 失败和重跑均保留。`I/r46-harness/` 保存实际新 build、JSON、CLI、receipt，不借 cfee 计数。
- **cfee 业务宽根**：Windows `1234 PASS + 19 SKIP = 1253`；GTK `872 PASS + 14 SKIP = 886`；POSIX `779 PASS + 14 SKIP = 793`，非最终全量套件。真实普通/映射字体隔离、非1 `ic_width`、96/144 DPI、FT 句柄/锁/ppem/metrics/OOM 已执行；找不到字面 `FontKeyPolicy` 不代表无覆盖，真 case 是 `gx.font_codepoint_map` 的 grid-key disabled/synthetic policy。
- cfee/d6 的 Audio26、Alpha11、D11/search17、caption2、`ghostty.h` ABI22、40B termio message2 有实际子集 PASS；显式 native BellBorder NVIDIA/Mesa 各5/5属于私有 FBO，不是上屏 Swap/DWM。
- 两端实际 Config.load `28/28` 和三 webdata **全文末项＋闭合 suffix**已验证；d6 历史长度 config162163/actions22038/commands22416B。新的源码改动后不能固定旧长度代全文合同。
- **framework 当前不是绿**：最新两轮879，KB freshness 1 failure，加 Windows 临时 repo cleanup WinError32 最新3 errors、14 skips；此前6 errors、定向复现1 error等原件保留。KB82来源过期 exit1，graph 指纹1063→1115过期 exit2。cfee framework845也有 KB failure，不混成 d6 全绿。
- 旧完整 VT 的 tinyio4处、main2处符号链接 `PermissionDenied` 是真实环境 FAIL，不能跳 case、改断言或用定向通过抹掉；最终标准门需合法前置与重新验证。
- 791 有限 Windows字体 restore/include、Mocha7/15、mouse-hide、终端焦点 F3真图 PASS；GTK在首业务 click 前 WINDOW=0/BadWindow，runner FAIL、业务 PENDING，没有执行 wheel/switch/split/reload。历史 LockScreen/H-SMILE/point guard不代表现在永久 blocked，今后每次 fresh 守门。
- d6 仅一有效标准 RF sample、每实验父变体各一 bootstrap：只证 source/路径/采集合同，**占产品十对数均为0**。d6 CPU总2038 tick/端点1999 tick、残差与候选界仅 diagnostic_only/unproved，没有精确 full-population/comparable 保证。

## 3. 新对话有界恢复步骤

| ID / 状态 | 依赖 | 行动、入口与完成证据 |
|---|---|---|
| H00 / PENDING | 用户新消息 | 核6.1-sol调度元数据，不读配置/凭据；Read本文、根/候选AGENTS，safe GetGoal/TaskList读现状态。用户发送第0节执行提示即已授权，无须再问是否执行/提交：同session有paused原goal则转active、接续原完成契约和本文剩余任务；新session无goal则CreateGoal记录本plan路径与第1节原完成契约，建立本会话依赖任务。旧agent/task ID不跨session复用。仅审提示或本轮修文不授权active；工具名称按实际可用接口，不以文档代工具状态 |
| H01 / PENDING | H00 | 分别在主仓、候选、三测量树跑 `git status --short`、`git branch --show-current`、`git rev-parse HEAD HEAD^{tree}`，主仓 `git worktree list --porcelain`；核本节身份、MERGE_HEAD、tracked/untracked、含本文的新文档改动。漂移或未知改动先保护并报告，不 reset/stash/checkout 替换 |
| H02 / PENDING | H01 | Read `.local/r23-state.json`、最新 integration notes、quiet-reviewed 的 notes/summary/commands/build-identity 四原件；验证 receipts/exe hash 与版本记录，核原失败和祖先历史。状态 JSON 只能获执行授权后按新证据增量维护，不能洗历史 |
| H03 / PENDING | H02 | 实际完整触及路径先 `just rules ...`，读所有 domain/nested AGENTS；扩大 scope重跑并集；`just rules-check`闭集失败不绕过。匹配 graphify skill时先加载，按 `scripts/graphify.py` wrapper；图过期只作导航并直接核源码。只读冻结时不用会写查询 stamp的入口，不 reflect/save-result/rebuild，不读旧模型凭据 |
| H04 / PENDING | H03＋执行授权 | 建新 owner/worktree/slot/desk账本，核 `.local/bin/slot.sh`、`desk.sh` 合同后使用；fresh Win PID+birth+exe+foreground+pointguard，WSL owned Popen/held fd/pidfd+birth，不沿用旧数字。当前文件不替这些实时证据；记录基线清单、环境限制与执行前置 |

恢复每步只查必要范围，不全盘扫描用户目录、环境变量或会话；原 plan和指定架构报告可按第10节作只读溯源，本文足以理解任务。缺文件/凭据/环境不能凭记忆编造。旧 TaskList0不是清别人的授权。

## 4. 依赖、并行与单写者

**优先序不是硬依赖**：`H00–H04 → C1优先尝试`；H04/V00之后，R4条件研究、V链路、R5-00及十一流可按自己的真实依赖推进，**不以C1 quiet/收益尚缺硬锁R5源码**。C1受非owned外部负载阻断时有界记录并转其他安全非测量任务；有执行授权时可实施/构建R5，准备采样前再停完所有重型工作。不得控制外部程序或无限等待。收尾依赖为`各必需任务源/验收 → R6真源冻结/生成/总门 → 最终gx集成复验 → 清理/完成`，未过必需门真实report、不得complete。

- **全机**最多3个重型 build/test（不是每代理3个）；统一 `slot.sh`，WSL与Windows一并计。GUI与bench同 `desk.sh run`独占串行。quiet两批期间不开build、测试、生成器重活、其他GUI；不杀非owned背景任务。
- 每流独占新模块；提交固定 SHA后独立复审，协调者按顺序整链 `--no-ff`，不要只追漂移 branch HEAD。失败修复小范围回作者，再审，不“编译相容”覆盖合同。
- **单写者热文件**：Win32 `App.zig`（含 surfaceWndProc）、`Window.zig`、`Surface.zig`、`ui/d2d.zig`、`Popup.zig`；GTK `class/application/window/surface/split_tree.zig`及GX路由；`Config.zig`、`gui_settings.zig`、测试根、PO、fork registry/shape、包装/自动化 scripts、共享文档/生成物都由协调集成 owner接线。
- R5的COM/身份/LaunchOrigin接口先冻结；IPC、转移、session、toast共享稳定引用但不共享裸地址。GTK编辑/profile可并行，GTK尺寸/session/split共享生命周期必须同一上游hook owner。Fluent与DComp可并行开发，D2D接点单写者。
- 每流最小验证：对应 rules＋定向Windows及POSIX/GTK tests、fmt、界面文字i18n、diff-check、必要真实场景与独立复审；测试根显式纳入，零命中filter不能称PASS。阶段framework/ci门照实记录，不因KB延后而称完成。

**Git Bash通用准备块**：新对话获执行许可后，在每个要调用just/zigw的独立shell先设同一主仓cache；这块与下文命令分开复制。编译只经`just`/`scripts/zigw.py`钉版**0.16.0**。已有`$ZIG`指向用户已安装的同版工具链时可依法核版本后沿用，不是新系统安装；默认`.local`工具链缺失不授权下载未钉版替代或系统安装，应按钉版setup权限报告/处理。

```bash
export ZIG_GLOBAL_CACHE_DIR='E:\gx_projects\gx_ghostty\.local\zig-cache\global'
```

所有`--clone "~/src/..."`必须保留引号，使字符串交给标准WSL wrapper；裸`~/...`会在Git Bash展开成Windows home。未来的build/sync只发生于quiet采样准备之前；`scripts/gx_perf.py::run_gtk`自身只循环标准smoke、**不build/sync**，不能指望perf自动刷新产物，也不能手动parent-host wsl跑perf替标准路径。

## 5. C1：优先恢复 GTK 两组完整标准十对，并安全选择分支

### 5.1 不可变输入和当前进度

三树均 `.local/worktrees/R4-GTKMeasurement-<variant>`，分支 `wip/R4-GTKMeasurement-<variant>`；各自 owned WSL为 `/home/gx/src/gx_ghostty-R4-GTKMeasurement-<variant>`，命令里的 `~/src/...` 指同一个gx用户目录。

| variant | 冻结 HEAD | 冻结 tree | 正常标准产物 |
|---|---|---|---|
| base | `fe2b233bd862c9105bc13dcb25fbdcece0bf1c49` | `856ddc25e8b3a40d5b9b60b1e997c14e8e8b4459` | `...-base/zig-out/bin/ghostty`；`quiet-reviewed/base-build-receipt.json` |
| gate | `b3fce03df816179377f9438d5d0b8612ef9ed7c5` | `dc89beb2344e23404fd04c8ebfb450ec0b40927b` | `...-gate/zig-out/bin/ghostty`；`quiet-reviewed/gate-build-receipt.json` |
| combined | `0ca3cf5629d23e8b8408415fb258482a7bf85b14` | `56d9ecef7aa3703d7f35fffbfd2559f82368ff01` | `...-combined/zig-out/bin/ghostty`；`quiet-reviewed/combined-build-receipt.json` |

完整 exe/receipt/collector四文件hash与stat在 `.local/evidence/R4/GTKPipeline/quiet-reviewed/build-identity.json`。三正常 `just wsl sync --clone ...` 后 `just wsl build --clone ... --gtk -Doptimize=ReleaseFast --summary all -j4` **真实exit0、install/eligible、before=after、dirty=false**；不是build被打断。没有理由仅因paused重复编译；身份变了才用正常wrapper重新生成对应真实receipt。

最新 quiet检查：compiler/test为0、slots空/deskfree，但全机CPU持续忙；三个窗口LoadPercentage100→63、66→32、49→69及非owned稳定身份CPU增长保留。有限等待30s、90s后仍blocked；衍生 `percent_of_one_core`不是校准CPU率。**两批命令仅记录、完全没执行：0/40 loads、0新截图、DATA_VALID=false，Gate-only和Poolcombined边际均INSUFFICIENT。** 不写“中断半跑”、median/p90或优化收益。

### 5.2 有界步骤与完整验收

| ID / 状态 | 依赖 / owner | 入口、动作与验收／完成证据 |
|---|---|---|
| C1-0 / 历史PASS，待fresh身份核 | H04 / perf owner | 核三树clean/SHA/tree、normal RFreceipt/exe版本/hash、相同collector4和共同marker；read 395/396/393源码关闭证据。旧normalharness awaiting文本不重开发现；旧receipt与当前身份一致就不重build。新source/产物变化才在quiet前经正常wrapper重审/重build和receipt，不手写或借父receipt |
| C1-1 / BLOCKED | C1-0 / 协调＋perf | 等外部负载自然结束或有界请求用户安排测试时段；重做**全机**quiet只读检查，含非owned CPU、Win/WSL重型、slots/desk。compiler0不等quiet；未过不启动load，转其他安全任务，不无限wait/操作外部程序。记录原因，不加新CPU百分比阈值。quiet通过后禁止编译/测试 |
| C1-2 / PENDING | C1-1通过 / perf | cwd必须为base测量树，使用其新标准bridge；两批顺序canonical十对AB/BA、20loads各、总40。每批OUT和对应JSON都fresh且不得覆盖，不warmup/丢cold或异常样本、不改settle/标准输入/尾1s/50ms采样、不另xdotool/input/new-window。perf只标准smoke，不build/sync或手动wsl替代；保存plan/argv/meta/raw/hash/receipt/birth/exit/captureID，严格拒subset/重复/单位或n错配 |
| C1-3 / PENDING | C1-2 / 独立证据reader | 每load seq1..3000000真实finished/exit0，40个末图逐张读见3000000；同身份重算全部raw。core main/renderer/total/window/workload两侧n=10，共有cpu组跨侧n相等，optional缺侧unknown不是0，count/gauge单位不当us。报CPU各组/总量/window/workload/minflt/RSS/HWM/成功export-import/gate-pool计数。missing、reused、negative、incomplete等安全门不弱化；失败整批INVALID保留，不补样凑n，重测用新完整批 |
| C1-4 / 合理校验PENDING；额外数学界独立PENDING | C1-3 / 计量review | 完整解释process total累计含退出线程、endpoint各TID组、CLK_TCK量化、舍入残差/读取偏斜；保持held fd/Popen未reap/pidfd＋birth、TIDbirth和实际采样安全校验，不拿端点sum当精确full-population。unproved候选界仅diagnostic，不作valid/comparable或精确transient CPU证据；**未证明额外全人口数学界本身不否定合法standard10pair，也不是新增必过门**。只有实际用于收益结论的精度/方向不稳或差异无法合理解释才INSUFFICIENT；未证CPUprecision独立PENDING报告，不新定百分比阈值。后端仍靠EGL设备/driver与成功export/GDK import，不靠环境名/GL字符串推断硬件 |
| C1-5 / PENDING | C1-3＋C1-4合理校验＋功能门 / 协调 | 原R4采纳口径不变：“收益明确才做”；原性能表要求renderer CPU下降，报告median/p90及原始差异，不新增门。base→gate与gate→combined只分别证明Gate和**在Gate上**Pool边际：Gate达门、Pool不达只采Gate；两者达门才采combined。Gate不达/不足时，即便Pool边际看似好也不能推断pool-only有效；需另建同量尺pool-only变体和完整标准对照才能决定，否则Pool保PENDING、源/理由保留，不遗漏其任务。measurement base只是共同量尺不是优化收益 |
| C1-6 / PENDING | C1-5采纳 / 集成 | R23的2eee不含最新bridge；先审保留标准receipt/FD/n/诊断合同的安全集成差异，再采获准gate/pool。实验GX39 gate、40 pool、41diag、42FD按**最终实际采纳顺序**统一重号，与实际32ID/max38闭集合并；不得覆盖原31–38/测试根/原3尾合同。仅branch组合no-ff可能带未采Pool，须隔离获准层及审历史，不拿整个combined硬并 |

先复制第4节cache准备块，完成C1-0/1后才复制以下Git Bash链；**cwd为 `E:/gx_projects/gx_ghostty/.local/worktrees/R4-GTKMeasurement-base`**。两批来自 `quiet-reviewed/commands.json`，各经真实`slot.sh → desk.sh run → python scripts/gx_perf.py gtk`，`&&`传播失败，第一失败不执行第二。四个fresh检查同时保护两个OUT及两个JSON；若任一已存在，保持原件、另选成对新OUT/JSON并记录，不能删旧输出来让检查通过。perf不build/sync，身份失配应退回quiet前准备，不在quiet后补编译。

```bash
cd "E:/gx_projects/gx_ghostty/.local/worktrees/R4-GTKMeasurement-base" &&
test ! -e "E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/base-vs-gate" &&
test ! -e "E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/base-vs-gate-result.json" &&
test ! -e "E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/gate-vs-combined" &&
test ! -e "E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/gate-vs-combined-result.json" &&
bash E:/gx_projects/gx_ghostty/.local/bin/slot.sh bash E:/gx_projects/gx_ghostty/.local/bin/desk.sh run python scripts/gx_perf.py gtk --clone "~/src/gx_ghostty-R4-GTKMeasurement-base" --clone "~/src/gx_ghostty-R4-GTKMeasurement-gate" --label base --label gate --out E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/base-vs-gate --runs 10 --env GHOSTTY_GX_PERF=1 --env GHOSTTY_GX_PIPELINE_STATS=1 --env GSK_RENDERER=cairo --json E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/base-vs-gate-result.json &&
bash E:/gx_projects/gx_ghostty/.local/bin/slot.sh bash E:/gx_projects/gx_ghostty/.local/bin/desk.sh run python scripts/gx_perf.py gtk --clone "~/src/gx_ghostty-R4-GTKMeasurement-gate" --clone "~/src/gx_ghostty-R4-GTKMeasurement-combined" --label gate --label combined --out E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/gate-vs-combined --runs 10 --env GHOSTTY_GX_PERF=1 --env GHOSTTY_GX_PIPELINE_STATS=1 --env GSK_RENDERER=cairo --json E:/gx_projects/gx_ghostty/.local/evidence/R4/GTKPipeline/quiet-reviewed/gate-vs-combined-result.json
```

`GSK_RENDERER=cairo`只是此受控实验共同变量，**没有改变生产默认**。原 `.local/evidence/R4/GTKPipeline/{baseline-gate/,gate-combined/,baseline-gate.json,gate-combined.json,EVIDENCE.json,notes-before-auditor393.txt}` 的unsafe harness旧40loads **永久REVOKED**，任何旧meets/doesn't meet均不能采纳；原件保留，不能回填成绿。bootstrap各一次也不计入这40。

C1完成证据还需获准层最终candidate标准build/Windows共享模块与GTK/POSIX相关测试、registry/roots/MDX检查、功能像素/native和实际GUI；实验已测4×4/非uniform独立BGRA、真实GDK texture/OOM/late release只证明对应源码，不替硬件DMABUF或最终性能。硬件路径缺失继续V7，不以Xvfb补绿。

## 6. 其他 R4 条件决策与完整性能矩阵

### 6.1 条件项：必须逐项保留

以下依赖H04；涉及桌面依赖V00前置，测量依赖quiet。每项完成证据均是fixed source/tree＋normal RF build身份＋完整对照raw/median/p90或已读图＋独立审查＋采纳/拒绝理由；当前都未形成最终采纳结论。

| ID / 当前状态 | 真实入口 | 剩余工作与验收 |
|---|---|---|
| C2 / PENDING | `src/gx/defaults*.ghostty`、`src/renderer/opengl/wgl.zig::present` | `window-padding-color=extend`、`adjust-cursor-thickness=1`、alpha native/linear/linear-corrected、freetype light/no-light在**100%/96 DPI**真实screen对照，含CJK粗体、选区、提示符首列、TUI边框/透明/低alpha。先核native sRGB格式与present语义；`#808080→#bcbcbc`只是静态错配风险，未确证bug，不能为假math改默认。仅明显更好且无回归才改，分别落决策 |
| C2-G / PENDING | `src/gx/defaults*.ghostty`、shell integration | GTK提示符处光标形状统一：实测shell集成、应用/TUI与用户配置优先级，再冻结合法实现；不把审计备选当已批准默认，不预选某个关闭集成选项 |
| C3 / PENDING | `src/os/mouse.zig`、`src/Surface.zig`的配置消费 | Windows系统双击已观测480 ms，空config核心500 ms；用户350 ms必须保留。先实测系统默认来源/点击选择一致性和高层覆盖，收益/一致性明确才加薄钩子，不替系统设置或覆盖用户值 |
| C4 / PENDING | `src/termio/Exec.zig`、`src/renderer/Thread.zig`等实际thread spawn | quiet下1/11终端测真实**commit/提交量**、线程/进程增量，不用WorkingSet、VmSize或审计估计代证。16 MiB stack hint是不是提交量尚待量测；无证不改stack_size。若确有收益再压测长IME/解析/renderer深栈与OOM，不拿减少reserve冒成功 |
| C5 / PENDING | `src/apprt/gtk/class/application.zig::setGtkEnv` | 软件GL下默认GSK/cairo/ngl对照Ubuntu24.04与现代GTK，用户GSK变量优先，真正软件设备判定；只在明显省资源且无功能回归才采用生产cairo选择。C1共同cairo环境不构成这个决策 |
| C6 / PENDING | `src/font/directwrite/discovery.zig::warmup`、`src/App.zig::create` | 原A=完整af8预热＋码位filter，B=仅关general_category，C=仅关预热保filter。warmup现已集成，最终以同current代码仅warmup变量quiet完整10pair决定保留/去留，不用旧A/C冒最终证明；提交/首帧/font cold-hot/RF身份一并报，不借WGL总收益遮独立退化 |
| C7 / PENDING（源码GX31已合） | `src/gx/cursor_blink.zig`、`src/renderer/Thread.zig`、`src/renderer/cursor.zig` | 正常控制组与优化组各10次idle CPU/wake/draw，1/11终端、可见/失焦/最小化、正常blink两相位/隐藏/不闪/IME preedit/输出重新唤醒；独立Kitty和custom shader animation不得抑制。可选停闪尚需单独证据，不擅改默认blink=true |
| C8 / 已实现，最终回归PENDING | `src/gx/environment.zig`、`src/apprt/gtk/gx/environment.zig`、Config vsync doc | `setGtkEnv` append GX36、Windows vsync文档GX33已完成，不重开；最终检查用户已有值追加去重、GTK<4.16路径、WGL vsync传递和完整MDX/CLI合同 |

C6历史定位：`E:/gx_projects/gx_ghostty/.local/evidence/R2/R2-Font/notes.md`与其`perf-loaded/`。A产品历史exe为 `.local/worktrees/R2-Font/.local/out-release-A/bin/ghostty.exe`，SHA256 `ed812081e8bb225a7bc9a639a609de801ff45f2d9c77c5cc3de462ec7b929701`；C为同树`.local/out-release-C/bin/ghostty.exe`，SHA256 `4aadea2091388fd6391c474b2118844ab825603568431a8b96c878b4a6316cb7`；本修文轮只读核两文件存在/hash匹配，未执行。A=B30218240B、分类额外0B；A比C预热额外3584B。旧20/20 responsive但CPU严重混杂，warmup shown median1614.2/p90 2147.0 ms，C1157.2/1658.5 ms，`steady_state_eligible=false`；完整负数/失败等待保留，不能据此删warmup或称收益。旧source/产物可作历史核验，current-variable对照才是最终去留证据；不伪造旧版新版receipt。

系统关闭blink：Windows历史只读`GetCaretBlinkTime`530，不证明INFINITE；GTK私有off/on真实property tests PASS但不是GUI。使用合法已有关闭环境/一次性测试账户或先获副作用许可，**不得擅改系统blink**。最终100% Font图和V6/V7补验必须明确绑定最终树。

### 6.2 原性能门完整保留

所有数值方向来自原计划，不改成“改善即合格”。统一ReleaseFast、`GHOSTTY_GX_PERF=1`、新旧交替各10次、报median/p90；cold/visible/hot分开，P00先核公平性，不套其他source/ConPTY/环境的数。

P00已知定位：`E:/gx_projects/gx_ghostty/.local/evidence/R1-C/baseline/README.md`；quiet raw为其`perf-quiet/baseline/`，loaded为`perf/`，GTK为`perf-gtk/`，旧图为`shots/`。Windows旧RF备份 `.local/perf-builds/a3535c2ed/bin/ghostty.exe` 本修文轮只读确认存在，30068224B/hash `7058b324eb5c0129274e7a802f7fceb23020d9ab0129a19549a4517b4cc0e263`，历史版本 `1.3.2-wip-R1-C-test-perf+a3535c2ed`，系统ConPTY、RTX5080硬件、Win11 26300、150%约3054×1661。GTK历史clone字符串`"~/src/gx_ghostty-r1c"`、snapshot61dbed37d、Ubuntu24.04/Xvfb1280×800/llvmpipe。原记录Windows quiet shown468.4/p90496.7 ms、loaded565.8/625.8 ms只是历史参考；这些旧值与当前bundled ConPTY/GPU/DPI/采集口径不自动公平。新对话先核实际source/产物/raw，缺失或不明metadata标unverified；**不伪造旧baseline新版receipt**。最终用已核且可比的旧新构建重新完整交替十对，或明确报告不可比及原门未验，不把存档单侧数字冒新最终证据。

| ID / 状态 | 原指标与目标 | 入口／最终完成证据 |
|---|---|---|
| P00 / PENDING | baseline清点与公平性 | 原R1基线及各实验raw；冻结OS/刷新率/GPU/驱动/字体/配置/ConPTY/屏幕网格、build优化/source/hash与采样口径；未知项显式列出 |
| P1 / PENDING | 启动→窗口显示：**比基线减少100 ms以上** | `App.run`、WGL settle/首chrome/首帧；用真实进程起点、visible时刻，不只日志第一行，10pair |
| P2 / PENDING | idle60 s：全系统进程快照**每2 s最多1次**、与标签数无关；最小化**0** | `src/gx/proc.zig::Table`、TabBar/app_mode共享路径；1/11/多标签及所有最小化计数，不以局部tick日志代全系统总量 |
| P3 / PENDING | 3窗口×15标签拖窗：滚动条重画**0次** | `Window` move与`Scrollbar` PaintKey；真实拖动/活动后台标签计数及screen |
| P4 / FAIL历史，待最终优化/复测 | Palette、主菜单、Settings **热路径≤1帧、无PATH扫描** | 当前历史Menu160Hz一帧6.25 ms，10/10仍FAIL；旧quiet热median9.548/p9010.213 ms，visible80.270→51.737 ms不是达门。保留冷/可见改善和失败，分别优化并10pair，不切到60Hz阈值洗绿 |
| P5 / PENDING | Keybinds hover每帧`CreateTextLayout` **≤10**，绘制 **<2 ms** | `ui/d2d.zig::TextCache`和Keybinds；真实hover帧/布局创建计数及RF时间，native退路不替自绘热点 |
| P6 / PENDING | 按住↓浏览主题2 s：重载**恰1次** | 两端主题防抖、Layers/apply路径；真按键过程＋reload计数，不能只用计时器单测 |
| P7 / PENDING | live resize：等帧超时次数**下降**；图里无黑边/拉伸 | `Surface.signalFrameDrawn/awaitResizeFrames`、Window共享deadline、WGL edgeFills；旧新同窗口/网格和真实resize视频帧/screen，不删除16 ms等待 |
| P8 / 源码已合，最终证据PENDING | 每终端渲染目标 **6张→2张** | GX-0004 swap_chain_count1/Windows不export texture；实际资源/显存计数，不只配置常量；GTK仍3帧 |
| P9 / 部分源码PASS，完整收益PENDING | GTK Xvfb DMABUF警告**只1次**（原11 s里23次）；标准`--perf` renderer CPU **下降** | GX29失败锁存已合；C1完整比较与真实成功export/import计数，不把缺扩展当硬件success |

R5新增UI不得重新引入同步PATH扫描/查询期进程扫描或常驻空闲轮询，最终再跑该矩阵。不能用汇总的事件数n40冒计划run n10；所有时间/count/gauge单位保留。真实硬件/Wayland和安全生命周期门与性能数据门分别判，任何之一未过都不构造综合PASS。

## 7. R2/R3 最终需求追踪、关键链路与GUI

### 7.1 D1–D17与源码语义追踪（V00，PENDING，依赖H04）

协调者建立最终树逐项“入口→真实行为→测试/场景→证据”的映射；只补缺口，不重做工作流。下表是冻结产品契约，不是新的产品审批。

| 决策 | 契约与入口 | 剩余对应 |
|---|---|---|
| D1 / D2 | 仅已分屏非活动pane WGL混RGB×目标alpha变暗，窗口整体失焦不变暗；透明/材质活动tab与terminal同色：`wgl.zig::present`、Backdrop/TabBar | V3/V6 |
| D3 / D4 / D5 | accent依次cursor/palette4/12并校验，Mocha蓝；idle只标题、默认标题视空、“ · ”；tab close中性，window close红：`src/gx/ui_color.zig`、`chrome/TabBar.zig::labelText` | V6、P2、R6用户文档 |
| D6 | Fluent83/167/250 ms、后台DwmFlush合并tick、popup LWA淡入，系统动画关闭/远程停动画；caption150/100已接 | V6、R5-10只popup实验defaultoff |
| D7 | 一期initials已在U+4E00–9FFF，不是旧设计GB2312子集；全音节R5仍缺，保留旧首字母 | R5-07 |
| D8 / D9 / D10 | 两端六设置分区，GTK宽900+主题子页；英文underline/中文键盘“(T)”访问键；历史哈希/geometry进状态目录不改config | V6/V7、R5-11、R6 |
| D11 / D12 / D13 | 可滚内容用户离底变化/右缘才揭条、输出裁剪不误揭；正常退出交核心，快速异常非模态Notice；恢复默认删overlay键 | V5/V6/V7；旧CHANGELOG模态描述需R6纠正 |
| D14 | GTK进程关闭确认/诊断去重/DMABUF锁存、GX4单帧vsync、中文粗体、blink省电核心已合；其余上游改动收益门 | 不重做源码；C1/C7/V7、最终registry |
| D15 / D16 / D17 | mandatory默认font/Mocha色序v2/mousehide/F3已合，conditional见C2；GTK gx-chrome精确选择＋dialogs/popovers命名色有意整窗着色；Win toggle_tab_overview是真tabs switcher | V6/V7、C2，不能改回审计附录的冲突备选 |

#### V00 原R2/R3叶需求矩阵

“原范围”是原计划 `C:/Users/guoxi/.kimi-code/sessions/wd_gx_ghostty_18c55036085c/session_d30cb445-3368-41e5-8baf-4ec00a95669d/agents/main/plans/medusa-banshee-stargirl.md` **计划文本**242–476的范围，不是源码行号。以下15个Windows owned拆分（Chrome→Tabs/Caption、Dialogs→Dialogs/Keybinds、Find→Find/Scrollbar）＋5个GTK流覆盖原关键叶；不重做已集成源。每行“.01”等补全为`<工作流>.01`稳定leafID，新对话逐leaf记录最终source/tree、生产入口、unit/native/真实case、raw/读图、状态和缺证，不能把整行“大都已实现”当验收。当前源码状态见第2节；**最终叶证据默认PENDING**，同树且合同不变的历史证据可标范围，不冒最终全绿。

`W`=`src/apprt/win32/`，`G`=`src/apprt/gtk/gx/`，`K`=`src/apprt/gtk/class/`；表中模块均相对这些完整前缀，跨域路径写全。类型：U=纯/运行期逻辑测试，N=真实native调用/资源，G=真实GUI/输入与已读screen，P=原性能门，X=CLI/生成/registry外部合同；N/U不代G。

| 工作流 / 原范围 | leafID及关键行为（自包含） | 实际owned模块/入口 | 验收类型与仍需绑定的缺证 |
|---|---|---|---|
| R2-接口 / 244–253 | .01 Surface定义尺寸frame握手、Render调用/Window收首帧；.02 Window写dim原子、Render读；.03 App写TabSlot progress、Chrome读；.04 Popup owner-lock与Chrome消费；.05系统/AllTabs菜单；.06 App统一profiles cache、Notice/Toast、两端settings_map | W `Surface.zig::signalFrameDrawn`、`Window.zig`、`App.zig`、`ui/Popup.zig`；`src/renderer/opengl/wgl.zig::present`、`src/gx/settings_map.zig` | U/N＋跨模块G；V3/V6/P4/P7，不只各自编译可用 |
| R2-App / 255–275 | .01 wakeup合并/requestQuit再唤醒；.02 Config.changed仅重做相关shell/keybind/conflict/appmode、缓存共用；.03首tab前系统明暗/多窗广播去重/reload按target/DSR996+2031；.04诊断Notice打开配置/重载/忽略、成功2s、异常退出/readonly/leader/复制Toast均post后GUI且守app-notifications；.05 msg_hwnd热键失败入冲突表；.06每terminal进度聚合error>paused>normal>indeterminate、15s过期/Explorer重放/tab进度；.07品牌/托盘图标/退出删除、audio/title/border、command_finished守bell-features；.08 OSC8 http(s)放行/file+UNC确认/可执行与search-ms拒绝、ShellExecute worker；.09先hide→托盘→窗口→msg_hwnd退出，SW_SHOWNA/隐藏与Quick呈现；.10无关联openas/notepad、鼠标只客户区、继承字号/new_window上下文；.11异步WGL能力settle失败/配置回调 | W `App.zig::applyConfig/syncColorScheme/ringBell/performAction`、`shortcut_conflicts.zig`；`src/gx/profiles.zig`、`url_policy.zig` | U/N/G/X/P；V1/V2/V6、P1/P2/P4，真实任务栏/托盘/通知/明暗DSR和默认反馈需leaf证据 |
| R2-Window / 277–298 | .01顶层setting/syscolor/theme广播；.02 show/lock/power/virtual-desktop可见性停render；.03 split布局/画线/命中同geometry、gap/tile、单pane跳过、配置divider/hover2–3DIP/min夹取/drag live-resize/活动格提示/dim/zoom；.04半区rect创建；.05批量模型摘下+hide一次布局/并行IOstop/真DestroyWindow/共享确认snapshot；.06 CH共享appmode、hidden跳过、标题300ms HQ复判；.07首帧post/300ms FF、last_grid/显示250ms后提示；.08 move只定位active popup不重画；.09 hidden DPI延后/不双layout/移窗重设；.10 fullscreen/max/displaychange顺序；.11 geometry恢复never/MonitorFromRect/错开/最小尺寸；.12标题滚轮/minTrack；.13真实move_tab非swap及split移新tab/window | W `Window.zig::moveTabToNewWindow`、`split_layout.zig`、`chrome/caption_layout.zig`；`src/gx/window_state.zig` | U/N/G/P；NVIDIA/Mesa销毁、真实可见性/多屏/资源/resize/移窗V6，P2/P3/P7 |
| R2-Surface / 300–315 | .01缓存pointer/同坐标skip/TME_LEAVE送(-1,-1)/IBEAM/完整cursor形状/隐藏不改shape；.02 Ctrl±120字号+开关、pinch、focus-follows-mouse；.03堆IME长串/QUERYCHARPOSITION/整段候选exclude；.04格式listing/GlobalSize/孤立代理/HTML、post确认；.05 never不建/system回滚才建/首网格扣scrollbar；.06 ResetEvent先resize、同size不等不wake、尺寸匹配frame/highres deadline、live WM_PAINT不多wake；.07 reparent重建popups、每surface擦底色、Kitty dirty+重试上限；.08 deadkey预编辑/textflag复位/OEM102；.09 Quick环境标记 | W `Surface.zig::readClipboard/confirmClipboard/onReparented/signalFrameDrawn/awaitResizeFrames`、`App.zig::surfaceWndProc` | U/N/G/PTY response；V1/V3/V5/V6和P7，真实IME/pinch/TDR及reparent不能日志代绿 |
| R2-Render / 317–322 | .01 blit后dim只混RGB×target alpha、reset重建；.02 GUI发布客户size、renderer无HWND API、同size不clear/edgeFills补边；.03 Windows1帧/不export texture/vsync传递/RF关GL notification/depth-stencil0优先；.04探测期临时llvmpipe/LP_NUM_THREADS并恢复、记录实际vendor/renderer/software；.05 Device.init线程+wait、无驱动MessageBox移apprt本地化 | `src/renderer/opengl/wgl.zig::present/Device`、`src/renderer/OpenGL.zig`、`opengl/Target.zig` GX4块；W App | U/N/G/X/P；V3/V6、软件/硬件可见呈现/失败退路，P1/P7/P8 |
| R2-Tabs / 324–353（Chrome拆分） | .01活动保底宽/常显close、非active hover才占位；.02关闭freeze宽直到mouse leave；.03溢出32×24按钮/50DIP滚/active入视野/两端fade；.04 max/fullscreen hit_top0、close整行×28命中；.05 D4 label/WSL去重/程序次色；.06 progress error红/bell/unread/zoom分开、hidden基线/盾牌一次；.07活动tab同terminal alpha/acrylic strip衬底/字色；.08 10DIP grab-offset跟手sort/anim/Esc、Popup改名失焦提交/Esc/EDIT退路；.09 middle down-up配对/double close/tooltip系统delay和相邻1/5+快捷键；.10 inactive text、D5中性色/pressed更淡/layout+path/text缓存/标题不变不invalidate | W `chrome/TabBar.zig::labelText`、`tab_layout.zig`、`Backdrop.zig`、Window TabSlot | U/N/G/P；V3/V6、真正溢出/关闭/拖动/状态位/低alpha；P2/P3/P4 |
| R2-Caption / 324–353（Chrome拆分） | .01无框材质不extend DWM/active边色变化且Applied去重；.02 caption tooltip Min/Max/Restore、hover==pressed/WM_SIZE重算/150–100淡出；.03 keep_owner_active计数处理NCACTIVATE、外部失活不伪active；.04自绘system menu；.05缓存DC/DIB、rcPaint不相交skip/按钮局部失效、layout/text/geometry cache；.06 nativeButtons启动一次/☰未截中心、pure caption layout/D2D失败native frame；.07 D5与pressed较浅 | W `chrome/TitleBar.zig`、`Backdrop.zig`、`caption_layout.zig`、`alpha.zig`、`ui/d2d.zig` | U/N/G/P；4C/4D已重号不redo；V3/V6、Win10/material/native/reset/owner生命周期，P4 |
| R2-Palette / 355–368 | .01命令/settings/theme/profiles cache按config+lang/目录mtime失效、首次非空才expand主题；.02共享fuzzy+initials、prefix/exact、跨组码点长/组内稳定、IME实时、零结果swap；.03命中runs/英文alias第二行；.04 selected底+3DIP条、hover/pressed/键滚后hover、空查询不列当前tab、profile exe参数/详情/swatch/零结果；.05 new-tab/theme子页、空Backspace、预览仅theme页；.06 CtrlEnter新窗/ShiftEnter主题保持/ShiftDel删历史、MRU tabs switcher；.07 hash历史/清除/输入→选择；.08输入400ms/导航150ms防抖、无display键skip/键帽cache | W `ui/Palette.zig`、`ui/trigger.zig`、旧fuzzy shim；`src/gx/fuzzy.zig`、`palette_history.zig` | U/G/private state/P；实际子页/次级键/MRU/英文高亮/IME，P4/P6；R5全拼是另流 |
| R2-Settings / 370–386 | .01Win支持bell/右键5值单选/reset删键+覆盖来源；.02失败草稿保留/退避/译原因、提交错误不被preview盖/重载回读；.03 D2D失败open config、Window.scale；.04 opacity auto/100/90/80/70、cursor/blink/padding/focusmouse/ctrlzoom、font sample；.05同target down-up/键盘focus-ring/按住step/direct number；.06 Esc先清/分组focus/font键入/PgUpDown；.07 wheel余数+system行数；.08搜索/reset UI/backend/material原因/provenance；.09 640DIP换行/direct前缀/路径中省与分隔符/重复reset和空带/scrim/max圆角；.10 Layers preview防抖、后台font枚举+Loading/WM_FONTCHANGE缓存、本地化alias；.11theme缓存绘后prefetch/herdr状态变才invalidate/footer+button测量cache | W `ui/Settings.zig`、`ui/settings/*`；`src/gx/settings_map.zig`、`config_layers.zig` | U/G/private overlay/X/P；六页/失败保存/CLI与restore、真实D2D退路，V6/P4/P6 |
| R2-Menu / 388–397 | .01父hot回入口/aim triangle/访问键/ImmGetVirtualKey/打开前held-repeat丢弃；.02 anchor_rect+align/placeRoot、☰右对齐/键盘同锚/flip/长menu滚/像素snap/terminal owner_scale；.03run内按层复用/layout cache/Popup首帧替40ms cloak/按需等替50Hz/App cache（第6阶段批准主菜单根按owner跨run隐藏复用，关闭不销毁；作废重建及100次资源门另验）；.04 D2D/读屏native TrackPopupMenuEx；.05 system+AllTabs接口、profile Kind图标/12号次色/间距24、hover无条/light向白/Win10边；.06 context split移tab/window/复制粘贴 | W `ui/Menu.zig`、`ui/MenuPopup.zig`、`ui/Popup.zig` | U/N/G/P；真实父子menu/访问键/scroll/退路/动作，P4一帧仍历史FAIL |
| R2-Dialogs / 399–408（拆分） | .01 previewLines末换行↵/危险码点U+XXXX/长行折/总行字符、empty read≠empty write、fallback净化、OSC52 remember；.02 default_button强调、link常underline/external icon/hand、about反馈+backend；.03关闭后果/按tab列process/去.exe；.04 owner scale、D2D/读屏TaskDialog退路 | W `ui/Dialogs.zig::confirmClipboardAccess`；Surface confirm、`src/gx/confirm.zig` | U/N/G/PTY；V1真实read先取owned文本再ask、remember/empty/cancel、分组/native退路 |
| R2-Keybinds / 402–408（拆分） | .01 gx.shortcuts有序分类+key精确/词前缀/类内score；.02 action次色、冲突点名/仅icon警示/原因顶部一次；.03 AltK真实录制过滤、row选择Enter执行；.04 CtrlHomeEnd才列表/可拖条/键滚重算hover；.05宽度与keycap cache；.06 ownerScale/读屏或D2D TaskDialog | W `ui/Keybinds.zig`、`shortcut_conflicts.zig`；`src/gx/shortcuts.zig` | U/N/G/P；ToolCapture/ShortcutTitles祖先不redo，录制/执行/长列表退路/owner锁，P5 |
| R2-Find / 416–421（拆分） | .01宽clamp(terminal−margin,240,380)/计数实测；.02 no-results caution+描边/只有focus caret/D2D失败可见提示；.03 Tooltip/F3+ShiftF3 performable；.04 URL同侧同串skip/placement避指针/≤60%中省保host/leave延迟/ensurePopup；.05 resize 14半粗+Window last_grid | W `ui/SearchBar.zig`、`LinkPreview.zig`、`ResizeOverlay.zig`、Surface/Window | U/G/实际search/IME；V5/V6/小pane/reparent/250ms提示与P7 |
| R2-Scrollbar / 411–415（拆分） | .01 D11可滚且用户离底变化/右缘reveal、无内容不thumb；.02 wheel转terminal/capture lost终止/track跳转+hold翻页；.03 offset未变不发/DIB cache/PaintKey/纯move不画；.04共享anim/系统关闭动效终态 | W `Scrollbar.zig`、Surface mouse/visibility/reparent接线 | U/N/G/P；V5满回滚裁剪/实际用户来源、Quick owner/reparent，P3必须0重画 |
| R2-Quick / 423–433 | .01立即首tick/easeOut-in/反向连续/同position无SetWindowPos；.02滑出初始还外部focus、自popup GA_ROOTOWNER/ACTIVATEAPP不误hide；.03region裁工作区/无taskbar或相邻屏越界、动画hide附件/center短距圆角；.04目标DPI先取/动画中忽略/DIP与px文档；.05先size后tab/等首帧/CLIPCHILDREN；.06 hidden activeVisiblefalse/popups hide/render0；.07config/display relayout/程序尺寸无提示；.08 hidden present滑入、末tab滑出再销毁、new_tab拒或可见tabrow | W `QuickTerminal.zig`、Window/Surface/Popup | U/N/G/CPU；V6首帧/焦点/最后标签、真实屏幕轨迹/DPI，P1/P7 |
| R2-Font / 435–436 | .01 DirectWrite warmup消费上游App.create钩子；.02未分配/非字符不全族scan但保MapCharacters；.03 uucode general_category体积/正确性；.04预热独立收益去留 | `src/font/directwrite/discovery.zig::warmup`、`src/App.zig::create` | U/N/G/P；C6原A/B/C仅历史，current-only-warmup十对待验；100% Font/V6 |
| R3-Style / 440–447 | .01 toolbar gx-chrome限定/scrollbar3–8px；.02共享tokens/chrome、4.14命名色覆盖window/view/header/popover/dialog/card/accent/destructive、仅auto/ghostty；.03 runtime≥4.16变量选择器实测；.04单tab无pill/inset、8圆角、拖tab标题底、多split focus-within/remote/superuser；.05材质时header/popup半透明为原P3；.06 CSS hash去重/growing writer/溢出warn | G `style.zig`、`style.css`、`window.zig` toolbar；`src/gx/gtk_css.zig` | U/GTK4.14解析/G；V7 modern/Wayland/KDE材质及实际drag/scale，旧Xvfb无WM不代 |
| R3-Settings / 449–455 | .01虚拟ListView/StringList/Filter+SingleSelection无autoselect/factory/scrollTo/swatch/保存勾/restore/成对theme两行+current；.02FontDialog family仅等宽/保fallback+clear；.03 fuzzy拼音排序/stop-search先清后关/过滤后重选；.04 applyTexts语言热切/静默reload/Settings saved/失败草稿retry译原因/saved_theme成功后改；.05宽900+/六区header/theme全高子页/记页/Apply同搜索；.06共享options、GXdisabled Banner禁改、reset icon/整数font/bell-path提示/Shell无direct/无障碍名/open folder | G `settings_dialog.zig`；`src/apprt/gtk/ui/1.5/gx-settings-dialog.blp`、`src/gx/settings_map.zig` | U/overlay/G/真实fontdialog；V7 save/reset/CLI/语言唯一toast/主题preview，P4/P6 |
| R3-Window / 457–465 | .01 setup-menu原tab stable scope关闭/other/right/copy/move/pin；.02open config/accel/zoom-reset/fullscreen/find、≤12项与Win顺序；.03 profiles default/settings默认shell/Edit Profiles/settings_page；.04shortcuts Esc/Clamp/横排每row最多2组+N/shared order-mods/StatusPage/keytable/Page_Up名；.05 language same no-op/quietreload唯一toast/CJK fallback检查，缺CJK改英文提示安装仍需原产品确认；.06 Application profiles cache签名前不探测、Builder按lang cache、about反馈/backend | G `window.zig`、`menus.zig`、`shortcuts.zig`、`shortcuts_dialog.zig`、`launch.zig`、`language.zig`、`app.zig`、`about.zig`；`src/apprt/gtk/ui/1.5/gx/menus.blp` | U/X/G/xdg handler；V7/真实rightclick scope/default profile/全屏WM/语言与CJK；manager属R5-11，不redo已路由new_tab_menu |
| R3-AppMode / 467–470 | .01全app单GSource500ms→10s退避、title/key reset、hidden/suspended跳、herdr命中停/disabled无timer/共享快照；.02≥2tab每秒后台输出needs-attention/shared unread；.03 leader icon/tooltip＋remote/superuser类、progress overlay fraction/状态转indicator饼；.04 Dock进度仍原P3延期，不冒称已实现 | G `app_mode.zig`、`progress.zig`；`src/gx/unread.zig`、`leader.zig` | U/计数/G；V7多窗/hidden/disable/真实进度/状态、跨屏DPI，P2；原P3依scope实记 |
| R3-Upstream / 472–475 | .01关闭确认真实进程列表；.02诊断摘要去重、theme preview不反复抢焦点；.03 DMABUF导出失败锁存/单次warn | K `close_confirmation_dialog.zig`、`application.zig`；G `confirm.zig`；`src/renderer/OpenGL.zig` GX27–29 | U/G/X及hardware N；registry/roots闭集、V7真实确认/diagnostics/hardware export-import，P9 |

把每个leaf展开为最终case不是重新做37份审计；已接ToolCapture/ShortcutTitles、Caption4C/4D与晚接线保留。没有对应最终case/身份或图就标该leaf PENDING；若实际发现bug，只最小修复＋回归。原P3/需确认项保原口径，不从摘要升级成新默认或删用户范围。

### 7.2 实际剩余关键链任务

每项依赖V00＋fresh自有实例守门，涉及测试副作用先许可。完成证据须最终标准app身份、真实行为/raw或response、实际screen逐图读取和正常清理；现有源码/native证据只能缩小调查范围。

**V1当前生产授权顺序（不是新设计）**：`Surface.clipboardRequest → readClipboard`先读取系统剪贴板、复制为owned文本并`CloseClipboard`，再`core.completeClipboardRequestWithConfirmation`得到Unauthorized，投递`WM_APP+33`，随后`Surface.confirmClipboard`显示ask。因此deny/cancel不意味着OS零读取，**配置隔离不隔离clipboard**；执行前必须安全已知测试fixture或用户对测试读取明确许可，不能读取/备份未知用户内容来“保存恢复”。不能默改为“先确认后读”或新增deny零read必做门；用户将来若要求改变授权顺序，另立安全产品决策，不属于原计划当前必做。remember仍先answer当前请求，再更新后续split policy；modal返回按core id重查。

| ID / 状态 | 真源入口 | 必须完成的验收 |
|---|---|---|
| V1 / PENDING | `src/termio/Exec.zig`→PTY/parser/core→`src/apprt/win32/Surface.zig::readClipboard/confirmClipboard` | 默认`clipboard-read=ask`真实ConPTY→核心→确认UI→PTY真实BEL/ST回复；bundled NuGet1.24.261001001生产flags6 query12/12、system flags0 query0/12是运输proof，不是UI。安全已知测试Clipboard条件下allow/deny/cancel、empty read/write、split remember、Quick/reparent/关闭竞态；先answer**当前请求**再更新后续split policy，modal返回按core id重查，不按旧指针。不能read/save未知用户内容、用私有WM/CLI/raw probe冒全链PASS |
| V2 / PENDING | `src/apprt/win32/App.zig::ringBell/performAction`、`BellAudio.zig` | 实际BEL与command_finished配置链、bell-features/platform flags、gain0/.5/1及听觉；不改系统volume/设备。永久driver不返回的loan/header/worker/context最终回收另有实体证明。源码100 ms是kernel wait、mock墙钟assert<500 ms，不虚称严格每次<100 ms |
| V3 / PENDING | `chrome/alpha.zig`、TitleBar/Backdrop/TabBar、`ui/d2d.zig`与WGL/DWM | NVIDIA＋Mesa真实GPU/default framebuffer→Swap→DWM接缝，low alpha、透明/材质、正常/最大化、浅深/高对比、真实混合DPI；dirty EndDraw/recreate/failure后完整补画/资源计数。native DIB/shared-helper expected不是独立GPU alpha数学证据，不能先认risk为bug |
| V4 / PENDING | `src/gx/bell_border.zig`、`Surface.ringBellBorder`、WGL present | 可见Mesa Swap/DWM与NVIDIA，完整可采样192DPI四角/实际跨屏，ring/repeat/color/clear/hidden-tab/reparent、idle正常wake。历史W21五图仅部分PASS、模拟192底部不可采样仍PENDING；私有RGBA8 FBO几何expected共用covers也不代screen |
| V5 / PENDING | `src/Surface.zig`、`src/terminal/search/Thread.zig`的GX30、Win `Surface/Scrollbar` | 真F3/ShiftF3/Enter搜索跳转，viewport内外及同一行、用户actual mutation来源；满scrollback裁剪和持续输出不误reveals，right edge仍可唤出；保持opt-in仅Windows且CABI/40B/renderer scrollbar协议不扩 |
| V6 / PENDING | Win `App/Window/Surface/QuickTerminal/Popup` | 长IME真实上屏与`IMR_QUERYCHARPOSITION`/候选排除整段，Win10、真实96→144→192混合DPI、弹层/UI退路；Quick最后tab先滑出再销毁且隐藏render0、自家popup不误autohide、焦点立即进/还；首帧真实post揭幕/300 ms fallback、全窗16 ms deadline、尺寸提示显示250 ms后/last_grid去重；split移窗不换PTY，old owner关闭后search/scrollbar正常。GPU appreset只是应用context重建，真实TDR需另合法环境，不能代证 |
| V7 / PENDING | `src/apprt/gtk/gx/{style,settings_dialog,window,app_mode,launch}.zig`及class hooks | Ubuntu4.14/Adw1.5和modern≥4.16/Wayland真实整窗theme/语言/默认font/保存恢复/zoom开关/CLI/provenance/每split；native pinch/smooth，不拿合成wheel替pinch；CJK100%/96dpi真图、真实DPI/全屏WM/合成材质；hardware DMABUF成功export→GDK import另验，Xvfb只软件路径；xdg editor handler用合法实际关联，不擅改用户handler。历史WINDOW0guard失效不强点 |

### 7.3 全量GUI最终包（R6-5执行，当前PENDING）

**W01–W15是既有R0 regression，不是“启动等overview”的文件别名**，全部保留；启动、tab1/3/12/30、Settings六页/浅主题/语言热切换、Palette/Menu/Find/Dialogs、三材质、DPI/live resize/长IME/软件渲染/冲突Notice/超长标题还要按V00/V1–7另补实际最终case，不能因跑完W01–15声称全UI覆盖。

仓内入口根为候选 `test/gui/win32/`、`test/gui/gtk/`；以下是实际文件inventory导航。执行前逐文件Read其steps/expect并映射leaf证据，不只凭名称计PASS。

| Windows编号 | 根下实际TOML入口 | 覆盖分类 |
|---|---|---|
| W01 | `W01-title-override.toml` | 手动title override |
| W02–W03 | `W02-edit-keys-stay-in-search.toml`；`W03-search-highlight-clears.toml` | search编辑键留UI、end-search高亮清理 |
| W04–W05 | `W04-split-focus-and-nested-drag.toml`；`W05-palette-preview-gate.toml` | split焦点/嵌套drag、Palette预览门 |
| W06–W08 | `W06-ctrl-click-long-url.toml`；`W07-startup-failure-dialog.toml`；`W08-clipboard-paste.toml` | 长URL、启动失败反馈、clipboard paste（先安全fixture） |
| W09–W11 | `W09-wsl-focus-reports.toml`；`W10-wsl-horizontal-wheel.toml`；`W11-wsl-side-buttons.toml` | WSL focus报告/横wheel/side buttons |
| W12–W13 | `W12-capture-loss-release.toml`；`W13-quick-terminal-focus.toml` | capture丢失release、Quick focus |
| W14–W15 | `W14-opacity-kept.toml`；`W15-goto-and-move-tab.toml` | reload opacity保持、goto/真实move |
| W16–W17 | `W16-chrome-tour.toml`；`W17-simulated-dpi.toml` | chrome tour、模拟DPI（不代真实跨屏） |
| W18–W19 | `W18-many-tabs.toml`；`W19-chinese-ui.toml` | 多tab、中文UI overview |
| W20 | `W20-R2-Window-splits-dpi.toml` | R2-Window split/DPI |

| GTK编号 | 根下实际TOML入口 | 覆盖分类 |
|---|---|---|
| G01–G02 | `G01-startup-en.toml`；`G02-zh-main-menu.toml` | 英文启动、中文主menu |
| G03–G04 | `G03-settings-dialog.toml`；`G04-shortcuts-search.toml` | Settings dialog、shortcuts搜索 |
| G05–G06 | `G05-tabs-and-split.toml`；`G06-light-theme-palette.toml` | tab/split、浅主题Palette |
| G07–G09 | `G07-R3-Window-main-menu.toml`；`G08-R3-Window-profiles.toml`；`G09-R3-Window-tab-context.toml` | R3主menu/profiles/tab context |
| G10–G12 | `G10-R3-Window-shortcuts.toml`；`G11-R3-Window-shortcuts-empty.toml`；`G12-R3-Window-shortcuts-escape.toml` | R3shortcuts正常/empty/Esc |
| G13–G14 | `G13-R3-Window-settings-page.toml`；`G14-font-zoom.toml` | settings_page、font zoom |

**外部W21不是仓内注册case**：本轮已直接Read确认 `E:/gx_projects/gx_ghostty/.local/evidence/R23/BellBorder/W21-after-unlock.toml`（id W21，zero-padding/border-only、真实screen），输入BEL/hidden-tab、模拟context reset/192DPI和focus-clear；证据在 `.local/worktrees/R23-int/.local/integration/bell-border/gui-W21-01/W21/`，部分192角仍PENDING。独立Font旧证据的外部`W20-R2-Font-default.toml`/`W21-R2-Font-override.toml`在 `.local/evidence/R2/R2-Font/`，与仓内W20、BellBorder W21不是同一注册入口，不混case含义或ID。

未来case先fresh列实际仓内最高编号及外部入口，按当时注册/所有权取新号或明确外部路径命名空间；不覆盖现有用途、不把外部W21自动占成仓内case。GTK保留G01–G14并补现代/硬件/Wayland、关键链与R5实际场景，日志无`Theme parser error`/`css parsing failed`；Xvfb覆盖不冒真实桌面。

所有GUI输入先fresh own PID/birth/exe/foreground/点位；每次important transition再observe，guard失败停止、保留runner FAIL，不绕过/自动重复到“成功”。screen capture与原分辨率crop逐张读；PrintWindow可定位局部但不代DWM/DComp上屏、隐藏窗或锁屏证据。UI日志、单测、native API通过都不能计截图PASS；Xvfb不代Wayland、硬件、真实WM/IME；macOS无对应环境记PENDING，不虚称已验。

## 8. R5：共同接口先行，十一工作流全部保留

**全体状态：PENDING／未实施。** 已有调查设计，不是代码或验收。标“NEW”的路径/接口尚须实施，不能当现有API：特别是R5-11的`Overlay.getAll`必须等R5-00新增能力完成后才消费，current不存在。各流依赖R5-00、自己的定向测试及最终V/P门；H04/V00后可推进，不被C1 quiet硬锁。跨host活PTY、提权drop和restore默认policy保留待冻结的合法设计/产品默认，**不把单host路由或安全拒绝冒完整功能、不缩用户scope**；设计提案不是默认批准，不因L级/环境阻塞删流。

### R5-00 共同接口与安全fixture（PENDING；依赖H04/V00；协调owner）

冻结四组接口后才放并行coder：

1. **稳定引用/转移**：Window/Tab/core Surface ID＋generation/host epoch；model移动不复制指针到IPC，modal/COM返回重查；launch origin按稳定profile ID传递。真正move的PID/Surface/PTY/scrollback保持；空目标容器不得先起再kill placeholder shell。
2. **COM/通知/IPC**：单一GUI apartment所有者、成功S_OK/S_FALSE配对、失败状态；UIA/OLE/taskbar/JumpList一致消费。后台仅持owned消息，GUI执行与ACK分开，队列有界；WinRT MTA不把GUI改成MTA。Shell identity/AUMID/activator与安装真源一份，不先写真实系统注册。
3. **Overlay/GTK生命周期**：真正真源 `src/gx/gui_settings.zig::Overlay` 已有get/setAll/delete/save、**没有getAll**，不是settings_overlay。NEW getAll按文件顺序含空值且明确内存寿命；latest-overlay上重放编辑避免丢外部改动。GTK launch Application cache、commit静默reload/回读；class window attach/detach/尺寸/焦点/quit钩子协调给session/split/state共用。
4. **安全fixture**：核当前harness的config/state/APPDATA隔离；R5旧设计指出state隔离缺口，d6标准harness后来已改变，须读最终实现，不照旧报告重写。session多轮restart同private state且更新birth；多launcher/可信host、bounded UIA MTA、实际OLE source、popup reset hooks皆用现有测试框架扩展，不放宽ownPID保护。安装/toast/JumpList验证环境变量不足，需VM/测试账户和副作用许可。

完成证据：接口设计/ownership表、实际签名与最小contract tests、消息/计时器无重号（当前Window4A/4B、Caption4C/4D已分开）、source闭集/roots、隔离负例。新配置默认/CLI语义、session restore策略、跨host范围、提权broker必须先冻结明确决定，提案不得自动视为产品授权。

### R5-01 标签拖出／跨窗合并

- **依赖/owner**：R5-00；跨host部分依赖R5-06。NEW `src/apprt/win32/tab_transfer.zig`、`TabTransfer.zig`；热接点 `chrome/TabBar.zig::Drag/onMouseMove/drop`、`Window.zig::moveTabToNewWindow`、`Surface.zig::onReparented`。现有只有真实move-to-new-window，没有`moveTabToWindow`。
- **实现**：纵向**>15 DIP**detach（等于15不触发），横向仍10 DIP；清拖动状态→释放capture→post→`SC_MOVE|2`系统循环，返回重查引用。NEW moveTabToWindow完整移树/override/zoom/活动pane、子HWND/DPI与弹层，事务失败保留owner、不stop/unref shell；单tab可移动本窗，合并后只关空容器。落点用当前几何/scroll/DPI，排除按钮/QT/隐藏栏/外部遮挡，Esc/捕获丢失/目标关闭处理。
- **验收/证据**：15边界、96/120/144/192及真实混合DPI、系统Snap；记录运行中PID+birth、Surface ID、HWND、scrollback计数前后不变；迁移后关闭源窗继续操作split/search/scrollbar。全部reparent/回滚失败、满64tab、modal竞争与退出需测。
- **跨host必留门**：两个launcher路由同一个host只证明单实例/同进程转移，不证明两个既存活PTY host间迁移。单host/路由可作合法架构设计，但不能自行缩scope或称跨host全完成；原门未满足就保PENDING，必须提供实际ownership/remoting路径并验证，或由用户另行明确变更范围（本plan不作变更）。不能newShell+kill源或复制输出假transfer。

### R5-02 两端安全会话恢复

- **依赖/owner**：R5-00，GTK生命周期与R5-11协调；NEW `src/gx/session.zig`、Win `Session.zig`、GTK `gx/session.zig`；复用 `src/gx/window_state.zig`、`state_file.zig`、`profiles.zig::List.find`，不拿Layers的`-e`重放当session。
- **实现**：有界versioned schema存windows/tabs/split ratio/活动叶/zoom/手动override/point字号/稳定profileID、安全typed cwd和geometry，不存任意command/argv、env、dynamic title、PTY输入或scrollback。parse/validate所有索引/连通/无环/ratio/限长后才建真实叶；不可还原旧PID。恢复只能解析当前可信profile并按冻结策略确认/拒绝custom/ad-hoc，失效profile/cwd明确反馈；不拼`cd`、不访问UNC/device/不明远程域。
- **启动/存储**：首个普通启动、CLI/-e/initial-window/never优先级明确；restore种子显式消除`initial-command`再执行，避免首次core init重跑命令。private atomic store/同步/单writer租约/generation，损坏/未来版本/忙/I/O分开且保旧档。建议默认off只是设计提案，**默认policy需先冻结**。
- **关闭语义/验收**：Quit先快照再冻结，明确close删对应对象、最后普通窗写empty；取消不删，Quick完全排除，失败不写半恢复。2普通窗、多tab、嵌套非0.5树/zoom/后台active/中文emoji标题/字号/cwd完整restart往返；缺profile、注入、超限、双实例/写失败、关闭不复活、CLI不被替换。GTK逻辑尺寸/最大化，不承诺Wayland XY。完成证据含真实多轮生产路径、private file审隐私、PIDbirth变化与逐图。

### R5-03 UIA与无障碍深化

- **依赖/owner**：R5-00；NEW `src/apprt/win32/ui/uia.zig`及bounded probe（可用NEW `scripts/gx_win_uia.py`）。Popup/Menu/Palette/Dialogs/Settings与tab/caption单写者适配。
- **实现**：Simple/Fragment/Root＋实际Invoke/SelectionItem/Value/Toggle/ExpandCollapse，菜单、面板Edit+List、对话框、设置、tab/caption的真实语义；Notification的popup root保留**Window pattern**，`UiaRaiseNotificationEvent`缺导出退路。保留低32位WM_GETOBJECT objectId匹配`OBJID_CLIENT`时**返回0**的规避（不改该常量），仅`UiaRootObjectId`提供provider；old Win10运行期系统DLL能力探测。
- **生命周期**：GUI STA初始化配对，provider只读owned已提交Snapshot、不读arena/scratch/renderer锁、不SetFocus或同步modal；Invoke/Select/Value/post后GUI按epoch/generation重查。COM lifetime独立于UI owner，hide/detach/换submenu/销毁后旧节点inert、bounded unavailable；disconnect避同步SendMessage重入，App终止前释放，DWM native按钮不重复曝光。
- **验收/证据**：真实外部无HWND **MTA IUIAutomation** client限PID/HWND/深度/数量/超时，查询与事件注册/移除同线程；实际收notification不只HRESULT。连续查询＋兄弟pane focus/IME/tabclose/menu/modal无focus死锁；旧provider不能操作替补节点。读屏detect与native HMENU/TaskDialog fallback已部分实现，补真实读屏及强制环境两种不同证据；不再造一套原生Palette/Settings。超时是FAIL，不全桌面descendants扫描。

### R5-04 OLE拖放与权限兼容

- **依赖/owner**：R5-00；跨权限安全broker依赖R5-06。NEW `src/apprt/win32/ole_drop.zig`、`drop_data.zig`、`ui/DropFeedback.zig`，复用Surface的protected paste而非keyCallback/textCallback unsafe路径。
- **实现**：真实`IDropTarget/IDropTargetHelper`、OLE apartment、refcount/注册撤销/reparent/销毁；hover仅反馈不聚焦/扫描/读clipboard。text/files/typed fileURI bounded读取，COPY/NONE、无自动Enter，HDROP优先、不猜普通文本是路径；按shell引用/URI单次解码，cmd `%`/`!`风险需真验。WM_DROPFILES始终DragFinish，OLE medium ReleaseStgMedium，clipboard借handle不释放；post owned payload→GUI按ID重查→焦点/保护确认。
- **权限门**：中→中、高→高、中→高、高→中四向分别真实测试。禁止ChangeWindowMessageFilter/UAC/uiAccess放行；中→高拒绝只是安全证据，不是管理员兼容完成。若要求普通Explorer到提权PTY，必须合法中完整性接收broker＋认证限长/新鲜性＋高端**显式预览确认**，或另冻结合法架构；不能未确认地注入管理员输入。
- **验收/证据**：真实Explorer/外部文本和受控IDataObject source，单多文件/空格CJKemoji/恶意路径/URI、CRLF/多行保护/bracketed/9001/Kitty、cancel/hover/目标销毁/reparent旧窗关闭/DPI、Helper/D2D退路；源文件不移动、clipboard不读写、PTY不回车。普通鼠标drag或直接调Drop不是实际OLE证明。

### R5-05 WinRT系统toast

- **依赖/owner**：R5-00＋R5-06激活路由，与R5-08共shellIdentity。NEW `src/apprt/win32/shell/{Identity,WinRTToast,ToastActivation}.zig`与共享identity真源提案；包装单写者 `dist/windows/gx/ghostty-gx.iss`、`scripts/gx_windows_package.py`。
- **实现**：同一AUMID/activator CLSID/安装快捷方式身份，AppId升级身份不误当AUMID；installer注册/卸载只owned项。portable路径隔离identity、**不自动注册**。MTA WinRT队列复制XML安全文本、两个通知不同target/session/token，App通知与command_finished两入口各守自己的配置；GUI回调重查Surface。warm Activated和COM cold activation都要真实路由，不先起多余shell、不执行通知正文/旧命令。
- **用户与退路**：用户禁通知或DND不能balloon绕过；技术能力/身份不可用才旧backend退路，queued/Show HRESULT≠visible。通知中心banner超时不是目标失效；进程关闭/target关闭/多实例/Quick/hidden/最小化分开处理。
- **验收/证据**：mock/native ABI无系统写入先验，真实安装/升级/外部通知/冷激活必须在获许可VM/测试账户，Win10/Win11、中英文、多目标、DND/disabled、portable两目录不串台。`ui/Toast.zig`只是应用内toast，不能替系统通知完成。

### R5-06 单实例IPC、toggle与真实路由

- **依赖/owner**：R5-00；NEW `src/gx/ipc/{protocol,policy,cli}.zig`、`src/apprt/win32/ipc/{Instance,Security,Client,Server}.zig`。实际缺口 `App.zig::performIpc`恒false、`src/cli/toggle_quick_terminal.zig::run`未parse class/help；公共`src/apprt/ipc.zig`不是wire协议。
- **实现**：versioned bounded codec、namedpipe本机认证、SID/logon/session/elevation/configroot/build/class/install隔离，双向核实际连接PID+birth，reject远程/非法版本/length/trailing data；去重request ID/host epoch、toggle不双执行。选主ready/crash/并发启动与shutdown取消有界；worker仅字节/owned队列，**GUI操作成功后才ACK**；前台授权仅authenticated host，不ASFW_ANY。secondary在建Surface/热键前转发并正常退出。
- **CLI/GTK**：真实实现`+toggle-quick-terminal`参数、帮助、错误与现host焦点，按键/IPC共路由；GTK保留GApplication/session D-Bus/class语义，不另造Linuxpipe，D-Bus传输exit0不替实际quick能力。自定义CLI/-e/detect与single-instance默认policy先冻结，不丢覆盖参数。
- **验收/证据**：多launcher真唯一host、一份热键；不同root/build/elevation不串台、冒名endpoint/重复toggle/ready前崩溃/退出请求；GUI创建失败无success ACK。transfer仅opaque refs/短票据，无terminal正文/clipboard/env。跨既存活host能力见R5-01，必须单独完成或明确阻断，不能凭IPC文本协议称已迁移活PTY。

### R5-07 全拼音节匹配

- **依赖/owner**：R5-00；`src/gx/fuzzy.zig::prepare/score/positions`、`pinyin.zig`、`scripts/gx_pinyin.py::SOURCE_FILES`；NEW音节表/manifest/钉版输入目录（提案 `vendor/gx-pinyin-data/0.15.0/`）。
- **数据**：当前0.15.0三个钉输入`pinyin.txt`、`kTGHZ2013.txt`、`kXHC1983.txt`摘要以SOURCE_FILES为真源；primary＋现代备用不加古音，保留**U+4E00–9FFF**和旧initials。MIT＋Unicode License V3两许可随包；正常生成/check离线完整再生成，不再把无source摘要check冒可复现。取得原输入/联网更新需另许可，revision/hash不编造。
- **算法**：三API/现有首字母/多词AND/全角/原literal prefix高亮与分数尺度保持；literal优先，变长DP全音节/zh-ch-sh/末尾输入prefix/拼音apostrophe，ü canonical v不能并u，多音不组合爆炸/不存每candidate罗马字。移除全拼错误n<m/initial subsequence预拒，仅可见行回溯，score/positions同路径；无新增后台索引或GTK上游面板补丁。
- **验收/证据**：zhongwen/zhw→中文，chongqing→重庆，yinyue/yinle→音乐，拒内部截取/同字混读；旧首字母原样、emoji UTF16高亮/ASCII排序、64query/192text/8terms/零分配边界。fresh checkout无缓存离线再生成及包许可/源码包既有体积门；Windows动态tab/字体、GTK GX主题/速查实际筛选读图，P4性能不放宽。

### R5-08 JumpList

- **依赖/owner**：R5-00＋R5-05共享identity＋R5-06启动路由；NEW `src/apprt/win32/shell/JumpList.zig`、`src/gx/windows_argv.zig`。
- **实现**：从`App.zig::cachedLaunchProfiles`owned snapshot取stable profile ID/标题/图标，exe绝对路径＋安全**Windows argv**，不是shell path_quote；不带cwd/rawcommand/历史/凭据，不重扫PATH。需要真实按profileID启动入口，不用Windows当前unsupported的公共new-*冒可用。删除/修改profile后明确错误/当前可信解析，不执行陈旧命令或显示名猜测。
- **事务/验收**：正确AUMID、ShellLink属性、BeginList/AddUserTasks/Commit失败Abort保旧；profile/语言/身份变化才刷新，portable不auto-register且有明确合法fallback。纯编码/内存COM先验；实际开始菜单/JumpList写入需获许可测试账户，Win10/11中英、空格CJK引号/尾反斜杠、removed profile、进程不运行、多目录不串台真点及screen；系统列表不是private LOCALAPPDATA变量能隔离的。

### R5-09 Fluent UI System Icons路径生成

- **依赖/owner**：R5-00；NEW `src/gx/fluent/{inputs,model.zig,paths.zig}`、`scripts/gx_fluent_icons.py`及既有框架中的测试、Win `ui/fluent_icons.zig`；d2d热接口协调。
- **实现**：选定官方MIT SVG，锁完整revision、路径/变体/尺寸、输入/LICENSE hash；无现成输入时不能编造或本轮下载。离线生成/check固定M/L/C/Z，multi-path/multi-figure/nonzero-evenodd洞、相对/曲线/弧规范化和精度确定，unsupported明确拒绝；D2D SetFillMode、多figure、共享factory geometry缓存、transform保存/恢复与scale正确。
- **验收/证据**：跨Win/Linux字节再生成、篡改/缺输入拒绝、洞/尺度/缓存/释放；真实96/120/144/192暗亮/高对比/禁用/选择图。默认system glyph保留，只补selected语义，不全局大改，不再分发或抽取Segoe字体；包内MIT原文/THIRD-PARTY和闭集同步，`gx_icon.py`品牌ICO不误当本生成器。

### R5-10 Popup DirectComposition实验

- **依赖/owner**：R5-00；NEW `src/apprt/win32/ui/dcomp.zig`，`Popup.zig`与d2d单写者。环境变量名字需冻结，建议`GHOSTTY_GX_POPUP_DCOMP`，**默认off**、不写gx配置。
- **实现**：仅popup runtime系统DLL能力/Win10 fallback；BGRA D3D11 hardware→WARP→legacy，共享D2D factory/device。NEW borrowed Canvas接口不重复调用DComp BeginDraw返回context的Begin/EndDraw，应用每帧offset、Surface.EndDraw后Commit，设备/画刷域代际正确；不动主WGL/标题DIB/scrollbar。
- **状态/验收**：成功EndDraw+Commit、当前size/DPI/generation firstframe latch才uncloak；recreate/reset/Commit任phase failure先legacy成功补画、不空窗/无限retry；DPI/IME、owner-latch平衡、modal/隐藏/NCDESTROY/late callback、菜单legacy rastercache不夹DComp HWND target。专用**真实popup reset/failure**逐phase screenshot、Win10缺API/NVIDIA/WARP/Mesa终端路径区分；terminal `gpu_reset`或caption D2D_FAILURE不代popup证据。默认off回归、开启实验P4十对与Fluent组合资源域都验，实验通过不授权默认开启。

### R5-11 GTK交互深化（四子任务均必做）

- **依赖/owner**：R5-00；keybind/profile UI可独占新模块并行，class window/split/session尺寸生命周期同一owner；保持4.14/Adw1.5。
- **11a 快捷键编辑**：NEW `src/gx/keybind_edit.zig`、GTK `gx/shortcut_editor.zig`。完整table＋Trigger序列＋flags＋action chain＋来源模型；`src/gx/shortcuts.zig`速查Row丢flags/ignore/unbind/catch_all，**不可反序列化回配置**。真实录制/高级语法原parser，普通同key/leader-prefix冲突确认、下层改绑旧trigger unbind，恢复只删对应overlay编辑；保留clear/table/chain邻接/未知repeatable，失败草稿保留、CLI readonly、GXdisabled不写。不做系统热键冲突探测。
- **11b profile管理**：NEW `src/gx/launch_profile_edit.zig`、GTK `gx/launch_profiles_dialog.zig`；在R5-00实施NEW `src/gx/gui_settings.zig::Overlay.getAll`后，才用它＋latest重放CRUD（current没有getAll），Application cached profiles给menu/Shell/管理页共同消费。探测/用户/include/CLI项只读，仅overlay自有可改，空值清表/Name=删除/删覆盖下层重新出现都回读；默认shell仍command/恢复删键，不自动GX Zsh。改名stable `custom:Name`引用/默认后果明确，newline/NUL拒绝，外部编辑不丢行。
- **11c new_tab_menu＋geometry**：`gx/app.zig::performGxAction → gx/window.zig::popupNewTabMenu`已经真实SplitButton/fallback路由，**不重做**；只把Edit Launch Profiles入口接真实manager，并验native/tabs/fullscreen/herdr隐藏chrome/fallback实际启动。NEW GTK `gx/window_state.zig`接真实new/surfaceInit/dispose/quit lifecycle，normal逻辑尺寸/各轴CLI优先/max/fullscreen/tiled不污染、never、最后普通窗/Quick排除、取消关闭不写；Wayland无XY，不把仅创建时setDefaultSize当恢复完成。
- **11d split真实迁移**：当前两个move_split动作unknown/false，必须NEW `gx/split_transfer.zig`搬**已有Surface**到空Tab/Window，无默认shell placeholder，不close/reinit；持强引用/预分配树、源与目标focus/zoom/listeners正确。核 `class/window.zig` SplitTree.changed attach/detach旧callback、`class/split_tree.zig`last_focused setter，不能让旧Window/迁出叶迟到focus；boxed-copy/OOM能力按实际API处理，不用纯模型测试冒原子回滚。
- **验收/证据**：11a真实按键结果＋中英暗亮/保存失败/table/chain/flags/取消/恢复/CLI；11b CRUD/default/只读项/重开跨窗同步且旧shell不重启；11c resize→close→restart/max/never/两轴/Quick/Wayland真实WM；11d PIDbirth/SurfaceID/PTY/scrollback不变，嵌套/zoom连续迁移后关闭旧窗继续split/title。Ubuntu24.04与modern GTK构建/单测/控件图，真实X11/Wayland/scale/IME另验，Xvfb不代这些环境。

R5各流完成证据还须各自新模块tests显式进入 `src/gx/main.zig::test`、`src/apprt/win32.zig::test`或`src/apprt/gtk/gx/main.zig::test`，roots/fork/GTK contract检测、最小Windows/POSIX/GTK相关runtime与实际UI，不靠编译惰性。共享PO按msgid合并后生成，公共接口变化纳入KB；任何架构未解决门保留未完成，不把设计报告记功能PASS。

## 9. R6：真源、生成物、总门、最终集成与清理

| ID / 当前状态 | 依赖 / owner | 具体任务、入口及验收／完成证据 |
|---|---|---|
| R6-1 / PENDING | C/V/P决策＋R5源冻结 / docs单写者 | 更新`CHANGELOG.md` **0.0.3(TBD)** Added/Changed/Fixed用户可见项（accent/title/scrollbar/default/px DIP语义/新增功能），不擅bump0.1，不把产品build1.3.2当fork版本；`docs/GX_FEATURES.md`对照/未实现、`ARCHITECTURE.md`、`FORK_PATCHES.md`、`TESTING.md`、`MAKE_COMMANDS.md`。修旧子进程模态描述、renderer displayRealized只改flag、font disabled/synthetic hash、目录/缓存等已过时描述；如实保留未验限制 |
| R6-1R / PENDING | R6-1 / rules单写者 | `docs/AGENT_RULES/` apprt-win32消息/计时器/模块、gx-core快照/cache、apprt-gtk、renderer单帧与恢复、testing新工具/生成物；resolver真源routes与必要root索引同步，不新增nested AGENTS、不改上游嵌套原文。root/domain均16KiB、重复段落160字符/KB2.5MiB预算不抬；testing当前 **16304/16384B仅余80B**，先压缩冗余/用跨域链接，不复制rules或提高预算 |
| R6-2 / PENDING | R5消费者冻结 / 源码owner | 删除三个Win shim：`src/apprt/win32/ui/fuzzy.zig`、`ui/settings/fuzzy.zig`、`ui/settings/swatch.zig`及旧roots/import，消费者直接共享`gx.fuzzy/theme_swatch`；扫真实死代码/旧注释，不删仍public需要的接口。Read→Edit、引用全查、相关tests/roots/fmt/fork/diff为证 |
| R6-3 / PENDING | 最后源码＋文档（含本文）freeze / generation单写者 | 所有变更先定真源再生成：`just i18n`、全拼新pinyin/Fluent正式离线生成器与校验、`just kb`、`just graph`后审diff；再`just generated-check`。不手改zh_CN/initials/syllables/chunks/graph产物，graph.json本机ignored不提交；包许可与输入快照归对应真源。若之后修改文档/公开签名，重新生成相应语料，再check，不能在gen之后随手改doc却声称fresh |
| R6-4 / PENDING（历史FAIL待处理） | R6-3 / test owner | 合法排查KB过期/Windows TempRepo WinError32；若确证自身runner/fixture资源生命周期bug，允许最小修复＋复现/回归/独立审查，不是绝对禁止改runner。仍禁未知kill、强删外部锁/目录、skip case、吞error或改serial仅洗绿；原FAIL保留。标准rules/version/fmt/framework/ci/diff门、完整Windows `just test`/`just test-vt`、ownWSL POSIX/main＋GTK测试/app build全部实跑，真实skip/fail不借定向数；tinyio前置合法获许可解决/正确环境补验，不省4/2case |
| R6-4A / PENDING按实际sourceimpact | R6-4 / core test owner | 共享renderer/font/IPC若触lib-vt/CABI/freestanding范围，按resolver跑`just build-vt`、`just vt-wasm`、C ABI/examples及`test-lib-vt`相关合同；不在Windows链接失败的internal app-runtime=none绕标准main；公共C枚举/sized struct/导出步骤不变或实测。macOS无法跑的受影响项记PENDING与补验，不伪N/A |
| R6-4W / PENDING（历史三尾已PASS） | 最新source / build owner | 正常`just build -Demit-webdata`后的config末`gx-ctrl-scroll-zoom`完整doc、actions末`gx`全文、commands末`toggle-quick-terminal` flags/example＋闭合suffix逐全文核，再实际CLI/help/错误码；新增R5 CLI字段文档一并验。build exit0不是contract PASS，旧GX37三flush已合，不重做它 |
| R6-5 / PENDING | C/V/R5源＋R6-4 / GUI/perf owner | 最终候选标准build保留真实W01–15 R0 regression、仓内W16–20/G01–14，并补第7节叶需求/overview/外部BellBorder/R5场景逐图、关键链真实响应；Windows最终A/B/input、GTK标准十对/C1与P1–P9报告。same source/tree/backend/ConPTY/receipt，独立核raw单位/n/图；必需硬件/Wayland/IME/TDR缺证不合成全绿，C1额外precision研究按独立PENDING报告而非新必过门 |
| R6-6 / PENDING | 必需门通过＋第0节执行提示授权 / 协调 | 精确暂存、列中文`type(scope): 描述`消息与每阶段证据；用户已发送执行提示时，本地commit/no-ff权限已延续，无需二次问是否执行/提交（仅审时没有权限）。独立review/固定完整历史合候选，本文纳入最终语料/精确提交且不reset主仓文档。核候选tree/ancestor/registry/完整测试场景后本地no-ff合gx，不移动main/no push；合后用户实际gx树再标准build/test/最终场景/gencheck，冲突/新增变化重测影响，不借merge前binary冒最终 |
| R6-7 / PENDING | R6-6成功或有界停工 / cleanup owner | 只清ownedPID+birth/handle及WSL starttime/pidfd、正常归还worker/header/COM/D2D/pipe/lease/slots/desk/task，不以强kill当生命周期PASS。审tracked/untracked/ignored、branch contains、未合/未提交成果后决定是否清worktree，不要求删全部；未合成果保分支/证据/未提交内容。junction先列自己链接本体与真实target；如移除仅非递归移除**自己junction本体**，核主仓zig-pkg真实target未损，不递归删target、不清别树/未知TempRepo、不git force |
| R6-8 / PENDING | 最终验收与清理 / 协调 | 最终报告逐任务ID的PASS/FAIL/PENDING/N/A、source/tree/exe/receipt、命令exit/真实统计、已读图与路径、condition拒绝/未验理由、补验命令及清理身份；全部必需功能与门满足才goal complete。否则保持not_complete，报告阻断而非交较小结果 |

执行命令的最小定位模板：在相应最终owned树cwd先复制第4节独立cache export块、读当时CLI/help/rules；各重型命令按slot合同调度，GUI按desk，**不是让整块无条件执行**，不得在quiet采样期间build/test。Git Bash的clone参数一律保留引号，compiler仅just/zigw钉0.16.0，不能裸tilde变Windows home或借旧test binary零命中。

```bash
just test --filter apprt.win32 --filter gx.
just wsl --clone "~/src/gx_ghostty-R23-int" test --filter gx.
just wsl --clone "~/src/gx_ghostty-R23-int" test --gtk --filter apprt.gtk.gx
python scripts/run_unittests.py test_fork_patches test_gx_test_roots test_gtk_gx_contract
python scripts/run_unittests.py test_gx_perf test_gx_wsl test_gx_win_gui test_zig_test test_gx_workflows
just build -Demit-webdata
just wsl --clone "~/src/gx_ghostty-R23-int" build --gtk -Doptimize=ReleaseFast --summary all
just test
just test-vt
just wsl --clone "~/src/gx_ghostty-R23-int" test
just wsl --clone "~/src/gx_ghostty-R23-int" test --gtk
just i18n
just kb
just graph
just generated-check
just rules-check
just framework-check
just ci-check
git diff --check
```

新R5模块要添加实际存在的定向test名，保持原标准runner/并行方式；不创建无项目约定的临时报表/脚手架来绕验收。版本/许可/源码包上限按已有规则，不发明新的数值门。

**goal停工规则**：执行后优先找仍可安全推进的任务；只有连续至少3个goal turn没有安全进展且必需前置确实无法获取，才按goal工具规则进入blocked并完整记录原因/证据/补验。用户paused优先，立即停止执行，不等三轮；当前交接不会active任何goal。环境缺失不是自动豁免，也不授权系统改动。

## 10. 证据目录、溯源与无上下文reader检查

### 10.1 当前真源与优先级

1. 本文是剩余执行契约；本轮用户授权与限制优先。实际后续source/receipt/raw胜过作者总结；更晚同scope独立复审/实测可覆盖旧状态，但原失败不删。
2. 主 `.local/r23-state.json` 的`integration/r4_entries/r46_standard_harness/phase_R4`与 `.local/evidence/R23/integration/notes.md`最新收口；不从旧`workflows.next`抽pending。
3. 最新C1 `.local/evidence/R4/GTKPipeline/quiet-reviewed/{notes.txt,summary-results.json,commands.json,build-identity.json}`；quiet三个raw窗口、receipt/version/inventory同目录。`normalharness/`、`reviewfix/checkpoint.json`、`measurement/RUNTIME-PROOF.json`用于来源/关闭历史；unsafe旧40仍revoked。
4. 候选`I/r4-font/`、`I/r4-joint/`（GUI限定791）、`I/r46-harness/`（d6最新）、`I/{bell-border,bell-audio,chrome-alpha,r4-renderer}/`；OSC52运输 `.local/evidence/R23/OSC52Transport/{notes-bundled01-frozen.md,notes.md}`。源事实用 `src/...::symbol`，长期引用不钉漂移行号。
5. 原计划全文：`C:/Users/guoxi/.kimi-code/sessions/wd_gx_ghostty_18c55036085c/session_d30cb445-3368-41e5-8baf-4ec00a95669d/agents/main/plans/medusa-banshee-stargirl.md`；R5设计溯源：同`agents/main/tool-results/AgentSwarm-call_j3uTJuw6XVTK631UnWCSxUfT-6aff1b62-a6a8-476c-8055-d68a173d23fd.txt`。它们是指定只读文件，不授权搜其他私有session/凭据；旧报告基线3e79、max30及harness缺口描述已过时，不能覆盖当前d6/max38事实。

### 10.2 新证据必须可重算

按 `.local/evidence/<任务ID>/<batch>/`（或owned worktree的同类ignored目录）保存：输入freeze/source-tree/dirty、实际argv/env白名单、标准build receipt/version/exe hash、OS/backend/配置/ConPTY摘要、raw logs/exit、canonical plan/captureIDs/每load身份与units+n、screens原件/读图结论、失败/复跑原因、review/决策、cleanup PIDbirth/handle/slot/desk。配置只能测试自有文件，不落用户剪贴板或secret正文。

错误修复前后raw分目录，完整失败批不重标valid；不得删除负结果或将bootstrap/回归fixture塞入产品10pair。进入下一会话只读重新枚举进程/task/worktree，不用文档里的旧PID或agent/task ID控制对象。

### 10.3 新reader验收问题

协调者已完整Read初稿；两名无旧上下文reader401/402指出授权、命令、计量、leaf与inventory缺口后，writer仅Read→Edit本文修订，没有实施工程任务。协调者随后完整Read修订稿，另两名全新6.1-sol reader403/404仅凭本文复测，均判定交接可用、无阻塞文档使用的核心缺口。**文档reader测试PASS，不代表工程、性能、GUI或整体goal PASS；当前goal仍paused。** 复测覆盖一次新消息授权、引用clone/slot→desk链/fresh OUT＋JSON、CPUprecision非新增硬门、15Win＋5GTK leaf与真实case入口、生产clipboard先读后ask、NEW getAll和junction边界。新对话也可用以下问题复核：

- 当前主仓/候选与三测量树身份是什么，旧goal是否active，什么授权之后才执行？
- 哪些审计/源码/晚接线/helper不用重做，哪些历史PASS不能当最终PASS？
- 最近GTK性能究竟跑了几次：build/quiet/loads/screens、数据状态各是什么？旧40和bootstrap能否计入？
- C1怎样在标准桥/身份/n/单位/CPU精度守门下恢复两个十对，怎样区分Gate与Pool边际和安全采纳？
- P1–P9数值方向、Menu160Hz未达门、conditional默认/stack/warmup/cairo有哪些不能自动决定？
- OSC52、BEL/音频、Alpha/BellBorder、D11、IME/首帧/Quick、GTK硬件/Wayland的真实证明各缺什么？
- R5十一流具体做什么、入口/共同owner/安全边界/实际验收是什么，已有new_tab_menu为什么不重做？
- 什么是假跨host活PTY转移、UAC绕过、UIA焦点死锁、session initial-command重执行或DComp假reset证明？
- R6文档/规则预算/shim/生成/全量门/最终本地gx merge/清理怎样闭环，未过门能否complete？

若reader无法仅凭本文回答，修本文相应节，不把更多长审计粘贴成前置。后续正文变更属于KB语料，必须在R6最后真源冻结后重新生成检查。
