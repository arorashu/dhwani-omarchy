import importlib.util
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[1]
FIXTURES = Path(__file__).parent / "fixtures"
SPEC = importlib.util.spec_from_file_location("dhwani_state", ROOT / "state.py")
state = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(state)


def parse(kind: str, fixture: str, extra=""):
    script = f"""
const fs = require('fs');
const Model = require({json.dumps(str(ROOT / "Model.js"))});
const raw = fs.readFileSync({json.dumps(str(FIXTURES / fixture))}, 'utf8');
const result = Model.{kind}(raw{extra});
if (!result.ok) throw new Error(result.error);
process.stdout.write(JSON.stringify(result));
"""
    return json.loads(subprocess.check_output(["node", "-e", script], cwd=ROOT))


def test_fake_api_to_persisted_queue(tmp_path: Path):
    trending = parse("parseTrending", "trending.json", ", 10")
    shows = parse("parsePodcasts", "podcasts.json")
    show = parse("parseShow", "show.json")
    assert [item["episodeId"] for item in trending["episodes"]] == [
        "AOW3VXulOz",
        "ydMOiRDhLM",
    ]
    assert shows["total"] == 2
    assert show["episodes"][0]["podcastTitle"] == "Y Combinator Startup Podcast"

    queue_script = f"""
const Model = require({json.dumps(str(ROOT / "Model.js"))});
const trending = {json.dumps(trending["episodes"])};
const show = {json.dumps(show["episodes"])};
let queue = [];
queue = Model.enqueue(queue, trending[1]);
queue = Model.enqueue(queue, show[0]);
queue = Model.enqueue(queue, trending[1]);
queue = Model.rememberPosition(queue, queue[0], 1122, 4424);
process.stdout.write(JSON.stringify(queue));
"""
    queue = json.loads(subprocess.check_output(["node", "-e", queue_script], cwd=ROOT))
    assert [item["episodeId"] for item in queue] == ["ydMOiRDhLM", "IuiARqppaF"]
    assert queue[0]["position"] == 1122

    config = {"state_dir": tmp_path / "dhwani-omarchy"}
    payload = state.empty()
    payload["queue"] = queue
    payload["nav"]["tab"] = 1
    payload["cache"]["trending"] = {"fetchedAt": 1, "episodes": trending["episodes"]}
    payload["cache"]["shows"] = {
        "fetchedAt": 1,
        "items": shows["shows"],
        "total": shows["total"],
    }
    state.save(payload, config)

    restored = json.loads(
        subprocess.check_output(
            [
                "node",
                "-e",
                f"""
const Model = require({json.dumps(str(ROOT / "Model.js"))});
const raw = {json.dumps(json.dumps(state.load(config)))};
const parsed = Model.parseState(raw);
process.stdout.write(JSON.stringify(parsed));
""",
            ],
            cwd=ROOT,
        )
    )
    assert restored["nav"]["tab"] == 1
    assert restored["queue"][0]["audioUrl"] == "https://cdn.example.test/sonos.mp3"
    assert restored["queue"][0]["position"] == 1122
    assert restored["queue"][1]["episodeId"] == "IuiARqppaF"


if __name__ == "__main__":
    import tempfile

    with tempfile.TemporaryDirectory() as directory:
        test_fake_api_to_persisted_queue(Path(directory))
    print("E2E tests passed")
