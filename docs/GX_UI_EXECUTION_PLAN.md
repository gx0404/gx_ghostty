# GX UI 当前执行计划：单对话原生子智能体、集中验证、R6 收口

本计划依据当前对话 2026-10-14 的授权与 2026-10-17 的模型分工更新，覆盖旧交接文档的任务组织、构建频次和提交授权；功能范围仍是 F1–F10，原完整验收契约（`docs/GX_UI_REMAINING_PLAN.md`）中的门不因本计划而视为通过。原定截止北京时间 2026-10-14 02:48 **已超期**，如实保留，已用时间不清零。当前总状态 **`not_complete`**。

## 第 6 阶段（2026-10-18 起，进行中）

本节只概括第 6 阶段的安排，不记录任何结论。完整真源是用户批准的计划原文 `.local/evidence/R5/execution-20261013/final-r3/phase6-plan.md`（该目录下称 F3）与子智能体共同合同 `F3/r6-contract.md`；本节与二者不一致时以原文为准。总状态仍为 `not_complete`，后文各节的历史记录保持原样。

- 目标：在本机、Win11/Win10 VM、WSL 与 gx-ci 能覆盖的范围内，把 C1–C8、V1–V7、P00–P9 与远程性能、8 组功能边界、平台项、142 叶签收与 R6 收口逐项做出确定结论；发现缺陷就修，不降门槛，不改写历史结论。
- 结论口径：PASS；FAIL（已尝试修复，原件保留）；PENDING（写明环境原因与补验命令）；BLOCKED（附轮询记录）。142 叶另可记 PASS_SCOPED（列缺口），C 项另可记 INSUFFICIENT，见下文与 F3。
- 已定选择（仓库与 CI）：恢复 6 个 `wip/R4-*` 分支继续 C1；允许 push 到 `origin/gx_ghostty`，并手动触发 gx-ci 的 macos、gtk_smoke、win_smoke。
- 已定选择（环境）：VM 内可以建账户、改设置、用讲述人，可以下载钉版 Win10 ISO；宿主系统设置一律不动；GUI 与性能按身份型安静判据自动轮询。
- 已定选择（改动）：P4 允许弹层隐藏复用加空闲预排版，DComp 仍默认关闭；默认值改动由 agent 加独立复审按合同决定，逐项单独提交；新上游补丁按合入顺序从 GX-0045 起由 root 编号。
- 分工（同时不超过 10 个子智能体，每个文件只有一个写者，归属表见 `F3/r6-contract.md` 第 5 节）：root 负责调度、构建与 VM/WSL/桌面/性能的实际执行、接口裁决、集成提交、push 与 CI。
- 实现工位：A1 Windows 埋点、P4 优化、采纳项接入与 Windows 缺陷修复；A2 `gx_perf.py`/`gx_slots.py` 新能力与远程性能链路；A3 迁移、会话、IPC、UIA、OLE、broker 夹具及相应修复；A4 GTK 侧 C1 集成、C2-G、C5、V7 与编辑器、管理器边界修复。
- 辅助工位：O1 CI 修复、VM 相位、W/G 场景、C 变体分支与文档；O2 全部截图逐张读图，root 抽查不少于 10%；D1 142 叶映射、影响集、证据 JSON 与账本；R 在每个 src 提交前独立评审，P4 与 C1 另加 Astra 交叉审。
- 波次一：W1 叶映射与 W2 工具、埋点、夹具并行；W2 还把外部 BellBorder 与两个 R2-Font 场景导入为 W21–W23（新 Windows 场景从 W24、GTK 从 G17 起连续编号），并建 `wip/C4-stack4m`、`wip/C6-nowarmup`、`wip/C7-blink-control` 三个只改一个变量的变体分支。
- 波次二：r6 构建只做一次；W3 功能补验（宿主、VM、WSL，不需安静窗）；W4 在第一次安静窗做决策实验（C1 两批十对，C4–C7 各十对）。
- 波次三：W5 工程改动与采纳项接入；r7 构建候选 rF，仍有修改最多再出 r8 一轮后冻结源码；W6 在 rF 上跑最终门，第二次安静窗跑 P00–P9、远程性能与 P4 终测。
- 安静判据：性能批次开始前与结束后都要满足无构建/测试进程、VM 已停、`gx_slots --kind quiet` 拿到全部槽、用户无输入不少于 10 分钟、黑名单进程未运行；结束后不满足则整批 INVALID、原件保留、改日新目录重跑；每 15 分钟轮询，每批每天最多 3 次，其他工作完成后再等 24 小时仍不满足记 BLOCKED。
- 「明确收益」（C1、C4–C7）：目标指标 median 与 p90 都改善、median 差大于两侧 IQR 的较大者、守护指标 median 不按同一界限变差且功能与视觉检查全过才采纳；目标变差或任何功能回归即拒绝；其余记 INSUFFICIENT（新改动不采纳、已合入项保持、实验分支保留）。
- 其余口径：P1–P9 阈值、C1–C8 各项判据与 142 叶签收规则以 F3 计划第 4 节为准；R3-AppMode.04 维持 DEFERRED，R2-Font.04 取 C6 结论。
- 预期终态：各项给出确定结论后总状态仍为 `not_complete`；macOS app、宿主真实多 DPI、真实 TDR、GTK 原生手势与 IME、硬件 DMABUF、V2 人耳试听、Win10 中文输入法与现代 GTK 性能预计仍 PENDING；一直没有安静窗时 P 门与 C1、C4–C7 记 BLOCKED。

## 授权与组织

- 只派当前会话的原生子智能体，同时活动上限 10 个；不建独立对话或后台 CLI 会话，不恢复已归档的独立对话；当前对话里已完成的原生子智能体按需 followup 复用。子智能体直接指定 `model`、`reasoning_effort` 与 `fork_turns:"none"`，不改客户端配置。
- 模型（2026-10-17 用户更新）：中等及以上复杂度任务默认用 `gpt-6-astra` `xhigh`，包括跨模块接线、系统集成排障、跨进程生命周期、协议与绑定续延；边界明确的简单实现、简单修复、常规夹具和文档用 `claude-opus-5-5` `xhigh`；清单、哈希、映射、证据 JSON 等机械工作用 `deepseek-flash` `max`。按任务实际复杂度分配，不仅按文件类型分配；简单任务出现多模块或系统行为不确定性时转交 Astra。DeepSeek 的 fresh 明文探针已返回 `DEEPSEEK_PLAINTEXT_OK`；探针或创建成功不等于该模型的产出已验收。
- 全机重型任务（构建、完整测试、VM、性能）最多 3 个；同一工作树的构建串行，构建期间冻结相关源码；宿主桌面独占，GUI 与性能不并行。
- Windows 与 GTK 完整 main 各已运行一次（final-r2），不再重复；新编译后只重跑受影响的定向测试与场景。打包不重编，翻译、KB、图谱在源码与文档冻结后各生成一次。
- 用户已授权把全部已有与新增改动做本地阶段 commit，无需逐次确认：精确暂存、提交信息按根 `AGENTS.md`「提交规范」。不 push、不建 PR/Issue/tag/release、不新增下载，不触碰 `GX_API`。
- 主树按文件单写者工作；所有权按文件显式移交；状态经原生消息回传，不共写状态文件。文档、CHANGELOG、补丁登记与证据导航由文档工位独占，证据 JSON 由机械工位维护。

## 当前状态（2026-10-18 核对）

- 已有本地阶段提交：`8a2b4bb59` 保存整体实现，`de3149e1f` 修 GTK 恢复泄漏，`03c8e138f` 隔离 VM 单测并核验容器归属，`c9dd5eb7c` 修 ReleaseFast 远程粘贴事务身份，`ff41652c2` 修远程取消、映射替换和退出清理，`b0de75a1b` 补远程压力与焦点时序夹具，`84671b9b6` 修通知激活器快捷方式 GUID，`f55771d84`、`432f91eb4` 补 VM 关闭结果、拖放源与指针模式，`3aeb28f15` 让拖放接收器以关联令牌启动，`d5c4f911d` 为文档检查点，`5fd3a2741` 让 VM 夹具自动衔接真实拖放与身份校验（这两个提交未改 `src/**`）。`eb2f37d2e` 精确单文件提交同用户三向原生拖放夹具（作者本机核过解析、Add-Type 与 token 用例 3 正 8 负、错误 birth 在输入前拒绝，独立复审 PASS）。HEAD 为 `aa9fec9d7`；`5fd3a2741` 保留为本轮开工核对身份，不回写历史 receipt。`src/apprt/win32/App.zig`、`src/apprt/win32/ShellIntegration.zig` 的冷激活提示最窄修复已独立 review PASS、构建为 r5，并单独提交为 `aa9fec9d7`（两文件冻结哈希不变，全部 `src/**` 已提交，当前实树源码与 r5 构建字节相同）；r5 构建身份仍是 `eb2f37d2e` 加这两个文件的哈希，不倒写为构建于 `aa9fec9d7`；r4 哈希保留为历史证据；文档、KB 与图谱由 root 最终提交。提交不是验收通过。2026-10-17 机械核对（`final-r2/identity-20261017.json`）：`src/**` 1223/1223 与 r4 构建前快照一致，r4 app/setup/zip 与 r3 test-bin 哈希全部匹配，当时无需重编；r4 app 哈希此后未变。
- 最新候选为 r5（见下条）。此前 r4 为 `zig-out-delivery-r4/bin/ghostty.exe`，SHA256 `eece67e02e54823a8336849359776c86fe1195c1fef4d721c146f40013c37e90`；离线包 setup `de2a810188d84c94dabad61719dea320f0144b9ea36584be11f637264013c9ea`、zip `9d440ea5…fc25f`。r4 相对 r3（`95d7a015…8eba`，合并构建与 50 项定向通过）只把接收器启动令牌权限由 `0x0B` 改为 `0x18B`，r3 的测试、远程与 GUI 证据只覆盖未改动的逻辑，按范围复用，不计为 r4 的新测试结果；令牌权限改动由 VM 四组令牌对照与接收器配对实证覆盖。Toast 诊断 app `435c87aa…236e` 不作最终包，四个诊断源码文件已精确撤回（补丁留存），撤回后源码曾与 r4 清单一致。此前 `cc2edbc9…663f76` 的已验范围独立保留。源身份以构建时 HEAD 加文件摘要为准，不因后来提交而改写 receipt。最新已验 GTK 快照为 `38e3e644f`。
- r5 已构建：app `f0c80e8cdfe576594eaa222e15ee916f857f9eaeeb2cbe8c166f853ea8b0c3db`（34,956,800 B）、test-bin `8b75f8dc6984b63a5c78b6b73da36ef95173f1a4723de097d5a36067ccef348c`（172,882,432 B）、setup `d94b9a40f10ee32cd151276d0fddb706d5afbe0b438a9113c75ba24d14b3d597`、zip `2d4bd9616249d1dbbedc34db990f7ebaf9303402274f0cf5e875d1a11fc66367`，分别在 `zig-out-delivery-r5/` 的 bin、test、dist；DeepSeek 复核 ZIP 中唯一 exe 与 prefix 一致。`src/**` 1223 个文件中相对 r4 只有 `App.zig`（`2a8736b5…d266`）与 `ShellIntegration.zig`（`c0dd496f…7de3`）变化，修复已独立 review PASS。正确引用版本参数后的合并构建工具记录 exit 0（工具 session 66398，无 stdout 日志文件）；首次 `delivery-r5-build.log` 因 PowerShell 拆分配置参数报 InvalidVersion、未编译，原件保留。同一测试二进制定向 23/23、0 skip（seed `0x52553501`，jobs 2，filter `toast server watchdog`、`apprt.win32.shell.`、`gx.shell_startup`），二进制发现 5056 项，只跑这 23 项，不等于全量；离线打包 `delivery-r5-package.log` exit 0。r4 的历史失败与矩阵证据不回写成 r5 新运行，未受影响部分按范围复用；inst-r5 安装、热冷激活、无激活退出与 r5 最终卸载均见下方 r5 系统通知条。
- 完整 main 已各运行一次：Windows 5017 总、4942 PASS、73 SKIP、2 环境 FAIL（符号链接权限）；GTK 4533 总、4480 PASS、53 SKIP。历史 W0 的 161 项和误混旧二进制的 226 项不冒充新证据。
- Windows 后续 103 项受影响测试通过；RemoteInput 的真实源码小入口 Debug/ReleaseFast 各 7/7，真实安全粘贴子集 9 项和 4 图通过。W06/W07/W14/W16 修复批次 19 图已读；本轮 session/IPC 4 组、7 图以及 W20 的 23 步、6 图通过。Popup UIA/DComp 21 项原生检查、13 图已审阅，范围限制见证据索引。
- GTK 生命周期 38/38、20 图通过，两次退出码均为 0；迁移后原 PID/birth/PTY 不变，恢复确认、临时命令跳过及几何恢复均有证据。恢复探针 6/6 与 7/7，受影响 G15/G16 通过。Xvfb 不代 Wayland/IME/硬件验收。
- r3 已复验三个远程修复：取消后输入正常，目标丢失后回收并退出 15/15 为 0，连续 330 次分屏与布局变化未再出现非预期断连。52 张图已读完（含 15 张历史夹具失败图的独立判读），另有 root 和 Opus 抽查；旧失败原件保留。Win11 接收器的 1346 已修复；后续访问拒绝由四组真实令牌权限对照确认只有 `0x18B` 成功。r4 安装版经提权窗口菜单启动接收器，host 10180 与 receiver 8260 双向关联认证 PASS（high/medium 登录会话互为 linked，同 SID、同会话）；这些 PID 是 10-14 的历史记录，不代表今天仍在运行。本次运行（`F/vm-resume-20261017/`）的提权 host 4844（birth 134367489947377883）与 receiver 4492（birth 134367490645127172）上，medium→high 真实 DoDragDrop 的文本取消（Step `20261017-092401-564`，source 7884，图 45—47）、允许后不追加回车（Step `20261017-092721-251`，source 1908，图 49—51）与多行保护取消（Step `20261017-093752-026`，source 8276，图 58—60、62，root 逐图已读）PASS；来源 COPY 准入与 GUI 完成回执分开判定，r4 app 哈希未变。multiline1 超时保留 unknown，图 53—57 不计为及时取消 PASS。同用户 direct 三向（medium→medium、high→medium、high→high）最小文本拖放均 native 与读图 PASS（`F/vm-resume-20261018-direct/`），与 broker 合计为 F6 四方向最小文本矩阵 PASS_SCOPED，不扩大为原完整 files/URI/DPI 矩阵。
- VM 曾被未隔离单测误操作，异常关机原件保留；真实磁盘未丢失。单测与容器身份检查已修复。GL 关闭探针已确认窗口和请求正确；历史“正常关闭”漏查退出码，实际含与宿主相同偏移的 `WM_QUIT` 清理崩溃，结论已作废。r3 的三次关闭均退出 0；渲染图本身仍只证明渲染。
- Win11 系统集成：r3 安装 exit 0 后卸载 exit 0，五组注册表键与应用目录均不存在；r4 安装 exit 0 并核对 app 哈希。JumpList 用键盘打开，选择启动配置在同一进程（PID 2912）新开窗口，PASS。系统通知的原生同 AUMID 探针、诊断版与 r3 原版重启对照都显示了横幅；早期三次 OSC 未显示仍记 FAIL，原因不明，不宣称诊断日志修复了它。Toast 热激活 PASS：用键盘在通知中心选中并激活（图 70、71、79、80，root 已读），`r18-toast-start.json` 与 `r18-toast-hot-result.json` 的 PID 3068、birth 134367290904078802、HWND 1900866 一致，r4 app 哈希一致，激活后 app 进程恰为 3068/4492/4844、无新 app，图 80 原终端获焦（证据在 `.local/windows-vm/win11/exchange/validation/out/`）；图 72 的坐标点击未命中（图 74 通知仍在、光标未动），不记产品 FAIL，也不记点击成功。冷点击合同是提示历史目标不可用并退出 toast-server，不开新 shell。首个冷点击通知（图 81，source 3068 exit 0）保留原记录。r4 冷激活的原生部分成立：cold2 source 6180 正常退出 exit 0、`app_pids=[]`，通知历史 XML 带原生 token（`r18-toast-cold2-history.json`），系统真实启动 PID 7120（birth 134367322172516267，参数 `--gx-shell-action=toast-server -Embedding`，r4 SHA，`children=[]`）并 exit 0（`r18-toast-cold2-start.json`、`r18-toast-cold2-exit.json`）。但图 94、95 没有前台提示：原始 `#32770` 对话框在其他窗口之后，并被 15 s watchdog 结束，所以冷激活的关键 GUI 门在 r4 上记 FAIL，不记 cold PASS。已定位原因：MessageBox 只用 ICON_INFORMATION，计时器无条件 PostQuit。Astra 冻结了 2 个文件的最窄修复（有效激活先标记并 KillTimer，handler 吞掉排队的旧 timer，冷启动提示置于前台，用户关闭后才退出），r5 已按此修复构建一次 app 与 test-bin，定向 23/23 通过，GUI 复验见下条。卸载前三个 app 4492/4160/4844 经 CloseMainWindow 正常退出 exit 0（`r18-direct-owned-close.json`），`r18-direct-apps-remaining.json` 为空；注册 inspect（`inst-r4--gxadmin--20261017-102047-955-inspect.json`）PASS，ShellAumid 的 GxExecutable/IconUri 与 CLSID LocalServer32 都指向 inst-r4，运行令牌为 medium。r4 最终卸载 PASS：`inst-r4--gxadmin--20261017-104517-405-uninstall.json` exit 0，五组注册表键都不存在；`r18-r4-uninstall-residue.json` 显示应用目录不存在、`app_pids=[]`。这只关闭卸载门，不代表 r4 最终验收完成。
- r5 系统通知复验：r5 关键 GUI PASS（图在 `F/vm-resume-20261017/`，原生 JSON 在 `.local/windows-vm/win11/exchange/validation/out/`）：inst-r5 安装（`inst-r5--gxadmin--20261017-110227-045-install.json`）exit 0、app 哈希 `f0c80e8c…c3db`、五组注册表正确；热激活 source PID 5412（birth 134367340058015314，HWND 1245934）在 `r18-r5-source-start.json` 与 `r18-r5-hot-result.json` 中一致且只有 5412 一个 app，图 102 横幅、103 选中、104 原窗口获焦（root 已读）；通知历史为原生 gx-toast-v1 XML（`r18-r5-cold-history.json`），source 5412 exit 0、apps 为空（`r18-r5-source-exit.json`）；OS 冷激活新进程 5976（birth 134367345580780184，`--gx-shell-action=toast-server -Embedding`，r5 SHA，`children=[]`），`r18-r5-cold-start.json` 显示前台窗口就是它的 `#32770`（HWND `0x15020e`）；图 108 与 109 相隔 21.36 s，提示「这条通知对应的终端已不可用。」一直在前台可见（root 逐图已读），手动 Esc 后图 110 提示消失，`r18-r5-cold-exit.json` 显示同一 5976 正常 exit 0。r4 的前台与超时 FAIL 保留为修复前证据，r5 复验通过；早期三次未显示仍为历史 FAIL、原因不明。Astra 独立复审图 108、109、110、原生身份与 23/23 报告 PASS。无激活 idle guard 单独验证 PASS_SCOPED：`r18-r5-no-activation-timeout.json` 中 PID 7484（birth 134367347566290408）、r5 哈希，15078 ms 后 exit 0；它只证明没有激活时 15 s 后退出，不代 OS 冷点击。r5 最终卸载 PASS_SCOPED：`inst-r5--gxadmin--20261017-111936-284-uninstall.json` exit 0，五组注册表键都不存在；卸载后立即检查的 `r18-r5-uninstall-residue.json` 显示应用目录仍在（卸载器自删除窗口，原件保留），随后复查 `r18-r5-uninstall-residue-after-wait.json` 显示应用目录不存在、`remaining=[]`、`app_pids=[]`，期间没有手动删除；图 112 root 已读。
- VM 已经 owned stop 关闭：`final-r2/win11-stop-20261018.log` 显示 owned=true、完整容器 ID `a8771d3f901916c03885e735204f6971df1c5315ba023fb7a37b4f738516d6df`、running=false、status exited、exit 143、oom=false、binding_errors 为空；stop 命令 exit 0，heavy guard session 9120 已 exit 0 释放，磁盘保留，停止前已复核 UUID `466cf44f-4c70-4863-80a6-cc0b10aa8103` 匹配。这个 143 是容器停止状态，不是客机应用崩溃，应用关闭与卸载的 exit 0 另有证据。
- 2026-10-17 已重新启动 Docker，并复用原 Win11 容器（`a8771d3f…`，此前 exited 255，live UUID 匹配），heavy 由 session 9120 持有；direct 三向已完成，三个 app 已正常关闭，VM GUI 已交还 root，VM 最终已 owned stop 关闭（见上条）；10-14 的客机 PID 一律不视为在运行。
- 10-17 的 framework 日志曾为 936 项、17 skip、exit 0（历史）。10-18 root 用 `python scripts/gx_slots.py --kind heavy -- python scripts/run_unittests.py --jobs 2` 集中跑完整框架单测：936 项、17 skip，唯一 FAIL 是 `test_agent_kb.RealCorpusTests.test_checked_in_kb_is_fresh`（新文档后尚未生成 KB），其余通过；原日志 `final-r2/framework-20261018.log`，wall 436.36 s。这次记 FAIL，不是 PASS，也不是 15 s 级的快速检查。`just fmt-check`、`just fluent-check`、`just graph-check` 在 r5 两文件修改之前由 root 运行，exit 0；修改后已按两源变化重建图谱（`final-r2/graph-20261018.log` exit 0，35 处头文件解析限制不变）；r5 源码冻结后 graph-check 与 fmt-check 重新 exit 0（本轮工具记录），i18n、pinyin、fluent 真源未变且 check exit 0。

## 功能状态

| 项 | 源码 | 现有证据 | 状态 |
|---|---|---|---|
| F1 混合树与 Session 剪枝 | `Leaf`/`Pane`、Window、TabTransfer、Session | 拖回、再迁移、混合标签拒绝、本地部分恢复及原终端身份已有实证 | PASS_SCOPED：回收后退出 15/15，正式签收 PENDING |
| F2 远程视图与输入 | RemotePane、RemoteInput、key_translate | 原 shell 输入、IME、OLE、安全粘贴、鼠标选择复制通过 | PASS_SCOPED：取消后正常输入，原失败已复验 |
| F3 协议与状态 | remote_protocol、RemoteSource、RemoteCoordinator | 协议与输入队列定向；330 次布局变化无非预期断连 | PASS_SCOPED：原生与全部附加压力图已审阅 |
| F4 绑定续延 | remote_binding、GX-0044、RemoteSource | 链、once、普通 performable 回退及 cancelled 语义有单测和真实回放 | PASS_SCOPED，完整矩阵仍按证据索引 |
| F5 目标交互 | RemotePaneUi、UIA、OLE、菜单、搜索与剪贴板 | 外部 MTA、真实 OLE、弹层及部分确认通过；取消状态已在 r3 复验 | PASS_SCOPED：完整平台矩阵按批准延期 |
| F6 broker 与 shim | DropBroker、DropBridge、DropCompanion | shim 已删除并构建；认证/回执定向通过；r4 安装版接收器启动与双向配对通过；medium→high 真实拖放的文本取消、允许不追加回车与多行保护取消通过；同用户 direct 三向最小文本拖放 native 与读图通过 | PASS_SCOPED：四方向最小文本矩阵与 broker 取消/允许/多行保护已闭环；原完整 files/URI/DPI 矩阵不扩大签收 |
| F7 GTK 生命周期 | GTK GX 生命周期、迁移、session 与编辑器 | 38 项生命周期、20 图、原 PTY、双退出与重启通过 | PASS_SCOPED；Wayland/IME/硬件保留 PENDING |
| F8 Win11 系统集成 | ShellIntegration、shell、安装器 | 登录、真实 medium/high 配对、Mesa 渲染预演；r3 安装与无残留卸载、r4 安装、JumpList 通过；通知显示对照通过；Toast 热激活（键盘）聚焦原终端且无新进程；冷激活原生启动与退出成立；r4 最终卸载无残留；r5 安装、热激活、冷激活前台提示、无激活 15 s 退出与最终卸载复验通过 | PASS_SCOPED（r5）：r4 前台/超时 FAIL 保留为修复前证据；早期三次 OSC 未显示保留 FAIL；升级与 Win10 延期 |
| F9 文档与生成物 | R6、GX-0039～0044、671 条翻译、142 叶映射 | 补丁与测试根检查通过；10-18 完整框架单测 936 项（17 skip）仅 KB 新鲜度 1 项 FAIL；fmt-check、fluent-check、graph-check（r5 修改前）exit 0，图谱已按 r5 两源变化重建；正式 142 叶签收为批准延期的 PENDING，52 叶仅流级证据如实保留，不新建场景 | PASS_SCOPED：文档与生成物收口；r5 冻结后 fmt-check、graph-check 与 i18n/pinyin/fluent check exit 0；KB 已生成，RealCorpusTests 6/6 通过，随本次状态更新再次生成并校验 |
| F10 条件实验与性能 | C1–C8 保持默认；DComp 实验默认关 | 无新样本 | PENDING；P4 保留既有 FAIL 至重测 |

交付口径：F1–F9 功能交付按上表已验范围的限定证据完成，PASS_SCOPED 只覆盖列出的范围，不升级为原完整验收 PASS，也不代表原完整 files/URI/DPI 等矩阵。本轮已无额外实现工作；余下只有原完整验收中已批准延期的项（性能与 P4、硬件、Win10 与升级路径、跨账户负向、正式 142 叶签收等）；F9 KB 已由 `just kb` 生成，`RealCorpusTests` 定向 6/6 通过（`final-r2/kb-final-20261018.log`）；本次状态更新随交付记录再次生成并校验 KB，精确本地提交。原验收总状态仍为 `not_complete`。

## 接口冻结（仍有效）

- `Window.adoptRemoteTab(at, description, panes)!refs.Reference`：RemotePane 由远程侧创建，Leaf 与树由 Window 创建，仅成功后转移所有权；`leafForPane`、`activeLeaf`、`removeLeaf`、`onLeafStateChanged`、`describeTab`、`performUiAction`；App 提供 `resolveLeaf`、`resolveRemote`、`visiblePanes`。
- `RemoteCoordinator.sendToSource/sendToTarget` 按 source 稳定引用找已认证连接；`RemotePaneUi.handlePacket`、`performBindingAction` 的返回值只表示真实结果。
- 协议 v2：两端共享规范动作文本；请求与结果携带 surface、lease、transaction、config_generation；快照文本有界（60 KiB），不按值扩张队列槽位。源持有终端与绑定状态，目标持有可见 UI。
- 语义：源丢失不重放命令；目标退出归还源；纯远程标签可拖回源，混合标签禁止跨进程迁移；all/global 只作用目标可见窗格；Session 不保存远程叶；Quick Terminal 拒收远程。粘贴单块受协议上限约束、总量不超过 16 MiB，不追加 Enter。模态返回后重查稳定引用。

## 批次记录与收尾

原定构建/打包次数已因真实系统缺陷超出：r3 合并 app/test-bin，r4 仅 app 热修，单独 Toast 日志诊断 app，以及 r5 冷激活提示的必要热修（合并构建 app 与 test-bin 一次；首次因 PowerShell 拆分版本参数报 InvalidVersion、未编译，原件保留，修正参数后成功）；r3/r4/r5 各离线打包一次，诊断 app 不作为最终包，其源码改动已撤回。未追加完整 main。已生成的 KB/图谱在真源再变后需重验新鲜度，按实际影响补生成，不把旧产物冒充最终冻结结果。

1. 已完成：broker 拖放（四方向最小文本矩阵与取消、允许、多行保护）与 Toast 热冷激活等系统集成排障由 Astra 承担并闭环，简单夹具与文档由 Opus，证据映射由 DeepSeek，root 统一测试根、构建、VM 输入与接口裁决，未新增独立对话。既有远程修复证据保留，不重做。后续若出现新异常，仍按此分工：中等及以上的排障与修复交 Astra，构建只按实际影响补一次并保留失败原件。
2. 已完成：r3 合并构建一次 `install test-bin`，受影响并集 50/50（seed `0x52553301`）非零命中，未重跑 main。r4 只改启动令牌权限，不再重编测试；r3 结论不计为 r4 新套件结果。
3. 已完成：r3 复跑受影响远程子集（取消后正常输入、330 次 split/resize、目标丢失回收 15/15 干净退出），52 图已读并以旧失败原件对照；W09/W12 增强后复验通过。
4. 不改变 GTK 生产路径的 Win32 专用修复复用 `38e3e644f` 证据；若共享修改实际影响 GTK，再补对应编译与定向。不得因 commit 或文档变更全量重编。
5. r4 已离线打包（不加 `--build`）并安装；r3 卸载无残留，JumpList 与接收器配对通过。medium→high 真实拖放的文本取消、允许不追加回车与多行保护取消已通过。同用户 direct 三向（medium→medium、high→medium、high→high）最小文本拖放均 native 与读图 PASS（`F/vm-resume-20261018-direct/`），与 broker 合计为 F6 四方向最小文本矩阵 PASS_SCOPED，不扩大为原完整 files/URI/DPI 矩阵。三个 app 已正常关闭，注册 inspect 通过，r4 最终卸载无残留（Win11 卸载属于本次功能门，未延期）。Toast 热激活已通过；冷激活原生部分成立，但前台提示在 r4 上 FAIL。r5 已 review、构建一次 app 与 test-bin、定向 23/23 通过并离线打包。inst-r5 安装后热激活与冷激活均已复验通过：冷激活提示历史目标不可用，前台可见并保持 21 s 以上，Esc 关闭后 toast-server 正常退出，未开新 shell。无激活 15 s 退出（单独 idle guard，不代冷点击）与 r5 最终卸载均 PASS_SCOPED，VM 已 owned stop 关闭、磁盘保留。本条工作已全部完成。早期关闭探针先明确请求是否送达，不能以超时猜产品根因。
6. 完整框架单测已于 10-18 集中运行一次（结果与原日志见「当前状态」，唯一 FAIL 为 KB 新鲜度），fmt-check、fluent-check、graph-check 在 r5 修改前已 exit 0，图谱已按 r5 两源变化重建；r5 源码冻结后 graph-check 与 fmt-check 重新 exit 0（本轮工具记录），i18n、pinyin、fluent 真源未变且 check exit 0。root 已运行 `just kb` 并只补跑 `python -m unittest scripts.test_agent_kb.RealCorpusTests`，6/6 通过（`F/kb-final-20261018.log`）；本次状态更新随交付记录再次生成并校验 KB，精确本地提交；不运行会重复 936 项的 `just framework-check` 或 `just ci-check`，936 项整框架只在 10-18 运行过一次，其 KB FAIL 原件保留，组合证据只写实际执行的命令，不冒称重跑 936 项或聚合命令运行过。原 `ci-check` 的 VT、独立 POSIX、Win10/升级、硬件/性能/macOS 与正式 142 叶签收按已批准延期表保留 PENDING；P4 保留既有 FAIL。

每项逐条记 PASS / FAIL / PENDING / BLOCKED / N/A 并附原件；未运行项写补验命令与理由，不写假绿。
