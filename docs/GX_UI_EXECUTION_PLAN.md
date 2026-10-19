# GX UI 当前执行计划：单对话原生子智能体、集中验证、R6 收口

## 当前检查点（2026-10-19，r9 基础及 r10 OLE 候选）

本节是当前执行口径；后文 10-18/r5 的“当前状态”“最新候选”“已无额外实现工作”及批次收尾均为历史记录，正文原样保留，不代表 r9 已完成。总状态仍为 **`not_complete`**；142 叶正式账本 `.local/evidence/R5/execution-20261013/leaf-matrix.json` 的 **`results` 仍为 0**，候选映射与工具独审、离线 GREEN 均不代实测 PASS。下称 F3 为 `.local/evidence/R5/execution-20261013/final-r3`，表中路径相对 `F3/root/`。

- 用户裁定（已写入 `F3/r6-contract.md` 的 2026-10-19 补充）：C2-G **显式配置始终优先**，不只在 shell 提示符处；形状与闪烁分别约束，显式等于默认值也有效。修复已提交 `805fa4556`；旧解释与旧证据保留，不能据此签完整 PASS。Win11 无系统设置副作用的隔离普通功能允许在宿主补验，仍不改宿主系统设置；跨账户、安装升级/注册冲突、DPI/高对比/勿扰等系统改动留 VM，Win11 不可代证 Win10。
- 身份：此检查点核对的 HEAD 为 `700ada696`、tree 为 `418c0388a858b751a7b83f16f2f6cec223fc110b`；r9 构建身份仍是 `dc02219fe`、tree `08e903eba89f6cd8eefa466b8a1bfbf205d71dd3`、`source_dirty=true` 加 `r9-current-bind-20261019-01/native-source-before.json` 的文件哈希。root 此前核对 1543/1543 native 文件与该清单一致；后续工具或文档提交不倒写构建身份。r9 app SHA256 为 `d98ad539f1c94387001f052fd8a3610c7af4fdc7787bbfb99d76c0fe44375861`；root 核对原执行目录没有 ConPTY/OpenConsole 旁车。
- 构建次数：r9 已超出下文原定“最多 r8 后冻结”的上限，是为实际缺陷修复（含落实 C2-G 原计划语义的优先级修复与测试运行时守卫）追加的实际轮次；原上限不倒改，也不因此认定 r9 已是签收完成的 rF。

原报告中的视觉 PENDING 字段保留；已读图结论与读取记录是否归档分别核对，未归档不等于未读。

| 核对项 | 原始入口 | 当前可记录的结论与边界 |
|---|---|---|
| r9 构建与测试 | `r9-current-bind-20261019-01/`：`windows-build.exit`、`gtk-build-receipt.json`、`rf-targeted.json`、`windows-main-final.json`、`windows-main-exact-failure.json` | Windows/GTK 构建记录 exit 0；定向 **53/53 PASS**。Windows 全量 **FAIL**：5255 总、5179 PASS、73 SKIP、3 个符号链接 `PermissionDenied`；D28 单项复现仍 FAIL。GTK receipt `perf_eligible=false`，不代性能验收。 |
| C2-G | `c2g-w26-r9-20261019-01/`；`c2g-reload-supplement-20261019-02/run/G22/` | W26 SUMMARY 为 OK，已有 O2 40 图及 root 抽查 14 图报告；其 `build-identity-win.json` 是 `ac4c068e…25955` 候选且 `not_rF=true`，不能混写成 `d98ad539…75861` 的新运行。GTK 补验 meta exit 0，原生 DECRQSS 为 **4→1→4**；本检查点不扩大为完整 C2-G PASS。 |
| Session | `r9-session-{roundtrip,boundaries}-20261019-01/report.json`；`r9-session-dual-privacy-quick-20261019-{01,02}/report.json` 及 02 的 raw/3 PNG | 第三批 02 已 exit 0，**SES-06/07/08 三项 native PASS**。paused before/after 字节相等（SHA `733a28e5…e6166`、gen8），first `resume_verified=true`，正常 Quit 后 gen9、完整 2 窗各 2 tab 保留；second exit 0。root 与 O2 Faraday 各 **3/3 已读**，O2 已核 SHA：`GhosttyGxPopupShadow` Busy 完整提示 PASS；privacy 合成环境/动态 title/scrollback marker 实际上屏、session JSON 无 marker。Quick 图仅窗口与块光标、无 prompt，不代 shell ready；工具窗口及关闭后 2 普通窗归档逻辑相等，排除结论仅据 native。root 核四个原 PID 均不存在；夹具作者/root 各 **31 项离线 PASS**，独审通过。01 second-busy FAIL 及更早写者归因未成立的 FAIL 原件均保留，既有范围不扩大。 |
| UIA | `r9-uia-terminal-events-20261019-01/report.json`、`reviews/UIA-05.json`、`reviews/UIA-06.json` | O2 4/4 图已逐张读取并核 SHA，root 抽查分屏焦点图；UIA-05/06 为 PASS_SCOPED。原件确认分屏 SetFocus 与外部 MTA 实际收到焦点／选择事件（ready 后目标事件：菜单焦点 1、Palette 选择 1、Settings 焦点 1／Appearance 选择 1），不是仅接口支持。Notification 的 events 均为空、retained_actions=0，实际通知接收与旧 provider inert 仍 PENDING；Settings 搜索 Edit 的 Name 原为空，不补成可见占位文字。原报告 PENDING 不覆写；仍是 r9 证据，不代 r10 新运行、讲述人或 Win10。 |
| GTK 设置定向回归 | `r9-gtk-settings-regression-20261019-01/{G26,G27}/` | **PASS_SCOPED**：G26 14 张、G27 16 张全部由 O2 逐张读取，root 重核全部 30 张 SHA 并累计独立抽查 7 张。保存失败、Revert、预览另一主题时 Retry、跨窗失败草稿保留与重试符合本批预期。G27 的 counts.json 为中途 **3 builds/17 opens**，完整 raw 是 **4 builds/21 opens、5 条 theme.reload**，不能混用。仅 GTK r9 Debug/X11/Xvfb 回归；meta exit 0 不等于 app 正常退出：清理记录为 owned pidfd SIGTERM、child_exit=-15。不代 P4 性能或完整 C2-G；人工读图结果仍未落盘归档。 |
| Session 追加边界 | `r9-session-final-boundaries-20261019-01/`；`r9-session-write-failure-20261019-02/` | 18:38 批次 **SES-00/03a/04 自动检查 PASS**，root 读完 8 图；SES-05 因夹具读取受拒和 `icacls /restore` 缺权限 **FAIL 保留**。root 已精确恢复旧批次 3 份 DACL、核原存档哈希未变，5 个自有应用 PID 均不存在。最小夹具返修后 18:57 仅复验 SES-05，exit 0：前／动作后／Quit 后／恢复后及实际路径 **5 份存档逐字节一致**，SHA `f9d7ad18…ce501`；3 份 DACL 精确恢复，PID 35324 已不存在。root 与独立 O2 均 **9/9 已读**，O2 判四项 PASS_SCOPED；两张失败提示图的 occluder HWND 缺 owner/PID，归属仍 PENDING，不能猜定。随后独审发现原始显式 ALLOW 可能被 `/deny` 削减；新增注入前保护及 AI／重解析点回归后 Windows **72/72**、WSL **68 PASS/4 原生平台 SKIP**，三轮独审通过，已提交 `700ada696`。18:57 GUI 对应旧驱动 SHA `dfc5fd35…19f91`，不冒充最新 `2fd5459b…c3b5` 的运行；最新驱动 GUI 及正式归档 PENDING，不能签完整 Session PASS。 |
| V4 原生补验 | `r9-native-bell-system-20261019-01/`；`r9-native-bell-software-20261019-{01,02}/` | 同 r9 test exe SHA `515542eb…cc08cb`，`--no-build --filter "native bell border" --jobs 1 --seed 0xb3111019`：NVIDIA **5/5**，显式 `GALLIUM_DRIVER=llvmpipe LP_NUM_THREADS=4` 的 Mesa **5/5**，无 skip。原件证明隐藏 FBO 像素／状态／上下文重建与空闲发布唤醒链；不代桌面 SwapBuffers、DWM、真实 DPI、GTK 或完整 V4。软件 01 没经过产品 `chooseLib` 的 llvmpipe 固定逻辑，首项原 **600 s timeout** 后 root 中止其余等待，自有进程核空；机器汇总未生成，超时仅存会话命令原件。02 使用同 exe／DLL、同 seed 修正调用环境后通过，不改写 01。可补旧叶映射 R2-App.07／R2-Render.01 的同名 N 测试跳过缺口，但不是两叶完整签收。 |
| P6 正式 | `p6-r9-final-20261019-01/{quiet,measure}/RESULT.json`；旧诊断 `p6-fixture-diagnostic-r9-20261019-{01,02}/` 保留 | 十对 **20 runs 完成**，quiet **VALID**、command exit 0；新臂 **10/10 各唯一 `theme.reload=1`**，旧臂无埋点仍 n0。O2 40 张、root 抽查 4 张已读（会话证据，未手工归档）；动作前选中不等于预览，动作后 Previewing 另有图证。仅记 r9 范围，旧诊断不充正式样本。 |
| P5 正式 | `p5-r9-final-20261019-01/{quiet,measure}/RESULT.json` 及逐轮 raw | 十对 **20 runs 完成**，quiet **VALID**、command exit 0；新臂 **9240 frames**，paint median **0.6365 ms**、p90 **0.719 ms**，layout/frame max **0**；每轮 paint p90<2 ms、layout/frame max≤10。root 按 raw 每窗口/线程逐帧重数 9240 一致；8 工位 O2 全读 **1010 张**且逐图 SHA 核对一致，root 已读/hash **101 张原图**。**PASS（仅 r9 测量范围）**；旧臂无埋点 n0，不扩大到未绑定的 rF 或所有视觉平台。 |
| C8 | `c8-r9-webdata-20261019-01/webdata-verify.json`；工具提交 `38686a750` | 既有 config/actions/commands 三份 MDX 全文比对 **PASS**，不重编。新提交仅工具；root 回报 Windows/WSL 各 **24 项 PASS**。**exe→source receipt 仍缺**，不称 C8 完整 PASS，CI 的 `5ea7604b4` 成功也不覆盖此工具提交。 |
| 验证回归与 Fresh regen | root 会话工具记录（原件克隆保留） | root 回报完整框架 **1555 项、17 SKIP PASS**；既有 rules/version/kb/i18n/pinyin/fluent/graph checks 均 exit 0。Fresh regen 在同 `73623c429` 的两个全新 checkout 上完成，Windows/Linux 三表字节一致；r9 包许可核验与收据保留。此文档排除于 KB 语料，不重生 KB。 |
| P4 / P7 | `p4-r7-20261019-02/measure/RESULT.json`；`p1-p7-r7-20261019-01/measure/`；`p1-p7-r8candidate-20261019-01/measure/`（两批 `RESULT.json` 的 `runs[].path` 指向逐轮原始 JSON）；后者目录上层 `engineering-review.json` | **P4/P7 FAIL 保留**。P4 新臂绝对门仍失败。P7 逐轮原始 `setwindowpos_ms ≥16` 计数：r7 为 old **1/60**、new **10/60**；后续 r8 候选为 old **0/60**、new **0/60**，两批 quiet VALID，后者仍未满足严格减少，数值门 **FAIL**。captured、exit 0 及原件的严格终帧/视觉 PENDING 不覆盖该结论，也不能据此否定已读图记录。 |

CI：`5ea7604b4` 的 [push 39212670036](https://github.com/gx0404/gx_ghostty/actions/runs/39212670036) 与 [dispatch 39212700961](https://github.com/gx0404/gx_ghostty/actions/runs/39212700961) 均已完成且 **success**；已执行 job 全成功，push 的 macos/gtk-smoke 按条件 skipped，dispatch 全部 success。root 回报 artifacts 早/晚两批目录均已下载，Windows/GTK smoke 已读图；不代 macOS app GUI 验收。`805fa4556` 的旧 [push 39206683669](https://github.com/gx0404/gx_ghostty/actions/runs/39206683669) / [dispatch 39206713871](https://github.com/gx0404/gx_ghostty/actions/runs/39206713871) **FAIL 保留**：cross-win 在 `pkg/translate-c/build.zig.zon:15` 下载 Codeberg translate-c 时 `NameServerFailure`。核对入口：`gh run view <run-id> --repo gx0404/gx_ghostty --json status,conclusion,headSha,jobs`。

r9 离线包仅记 **PASS_SCOPED（包构造与内容核验）**：root 已完成 `gx_windows_package.py --prefix zig-out-delivery-r9 --output-dir <F3>/root/r9-package-20261019-01/dist --offline`，无 `--build`、未安装。该 dist 中 zip 为 85,509,986 B、SHA256 `2409eb885e4810f4b9a5be0df717dd5a296369d7d113bc337d803ba3d9e559c7`；setup 为 60,855,398 B、SHA256 `85c62fec7dc2041211d53dd78242c3312afab866650455cb3d2110a9748166ac`。只读内容核验确认 ZIP 内 exe 与上述 r9 哈希一致，pinyin-data/Unicode/Fluent 三许可与 Git HEAD 真源逐字节一致；ZIP 含钉版 `conpty.dll`（`5afea6c9…34852`）与 `OpenConsole.exe`（`6f8e68de…5737`）。这不代包内旁车路径、安装或 GUI 验收。

剩余动作由 root 统一安排，不因本次文档更新重跑全量：

1. **SES-00/03a/04/05** 的追加执行及失败修复见上表，独审与 O2 已完成，待最新驱动 GUI／最终树绑定；既有 **SES-01/02/03/06/07/08** 仍按所列限定证据，不代表 Session 全关。IPC 及原计划其他功能/V/P 缺口仍须按 `docs/GX_UI_REMAINING_PLAN.md` 原完整契约补验，不是仅剩绑定。root 确认 SES-06/07/08 第三批于 **17:24:00**（idle **909.89 s**）实际执行并 exit 0。**15:16:45** 的 idle=598 s、未启动记录保留，不记作 17:16；各旧 FAIL 不回写，归因未成立的不写成产品缺陷。
2. 核对 C2-G、Session、UIA 等已有截图的逐图结论及对应 app 身份；读取记录未落盘时不称“已归档”。完成 r9/rF 绑定、复用范围裁决后才逐叶写正式结果，142 叶候选清单不等于签收。
3. 保留 P4/P7 FAIL 与其余平台/硬件等缺口，按原门槛补测；C8 补齐 exe→source receipt 后再作完整裁决。由 root 决定离线包安装、GUI 与旁车路径补验，不以包或工具检查代证。

本节是计划要求的跟进文档，**不代替被 hook 拒绝的证据归档**。

19:00 补记：`c0ea2a078` 的 push CI **39235905376 success**，应运行 job 全通过；macos、gtk-smoke 按 push 条件跳过，不冒称本树手动冒烟已跑。四份单测原件已下载至 `F3/ci-artifacts/39235905376/{early,late}/`：Windows app 1310 PASS/23 SKIP、Linux main 4410/62、Linux VT 6650/70、Windows VT 6662/62；本地 3 个权限失败同名用例在本轮 CI 均 PASS，本地 FAIL 不改写。该 CI 不覆盖上述未提交的 ACL 夹具返修。Win10 始终未确认登录，最新锁屏图为 `win10-r9-20261019-01/login-status-03.png`；19:00 已正常 owned stop、容器 exited 143、启动包装器 exit 0，两个 VM 均停止，磁盘／ISO／r9 包保留。Win10 暂存夹具仍绑定 `c0ea2a078`，尚不含未提交返修；登录后执行前须更新并重新核身份。

20:36 追加检查点（不回写上面的历史执行条件）：

- 用户取消启动前十分钟桌面空闲门；`--no-start-idle-gate` 显式记录新条件和旧条件是否满足，默认行为不变。其他软件仅观察的既有裁定继续有效；批内输入／前台／指针、自有身份、槽、构建测试与 VM 门、原性能数值门保持。新工具独审通过；Windows 三个相关框架模块 449 项、3 SKIP，其余 PASS；WSL `test_gx_perf` 207 项、1 SKIP，其余 PASS。旧 P2 三次未启动仍 n=0，当日同批尝试不重置。
- IPC：`r9-ipc-boundaries-20261019-02` 与 `r9-ipc-negative-20261019-01` 共 8 图独立 O2 全读、SHA 匹配，root 已抽查。范围限 launcher 复用／独立执行、六 launcher 竞争、不同私有配置根、相同 exe 不同目录、非响应冒名端点；不代不同构建、实际安装及跨账户隔离。早期 crash 例无内部 ready 证据；另批 `r9-ipc-native-seams-20261019-01/IPC-03` 用 hold-ready 原生 marker 补验通过。
- IPC-04b 的快速退出观测竞态修复已独审，Windows／WSL 各 12/12。`r9-ipc-native-seams-20261019-02` 实际四项 exit 0：合法格式冒名 hello 因 `DifferentImage` 被拒、GUI 失败 secondary exit 1、不重复执行重放、六 launcher 的全局热键 attempts/success/current 为 1/1/1。12 个自有 app PID 复查均不在；O2 5/5 图已读、SHA 匹配，root 抽查 Quick 图。四例 N 为 PASS_SCOPED；IPC-07 主窗口 after 被同进程 Quick 窗遮挡，完整主窗口 G 仍 PENDING，不误报产品故障。旧 04b FAIL 保留。
- OLE：`r9-ole-typed-source-20261019-01` 前五项原生断言通过，O2 11/11 图已读并核 SHA、root 抽查 2 图。Unicode／单文件／多文件／URI 四例可见预期粘贴内容；shell_metachar 显示 `Cannot drop here` 且提示符后为空，只签拒绝反馈，不因 COPY 签成功粘贴。完整无 Enter 仍需目标输入证据。quoted_path **FAIL**（source exit 2、effect COPY、成功 medium 2／释放 1），multiline 未跑。候选旧 HDROP 回退链尚缺最终 trace，先补有界关键 trace 与失败 after 取证，不放宽拒绝或释放断言；controlled IDataObject 不是 Explorer 真源。
- `700ada696` 的 push CI **39249027328 success**；四份新 artifacts 已下载至 `F3/ci-artifacts/39249027328/` 并逐条重数：Windows app 1310 PASS/23 SKIP（seed `0xd8c08786`），Linux main 4410/62（`0xfb310740`），Linux VT 6650/70（`0xb5432289`），Windows VT 6662/62（`0xc37e6958`）。本地三个 FAIL 的精确同名用例在新 CI 均 PASS，本地原件不改写；另有 tinyio `openFile symlink handling` 在 Windows CI 为 SKIP，不误报全族通过。IPC／perf 修复已分别提交 `20ff175fa`／`a5dbedb52`，不将旧 CI 覆盖扩大到它们。
- 启动豁免实机探针 `start-idle-waiver-probe-20261019-01` exit 0：新条件满足，旧 idle 门不满足（36.25 秒），所有其他门通过；这不是性能测量结果。P2 单窗 11 标签可见批 `p2-r9-w1-t11-visible-20261019-01` 已实际运行：old 完成 5 轮、r9 完成 4 轮，r9 第 5 轮因 60 秒测量窗内外部输入终止（tick `177599531→177614406`）。结束时其他门全部通过，但批内输入门失败，整批 **INVALID**，原件保留、有效正式样本 n=0，不拼接局部数值签收。证据目录写入例外虽获授权，策略仍未由人工改入；正式审阅归档与叶账本仍未写入，不把会话报告称作已归档。

20:55 OLE 补证：新 helper SHA `6abf0651…c45dc`（源码 `ad4a0c6c…e1ff8`）经 fmt-check、Zig 4/4 与 build-exe 验证；Python 最初 Windows 9/9，WSL 因未 mock `CREATE_NO_WINDOW` 失败，补平台常量 mock 后 root 两平台各 9/9。`r9-ole-quoted-trace-20261019-02` 再现原 **FAIL**：149 行 trace 保住最终事件，medium 1 引用 3→0，medium 2 无释放，DoDragDrop 返回 COPY，旧 HDROP 路径仍记录拒绝引用。新增 failure-after 已读：空提示符及小窗口残影，不猜定残影归属。`r9-ole-multiline-20261019-01` exit 0、GetData/release 1/1，多行保护显示 2 行 37 字符，Esc 后提示符为空；root 已读保护与取消两图，O2 六张新图已逐张读取并核对 SHA；保护与取消路径 PASS_SCOPED，完整无 Enter 及残影归属仍 PENDING。两批各 app/source/PTY/conhost 的四个 PID 均已不存在；不扩大为产品缺陷已修。独审另指出纯失败截图不应写成输入注入痕迹；夹具两处 `probe=True` 与真实审计回归已修，root 双平台各 10/10，独审通过，三夹具文件提交 `d3006954c`。两批 GUI 的 driver 仍是 `63b9d932…3010f`，不能代最终 `03f753b1…d84c7` 的输入审计实测。产品旧入口修复另行实现，不把工具补证当作产品修复。

### r10 OLE 最小修复候选

生产改动仅在成功安装 OLE target、重新解析 attachment 并接管后关闭该 HWND 的旧文件拖放入口；不在撤销或重挂接时重新启用。新增真实窗口注册成功／失败、撤销／重新安装及恶意 HDROP 拒绝回归。只涉及 `src/apprt/win32/Surface.zig` 与 `ole_drop.zig`，后者仅测试变化。r10 为新发现缺陷而追加，继续保留原构建轮次上限的偏离，不称全计划已冻结。

- 首轮 `zig-out-delivery-r10` 编译因新增测试 `defer if` 赋值语法退出 1，没有运行测试；原输出保留。只加 block 修复后，新目录 `zig-out-delivery-r10b` 的 `install test-bin` 构建 exit 0。
- 构建身份：`d3006954c` 加未提交的 Surface SHA `09123d8508d7885e6f983189c6edb4e3ec23f8c8fe285126541055e94bc02481`、ole_drop SHA `0c159e2c03055a46147de5ead2a40b82366b3c9365d9a2fb5553fa09313905fe`。1543 个 native 文件相对 r9 原清单只有这两项变化。ReleaseFast app SHA `fae6657ab92292726720e1218d87dca28f7e8a06e732db1939820a34fa749426`，Debug test SHA `6e5f05ce0fefd9e63f2f5373e21381e79b0e29267b1b09590f502c87d57df536`；不倒写 clean receipt，正式构建归档仍 PENDING。
- `r10-ole-targeted-20261019-01/tests.json`：`--filter "OLE " --filter "runtime reference reparent" --jobs 2 --seed 0xa101019 --no-build`，**16/16 PASS、0 SKIP**；补丁闭集／测试根框架 **146/146**，规则检查、格式检查及 KB 新鲜度通过。不是最终完整框架、main 或平台门。
- `r10-ole-rejection-control-20261019-01` 真实回放 exit 0：quoted_path source exit 4、effect 0、medium 1/1，旧 HDROP 拒绝日志不再出现；single_file source exit 0、effect 1、medium 1/1。root 已读两张 after：恶意路径后空提示符，正常带空格／中文／emoji 的完整路径带双引号显示。8 个 app/source/PTY/conhost PID 复查均不存在。O2 四图全部独立读取并核 SHA、两例 N/G PASS_SCOPED，源码独审通过；修复提交 `7ece28e73`，r10b 构建身份仍保留为 `d3006954c` 加当时两份摘要。r9 两批 FAIL 保留，Explorer／完整无 Enter／完整重挂接矩阵不扩签。
- 三个工具提交已 push 至 origin；`d3006954c` 的 gx-ci `39257738400` 仍运行，不把它覆盖扩大到后续 r10 源码提交。完整框架另受待人工应用的证据目录策略例外影响，`test_ai_tool_hooks` 当前 RED 未提交；不以局部通过冒充全树通过。

### r10 后续边界与复用核对

- `r10-uia-notification-stale-20261019-01` 的 UIA-04/02 和 `r10-uia-ime-modal-20261019-01` 的 UIA-03 实际 exit 0；O2 **7/7** 图已读并核 SHA、root 抽查 2 图，三个 app PID 复查均不存在。UIA-04 的无窗口 MTA 真实收到一条 `The session could not be saved.` 通知（kind 4、processing 2），仅原生测试消息触发，不代真实存档失败或读屏播报。UIA-02 三个旧元素在隐藏重开／替换子菜单／销毁根后均于属性读取返回 `0x80040201`，没有污染新目标；不是旧 pattern 的 Invoke/SetValue 本体调用，后者仍缺证。UIA-03 记录 **38 查询、1 unavailable、有效 37**；真实 `ni` 组字计数 2，IME 前后 open=1/mode=1025、布局 `0x08040804` 未改变，不能代实际切换后恢复或 2000 字压力。三例仅 PASS_SCOPED，旧 r9 原件不回写。
- `r10-ole-lifecycle-20261019-01/OLE-08` **FAIL 保留**：插值路径触发两窗口范围守门，随后源窗口前台导致清理再次拒绝，主原因被清理异常覆盖；未进入重挂接产品断言，OLE-09 未跑。app/source 均已退出，root 发现左键仍 down 后停止 GUI 并提醒用户，没有向外窗补输入；后续只读已确认 up。两文件夹具返修增加路径预检、已有按下拒绝、源身份保护清理、双重异常及中断保留；root Windows／WSL 各 **33/33**，独审通过并提交 `927a42920`。02 批仅因 source 激活被系统拒绝而 FAIL，未按下，清理 errors=[]/pending=false；03 批 OLE-08/09 实际 exit 0，O2 两图全读、root 抽查 1 图。重挂接保持原 core/HWND/PTY 与树；销毁后原目标消失，其余两叶身份保持。两例均取消 HRESULT `0x00040101`、effect 0、成功 medium 0/release 0，不能说数据已粘贴；native 粘贴排队计数不增，四个 app/source PID 已不存在、左键 up。01/02 原 FAIL 保留，今日该批三次已用完。
- 只读叶影响核对：142 叶／29 批无重复漏项，65 个入口中仅 Surface 命中 r10 变化，涉及 **36 叶／10 批**；另 81 个 Windows 叶入口相同但有共享 Surface 间接依赖，25 个 GTK 叶不因本次 Win32 变化重跑。相对旧 v2/r7，互斥计数为旧变化 17、本次变化 17、两者都有 19、入口仍同 89，累计 **53 叶需核绑定**，不等于 53 个功能失败。不得只凭哈希签完整复用；正式 results 和 case_to_leaves 仍为 0。完整核对报告在会话中，未称正式归档。
- `r10-package-20261019-01/dist` 离线打包 exit 0，没有 `--build`、未在宿主安装：ZIP **85,442,279 B**、SHA `ff533ce0adb5c1a5dc29b8dd80c34c08b056789e077c06d63fd8d8e7f804f8be`；setup **60,798,407 B**、SHA `85b749710eff030dad7f88aded2ef507e3236b46f423d1d3b02a68f3bbca0d36`。ZIP 唯一 app 与 r10b 一致，三许可逐字节匹配仓内真源，随包 ConPTY/Mesa 哈希核对；原 prefix 仍没有 ConPTY 旁车。仅包构造 PASS_SCOPED，安装／升级／包内运行尚未验。
- `d3006954c` push CI **39257738400 success**，四份 artifacts 已下载并重数：Windows app 1310/23、Linux main 4410/62、Linux VT 6650/70、Windows VT 6662/62（PASS/SKIP）。当前源码 `a062da275` 的 push **39259514397** 及手动三平台 **39260733272** 均已 success；两轮原件均已下载，Windows app **1313 PASS/23 SKIP**（新增 3 项 OLE 在 push 中精确同名通过），Linux main 4410/62、Linux VT 6650/70、Windows VT 6662/62。手动明确启用 gtk_smoke、macos、win_smoke；macOS 仅 lib-vt，不涉及 gx-release。两张冒烟图 O2/root 均已读、仅视觉 PASS_SCOPED：Windows Debug llvmpipe 有首帧日志与 pwsh 提示符，GTK ReleaseFast 4.18.6/adwaita 1.7.6 的 Xvfb/llvmpipe 以 CPU 内存呈现，GX 定向 102/102。中文字体／locale／dbus 等日志缺项保留，不代完整字体、Wayland 或性能；两边未上传 exe/摘要，CI exe SHA 为 unknown，不冒用本地 r10b。

补验续记：`r10-ole-explorer-20261019-01` exit 0，真实 Explorer 私有文件拖入，原生 200/201 计数 `[0,0]→[1,1]`；O2 两图已读、root 抽查目标图，路径完整带引号可见。原文件 38 B、SHA `575e0baf…d3af` 未变；只关闭新建私有目录 HWND 58659096，未终止共享 Explorer，root 确认 HWND 已消失和 app PID 16028 已退出。仅 PASS_SCOPED，不代跨权限 token 全字段或完整目标输入流无 Enter。

旧 pattern 直接调用扩展的首批 `r10-uia-retained-pattern-20261019-01` 保留 FAIL：日志标记 SetValue 尝试返回 `0x80131509`，持有/释放 1/1，新面板搜索框为空，root/O2 均读图。但独审随后发现 `GetCurrentPattern` 取得 IUnknown 后未显式取得对应 typed interface，且清理异常可能覆盖主错；因此撤回“日志已证明正确 typed SetValue 方法本体调用”的推断，不能将该错误码归因产品。

23:01 追加：夹具已统一使用客户端 IID 的 `GetCurrentPatternAs`（槽 14），Value.SetValue 用 BSTR／UTF-16 代码单元长度，释放错误保留主错并继续剩余清理；独立静态复审通过，root 在 Windows／WSL 各重跑探针 **46/46**、boundary **11/11**。新原件 `r10-uia-retained-pattern-20261019-02` 仍 **FAIL**：同一 MTA 20032 在 ready 前取得 typed ValuePattern，signal 后 SetValue 返回 `0x80131509`，不是严格预期 `0x80040201`。引用取得／释放 1/1、所有清理成功，app PID 22996 正常 exit 0、复查无残留；root 已读失败图，Search 为空且没有测试 marker。这次能证明 typed 客户端调用，不证明产品 provider 方法已被 UIA core 实际转发；产品归因 PENDING，后两个子案例未执行。当天 UIA-02 次数已用完，不再重跑、不放宽 HRESULT，旧原件不覆盖。

远程采样 `remote-r10-20261019-01`：两个自有 app 正常 exit 0、PID 已不存在；50 字符、200 ms 节奏，quiet **VALID**（本次旧 idle 阈值也满足，其他软件仍按新裁定仅观察），命令 exit 0。只对两个独立 stderr 原件汇总：103 个帧字节记录，每帧 **19,507,800 B**；readback n103 median/p90 **1.722/2.193 ms**，map n103 **1.885/2.676 ms**，present n82 **3.0065/4.298 ms**，input_to_present n50 **9.341/11.801 ms**。保留不同 n，不强配逐帧对应；这是产品 QPC 埋点范围，只记录、不设门，不宣称性能提升或精确屏幕可见字形延迟。O2 **3/3 原图已逐张读取**并独立复算上述数据，root 已抽查输入图；101/101 批内守门通过。读图与复算为 PASS_SCOPED，原报告视觉 PENDING 字段不覆盖；正式审阅记录尚未落盘，rF 最终绑定仍需核对。

本轮 Win10 裁定（2026-10-19）：按用户确认于 22:01 复用原容器启动，live UUID 与 machine.json 均为 `0b9578ea-d38f-42d1-b8b5-a84324f7bf5f`，网页 HTTP 200；只读图先显示锁屏，后显示 gxadmin 密码登录框，未进入桌面。没有代输入密码，也没有读取或输出密码值。用户随后决定“ 不行就放弃这个测试 ”，因此本轮 Win10 功能验收 **PENDING（未登录，用户决定暂不做）**，不再自动重启或重复请求登录。22:06 owned stop exit 0，原容器 exited 143、running=false、binding_errors=[]；磁盘／ISO／已有证据保留。两张图在 `win10-r10-20261019-01/login-status-{01,02}.png`，不构成 Win10 应用通过证据。

### 2026-10-19 23:10 加速执行补记

- UIA 夹具返修已提交 `e22e76daa`；上述 02 失败图 root／独立 O2 均已读取。独审未找到确定产品源码缺陷，`0x80131509` 是 `UIA_E_INVALIDOPERATION`，UIA core 的前置检查或转换仅是候选解释。下一允许诊断窗口先被动跟踪旧 snapshot 的 getter／SetValue／dispatch，不先改源码或放宽预期。
- `p1-p7-r10-20261019-01` 完整十对、每臂 n10，quiet **VALID**、命令 exit 0；启动 `startup.shown` 的 old median/p90 **405.35/427.8 ms**，r10b **299.1/321.3 ms**，中位数改善 **106.25 ms**，本批 P1 数值达标。新旧 exe 分别为前述 `fae6657a…49426`／`14659ac7…059e7`；r10b 仍按实际 dirty 构建身份，不倒写本次 HEAD。两个执行目录均无随包 ConPTY 旁车，P00 全部公平性字段及 rF 绑定尚未完成。
- **调度偏离保留**：启动上述通用驱动后，才从独立差集核对找回早先 `no_more_P7_retries=true` 的裁定。本次附带缩放不应再采，原件保留为额外诊断，不能择优替换旧 P7 **0/60 对 0/60 的 FAIL**。本批原始 proxy 为 old 1/60、r10b 0/60；新版零 timeout 未附能力声明，不把缺日志补成已证明零事件。120 图 root 已抽查 12 张，O2 完整复核待回报；所有 Ghostty 进程复查为 0。之后不再安排 P7 重采。
- 图谱已按两份 r10 native 变化经标准生成器重建，1192 源文件；`graph-check`、`kb-check`、`rules-check`、`git diff --check` 均通过。既有 35 个头文件解析限制不变，不宣称完整头文件符号覆盖。
- 最小剩余队列：**P4 最终数值**（先有 r10 能力绑定，不新增优化轮）；**Windows P2/P3**（遵守原当日额度，P3 先修前置夹具）；**C1/C5**（先解决计量有效性，不复用被拒样本）；**C3、长 IME、其余 V/功能边界**（只补已核差集）。C7 同环境停止重复诊断，保留环境 PENDING；Win10 本轮不做。
- P5/P6 Windows、P8、GTK P2、C6、C8、C2-G 优先做身份／覆盖核对与签收，不因报告旧视觉 PENDING 字段重复采样或读图。V2 已有 18 次环回原件，优先绑定，不误称完全未做；人耳试听仍 PENDING。142 叶继续复用场景映射，不新建逐叶场景。
- 手工证据追加例外虽已获用户批准，安全策略文件尚未由人工落实，正式审阅归档与账本写入仍受阻；不通过换工具／目录绕过。对应待生效的 hook 测试仍 RED、未提交，本次局部通过不代 `framework-check` 或最终整套通过。

## 历史依据（截至 2026-10-18，正文原样保留）

本计划依据当前对话 2026-10-14 的授权、2026-10-17 的模型分工更新及 2026-10-18 第 6 阶段与后续裁定，覆盖旧交接文档的任务组织、构建频次和提交授权；功能范围仍是 F1–F10，原完整验收契约（`docs/GX_UI_REMAINING_PLAN.md`）中的门不因本计划而视为通过。原定截止北京时间 2026-10-14 02:48 **已超期**，如实保留，已用时间不清零。当前总状态 **`not_complete`**。

## 第 6 阶段（2026-10-18 起，进行中）

本节只概括第 6 阶段的安排，不记录任何结论。完整真源是用户批准的计划原文 `.local/evidence/R5/execution-20261013/final-r3/phase6-plan.md`（该目录下称 F3）与子智能体共同合同 `F3/r6-contract.md`；本节与二者不一致时以原文为准。总状态仍为 `not_complete`，后文各节的历史记录保持原样。

本阶段最新模型分工、安静判据与授权继续有效；下列波次保留原安排，r9 的实际执行与原上限偏离见文首检查点。

- 目标：在本机、Win11/Win10 VM、WSL 与 gx-ci 能覆盖的范围内，把 C1–C8、V1–V7、P00–P9 与远程性能、8 组功能边界、平台项、142 叶签收与 R6 收口逐项做出确定结论；发现缺陷就修，不降门槛，不改写历史结论。
- 结论口径：PASS；FAIL（已尝试修复，原件保留）；PENDING（写明环境原因与补验命令）；BLOCKED（附轮询记录）。142 叶另可记 PASS_SCOPED（列缺口），C 项另可记 INSUFFICIENT，见下文与 F3。
- 已定选择（仓库与 CI）：恢复 6 个 `wip/R4-*` 分支继续 C1；允许 push 到 `origin/gx_ghostty`，并手动触发 gx-ci 的 macos、gtk_smoke、win_smoke。
- 已定选择（环境）：VM 内可以建账户、改设置、用讲述人，可以下载钉版 Win10 ISO；宿主系统设置一律不动；GUI 与性能按身份型安静判据自动轮询。
- 已定选择（改动）：P4 允许弹层隐藏复用加空闲预排版，DComp 仍默认关闭；默认值改动由 agent 加独立复审按合同决定，逐项单独提交；新上游补丁按合入顺序从 GX-0045 起由 root 编号。
- 分工（同时不超过 10 个子智能体，每个文件只有一个写者，归属表见 `F3/r6-contract.md` 第 5 节）：root 负责调度、构建与 VM/WSL/桌面/性能的实际执行、接口裁决、集成提交、push 与 CI。
- 实现工位：A1 Windows 埋点、P4 优化、采纳项接入与 Windows 缺陷修复；A2 `gx_perf.py`/`gx_slots.py` 新能力与远程性能链路；A3 迁移、会话、IPC、UIA、OLE、broker 夹具及相应修复；A4 GTK 侧 C1 集成、C2-G、C5、V7 与编辑器、管理器边界修复。
- 辅助工位：O1 CI 修复、VM 相位、W/G 场景、C 变体分支与文档；O2 全部截图逐张读图，root 抽查不少于 10%；D1 142 叶映射、影响集、证据 JSON 与账本；R 在每个 src 提交前独立评审，P4 与 C1 另加 Astra 交叉审。
- 当前模型分工（2026-10-18 用户更新，覆盖下文历史分工）：中等任务（原因明确的修复、返修、测试与夹具）使用 `worker`，显式指定 `gpt-6-astra` / `medium`；复杂任务继续用 `gx_complex`（Astra / `xhigh`）；所有现有及后续原定 Opus 任务（简单实现、VM、文档、逐图审阅等）统一为 `gpt-6.1-sol` / `max`，`gx_simple` 的持久角色配置同步更改；当前会话仍显式指定模型，避免已加载的旧角色缓存继续使用 Opus。正在进行的 Opus 工位也必须交接替换，保留证据和自有运行进程状态；历史记录保留实际使用的模型。机械工作用 `gx_mechanical`（DeepSeek），独立评审用 `gx_ghostty_reviewer` 并显式选用 Sol max。
- 波次一：W1 叶映射与 W2 工具、埋点、夹具并行；W2 还把外部 BellBorder 与两个 R2-Font 场景导入为 W21–W23（新 Windows 场景从 W24、GTK 从 G17 起连续编号），并建 `wip/C4-stack4m`、`wip/C6-nowarmup`、`wip/C7-blink-control` 三个只改一个变量的变体分支。
- 波次二：r6 构建只做一次；W3 功能补验（宿主、VM、WSL，不需安静窗）；W4 在第一次安静窗做决策实验（C1 两批十对，C4–C7 各十对）。
- 波次三：W5 工程改动与采纳项接入；r7 构建候选 rF，仍有修改最多再出 r8 一轮后冻结源码；W6 在 rF 上跑最终门，第二次安静窗跑 P00–P9、远程性能与 P4 终测。
- 安静判据（2026-10-18 用户允许忽略其他软件运行状态）：性能批次开始前与结束后都要满足 Windows/WSL 无本项目构建或测试、验证 VM 已停、quiet 拿到全部重型槽和桌面槽。Devin、ToDesk、Kimi Code、哔哩哔哩等软件与全机 CPU 只记录，不作门。Windows 桌面批次仍要求开始前用户无输入不少于 10 分钟，批次内按是否注入输入使用输入时间或前台/指针守门；仅在 WSL/Xvfb 运行的 C1、C5、P9 及 GTK P2/P4 子项对用户输入只记录。结束后门不满足则整批 INVALID，原件保留、改日新目录重跑；每 15 分钟轮询，每批每天最多 3 次，其他工作完成后再等 24 小时仍不满足记 BLOCKED。旧判据下的轮询与 INVALID 不改写，细则见 `F3/r6-contract.md`。
- 「明确收益」（C1、C4–C7）：目标指标 median 与 p90 都改善、median 差大于两侧 IQR 的较大者、守护指标 median 不按同一界限变差且功能与视觉检查全过才采纳；目标变差或任何功能回归即拒绝；其余记 INSUFFICIENT（新改动不采纳、已合入项保持、实验分支保留）。
- 其余口径：P1–P9 阈值、C1–C8 各项判据与 142 叶签收规则以 F3 计划第 4 节为准；R3-AppMode.04 维持 DEFERRED，R2-Font.04 取 C6 结论。
- 预期终态：各项给出确定结论后总状态仍为 `not_complete`；macOS app、宿主真实多 DPI、真实 TDR、GTK 原生手势与 IME、硬件 DMABUF、V2 人耳试听、Win10 中文输入法与现代 GTK 性能预计仍 PENDING；一直没有安静窗时 P 门与 C1、C4–C7 记 BLOCKED。

## 既有授权与组织（历史，当前以第 6 阶段为准）

- 只派当前会话的原生子智能体，同时活动上限 10 个；不建独立对话或后台 CLI 会话，不恢复已归档的独立对话；当前对话里已完成的原生子智能体按需 followup 复用。子智能体直接指定 `model`、`reasoning_effort` 与 `fork_turns:"none"`，不改客户端配置。
- 模型（2026-10-17 用户更新）：中等及以上复杂度任务默认用 `gpt-6-astra` `xhigh`，包括跨模块接线、系统集成排障、跨进程生命周期、协议与绑定续延；边界明确的简单实现、简单修复、常规夹具和文档用 `claude-opus-5-5` `xhigh`；清单、哈希、映射、证据 JSON 等机械工作用 `deepseek-flash` `max`。按任务实际复杂度分配，不仅按文件类型分配；简单任务出现多模块或系统行为不确定性时转交 Astra。DeepSeek 的 fresh 明文探针已返回 `DEEPSEEK_PLAINTEXT_OK`；探针或创建成功不等于该模型的产出已验收。
- 全机重型任务（构建、完整测试、VM、性能）最多 3 个；同一工作树的构建串行，构建期间冻结相关源码；宿主桌面独占，GUI 与性能不并行。
- Windows 与 GTK 完整 main 各已运行一次（final-r2），不再重复；新编译后只重跑受影响的定向测试与场景。打包不重编，翻译、KB、图谱在源码与文档冻结后各生成一次。
- 用户已授权把全部已有与新增改动做本地阶段 commit，无需逐次确认：精确暂存、提交信息按根 `AGENTS.md`「提交规范」。不 push、不建 PR/Issue/tag/release、不新增下载，不触碰 `GX_API`。
- 主树按文件单写者工作；所有权按文件显式移交；状态经原生消息回传，不共写状态文件。文档、CHANGELOG、补丁登记与证据导航由文档工位独占，证据 JSON 由机械工位维护。

## 历史｜当前状态（2026-10-18 核对）

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

## 历史｜功能状态

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

## 历史｜批次记录与收尾

原定构建/打包次数已因真实系统缺陷超出：r3 合并 app/test-bin，r4 仅 app 热修，单独 Toast 日志诊断 app，以及 r5 冷激活提示的必要热修（合并构建 app 与 test-bin 一次；首次因 PowerShell 拆分版本参数报 InvalidVersion、未编译，原件保留，修正参数后成功）；r3/r4/r5 各离线打包一次，诊断 app 不作为最终包，其源码改动已撤回。未追加完整 main。已生成的 KB/图谱在真源再变后需重验新鲜度，按实际影响补生成，不把旧产物冒充最终冻结结果。

1. 已完成：broker 拖放（四方向最小文本矩阵与取消、允许、多行保护）与 Toast 热冷激活等系统集成排障由 Astra 承担并闭环，简单夹具与文档由 Opus，证据映射由 DeepSeek，root 统一测试根、构建、VM 输入与接口裁决，未新增独立对话。既有远程修复证据保留，不重做。后续若出现新异常，仍按此分工：中等及以上的排障与修复交 Astra，构建只按实际影响补一次并保留失败原件。
2. 已完成：r3 合并构建一次 `install test-bin`，受影响并集 50/50（seed `0x52553301`）非零命中，未重跑 main。r4 只改启动令牌权限，不再重编测试；r3 结论不计为 r4 新套件结果。
3. 已完成：r3 复跑受影响远程子集（取消后正常输入、330 次 split/resize、目标丢失回收 15/15 干净退出），52 图已读并以旧失败原件对照；W09/W12 增强后复验通过。
4. 不改变 GTK 生产路径的 Win32 专用修复复用 `38e3e644f` 证据；若共享修改实际影响 GTK，再补对应编译与定向。不得因 commit 或文档变更全量重编。
5. r4 已离线打包（不加 `--build`）并安装；r3 卸载无残留，JumpList 与接收器配对通过。medium→high 真实拖放的文本取消、允许不追加回车与多行保护取消已通过。同用户 direct 三向（medium→medium、high→medium、high→high）最小文本拖放均 native 与读图 PASS（`F/vm-resume-20261018-direct/`），与 broker 合计为 F6 四方向最小文本矩阵 PASS_SCOPED，不扩大为原完整 files/URI/DPI 矩阵。三个 app 已正常关闭，注册 inspect 通过，r4 最终卸载无残留（Win11 卸载属于本次功能门，未延期）。Toast 热激活已通过；冷激活原生部分成立，但前台提示在 r4 上 FAIL。r5 已 review、构建一次 app 与 test-bin、定向 23/23 通过并离线打包。inst-r5 安装后热激活与冷激活均已复验通过：冷激活提示历史目标不可用，前台可见并保持 21 s 以上，Esc 关闭后 toast-server 正常退出，未开新 shell。无激活 15 s 退出（单独 idle guard，不代冷点击）与 r5 最终卸载均 PASS_SCOPED，VM 已 owned stop 关闭、磁盘保留。本条工作已全部完成。早期关闭探针先明确请求是否送达，不能以超时猜产品根因。
6. 完整框架单测已于 10-18 集中运行一次（结果与原日志见「当前状态」，唯一 FAIL 为 KB 新鲜度），fmt-check、fluent-check、graph-check 在 r5 修改前已 exit 0，图谱已按 r5 两源变化重建；r5 源码冻结后 graph-check 与 fmt-check 重新 exit 0（本轮工具记录），i18n、pinyin、fluent 真源未变且 check exit 0。root 已运行 `just kb` 并只补跑 `python -m unittest scripts.test_agent_kb.RealCorpusTests`，6/6 通过（`F/kb-final-20261018.log`）；本次状态更新随交付记录再次生成并校验 KB，精确本地提交；不运行会重复 936 项的 `just framework-check` 或 `just ci-check`，936 项整框架只在 10-18 运行过一次，其 KB FAIL 原件保留，组合证据只写实际执行的命令，不冒称重跑 936 项或聚合命令运行过。原 `ci-check` 的 VT、独立 POSIX、Win10/升级、硬件/性能/macOS 与正式 142 叶签收按已批准延期表保留 PENDING；P4 保留既有 FAIL。

每项逐条记 PASS / FAIL / PENDING / BLOCKED / N/A 并附原件；未运行项写补验命令与理由，不写假绿。
