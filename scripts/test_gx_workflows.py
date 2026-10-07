"""Shape locks for the fork's GitHub workflows (stdlib text assertions; YAML semantics need actionlint)."""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))

ROOT = SCRIPTS.parent
WORKFLOWS = ROOT / ".github" / "workflows"
ARCHIVE = ROOT / ".github" / "workflows-archive"
DOCKERFILE = ROOT / "src" / "build" / "docker" / "debian" / "Dockerfile"
REPOSITORY = "gx0404/gx_ghostty"
ACTIVE = {"gx-ci.yml", "gx-release.yml"}
ARCHIVED = {
    "clean-artifacts.yml", "flatpak.yml", "milestone.yml", "nix.yml", "publish-tag.yml",
    "release-tag.yml", "release-tip.yml", "snap.yml", "test.yml", "update-colorschemes.yml",
    "vouch-check-issue.yml", "vouch-check-pr.yml", "vouch-manage-by-discussion.yml",
    "vouch-manage-by-issue.yml", "vouch-sync-codeowners.yml",
}
ALLOWED_ACTIONS = {"actions/checkout", "actions/upload-artifact", "actions/download-artifact", "mlugg/setup-zig"}
CI_JOBS = {"framework", "zig-fmt", "linux-vt", "linux-main", "lib-vt-cross", "windows", "gtk-smoke", "macos"}
CI_TIMEOUTS = {
    "framework": 20, "zig-fmt": 20, "linux-vt": 45, "linux-main": 60,
    "lib-vt-cross": 45, "windows": 60, "gtk-smoke": 90, "macos": 60,
}
# Jobs that run the sharded Zig test runner; each writes its --json report into $RUNNER_TEMP/gx-zig-test/.
ZIG_TEST_COMMANDS = {
    "linux-vt": 'python3 scripts/zig_test.py --suite vt --json "$RUNNER_TEMP/gx-zig-test/linux-vt.json"',
    "linux-main": 'python3 scripts/zig_test.py --suite main -Dapp-runtime=none '
                  '--json "$RUNNER_TEMP/gx-zig-test/linux-main.json"',
    "windows": 'python scripts/zig_test.py --suite vt --json "$env:RUNNER_TEMP/gx-zig-test/windows.json"',
}
# The only mlugg/setup-zig inputs in gx-ci; no job sets version, so every job installs minimum_zig_version.
SETUP_ZIG_INPUTS = {
    "linux-vt": {"cache-size-limit": "4096"},
    "linux-main": {"cache-size-limit": "4096"},
    "windows": {"cache-size-limit": "4096"},
    "lib-vt-cross": {"cache-key": "${{ matrix.target }}"},
}
RELEASE_JOBS = {"prepare", "source", "libvt", "libvt-macos", "linux-gtk", "macos", "verify", "publish"}
CROSS_TARGETS = [
    "x86_64-linux-gnu", "aarch64-linux-gnu", "x86_64-linux-musl",
    "x86_64-windows-gnu", "aarch64-macos", "wasm32-freestanding",
]
LIBVT_MATRIX = {
    "x86_64-linux-gnu": "ubuntu-24.04",
    "aarch64-linux-gnu": "ubuntu-24.04",
    "x86_64-linux-musl": "ubuntu-24.04",
    "wasm32-freestanding": "ubuntu-24.04",
    "x86_64-windows-msvc": "windows-2025",
}
SMOKE_TOOLS = {"git", "ca-certificates", "xz-utils", "gettext", "xvfb", "xauth", "scrot"}
RELEASE_TOOLS = {"git", "ca-certificates", "xz-utils", "gettext"}
PWSH_CHECK = "if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
NATIVE_RE = re.compile(r"^(?:&\s*)?(?:git|zig|python3?|gh|\.[/\\])")
USES_RE = re.compile(r"^\s*(?:- )?uses:\s*(?P<ref>\S+)(?P<comment>.*)$")
RUN_RE = re.compile(r"^(?P<indent>\s*)(?P<dash>- )?run:\s*(?P<value>.*)$")
PIN_RE = re.compile(r"^(?P<action>[\w.-]+/[\w.-]+(?:/[\w./-]+)?)@(?P<sha>[0-9a-f]{40})$")
ZERO_SHA = "0" * 40


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def block(lines: list[str], start: int, indent: int) -> list[str]:
    body = []
    for line in lines[start + 1:]:
        if line.strip() and indent_of(line) <= indent:
            break
        body.append(line)
    return body


def run_scripts(lines: list[str]) -> list[str]:
    scripts = []
    for index, line in enumerate(lines):
        match = RUN_RE.match(line)
        if not match:
            continue
        column = len(match.group("indent")) + (2 if match.group("dash") else 0)
        value = match.group("value").strip()
        if not value:
            continue
        if value in ("|", "|-", "|+", ">", ">-", ">+"):
            scripts.append("\n".join(block(lines, index, column)))
        else:
            scripts.append(value)
    return scripts


def steps(job: list[str]) -> list[list[str]]:
    if "    steps:" not in job:
        return []
    result: list[list[str]] = []
    for line in job[job.index("    steps:") + 1:]:
        if line.strip() and indent_of(line) <= 4:
            break
        if line.startswith("      - "):
            result.append(["        " + line[8:]])
        elif result:
            result[-1].append(line)
    return result


def field(lines: list[str], key: str, indent: int) -> str | None:
    pattern = re.compile(rf"^ {{{indent}}}{re.escape(key)}:\s*(.*)$")
    for line in lines:
        match = pattern.match(line)
        if match:
            return match.group(1).strip()
    return None


def mapping(lines: list[str], key: str, indent: int) -> dict[str, str]:
    header = " " * indent + key + ":"
    if header not in lines:
        return {}
    result = {}
    for line in block(lines, lines.index(header), indent):
        match = re.match(rf"^ {{{indent + 2}}}([\w-]+):\s*(.*)$", line)
        if match:
            result[match.group(1)] = match.group(2).strip()
    return result


def apt_packages(script: str) -> set[str]:
    words = script.replace("\\", " ").split()
    if "install" not in words:
        return set()
    packages = set()
    for word in words[words.index("install") + 1:]:
        if word in ("&&", ";"):
            break
        if not word.startswith("-"):
            packages.add(word)
    return packages


def dockerfile_packages() -> set[str]:
    packages: set[str] = set()
    active = False
    for line in DOCKERFILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not active:
            active = "apt-get" in stripped and re.search(r"\binstall\b", stripped) is not None
            continue
        if not stripped or stripped.startswith("#"):
            continue
        words = stripped.replace("\\", " ").split()
        for word in words:
            if word == "&&":
                return packages
            if not word.startswith("-"):
                packages.add(word)
    return packages


class Workflow:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.lines = path.read_text(encoding="utf-8").splitlines()
        self.text = "\n".join(self.lines) + "\n"

    def section(self, key: str) -> list[str]:
        return block(self.lines, self.lines.index(f"{key}:"), 0)

    def jobs(self) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        current = None
        for line in self.section("jobs"):
            match = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
            if match:
                current = match.group(1)
                result[current] = []
            elif current is not None:
                result[current].append(line)
        return result

    def job(self, name: str) -> list[str]:
        return self.jobs()[name]

    def job_text(self, name: str) -> str:
        return "\n".join(self.job(name)) + "\n"

    def scripts(self, name: str | None = None) -> list[str]:
        return run_scripts(self.job(name) if name else self.lines)

    def uses(self) -> list[tuple[str, str]]:
        found = []
        for line in self.lines:
            match = USES_RE.match(line)
            if match:
                found.append((match.group("ref"), match.group("comment").strip()))
        return found


CI = Workflow(WORKFLOWS / "gx-ci.yml")
RELEASE = Workflow(WORKFLOWS / "gx-release.yml")


class WorkflowSetTests(unittest.TestCase):
    def test_only_the_two_fork_workflows_are_active(self):
        self.assertEqual({path.name for path in WORKFLOWS.iterdir()}, ACTIVE)

    def test_archive_keeps_exactly_the_fifteen_upstream_workflows(self):
        names = {path.name for path in ARCHIVE.iterdir()}
        self.assertEqual(names - {"README.md"}, ARCHIVED)
        self.assertIn("README.md", names)

    def test_archive_readme_points_back_to_the_release_docs(self):
        readme = (ARCHIVE / "README.md").read_text(encoding="utf-8")
        for needle in ("gx-ci.yml", "gx-release.yml", "git mv", "docs/RELEASE.md"):
            self.assertIn(needle, readme)


class SharedShapeTests(unittest.TestCase):
    workflows = (CI, RELEASE)

    def test_top_level_permissions_are_read_only(self):
        for workflow in self.workflows:
            with self.subTest(workflow=workflow.path.name):
                self.assertEqual([line for line in workflow.section("permissions") if line.strip()],
                                 ["  contents: read"])

    def test_no_privileged_triggers_secrets_or_mutable_refs(self):
        for workflow in self.workflows:
            with self.subTest(workflow=workflow.path.name):
                for forbidden in ("pull_request_target", "secrets.", "workflow_run", "@main", "@master",
                                  "persist-credentials: true", "--clobber", "git push", "continue-on-error"):
                    self.assertNotIn(forbidden, workflow.text)

    def test_run_blocks_never_interpolate_expressions(self):
        for workflow in self.workflows:
            scripts = workflow.scripts()
            self.assertGreater(len(scripts), 5)
            for script in scripts:
                with self.subTest(workflow=workflow.path.name, script=script[:60]):
                    self.assertNotIn("${{", script)

    def test_every_action_is_pinned_to_an_upstream_commit_sha(self):
        archived = "\n".join((ARCHIVE / name).read_text(encoding="utf-8") for name in sorted(ARCHIVED))
        seen: dict[str, set[str]] = {}
        for workflow in self.workflows:
            for ref, comment in workflow.uses():
                with self.subTest(workflow=workflow.path.name, ref=ref):
                    match = PIN_RE.match(ref)
                    self.assertIsNotNone(match, f"{ref} is not pinned to a 40-hex commit SHA")
                    self.assertRegex(comment, r"^# v\d+(?:\.\d+)*$")
                    self.assertIn(match.group("action"), ALLOWED_ACTIONS)
                    self.assertIn(f"uses: {ref} {comment}", archived,
                                  "reuse the SHA (and version comment) already pinned by the upstream workflows")
                    seen.setdefault(match.group("action"), set()).add(match.group("sha"))
        self.assertEqual(set(seen), ALLOWED_ACTIONS)
        for action, shas in seen.items():
            self.assertEqual(len(shas), 1, f"{action} is pinned to several SHAs")

    def test_every_checkout_discards_credentials(self):
        for workflow in self.workflows:
            for name, job in workflow.jobs().items():
                for step in steps(job):
                    uses = field(step, "uses", 8) or ""
                    if uses.startswith("actions/checkout@"):
                        with self.subTest(workflow=workflow.path.name, job=name):
                            self.assertEqual(mapping(step, "with", 8).get("persist-credentials"), "false")

    def test_every_job_has_a_bounded_timeout(self):
        for workflow in self.workflows:
            for name, job in workflow.jobs().items():
                with self.subTest(workflow=workflow.path.name, job=name):
                    timeout = field(job, "timeout-minutes", 4)
                    self.assertIsNotNone(timeout)
                    self.assertLessEqual(int(timeout), 120)

    def test_pwsh_native_commands_check_the_exit_code(self):
        scripts = CI.scripts("windows") + [
            script for step in steps(RELEASE.job("libvt")) if field(step, "shell", 8) == "pwsh"
            for script in run_scripts(step)
        ]
        self.assertGreaterEqual(len(scripts), 5)
        checked = 0
        for script in scripts:
            lines = [line.strip() for line in script.splitlines() if line.strip()]
            for index, line in enumerate(lines):
                if NATIVE_RE.match(line):
                    with self.subTest(command=line):
                        self.assertLess(index + 1, len(lines))
                        self.assertEqual(lines[index + 1], PWSH_CHECK)
                        checked += 1
        self.assertGreaterEqual(checked, 7)

    def test_zig_pin_matches_build_zig_zon(self):
        import setup_zig

        zon = (ROOT / "build.zig.zon").read_text(encoding="utf-8")
        pins = re.findall(r'^\s*\.minimum_zig_version\s*=\s*"([^"]+)"', zon, re.M)
        self.assertEqual(pins, [setup_zig.ZIG_VERSION])


class CiWorkflowTests(unittest.TestCase):
    def test_triggers_are_the_fork_branch_and_manual_inputs(self):
        on = CI.section("on")
        self.assertEqual([line for line in on if re.match(r"^  \S", line)],
                         ["  push:", "  pull_request:", "  workflow_dispatch:"])
        self.assertEqual(field(on, "branches", 4), "[gx_ghostty]")
        self.assertEqual(sum(line == "    branches: [gx_ghostty]" for line in on), 2)
        inputs = block(on, on.index("    inputs:"), 4)
        self.assertEqual([line.strip() for line in inputs if indent_of(line) == 6], ["gtk_smoke:", "macos:"])
        self.assertEqual(sum(line.strip() == "type: boolean" for line in inputs), 2)
        self.assertEqual(sum(line.strip() == "default: false" for line in inputs), 2)

    def test_only_pull_requests_cancel_superseded_runs(self):
        # Every push run must finish: its framework job is the only check of that push's before..after subjects,
        # and a shared group cancels pending runs even without cancel-in-progress, so push runs get a per-run group.
        self.assertEqual([line for line in CI.section("concurrency") if line.strip()], [
            "  group: gx-ci-${{ github.event_name }}-${{ github.event.pull_request.number || github.run_id }}",
            "  cancel-in-progress: ${{ github.event_name == 'pull_request' }}",
        ])

    def test_job_set_and_read_only_jobs(self):
        self.assertEqual(set(CI.jobs()), CI_JOBS)
        self.assertNotIn("contents: write", CI.text)
        for name, job in CI.jobs().items():
            with self.subTest(job=name):
                self.assertIsNone(field(job, "permissions", 4))

    def test_heavy_jobs_wait_for_the_fast_gates(self):
        for name in CI_JOBS - {"framework", "zig-fmt"}:
            with self.subTest(job=name):
                self.assertEqual(field(CI.job(name), "needs", 4), "[framework, zig-fmt]")
        for name in ("framework", "zig-fmt"):
            with self.subTest(job=name):
                self.assertIsNone(field(CI.job(name), "needs", 4))

    def test_job_timeouts(self):
        self.assertEqual({name: field(job, "timeout-minutes", 4) for name, job in CI.jobs().items()},
                         {name: str(minutes) for name, minutes in CI_TIMEOUTS.items()})

    def test_framework_job_runs_the_fork_gates_without_graph_check(self):
        text = CI.job_text("framework")
        for command in ("python3 scripts/resolve_agent_rules.py --check\n",
                        "python3 scripts/version.py --check\n",
                        "python3 scripts/run_unittests.py\n",
                        "run: python3 scripts/build_agent_kb.py\n",
                        'python3 scripts/conventional_commits.py --range "$range"'):
            self.assertIn(command, text)
        self.assertNotIn("unittest discover", CI.text)
        self.assertEqual(field(CI.job("framework"), "runs-on", 4), "ubuntu-24.04")
        self.assertIn("fetch-depth: 0", text)
        self.assertNotIn("--confirm", text)
        self.assertNotIn("graphify", CI.text)

    def test_commit_range_follows_the_event(self):
        step = next(step for step in steps(CI.job("framework")) if "conventional_commits.py" in "\n".join(step))
        env = mapping(step, "env", 8)
        self.assertEqual(env, {
            "GX_EVENT": "${{ github.event_name }}",
            "GX_BEFORE": "${{ github.event.before }}",
            "GX_AFTER": "${{ github.event.after }}",
            "GX_BASE": "${{ github.event.pull_request.base.sha }}",
            "GX_HEAD": "${{ github.event.pull_request.head.sha }}",
        })
        script = run_scripts(step)[0]
        self.assertIn(f"zero={ZERO_SHA}", script)
        self.assertIn('range="${GX_BEFORE:-$zero}..$GX_AFTER"', script)
        self.assertIn('range="$GX_BASE..$GX_HEAD"', script)
        self.assertIn('range="$zero..$GITHUB_SHA"', script)
        import conventional_commits

        self.assertIn("-1", conventional_commits.range_command(f"{ZERO_SHA}..{'a' * 40}"))
        self.assertIn("--first-parent", conventional_commits.range_command(f"{'b' * 40}..{'a' * 40}"))

    def test_linux_vt_runs_sharded_lib_vt_tests_then_the_abi_manifest(self):
        job = CI.job("linux-vt")
        self.assertEqual(field(job, "runs-on", 4), "ubuntu-24.04")
        self.assertIn(ZIG_TEST_COMMANDS["linux-vt"], CI.scripts("linux-vt"))
        self.assertIn("zig build test-lib-vt-schema", CI.scripts("linux-vt"))
        text = CI.job_text("linux-vt")
        needles = (
            "uses: actions/checkout@", "uses: mlugg/setup-zig@",
            "sudo apt-get install -y --no-install-recommends python3-jsonschema", "python3 -c 'import jsonschema'",
            ZIG_TEST_COMMANDS["linux-vt"], "zig build test-lib-vt-schema", "uses: actions/upload-artifact@")
        self.assertEqual({needle: text.count(needle) for needle in needles}, dict.fromkeys(needles, 1))
        order = [text.index(needle) for needle in needles]
        self.assertEqual(order, sorted(order))
        self.assertNotIn("zig build test-lib-vt\n", text)

    def test_linux_main_runs_the_sharded_core_suite_without_an_app_runtime(self):
        job = CI.job("linux-main")
        self.assertEqual(field(job, "runs-on", 4), "ubuntu-24.04")
        self.assertEqual(CI.scripts("linux-main"), [ZIG_TEST_COMMANDS["linux-main"]])
        text = CI.job_text("linux-main")
        needles = ("uses: actions/checkout@", "uses: mlugg/setup-zig@", ZIG_TEST_COMMANDS["linux-main"],
                   "uses: actions/upload-artifact@")
        self.assertEqual({needle: text.count(needle) for needle in needles}, dict.fromkeys(needles, 1))
        order = [text.index(needle) for needle in needles]
        self.assertEqual(order, sorted(order))
        self.assertNotIn("zig build -Dapp-runtime=none test", CI.text)

    def test_zig_test_jobs_upload_the_json_report_only_on_failure(self):
        for name, command in ZIG_TEST_COMMANDS.items():
            with self.subTest(job=name):
                job = CI.job(name)
                self.assertEqual(sum(command in script for script in CI.scripts(name)), 1)
                self.assertEqual(mapping(job, "env", 4), {
                    "PYTHONDONTWRITEBYTECODE": "'1'",
                    "GX_ZIG_TEST_TIMINGS_DIR": ".zig-cache/gx-test-timings",
                })
                upload = steps(job)[-1]
                self.assertTrue((field(upload, "uses", 8) or "").startswith("actions/upload-artifact@"))
                self.assertEqual(field(upload, "if", 8), "failure()")
                self.assertEqual(mapping(upload, "with", 8), {
                    "name": f"gx-zig-test-{name}",
                    "path": "${{ runner.temp }}/gx-zig-test/",
                    "if-no-files-found": "ignore",
                    "retention-days": "14",
                })
                self.assertEqual(sum((field(step, "uses", 8) or "").startswith("actions/upload-artifact@")
                                     for step in steps(job)), 1)
        self.assertEqual(sum("scripts/zig_test.py" in script for script in CI.scripts()), len(ZIG_TEST_COMMANDS))

    def test_lib_vt_cross_matrix(self):
        job = CI.job("lib-vt-cross")
        matrix = block(job, job.index("        target:"), 8)
        self.assertEqual([line.strip()[2:] for line in matrix if line.strip()], CROSS_TARGETS)
        self.assertIn('zig build -Demit-lib-vt "-Dtarget=$GX_TARGET"', CI.job_text("lib-vt-cross"))

    def test_windows_job_covers_lib_vt_and_static_example(self):
        job = CI.job("windows")
        self.assertEqual(field(job, "runs-on", 4), "windows-2025")
        self.assertEqual(mapping(job, "defaults", 4), {"run": ""})
        self.assertIn("        shell: pwsh", job)
        text = CI.job_text("windows")
        order = [text.index(needle) for needle in (
            "git config --global core.autocrlf false", "uses: actions/checkout@", "uses: mlugg/setup-zig@",
            ZIG_TEST_COMMANDS["windows"], "zig build -Demit-lib-vt",
            "working-directory: example/c-vt-static", "./zig-out/bin/c_vt_static.exe")]
        self.assertEqual(order, sorted(order))
        self.assertNotIn("zig build test-lib-vt", text)

    def test_gtk_smoke_is_manual_and_mirrors_the_debian_dockerfile(self):
        job = CI.job("gtk-smoke")
        self.assertEqual(field(job, "if", 4), "github.event_name == 'workflow_dispatch' && inputs.gtk_smoke")
        self.assertEqual(mapping(job, "container", 4), {"image": "debian:13"})
        scripts = CI.scripts("gtk-smoke")
        packages = apt_packages(scripts[0])
        required = dockerfile_packages()
        self.assertGreaterEqual(len(required), 10)
        self.assertLessEqual(required | SMOKE_TOOLS, packages)
        text = CI.job_text("gtk-smoke")
        order = [text.index(needle) for needle in (
            "apt-get install", "uses: actions/checkout@", 'safe.directory "$GITHUB_WORKSPACE"',
            "uses: mlugg/setup-zig@", "zig build -Doptimize=ReleaseFast -Dcpu=baseline",
            "./zig-out/bin/ghostty +version", "xvfb-run", 'scrot "$evidence/ghostty-xvfb.png"',
            "uses: actions/upload-artifact@")]
        self.assertEqual(order, sorted(order))
        self.assertIn("minimum_zig_version", text)
        upload = next(step for step in steps(job) if (field(step, "uses", 8) or "").startswith("actions/upload"))
        self.assertEqual(field(upload, "if", 8), "always()")
        self.assertEqual(mapping(upload, "with", 8)["path"], "${{ runner.temp }}/gx-gtk-smoke/")

    def test_macos_is_manual_and_runs_lib_vt_tests(self):
        job = CI.job("macos")
        self.assertEqual(field(job, "if", 4), "github.event_name == 'workflow_dispatch' && inputs.macos")
        self.assertEqual(field(job, "runs-on", 4), "macos-15")
        self.assertIn("zig build test-lib-vt", CI.job_text("macos"))

    def test_setup_zig_reads_minimum_zig_version_and_tunes_only_the_locked_cache_inputs(self):
        self.assertLessEqual(set(SETUP_ZIG_INPUTS), CI_JOBS - {"framework"})
        for name, job in CI.jobs().items():
            setups = [step for step in steps(job) if (field(step, "uses", 8) or "").startswith("mlugg/setup-zig@")]
            with self.subTest(job=name):
                self.assertEqual(len(setups), 0 if name == "framework" else 1)
                for step in setups:
                    inputs = SETUP_ZIG_INPUTS.get(name, {})
                    self.assertEqual(field(step, "with", 8), "" if inputs else None)
                    self.assertEqual(mapping(step, "with", 8), inputs)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_manual_dispatch_only_with_three_inputs(self):
        on = RELEASE.section("on")
        self.assertEqual([line for line in on if re.match(r"^  \S", line)], ["  workflow_dispatch:"])
        inputs = block(on, on.index("    inputs:"), 4)
        self.assertEqual([line.strip() for line in inputs if indent_of(line) == 6], ["ref:", "publish:", "macos:"])
        self.assertEqual(mapping(inputs, "ref", 6)["default"], "gx_ghostty")
        self.assertEqual(mapping(inputs, "ref", 6)["type"], "string")
        for name in ("publish", "macos"):
            self.assertEqual(mapping(inputs, name, 6)["type"], "boolean")
            self.assertEqual(mapping(inputs, name, 6)["default"], "false")

    def test_releases_are_serialized(self):
        self.assertEqual([line for line in RELEASE.section("concurrency") if line.strip()],
                         ["  group: gx-release", "  cancel-in-progress: false"])

    def test_job_set_and_repository_guard(self):
        jobs = RELEASE.jobs()
        self.assertEqual(set(jobs), RELEASE_JOBS)
        guard = f"github.repository == '{REPOSITORY}'"
        self.assertEqual(field(jobs["prepare"], "if", 4), f"{guard} && github.event_name == 'workflow_dispatch'")
        publish_if = "\n".join(block(jobs["publish"], jobs["publish"].index("    if: >-"), 4))
        for clause in (guard, "inputs.publish", "github.event_name == 'workflow_dispatch'",
                       "needs.verify.result == 'success'", "needs.prepare.result == 'success'"):
            self.assertIn(clause, publish_if)
        for name in RELEASE_JOBS - {"prepare"}:
            with self.subTest(job=name):
                self.assertIn("prepare", field(jobs[name], "needs", 4))

    def test_only_publish_can_write(self):
        for name, job in RELEASE.jobs().items():
            with self.subTest(job=name):
                permissions = mapping(job, "permissions", 4)
                self.assertEqual(permissions, {"contents": "write"} if name == "publish" else {})
        self.assertEqual(RELEASE.text.count("contents: write"), 1)

    def test_checkouts_use_the_input_ref_once_then_the_prepared_sha(self):
        for name, job in RELEASE.jobs().items():
            checkouts = [step for step in steps(job) if (field(step, "uses", 8) or "").startswith("actions/checkout@")]
            with self.subTest(job=name):
                self.assertEqual(len(checkouts), 1)
                expected = "${{ inputs.ref }}" if name == "prepare" else "${{ needs.prepare.outputs.sha }}"
                self.assertEqual(mapping(checkouts[0], "with", 8).get("ref"), expected)

    def test_prepare_exports_the_release_identity(self):
        job = RELEASE.job("prepare")
        self.assertEqual(mapping(job, "outputs", 4), {
            key: f"${{{{ steps.prepare.outputs.{key} }}}}" for key in ("sha", "version", "tag", "version_string", "zig")
        })
        step = next(step for step in steps(job) if field(step, "id", 8) == "prepare")
        self.assertEqual(mapping(step, "env", 8), {
            "GH_TOKEN": "${{ github.token }}", "GX_PUBLISH": "${{ inputs.publish }}", "PYTHONDONTWRITEBYTECODE": "'1'",
        })
        self.assertIn('python3 scripts/gx_release.py prepare "${args[@]}"', run_scripts(step)[0])

    def test_tokens_reach_only_prepare_and_publish(self):
        for name, job in RELEASE.jobs().items():
            with self.subTest(job=name):
                count = "\n".join(job).count("${{ github.token }}")
                self.assertEqual(count, 1 if name in ("prepare", "publish") else 0)

    def test_every_zig_build_uses_the_release_version_string(self):
        builds = 0
        for name, job in RELEASE.jobs().items():
            for script in run_scripts(job):
                for line in script.replace("\\\n", " ").splitlines():
                    if "zig build" in line:
                        builds += 1
                        with self.subTest(job=name, line=line.strip()):
                            self.assertIn('-Dversion-string=$', line.replace('"', ""))
        self.assertGreaterEqual(builds, 6)

    def test_release_toolchain_is_pinned_and_uncached(self):
        for name, job in RELEASE.jobs().items():
            for step in steps(job):
                if (field(step, "uses", 8) or "").startswith("mlugg/setup-zig@"):
                    with self.subTest(job=name):
                        self.assertEqual(mapping(step, "with", 8),
                                         {"version": "${{ needs.prepare.outputs.zig }}", "use-cache": "false"})
            for script in run_scripts(job):
                if "zig build" in script:
                    with self.subTest(job=name, script=script[:40]):
                        self.assertIn("RUNNER_TEMP", script)
                        self.assertIn("ZIG_LOCAL_CACHE_DIR", script)
                        self.assertIn("ZIG_GLOBAL_CACHE_DIR", script)

    def test_source_job_runs_distcheck_with_size_limit(self):
        text = RELEASE.job_text("source")
        self.assertIn('zig build distcheck -Demit-lib-vt=true "-Dversion-string=$GX_VERSION_STRING"', text)
        self.assertIn('archive="zig-out/dist/libghostty-vt-$GX_VERSION_STRING.tar.gz"', text)
        self.assertIn("max=$((5 * 1024 * 1024))", text)

    def test_libvt_matrix_targets_and_runners(self):
        job = RELEASE.job("libvt")
        entries: dict[str, str] = {}
        target = None
        for line in job:
            match = re.match(r"^          - target: (\S+)$", line)
            if match:
                target = match.group(1)
            match = re.match(r"^            os: (\S+)$", line)
            if match and target:
                entries[target] = match.group(1)
        self.assertEqual(entries, LIBVT_MATRIX)
        self.assertEqual(field(job, "runs-on", 4), "${{ matrix.os }}")
        text = RELEASE.job_text("libvt")
        self.assertIn('name="libghostty-vt-$GX_VERSION_STRING-$GX_TARGET"', text)
        self.assertIn('$name = "libghostty-vt-$env:GX_VERSION_STRING-$env:GX_TARGET"', text)
        self.assertIn('tar -C "$stage" -czf "$RUNNER_TEMP/gx-out/$name.tar.gz" "$name"', text)
        self.assertIn('(Join-Path $out "$name.zip")', text)

    def test_macos_jobs_are_optional(self):
        for name, runner in (("libvt-macos", "macos-15"), ("macos", "macos-26")):
            with self.subTest(job=name):
                self.assertEqual(field(RELEASE.job(name), "if", 4), "inputs.macos")
                self.assertEqual(field(RELEASE.job(name), "runs-on", 4), runner)

    def test_linux_gtk_builds_from_the_dist_tarball_in_debian_13(self):
        job = RELEASE.job("linux-gtk")
        self.assertEqual(mapping(job, "container", 4), {"image": "debian:13"})
        packages = apt_packages(RELEASE.scripts("linux-gtk")[0])
        self.assertLessEqual(dockerfile_packages() | RELEASE_TOOLS, packages)
        text = RELEASE.job_text("linux-gtk")
        order = [text.index(needle) for needle in (
            "apt-get install", "uses: actions/checkout@", 'safe.directory "$GITHUB_WORKSPACE"',
            'zig build dist "-Dversion-string=$GX_VERSION_STRING"',
            'tar -xzf "$RUNNER_TEMP/gx-out/ghostty-$GX_VERSION_STRING.tar.gz"',
            "test ! -e .git", "--prefix /usr -Doptimize=ReleaseFast -Dcpu=baseline",
            "+version", 'grep -Fx "  - version: $GX_VERSION_STRING"')]
        self.assertEqual(order, sorted(order))
        self.assertIn('name="ghostty-gx-$GX_VERSION_STRING-x86_64-linux-debian13"', text)

    def test_workflow_produces_exactly_the_assets_verify_expects(self):
        import gx_release

        produced = set()
        texts = {name: RELEASE.job_text(name) for name in RELEASE_JOBS}
        for target, runner in LIBVT_MATRIX.items():
            produced.add(f"libghostty-vt-$VS-{target}" + (".zip" if runner.startswith("windows") else ".tar.gz"))
        if "libghostty-vt-$GX_VERSION_STRING.tar.gz" in texts["source"]:
            produced.add("libghostty-vt-$VS.tar.gz")
        if 'cp "zig-out/dist/ghostty-$GX_VERSION_STRING.tar.gz"' in texts["linux-gtk"]:
            produced.add("ghostty-$VS.tar.gz")
        if '"$RUNNER_TEMP/gx-out/$name.tar.gz"' in texts["linux-gtk"]:
            produced.add("ghostty-gx-$VS-x86_64-linux-debian13.tar.gz")
        for job, name in (("libvt-macos", "libghostty-vt-$GX_VERSION_STRING-xcframework.zip"),
                          ("macos", "ghostty-gx-$GX_VERSION_STRING-universal-macos-unsigned.zip")):
            if name in texts[job]:
                produced.add(name.replace("$GX_VERSION_STRING", "$VS"))
        self.assertEqual(produced, set(gx_release.expected_assets("$VS", macos=True)))

    def test_uploads_feed_verify_and_verified_assets_feed_publish(self):
        uploads = {}
        for name, job in RELEASE.jobs().items():
            for step in steps(job):
                if (field(step, "uses", 8) or "").startswith("actions/upload-artifact@"):
                    uploads[name] = mapping(step, "with", 8)
        for name in ("source", "libvt", "libvt-macos", "linux-gtk", "macos"):
            with self.subTest(job=name):
                self.assertTrue(uploads[name]["name"].startswith("gx-"))
                self.assertEqual(uploads[name]["if-no-files-found"], "error")
        self.assertEqual(uploads["verify"]["name"], "verified-release")
        verify_download = next(step for step in steps(RELEASE.job("verify"))
                               if (field(step, "uses", 8) or "").startswith("actions/download-artifact@"))
        self.assertEqual(mapping(verify_download, "with", 8)["pattern"], "gx-*")
        self.assertEqual(mapping(verify_download, "with", 8)["merge-multiple"], "true")
        publish_download = next(step for step in steps(RELEASE.job("publish"))
                                if (field(step, "uses", 8) or "").startswith("actions/download-artifact@"))
        self.assertEqual(mapping(publish_download, "with", 8)["name"], "verified-release")

    def test_verify_runs_in_build_only_mode_and_publish_goes_through_the_script(self):
        verify_if = "\n".join(block(RELEASE.job("verify"), RELEASE.job("verify").index("    if: >-"), 4))
        self.assertNotIn("inputs.publish", verify_if)
        self.assertIn("!cancelled()", verify_if)
        self.assertIn("needs.linux-gtk.result == 'success'", verify_if)
        verify = RELEASE.job_text("verify")
        self.assertIn('python3 scripts/gx_release.py verify --sha "$GX_SHA" --version-string "$GX_VERSION_STRING"', verify)
        self.assertIn("sha256sum -c SHA256SUMS", verify)
        publish = RELEASE.job_text("publish")
        self.assertIn('python3 scripts/gx_release.py publish --sha "$GX_SHA" --version-string "$GX_VERSION_STRING"',
                      publish)
        self.assertNotIn("gh release", RELEASE.text)
        self.assertEqual(field(RELEASE.job("publish"), "needs", 4), "[prepare, verify]")


if __name__ == "__main__":
    unittest.main()
