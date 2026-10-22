#!/usr/bin/env python3
"""Exercise generated offline graph pages in an existing Playwright Chromium.

This is an explicit browser acceptance runner, not a unittest discovery module.
It writes a new evidence directory; screenshots still require human/agent review.
"""
from __future__ import annotations

import argparse
import json
import platform
import shutil
import sys
import time
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--overview", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--gpu", choices=("hardware", "software"), default="hardware")
    parser.add_argument("--enforce-performance", action="store_true")
    parser.add_argument("--require-webgl", action="store_true")
    args = parser.parse_args(argv)
    overview = args.overview.resolve()
    output = args.output.resolve()
    if not overview.is_file():
        parser.error("--overview must name an existing generated HTML page")
    if output.exists():
        parser.error("--output must be a new evidence directory")
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("PENDING: Playwright is not installed in the selected interpreter", file=sys.stderr)
        return 2

    output.mkdir(parents=True)
    report: dict = {
        "overview": str(overview), "platform": platform.platform(),
        "python": sys.version, "gpu_requested": args.gpu,
        "checks": [], "screenshots": [], "console": [], "page_errors": [],
        "external_requests": [], "request_failures": [],
        "visual_review": "PENDING: read back the PNG files before visual acceptance",
    }
    failures: list[str] = []
    expected_missing = False

    def check(name: str, condition: bool, detail: object = None) -> None:
        report["checks"].append({"name": name, "status": "PASS" if condition else "FAIL", "detail": detail})
        if not condition:
            failures.append(name)

    def attach(page) -> None:
        page.on("pageerror", lambda error: report["page_errors"].append(str(error)))
        page.on("console", lambda message: report["console"].append({"type": message.type, "text": message.text, "expected_missing_data": expected_missing}))
        page.on("request", lambda request: report["external_requests"].append(request.url) if request.url.startswith(("http://", "https://")) else None)
        page.on("requestfailed", lambda request: report["request_failures"].append({"url": request.url, "error": request.failure, "expected_missing_data": expected_missing}))

    def ready(page) -> None:
        page.wait_for_selector("body[data-ready=true]", timeout=20000)
        page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")

    def screenshot(page, name: str) -> None:
        page.evaluate("() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))")
        page.screenshot(path=str(output / (name + ".png")), full_page=False)
        report["screenshots"].append(name + ".png")

    def inspect(page) -> dict:
        return page.evaluate("GXAtlas.inspect()")

    def search(page, text: str) -> None:
        version = inspect(page)["filterVersion"]
        page.locator("#search").fill(text)
        page.wait_for_function("version => GXAtlas.inspect().filterVersion > version", arg=version)

    try:
        with sync_playwright() as pw:
            launch_args = []
            if args.gpu == "hardware" and sys.platform == "win32":
                launch_args.append("--use-angle=d3d11")
            elif args.gpu == "software":
                launch_args.extend(["--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
            browser = pw.chromium.launch(headless=True, args=launch_args)
            report["browser"] = browser.version
            context = browser.new_context(viewport={"width": 1440, "height": 900}, device_scale_factor=1)
            page = context.new_page()
            attach(page)
            page.goto(overview.as_uri(), wait_until="load")
            ready(page)
            initial = inspect(page)
            report["initial"] = initial
            check("catalog_ready", initial["counts"].get("nodes", 0) > 0, initial["counts"])
            check("no_initial_relation_fetch", initial["loadedShards"] == 0, initial["loadedShards"])
            check("overview_relation_budget_visible", "条聚合关系" in page.locator("#sceneCount").inner_text())
            if args.require_webgl:
                check("webgl_available", initial["scene"]["mode"] == "3d", initial["scene"])
            screenshot(page, "01-overview-desktop")
            search_term = page.evaluate("""() => {
                const c = JSON.parse(document.querySelector('#graph-data').textContent);
                const n = c.nodes.find(n => n[1].includes('Surface')) || c.nodes[0];
                return n[1];
            }""")

            before_frames = initial["scene"]["frames"]
            motion_start = time.perf_counter()
            page.evaluate("GXAtlas.measureMotion(1600)")
            page.wait_for_timeout(1700)
            elapsed = time.perf_counter() - motion_start
            after_motion = inspect(page)
            frames = after_motion["scene"]["frames"] - before_frames
            draws = after_motion["scene"]["draws"][-frames:] if frames else []
            fps = ((len(draws) - 1) * 1000 / (draws[-1] - draws[0])) if len(draws) > 1 and draws[-1] > draws[0] else 0
            report["motion"] = {"frames": frames, "wall_seconds": elapsed, "active_draw_fps": fps, "renderer": initial["scene"]["renderer"]}
            page.locator("#resetView").click()

            page.keyboard.press("/")
            check("keyboard_search", page.locator("#search").evaluate("e => e === document.activeElement"))
            search(page, search_term)
            check("search_matches", inspect(page)["matched"] > 0, inspect(page)["matched"])
            screenshot(page, "02-search-results")
            search(page, "__gx_atlas_intentionally_missing_938710__")
            check("empty_search", inspect(page)["matched"] == 0 and page.locator("#emptyResults").is_visible())
            screenshot(page, "03-empty-search")
            page.locator("#clearFilters").click()
            report["filter_ms"] = inspect(page)["filterMs"]

            module_value = str(page.evaluate("JSON.parse(document.querySelector('#graph-data').textContent).nodes.find(n => n[2] >= 0)[5]"))
            page.locator("#module").select_option(module_value)
            check("module_filter", inspect(page)["matched"] > 0)
            screenshot(page, "04-module-files")
            check("file_keyboard_entry", page.locator("#fileJump").is_visible())
            file_value = page.locator("#fileJump option").nth(1).get_attribute("value")
            page.locator("#fileJump").select_option(file_value)
            check("file_to_symbols", inspect(page)["matched"] > 0 and not page.locator("#fileJump").is_visible())
            screenshot(page, "04b-file-symbols")
            page.locator("#clearFilters").click()
            report["filter_ms"] = inspect(page)["filterMs"]
            page.locator(".result-button").first.click()
            page.wait_for_function("GXAtlas.inspect().loadedRelations > 0 || document.querySelector('#relationError').hidden === false")
            selected = inspect(page)
            check("lazy_relations", selected["loadedShards"] > 0 and selected["loadedRelations"] > 0, selected["loadedRelations"])
            check("neighbor_draw_budget", selected["scene"]["visibleNodes"] <= 41, selected["scene"]["visibleNodes"])
            screenshot(page, "05-node-relations")
            page.locator(".relation-context summary").first.click()
            check("relation_context_score", "提取器置信度" in page.locator(".relation-context").first.inner_text())
            screenshot(page, "05b-relation-evidence")
            if page.locator("#moreRelations").is_visible():
                previous_count = selected["loadedRelations"]
                page.locator("#moreRelations").click()
                page.wait_for_function("n => GXAtlas.inspect().loadedRelations > n", arg=previous_count)
                check("relation_pagination", inspect(page)["loadedRelations"] > previous_count)
            else:
                check("relation_pagination", selected["counts"].get("edges", 0) < 100, "No pageable node selected")
            page.locator("#evidence").select_option("INFERRED")
            check("evidence_filter", page.locator("#relations .relation:not(.inferred)").count() == 0)
            page.locator("#evidence").select_option("")

            if not page.locator("#sourceLink").count():
                source_node = page.evaluate("""() => {
                    const c=JSON.parse(document.querySelector('#graph-data').textContent);
                    const i=c.nodes.findIndex(n => n[2] >= 0 && n[3] > 0 && n[10] > 0);
                    return {index:i,id:c.nodes[i][0]};
                }""")
                search(page, source_node["id"])
                page.locator('.result-button[data-node="' + str(source_node["index"]) + '"]').click()
            if page.locator("#sourceLink").count():
                href = page.locator("#sourceLink").get_attribute("href")
                page.locator("#sourceLink").click()
                page.wait_for_load_state("load")
                anchor = page.url.split("#", 1)[1] if "#" in page.url else ""
                check("source_anchor", bool(anchor) and page.locator('[id="' + anchor + '"]').count() == 1, href)
                screenshot(page, "06-source-line")
                page.go_back(wait_until="load")
                ready(page)
                page.wait_for_function("GXAtlas.inspect().selected >= 0")
            else:
                check("source_anchor", False, "Selected node had no source link")
            page.locator("#nodeViewLink").click()
            page.wait_for_load_state("load")
            ready(page)
            check("detail_deep_link", page.locator("body").get_attribute("data-view") == "detail" and inspect(page)["selected"] >= 0)
            screenshot(page, "07-detail-deep-link")
            unknown_node = page.evaluate("""() => {
                const c = JSON.parse(document.querySelector('#graph-data').textContent);
                const i = c.nodes.findIndex(n => n[2] < 0 && n[10] === 0);
                return i >= 0 ? {index:i,id:c.nodes[i][0]} : null;
            }""")
            if unknown_node:
                search(page, unknown_node["id"])
                page.locator('.result-button[data-node="' + str(unknown_node["index"]) + '"]').click()
                check("unknown_source_zero_degree", page.locator("#sourceLink").count() == 0 and inspect(page)["loadedRelations"] == 0 and "没有已记录" in page.locator("#relationStatus").inner_text())
                screenshot(page, "07b-unknown-source")
                page.locator("#clearFilters").click()
                page.locator(".result-button").first.click()
                page.wait_for_function("GXAtlas.inspect().loadedRelations > 0")
            page.locator("#toggle2d").click()
            check("manual_2d", inspect(page)["scene"]["mode"] == "2d")
            screenshot(page, "08-flat-view")

            page.locator("#helpButton").click()
            check("help_background_inert", page.locator(".workspace").evaluate("e => e.inert"))
            page.keyboard.press("Shift+Tab")
            check("help_focus_trap", page.locator("#helpPanel").evaluate("e => e.contains(document.activeElement)"))
            page.keyboard.press("Escape")
            check("help_focus_return", page.locator("#helpButton").evaluate("e => e === document.activeElement"))

            page.set_viewport_size({"width": 1024, "height": 768})
            page.locator("#showDetail").click()
            screenshot(page, "09-tablet-detail")
            page.set_viewport_size({"width": 390, "height": 844})
            page.locator("#closeDetail").click()
            check("narrow_no_horizontal_overflow", page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
            screenshot(page, "10-mobile-map")
            page.locator("#showList").click()
            screenshot(page, "11-mobile-search")
            page.locator(".result-button").first.click()
            check("narrow_single_panel", page.locator("#detailPanel").is_visible() and not page.locator("#listPanel").is_visible())
            screenshot(page, "12-mobile-detail")
            page.keyboard.press("Escape")
            check("narrow_focus_return", page.locator("#showDetail").evaluate("e => e === document.activeElement"))

            page.set_viewport_size({"width": 1440, "height": 900})
            page.goto(overview.as_uri(), wait_until="load")
            ready(page)
            page.locator("#toggleExplore").click()
            check("immersive_layout", not page.locator("#listPanel").is_visible() and not page.locator("#detailPanel").is_visible())
            screenshot(page, "13-immersive")
            page.keyboard.press("Escape")
            page.emulate_media(reduced_motion="reduce")
            page.wait_for_function("GXAtlas.inspect().scene.reducedMotion")
            check("reduced_motion", inspect(page)["scene"]["reducedMotion"])
            screenshot(page, "14-reduced-motion")
            page.emulate_media(reduced_motion="no-preference")
            if inspect(page)["scene"]["mode"] == "3d":
                page.evaluate("GXAtlas.loseContext()")
                page.wait_for_function("GXAtlas.inspect().scene.mode === '2d'")
                check("context_loss_fallback", inspect(page)["scene"]["reason"] == "context-lost")
                screenshot(page, "15-context-loss")
            else:
                report["checks"].append({"name": "context_loss_fallback", "status": "PENDING", "detail": "WebGL was unavailable"})

            # A separate copy with a deliberately absent data directory exercises retry.
            expected_missing = True
            missing_root = output / "missing-data"
            missing_root.mkdir()
            missing_html = missing_root / "overview.html"
            shutil.copy2(overview, missing_html)
            broken = context.new_page()
            attach(broken)
            broken.goto(missing_html.as_uri(), wait_until="load")
            ready(broken)
            broken.locator(".result-button").first.click()
            broken.wait_for_selector("#relationError:not([hidden])", timeout=15000)
            check("missing_shard_error", broken.locator("#relationError").is_visible())
            screenshot(broken, "16-missing-shard")
            shard = broken.evaluate("() => { const c=JSON.parse(document.querySelector('#graph-data').textContent); return c.shards[c.nodes[GXAtlas.inspect().selected][9][0][0]]; }")
            restored_shard = missing_root / shard
            restored_shard.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(overview.parent / shard, restored_shard)
            broken.locator("#retryRelations").click()
            broken.wait_for_function("GXAtlas.inspect().loadedRelations > 0")
            check("missing_shard_retry", not broken.locator("#relationError").is_visible())
            broken.close()
            expected_missing = False

            blocked_context = browser.new_context(viewport={"width": 1024, "height": 768})
            blocked_context.add_init_script("""const original = HTMLCanvasElement.prototype.getContext;
HTMLCanvasElement.prototype.getContext = function(kind, ...args) {
  if (kind === 'webgl' || kind === 'webgl2') return null;
  return original.call(this, kind, ...args);
};""")
            blocked = blocked_context.new_page()
            attach(blocked)
            blocked.goto(overview.as_uri(), wait_until="load")
            ready(blocked)
            check("webgl_unavailable_fallback", inspect(blocked)["scene"]["mode"] == "2d")
            search(blocked, search_term)
            check("fallback_search", inspect(blocked)["matched"] > 0)
            screenshot(blocked, "17-no-webgl")
            blocked_context.close()

            zoom_context = browser.new_context(viewport={"width": 720, "height": 450}, device_scale_factor=2)
            zoom_page = zoom_context.new_page()
            attach(zoom_page)
            zoom_page.goto(overview.as_uri(), wait_until="load")
            ready(zoom_page)
            check("200pct_equivalent_no_overflow", zoom_page.evaluate("document.documentElement.scrollWidth <= innerWidth"))
            check("200pct_result_area", zoom_page.locator(".result-scroll").evaluate("e => e.clientHeight >= 80"))
            screenshot(zoom_page, "18-200pct-equivalent")
            zoom_context.close()

            # Measurements from the original full-size view, before any responsive test.
            report["performance"] = {"first_interactive_ms": initial["readyMs"], "filter_ms": report.get("filter_ms", [])}
            # Search timings are captured before the main page's navigation resets its state.
            report["performance"]["animation_fps"] = fps
            check("no_page_errors", not report["page_errors"], report["page_errors"])
            check("offline_no_external_requests", not report["external_requests"], report["external_requests"])
            unexpected_requests = [item for item in report["request_failures"] if not item["expected_missing_data"]]
            check("no_unexpected_request_failures", not unexpected_requests, unexpected_requests)
            unexpected_console = [item for item in report["console"] if item["type"] == "error" and not item["expected_missing_data"]]
            check("no_unexpected_console_errors", not unexpected_console, unexpected_console)
            if args.enforce_performance:
                check("first_interactive_2s", initial["readyMs"] <= 2000, initial["readyMs"])
                check("filter_200ms", bool(report.get("filter_ms")) and max(report["filter_ms"]) <= 200, report.get("filter_ms"))
                check("motion_30fps", fps >= 30, fps)
            browser.close()
    except Exception as exc:
        failures.append("browser_runner")
        report["runner_error"] = str(exc)
    report["status"] = "FAIL" if failures else "PASS"
    report["failures"] = failures
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"status": report["status"], "failures": failures, "evidence": str(output), "visual_review": report["visual_review"]}, ensure_ascii=False))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
