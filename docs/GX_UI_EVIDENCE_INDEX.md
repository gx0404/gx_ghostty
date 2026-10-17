# GX UI 后续实施证据索引

核对日期：2026-10-14（R6 文档收口）。整体状态：**not_complete**。本文件是实施中的独立证据导航，不修改原验收范围，不代替任务账本，也不重开原 37 份源码审计。

## 1. 真源与证据边界

- 完成合同：`docs/GX_UI_REMAINING_PLAN.md` 第 6—9 节；进度补充：`docs/GX_UI_HANDOFF_PLAN.md` 第 9 节。本轮用户确定的并行实施、默认恢复关闭、`-e` 独立、Docker 测试机、DComp 默认关闭，以及 2026-10-14 起的本地阶段 commit 授权（仍不 push、不建 PR/Issue/tag/release、不新增下载），优先于旧计划的历史授权措辞；任务组织见 `docs/GX_UI_EXECUTION_PLAN.md`。
- 本轮执行账本：`.local/evidence/R5/execution-20261013/tasks.json`。总状态仍为 not_complete；批次 PASS 只证明明确选中的范围，P4 保留历史 FAIL。
- 原叶需求账本：同目录 `leaf-matrix.json`，共 **21 组、142 叶**，其中 Windows R2 为 117 叶、GTK R3 为 25 叶；`results={}`、`case_to_leaves={}`，最终逐叶状态仍全部 PENDING。该文件保留原候选 `d6f9e1c…` 身份，同时另记本轮基线，不能把两个树当成一个最终树。
- 本轮已提交 `8a2b4bb59`、`de3149e1f`、`03c8e138f`、`c9dd5eb7c`、`ff41652c2`、`b0de75a1b`、`84671b9b6`、`f55771d84`、`432f91eb4`、`3aeb28f15`、`d5c4f911d`、`5fd3a2741`、`eb2f37d2e`、`aa9fec9d7`；2026-10-18 核对时 HEAD 为 `aa9fec9d7`，`5fd3a2741` 保留为本轮开工核对身份；`src/apprt/win32/App.zig`、`src/apprt/win32/ShellIntegration.zig` 的冷激活提示最窄修复已独立 review PASS、构建为 r5，并单独提交为 `aa9fec9d7`（两文件冻结哈希不变，全部 `src/**` 已提交，当前实树源码与 r5 构建字节相同）；r5 构建身份仍是 `eb2f37d2e` 加这两个文件的哈希，不倒写为构建于 `aa9fec9d7`；r4 哈希保留为历史证据；文档、KB 与图谱由 root 最终提交。构建身份始终用当时 HEAD 加文件摘要，不回写历史 receipt。
- 最新已构建候选为 r5（第 2.0 节 r5 行；关键 GUI、无激活退出与最终卸载均已通过，限定范围）；此前 r4 为 `zig-out-delivery-r4/bin/ghostty.exe`（SHA256 `eece67e02e54823a8336849359776c86fe1195c1fef4d721c146f40013c37e90`），只在 r3 `95d7a015…8eba`（50 项定向通过）基础上改接收器启动令牌权限。此前 `zig-out-delivery` 的 `cc2edbc9…663f76` 证据仍绑定其自身。`candidate-20261014-0250` 与 windows-app-06 为历史证据。
- r3/r4 图谱已用钉版生成器重建并包含远程模块；35 处头文件解析警告仍为覆盖限制。后续诊断源码有变，最终需按指纹检查决定重建；技能版本警告不触发工具升级。

本文用 U 表示纯逻辑或定向测试，N 表示实际原生调用，G 表示真实交互及已读截图，P 表示原性能合同。U/N 不代 G，构建成功不代运行，单个 G 不代 142 叶，运行器退出 0 不代读图。下面各表中的 PENDING 指**完整任务验收**；已有子证据单独注明。

证据目录缩写 `E` 仅指 `.local/evidence/R5/execution-20261013/`，`W` 指 `src/apprt/win32/`，`G` 指 `src/apprt/gtk/gx/`，`K` 指 `src/apprt/gtk/class/`。这些是仓内路径，不是额外真源。

## 2. 本轮已经能证明的范围

### 2.0 后续修复与已验范围（2026-10-18 核对）

本节 `F` 指 `E/final-r2/`。以下结果均为限定范围，未关闭原完整验收门。

| 证据入口 | 实际结果 | 限制与后续 |
|---|---|---|
| `F/delivery-r3-identity.json`、`F/delivery-r3-targeted.json` | 合并 app/test-bin 构建通过；受影响 50/50，seed `0x52553301`、jobs 2；补丁/测试根 89 项通过 | `95d7a015…eba`；覆盖退出队列、映射 ACK 寿命、取消、令牌配对和输入队列。本条构建与单测本身不代真实场景或打包，后续完成证据见本节远程、打包及 VM 记录 |
| `F/paste-input-target-verified-manifest.json` 与 Debug/ReleaseFast 日志 | 精确生产源码小入口各 7/7；修复 ReleaseFast 的 paste T=9 被覆盖为 1 | 已提交 `c9dd5eb7c`；不代所有远程交互 |
| `F/delivery-remote-subset/review-root.json` | 9 native checks、4 图通过；外部 MTA、once、performable、选择复制、安全粘贴 | app `cc2edbc9` |
| `F/delivery-r3-remote/review.json`、`review-root-spotcheck.json`、`F/windows-visual-review/review-r3-spotcheck.json` | r3 取消后输入 PASS；回收后退出 15/15；330 次分屏与布局变化无非预期断连 | 52 图已读完：附加 25 图见 `review-remaining.json`（10 PASS、15 张历史夹具失败图无异常、0 视觉失败）；r1—r4 的新夹具错误有独立说明，不改写旧产品失败 |
| `F/delivery-r3-package-identity.json` | 离线 setup 与 zip 生成并核包内 exe SHA；setup `17a4dca5…`、zip `c9e0aa2c…` | 首次 ISCC GUID 转义失败已修复；104 打包/发布契约测试（6 skip）；VM 安装与卸载见下方 r3 行 |
| `F/delivery-r3-framework.log`、`delivery-r3-kb-recheck.log`、`delivery-r3-generated.log` | 929 框架测试（17 skip）仅 KB 过期失败；重建后仅复跑失败类 6/6；生成物检查 PASS | 保留首次失败，不重跑无关全套；图谱 35 处头文件解析警告记录为工具覆盖限制 |
| `F/delivery-remote-full/review.json` | source-loss-r4 19 PASS/1 FAIL；target-loss-r4 7 PASS/1 FAIL；27 图已读 | 取消粘贴注入控制键、回收后退出崩溃；另 r3 偶发映射替换断连。三项修复已在 r3 复验通过，原 FAIL 保留 |
| `F/gtk-lifecycle-fix2-full/`、`F/gtk-lifecycle-fix2-restoreprobe-a/`、`F/gtk-lifecycle-fix2-restoreprobe-b/`、`F/gtk-lifecycle-fix2-gscenarios/` | 快照 `38e3e644f`：生命周期 38/38、20 图由 Opus 逐张审阅；恢复探针 7/7、6/6；受影响 G15/G16 通过 | 原 PID/birth/PTY 保持、关闭旧窗仍可输入、双 quit=0；只证 Xvfb 软件路径，combined build receipt 为 non-install |
| `F/uia-uac-targeted.json` | 103/103 PASS，seed `0xf66f6cc7` | 包含 UIA 寿命、叶关闭与 UAC 身份模型；不代真实 VM 接收器启动 |
| `F/resume-w-repairs/*/review-root.json` | W06/W07/W14/W16 修复验证，19 图已读 | `d433edce` 候选，后续无关改动按影响复用 |
| `F/delivery-session-ipc/review-root.json` | 4 native 组、7 图通过 | 单实例复用、`-e` 独立、恢复默认关闭、自定义 profile 每次确认、Quit 保留和关闭清空 |
| `F/delivery-w20/W20/review-root.json` | 23 步、6 图通过 | 关闭与切标签后无旧尺寸提示，观测 0.530/0.509 秒早于 0.750 秒超时；真实 resize 提示保留 |
| `F/delivery-windows-gaps/review.json`、`F/delivery-windows-w09-w12/review.json` | W01/W15/W16 通过；W09/W12 增强夹具后通过，4 张新图已读 | W09 区分初始焦点与两次切换；W12 在物理松开前已观察到释放；没有放宽次数要求 |
| `F/delivery-popup-uia/review-opus.json` | 21 native 检查、13 张 screen 图已审阅；6 次外部 MTA；DComp 关闭/开启/reset/五故障回退 | 3 张像素与 legacy 相同，不能单凭图分辨后端；后端状态与其余图另列，字体约 1 px 差异原因未定，不代性能门 |
| `F/vm-resume/BROKER-CGL-CONCLUSION.md` | 真实 split-token 菜单可见，接收器启动 FAIL：1346，后续配对 BLOCKED；旧 GL 关闭漏查退出码，已撤销其正常退出 PASS | 新探针确认正确 HWND/CloseMainWindow=true，崩溃偏移与宿主同为 `0x145992`；r3 launcher 真实复验仍 err=5；退出清理已三次退出0；r4 接收器启动与配对已通过（见下行），不能把旧超时猜作死锁 |
| `F/delivery-r4-identity.json`、`F/delivery-r4-package-identity.json` | r4 app `eece67e0…7e90` 构建 exit 0，相对 r3 只改接收器启动令牌 `0x0B`→`0x18B`（Leaf 仅换行符）；离线 setup `de2a8101…c9ea`、zip `9d440ea5…fc25f`，包内 exe 哈希一致 | r3 的 50 项定向与远程/GUI 证据只覆盖未改逻辑，不计为 r4 新套件；Toast 诊断 app `435c87aa…236e`（`F/toast-diag-identity.json`）不作最终包，四个诊断源码文件已精确撤回，补丁留存 `F/toastdiag-final.patch` |
| `F/vm-resume/guest-out/inst-r3--gxadmin--20261014-072851-661-install.json`、`…-085738-054-uninstall.json`、`r4-owned-files-residue-post-uninstall-r3.json` | r3 安装 exit 0、注册齐全；卸载 exit 0，AppPath/Background/Directory/ShellAumid/ShellClsid 均不存在，`Apps\inst-r3` 目录不存在 | PASS_NATIVE_SCOPED；r4 最终卸载见第 2.0 节冷激活行之后 |
| `F/vm-resume/guest-out/inst-r4--gxadmin--20261014-090045-197-install.json`、`…-091411-809-broker-peer.json` | r4 安装 exit 0、用户范围、未提权，app 哈希核对通过；提权 host 10180 经菜单启动 receiver 8260，双向关联认证与配对 PASS（high 567492 / medium 567552，同 SID、会话 1） | 首次 peer 因夹具引号匹配 FAIL，原件保留，改 CommandLineToArgvW 后重跑通过；PID 为 10-14 历史值，不代今日运行；实际拖放结果见下一行 |
| `F/vm-resume-20261017/45-cancel2-preview.png`—`47-cancel2-receiver.png`、`49-allow1-preview.png`—`51-allow1-receiver.png`、`58-multiline2-broker-preview.png`—`60-multiline2-after-cancel.png`、`62-multiline2-receiver-cancelled.png` | r4 medium→high 真实 DoDragDrop 的文本取消（Step `20261017-092401-564`，source 7884，图 45—47）、允许后不追加回车（Step `20261017-092721-251`，source 1908，图 49—51）与多行保护取消（Step `20261017-093752-026`，source 8276，图 58—60、62，root 逐图已读）PASS；来源 COPY 准入与 GUI 完成回执分开判定 | 本次运行身份：high host 4844（birth 134367489947377883）、receiver 4492（birth 134367490645127172），r4 app 哈希未变；multiline1 超时保留 unknown，53—57 不计为及时取消 PASS；同用户 direct 三向结果见下一行 |
| `F/vm-resume-20261018-direct/06-mm-no-enter.png`、`11-hm-no-enter.png`、`17-hh-no-enter.png`；`.local/windows-vm/win11/exchange/validation/out/` `inst-r4--gxadmin--20261017-<Step>-drop-source.json` | 同用户 direct 三向 native 与读图 PASS，root 抽读 3 张关键图：medium→medium（Step `100024-587`，source 2664，target 4160）、high→medium（Step `100827-603`，source 9524，target 4160）、high→high（Step `101336-184`，source 5616，target 4844）；每次 COPY（effect 1）、GetData 1、release 1、source exit 0，marker 停在原行，未注入 Enter | medium target 4160 birth 134367299262570425，high target 同 4844；high→medium 首次 `100319-056` 在源启动前因 controller 继承错误的 LOCALAPPDATA 安全 FAIL，只修该控制台临时环境后重试，不是产品拖放失败，原报告与图 08 保留；夹具已提交 `eb2f37d2e`；与 broker 合计为 F6 四方向最小文本矩阵 PASS_SCOPED，不代原完整 files/URI/DPI 矩阵 |
| `F/vm-resume/handoff-r3.txt`（JumpList 与 Toast 段）及截图 win11-91…139 | JumpList 键盘打开，选择 PowerShell 启动配置在同一进程 2912 新开窗口，PASS；原生同 AUMID 探针（104）、诊断版（120—122）与 r3 原版重启对照（136）均显示横幅 | 早期三次 OSC 未显示（92—98）保留 FAIL，原因不明，不宣称诊断日志修复；诊断版热激活未核到产品侧日志；当前热、冷激活结果见下一行 |
| `F/vm-resume-20261017/70-toast-hot-banner.png`、`71-toast-hot-center.png`、`79-toast-hot-item-focus.png`、`80-toast-hot-activated.png`、`81-toast-cold-banner.png`；`.local/windows-vm/win11/exchange/validation/out/` `r18-toast-start.json`、`r18-toast-hot-result.json`、`r18-toast-source-exit.json` | Toast 热激活 PASS：用键盘在通知中心选中并激活（图 70、71、79、80，root 已读），`r18-toast-start.json` 与 `r18-toast-hot-result.json` 的 PID 3068、birth 134367290904078802、HWND 1900866 一致，r4 app 哈希一致，激活后 app 进程恰为 3068/4492/4844、无新 app，图 80 原终端获焦；冷点击通知已显示（81）并留在通知中心，source 3068 exit 0 | 图 72 的坐标点击未命中（图 74 通知仍在、光标未动），不记产品 FAIL，也不记点击成功；冷点击合同为提示历史目标不可用并退出 toast-server、不开新 shell，cold2 结果见下一行；早期三次未显示仍 FAIL |
| `F/vm-resume-20261017/90-cold2-banner-history.png`—`96-cold2-closed.png`；`.local/windows-vm/win11/exchange/validation/out/` `r18-toast-cold2-source-exit.json`、`r18-toast-cold2-history.json`、`r18-toast-cold2-start.json`、`r18-toast-cold2-exit.json` | 原生部分成立：source 6180 exit 0、`app_pids=[]`；历史 XML 带原生 token；OS 真实启动 7120（birth 134367322172516267，`--gx-shell-action=toast-server -Embedding`，r4 SHA，`children=[]`）并 exit 0 | 关键 GUI 门 FAIL：图 94、95 无前台提示，原始 `#32770` 在其他窗口后，被 15 s watchdog 结束；原因已定位为 MessageBox 只用 ICON_INFORMATION、计时器无条件 PostQuit；2 文件最窄修复已构建为 r5，复验通过见下方 r5 GUI 行；r4 上不记 cold PASS，原 FAIL 保留为修复前证据 |
| `.local/windows-vm/win11/exchange/validation/out/` `r18-direct-owned-close.json`、`r18-direct-apps-remaining.json`、`inst-r4--gxadmin--20261017-102047-955-inspect.json`、`inst-r4--gxadmin--20261017-104517-405-uninstall.json`、`r18-r4-uninstall-residue.json`；图 97、98 | 4492/4160/4844 经 CloseMainWindow exit 0，剩余 app 为空；inspect PASS，ShellAumid GxExecutable/IconUri 与 CLSID LocalServer32 指向 inst-r4，medium 令牌；r4 卸载 exit 0，五组注册表键不存在，应用目录不存在、`app_pids=[]` | PASS_NATIVE_SCOPED；只关闭卸载门，不代表 r4 最终验收完成 |
| `zig-out-delivery-r5/`；`F/delivery-r5-build.log`、`F/delivery-r5-test-list.log`、`F/delivery-r5-tests.json`、`F/delivery-r5-tests.log`、`F/delivery-r5-package.log`、`F/graph-20261018.log` | r5 app `f0c80e8cdfe576594eaa222e15ee916f857f9eaeeb2cbe8c166f853ea8b0c3db`（34,956,800 B）、test-bin `8b75f8dc6984b63a5c78b6b73da36ef95173f1a4723de097d5a36067ccef348c`（172,882,432 B）、setup `d94b9a40f10ee32cd151276d0fddb706d5afbe0b438a9113c75ba24d14b3d597`、zip `2d4bd9616249d1dbbedc34db990f7ebaf9303402274f0cf5e875d1a11fc66367`；ZIP 唯一 exe 与 prefix 一致（DeepSeek 复核）；相对 r4 只改 `App.zig`（`2a8736b5aae1321b0bf6eed3a847e6b00100ec9e8f0ab3c4e1749d2610dad266`）与 `ShellIntegration.zig`（`c0dd496f53901202e0bece6883b8404fe5a4e9a4cb647362be18625848f37de3`），修复独立 review PASS；正确引用版本参数后的合并构建工具记录 exit 0（工具 session 66398，无 stdout 日志文件）；定向 23/23、0 skip（seed `0x52553501`，jobs 2，3 个 filter）；package exit 0；图谱按两源变化重建 exit 0 | 首次 build.log 因 PowerShell 拆分配置参数报 InvalidVersion、未编译，原件保留；二进制发现 5056 项，只跑 23 项，不等于全量；GUI 结果见下一行；r4 历史失败与矩阵证据不回写成 r5 新运行，未受影响部分按范围复用；源码已单独提交 `aa9fec9d7`，r5 构建身份仍是 `eb2f37d2e` 加两文件哈希；文档、KB、图谱由 root 最终提交 |
| `F/vm-resume-20261017/102-r5-hot-banner.png`、`103-r5-hot-selected.png`、`104-r5-hot-activated.png`、`108-r5-cold-visible.png`、`109-r5-cold-after-22s.png`、`110-r5-cold-dismissed.png`；`.local/windows-vm/win11/exchange/validation/out/` `inst-r5--gxadmin--20261017-110227-045-install.json`、`r18-r5-source-start.json`、`r18-r5-hot-result.json`、`r18-r5-cold-history.json`、`r18-r5-source-exit.json`、`r18-r5-cold-start.json`、`r18-r5-cold-exit.json` | r5 关键 GUI PASS（图在 `F/vm-resume-20261017/`，原生 JSON 在 `.local/windows-vm/win11/exchange/validation/out/`）：inst-r5 安装（`inst-r5--gxadmin--20261017-110227-045-install.json`）exit 0、app 哈希 `f0c80e8c…c3db`、五组注册表正确；热激活 source PID 5412（birth 134367340058015314，HWND 1245934）在 `r18-r5-source-start.json` 与 `r18-r5-hot-result.json` 中一致且只有 5412 一个 app，图 102 横幅、103 选中、104 原窗口获焦（root 已读）；通知历史为原生 gx-toast-v1 XML（`r18-r5-cold-history.json`），source 5412 exit 0、apps 为空（`r18-r5-source-exit.json`）；OS 冷激活新进程 5976（birth 134367345580780184，`--gx-shell-action=toast-server -Embedding`，r5 SHA，`children=[]`），`r18-r5-cold-start.json` 显示前台窗口就是它的 `#32770`（HWND `0x15020e`）；图 108 与 109 相隔 21.36 s，提示「这条通知对应的终端已不可用。」一直在前台可见（root 逐图已读），手动 Esc 后图 110 提示消失，`r18-r5-cold-exit.json` 显示同一 5976 正常 exit 0 | PASS_SCOPED；r4 的前台与超时 FAIL 保留为修复前证据；早期三次未显示仍为历史 FAIL、原因不明；Astra 独立复审图 108、109、110、原生身份与 23/23 报告 PASS；无激活退出、r5 卸载与 VM 停止见下两行 |
| `F/vm-resume-20261017/112-r5-idle-uninstall.png`；`.local/windows-vm/win11/exchange/validation/out/` `r18-r5-no-activation-timeout.json`、`inst-r5--gxadmin--20261017-111936-284-uninstall.json`、`r18-r5-uninstall-residue.json`、`r18-r5-uninstall-residue-after-wait.json` | 无激活 idle guard 单独验证 PASS_SCOPED：`r18-r5-no-activation-timeout.json` 中 PID 7484（birth 134367347566290408）、r5 哈希，15078 ms 后 exit 0；它只证明没有激活时 15 s 后退出，不代 OS 冷点击；r5 最终卸载 PASS_SCOPED：`inst-r5--gxadmin--20261017-111936-284-uninstall.json` exit 0，五组注册表键都不存在；卸载后立即检查的 `r18-r5-uninstall-residue.json` 显示应用目录仍在（卸载器自删除窗口，原件保留），随后复查 `r18-r5-uninstall-residue-after-wait.json` 显示应用目录不存在、`remaining=[]`、`app_pids=[]`，期间没有手动删除；图 112 root 已读 | PASS_SCOPED；idle guard 不代 OS 冷点击；即时残留检查的 appdir=true 原件保留，不改写 |
| `F/win11-stop-20261018.log` | VM 已经 owned stop 关闭：`final-r2/win11-stop-20261018.log` 显示 owned=true、完整容器 ID `a8771d3f901916c03885e735204f6971df1c5315ba023fb7a37b4f738516d6df`、running=false、status exited、exit 143、oom=false、binding_errors 为空；stop 命令 exit 0，heavy guard session 9120 已 exit 0 释放，磁盘保留，停止前已复核 UUID `466cf44f-4c70-4863-80a6-cc0b10aa8103` 匹配。这个 143 是容器停止状态，不是客机应用崩溃，应用关闭与卸载的 exit 0 另有证据 | exit 143 是容器停止状态，不混作应用退出码 |
| `F/vm-resume/INCIDENT-test-docker.md` | 单测误操作导致 VM 异常关机，真实存储未丢失；修复测试 11/11 | 容器精确归属校验与测试 subprocess 隔离已提交 `03c8e138f`，原事件仍保留 |
| `F/identity-20261017.json`、`tasks.json` 的 `resume_20261017` | `src/**` 1223/1223 与 r4 构建前快照一致；r4 app/setup/zip 与 r3 test-bin 哈希全部匹配；10-17 framework 日志 936 项（17 skip）通过（历史，已被下一行 10-18 结果取代）；Win11 原容器复用重启，live UUID 匹配，heavy session 9120 | 只证身份连续、无需重编，不新增测试结论；10-14 的客机 PID 不代今日运行 |
| `F/framework-20261018.log` | root 用 `python scripts/gx_slots.py --kind heavy -- python scripts/run_unittests.py --jobs 2` 集中跑完整框架单测：936 项、17 skip，唯一 FAIL 是 `test_agent_kb.RealCorpusTests.test_checked_in_kb_is_fresh`（新文档后尚未生成 KB），其余通过；原日志 `final-r2/framework-20261018.log`，wall 436.36 s。这次记 FAIL，不是 PASS，也不是 15 s 级的快速检查 | `just fmt-check`、`just fluent-check`、`just graph-check` 在 r5 两文件修改之前由 root 运行，exit 0；修改后已按两源变化重建图谱（`final-r2/graph-20261018.log` exit 0，35 处头文件解析限制不变）；r5 源码冻结后 graph-check 与 fmt-check 重新 exit 0（本轮工具记录），i18n、pinyin、fluent 真源未变且 check exit 0；root 已运行 `just kb` 并只补跑 `python -m unittest scripts.test_agent_kb.RealCorpusTests`，6/6 通过（`F/kb-final-20261018.log`）；本次状态更新随交付记录再次生成并校验 KB，精确本地提交；不运行会重复 936 项的 `just framework-check` 或 `just ci-check`，936 项整框架只在 10-18 运行过一次，其 KB FAIL 原件保留，组合证据只写实际执行的命令，不冒称重跑 936 项或聚合命令运行过 |
| `F/evidence-resume/reconciliation-20261014.json`、`F/evidence-resume/leaf-map-draft.json` | 142 叶映射草稿、来源摘要与缺口分类；草稿中 52 叶仍只有流级证据（`counts.flow_level_only_after`），如实保留 | 正式 142 叶签收已由用户批准的 180 分钟方案列为延期门，本次交付保留 PENDING，不逐叶重验、不为此新建场景；两份 JSON 保留 2026-10-14 生成时的历史身份，不倒改旧报告 |

### 2.1 历史完整候选 final-r2（`candidate-20261014-0250`）

`F` 指 `E/final-r2/`。该候选由 2026-10-14 约 02:46 的工作区一次构建（`F/final-build.log`；此前 `F/m1-build.log` 的 ReleaseFast 测试构建 9 处编译错误作为失败原件保留）。此后 root 继续修改 App、Surface、Window、Palette、SearchBar、Remote* 与 runtime helper（`F/app-review/` 留有 10:31 的快照与 diff），新快照 `80fd77531` 在唯一主树构建到 `zig-out-resume`（含 install、test-bin 与 `-Demit-webdata`；不覆盖 02:50 产物，非完整 main）：首编 session 48133（源快照 `F/evidence-resume/source-snapshot-20261014T025803Z-ecdac2400-resume-prebuild.json`）**FAIL**，4 处接线错误由 root 修复；修复编译 session 44734（源快照 `...T030359Z-ecdac2400-resume-repair-prebuild.json`）**尚未编译通过**，同目录另有 `T030732Z` repair2 快照，其构建结果待 root 确认；**新源码未经验证前，下表结论不继承到当前工作区**；`F/windows-fixtures-resume/` 下基于旧 02:50 产物的预演只用于调通夹具；Windows、GTK 完整 main 各已运行一次，按计划不重复，新编译后只重跑受影响的定向测试与场景。

| 证据入口 | 实际结果 | 能证明的范围与限制 |
|---|---|---|
| `F/windows-main-final.json`、`.log` | 完整 Windows main：总 5017，PASS 4942，SKIP 73，FAIL 2；seed `0xdfd10e41`，jobs 3，二进制 `zig-out-final/test/ghostty-test.exe` | 2 个 FAIL 都是 `lib.tinyio` 符号链接用例的 `PermissionDenied`（未开开发者模式），记环境 FAIL，不跳过、不改用例；只绑定该候选源码 |
| `F/gtk-main-final.log` | 完整 GTK main（WSL）：总 4533，PASS 4480，SKIP 53，FAIL 0；seed `0x6bdde806`，jobs 1 | 绑定当时同步到 WSL 克隆的源码与 `F/gtk-build-final.log`；不代硬件、Wayland 或 IME |
| `F/windows-targeted.json`、`.log` | 运行器汇总 226 PASS、0 skip，seed `0xa727726b`，jobs 2；**其中 105 项来自误带的默认旧二进制，属于当前候选的只有 121 项 PASS** | 只能按候选二进制的 121 项理解远程服务、Quick 末标签、protected paste 回执、broker 粘贴确认等所选用例；226 不得合计为最终证据 |
| `F/w0/w0-targeted.json` 与日志 | 历史 W0 定向 161/161 PASS | 只覆盖 W0 当时的源码，独立保留，不与 final-r2 或后续批次合计 |
| `F/remote-normal-window/report.json`、`review.json` | native 7 个检查 PASS，4 张图已读，`PASS_SCOPED`；app SHA256 `536afb0b09a01aef3c6667f18470dba8b5d144e75be36d505926ab44f256347e` | 两个独立宿主的普通窗口迁移、远程输入进原 shell（PID/birth 不变）、远程窗格旁新建本地分屏、目标进程被结束后原 core 恢复且命令只启动一次。3 张图是 PrintWindow，只证可读内容；不证 IME、OLE、MTA UIA、protected paste、拖回、session 重启与源故障 |
| `F/windows-scenarios/SUMMARY.txt` 与各 `notes.txt` | W01—W20：17 个场景步骤通过，W06 SKIPPED（需 `--allow-side-effects`），W07、W14 FAILED | 步骤通过不等于 GUI 通过；本轮有书面逐图结论的只有 W16（见下一行），其余场景的图读完前记 PENDING。W07 旧 expect 仍按模态对话框写，产品早已是非模态 Notice（D12），场景已改写，root 另修了失败终端关闭后清除自己的提示；W14 Nord 预览取色 `#1f1f28`≠`#2e3440`，root 已修预览代码；两者待新编译复验（`F/repro-w07-w14/` 为修前复现） |
| `F/windows-scenarios/W16/review-root.json` | 视觉 **FAIL**：7 张图已读；右侧锚点、快捷键分类与键帽、设置六分区 PASS，键盘打开主菜单时首项「New Tab」没有可见高亮 | expect 要求首项高亮；root 已修键盘入口 Window 为 null 的源码，待本批编译后新验，此前 W16 不计入 GUI 通过 |
| `F/gtk-scenarios/SUMMARY.txt` 与各 `notes.txt` | G01—G16 全部步骤通过 | Xvfb 软件路径、Debug、GTK 4.14.5/libadwaita 1.5；Opus 审阅者已读完 16 组图，限定 PASS（书面记录由证据工位写入 JSON）。不代 G15 的 PID/PTY 恒等、session 重启、管理器 CRUD、硬件、Wayland 或 IME |
| `F/contracts-resume.log` | 框架定向 247 tests，9 skip，OK | 10:01 时的脚本与契约子集；不是 `just framework-check`，其后文档与脚本变化须重跑 |
| `F/source-manifest.{json,md,txt}` | 00:31 的源快照清单（HEAD `ecdac2400…`、143 个身份文件） | 只描述那一刻的工作区，不是 final-r2 构建的源身份 |

### 2.2 历史批次（只证明各自快照）

| 证据入口 | 实际结果 | 能证明的范围与限制 |
|---|---|---|
| `E/windows-22.log` | PASS：569/569，0 skip，seed `0x52553049`，jobs 2 | 本地 Pane、DropBridge/Companion 接线及受影响 Windows 子集；不是完整 main，晚于此批的确认视图寿命修复待另验 |
| `E/bell-native-01/results.json`、两份 native 文本 | 限定 N PASS：5/5，0 skip，seed `0x5255304a`，jobs 1 | batch22 二进制、RTX 5080 真实隐藏 GL/FBO、context 重建及 idle worker 产帧；不是桌面 DWM 边框验收 |
| `E/remote-app06-01/review.json` | 限定 N/G PASS：两进程单叶迁移及断连恢复，3 图已读 | 原 core ID、terminal HWND、cmd PID/birth 与单次启动保持；源普通窗口关闭后后台宿主仍存活。仍为专用远程窗口，非普通窗口 local/remote 混合树 |
| `E/popup-uia-current-user-01/review.json`、`uia-root-app05/report.json` | 限定 N/G PASS：popup 13 图、6 次外部 MTA、5 个 DComp 故障阶段；root 非客户区去重复验通过 | 不代读屏、Notification 事件、Win10、WARP 或性能；保留此前前台激活失败原件 |
| `E/ole-source-window-app05-01/review.json`、`ole-source-window-app05-02/review.json` | 限定 N/G PASS：真实外部 DoDragDrop，8 图已读 | 同权限 text/multiline/files、默认取消保护与路径引用；不代跨权限四方向 |
| `E/gtk-app-08.log`、`gtk-gui-08/review.json` | 构建及 G15/G16 限定 G PASS：4 图已读 | WSL 快照 `0ea5f8303`；既有分屏内容移入新标签、中文 profile manager 可打开；不代迁移 PID/PTY、CRUD 或重启 |
| `E/innosetup-setup.log` | PASS：钉版 7.1.0 便携工具安装与摘要校验 | 仅工具准备；不代安装包编译或 VM 安装/升级/卸载 |
| `E/windows-12.json`、`windows-12.log` | PASS：557/557，0 skip，seed `0x5255303c`，jobs 3 | 当批 `apprt.win32`、引用、IPC、session、全拼、Fluent、编辑模型及 toggle 选中用例；不是完整 main，也不包含后来所有修改 |
| `E/windows-13.json` | PASS：530/530，0 skip，seed `0x5255303e`，jobs 2 | 当批 win32、session、shell startup、argv、remote_view 子集 |
| `E/windows-14.json` | PASS：558，SKIP：5，总选中 563；seed `0x52553041`，jobs 1 | win32、session、Shell、远程模型和 WGL 选中范围；5 个显式启用的 BellBorder GL 用例未运行，不能称“全部 native GL 通过”；该批也不覆盖随后 session OOM 第二阶段修复 |
| `E/windows-app-04.log` | PASS：标准 app 构建 | 绑定上节 app04 哈希；不是安装包、最终全部测试或 GUI 总门 |
| `E/gtk-interfaces-02.log`、`gtk-04.log`、`gtk-05.log` | PASS：81、26、104，各 0 skip | 分别绑定快照 `479c38195`、`f9a526817`、`207362f94` 的选中范围；不累加成最终完整 suite |
| `E/gtk-06.log`、`gtk-07.log` | PASS：91/91、16/16，均 0 skip | 分别绑定 `e1c50a811`、`fbde5c1f2`；后一批为 session 等定向验证，不代真实多轮重启 |
| `E/gtk-app-05.log`、`gtk-app-06.log` | PASS：GTK app 构建记录 | 保留各自 WSL build receipt/快照；不能用当前 Windows 工作区替代其构建身份 |
| `E/windows-gui-02/W01/run.json` 与该目录 3 张图 | 限定 G PASS：标题覆盖、OSC 标题后保持、清空后跟随 | app 第 1 批的标题场景；不证明 DComp、UIA、session 或其余 W01—W20 |
| `E/gtk-gui-05/review.json` | 限定 G PASS：G05/G08 共 4 图 | `207362f94`，Debug Xvfb 软件路径；标签/分屏及启动菜单条目，不证明 Wayland、真实迁移身份、manager CRUD |
| `E/gtk-gui-new-01/review.json` | G15 限定 PASS；G16 FAIL | G15 仅看到既有输出进入第二个 tab，PID/PTY 未证明；G16 原按键没有打开管理器，不能被 runner exit 0 覆盖 |
| `E/gtk-gui-manager-02/G16/` 与对应 `.log` | 运行器 exit 0；独立视觉结论 PENDING | 该目录有新原生运行/图像证据；本索引未据此自行签署读图或完整 CRUD 通过 |
| `E/windows-session-fixture-02/report.json` | 限定 N PASS：普通 launcher 复用、`-e` 独立、默认 off 保留文件；custom FAIL | app02；PrintWindow 图仍 PENDING，不代 GL/DWM 上屏 |
| `E/windows-session-fixture-04/report.json` | 限定 N/G PASS：两次 custom 恢复每次确认、Quit 保留、关闭写空；4 图已读 | app04，同私有状态更新 PID/birth；不覆盖嵌套树、所有来源、CLI、写失败与双 writer 全矩阵 |
| `.local/evidence/R5/uia-readonly-root-app04/` | 限定 N PASS：外部、无 HWND 的 MTA 查询 | 共 18 节点，其中 11 个 `gx-` 自定义节点，包含 Window/Tabs/terminal pane；未 activate、未发键鼠、无截图。实际发现重复非客户区标题栏，后续修复尚待新 app 复验 |
| `.local/evidence/R5/popup-uia-dcomp-app04/report.json` | FAIL：前台 HWND=0、激活失败 | 未发输入、未查询 popup、无截图；自有实例正常关闭。此次失败不意味着桌面永久不可用，也不能绕过守门重试成绿 |
| `.local/evidence/UI-implementation-20261013/ole-text-first/report.json` | FAIL：受控 OLE text 首次场景在激活守门停止 | app04 与外部 source 各有哈希；无截图、未读剪贴板、未注入 Enter、自有 app 正常关闭。不能据 source 程序存在称真实 Drop 已通过 |
| `.local/evidence/R5/DComp/native-contract.json`、`.local/dcomp-native/source-sha.json` | 限定 N PASS：7 个测试条目 | 包含实际隐藏 layered HWND 的 hardware D3D/D2D/DComp、借用 context、EndDraw/Commit、阶段失败与帧代次合同；不是实际 popup 上屏、WARP、Win10 或性能证明 |
| `.local/uia-native/source-sha.json`、同目录 harness | 限定 N/U：该次执行 50/50 | 包括 owned snapshot、队列、OLE medium/撤销生命周期；不覆盖其后非客户区 flags 修复，不代真实 OLE 拖动或 UIA 通知接收 |
| `E/contracts-07.log`、`roots-patches-07.log`、`package-07.log` | 定向框架/闭集/打包测试记录 | 139、85、48 项；打包记录另有 6 skip。后续源码/文档变化须重新核真源；不代完整 framework/ci |

必须保留的失败原件还包括 `windows-06` 旧全拼断言、`windows-11` SRW 编译失败、`windows-app-03` 缺 RDW 常量、相对隔离目录的 `windows-gui-01`、session fixture01—03 及 GUI/WSL runner 原失败。修复后的有限子集只关闭对应原因，不删除原证据。

## 3. R5 源码入口与原完整验收门

下表保留完整合同导航；已取得的限定证据以第 2.0 节为准，不能把本表历史待验描述当成当前交付必须全量重跑的清单。

| 合同 | 当前可核源码入口 | 本轮证据与完整状态 | 仍需实现或补验 |
|---|---|---|---|
| R5-00 | `src/gx/ui_ref.zig`、`gui_settings.zig::Overlay.getAll`；W `ComApartment.zig`、`App.zig`、`Surface.zig`；K 生命周期钩子与 G `launch.zig` | 基础 U/N、标准 app 子集已有；完整 PENDING | init/OOM、hide/reopen、modal/COM 返回重查、shutdown、同 private state 多次启动及队列满等必须最终批次绑定；一条通路不代全部 owner |
| R5-01 | W `TabTransfer.zig::run`、`tab_transfer.zig::gesture/reparent`、`Window.zig::moveTabToNewWindow/moveTabToWindow`、`Surface.zig::onReparented` | 源码及定向子集；真实完整迁移 PENDING | 15 DIP 严格边界、横向 10 DIP、混合 DPI、完整树/zoom/override/活动 pane、满 tab、SetParent 重入/回滚；迁移后关源窗，核 PID/birth/PTY/Surface/scrollback 不变 |
| R5-01X | `src/gx/remote_view.zig`、`remote_protocol.zig`、`remote_binding.zig`；W `Leaf.zig`、`Pane.zig`、`RemotePane.zig`、`RemotePaneUi.zig`、`RemoteSource.zig`、`RemoteCoordinator.zig`、`RemoteInput.zig`、`RemoteHost.zig`、`ipc/remote_frame.zig`、`RemoteChannel.zig`、`RemoteService.zig`、`ui/uia_remote.zig`；`wgl.zig::Context.present` GX-0043；`src/Surface.zig` GX-0044 | final-r2 两进程普通窗口迁移、远程输入、混合分屏、目标崩溃恢复 native 7 项与 4 图 `PASS_SCOPED`；完整 PENDING | 普通窗口的 Leaf 混合树、目标交互与源端绑定续延已接线，`RemoteInput` 转发物理键、文本、IME、鼠标与 protected paste 分块；10:00 后的 runtime helper 修改未编译。仍缺：拖回原进程、混合标签拒绝跨进程、IME/OLE/MTA UIA/protected paste/搜索/确认在远程窗格上的真实场景，链式绑定 once/performable/断连取消，输入 ACK 丢失后查询，源进程故障显示与会话剪枝，DWM 上屏（非 PrintWindow）与输入到显示延迟 |
| R5-02 | `src/gx/session.zig`、`session_cwd.zig`；W `Session.zig::tryRestore/onQuit/onWindowClose`；G `session.zig::activate/quit/closing` | app04 两次 custom 恢复限定 PASS；GTK U 与接线；完整 PENDING | 两端多窗嵌套非 0.5 树、zoom/字号/手动标题/合法 cwd、失效 profile、CLI/initial-command、取消关闭、写失败、双 writer、Quick 排除及文件隐私。GTK 真 resize→close→restart 尚需独立场景 |
| R5-03 | W `ui/uia.zig::Publisher`、`uia_bridge.zig`、Popup/Palette/Menu/Settings/Dialogs/Toast 接线；`scripts/gx_win_uia.py` | root/remote/popup 外部 MTA 与 popup 13 图限定 PASS；历史前台失败保留，完整 PENDING | 新非客户区去重修复的外部 MTA 复验；真实 popup Invoke/Selection/Value/Toggle/Expand、旧 provider inert、焦点/IME/modal 压力、Notification 真接收、读屏、Win10 缺 API。不能以 Show/notify HRESULT 代事件 |
| R5-04 | W `ole_drop.zig`、`drop_data.zig`、`ui/DropFeedback.zig`、Surface protected paste 与 App owned queue/延后撤销 | medium/注册/撤销原生合同；完整 PENDING | 外部受控 DoDragDrop 与 Explorer 真源、Unicode/文件/URI/多行保护、不自动 Enter、reparent/销毁。跨完整性 broker 已有生产实现：`src/gx/ipc/drop_broker.zig` 合同、W `ipc/DropBroker.zig` 专用管道、`DropBridge.zig`（高端预览确认后经 protected paste 回执）与 `DropCompanion.zig`（显式启动的 medium 接收窗口，核验目标 PID/birth 与映像）；普通 IPC 的 `policy.authenticate` 仍拒绝不同 elevation。VM 已实测菜单入口；1346 与 err=5 修复后，r4 安装版接收器启动与双向配对 PASS_NATIVE_SCOPED；medium→high 真实拖放的文本取消、允许不追加回车与多行保护取消 PASS_SCOPED（第 2.0 节）；同用户 direct 三向（medium→medium、high→medium、high→high）最小文本拖放均 native 与读图 PASS（`F/vm-resume-20261018-direct/`），与 broker 合计为 F6 四方向最小文本矩阵 PASS_SCOPED，不扩大为原完整 files/URI/DPI 矩阵；拒绝、过期与目标关闭回执按原合同仍未签收 |
| R5-05 | W `ShellIntegration.zig::initialize/notify/drain`、`shell/Identity.zig`、`WinRTToast.zig`、`ToastActivation.zig`；安装器/包装接线 | native/编码与 app02+构建子集；VM r3 安装与无残留卸载、r4 安装 PASS_NATIVE_SCOPED，横幅显示对照通过，Toast 热激活（键盘）PASS_SCOPED，r4 最终卸载 PASS_NATIVE_SCOPED，r4 冷激活原生部分成立但前台提示 FAIL（修复前证据），r5 安装、热激活、冷激活前台提示、无激活 15 s 退出与最终卸载 PASS_SCOPED，早期三次 OSC 未显示保留 FAIL；完整 PENDING | 冷激活前台提示（提示历史目标不可用、用户关闭后退出 toast-server，不开新 shell）已在 r5 复验通过；本次功能门已无余项；升级路径为批准延期；原合同另列多目标 token、DND/禁用、关闭/Quick、多目录 identity；应用内 `ui/Toast.zig` 不代系统通知 |
| R5-06 | W `ipc/Instance.zig::elect`、Client/Server/Security；`src/gx/ipc/`、App 路由、toggle CLI | 普通 launcher/-e 有限 PASS；完整 PENDING | 多 launcher 竞争、ready 前崩溃、退出、冒名 endpoint、不同 root/build/class/install/elevation、重复 toggle、GUI 失败不得 success ACK；GTK D-Bus 真 quick 行为仍独立验 |
| R5-07 | `src/gx/fuzzy.zig`、`pinyin.zig`、`pinyin/inputs/0.15.0/`；`scripts/gx_pinyin.py` | 钉版输入与离线生成、定向算法子集；完整 PENDING | fresh checkout 离线全量再生成/许可随包，三 API 同路径、polyphone/ü-v/高亮边界，Windows 动态 tab/字体与 GTK GX 筛选实际读图；P4 不放宽 |
| R5-08 | W `shell/JumpList.zig`、`ShellIntegration.zig`；`src/gx/windows_argv.zig` 与 startup/profile 路由 | 实现与 native/编码子集；VM 键盘打开 JumpList 并在同一进程新开启动配置窗口 PASS；完整 PENDING | 真系统 JumpList 写入/点击、冷启动、removed profile、语言、路径引用、两目录不串台、Abort 保旧、portable 不自动注册；测试环境变量不能隔离系统列表 |
| R5-09 | `src/gx/fluent/{inputs,model.zig,paths.zig}`；`scripts/gx_fluent_icons.py`；W `ui/fluent_icons.zig`、D2D 与 Settings selected 图标 | 六个 MIT 官方输入、离线生成/几何子集；完整 PENDING | Windows/Linux 字节再生、许可包、真实多 DPI/暗亮/高对比/禁用/选择图、device/factory 资源域；系统 glyph 默认保留 |
| R5-10 | W `ui/dcomp.zig::Device/Backend`、`d2d.zig::Canvas.beginBorrowed/finishBorrowed`、`Popup.zig::paintComposition` | 隐藏 HWND native 合同与生产 popup 图限定 PASS；完整 PENDING | `GHOSTTY_GX_POPUP_DCOMP=1` 明确 opt-in，默认 off；真 popup 的 reset/target/surface/begin/end/commit、先 legacy 补画、size/DPI/generation 首帧、IME/modal/销毁、Win10/WARP/NVIDIA/Mesa 区分、Fluent 共域及 P4 十对 |
| R5-11a | `src/gx/keybind_edit.zig::enumerate/parseValues/apply`；G `shortcut_editor.zig::present`、`app.zig` | GTK 模型与真实 UI 入口已存在；完整 PENDING | 真实录制及执行结果、table/chain/flags、prefix 冲突、下层 unbind、CLI readonly、失败草稿、外部编辑、取消/恢复，中英文暗亮截图 |
| R5-11b | `src/gx/launch_profile_edit.zig::apply/commit`；G `launch_profiles_dialog.zig::present`、`app.zig` | GTK 管理器实现；G16 原失败及修后 runner 原件均保留；完整 PENDING | CRUD/default/rename 引用影响、只读来源、删覆盖后下层重现、跨窗/重开同步、旧 shell 不重启、保存失败和外部编辑；打开窗口本身不代这些动作 |
| R5-11c | G `window_state.zig::install/restore/closing/quit`、session 生命周期、`window.zig::popupNewTabMenu` | 真实 resize→close→restart 几何限定 PASS；完整 PENDING | 真实 resize→close→restart、各轴 CLI、max/tiled/fullscreen 不污染、never/Quick/取消关闭；Wayland 不承诺 XY，需真 WM 环境 |
| R5-11d | G `split_transfer.zig::perform`，K window/split_tree 的空树收养与 listeners | 生命周期 38/38、20 图，PID/PTY 与关旧窗继续输入限定 PASS；完整 PENDING | PID/birth、Surface/PTY/scrollback 恒等，嵌套/zoom/连续移窗、旧窗关闭后 split/title/search 可用、OOM/回滚与迟到 focus |

**Windows 11a/11b 范围说明。** 原合同 R5-11 标题和四子任务明确为 GTK。当前 W `ui/Keybinds.zig` 是速查/查询录制并执行已有动作，未消费 `keybind_edit`；W `ui/Menu.zig::showProfileMenu` 提供启动、分屏和默认 shell 设置，未接 `launch_profile_edit` 管理 UI。因此不能声称 Windows 已有完整快捷键编辑器/profile CRUD；也不能把本次核查自行扩张为原合同没有的 Windows 新必过项。共享编辑模型测试不证明任一平台完整 UI。

## 4. 142 叶分组导航

以下覆盖原账本全部叶 ID 区间，不重新解释或删减叶内并列条件。每行的测试/场景只是导航，最终证据仍须回填原叶 `source/tree`、构建 receipt、命令退出码、raw 与已读图；整组 PASS 不得替代逐叶签收。正式 142 叶签收已由用户批准的 180 分钟方案列为延期门，本次交付保留 PENDING，不逐叶重验、不为此新建场景；仅有流级证据的 52 叶如实保留。

| 叶组与数量 | 当前源码导航 | 本轮可证范围 | 未关闭门 |
|---|---|---|---|
| R2-接口 .01—.06（6） | W Surface/Window/App/Popup；WGL；`src/gx/settings_map.zig` | Windows 定向 U/N；无完整跨模块最终 G | V3/V6、P4/P7 |
| R2-App .01—.11（11） | W `App.zig::performAction/ringBell`、shortcut_conflicts；GX profiles/url_policy | 单实例与 session fixture 仅所列路径；Shell 系统场景未验 | V1/V2/V6、P1/P2/P4 |
| R2-Window .01—.13（13） | W Window/split_layout/caption_layout；GX window_state | 标题/session 有限场景，不代真实移窗/多屏 | V6、P2/P3/P7 |
| R2-Surface .01—.09（9） | W `Surface.zig::readClipboard/confirmClipboard/onReparented/awaitResizeFrames` | OLE/UIA 生命周期 N 子集；真 IME/PTY/clip 链未签收 | V1/V3/V5/V6、P7 |
| R2-Render .01—.05（5） | WGL present/Device，OpenGL/Target，W App | app04 实际启动 GL；不是 alpha/reset/资源数证据 | V3/V6、P1/P7/P8 |
| R2-Tabs .01—.10（10） | W chrome/TabBar、tab_layout、Backdrop、Window | W01 只证标题覆盖子行为 | V3/V6、P2/P3/P4 |
| R2-Caption .01—.07（7） | W TitleBar/Backdrop/caption_layout/alpha/D2D | 自绘 UIA root 子证据，不代 DWM 像素/动画 | V3/V6、P4 |
| R2-Palette .01—.08（8） | W Palette/trigger；GX fuzzy/palette_history | 全拼 U；本轮 popup GUI 被前台 guard 阻断 | V6、P4/P6 |
| R2-Settings .01—.11（11） | W Settings/settings；GX settings_map/config_layers | 源码/模型与 Fluent 接线；本轮自绘设置图 PENDING | V6、P4/P6 |
| R2-Menu .01—.06（6） | W Menu/MenuPopup/Popup | UIA/DComp 基础不代实际菜单；W16 原 expect 仍需对齐真实右侧锚点 | V6、P4 |
| R2-Dialogs .01—.04（4） | W Dialogs/Surface；GX confirm | app04 原生 custom 恢复确认有限 G；不代其他确认流 | V1/V6 |
| R2-Keybinds .01—.06（6） | W Keybinds/shortcut_conflicts；GX shortcuts | 现为速查表；未签收 hover 时间/布局计数 | V6、P5 |
| R2-Find .01—.05（5） | W SearchBar/LinkPreview/ResizeOverlay/Surface/Window | 当前批次 U 仅实现子集；无本轮全搜索 GUI 证据 | V5/V6、P7 |
| R2-Scrollbar .01—.04（4） | W Scrollbar/Surface | 隐藏/reparent 基础接线；无拖窗零重画实测 | V5/V6、P3 |
| R2-Quick .01—.08（8） | W QuickTerminal/Window/Surface/Popup | IPC/toggle 基础不代动画/焦点/最后 tab | V6、P1/P7 |
| R2-Font .01—.04（4） | DirectWrite discovery/warmup；`src/App.zig::create` | 原已合源码保留，不重新审实现 | C6/V6，96 DPI 真图与独立十对 |
| R3-Style .01—.06（6） | G style/style.css/window；GX gtk_css | G05/G08 软件 Xvfb 的有限图 | V7：modern/Wayland/材质/真实 DPI |
| R3-Settings .01—.06（6） | G settings_dialog；GTK 1.5 Blueprint；GX settings_map | GTK 定向 U；不代全部保存/语言/fontdialog | V7、P4/P6 |
| R3-Window .01—.06（6） | G window/menus/shortcuts/launch/language/app/about | G08 菜单条目及 G15 输出有限图；G16 管理动作待验 | V7、R5-11 |
| R3-AppMode .01—.04（4） | G app_mode/progress；GX unread/leader | 源码已有；本轮无完整 idle/进度计数 | V7/P2；原 Dock 进度延期语义保留 |
| R3-Upstream .01—.03（3） | K close_confirmation_dialog/application；G confirm；OpenGL GX27—29 | GTK 构建/U 不代 hardware DMABUF/真实确认 | V7/P9 |

## 5. C、V、P 原硬门保留

### 条件决策 C1—C8

| 项目 | 源码/研究入口 | 本轮证据状态与补验要求 |
|---|---|---|
| C1 | 原计划三冻结 GTK measurement 树、`scripts/gx_perf.py` | PENDING。账本没有本轮完整 40 loads；保留既有 quiet BLOCKED、0/40、DATA_VALID=false。两批各十对完整交替，quiet 不满足就结束本次尝试，不能借本轮 Debug GTK 图或构建改判收益 |
| C2、C2-G | GX defaults、WGL present、shell integration | PENDING。96 DPI 的 padding/cursor/alpha/freetype/CJK 实屏比较及 GTK prompt 光标来源尚未形成逐项采纳/拒绝；不预改默认，不由 C1 cairo 推导 |
| C3 | `src/os/mouse.zig`、`src/Surface.zig` 配置消费 | PENDING。系统双击值与空 config、显式 350 ms 覆盖的真实点击合同；不更改用户系统设置 |
| C4 | Exec/renderer Thread 的 spawn | PENDING。quiet 下 1/11 终端真实 commit 增量与栈压力；WorkingSet/reserve 不代提交量，不无证压 stack |
| C5 | K `application.zig::setGtkEnv` | PENDING。Ubuntu 4.14 与现代 GTK 下实际软件设备、GSK 默认/cairo/ngl 对照及用户环境优先 |
| C6 | DirectWrite `discovery.zig::warmup` | PENDING。同 current 代码仅切 warmup 的公平十对、冷/热字体及首帧；旧 A/C 结果不代最终判断 |
| C7 | GX cursor_blink、renderer Thread/cursor | PENDING。1/11 终端、可见/失焦/最小化、blink 两相位、IME/输出再唤醒及独立动画；不能由单测推 CPU 收益 |
| C8 | GX environment、GTK environment、Config vsync doc | 源码已实现，最终合同 PENDING。用户值追加去重、GTK<4.16、WGL vsync、MDX/CLI 全文尾项 |

条件项可以有据“拒绝优化”，但只关闭对应决策；证据不足继续 PENDING，不删除实验成果。

### 关键验证 V1—V7

| 项目 | 当前入口 | 未被本轮子证据满足的硬门 |
|---|---|---|
| V1 | Exec→ConPTY→parser/core→W Surface clipboard/确认→PTY | 已知安全测试剪贴板下真实 BEL/ST 回复、allow/deny/cancel、empty read/write、split remember、Quick/reparent/关闭竞态；不读或备份未知剪贴板，不用私有消息或 codec 代完整链 |
| V2 | W App bell 路由、BellAudio | 实际 BEL/command_finished 配置、gain 0/.5/1 与听觉、永久驱动不返回的资源收尾；不调系统音量 |
| V3 | W alpha/Backdrop/TitleBar/TabBar/D2D、WGL→DWM | NVIDIA/Mesa 可见 default framebuffer/Swap/DWM、低 alpha、亮暗/高对比、混合 DPI、recreate/failure 补画；DIB/隐藏 HWND 不代证 |
| V4 | GX bell_border、W Surface、WGL | 两后端可见四角 192 DPI/跨屏、repeat/clear/hidden/reparent/idle；Windows-14 的 5 skip 不能算通过 |
| V5 | core search/terminal search、W Surface/Scrollbar | F3/ShiftF3/Enter 实际 viewport 变化、满 scrollback 裁剪和持续输出不误揭条、右缘仍可唤出 |
| V6 | W App/Window/Surface/QuickTerminal/Popup | 长 IME/候选定位、Win10、真实混合 DPI、native退路、Quick 还焦/末 tab、首帧/共享16 ms deadline、真实 TDR 与迁移后继续交互；标题或 session 单场景不代全链 |
| V7 | G style/settings/window/app_mode/launch 与 K hooks | Ubuntu4.14/Adw1.5 和 modern≥4.16、Wayland/WM、原生 pinch/IME/全屏/字体/语言/来源、xdg handler；硬件 DMABUF export→GDK import 单独验，Xvfb 不代证 |

### 性能 P1—P9

所有项目均缺本轮完整最终比较。P4 的历史 FAIL 必须保留；本轮功能测试、截图或单次启动时间不折算为有效十对。

| 项目 | 原门与源码入口 | 必须补交的数据 |
|---|---|---|
| P1 | 启动显示比基线改善 **>100 ms**；App/WGL/首帧 | 公平旧新完整交替十对，实际进程起点和 visible，median/p90 |
| P2 | 进程快照每 2 s 至多 1 次，最小化 0；GX proc 与共享 AppMode | 1/11/多标签、全应用总计数，非单局部日志 |
| P3 | 三窗口各 15 tab 拖窗，scrollbar 重画 0 | 真拖动、活动/后台标签计数与 screen |
| P4 | Palette/Menu/Settings 热路径 ≤1 帧且无 PATH 扫描 | 保留原 160 Hz=6.25 ms 门；完整十对。DComp 实验和 Fluent 组合另列成本，不能改成 60 Hz 门 |
| P5 | Keybinds hover 每帧 CreateTextLayout≤10、绘制<2 ms | 真实 hover、布局计数和 ReleaseFast 时间 |
| P6 | 连续↓浏览主题 2 s，reload 恰一次 | 两端实际按键过程及 reload 计数，非计时器单测 |
| P7 | resize 等帧 timeout 下降，无黑边/拉伸 | 同窗口/网格的旧新真实 resize 帧，保留全窗16 ms deadline |
| P8 | Windows 每 terminal 实际渲染目标 6→2 | 实际资源/显存计数，非配置常量；GTK 仍保留3帧 |
| P9 | GTK DMABUF warn一次、renderer CPU下降 | 标准十对及真 export/import 计数；缺扩展不是 hardware success |

跨 host 另记 BGRA 传输成本与输入到显示延迟，不能用源单进程渲染时间代替。性能窗口前必须停所有 owned 重型构建、测试、安装和 VM；不控制未知进程。

## 6. 补验入口与最终集中门

以下是**待执行入口**，本文没有运行。先核当时 source/build receipt、实际测试名、资源槽及权限条件，稳定批次合并 filter；不能把这些命令机械地全部重复跑一遍。

- 模块定向：`just test --filter apprt.win32 --filter gx.session`，或实际受影响的新模块过滤器；GTK 用 `just wsl test --gtk --filter <实际名称>`。完整运行期筛选和 seed 以相应批次 JSON 的 `build/filters/reproduce` 为准；零命中不计通过，`--no-build` 需身份一致。
- 原场景：Windows `just win-gui run --out <新的绝对隔离目录> W01 ... W20`；GTK `just wsl scenario --out <目录> G01 ... G16`，另保留外部 BellBorder 与所有 R5 场景。不要为了填 142 行机械创建 142 个场景。
- 本轮 W06/W07/W14/W16、W20、W01/W15 和增强后的 W09/W12 已有读图结论，见第 2.0 节；后续只按实际改动影响补验。GTK 生命周期、G15/G16 已在修复后的快照通过。
- 远程窗格：`test/windows/gx_remote_fixture.py` 已包含拖回、混合拒绝、源/目标丢失、IME/UIA/OLE/protected paste 与 session 剪枝。取消、映射替换和干净退出三项修复已在 r3 完成复验，52 图已读、回收退出 15/15、330 次布局变化无非预期断连，见第 2.0 节；r5 的冷通知修复未改变这些路径，不重复已有同路径证据的组合。
- 跨权限拖放：`test/windows/gx_drop_broker_fixture.py` 只在 VM 中按模块文档的 setup/target/drop 顺序、从同一用户同一会话预开的 medium/high 控制台运行；它不提权、不用 Explorer、不改 UIPI、不读剪贴板、不发 Enter。
- Session/IPC：`test/windows/gx_session_ipc_fixture.py --help` 后选择真实新证据批次；同私有 state 多轮恢复仍须每轮核 PID/birth/exe。已有 custom 子场景与其他 session 门分别签收。
- UIA/DComp：`test/windows/gx_popup_uia_fixture.py --exe <标准exe> --sha256 <构建后实际哈希> --out <新绝对目录> --build <批次>`；`--readonly-root` 只签 root/window/pane MTA 层；`--capture print` 只能诊断，不签 GL/DComp 上屏。脚本内部统一 heavy→desktop；前台/点位失败停止并保留 FAIL，逐张读 `visual-review.md` 指向的图。
- 系统功能：Win11 VM 已运行并有同一用户真实 medium/high 拆分令牌，Mesa 渲染图有效；旧 GL 正常关闭判断因未检查退出码而失效，与远程相同的 `WM_QUIT` 清理崩溃修复后 r3 三次关闭均退出 0。`test/windows/gx_vm_validation.ps1` 已加强退出码与窗口诊断。r3 安装与卸载、r4 安装、JumpList、接收器配对，以及 broker medium→high 文本取消、允许不追加回车与多行保护取消和同用户 direct 三向最小文本拖放已有证据（第 2.0 节）；Toast 热激活与 r4 最终卸载已通过（Win11 卸载未延期）；Toast 冷激活的前台提示在 r4 上 FAIL（修复前证据），r5 安装与热、冷激活复验已通过；无激活 15 s 退出与 r5 最终卸载也已 PASS_SCOPED，VM 已 owned stop 关闭、磁盘保留，本次功能门已无余项；Win10、升级路径、不同账户负向是批准延期项。
- OLE 专用入口：`test/windows/gx_ole_fixture.py` 与其受控外部 source；以当时 `--help`、已冻结 app/source 哈希和自有窗口守门执行。首个 text 失败在上表，后续正常权限真实成功也不能替代跨权限 broker 与四方向验收。
- 完整 Windows/GTK main 已各运行一次，原件保留；不因提交/文档重跑。新 Windows 修复只统一构建 app＋test-bin 并跑非零命中的受影响并集。VT、独立 POSIX/C ABI/wasm、硬件与性能门按批准计划延期，不能再把 `ci-check` 与组成项重复运行。
- 10-18 root 用 `python scripts/gx_slots.py --kind heavy -- python scripts/run_unittests.py --jobs 2` 集中跑完整框架单测：936 项、17 skip，唯一 FAIL 是 `test_agent_kb.RealCorpusTests.test_checked_in_kb_is_fresh`（新文档后尚未生成 KB），其余通过；原日志 `final-r2/framework-20261018.log`，wall 436.36 s。这次记 FAIL，不是 PASS，也不是 15 s 级的快速检查。`just fmt-check`、`just fluent-check`、`just graph-check` 在 r5 两文件修改之前由 root 运行，exit 0；修改后已按两源变化重建图谱（`final-r2/graph-20261018.log` exit 0，35 处头文件解析限制不变）；r5 源码冻结后 graph-check 与 fmt-check 重新 exit 0（本轮工具记录），i18n、pinyin、fluent 真源未变且 check exit 0。root 已运行 `just kb` 并只补跑 `python -m unittest scripts.test_agent_kb.RealCorpusTests`，6/6 通过（`F/kb-final-20261018.log`）；本次状态更新随交付记录再次生成并校验 KB，精确本地提交；不运行会重复 936 项的 `just framework-check` 或 `just ci-check`，936 项整框架只在 10-18 运行过一次，其 KB FAIL 原件保留，组合证据只写实际执行的命令，不冒称重跑 936 项或聚合命令运行过。i18n 当前为 671 条，真源不变不重复生成；打包离线消费最终 app，不加 `--build`。本索引与用户文档不能代替实际运行记录。
- 将来做正式逐叶签收时（当前为批准延期的 PENDING 门），每叶需要完整身份、命令退出码、raw 单位/n、读图判定与缺证原因。本地阶段 commit 已获授权（精确暂存、不 push）；commit 只保存可审的工作，不代表任何门通过。全部必需功能和门满足前，`tasks.json` 与最终交付继续 **not_complete**。F1–F9 功能交付按限定证据完成；本轮已无额外实现工作；余下只有原完整验收中已批准延期的项（性能与 P4、硬件、Win10 与升级路径、跨账户负向、正式 142 叶签收等）。
