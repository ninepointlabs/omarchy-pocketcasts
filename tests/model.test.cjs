// Node test runner (`node --test tests/model.test.cjs`) for Model.js: the
// formatting and row helpers the panel renders, the trusted executable and
// closed environment layer, and a static check that the QML never starts a
// program any other way or leaks the password.
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const ROOT = path.join(__dirname, "..")

// Model.js is a QML `.pragma library` script rather than a CommonJS module:
// drop the pragma and evaluate it in a fresh context whose globals are its API.
function loadModel() {
  const source = fs.readFileSync(path.join(ROOT, "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
  const context = vm.createContext({})
  vm.runInContext(source, context, { filename: "Model.js" })
  return context
}

const Model = loadModel()
// Values from the vm context carry that realm's prototypes; compare as JSON.
const plain = (value) => JSON.parse(JSON.stringify(value))

const episode = (extra) => Object.assign({
  type: "episode", uuid: "e1", podcast: "p1", show: "Show", name: "Ep", published: "2026-09-28T08:00:00Z",
  duration: 3600, playedUpTo: 0, status: 1
}, extra)

test("time formatting", () => {
  assert.equal(Model.fmtTime(0), "0:00")
  assert.equal(Model.fmtTime(65.9), "1:05")
  assert.equal(Model.fmtTime(3723), "1:02:03")
  assert.equal(Model.fmtDuration(42 * 60), "42 min")
  assert.equal(Model.fmtDuration(65 * 60), "1 h 05 min")
  assert.equal(Model.fmtDuration(0), "")
  assert.equal(Model.fmtSpeed(1), "1.0×")
  assert.equal(Model.fmtSpeed(1.25), "1.3×")
})

test("dates read relative to today", () => {
  const now = new Date(2026, 9, 1, 12, 0, 0)
  assert.equal(Model.fmtDate("2026-10-01T09:00:00Z", now), "Today")
  assert.equal(Model.fmtDate("2026-09-30T09:00:00Z", now), "Yesterday")
  assert.equal(Model.fmtDate("2026-03-08T09:00:00Z", now), "Mar 8")
  assert.equal(Model.fmtDate("2024-03-08T09:00:00Z", now), "Mar 8, 2024")
  assert.equal(Model.fmtDate("garbage", now), "")
})

test("row subtitles reflect listening state", () => {
  assert.match(Model.subtitle(episode()), /^Show {2}· {2}.+ {2}· {2}1 h$/)
  assert.match(Model.subtitle(episode({ status: 2, playedUpTo: 1800 })), /30 min left$/)
  assert.match(Model.subtitle(episode({ status: 3 })), /Played$/)
  assert.ok(!Model.subtitle(episode(), true).startsWith("Show"))
  assert.equal(Model.progressFraction(episode({ playedUpTo: 900 })), 0.25)
  assert.equal(Model.progressFraction(episode({ status: 3 })), 1)
})

test("up next leaves out the playing episode", () => {
  const items = [episode({ uuid: "a" }), episode({ uuid: "b" })]
  const rows = plain(Model.upNextRows(items, "a", false, ""))
  assert.deepEqual(rows.map((r) => r.item.uuid), ["b"])
  const onlyNow = plain(Model.upNextRows([episode({ uuid: "a" })], "a", false, ""))
  assert.equal(onlyNow[0].kind, "note")
  assert.equal(plain(Model.upNextRows([], "", false, ""))[0].kind, "note")
  assert.equal(plain(Model.upNextRows([], "", true, ""))[0].text, "Loading…")
})

test("the cursor only lands on items", () => {
  const rows = [{ kind: "note" }, { kind: "item" }, { kind: "header" }, { kind: "item" }]
  assert.equal(Model.firstItemIndex(rows, 0, 1), 1)
  assert.equal(Model.firstItemIndex(rows, 3, -1), 3)
  assert.equal(Model.firstItemIndex([], 0, 1), -1)
  assert.ok(Model.containsUuid([{ uuid: "x" }], "x"))
})

test("trustedExecutable accepts only clean paths inside trusted directories", () => {
  assert.equal(Model.trustedExecutable("/usr/bin/python3"), "/usr/bin/python3")
  for (const bad of ["python3", "./python3", "/usr/local/bin/python3", "/home/tim/.local/bin/python3",
    "/usr/bin/../../tmp/python3", "/usr/bin/.python3", "/usr/bin/py thon", "/usr/bin/", "/usr/bin/sub/python3",
    "/usr/bin/python3\n", "", null, undefined, 42, ["/usr/bin/python3"]]) {
    assert.equal(Model.trustedExecutable(bad), "", String(bad))
  }
})

test("the bridge runs under an isolated absolute interpreter or not at all", () => {
  assert.deepEqual(plain(Model.bridgeCommand("/usr/bin/python3", "/p/bin/pocketcasts-bridge", ["play", "a b; $(id)"])),
    ["/usr/bin/python3", "-I", "-B", "/p/bin/pocketcasts-bridge", "play", "a b; $(id)"])
  assert.deepEqual(plain(Model.bridgeCommand("python3", "/p/bin/pocketcasts-bridge", ["status"])), [])
  assert.deepEqual(plain(Model.bridgeCommand("/home/x/bin/python3", "/p/bin/pocketcasts-bridge", ["status"])), [])
  assert.deepEqual(plain(Model.bridgeCommand("/usr/bin/python3", "bin/pocketcasts-bridge", ["status"])), [])
  for (const candidate of Model.pythonCandidates) {
    const command = plain(Model.pythonProbeCommand(candidate))
    assert.equal(command[0], candidate)
    assert.equal(command[1], "-I")
  }
})

test("closedEnvironment keeps only listed single-line values and pins PATH", () => {
  const env = plain(Model.closedEnvironment({
    HOME: "/home/x",
    PATH: "/tmp/evil:/usr/bin",
    LD_PRELOAD: "/tmp/evil.so",
    DBUS_SESSION_BUS_ADDRESS: "unix:path=/run/user/1/bus\nBASH_ENV=/tmp/x",
    USER: ""
  }, ["HOME", "PATH", "DBUS_SESSION_BUS_ADDRESS", "USER"], Model.trustedPathEnvironment))
  assert.deepEqual(env, { HOME: "/home/x", PATH: Model.trustedPathEnvironment })
})

test("no environment allow-list carries a code-loading or command variable", () => {
  const forbidden = ["PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "BASH_ENV", "ENV", "PYTHONPATH", "PYTHONHOME",
    "QT_PLUGIN_PATH", "TERMINAL", "EDITOR", "BROWSER", "http_proxy", "https_proxy", "SSL_CERT_FILE", "SHELL"]
  for (const name of plain(Model.bridgeEnvironmentNames)) {
    assert.ok(!forbidden.includes(name), name)
    assert.ok(!/^BASH_FUNC_|^LD_|^PYTHON/.test(name), name)
  }
  for (const dir of Model.trustedPathEnvironment.split(":")) {
    assert.ok(!dir.startsWith("/home") && !dir.startsWith("/usr/local") && dir.startsWith("/"), dir)
  }
})

test("the QML starts programs only through closed-environment Process objects", () => {
  const service = fs.readFileSync(path.join(ROOT, "Service.qml"), "utf8")
  const qml = ["Service.qml", "Panel.qml", "BarWidget.qml"].map((file) => fs.readFileSync(path.join(ROOT, file), "utf8")).join("\n")
  for (const pattern of [/\bbash\b/, /-lc\b/, /execDetached/, /\.run\(/, /command:\s*\[\s*bridge\b/, /startDetached/]) {
    assert.ok(!pattern.test(qml), String(pattern))
  }
  const processes = (service.match(/\bProcess\s*\{/g) || []).length
  const closed = (service.match(/clearEnvironment:\s*true/g) || []).length
  assert.ok(processes >= 2)
  assert.equal(closed, processes)
})

test("the password travels on stdin, never in argv, and is cleared after use", () => {
  const service = fs.readFileSync(path.join(ROOT, "Service.qml"), "utf8")
  const panel = fs.readFileSync(path.join(ROOT, "Panel.qml"), "utf8")
  assert.match(service, /call\(\["login"\], function/)
  assert.ok(!/"login",\s*[^\]]/.test(service), "login takes no arguments")
  assert.match(service, /write\(secret\)\s*\n\s*secret = ""\s*\n\s*stdinEnabled = false/)
  assert.match(panel, /password:\s*true/)
  assert.match(panel, /passwordField\.text = ""/)
})
