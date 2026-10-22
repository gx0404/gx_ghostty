# 代码图谱、离线浏览器与知识库

从模块概览定位文件和符号，再沿关系页查看来源。原始图谱提供抽取结果，浏览器组织交互与源码快照，KB 用于文档和公开接口检索；三者的覆盖和新鲜度分别验收。

## 生成与打开

前置：Python ≥ 3.10、Git，以及 `just setup` 安装的 graphifyy 0.9.73。以下命令在仓库根运行：

```sh
just graph               # 全量抽取原图、写指纹，随后生成浏览器
just graph-view          # 已有新鲜原图时单独生成/重建浏览器
just kb                  # 源码与文档定稿后最后生成
just generated-check
just graph-view-check
```

直接在浏览器打开 `graphify-out/framework/overview.html`；符号详情入口是同目录的 `detail.html`。两页内联目录，关系通过同目录的经典 script 分片加载，源码链接指向本地 HTML；可以从 `file://` 离线浏览，不需要 HTTP 服务、CDN 或运行时包安装。构建页面与浏览页面是两个阶段，不能用打开旧页面代证本轮生成成功。

`just graph-view` 等价于 `python scripts/graphify_viewer.py build`，检查为 `check`；可用 `--root <仓库>` 指定根目录。成功退出 0；输入、来源、预算、陈旧或所有权校验失败退出 2。拒绝后先保留手改或未知成果到受管目录外，经确认再清理本机 framework 目录并重建；没有强制覆盖开关。

`just graph-query <问题>`、`python scripts/graphify.py path …` 与 `explain …` 在调用前检查新鲜度。查询关闭 Graphify 追加日志，但本机会更新 `graphify-out/cache/last_query_stamp`，不是完全无写入的命令。含 shell 元字符的查询直接调用脚本。

## 浏览流程

1. 在概览中按模块进入文件、符号，或按 `/` 聚焦搜索；搜索覆盖完整目录，可按模块与类型筛选。
2. 选中节点后查看关系与证据，关系按每页 100 条继续加载。星图最多绘制选中节点和 40 个邻居，绘制上限不截断关系列表。
3. 查看关系方向、类型、证据级别与上下文，再打开源码快照。来源页使用路径哈希文件名，行号链接形如 `sources/<sha256(path)>.html#L42`；没有来源或行号的外部/未知节点会保留缺失状态。
4. 分析布局默认保留画布与侧栏，可切换沉浸模式；窄视口使用抽屉。方向键、加减号与 `0` 操作画布，Esc 关闭面板或帮助；完整结果列表支持键盘导航。
5. 需要平面布局时切到 2D。WebGL 不可用或 context 丢失时退回 Canvas2D，搜索、关系与来源仍可使用。

这些是实现支持的流程。是否在当前浏览器正确显示、是否遮挡、焦点是否可见，必须通过实际操作和读图确认。

## 产物与真源

| 路径 | 用途与入库策略 |
|---|---|
| `.graphifyignore`、`scripts/graphify.py`、`scripts/graphify_fingerprint.py` | 抽取范围、钉版调用和原图新鲜度，入库 |
| `graphify-out/GRAPH_REPORT.md`、`source-fingerprint.json` | 入库报告与指纹 |
| `graphify-out/graph.json` | 本机原始图，不入库 |
| `scripts/graphify_viewer.py`、`scripts/graphify_viewer_assets/` | 浏览器适配器、页面与离线资源真源，入库 |
| `graphify-out/framework/` | 本机生成目录：overview/detail、manifest、REPORT、关系 JS 与来源 HTML，不入库 |
| `docs/kb/chunks.json` | KB schema 2，由 `scripts/build_agent_kb.py` 生成，入库 |

浏览器 manifest schema 为 1，包含原图、适配器、全部资源与来源内容的摘要，以及完整输出文件集合和摘要。单独检查会重建预期内容并比对，保持文件与 mtime 不变；缺失、额外、手改或陈旧输出都应拒绝。build 也不会覆盖未知/被手改的受管产物。manifest 最后写入，构建中断可被检测，整个目录写入不是事务。

Three.js 0.186.1 的离线 bundle、MIT 许可、构建输入与摘要登记在 `scripts/graphify_viewer_assets/vendor/manifest.json`；浏览时使用已打包资源，资源升级必须按该登记重建并审 diff。

维护者从仓库根执行以下命令复现依赖；需要已安装的 Node/npm 与首次下载网络，普通图谱生成和浏览无需它们。安装只写该目录的已忽略 `node_modules` 与 `.local` 缓存：

```sh
npm ci --prefix scripts/graphify_viewer_assets/vendor/build --cache .local/npm-viewer-cache --no-audit --no-fund
node scripts/graphify_viewer_assets/vendor/build/build_vendor.mjs --check
```

有意升级时先更新锁与许可证，再不带 `--check` 生成 bundle 和 manifest、审 diff，最后执行 `just graph-view` 与浏览器回归。`--check` 比较重建字节与登记摘要，不修改资源。

## 预算与覆盖

| 限制 | 数值 |
|---|---:|
| 每页关系数 | 100 |
| 单关系脚本 | 512 KiB |
| 单 HTML | 8 MiB |
| 全部浏览器输出 | 128 MiB |
| KB 文件 | 2.5 MiB |

浏览器与 KB 都在写入前检查相应预算。超限先检查异常来源、重复文档与抽取结果，不缩减必要覆盖或提高上限来换取通过。浏览器预算不等于原始 graph.json 大小，REPORT 与 manifest 给出本轮精确节点/边、来源、模块、社区、证据、自环和 unknown 计数，以及图摘要与内容指纹。

当前原图是产品源码的 AST 视图，精确集合由 `.graphifyignore` 与 `graphify_fingerprint.py` 决定。Graphify 会跳过 build/dist/target 等目录；构建脚本、开发框架以及缺失的头文件符号关系直接读源码或查 KB。EXTRACTED / INFERRED / AMBIGUOUS 是抽取证据，不是运行时调用证明；保留原始 source/target 方向，不把星图称为完整调用图，也不补造缺失边。

`just graph-check` 不要求安装 graphify；没有本机 `graph.json` 时只能校验两份入库产物和源码指纹，并提示本机图缺失。有原图时还检查浏览器；单独 `just graph-view-check` 需要本机完整输入。`framework-check`、`ci-check` 与 push CI 不运行重抽取；同步和发布前追平。

## 检查与证据

```sh
python scripts/run_unittests.py test_graphify_fingerprint test_graphify_viewer test_agent_kb
python scripts/test_graphify_viewer_browser.py --overview graphify-out/framework/overview.html --output .local/evidence/graph-view --gpu software
```

定向单测使用临时夹具，验证映射、来源、分页、预算、陈旧和篡改拒绝，不能代替真实仓库图。浏览器检查需要可用的 Playwright/Chromium；`--help` 查看 `--require-webgl`、`--enforce-performance` 等选项，软件环境的结果不外推到硬件性能。

实际浏览必须覆盖概览 → 文件/符号 → 关系翻页 → 来源行号、全目录搜索、3D/2D、WebGL 退路、桌面和窄视口、键盘焦点。保留 pageerror、console、请求失败、性能记录与截图；逐张读图后才签署视觉 PASS。文件存在、结构检查、DOM 断言、截图生成和视觉验收分别报告。

本轮真实原图重建、KB 预算、浏览器截图与性能以执行批次证据为准；未执行前均为 PENDING。不要把历史报告或夹具结果写成最终树验收。
