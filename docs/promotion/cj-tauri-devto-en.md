# Tauri-style desktop apps in Cangjie: system WebView, no bundled Chromium

*English version of the cj-tauri article, written for dev.to / Hashnode. Facts below are checked against
cj-tauri **2.1.0** (2026-10-25) — platform status, plugin count and test numbers are taken from the repo
rather than from the original Chinese draft.*

---

Cangjie is Huawei's statically compiled language. It has no official desktop WebView bindings, so if you
want a GUI you have two options: write the FFI yourself, or don't build a desktop app at all. I took the
first road, and copied Tauri's architecture while doing it — the UI stays HTML/CSS/JS rendered by the
system WebView, the backend is Cangjie, and the two are connected by a JSON IPC channel.

The project is called **cj-tauri**. It runs on Windows (WebView2), Linux (WebKitGTK) and HarmonyOS PC
(ArkWeb) — all three verified on real hardware, not in an emulator.

## Why not just use Electron

Electron's problem isn't ergonomics, it's cost. Every app ships its own Chromium: installers in the
hundreds of megabytes, idle memory to match.

Every desktop already ships a WebView — WebView2 on Windows, WebKitGTK on Linux, ArkWeb on HarmonyOS.
Let those render the UI and the installer drops to a few megabytes. Tauri proved the model works, and it
solved a harder problem along the way: *which backend capabilities the page is allowed to call should not
be decided by the page*. A `capabilities` whitelist makes that an explicit declaration, and the default
is "nothing".

Moving that architecture to Cangjie adds one more reason. Cangjie compiles to a static binary with no
runtime to ship, and it targets the OpenHarmony ecosystem. A "WebView shell + Cangjie backend" that runs
on desktop today and lands on HarmonyOS tomorrow is a better position than a desktop-only framework.

The cost is that almost nothing exists yet: there are no WebView2 or WebKitGTK bindings for Cangjie, so
both had to be written as a C bridge and called over FFI.

## Three parts, and only one of them knows about the platform

**The host.** One window plus one WebView, responsible for rendering the page and delivering messages.
On Windows that's Win32 for the window and WebView2 for rendering, with the message loop on the host
thread; on Linux it's GTK + WebKitGTK, with one extra constraint I'll come back to.

**The IPC bridge.** The frontend sends JSON shaped like `{cmd, args, id}`. A native callback on the host
catches it and passes it to Cangjie over FFI. Cangjie runs the command and injects the result back into
the page by `id`, resolving the matching Promise. The reverse direction uses the same pipe: `ipc.emit()`
on the Cangjie side becomes an event the page's `listen` callback receives. The whole chain is shared —
`ipc_hub`, `capability` and the built-in commands are pure Cangjie with zero platform branches. Platform
differences live only in the host layer and its C bridge.

**The capability model.** Every command and every event has to appear in `capabilities/default.json` to
be allowed. An undeclared command is rejected outright with `command not allowed: xxx` and never reaches
business code.

One `invoke('greet', { name: 'Cangjie' })` round trip looks like this:

```
frontend   window.__CJ_TAURI__.invoke('greet', {...})
  │   JSON {cmd, args, id}
  ▼
host   postMessage / script message  ──FFI──▶  IpcHub
                                                │
                                    capability check (reject on failure)
                                                │
                                     registered CommandHandler.handle()
                                                │
   ExecuteScript injects the result ◀───────────┘
  │
  ▼
frontend   Promise resolves
```

The API surface deliberately mirrors Tauri: `invoke` / `emit` / `listen`, and the same shape of
`capabilities` JSON. If you've written a Tauri app, there's little to relearn.

## Getting started

The CLI ships as an npm package and as a native binary (it's written in Cangjie itself):

```bash
npx cj-tauri create my-app      # scaffold: cj-tauri.toml + src/ + assets/ui + assets/capabilities
cd my-app
npx cj-tauri info               # doctor: does it resolve the framework, project, stdx, SDK, cjpm, C bridge?
npx cj-tauri dev                # build the C bridge → cjpm build → open the window
```

`dev`, `build` and `run` also do one thing you'd otherwise do by hand: they put the C bridge, stdx and the
Cangjie runtime onto the child process's search path (`LD_LIBRARY_PATH` on Linux, `PATH` on Windows).
Missing that step gives you either exit code 127 with no output, or "cannot find libcjtbridge.dll".

A project is described by a single manifest, `cj-tauri.toml`, and the per-target skeletons are derived
from it by `cj-tauri sync`:

```toml
[app]
  name = "my-app"
  id = "com.example.myapp"
  package = "myapp"

[[windows]]
  label = "main"
  title = "my-app"
  width = 1000
  height = 700

[assets]
  page = "ui/index.html"

[capabilities]
  dir = "assets/capabilities"
```

The page itself isn't loaded by the host directly — the Cangjie side reads it and hands it over, so you can
change the frontend without touching backend logic, and a Vite build output drops in the same way
(`cj-tauri dev` even takes over an existing Vite dev server).

## Adding a command takes three edits

The generated `src/main.cj` has two commands in about a hundred lines. Here's what one looks like:

```cangjie
public class GreetCommand <: CommandHandler {
    public init() {}

    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        var name = "world"
        if (let Some(n) <- args.get("name")) {
            match (n.kind()) {
                case JsonKind.JsString => name = n.asString().getValue()
                case _ => ()
            }
        }
        return JsonString("Hello, ${name}! from the Cangjie backend")
    }
}
```

Register it during assembly:

```cangjie
let app = TauriApp()
    .register("greet", GreetCommand())
    .register("timer", TimerCommand())
    .addCapabilityJson(capJson)
```

And that's still not enough — calling it from the page returns `command not allowed: greet` until you add
the name to `assets/capabilities/default.json`:

```json
{
  "identifier": "default",
  "windows": ["main"],
  "commands": ["greet", "timer", "system:version", "system:ping", "system:echo", "system:devtools"],
  "permissions": ["menu:state"],
  "events": ["tick", "menu:click"]
}
```

The double registration looks redundant — why block a command that's registered in the same repo? Because
commands *are* the attack surface exposed to the page, and not everything running in the page is yours: a
remote UI, one XSS, a build artifact swapped by someone else, and arbitrary script can reach this API. The
`commands` whitelist lives in backend code that the page cannot modify. Default-deny means the worst case
of forgetting a declaration is a feature that doesn't work — not a capability quietly exposing itself.

## It isn't only about which commands

Allowing a command is not the same as allowing its arguments. The capability file can scope a plugin's
page-controlled paths:

```json
"scopes": { "fs": { "allow": ["$HOME/notes/**"], "deny": ["**/id_rsa"] } }
```

Deny wins over allow, allow has to match explicitly, and paths are canonicalized (symlinks resolved) before
matching. Out-of-scope access is refused with a business-level error rather than a silent success. The
`http` plugin has the equivalent gate for outbound hosts, and `shell` passes argv arrays to the OS instead
of splicing a string into a shell — the page never gets to build a command line.

There's also a runtime escape hatch for endpoints that can't be known at build time. It's deliberately
awkward: the app is expected to confirm with the user *in a native dialog*, because the page can't draw
one and therefore injected script can't approve its own host. The registry accepts only concrete values —
a wildcard arriving through that path is rejected on the spot.

## Two platform constraints you only find on real hardware

The two hosts are written separately, and each one blocked the project once with a symptom that pointed
somewhere else entirely.

**Windows: a blank page and `0x8007139F`.** The window appeared, the page stayed white, the navigation
completed event never fired, and `ExecuteScript` consistently returned `0x8007139F`
(E_ILLEGAL_METHOD_CALL). That code reads like "you called this at the wrong time", so the obvious suspects
were the thread model and COM initialization. Neither was it.

The real cause was object lifetime. WebView2 hands the environment and controller to you inside an async
callback; storing the pointers without taking a reference meant the refcount hit zero when the callback
returned, WebView2 tore down the browser process, and every later call returned that misleading HRESULT.
The fix is unglamorous: `AddRef` both objects in the callback and hold them until exit — `hr=0x0`
afterwards. A smaller ordering bug lived alongside it: `ShowWindow` before `put_Bounds`, otherwise the
first frame has zero size and the page is blank anyway.

**Linux: an immediate abort.** GTK and WebKit calls have to happen on "the main thread", but that main
thread is not Cangjie's main thread. Cangjie's `main` runs on a heap-allocated coroutine stack in its M:N
lightweight-thread runtime, and WebKit's JavaScriptCore validates the stack pointer against pthread stack
bounds at the call boundary. The two disagree, and the process dies. So the bridge moves every GTK/WebKit
call into a pthread it creates itself; Cangjie only calls in over FFI and gets results back through
`CFunc` callbacks. The thread juggling in `bridge_linux.c` isn't over-engineering — it's the only shape
that works.

The hard part of a cross-platform framework usually isn't "write it twice". It's the concepts that aren't
the same concept on both sides: main thread, ownership, teardown order.

## Where it stands (2.1.0)

- **Platforms**: Windows (WebView2), Linux (WebKitGTK) and HarmonyOS PC (ArkWeb) verified end-to-end on
  real machines — window creation, bidirectional IPC, capability enforcement.
- **Plugins**: 14 official ones — fs, http, sqlite, serial, shell, menu, dialog, clipboard, notification,
  store, log, ws, mqtt, redis. Each is its own Cangjie subpackage, so an app that uses one plugin doesn't
  link the others' dependencies.
- **Examples**: 30 example projects in the repo, spanning desktop and HarmonyOS, most with unattended
  self-checks that assert on the bridge's own log lines.
- **Tests**: 349 unit tests, plus 11 end-to-end entries that drive a probe app and archive evidence.
- **Size**: desktop binaries land between 4.7 and 10.3 MB depending on plugins — no Chromium.
- **Multi-window and embedded views**: several windows with per-label routing, owner windows that don't
  take a taskbar slot, and multiple WebViews inside one window (how the bundled chat app renders eight
  web versions of AI chat sites as tabs).

## What's honestly missing

- **No macOS.** The host layer doesn't exist; nothing is claimed there.
- **HarmonyOS host capabilities are mostly unimplemented.** The menu works on device (verified), tray,
  global hotkeys, drag-and-drop and notifications report zero, and the framework says so at runtime instead
  of pretending.
- **Most documentation is Chinese.** The English README covers the introduction and quick start; deep docs
  (`docs/使用文档.md`, the ADRs, the platform matrix) are still Chinese-only.
- **The ecosystem is young.** You won't find a plugin marketplace; 14 official plugins is the whole
  catalogue today.

## Trying it

```bash
npx cj-tauri create my-app && cd my-app && npx cj-tauri dev
```

You'll need the Cangjie SDK 1.2.0+ and stdx; `npx cj-tauri doctor` tells you what's missing and where to
get it. The project is MIT licensed.

- GitHub: <https://github.com/yangyongzhen/cj-tauri>
- AtomGit (primary): <https://atomgit.com/qq8864/cj-tauri>
- npm: <https://www.npmjs.com/package/cj-tauri>
- Website: <https://yangyongzhen.github.io/cj-tauri/>

If you're building on Cangjie and hit a WebView problem on any of the three platforms, the issue tracker is
the right place — real-hardware reports are exactly what this project is short of.


