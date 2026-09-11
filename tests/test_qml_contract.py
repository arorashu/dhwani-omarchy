import re
from pathlib import Path
from types import SimpleNamespace

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


def refresh_button_enabled(source: str) -> str:
    lines = source.splitlines()
    start = next(
        i
        for i, line in enumerate(lines)
        if line.strip().startswith("id: refreshButton")
    )
    for line in lines[start:]:
        if "enabled:" in line:
            return line.split("enabled:", 1)[1].split("//")[0].strip()
    raise AssertionError("refreshButton has no enabled binding")


def function_body(source: str, name: str) -> str:
    lines = source.splitlines()
    start = next(
        i
        for i, line in enumerate(lines)
        if line.strip().startswith(f"function {name}(")
    )
    depth = 0
    body = []
    for line in lines[start:]:
        body.append(line)
        depth += line.count("{") - line.count("}")
        if depth <= 0:
            break
    return "\n".join(body)


def qml_bool_to_python(expression: str) -> str:
    expression = (
        expression.replace("!==", " != ")
        .replace("===", " == ")
        .replace("&&", " and ")
        .replace("||", " or ")
    )
    return re.sub(r"!(?!=)", " not ", expression)


def test_refresh_button_allows_retry_for_a_queue_search():
    # Regression: the button was disabled whenever tab === 1, so a search that
    # was started from the Queue tab could not be refreshed or retried.
    expression = refresh_button_enabled(
        (ROOT / "Panel.qml").read_text(encoding="utf-8")
    )
    code = qml_bool_to_python(expression)
    states = [
        (False, 1, True),  # queue tab, active search -> must be enabled
        (False, 1, False),  # queue tab, no search       -> disabled
        (False, 0, False),
        (False, 2, False),
        (True, 0, False),  # a fetch is already running
        (True, 1, True),
    ]
    for refreshing, tab, search_active in states:
        root = SimpleNamespace(
            refreshing=refreshing, tab=tab, searchActive=search_active
        )
        expected = (not refreshing) and (search_active or tab != 1)
        actual = eval(code, {"root": root})
        assert actual == expected, (expression, refreshing, tab, search_active)


def test_refresh_retries_search_before_the_queue_early_return():
    body = function_body((ROOT / "Panel.qml").read_text(encoding="utf-8"), "refresh")
    assert "if (searchActive)" in body
    assert "beginSearch" in body
    assert body.index("searchActive") < body.index("tab === 1")


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


if __name__ == "__main__":
    test_keyboard_panel_direct_children_are_items()
    test_shortcut_as_keyboard_panel_child_is_rejected()
    test_refresh_button_allows_retry_for_a_queue_search()
    test_refresh_retries_search_before_the_queue_early_return()
    print("QML contract tests passed")
