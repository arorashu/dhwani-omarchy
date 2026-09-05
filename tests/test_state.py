import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("dhwani_state", ROOT / "state.py")
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


def test_round_trip_with_injected_dir(tmp_path: Path):
    config = {"state_dir": tmp_path / "dhwani-omarchy"}
    payload = state.empty()
    payload["queue"] = [{"episodeId": "abcdefghij", "title": "One"}]
    saved = state.save(payload, config)
    loaded = state.load(config)
    assert saved == config["state_dir"] / "state.json"
    assert loaded["queue"][0]["title"] == "One"


def test_corrupt_file_returns_empty(tmp_path: Path):
    config = {"state_path": tmp_path / "state.json", "state_dir": tmp_path}
    config["state_path"].write_text("{", encoding="utf-8")
    loaded = state.load(config)
    assert loaded["schemaVersion"] == 1
    assert loaded["queue"] == []


def test_missing_file_returns_empty(tmp_path: Path):
    loaded = state.load(
        {"state_path": tmp_path / "missing.json", "state_dir": tmp_path}
    )
    assert loaded == state.empty()


if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        test_round_trip_with_injected_dir(root / "a")
        (root / "b").mkdir()
        test_corrupt_file_returns_empty(root / "b")
        test_missing_file_returns_empty(root / "c")
        json.dumps(state.empty())
    print("State tests passed")
