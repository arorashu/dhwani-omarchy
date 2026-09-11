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


def search_field_key_block(source: str) -> str:
    """Return the search field's Keys.onPressed handler body."""
    lines = source.splitlines()
    start = next(
        i for i, line in enumerate(lines) if line.strip().startswith("id: searchField")
    )
    capturing = False
    depth = 0
    block = []
    for line in lines[start:]:
        if not capturing and "Keys.onPressed" in line:
            capturing = True
        if capturing:
            block.append(line)
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                break
    assert block, "searchField has no Keys.onPressed handler"
    return "\n".join(block)


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


def test_back_from_a_show_reloads_the_show_list():
    # Regression: opening a show from a Trending show search on a cold All Shows
    # cache left the list empty after Escape, because back() cleared openShow
    # without asking the service for the show list again.
    source = (ROOT / "Panel.qml").read_text(encoding="utf-8")
    body = function_body(source, "back")
    assert "openShow = null" in body
    assert "ensureData(false)" in body
    assert body.index("openShow = null") < body.index("ensureData(false)")
    # Ordinary browsing navigation is preserved: the saved cursor is restored
    # before the list is (re)requested, so returning never resets the position.
    assert body.index("restoreIndex()") < body.index("ensureData(false)")
    # back() must reach the All Shows branch of ensureData for the reload to run.
    ensure = function_body(source, "ensureData")
    assert "tab === 2 && !openShow" in ensure
    assert "ensureShows(force)" in ensure


def test_search_field_tab_switches_mode_and_keeps_focus():
    block = search_field_key_block((ROOT / "Panel.qml").read_text(encoding="utf-8"))
    assert "Qt.Key_Tab" in block
    assert "Qt.Key_Backtab" in block
    assert "root.setSearchKind(" in block
    # Tab toggles in both directions between the two search modes.
    assert 'root.searchKind === "shows"' in block
    # Native Tab must not hand focus to the next item: typing continues.
    assert "searchField.forceActiveFocus()" in block
    # Focus traversal must be suppressed.
    assert "event.accepted = true" in block


def test_search_bar_advertises_the_tab_mode_switch():
    source = (ROOT / "Panel.qml").read_text(encoding="utf-8")
    search_bar = source[source.index("id: searchBar") : source.index("id: separator")]
    assert '"tab switches mode"' in search_bar


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
    test_back_from_a_show_reloads_the_show_list()
    test_search_field_tab_switches_mode_and_keeps_focus()
    test_search_bar_advertises_the_tab_mode_switch()
    print("QML contract tests passed")
