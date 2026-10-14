# GX UI 剩余任务接手计划（主分支收口版）

> 生成日期：2026-10-13。用户已明确暂停功能开发，要求把正式成果合回 `gx_ghostty`、归档后清理关联 worktree，并交接剩余任务。**原产品计划仍是 `not_complete`。本次合入是暂停检查点，不是 GUI、性能、发布或 R0–R6 全部验收通过。**
>
> 本文件是新 agent 的入口；同仓 `docs/GX_UI_REMAINING_PLAN.md` 保留原始完整验收契约，必须一并读取。本文覆盖其过时的模型/goal 工具、主分支 SHA、worktree 存在性、合入状态和 R5-00 进度；其 D1–D17、142 叶需求、C/V/P 数值门及 R5 十一流范围不缩减。不要只读摘要后执行，不需要访问旧私有会话才能理解任务。

## 0. 可直接交给新 agent 的启动提示

```text
完整读取并执行：
E:/gx_projects/gx_ghostty/docs/GX_UI_HANDOFF_PLAN.md
以及该文件指定的原验收契约 docs/GX_UI_REMAINING_PLAN.md。

我授权继续所有剩余任务，使用当前会话实际可用模型和任务管理工具；不得冒称另一模型或复活旧 agent/task/goal ID。延续精确中文本地 commit 与 --no-ff 合入 gx_ghostty 的权限；不 push、不移动 main、不创建 tag/release/Issue/PR。
先核当前 HEAD/tree/dirty、归档和证据，保护未知改动。旧 worktree 已按收口清单清理，不能直接 cd 旧路径或用旧二进制冒当前验证。恢复实验时使用保留分支/固定 SHA 与原始归档，不把未采纳实验直接叠进主源码。
完整完成剩余 R5-00、R5 十一流、C/V/P 与 R6；已闭合源码不重做。未验证、未达标、环境阻塞和历史失败均保留，不将暂停合入或定向测试冒称 complete。除非另获许可，不安装/注册/下载、不操作未知进程或未知用户剪贴板。
```

当前这份文档本身不恢复开发。仅审阅时明确发送“只读审阅，不执行”。新会话是否执行以用户的新消息为准。

## 1. 当前源码与收口选择

### 1.1 可核对的固定身份

所有 Windows 路径以 `E:/gx_projects/gx_ghostty` 为根。

| 对象 | 固定身份 / 语义 |
|---|---|
| 收口前主分支 | `98e89ac4e92b3b22284ba8d4256a511e0bc8a9ef`，tree `210ddbe9187e2cc68efb9959ecb930a57f10cbcf` |
| 原 R23 正式候选 | `d6f9e1c03587971096ea595cedc614f47a99ef5e`，已随完整历史进入主分支 |
| R5 稳定引用纯值切点 | `bfc0e6a7da54223572af9d73caff99cc40d452dc`；其三平台 21/21 是历史定向证据 |
| 本轮初稿保存提交 | `f5dc4fd28fe7566f63fd7b7f4b21232a2324243c`，tree `6a8226ea8e232c54b31697db6ebe782af1c009b8` |
| 正式历史 no-ff 合入 | `88fb44bd2a875fd1071a8bb081452f064a0e82a1`，tree 与上述初稿相同 |
| 补回遗漏 R3 提交 | `85d93f074ec564106e7dda809b9b7705c45d631d`：GTK 启动诊断在首个窗口内显示 |
| 本次业务源码最终合入点 | `7a4e90c1bdfd2fbbda1d49b9f3d0cff0653e8fcb`，tree `a791fd45c063928623eb5d1f48fd3754373cb1ab` |
| `main` 镜像 | `246f702876b924a1cb7cade1e99274d1470302fc`，本轮未移动 |
| 文档/生成物提交后的 HEAD | 用 `git rev-parse HEAD HEAD^{tree}` 实查；不得将上面的业务源码切点误认为永远是 HEAD |

`gx_ghostty` 已包含 R0/R1、R2/R3 正式实现、R4 mandatory、标准 GTK harness、Overlay/COM/GUI 安全守门、稳定引用纯值模型和 Windows 接线初稿。祖先关系比旧账本 `workflows.*.next` 可靠。本次盘点发现 R3-Upstream 最后一条修正此前确实漏合，不能再沿用“所有 R3 tip 都是候选祖先”的旧说法。

### 1.2 用户本轮明确选择

1. **正式成果合入，实验保留**：GTK Pipeline 和三棵测量变体不进入主业务源码；分支、提交和归档保留。
2. **初稿最小修正后合入**：只修编译阻塞，不继续 GTK/新功能开发；初稿仍待审、待真实 GUI。
3. **归档核验后删除 49 个关联 worktree**：不强制删除，不删源分支、主工作区、共享依赖或 WSL 独立克隆。准确操作结果见第 3 节收口账本，不以授权替完成事实。
4. 本次检查点合入不要求伪造原计划最终全绿；剩余总门全部进入下一轮。以后最终完成仍受原门约束。

## 2. 当前实现状态与下一处代码入口

### 2.1 已保存且不要重做

- `src/gx/gui_settings.zig::Overlay.getAll`：按文件顺序保留重复、空 reset、裸键；外层切片由调用 allocator 释放，元素借用 Overlay 行。原三平台相关验证各 79/79，文档与独立复审已关闭。提交 `12db5cef2`、`038e0563f`。
- `src/apprt/win32/ComApartment.zig` 和 App 接线：GUI COM/OLE ownership、S_OK/S_FALSE 配对、初始化失败、关闭防重入。提交 `754158863`。
- `scripts/gx_win_gui.py`：隔离 LOCALAPPDATA、APPDATA、XDG config/state/cache；每次输入核 PID、birth、exe、foreground 和点位，保存 creation time。提交 `7da79b69d`、`c8664fe01`。不要移除负例或放宽守门。
- `src/gx/ui_ref.zig`：epoch/kind/id/generation；Attachment 分离 view revision/owner；Window 只能自绑定；耗尽失败且不复用。提交 `16d0d514a`、`bfc0e6a7d`。
- 原 R23 的 R2/R3 晚接线、BellAudio/BellBorder/ChromeAlpha/D11、Renderer/Defaults/GTKInput/Webgen/Font mandatory 已保留完整历史。原契约第 2 节列有源 SHA 和证据，不能重做整轮审计。

### 2.2 本次已合入但未完成的初稿

`f5dc4fd28` 只涉及四个源码文件：

| 文件 / 符号 | 已写入主树 | 下一轮必须补齐 |
|---|---|---|
| `src/apprt/win32/App.zig` | 每 App 随机非零 `ui_ids` epoch；`resolveWindow`、`resolveSurface`、`resolveSurfaceView`；退出使 epoch 失效；保留 default profile ID | GUI 单写者契约和 shutdown/reentry 实审；异步/modal/COM 消费者真正迁移，不能只增字段；完整 Window/Tab/view 解析需求 |
| `src/apprt/win32/Window.zig` | Window/Tab reference、attachment；TabSlot 移动携带身份；add/move split/move tab 预留引用；`resolveTab`；deinit 撤销 Window 身份 | hide/reopen 的 view revision、跨窗中间态/回滚、Tab/view 解析和真实 GUI；当前没有 R5-01 拖出/合并新功能 |
| `src/apprt/win32/Surface.zig` | core ID 不变的 Surface reference；初始化/销毁；`prepareReparent` 预留新 attachment，`onReparented` 发布；拥有 LaunchOrigin | 验证 init 后引用分配失败的完整 unwind；SetParent 泵消息期间旧引用是否应暂时失效；所有失败/回滚；旧 owner 关闭后的 popup/search/scrollbar；没有跨 host PTY 转移 |
| `src/gx/profiles.zig::LaunchOrigin` | `unknown/ad_hoc/profile`，clone/deinit/profileId/select；只复制稳定 profile ID；initial-command 优先判 ad_hoc；Win32 显式 profile、默认和 duplicate 路径传递 | 公共接口 ownership 文档、无效/失效/改名 profile 语义、GTK 传递；现有 configured command 未猜成 profile，未知来源不可直接恢复；不能当 session restore |

当前初稿没有独立源码复审，也没有该新树真实 GUI。其测试覆盖不等于以上遗漏已解决。下一轮先审这四个文件，必要时最小修正，不直接并行开发所有消费者。

**停止时失败与修正**：LaunchOrigin 测试曾对 union 的标签 `LaunchOrigin.ad_hoc` 直接调用方法，标准测试根编译失败。收口只改为 `@as(LaunchOrigin, .ad_hoc/.unknown)` 并将原 `findEditOwner` 注释放回正确位置。原始错误与红绿记录见 `draft-validation.json`、`runtime-origin-red.txt`，不删失败。

### 2.3 R5-00 共同接口仍待冻结

必须完成后再放开依赖消费者：

- 两端稳定对象引用和 view attachment 生命周期；GUI 单写者、活对象查找、modal/COM 返回重查。保留活 PTY、core Surface ID，IPC 不带裸指针。
- GTK 优先复用 GObject qdata、既有注册的 hooks、WeakRef 和 dispose/finalize；不能为了接线把 GX 逻辑大段写进上游类。读 `src/apprt/gtk/gx/{window,app_mode,launch,app}.zig` 与 `class/{application,window,tab,surface,split_tree}.zig`。
- GTK Application profile cache 已存在于 `gx/launch.zig`，不要误判全无；完整共用生命周期、LaunchOrigin、静默 reload/回读还未收口。
- COM owner 已有，但有界 owned 消息队列、GUI 执行后 ACK、通知/IPC/shared shell identity 等接口尚未完成；WinRT MTA 不改变 GUI STA。
- 安全 fixture 基础已修；多次 restart 同 private state、新 birth、多 launcher、UIA MTA/OLE source/popup reset 等专用 fixture 尚缺。真实系统注册不是设置环境变量即可隔离。

已冻结产品选择：**会话恢复默认关闭，由用户启用；普通 Windows 启动复用同隔离域主实例，`-e` 独立启动，支持显式独立。** custom/ad-hoc restore 仍需确认或拒绝策略，不能重放任意命令。两个 launcher 路由同一 host 不构成两个既存活 PTY host 之间的转移。

## 3. 证据、归档与恢复

### 3.1 本次入口

- 收口证据根：`.local/evidence/UI-closeout-20261013/`。
- `worktrees-before.txt`：原 50 个工作区（主工作区 + 49 个关联 worktree）的路径、SHA 和 branch。
- `branches-before.txt` / `branches-after.txt`：清理前后分支清单；`worktrees-after.txt` 已只剩主工作区。
- `source-branches.bundle`：源码合入点 `7a4e90c1b` 时全部 refs 和完整历史，`git bundle verify` 已通过；不包含之后的交接文档提交，主仓仍是最新真源。
- `runtime-origin-draft.patch`、`draft-validation.json`、`runtime-origin-red.txt`：本轮初稿、修前失败和有限验证。
- `windows-draft-tests.json`：初稿定向 481/481，0 skip，seed `0x52553030`、jobs 3。
- `windows-merged-tests.json`：主仓实树定向 481/481，0 skip；`windows-build.log` 的 `just build` 成功，`ghostty.exe` SHA256 `BAC395276C45646C87659D98C028BDA7D655A279A4C932AAD49E4FCEE1549C8F`。
- `gtk-merged-tests.json`：GTK 定向 30 项，29 PASS、1 SKIP（`gx.profiles.test.wslDistros reads the registry`）；`posix-merged-tests.json`：POSIX 定向 25 项，24 PASS、1 SKIP（同一注册表测试）。
- `archives.sha256`、`archive-run02.log`、`pre-delete-worktrees.txt`、`cleanup-result.json`：49 个归档全部 `tar --compare` 且 SHA-256 `OK`；49 个已确认目录全部删除，Git worktree 元数据已 prune。第一次 `archive-run.log` 的 Windows 盘符误识别失败保留。
- 主根 `.local/evidence/`、`.local/r23-state.json`、`.local/bin/slot.sh`、`desk.sh` 保留，不随 worktree 删除。

归档根：`.local/worktree-archives/UI-closeout-20261013/<原目录名>.tar.gz`。每个归档含对应工作树源码、`.local` 下证据/日志/私有 fixture、`zig-out` 和其他本地文件。仅排除明确可再生的顶层 `.zig-cache`、`zig-pkg`、`.local/zig-cache`、`.local/cache`、`scripts/__pycache__`；tar 未启用 dereference，不跟随外部依赖链接。历史二进制只用于历史核验，不作为当前构建。

**旧路径转换**：旧记录中的 `.local/worktrees/<name>/<relative>` 在清理后不再存在。先核对应归档的 SHA256，再把需要的 member 解到新建的独立证据目录。不要恢复归档中的 `.git` 指针覆盖新 worktree。尤其原 `I = .local/worktrees/R23-int/.local/integration` 在 `R23-int.tar.gz` 的 `./.local/integration/` 内；R2-Font 历史 A/C 产物在 `R2-Font.tar.gz` 的 `./.local/out-release-{A,C}/` 内。

查看/恢复示例（先验证父目录和归档摘要，目录必须新建且无未知文件）：

```bash
sha256sum -c .local/evidence/UI-closeout-20261013/archives.sha256
tar --force-local -tzf .local/worktree-archives/UI-closeout-20261013/R23-int.tar.gz
# 仅提取需要的 member；不要整包覆盖仓库或导入旧 .git。
tar --force-local -xzf .local/worktree-archives/UI-closeout-20261013/R23-int.tar.gz \
  -C <新的证据解包目录> ./.local/integration
```

### 3.2 原证据入口与真实状态

- `.local/evidence/R23/integration/devin-20261013/resume-state.json`：此前恢复核查和小切片验证；其主分支/旧 worktree 字段是历史切点，当前状态优先看本计划和收口账本。
- 同目录 `leaf-matrix.json`：142 个 leaf 已登记；最终树绑定仍 PENDING。
- 同目录 `getall-final.json`、`com-gui-results.json`、`ui-ref-final.json`、`framework-check.json`：历史范围明确；不搬旧测试数字当当前新测。
- W22 COM 链、W01 标题回归曾有限 PASS；共 11 张图已读（包括 W16）。**W16 旧 expect 与右侧菜单锚点契约冲突，视觉验收仍 PENDING**。
- 原 framework：884 总 = 869 PASS + 14 SKIP + 1 KB freshness FAIL；旧 TempRepo WinError32 保留，本轮之前未复现不等于已修复。
- 收口后 `just framework-check`：885 tests、14 SKIP、0 FAIL；`just graph-check` 仍 FAIL（源指纹 1063→1117），最终前必须 `just graph` 后复验。
- `.local/evidence/R4/GTKPipeline/quiet-reviewed/`：三棵标准 RF build、receipt/hash/version、原 quiet、commands、summary。原 unsafe 40 loads 永久 REVOKED；bootstrap 不计产品门。
- 最近三次补充 quiet：37→26%、29→15%、33→11%，外部同 birth 进程持续 CPU；无 owned build/test、空 slots 并不等于 full-machine quiet。**仍 0/40 新 loads、0 新截图、DATA_VALID=false、Gate/Pool INSUFFICIENT**。
- `.local/evidence/R23/OSC52Transport/`：bundled ConPTY raw transport 与真实 core/UI 是不同证据。

### 3.3 实验分支与 WSL

以下分支保留，不合入主源码，也不因清理目录而认为实验已拒绝：

| 分支 | 固定 SHA / tree |
|---|---|
| `wip/R4-GTKPipeline` | `1d11fc890bdb21a3b56a1c702c7260e4ef8d3dea` |
| `wip/R4-GTKPipeline-gate-only` | `db017b7aaa137ce7cd5ba11650ae55ca10b3ce28` |
| `wip/R4-GTKPipeline-gate-v2` | `f9748b02d4a3d01523011fd3802c46f229277baf` |
| `wip/R4-GTKMeasurement-base` | `fe2b233bd862c9105bc13dcb25fbdcece0bf1c49` / `856ddc25e8b3a40d5b9b60b1e997c14e8e8b4459` |
| `wip/R4-GTKMeasurement-gate` | `b3fce03df816179377f9438d5d0b8612ef9ed7c5` / `dc89beb2344e23404fd04c8ebfb450ec0b40927b` |
| `wip/R4-GTKMeasurement-combined` | `0ca3cf5629d23e8b8408415fb258482a7bf85b14` / `56d9ecef7aa3703d7f35fffbfd2559f82368ff01` |

重新需要 Windows 测量工作树时，核分支 SHA 后 `git worktree add <新目录> <保留分支>`；不要盲并三变体。C1 标准桥必须从 base 变体运行，主树标准 harness 不含全部实验诊断和最新 n 校验。原契约第 5 节的命令要把已删除 cwd 替换为新恢复目录，argv/env/顺序/门保持不变。

WSL 发行版 `Ubuntu-24.04`，用户 `gx`；本轮未删独立克隆：
- `/home/gx/src/gx_ghostty-R5-00-overlay` 是本轮复用验证克隆，虽名 overlay，已同步源码合入点 `7a4e90c1b`。不存在 `gx_ghostty-R5-00-refs` 克隆，不要猜名称。
- 三测量克隆 `/home/gx/src/gx_ghostty-R4-GTKMeasurement-{base,gate,combined}` 保持独立；使用前只读核 clean/SHA/receipt/exe，不无理由重建。
- 其他 WSL 克隆未列入本次 49 目录删除授权；需用时 fresh 查身份，不删除、不覆盖未知内容。

## 4. 新 agent 的最短接续流程

1. 完整读本文件和原契约。运行 `git status --short --branch`、`git rev-parse HEAD HEAD^{tree} main`、`git worktree list --porcelain`、`git log -6 --oneline`。确认无 MERGE_HEAD、未知改动先保护。
2. 根 `AGENTS.md` → 对实际触及路径运行 `just rules` / `just rules-review` → 读全部返回域和嵌套规则 → `just rules-check`。图谱过期时直接读源码，不重做旧审计、不依据旧 graph 下结论。
3. 读收口账本、最新测试结果、原 quiet 四原件和 leaf 矩阵。归档中的证据先验证再定向恢复；不要沿用旧 PID、任务或截图结论。
4. 使用实际可用的 todo 管理；没有 GetGoal/CreateGoal/TaskList 不虚构恢复。工具访问 `.local` 被 ignore 屏蔽时让用户通过客户端合法设置解阻，不改仓库忽略/权限绕过。
5. 先审 `f5dc4fd28` 初稿与 R3 补合影响，补最小运行时/ownership 合同；然后完成 R5-00 GTK/LaunchOrigin/消息接口。C1 quiet 不成立时继续安全源码任务，不让性能环境阻塞全计划。
6. 新工作树可从当前 `gx_ghostty` 创建；只在明确 scope 上写入。Windows 和 WSL 共用最多三重型槽；GUI/bench 独占桌面。`slot.sh`/`desk.sh` 有按锁年龄回收行为，未知锁不能按年龄回收，执行前核当前归属。
7. Windows Zig 经 `scripts/zigw.py` 钉版 0.16.0；Git Bash 可设 `ZIG_GLOBAL_CACHE_DIR='E:\gx_projects\gx_ghostty\.local\zig-cache\global'`。`--clone "~/src/..."` 保留引号；PowerShell 调 WSL 原生绝对路径避免 MSYS 转换。不得为测试擅自下载依赖。

## 5. 全部剩余工作与依赖

完整任务细节仍以原契约对应章节为验收清单，下面每项都必须留在新任务账本，不能用一个“R5完成”勾选代替十一流。

| ID | 当前状态与实际下一步 | 依赖 / 关键完成门 |
|---|---|---|
| V00 | 142 leaf 已登记，给 D1–D17、R2/R3 每叶绑定最终 source/tree/入口/unit/native/GUI/raw/读图；只补缺口 | 原契约 §7.1，最终证据默认 PENDING |
| C1 | full-machine quiet BLOCKED；恢复正确测量树身份后，两批完整十对 = 40 loads；不得 warmup/补样/滤外部负载 | 原 §5；canonical AB/BA、1280×800×24、三 env、全部末图 3000000；median/p90，合理 CPU 精度说明；决定 Gate 与在 Gate 上 Pool 边际 |
| C2、C2-G | 96 DPI 默认渲染/alpha/字体对照、GTK prompt 光标与 shell 集成优先级 | 原 §6.1；不能先把静态风险认作 bug、不能擅改默认 |
| C3/C4/C5 | 系统双击默认、线程真实 commit/深栈、生产软件 GL 下 cairo 选择 | 分别实测，保护显式用户值；C1 cairo 不等于 C5 已采纳 |
| C6/C7/C8 | 当前源码仅 warmup 变量十对；blink idle CPU/wake/draw 及动画/IME；env append/vsync 完整外部合同回归 | 历史 warmup 混杂数据保留；C8/GX31等源码已合不重写 |
| R5-00 | 完成 §2.3，四组共同接口冻结 | Windows 初稿不是完整运行时闭合；GTK、异步消费者、专用 fixture 尚缺 |
| R5-01 | >15 DIP 纵向 detach（等于15不触发）、10 DIP 横向；真实跨窗合并、整树/zoom/active/override、事务回滚、系统移动后重查 | 依 R5-00；跨 host 依 R5-06，既存 PID/birth/PTY/Surface/scrollback 保持，不能新 shell+kill 源 |
| R5-02 | 两端默认 off 的安全 session；有界 versioned schema、稳定 profile、typed cwd、树校验、原子写/租约/代次；关闭与 Quit 语义 | 禁命令/argv/env/dynamic title/输入/scrollback；种子消除 initial-command；真实多窗/嵌套/zoom/字号/中文标题 restart，Quick 排除，CLI 优先 |
| R5-03 | UIA Simple/Fragment/Root 和真实 patterns；owned snapshot、provider 独立寿命、post 后 GUI 核 ref、旧节点 inert | bounded 外部 MTA client，查询/事件同线程，真实通知与无 focus 死锁；OBJID_CLIENT 规避保持返回0；Win10 动态探测 |
| R5-04 | OLE IDropTarget/Helper、bounded text/files/typed URI、medium 配对、protected paste、不自动 Enter | 真 OLE source，不触未知 clipboard；四权限方向分别测；管理员兼容需合法 broker+认证+高端明确预览确认，拒绝不冒全部兼容 |
| R5-06 | versioned bounded named-pipe IPC、本机认证/隔离/双方 PIDbirth、去重/ready/shutdown、有界 owned 队列、GUI 成功才 ACK；真实 toggle CLI | 普通复用、-e独立；GTK 保留 GApplication/D-Bus；不 ASFW_ANY，不跨隔离域，不把路由称跨既存 host PTY 迁移 |
| R5-05 | 共 shell identity/AUMID/activator，WinRT MTA 系统 toast、warm/cold 两种激活、双目标稳定引用 | 依00/06；DND/用户关闭不绕到balloon；真实注册/升级/安装必须获许可VM/测试账户，portable不自动注册 |
| R5-08 | 同 identity 的 JumpList，owned cached profile snapshot、稳定ID、Windows argv编码、事务失败Abort保旧 | 依00/05/06；不raw command/cwd/历史/凭据；开始菜单/列表真实写入另需测试环境许可 |
| R5-07 | 0.15.0钉源、primary+现代读音的全音节变长DP，literal优先/首字母保持/ü→v不并u/末音节prefix/高亮同路径 | 原数据取得另许可；离线生成check与双许可；zhongwen/zhw/chongqing/yinyue/yinle、边界和P4；不改上游GTK palette |
| R5-09 | MIT官方Fluent SVG钉revision/hash，离线确定性路径生成，fill mode/多figure/洞/曲线，D2D共享geometry与状态恢复 | 无输入不得编造或自动下载；DPI暗亮高对比实际图，默认系统glyph保留，不分发Segoe字体 |
| R5-10 | 默认off的Popup DComp实验；借用context协议、offset/EndDraw/Commit、资源代次、firstframe latch与legacy失败退路 | 环境变量名仍待冻结；只popup不改主WGL；真实逐phase reset/failure图及10pair，terminal reset不代证 |
| R5-11a/b | GTK完整keybind编辑（flags/table/chain/来源/冲突/恢复）及profile CRUD（latest overlay/getAll/只读来源/回读/改名后果） | 不能从速查Row反序列化；getAll已存在勿重做；失败保草稿、CLI readonly、外部编辑不丢 |
| R5-11c/d | GTK geometry真实尺寸/close/restart、各轴CLI/never/Quick/Wayland；移动已有Surface到空Tab/Window | new_tab_menu路由已存在勿重做；不能placeholder shell；旧focus/listener必须解绑，PIDbirth/PTY/scrollback不变 |
| V1–V7 | OSC52真实确认回包；BEL/audio；Alpha DWM；BellBorder四角；搜索/滚动真实来源；Win IME/Quick/DPI/首帧/reset；GTK modern/Wayland/硬件 | 原 §7.2，unit/native/日志不代真实逐图；未知剪贴板不读/备份；app reset不代TDR，Xvfb不代硬件/WM/IME |
| R6-1/1R/2 | 用户真源/CHANGELOG 0.0.3(TBD)/规则/registry；删除已无消费者的三个Win shim；不抬规则预算 | 不改main、不bump；当前public/ownership文档和旧描述待收口；root及域16KiB/KB2.5MiB约束保留 |
| R6-3/4/4A/4W | 最终真源freeze后生成、framework/CI、完整Win main+VT与POSIX+GTK；按实际影响跑CABI/freestanding；三webdata末项全文及suffix | KB可在本检查点更新但不代表最终fresh永续；graph及全量门仍实查；tinyio权限FAIL不能skip洗绿 |
| R6-5/6/7/8 | 最终真实GUI全包和性能矩阵、独立复审、后续本地no-ff、最终gx实树再构建/测试/图、正常清理和真实交付 | 本轮归档清理只完成暂停收口，不关闭未来最终验收与清理；必需门全过才能complete |

### 性能门速查（不替代原 §6.2）

- P00：旧新 source/ConPTY/OS/GPU/字体/DPI/刷新率/网格/采集口径公平性；不伪造旧 baseline receipt。
- P1：启动至窗口显示比基线减少 **100 ms 以上**。
- P2：idle60s全系统进程快照 **每2s最多1次**、与标签数无关；最小化 **0**。
- P3：3窗口×15标签真实拖窗，滚动条重画 **0次**。
- P4：Palette/Menu/Settings 热路径 **≤1帧且无 PATH 扫描**；历史160Hz门6.25ms，Menu十次均FAIL，热median9.548/p9010.213ms，不改成60Hz或“有改善”。
- P5：Keybinds hover每帧 CreateTextLayout **≤10**，绘制 **<2ms**。
- P6：按住↓浏览主题2s，重载 **恰1次**。
- P7：live resize超时次数下降，实际图无黑边/拉伸；保留全窗共享16ms等帧截止。
- P8：每终端渲染目标 **6→2**，实际资源计数，不只常量。
- P9：GTK Xvfb DMABUF失败警告只1次，标准perf renderer CPU下降；软件失败锁存不代硬件成功export/import。
- 全部RF、交替新旧各10次、median/p90、原始单位/n、有效身份和完整截图。没有新性能样本时不填收益值。

## 6. 验证命令与交付判据

命令在对应树中执行，先读取 `--help`、resolver、slot/desk 和当前占用。不同时构建同一树不同目标；不要并行 GUI 和性能。

```bash
python scripts/resolve_agent_rules.py --check
python scripts/run_unittests.py test_fork_patches test_gx_test_roots test_gtk_gx_contract
python scripts/zig_test.py --suite main --filter apprt.win32 --filter gx.ui_ref --filter gx.profiles
python scripts/gx_wsl.py --clone "~/src/gx_ghostty-R5-00-overlay" sync gx_ghostty
python scripts/gx_wsl.py --clone "~/src/gx_ghostty-R5-00-overlay" test --filter gx.ui_ref --filter gx.profiles
python scripts/gx_wsl.py --clone "~/src/gx_ghostty-R5-00-overlay" test --gtk --filter apprt.gtk.gx --filter gx.ui_ref --filter gx.profiles
just fmt-check
just build
just wsl --clone "~/src/gx_ghostty-R5-00-overlay" build --gtk
```

最终阶段还须 `just test`、`just test-vt`、WSL完整POSIX/GTK、`just framework-check`、`just ci-check`、适用的VT/CABI/wasm、`just build -Demit-webdata`、`just generated-check`、`git diff --check`。**定向 481 或历史 79/21 不能代全量。** 新语料写完才 `just kb`；i18n/pinyin/Fluent/graph 只能生成器更新，禁止手改产物。GUI按原W01–W20/G01–G14及外部/新增case完整逐图；W08等先有安全fixture；重要转场重新observe，guard失败立刻停止而非重试洗绿。

交付逐项写 PASS / FAIL / PENDING / BLOCKED / N/A（带理由）；CLOSED只表示源码发现关闭。保存 source/tree/dirty、标准exe/receipt/hash、命令exit、seed/filter/skip、raw/截图及清理身份。没有完整必需门时整体永远是 `not_complete`。

## 7. 接手自检问题

新 agent 开工前应能只凭本文件和同仓原契约回答：

1. 当前业务源码合入点是什么，为什么不能继续把 `98e89ac4e` 当主HEAD？
2. 哪条R3提交原来漏合？本轮初稿修了什么编译错误、还有哪些运行时缺口？
3. 原R23 `I/` 证据和R2-Font A/C产物删worktree后如何核验恢复？哪些WSL克隆仍保留？
4. 哪些实验明确不在主源码？C1测量桥为什么不能直接用主树替代？
5. 最近性能实际样本数是多少？旧40、bootstrap和旧Menu改善为什么不能算达门？
6. session/single-instance默认决策是什么？何为假跨host转移、假session replay和假TDR？
7. GTK引用/LaunchOrigin和十一流是否已完成？下一段实现应从哪里开始？
8. 清理是否代表原R6完成？哪些生成物、平台、GUI、性能与权限门仍需补验？

本轮不声称已做无上下文独立reader测试；未调用子代理。接手者答不出来时先补文档缺口，不重做37份审计、不扩大到其他私有会话。

## 8. 2026-10-13 接续实施检查点（进行中）

本节是后续实施的中间记录，不替代前文验收契约。用户已授权分波并行实施、Docker Windows 测试机部署和钉版拼音／Fluent 素材下载；当时没有 commit/push 授权（2026-10-14 起本地阶段 commit 已获授权，见第 9 节）。主分支 HEAD 仍以实查为准，本轮源码尚在工作区。整体 **not_complete**。

- 新实现覆盖两端稳定引用、GTK 来源／空树收养／分屏迁移／geometry／session／profile 管理、Windows authenticated IPC 与 CLI、共享安全 session、全拼、Fluent 路径及其选中图标接线；Windows session、OLE、UIA 与标签拖出／合并仍在接线和复审。
- GTK 快照 `479c38195` 定向 81/81；`f9a526817` 定向 26/26；`207362f94` 定向 104/104，均零 skip。这些只证明相应快照的选择范围。
- `207362f94` 标准 GTK app 已构建；G05/G08 共四张截图已读，只确认现有分屏／标签和启动菜单回归。真实迁移 PID/PTY、session restart、manager CRUD、硬件／Wayland／IME 验收仍 PENDING。
- Windows 第 6 批保留原 506 PASS、1 FAIL（旧测试要求 `zihao` 不匹配“字号”）。修复后第 12 批 557/557、零 skip，包含 OLE 外层撤销、UIA、session 和全拼。第 11 批 SRW API 编译失败也保留日志；新快照不自动继承旧测试结论。
- 标准 Windows app 第 1、2 批构建成功；第 2 批接入 shell identity、通知和 JumpList，SHA256 为 `3005be94b8e650189ea0a32bd53ecbea039bceb67c9ff650c1ee15a96f08d29a`。W01 在第 1 批 app 的绝对隔离路径下通过，三张图已读；相对 out 导致相对环境目录被二次解析的首次失败保留。其余 GUI 和系统功能不由 W01 代证。
- GTK 快照 `e1c50a811` 第 6 批定向 91/91、零 skip，包含编辑模型、session 和 GTK GX 生命周期；新 std app build 与 session restart 场景继续验证。
- Shell 模块、安装器注册及按所有权卸载、实际 CLI 参数过滤已实现；轻量 native 29/29，相关 package/release 99 tests、6 环境 skip。未实际编译安装器或执行 VM 安卸载、通知冷暖激活及 JumpList，保持 PENDING。
- R5-01X 已有双缓冲 CAS 所有权与源权威输入租约，轻量 12/12；真实映射、认证句柄、源产帧、目标呈现和全部 UI 回调仍在实施，不记跨 host 已完成。
- 相关框架定向 139 项通过；打包定向 48 项、6 skip。完整 framework/CI/main/VT/POSIX/GTK 总门尚未运行。
- 独立复审发现并修复 GTK 同窗迁移监听断连、隐藏 pane 旧引用及窗口手动标题遗漏；OLE 真实原生测试证明先 DestroyWindow 再 RevokeDragDrop 会泄漏注册引用，当前采用保留 HWND、外层 GUI 循环撤销后销毁和注册中 reservation，该生产回归已随 Windows 第 12 批通过。UIA 追加每批请求预算、通知语义去重和队列满重试，外部 MTA 与真实 OLE source 仍需补验。
- 新 `scripts/gx_slots.py` 用内核锁协调 Windows 发起的 Windows/WSL/Docker 作业，三重型槽与单桌面槽，不按年龄删除锁。旧 `.local/bin/slot.sh`／`desk.sh` 不再作为本轮调度入口。
- Win11 Docker VM 已通过实际 KVM、官方 ISO SHA256 校验并启动到登录界面；已正常停止，磁盘保留。首次登录后的普通账户／策略验收、Win10、安装／通知／提权场景仍 PENDING。不能用安装完成代 GUI 或 GPU 验收。
- 当前证据：`.local/evidence/R5/execution-20261013/tasks.json`、`leaf-matrix.json`、各批日志和 `gtk-gui-05/review.json`；VM 在 `.local/evidence/R5/VM/`。142 叶最终绑定、C1 新 40 loads、P 门、其余 R5/R6 都未关闭。

## 9. 2026-10-14 R6 收口检查点

本节只更新组织方式与入口，不替代前文验收契约，也不关闭任何门。整体 **not_complete**。

- 任务组织、模型分工、重型槽、构建频次与提交授权以 [GX_UI_EXECUTION_PLAN.md](GX_UI_EXECUTION_PLAN.md) 为准：只派当前会话的原生子智能体（同时最多 10 个），本地阶段 commit 已授权，仍不 push、不建 PR/Issue/tag/release、不新增下载。原定 02:48 截止已超期，如实保留。
- 最近的完整候选证据是 final-r2（`candidate-20261014-0250`），结果、限制与补验入口见 [GX_UI_EVIDENCE_INDEX.md](GX_UI_EVIDENCE_INDEX.md) 2.1 与第 6 节。它之后的源码修改尚未编译，任何新结论都要绑定新的构建身份。
- 第 2.3 节的 R5-00 与第 5 节各流的源码大部分已接线：普通窗口本地/远程混合树、远程输入与绑定续延（GX-0043、GX-0044）、两端会话恢复（默认关）、Windows 单实例与 `-e` 独立、protected paste 与跨权限拖放 broker、Shell 身份下的 Toast/JumpList、UIA、全拼、Fluent 图标与默认关闭的 Popup DComp，以及 GTK 的生命周期、geometry、分屏迁移、快捷键编辑器与启动配置管理器。接线不等于验收：第 5 节每一行的完成门照旧适用。
- 用户可见行为写在 [GX_FEATURES.md](GX_FEATURES.md)「会话、实例与远程窗格」与根 `CHANGELOG.md` 的 `0.0.3(TBD)`；上游补丁 GX-0039～GX-0044 登记在 [FORK_PATCHES.md](FORK_PATCHES.md)。
