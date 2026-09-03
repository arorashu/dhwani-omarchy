import importlib.util
import json
import socket
import tempfile
import threading
import time
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "dhwani_play", Path(__file__).parents[1] / "play.py"
)
play = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(play)


def test_only_http_audio_sources_are_accepted():
    assert play.valid_url("https://cdn.example.test/episode.mp3")
    assert play.valid_url("http://localhost:8000/audio")
    assert not play.valid_url("file:///tmp/episode.mp3")
    assert not play.valid_url("not-a-url")


def test_mpv_is_audio_only_and_uses_its_own_ipc_socket():
    socket_file = Path("/run/user/1000/dhwani.sock")
    command = play.mpv_command(
        socket_file,
        "https://cdn.example.test/episode.mp3",
        "Episode · Podcast",
    )
    assert command[0] == "mpv"
    assert "--no-video" in command
    assert "--pause=no" in command
    assert f"--input-ipc-server={socket_file}" in command
    assert command[-1] == "https://cdn.example.test/episode.mp3"


def test_concurrent_launches_start_one_player():
    with tempfile.TemporaryDirectory() as directory:
        runtime = Path(directory)
        starts, loads = [], []
        original_runtime_dir = play.runtime_dir
        original_popen = play.subprocess.Popen
        original_wait = play.wait_until_owned
        original_load = play.load

        def fake_popen(*args, **kwargs):
            starts.append(args[0])
            return object()

        def fake_wait(process, socket_file, timeout=2):
            time.sleep(0.1)
            socket_file.touch()

        def fake_load(socket_file, url, title):
            loads.append(url)
            return True

        play.runtime_dir = lambda: runtime
        play.subprocess.Popen = fake_popen
        play.wait_until_owned = fake_wait
        play.load = fake_load
        barrier = threading.Barrier(2)

        def launch(index):
            barrier.wait()
            play.play(f"https://cdn.example.test/{index}.mp3", f"Episode {index}")

        try:
            threads = [
                threading.Thread(target=launch, args=(index,)) for index in range(2)
            ]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join()
        finally:
            play.runtime_dir = original_runtime_dir
            play.subprocess.Popen = original_popen
            play.wait_until_owned = original_wait
            play.load = original_load

        assert len(starts) == 1
        assert len(loads) == 1


def test_reused_player_loads_and_unpauses():
    with tempfile.TemporaryDirectory() as directory:
        socket_file = Path(directory) / "dhwani-mpv.sock"
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(socket_file))
        server.listen()
        commands = []

        def answer():
            connection, _ = server.accept()
            with connection, connection.makefile() as requests:
                for _ in range(2):
                    payload = json.loads(requests.readline())
                    commands.append(payload["command"])
                    response = {"error": "success", "request_id": payload["request_id"]}
                    connection.sendall((json.dumps(response) + "\n").encode())

        responder = threading.Thread(target=answer)
        responder.start()
        try:
            assert play.load(
                socket_file, "https://cdn.example.test/episode.mp3", "Episode"
            )
        finally:
            responder.join()
            server.close()

        assert commands[0][0] == "loadfile"
        assert commands[1] == ["set_property", "pause", False]


def test_delayed_ack_does_not_spawn_or_unlink_owner():
    with tempfile.TemporaryDirectory() as directory:
        runtime = Path(directory)
        socket_file = runtime / "dhwani-mpv.sock"
        server = socket.socket(socket.AF_UNIX)
        server.bind(str(socket_file))
        server.listen()

        def delayed_ack():
            connection, _ = server.accept()
            with connection:
                connection.recv(4096)
                time.sleep(1.1)
                try:
                    connection.sendall(
                        json.dumps({"error": "success", "request_id": 1}).encode()
                        + b"\n"
                    )
                except OSError:
                    pass

        responder = threading.Thread(target=delayed_ack)
        responder.start()
        starts = []
        original_runtime_dir = play.runtime_dir
        original_popen = play.subprocess.Popen
        play.runtime_dir = lambda: runtime
        play.subprocess.Popen = lambda *args, **kwargs: starts.append(args)
        try:
            try:
                play.play("https://cdn.example.test/episode.mp3", "Episode")
                raise AssertionError("a delayed ACK must fail visibly")
            except OSError:
                pass
        finally:
            play.runtime_dir = original_runtime_dir
            play.subprocess.Popen = original_popen
            responder.join()
            server.close()

        assert starts == []
        assert socket_file.exists()


if __name__ == "__main__":
    test_only_http_audio_sources_are_accepted()
    test_mpv_is_audio_only_and_uses_its_own_ipc_socket()
    test_concurrent_launches_start_one_player()
    test_reused_player_loads_and_unpauses()
    test_delayed_ack_does_not_spawn_or_unlink_owner()
    print("Playback tests passed")
