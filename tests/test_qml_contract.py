import re
from pathlib import Path

ROOT = Path(__file__).parents[1]
NOT_ITEMS = {
    "Shortcut",
    "Timer",
    "Process",
    "FileView",
    "Connections",
    "QtObject",
    "Binding",
    "Instantiator",
    "Component",
}
OBJECT = re.compile(r"^([A-Z][A-Za-z0-9.]*)\s*\{")


def keyboard_panel_children(source: str) -> list[str]:
    lines = source.splitlines()
    start = next(
        i for i, line in enumerate(lines) if line.lstrip().startswith("KeyboardPanel {")
    )
    depth = 0
    names = []
    for index, line in enumerate(lines[start:]):
        stripped = line.lstrip()
        if index and depth == 1:
            match = OBJECT.match(stripped)
            if match:
                names.append(match.group(1))
        depth += stripped.count("{") - stripped.count("}")
        if index and depth <= 0:
            break
    return names


def test_keyboard_panel_direct_children_are_items():
    names = keyboard_panel_children((ROOT / "Panel.qml").read_text(encoding="utf-8"))
    assert "PanelKeyCatcher" in names
    bad = [name for name in names if name in NOT_ITEMS]
    assert not bad, f"KeyboardPanel contentItem only accepts Items, not {bad}"


def test_shortcut_as_keyboard_panel_child_is_rejected():
    sample = """
    KeyboardPanel {
      Shortcut { sequences: ["h"] }
      PanelKeyCatcher { id: keyCatcher }
    }
    """
    names = keyboard_panel_children(sample)
    assert "Shortcut" in names
    assert any(name in NOT_ITEMS for name in names)


def test_search_hint_advertises_the_tab_switch():
    source = (ROOT / "Panel.qml").read_text(encoding="utf-8")
    search_bar = source[source.index("id: searchBar") : source.index("id: separator")]
    assert '"tab switches mode"' in search_bar


if __name__ == "__main__":
    test_keyboard_panel_direct_children_are_items()
    test_shortcut_as_keyboard_panel_child_is_rejected()
    test_search_hint_advertises_the_tab_switch()
    print("QML contract tests passed")
