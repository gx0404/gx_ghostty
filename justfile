# gx_ghostty 命令入口（fork 维护；上游 Makefile 保持原样）。命令手册：docs/MAKE_COMMANDS.md
# 配方体只写单条命令，cmd.exe / PowerShell / Git Bash / Linux sh 下行为一致；
# 串联的门禁用依赖表达，产品命令一律经 scripts/zigw.py 调用钉版 Zig 0.16.0。
# 变长参数原样拼进配方命令行、再按空格切分：含空格的值要在参数里内嵌双引号
# （bash 写法：just test '-Dtest-filter="Terminal: input"'），或绕过 just 直接调用脚本。
# 警告：参数不加引号地交给配方 shell 解释，Windows 的 cmd.exe 会处理 & | < > ^ %，其他系统的 sh
# 会处理 & | < > ; $ 等。例如 just commit-check "fix: a -> b" 会创建或清空文件 b，
# just kb-query "x & echo y" 会另外执行 echo y。含这些字符的自由文本与单条提交标题一律直接调用脚本
# （Linux/macOS 用 python3）：python scripts/conventional_commits.py "<标题>"、python scripts/agent_kb.py "<查询>"。

set windows-shell := ["cmd.exe", "/d", "/s", "/c"]

python := if os_family() == "windows" { "python" } else { "python3" }

# 列出全部配方（默认）
default:
    @just --list

# 安装钉版 Zig 0.16.0 与 graphify venv 到 .local/（幂等，已就绪则跳过）
setup:
    {{python}} scripts/setup_env.py

# 只读环境体检：FOUND / MISSING / OPTIONAL，缺必需项退出 1
doctor:
    {{python}} scripts/setup_env.py --check

# 列出改动路径必读的领域规则与上游嵌套 AGENTS.md（例：just rules src/terminal/c/terminal.zig）
rules *paths:
    {{python}} scripts/resolve_agent_rules.py {{paths}}

# 同 rules，另加代码审核规则（--task review）
rules-review *paths:
    {{python}} scripts/resolve_agent_rules.py --task review {{paths}}

# 校验规则路由闭集、根 AGENTS.md 体积与嵌套 AGENTS.md 登记
rules-check:
    {{python}} scripts/resolve_agent_rules.py --check

# 打印 fork 版本（CHANGELOG.md 中最大的 SemVer）
version:
    {{python}} scripts/version.py

# 校验 CHANGELOG.md 版本标题
version-check:
    {{python}} scripts/version.py --check

# 运行 scripts/ 下全部框架单测
framework-test:
    {{python}} -m unittest discover -s scripts -p "test_*.py"

# 框架门：rules-check、version-check、framework-test、kb-check（改公开签名或文档后先 just kb）
framework-check: rules-check version-check framework-test kb-check

# 生成物新鲜度门：kb-check、graph-check（上游同步后与发版前）
generated-check: kb-check graph-check

# 本地 CI 门：framework-check、fmt-check、test-vt
ci-check: framework-check fmt-check test-vt

# 重建代码图谱（钉版 graphifyy，需先 just setup）
graph:
    {{python}} scripts/graphify.py rebuild

# 校验图谱源码指纹与报告是否新鲜
graph-check:
    {{python}} scripts/graphify.py check

# 查询代码图谱
graph-query *a:
    {{python}} scripts/graphify.py query {{a}}

# 重建知识库 docs/kb/chunks.json（写入）
kb:
    {{python}} scripts/build_agent_kb.py --confirm

# 只读校验知识库是否新鲜
kb-check:
    {{python}} scripts/build_agent_kb.py

# 检索知识库（查询含 & | < > ^ % 等字符时直接调用 scripts/agent_kb.py，见文件头）
kb-query *q:
    {{python}} scripts/agent_kb.py {{q}}

# 启用仓库内 git 钩子（commit-msg 校验提交标题）
install-hooks:
    git config core.hooksPath .githooks

# 校验提交信息：--range A..B / --message-file <文件>；单条标题直接调用 scripts/conventional_commits.py（见文件头）
commit-check *a:
    {{python}} scripts/conventional_commits.py {{a}}

# zig build（参数原样透传）
build *a:
    {{python}} scripts/zigw.py build {{a}}

# zig build test（全量很慢，定向加 -Dtest-filter=<name>；Windows 上为尽力而为）
test *a:
    {{python}} scripts/zigw.py build test {{a}}

# libghostty-vt 测试：zig build test-lib-vt
test-vt *a:
    {{python}} scripts/zigw.py build test-lib-vt {{a}}

# 构建 libghostty-vt：zig build -Demit-lib-vt
build-vt *a:
    {{python}} scripts/zigw.py build -Demit-lib-vt {{a}}

# 构建 libghostty-vt 的 wasm32-freestanding ReleaseSmall 产物
vt-wasm:
    {{python}} scripts/zigw.py build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall

# 打含 libghostty-vt 的源码包：zig build dist -Demit-lib-vt=true
dist-vt:
    {{python}} scripts/zigw.py build dist -Demit-lib-vt=true

# zig fmt 格式化全仓（排除 .local/ 与构建产生的 zig-pkg/、zig-out/、.zig-cache/）
fmt:
    {{python}} scripts/zigw.py fmt --exclude .local --exclude zig-pkg --exclude zig-out --exclude .zig-cache .

# 只检查 zig 格式（排除同上；zig-pkg/ 是 Zig 0.16 拉取的第三方依赖包，不归本仓格式化）
fmt-check:
    {{python}} scripts/zigw.py fmt --check --exclude .local --exclude zig-pkg --exclude zig-out --exclude .zig-cache .

# 直通钉版 zig（例：just zig version）
zig *a:
    {{python}} scripts/zigw.py {{a}}
