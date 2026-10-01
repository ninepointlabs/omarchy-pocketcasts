"""Tests for bin/pocketcasts-bridge: private state files, input validation,
bounded and host-checked HTTP, token refresh, and an end-to-end run of the
player against a fake Pocket Casts server with a real mpv — play, pause,
position sync, the end of an episode, mark-played and autoplay.

Run with tests/run, or directly:

    /usr/bin/python3 -I -B -m unittest discover -s tests -v
"""

import gzip
import http.server
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "bin" / "pocketcasts-bridge"

sys.dont_write_bytecode = True
_loader = importlib.machinery.SourceFileLoader("pocketcasts_bridge", str(BRIDGE))
_spec = importlib.util.spec_from_loader("pocketcasts_bridge", _loader)
bridge = importlib.util.module_from_spec(_spec)
_loader.exec_module(bridge)

PODCAST_A = "11111111-1111-1111-1111-111111111111"
PODCAST_B = "22222222-2222-2222-2222-222222222222"
EP_1 = "aaaaaaaa-0000-0000-0000-000000000001"
EP_2 = "aaaaaaaa-0000-0000-0000-000000000002"
EP_3 = "bbbbbbbb-0000-0000-0000-000000000003"
PASSWORD = "correct horse battery staple"


def mode_of(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


class TempHome(unittest.TestCase):
    """A private throwaway $HOME with every XDG directory pointed inside it."""

    def setUp(self):
        self.home = os.path.realpath(tempfile.mkdtemp(prefix="pc-bridge-"))
        os.chmod(self.home, 0o700)
        self.addCleanup(shutil.rmtree, self.home, True)
        runtime = os.path.join(self.home, "run")
        os.mkdir(runtime, 0o700)
        env = {
            "HOME": self.home,
            "XDG_STATE_HOME": self.home + "/.local/state",
            "XDG_CACHE_HOME": self.home + "/.cache",
            "XDG_CONFIG_HOME": self.home + "/.config",
            "XDG_DATA_HOME": self.home + "/.local/share",
            "XDG_RUNTIME_DIR": runtime,
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.reset_globals()
        self.addCleanup(self.reset_globals)

    def reset_globals(self):
        if bridge._ART_DIR is not None:
            bridge._ART_DIR.close()
        bridge._ART_DIR = None
        bridge._AUTH = None

    @property
    def state(self):
        return os.path.join(self.home, ".local", "state", "omarchy-pocketcasts")


def run_bridge(*argv, stdin=""):
    """Run one subcommand in-process and return its JSON envelope."""
    out = io.StringIO()
    fake_stdin = io.TextIOWrapper(io.BytesIO(stdin.encode("utf-8")), encoding="utf-8")
    with mock.patch.object(sys, "stdout", out), mock.patch.object(sys, "stdin", fake_stdin), \
            mock.patch.object(bridge, "scrub_environment", lambda: None):
        bridge._AUTH = None
        bridge.main(list(argv))
    return json.loads(out.getvalue())


# --------------------------------------------------------------- unit tests

class Validation(unittest.TestCase):
    def test_uuid_must_be_a_uuid(self):
        self.assertEqual(bridge.safe_uuid(EP_1.upper()), EP_1)
        for bad in ["", "../etc", EP_1 + "/x", "x" * 36, None]:
            with self.assertRaises(bridge.ApiError):
                bridge.safe_uuid(bad)

    def test_only_http_media_urls_reach_mpv(self):
        self.assertTrue(bridge.safe_media_url("https://example.com/a.mp3"))
        self.assertTrue(bridge.safe_media_url("http://example.com/a.mp3?x=1"))
        for bad in ["file:///etc/passwd", "/etc/passwd", "lavfi://sine", "av://x", "edl://a",
                    "https://example.com/a\n.mp3", "ytdl://x", "https:///nohost", "", None]:
            self.assertEqual(bridge.safe_media_url(bad), "", bad)

    def test_mpv_quote_keeps_commas_inside_one_value(self):
        self.assertEqual(bridge.mpv_quote("a,b=c"), "%5%a,b=c")
        self.assertEqual(bridge.mpv_quote("é"), "%2%é")

    def test_norm_episode_shape_and_status(self):
        item = bridge.norm_episode({"uuid": EP_1.upper(), "podcastUuid": PODCAST_A, "title": "  Hello\nworld ",
                                    "url": "https://x.test/a.mp3", "duration": "120", "playedUpTo": 30,
                                    "published": "2026-09-30T10:00:00Z"})
        self.assertEqual(item["uuid"], EP_1)
        self.assertEqual(item["name"], "Hello world")
        self.assertEqual(item["status"], bridge.STATUS_IN_PROGRESS)
        self.assertEqual(item["duration"], 120)
        self.assertTrue(item["art"].startswith("https://static.pocketcasts.com/"))
        self.assertIsNone(bridge.norm_episode({"uuid": "nope"}))
        bad_url = bridge.norm_episode({"uuid": EP_1, "url": "file:///etc/shadow"})
        self.assertEqual(bad_url["url"], "")

    def test_start_position(self):
        self.assertEqual(bridge.start_position({"playedUpTo": 50, "duration": 100, "status": 2}), 50)
        self.assertEqual(bridge.start_position({"playedUpTo": 50, "duration": 100, "status": 3}), 0)
        self.assertEqual(bridge.start_position({"playedUpTo": 99, "duration": 100, "status": 2}), 0)
        self.assertEqual(bridge.start_position({"playedUpTo": 50, "duration": 100}, from_start=True), 0)

    def test_speed_is_clamped(self):
        self.assertEqual(bridge.clamp_speed("9"), 3.0)
        self.assertEqual(bridge.clamp_speed("0.1"), 0.5)
        self.assertEqual(bridge.clamp_speed("junk"), 1.0)

    def test_gzip_bomb_is_refused(self):
        bomb = gzip.compress(b"\0" * (bridge.SHOW_MAX_BYTES + 10))
        with self.assertRaises(bridge.ResponseTooLarge):
            bridge.gunzip_bounded(bomb, bridge.SHOW_MAX_BYTES)
        self.assertEqual(bridge.gunzip_bounded(gzip.compress(b"{}"), 100), b"{}")

    def test_show_redirect_to_a_foreign_host_is_refused(self):
        responses = [(302, b"", {"Location": "https://evil.example/x.json"})]
        with mock.patch.object(bridge, "http_raw", side_effect=lambda *a, **k: responses.pop(0)):
            with self.assertRaises(bridge.ApiError) as ctx:
                bridge.fetch_show(PODCAST_A)
        self.assertIn("unexpected", ctx.exception.message)

    def test_show_fetch_never_sends_the_token(self):
        seen = []

        def fake(method, url, headers=None, data=None, timeout=0, limit=0):
            seen.append(headers or {})
            if len(seen) == 1:
                return 302, b"", {"Location": "https://podcasts.pocketcasts.com/x/episodes_full_1.json"}
            return 200, gzip.compress(b'{"podcast": {"title": "T", "episodes": []}}'), {"Content-Encoding": "gzip"}

        with mock.patch.object(bridge, "http_raw", side_effect=fake):
            self.assertEqual(bridge.fetch_show(PODCAST_A)["title"], "T")
        for headers in seen:
            self.assertNotIn("Authorization", headers)

    def test_child_environment_is_closed(self):
        with mock.patch.dict(os.environ, {"LD_PRELOAD": "/tmp/evil.so", "BASH_ENV": "/tmp/x", "HOME": "/home/u",
                                          "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1/bus"}):
            env = bridge.child_env()
        self.assertNotIn("LD_PRELOAD", env)
        self.assertNotIn("BASH_ENV", env)
        self.assertEqual(env["PATH"], bridge.TRUSTED_PATH)
        self.assertIn("DBUS_SESSION_BUS_ADDRESS", env)


class StateFiles(TempHome):
    def test_state_is_private(self):
        bridge.save_auth({"access_token": "a", "refresh_token": "r"})
        path = os.path.join(self.state, "auth.json")
        self.assertEqual(mode_of(path), 0o600)
        self.assertEqual(mode_of(self.state), 0o700)
        self.assertEqual(bridge.load_auth()["refresh_token"], "r")

    def test_symlinked_auth_is_refused(self):
        bridge.save_auth({"access_token": "a"})
        path = os.path.join(self.state, "auth.json")
        os.unlink(path)
        target = os.path.join(self.home, "elsewhere.json")
        with open(target, "w") as fh:
            fh.write("{}")
        os.symlink(target, path)
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()

    def test_auth_open_to_others_is_refused(self):
        bridge.save_auth({"access_token": "a"})
        os.chmod(os.path.join(self.state, "auth.json"), 0o644)
        with self.assertRaises(bridge.UnsafePath):
            bridge.load_auth()

    def test_signed_out_status(self):
        result = run_bridge("status")
        self.assertTrue(result["ok"])
        self.assertFalse(result["data"]["authenticated"])

    def test_login_needs_stdin_not_argv(self):
        result = run_bridge("login", stdin="")
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "bad_args")
        with self.assertRaises(SystemExit):
            with mock.patch.object(sys, "stderr", io.StringIO()):
                bridge.build_parser().parse_args(["login", "--password", "x"])


class TokenRefresh(TempHome):
    def test_401_refreshes_once_then_retries(self):
        bridge.save_auth({"access_token": "old", "refresh_token": "r1", "expires_at": time.time() + 3600})
        calls = []

        def fake_post(path, body, token=""):
            calls.append((path, token))
            if path == "/user/token":
                return 200, {"accessToken": "new", "refreshToken": "r2", "expiresIn": 3600}
            return (401, {}) if token == "old" else (200, {"ok": 1})

        with mock.patch.object(bridge, "post_json", side_effect=fake_post):
            bridge._AUTH = None
            self.assertEqual(bridge.api("/user/in_progress"), {"ok": 1})
        self.assertEqual([c[0] for c in calls], ["/user/in_progress", "/user/token", "/user/in_progress"])
        self.assertEqual(bridge.load_auth()["refresh_token"], "r2")

    def test_rejected_refresh_marks_reauth(self):
        bridge.save_auth({"access_token": "old", "refresh_token": "r1", "expires_at": 0})
        with mock.patch.object(bridge, "post_json", return_value=(401, {})):
            bridge._AUTH = None
            with self.assertRaises(bridge.ApiError) as ctx:
                bridge.api("/user/in_progress")
        self.assertEqual(ctx.exception.code, "reauth")
        self.assertTrue(bridge.load_auth()["needs_reauth"])


# ------------------------------------------------- fake Pocket Casts server

class FakePocketCasts(http.server.BaseHTTPRequestHandler):
    """Just enough of api.pocketcasts.com and the show CDN to drive the
    bridge, with a log of every write the bridge makes."""

    state = None

    def log_message(self, *args):
        pass

    def reply(self, status, payload, gz=False, headers=None):
        body = json.dumps(payload).encode("utf-8") if not isinstance(payload, bytes) else payload
        if gz:
            body = gzip.compress(body)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if gz:
            self.send_header("Content-Encoding", "gzip")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        s = self.state
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/audio/"):
            blob = s["audio"]
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(len(blob)))
            self.end_headers()
            self.wfile.write(blob)
            return
        if path.startswith("/podcast/full/"):
            uuid = path.rsplit("/", 1)[1]
            self.reply(302, b"", headers={"Location": "/cdn/%s.json" % uuid})
            return
        if path.startswith("/cdn/"):
            uuid = path.rsplit("/", 1)[1][:-5]
            show = s["shows"][uuid]
            self.reply(200, {"podcast": {"uuid": uuid, "title": show["title"], "author": "Author",
                                         "episodes": [s["episodes"][e] for e in show["episodes"]]}}, gz=True)
            return
        self.reply(404, {})

    def do_POST(self):
        s = self.state
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        path = urllib.parse.urlsplit(self.path).path
        s["log"].append((path, body))
        token = (self.headers.get("Authorization") or "").replace("Bearer ", "")
        if path == "/user/login_pocket_casts":
            if body.get("password") == PASSWORD:
                self.reply(200, {"email": body["email"], "uuid": "u", "accessToken": "t1", "tokenType": "Bearer",
                                 "expiresIn": 3600, "refreshToken": "r1"})
            else:
                self.reply(401, {"errorMessage": "Wrong password", "errorMessageId": "login_password_incorrect"})
            return
        if path == "/user/token":
            self.reply(200, {"email": "me@example.com", "uuid": "u", "accessToken": "t2", "expiresIn": 3600, "refreshToken": "r2"})
            return
        if token not in ("t1", "t2"):
            self.reply(401, {})
            return
        eps = s["episodes"]
        if path == "/user/podcast/list":
            self.reply(200, {"podcasts": [{"uuid": u, "title": v["title"], "author": "Author",
                                           "lastEpisodePublished": "2026-09-30T00:00:00Z"} for u, v in s["shows"].items()]})
        elif path == "/up_next/list":
            self.reply(200, {"serverModified": 1, "episodes": [
                {"uuid": u, "title": eps[u]["title"], "url": eps[u]["url"], "podcast": eps[u]["podcast"],
                 "published": eps[u]["published"]} for u in s["upnext"]],
                "episodeSync": [{"uuid": u, "playedUpTo": s["progress"].get(u, 0), "duration": eps[u]["duration"]} for u in s["upnext"]]})
        elif path in ("/up_next/play_now", "/up_next/play_next", "/up_next/play_last"):
            uuid = body["episode"]["uuid"]
            if uuid in s["upnext"]:
                s["upnext"].remove(uuid)
            if path == "/up_next/play_last":
                s["upnext"].append(uuid)
            else:
                s["upnext"].insert(0 if path.endswith("now") else 1, uuid)
            self.reply(200, {})
        elif path == "/up_next/remove":
            s["upnext"] = [u for u in s["upnext"] if u not in body["uuids"]]
            self.reply(200, {})
        elif path == "/sync/update_episode":
            s["progress"][body["uuid"]] = body["position"]
            s["status"][body["uuid"]] = body["status"]
            self.reply(200, {})
        elif path == "/user/episode":
            e = dict(eps[body["uuid"]])
            e.update({"podcastUuid": e.pop("podcast"), "playedUpTo": s["progress"].get(body["uuid"], 0),
                      "playingStatus": s["status"].get(body["uuid"], 1)})
            self.reply(200, e)
        elif path in ("/user/in_progress", "/user/new_releases"):
            self.reply(200, {"episodes": [dict(eps[u], podcastUuid=eps[u]["podcast"], playedUpTo=s["progress"].get(u, 0))
                                          for u in eps]})
        elif path == "/user/podcast/episodes":
            self.reply(200, {"episodes": [{"uuid": u, "playedUpTo": s["progress"].get(u, 0),
                                           "playingStatus": s["status"].get(u, 1)} for u in s["shows"][body["uuid"]]["episodes"]]})
        else:
            self.reply(404, {})


def make_audio(seconds):
    out = tempfile.mktemp(suffix=".mp3")
    subprocess.run(["/usr/bin/ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i",
                    "sine=frequency=440:duration=%d" % seconds, "-q:a", "9", out], check=True)
    with open(out, "rb") as fh:
        blob = fh.read()
    os.unlink(out)
    return blob


@unittest.skipUnless(os.path.exists("/usr/bin/mpv") and os.path.exists("/usr/bin/ffmpeg"), "needs mpv and ffmpeg")
class EndToEnd(TempHome):
    """Every subcommand against the fake server, with a real (muted) mpv."""

    @classmethod
    def setUpClass(cls):
        cls.audio = make_audio(4)
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakePocketCasts)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base = "http://127.0.0.1:%d" % cls.server.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def setUp(self):
        super().setUp()
        ep = lambda uuid, podcast, title, day: {"uuid": uuid, "podcast": podcast, "title": title,
                                                "url": self.base + "/audio/%s.mp3" % uuid, "duration": 4,
                                                "published": "2026-09-%02dT08:00:00Z" % day}
        FakePocketCasts.state = {
            "log": [], "audio": self.audio, "progress": {}, "status": {},
            "shows": {PODCAST_A: {"title": "Show A", "episodes": [EP_1, EP_2]},
                      PODCAST_B: {"title": "Show B", "episodes": [EP_3]}},
            "episodes": {EP_1: ep(EP_1, PODCAST_A, "One, with a comma", 28),
                         EP_2: ep(EP_2, PODCAST_A, "Two", 29),
                         EP_3: ep(EP_3, PODCAST_B, "Three", 30)},
            "upnext": [EP_1, EP_2],
        }
        local = ("127.0.0.1",)
        for name, value in (("API", self.base), ("PODCAST_API", self.base),
                            ("_OPENER", bridge.build_opener(allow_plain_http=True)),
                            ("url_host_is", lambda url, hosts: urllib.parse.urlsplit(url).hostname in local),
                            ("podcast_art", lambda uuid: ""),
                            ("MPV_EXTRA_ARGS", ("--ao=null",))):
            patcher = mock.patch.object(bridge, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addCleanup(self.quit_mpv)
        bridge.save_prefs({"volume": 0})

    def quit_mpv(self):
        player = bridge.Mpv.connect()
        if player:
            with player:
                try:
                    player.command("quit")
                except bridge.ApiError:
                    pass

    def mpv_running(self):
        player = bridge.Mpv.connect()
        if player:
            player.close()
        return player is not None

    @property
    def fake(self):
        return FakePocketCasts.state

    def writes(self, path):
        return [body for p, body in self.fake["log"] if p == path]

    def login(self):
        result = run_bridge("login", stdin=json.dumps({"email": "me@example.com", "password": PASSWORD}))
        self.assertTrue(result["ok"], result)

    def wait_for(self, predicate, timeout=8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(0.2)
        self.fail("timed out")

    def test_wrong_password_is_reported_and_nothing_is_stored(self):
        result = run_bridge("login", stdin=json.dumps({"email": "me@example.com", "password": "nope"}))
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "login_failed")
        self.assertIn("Wrong password", result["error"])
        self.assertEqual(bridge.load_auth(), {})

    def test_password_is_never_written(self):
        self.login()
        run_bridge("podcasts")
        for dirpath, _, files in os.walk(self.home):
            for name in files:
                with open(os.path.join(dirpath, name), "rb") as fh:
                    self.assertNotIn(PASSWORD.encode(), fh.read(), name)
        self.assertEqual(bridge.load_auth()["refresh_token"], "r1")

    def test_lists(self):
        self.login()
        podcasts = run_bridge("podcasts")["data"]["items"]
        self.assertEqual({p["name"] for p in podcasts}, {"Show A", "Show B"})
        up_next = run_bridge("up-next")["data"]["items"]
        self.assertEqual([i["uuid"] for i in up_next], [EP_1, EP_2])
        self.assertEqual(up_next[0]["show"], "Show A")
        episodes = run_bridge("episodes", PODCAST_A)["data"]
        self.assertEqual(episodes["podcast"]["name"], "Show A")
        self.assertEqual([i["uuid"] for i in episodes["items"]], [EP_2, EP_1])  # newest first
        newest = run_bridge("new-releases")["data"]["items"]
        self.assertEqual(newest[0]["uuid"], EP_3)

    def test_queue_and_mark(self):
        self.login()
        self.assertTrue(run_bridge("queue", "last", EP_3, "--podcast", PODCAST_B)["ok"])
        self.assertEqual(self.fake["upnext"], [EP_1, EP_2, EP_3])
        self.assertTrue(run_bridge("queue", "remove", EP_1)["ok"])
        self.assertEqual(self.fake["upnext"], [EP_2, EP_3])
        self.assertTrue(run_bridge("mark", "played", EP_2, "--podcast", PODCAST_A)["ok"])
        self.assertEqual(self.fake["status"][EP_2], bridge.STATUS_PLAYED)
        self.assertEqual(self.fake["upnext"], [EP_3])

    def test_play_sync_finish_and_autoplay(self):
        self.login()
        played = run_bridge("play", EP_1, "--podcast", PODCAST_A)
        self.assertTrue(played["ok"], played)
        self.assertEqual(played["data"]["item"]["uuid"], EP_1)
        self.assertEqual(self.writes("/up_next/play_now")[0]["episode"]["uuid"], EP_1)

        view = self.wait_for(lambda: (lambda v: v if v["active"] and v["position"] > 0.5 else None)(run_bridge("player")["data"]))
        self.assertTrue(view["playing"])
        self.assertEqual(view["volume"], 0)

        # Pausing pushes the position to Pocket Casts straight away.
        paused = run_bridge("pause")["data"]
        self.assertFalse(paused["playing"])
        last = self.writes("/sync/update_episode")[-1]
        self.assertEqual((last["uuid"], last["status"]), (EP_1, bridge.STATUS_IN_PROGRESS))
        self.assertGreaterEqual(last["position"], 0)

        # Playing on to the end marks it played, takes it off Up Next and
        # starts the next episode.
        run_bridge("resume")
        view = self.wait_for(lambda: (lambda v: v if v["item"] and v["item"]["uuid"] == EP_2 else None)(run_bridge("player")["data"]))
        self.assertEqual(self.fake["status"][EP_1], bridge.STATUS_PLAYED)
        self.assertNotIn(EP_1, self.fake["upnext"])
        self.assertEqual(self.fake["upnext"][0], EP_2)

        # Skipping with nothing left queued says so.
        skipped = run_bridge("next")
        self.assertFalse(skipped["ok"])
        self.assertEqual(skipped["code"], "nothing_queued")

        stopped = run_bridge("stop")["data"]
        self.assertFalse(stopped["active"])
        self.assertFalse(self.mpv_running())

    def test_toggle_with_no_player_resumes_the_last_episode(self):
        self.login()
        self.fake["progress"][EP_2] = 2
        self.fake["upnext"] = [EP_2]
        view = run_bridge("toggle")["data"]
        self.assertEqual(view["item"]["uuid"], EP_2)
        self.wait_for(lambda: run_bridge("player")["data"]["position"] >= 2)

    def test_speed_and_volume_persist(self):
        self.login()
        self.assertEqual(run_bridge("speed", "cycle")["data"]["speed"], 1.1)
        self.assertEqual(run_bridge("speed", "1.5")["data"]["speed"], 1.5)
        self.assertEqual(run_bridge("speed", "cycle")["data"]["speed"], 1.7)
        self.assertEqual(run_bridge("volume", "40")["data"]["volume"], 40)
        prefs = bridge.load_prefs()
        self.assertEqual((prefs["speed"], prefs["volume"]), (1.7, 40))

    def test_unplayable_audio_is_reported(self):
        self.login()
        self.fake["episodes"][EP_1]["url"] = self.base + "/missing.mp3"
        result = run_bridge("play", EP_1, "--podcast", PODCAST_A)
        self.assertFalse(result["ok"])
        self.assertEqual(result["code"], "playback_failed")

    def test_socket_and_runtime_dir_are_private(self):
        self.login()
        run_bridge("play", EP_1, "--podcast", PODCAST_A)
        runtime = os.path.join(os.environ["XDG_RUNTIME_DIR"], "omarchy-pocketcasts")
        self.assertEqual(mode_of(runtime), 0o700)
        self.assertTrue(stat.S_ISSOCK(os.lstat(os.path.join(runtime, "mpv.sock")).st_mode))

    def test_logout_stops_the_player_and_forgets_tokens(self):
        self.login()
        run_bridge("play", EP_1, "--podcast", PODCAST_A)
        self.assertTrue(run_bridge("logout")["ok"])
        self.wait_for(lambda: not self.mpv_running())
        self.assertEqual(bridge.load_auth(), {})


if __name__ == "__main__":
    unittest.main()
