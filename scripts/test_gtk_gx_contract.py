#!/usr/bin/env python3
"""Contracts between the Ghostty GX layer of the GTK app and the upstream GTK sources it hooks into.

`src/apprt/gtk/gx/` reaches into upstream widgets by name: template children of the window
and the terminal, header bar buttons found by icon name, menus that replace the upstream
models, and actions that upstream classes register. GTK resolves all of these at runtime,
so a rename on an upstream sync compiles fine and only shows up as a missing menu, a dead
menu item or a warning. These tests read the blueprints and Zig sources and fail instead:

- every template child the GX layer fetches is bound by its upstream class and declared in
  that class's blueprint with the expected type;
- the icons the GX layer matches header bar buttons by are in the window blueprint;
- every blueprint a GX module loads exists and is compiled into the gresource bundle;
- the GX menus define every menu the GX code fills in, keep every action of the upstream
  menus they replace, and only use actions some class registers;
- the GX settings dialog binds exactly the children and callbacks its blueprint uses.

Run from the repo root: python scripts/run_unittests.py test_gtk_gx_contract
"""

from __future__ import annotations

import re
import unittest
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GTK = ROOT / "src/apprt/gtk"
GX = GTK / "gx"
UI = GTK / "ui"
GX_MENUS_BLP = UI / "1.5/gx/menus.blp"
GRESOURCE_ZIG = GTK / "build/gresource.zig"

# Template children the GX layer fetches with gtk_widget_get_template_child, and the type their
# blueprint must declare (GX code casts to these types or walks them).
TEMPLATE_CHILDREN = {
    ("Window", "toolbar"): "Adw.ToolbarView",
    ("Window", "toast_overlay"): "Adw.ToastOverlay",
    ("Surface", "context_menu"): "PopoverMenu",
}

# The upstream menus the GX menus replace: (blueprint, upstream menu id, GX menu id).
REPLACED_MENUS = (
    ("1.5/window.blp", "main_menu", "main_menu"),
    ("1.5/window.blp", "split_menu", "split_menu"),
    ("1.5/window.blp", "tab_context_menu", "tab_context_menu"),
    ("1.2/surface.blp", "context_menu_model", "context_menu"),
)

# Upstream actions the GX menus deliberately replace, with their replacement.
RENAMED_ACTIONS = {
    ("win.about", None): ("app.gx-about", None),
    ("app.open-config", "os-open"): ("app.gx-open-config-file", None),
}

MAIN_CONTEXT_ACTIONS = {
    ("win.copy", None): ("win.copy", None),
    ("win.paste", None): ("win.paste", None),
    ("win.prompt-window-title", None): ("win.prompt-window-title", None),
    ("win.close", None): ("win.close", None),
    ("win.prompt-tab-title", None): ("tab.prompt-tab-title", None),
    ("win.close-tab", "this"): ("tab.close", "this"),
    ("win.clear", None): ("win.clear", None),
    ("win.reset", None): ("win.reset", None),
    ("win.toggle-inspector", None): ("win.toggle-inspector", None),
    ("app.open-config", "new-window"): ("app.open-config", "new-window"),
}

# The upstream class that registers each action group the menus use.
ACTION_GROUPS = {
    "app": "class/application.zig",
    "win": "class/window.zig",
    "tab": "class/tab.zig",
    "split-tree": "class/split_tree.zig",
    "surface": "class/surface.zig",
}

OPENER_RE = re.compile(
    r"^(?:\[[^\]]*\]\s*)?(?:[\w-]+\s*:\s*)?"
    r"(?P<header>template\s+\$\w+\s*:\s*[\w.$]+|[\w.$]+)(?:\s+(?P<id>[A-Za-z_]\w*))?\s*\{$"
)
PROPERTY_RE = re.compile(r"^(?P<name>[\w-]+)\s*:\s*(?P<value>.+?);$")
SIGNAL_RE = re.compile(r"^[\w:-]+\s*=>\s*\$(?P<handler>\w+)\(")
TRANSLATED_RE = re.compile(r'^(?:_|C_)\((?:"[^"]*"\s*,\s*)?("(?:[^"\\]|\\.)*")\)$')
TEMPLATE_CHILD_CALL_RE = re.compile(
    r"gtk_widget_get_template_child\(\s*[^,]+,\s*(?P<cls>\w+)\.getGObjectType\(\),\s*\"(?P<name>\w+)\"", re.S)
ICON_IS_RE = re.compile(r'iconIs\([^;]*?,\s*"(?P<icon>[\w-]+)"\)')
BLUEPRINT_REF_RE = re.compile(
    r"gresource\.blueprint\(\.\{\s*\.major\s*=\s*(\d+),\s*\.minor\s*=\s*(\d+),\s*\.name\s*=\s*\"([^\"]+)\",?\s*\}\)")
ACTION_DECL_RE = re.compile(r"\.init(?:Stateful)?\(\s*\"([a-z0-9-]+)\"")
CHILD_BIND_RE = re.compile(r'bindTemplateChildPrivate\("(\w+)"')
CALLBACK_BIND_RE = re.compile(r'bindTemplateCallback\("(\w+)"')
MENU_ID_RE = re.compile(r'self\.menu\("(\w+)"\)')
MENU_ENUM_RE = re.compile(r"pub const Id = enum \{(?P<body>[^}]*)\}")
CLASS_NAME_RE = re.compile(r'\.name = "(Ghostty\w+)"')


@dataclass
class Node:
    """One blueprint object, template, menu, section, submenu or item."""

    kind: str
    id: str | None = None
    props: dict[str, str] = field(default_factory=dict)
    handlers: list[str] = field(default_factory=list)
    children: list["Node"] = field(default_factory=list)

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()


def unquote(value: str) -> str:
    value = value.strip()
    translated = TRANSLATED_RE.match(value)
    if translated:
        value = translated.group(1)
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def strip_comments(text: str) -> str:
    """Drop // and /* */ comments without touching string literals."""
    out = []
    position = 0
    for match in re.finditer(r'"(?:[^"\\\n]|\\.)*"|/\*.*?\*/|//[^\n]*', text, re.S):
        out.append(text[position:match.start()])
        token = match.group()
        out.append(token if token.startswith('"') else re.sub(r"[^\n]", "", token))
        position = match.end()
    out.append(text[position:])
    return "".join(out)


def parse_blueprint(text: str) -> Node:
    """A line-based reading of a blueprint formatted like the upstream files (one statement per line)."""
    root = Node("file")
    stack = [root]
    for raw in strip_comments(text.replace("\r\n", "\n")).split("\n"):
        line = raw.strip()
        if not line:
            continue
        opener = OPENER_RE.match(line)
        if opener:
            header = opener.group("header")
            if header.startswith("template"):
                node = Node("template", header.split()[1].rstrip(":"))
                node.props["parent"] = header.split(":", 1)[1].strip()
            else:
                node = Node(header, opener.group("id"))
            stack[-1].children.append(node)
            stack.append(node)
            continue
        if line in ("}", "};"):
            if len(stack) == 1:
                raise ValueError("unbalanced '}' in blueprint")
            stack.pop()
            continue
        signal = SIGNAL_RE.match(line)
        if signal:
            stack[-1].handlers.append(signal.group("handler"))
            continue
        prop = PROPERTY_RE.match(line)
        if prop:
            stack[-1].props[prop.group("name")] = unquote(prop.group("value"))
    if len(stack) != 1:
        raise ValueError(f"{len(stack) - 1} unclosed block(s) in blueprint")
    return root


def ids(root: Node) -> dict[str, Node]:
    return {node.id: node for node in root.walk() if node.id}


def menu_actions(menu: Node) -> set[tuple[str, str | None]]:
    return {(node.props["action"], node.props.get("target"))
            for node in menu.walk() if node.kind == "item" and "action" in node.props}


def blueprint(path: str) -> Node:
    return parse_blueprint((UI / path).read_text(encoding="utf-8"))


def gx_sources() -> dict[str, str]:
    return {path.name: path.read_text(encoding="utf-8") for path in sorted(GX.glob("*.zig"))}


def snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def class_file(cls: str) -> Path:
    return GTK / "class" / f"{snake(cls)}.zig"


def class_blueprint(source: str) -> str:
    refs = BLUEPRINT_REF_RE.findall(source)
    if len(refs) != 1:
        raise AssertionError(f"expected one gresource.blueprint() call, found {len(refs)}")
    major, minor, name = refs[0]
    return f"{major}.{minor}/{name}.blp"


def registered_actions() -> dict[str, set[str]]:
    """Action names registered per Zig file below src/apprt/gtk, keyed by path relative to it."""
    return {path.relative_to(GTK).as_posix(): set(ACTION_DECL_RE.findall(path.read_text(encoding="utf-8")))
            for path in sorted(GTK.rglob("*.zig"))}


def template(root: Node) -> Node:
    found = [node for node in root.children if node.kind == "template"]
    if len(found) != 1:
        raise AssertionError(f"expected one template, found {len(found)}")
    return found[0]


class BlueprintParserTests(unittest.TestCase):
    TEXT = "\n".join((
        "using Gtk 4.0;",
        "template $GhosttyX: Adw.Bin {",
        "  /* block { comment */",
        "  realize => $realize();",
        "  content: Adw.ToolbarView toolbar {",
        "    [top]",
        "    Gtk.MenuButton {",
        '      icon-name: "open-menu-symbolic"; // trailing',
        "      menu-model: main_menu;",
        "    }",
        "  };",
        "}",
        "menu main_menu {",
        "  section {",
        "    submenu gx_sub {",
        '      label: _("Split");',
        "      item {",
        '        label: C_("ctx", "A // b");',
        '        action: "win.copy";',
        '        target: "this";',
        "      }",
        "    }",
        "  }",
        "}",
    ))

    def test_objects_ids_properties_and_handlers(self):
        root = parse_blueprint(self.TEXT.replace("\n", "\r\n"))
        template = root.children[0]
        self.assertEqual(("template", "$GhosttyX", "Adw.Bin"), (template.kind, template.id, template.props["parent"]))
        self.assertEqual(["realize"], template.handlers)
        found = ids(root)
        self.assertEqual("Adw.ToolbarView", found["toolbar"].kind)
        button = found["toolbar"].children[0]
        self.assertEqual(("Gtk.MenuButton", "open-menu-symbolic", "main_menu"),
                         (button.kind, button.props["icon-name"], button.props["menu-model"]))
        self.assertEqual({("win.copy", "this")}, menu_actions(found["main_menu"]))
        self.assertEqual("Split", found["gx_sub"].props["label"])
        self.assertEqual("A // b", found["gx_sub"].children[0].props["label"])

    def test_unbalanced_blocks_are_rejected(self):
        for text in ("menu m {\n", "}\n"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_blueprint(text)


class TemplateChildTests(unittest.TestCase):
    def test_the_table_lists_every_template_child_the_gx_layer_fetches(self):
        used = {(m.group("cls"), m.group("name"))
                for text in gx_sources().values() for m in TEMPLATE_CHILD_CALL_RE.finditer(text)}
        self.assertEqual(used, set(TEMPLATE_CHILDREN))

    def test_children_are_bound_and_declared_with_their_type(self):
        for (cls, name), kind in TEMPLATE_CHILDREN.items():
            with self.subTest(cls=cls, name=name):
                source = class_file(cls).read_text(encoding="utf-8")
                self.assertIn(f'.name = "Ghostty{cls}"', source)
                self.assertIn(name, CHILD_BIND_RE.findall(source), f"class/{snake(cls)}.zig must bind {name}")
                root = blueprint(class_blueprint(source))
                self.assertEqual(f"$Ghostty{cls}", template(root).id)
                node = ids(root).get(name)
                self.assertIsNotNone(node, f"{class_blueprint(source)} has no object {name}")
                self.assertIn(node.kind, (kind, f"Gtk.{kind}"))


class HeaderBarTests(unittest.TestCase):
    def test_matched_icons_are_on_window_buttons(self):
        window = blueprint("1.5/window.blp")
        icons = {node.props["icon-name"]: node.kind for node in window.walk() if "icon-name" in node.props}
        matched = {m.group("icon") for text in gx_sources().values() for m in ICON_IS_RE.finditer(text)}
        self.assertEqual(matched, {"open-menu-symbolic", "view-grid-symbolic"})
        self.assertEqual(icons.get("open-menu-symbolic"), "Gtk.MenuButton")
        self.assertEqual(icons.get("view-grid-symbolic"), "Gtk.ToggleButton")

    def test_buttons_carry_the_menus_the_gx_layer_replaces(self):
        window = blueprint("1.5/window.blp")
        models = [(node.kind, node.props.get("menu-model")) for node in window.walk() if "menu-model" in node.props]
        self.assertIn(("Gtk.MenuButton", "main_menu"), models)
        self.assertIn(("Adw.SplitButton", "split_menu"), models)
        self.assertIn(("Adw.TabView", "tab_context_menu"), models)
        surface = blueprint("1.2/surface.blp")
        self.assertEqual(ids(surface)["context_menu"].props.get("menu-model"), "context_menu_model")


class BlueprintBundleTests(unittest.TestCase):
    def test_every_blueprint_the_gx_layer_loads_exists_and_is_bundled(self):
        bundled = set(re.findall(r'\.\{\s*\.major\s*=\s*(\d+),\s*\.minor\s*=\s*(\d+),\s*\.name\s*=\s*"([^"]+)"\s*\}',
                                 GRESOURCE_ZIG.read_text(encoding="utf-8")))
        loaded = {ref for text in gx_sources().values() for ref in BLUEPRINT_REF_RE.findall(text)}
        self.assertGreaterEqual(len(loaded), 2)
        for major, minor, name in sorted(loaded):
            with self.subTest(name=name):
                self.assertTrue((UI / f"{major}.{minor}/{name}.blp").is_file())
                self.assertIn((major, minor, name), bundled)


class MenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gx_menus = parse_blueprint(GX_MENUS_BLP.read_text(encoding="utf-8"))
        cls.gx_ids = ids(cls.gx_menus)

    def test_every_menu_the_gx_code_fills_in_is_defined(self):
        source = (GX / "menus.zig").read_text(encoding="utf-8")
        enum = MENU_ENUM_RE.search(source)
        self.assertIsNotNone(enum)
        wanted = {name.strip() for name in enum.group("body").split(",") if name.strip()}
        wanted |= set(MENU_ID_RE.findall(source))
        self.assertGreaterEqual(len(wanted), 7)
        for name in sorted(wanted):
            with self.subTest(menu=name):
                self.assertIn(name, self.gx_ids)
                self.assertIn(self.gx_ids[name].kind, ("menu", "section", "submenu"))

    def test_gx_menus_keep_every_upstream_action(self):
        for path, upstream_id, gx_id in REPLACED_MENUS:
            with self.subTest(menu=f"{path}:{upstream_id}"):
                upstream = ids(blueprint(path)).get(upstream_id)
                self.assertIsNotNone(upstream, f"{path} has no menu {upstream_id}")
                self.assertEqual(upstream.kind, "menu")
                actions = menu_actions(upstream)
                moved = MAIN_CONTEXT_ACTIONS if gx_id == "main_menu" else {}
                expected = {RENAMED_ACTIONS.get(action, action) for action in actions if action not in moved}
                missing = expected - menu_actions(self.gx_ids[gx_id])
                self.assertEqual(missing, set(), f"gx/menus.blp {gx_id} lacks actions of upstream {upstream_id}")
                for action in actions & moved.keys():
                    self.assertIn(moved[action], menu_actions(self.gx_ids["context_menu"]))

    def test_main_menu_matches_the_windows_order_and_has_twelve_entries(self):
        labels = [node.props["label"] for section in self.gx_ids["main_menu"].children
                  for node in section.children if "label" in node.props]
        self.assertEqual(labels, ["New Tab", "New Window", "New Tab with Profile", "Split",
                                  "Command Palette", "Settings…", "Keyboard Shortcuts", "Language",
                                  "Reload Configuration", "Open Configuration File", "About Ghostty GX", "Quit"])
        self.assertEqual(self.gx_ids["gx_view_section"].kind, "section")

    def test_tab_context_actions_are_distinct_from_active_tab_actions(self):
        actions = menu_actions(self.gx_ids["tab_context_menu"])
        wanted = {("win.gx-tab-" + name, None) for name in
                  ("close", "close-others", "close-right", "duplicate", "move-window", "pin")}
        self.assertTrue(wanted <= actions)
        source = (GX / "window.zig").read_text(encoding="utf-8")
        self.assertIn("adw.TabView.signals.setup_menu.connect", source)
        self.assertIn("context_page_key", source)

    def test_gx_menu_actions_are_registered(self):
        registered = registered_actions()
        gx_layer = set().union(*(names for path, names in registered.items() if path.startswith("gx/")))
        actions = {action for menu in self.gx_menus.children for action, _ in menu_actions(menu)}
        actions |= set(re.findall(r'"((?:app|win)\.[a-z0-9-]+)"', (GX / "menus.zig").read_text(encoding="utf-8")))
        self.assertGreaterEqual(len(actions), 20)
        for action in sorted(actions):
            group, _, name = action.partition(".")
            with self.subTest(action=action):
                self.assertIn(group, ACTION_GROUPS)
                owner = registered.get(ACTION_GROUPS[group], set())
                self.assertIn(name, owner | gx_layer, f"neither {ACTION_GROUPS[group]} nor the GX layer registers {action}")


class SettingsDialogTests(unittest.TestCase):
    def test_bound_children_and_callbacks_match_the_blueprint(self):
        source = (GX / "settings_dialog.zig").read_text(encoding="utf-8")
        root = blueprint(class_blueprint(source))
        self.assertIn(template(root).id.lstrip("$"), CLASS_NAME_RE.findall(source))
        declared = set(ids(root))
        children = set(CHILD_BIND_RE.findall(source))
        self.assertGreater(len(children), 10)
        self.assertEqual(children - declared, set(), "bound template children missing from the blueprint")
        handlers = {handler for node in root.walk() for handler in node.handlers}
        callbacks = set(CALLBACK_BIND_RE.findall(source))
        self.assertEqual(handlers - callbacks, set(), "blueprint handlers without bindTemplateCallback")
        self.assertEqual(callbacks - handlers, set(), "bound callbacks the blueprint never uses")


if __name__ == "__main__":
    unittest.main()
