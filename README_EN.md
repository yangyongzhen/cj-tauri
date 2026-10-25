<div align="center">

# cj-tauri · Tauri, in Cangjie

**A hybrid desktop-app framework in Huawei's Cangjie language — statically compiled Cangjie backend + system WebView front end.**
Keep writing the front end as the Web; the back end is a statically compiled Cangjie binary —
no bundled Chromium, 4.7–10.3 MB artifacts, verified on real hardware across Windows, Linux and
HarmonyOS PC (2in1).

Bidirectional IPC bridge · capability whitelist (commands / events / paths / egress — four gates) ·
14 official plugins · twenty-odd runnable examples · every example ships an unattended self-check

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20HarmonyOS%20PC-blue)](#examples)
[![Cangjie](https://img.shields.io/badge/SDK-1.2.0%2B-ff69b4)](https://cangjie-lang.cn)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

📖 Website <https://yangyongzhen.github.io/cj-tauri/> (bilingual · 24 on-device screenshots)&nbsp;·&nbsp; 💬 QQ group **92381027**

[Get started](#30-seconds-to-a-first-app) · [Why cj-tauri](#why-cj-tauri) · [Examples](#examples) ·
[Architecture](#architecture) · [Docs](#documentation)

</div>

## 30 seconds to a first app

**A. Just want to see it run? Download and double-click — no SDK, no runtime, no install.**

| Artifact | Size | What it is |
|---|---|---|
| [ai-chat.exe](examples/ai-chat/dist-single/ai-chat.exe) | 10.3 MB | AI chat client: multi-provider streaming Markdown chat + a local-Agent mode, one click to switch |
| [cj-link.exe](examples/cj-link/dist-single/cj-link.exe) | 5.63 MB | Serial + TCP/UDP combined debug assistant |
| [modbus-poll.exe](examples/modbus-poll/dist-single/modbus-poll.exe) | 5.69 MB | Modbus TCP/RTU debugging tool |

All ten single-file artifacts were measured on real machines (4.69–32.8 MB; PE import tables carry
only system DLLs, `Subsystem=GUI` so double-click opens no console; see
[the distribution measurements](docs/分发形态实测.md)) →
[full download table](#option-2-download-single-file-tools-no-install-no-sdk)

**B. Want your own app? Three commands.**

Prerequisites: the [Cangjie SDK](docs/使用文档.md#2-环境准备) 1.0.5+ and stdx (Windows additionally
needs mingw gcc and the WebView2 Runtime, bundled with Win11; Linux needs `libwebkit2gtk-4.1-dev`).
Not sure what is missing? Run `doctor` first:

```bash
npx cj-tauri doctor              # names what is missing and how to fix it — first thing on a new machine
npx cj-tauri create myapp        # no install needed
cd myapp && npx cj-tauri dev     # takes over the Vite dev server (Vue/React templates), HMR in-window
```

**C. Prefer no npm at all?** Build from source (Windows): `git clone … && native\build_win.bat && cli\cj-tauri.bat create myapp`
— details in [Option 3: build from source](#option-3-build-from-source). For a HarmonyOS PC project use
`create --template ohos`; the same business code is derived into a hap project by `cj-tauri sync ohos`.

![cj-tauri hello example](docs/images/cj_tauri.png)

*The hello example: dark card UI, invoke on button click, live events pushed from the Cangjie backend.*

## Screenshots

An **AI chat client** built with cj-tauri (`examples/ai-chat`; chat mode talks to providers directly,
Agent mode talks to a local cjh backend):

![ai-chat mode switch](docs/images/ai-chat-mode-switch.gif)

*Chat (direct to provider) → Agent (local cjh) with one click: the sidebar rebrands, four panels appear, the badge shows cjh's real model.*

![ai-chat missing-cjh guide](docs/images/ai-chat-guide.gif)

*When cjh is missing, switching to Agent shows a guide card: the download artifact for this platform, and picking the executable once starts it and remembers the path.*

A **Modbus debugging tool** built with cj-tauri (`examples/modbus-poll`, inspired by Modbus Poll,
without its long-standing pain points):

![Modbus Poll (cj-tauri)](examples/modbus-poll/images/modbus-poll-main.png)

*Multiple monitor panels plus a message-trace dock streaming Tx/Rx frames in hex.
See [its README](examples/modbus-poll/README.md) for details.*

More screenshots in the [examples](#examples) section.

## Why cj-tauri

- **Statically compiled backend** — no VM, no GC-jitter concerns; the protocol layer is a few
  hundred auditable lines of Cangjie.
- **No bundled Chromium** — uses the system WebView (WebKitGTK on Linux, WebView2 on Windows);
  single-example binaries are 4–10 MB.
- **Capability security model** — `capabilities/` whitelists with default-deny; unlisted commands
  are rejected. Independent of the host implementation.
- **Plugin system** — official `fs` / `dialog` / `shell` / `serial` / `menu` plugins, one line to
  plug in; permissions still come from the manifest.
- **Verifiable end to end** — instant evidence on the bridge's stderr, page-side self-checks that
  assert and report back; every example runs an unattended self-check.
- **Batteries-included scaffolding** — `cj-tauri create/dev/build/run/info`; capability manifests,
  the Windows GUI subsystem and cross-platform link flags are handled for you.

## Getting started

### Option 1: npm (recommended)

```bash
npx cj-tauri create myapp          # no install needed
cd myapp
npx cj-tauri dev                   # takes over the Vite dev server (Vue/React templates), HMR in-window
```

Prerequisites: see [30 seconds to a first app](#30-seconds-to-a-first-app). If the SDK is missing,
the CLI prints setup instructions and a `CANGJIE_HOME` example instead of `command not found`.

### Option 2: download a ready-made tool (no SDK, no install)

Statically-linked single-file Windows tools ship with the repo:

| Tool | What it is |
|---|---|
| [modbus-poll.exe](examples/modbus-poll/dist-single/modbus-poll.exe) (5.6 MB) | Modbus TCP/RTU debugging tool — [docs](examples/modbus-poll/README.md) (Chinese) |
| [movie.exe](examples/movie/dist-single/movie.exe) (9.5 MB) | Movie-browsing demo (third-party public APIs, [for study/research only](examples/movie/README.md#用途与免责声明)) |

### Option 3: build from source

```bash
git clone https://github.com/yangyongzhen/cj-tauri.git && cd cj-tauri
native/build_win.bat               # Windows: build the C bridge (native/build_linux.sh on Linux)

cli\cj-tauri.bat info              # self-check: framework/project/stdx/SDK/cjpm/bridge all resolved?
cli\cj-tauri.bat create myapp && cd myapp
..\cli\cj-tauri.bat dev            # use cli/cj-tauri.sh on Linux/macOS/Git Bash
```

To run a repo example (hello): `native\build_win.bat` → `cd examples\hello && cjpm build` → `run_win.bat` from the repo root.

## Examples

Twelve runnable examples live in `examples/`, plus three scaffolding templates in `cli/templates/`
(`app`, `app-vue`, `app-react`). Each example's directory has its own README with full details
and self-check instructions. Most docs are in Chinese; the code and logs are the universal language.

**End-user tools & apps**:

| Example | In one line |
|---|---|
| [modbus-poll](examples/modbus-poll) | **Modbus TCP/RTU debugging tool**: multi-panel monitors (as many groups as you want on one screen), FC 01-04/05/06/15/16, message trace, CSV logging, byte-order option, built-in slave simulator for closed-loop self-checks |
| [serial-assistant](examples/serial-assistant) | **Serial terminal**: parameter panel, color-coded TX/RX log, scheduled send, probe self-check |
| [movie](examples/movie) | Movie browsing (list/search/detail/play) — all data fetched by the Cangjie side, zero `fetch` in the front-end |
| [music](examples/music) | Music player: charts/playlists/favorites/sharing + synced lyrics + 4 themes |
| [typing-poem](examples/typing-poem) | Chinese-poem typing practice for kids: 108 poems with per-character pinyin, three.js 3D cards |

**Framework capability demos**:

| Example | Demonstrates |
|---|---|
| [hello](examples/hello) | Minimal loop: invoke + event push + permission denial |
| [todo_check](examples/todo_check) / [vue_todo](examples/vue_todo) | Todo app — zero-Node version vs Vue 3 + Vite version, same commands |
| [plugin-fs](examples/plugin-fs) / [plugin-dialog](examples/plugin-dialog) / [plugin-shell](examples/plugin-shell) / [plugin-serial](examples/plugin-serial) | Official plugins: file I/O / native dialogs / open-URL & subprocess / serial, each with permission contrasts |
| [menu](examples/menu) | Native menu bar (real click evidence on Windows + Linux) |
| [ipc-bench](examples/ipc-bench) | IPC benchmark: round-trip latency / throughput / payload scaling / event cost |

**Ecosystem projects** (separate repos built on cj-tauri, not part of `examples/`):

| Project | In one line |
|---|---|
| [cjnote](https://atomgit.com/qq8864/cjnote) | **AI-native Markdown notes**: three panes (note library / editor / AI assistant) + three view states (`Ctrl+1/2/3`); **native menu bar plus a subtitle** — File / View / Help, with title · saved-state · word count pushed into the system menu row (falls back to the in-page bar when the capability is missing); an Outline tab that jumps to 1–3 level headings; AI context from the whole note or from `note:search` hits, with rewrite / continue / translate going through a **diff confirm** strip; `Ctrl+O` opens an external `.md` as an in-memory draft (saved into the library only on the first `Ctrl+S`, never rewriting the original), `Ctrl+P` quick-opens library notes; every network call is made by the Cangjie side (zero `fetch` in the page) with a host whitelist behind it; page self-check **31/31 on Linux hardware** |

| movie app | music player, playing |
|---|---|
| ![movie app](docs/images/example-movie.png) | ![music playing](docs/images/example-music-playing.png) |

## Architecture

**One business codebase, several platform artifacts** — business code lives in `src/`, pages in `assets/`, and `cj-tauri sync` derives the skeletons into `targets/desktop` and `targets/ohos`; the business package is wired in as a path dependency, never copied:

![cj-tauri multi-platform architecture: business code → cj-tauri.toml manifest → CLI → targets/desktop and targets/ohos → WebKitGTK / WebView2 / ArkWeb](docs/images/architecture-multiplatform.png)

**Layered call chain** — responsibilities and cross-platform boundaries from the page down to the host:

![cj-tauri layered architecture: bridge JS → IPC hub → capability model → built-in / plugin commands → WebView host → shared C layer](docs/images/architecture.png)

The same layering in text form (searchable / copyable):

```
Front-end (HTML/CSS/JS) ← window.__CJ_TAURI__.invoke/listen/emit (injected bridge JS, like @tauri-apps/api)
        │  JSON over postMessage (Linux: WebKitUserContentManager; Windows: chrome.webview.postMessage)
        ▼
IPC hub (src/ipc_hub.cj) ← command registry / dispatch / validation (like tauri IPC; commands run async on workers)
        ▼
Capability model (src/capability.cj) ← command/event whitelist, default-deny (like Tauri capabilities)
        ▼
Built-in commands (src/api_system.cj): system:version / ping / echo / devtools
        ▼
WebView host (src/host.cj trait + per-platform impls)
   ├─ Linux: webkit2gtk-4.1 (src/host_webkit.cj + native/platforms/linux/bridge_linux.c, C bridge runs GTK on a native pthread)
   ├─ Windows: WebView2 (src/host_webview2.cj + native/platforms/windows/bridge_win.c, Win32 message loop on the host thread)
   └─ HarmonyOS: ArkWeb (ArkUI `Web` + `javaScriptProxy` on the app side, bridged through `arkweb_proxy.cj`; 2in1 / HarmonyOS PC)
```

Writing an app takes three steps (mirroring tauri command / Builder / capabilities):

```cangjie
// 1. implement a command
public class GreetCommand <: CommandHandler {
    public func handle(cmd: String, args: JsonObject, ipc: IpcContext): JsonValue {
        return JsonString("Hello, ${argString(args, "name", "world")}!")
    }
}

main(): Int64 {
    // 2. assemble: window + register; 3. run (capabilities/ is auto-scanned by run())
    let app = TauriApp()
        .window(WindowConfig("hello", 1000, 700))
        .register("greet", GreetCommand())
    app.run(html)
    return 0
}
```

```js
// Front-end: the bridge is injected before page scripts run. Safer to wait for it first
// (the templates' waitForBridge is the reference pattern), especially with bundled/inlined modules.
window.__CJ_TAURI__.invoke('greet', { name: 'world' }).then(d => console.log(d));
window.__CJ_TAURI__.listen('tick', p => console.log(p));
```

## Documentation

| Doc | Contents |
|---|---|
| [使用文档](docs/使用文档.md) | Setup → create → develop → troubleshoot (the canonical guide, Chinese) |
| [前端入门教程](docs/前端入门教程.md) | Front-end from zero: layout → bridge API → events → capabilities → full walkthrough |
| [插件体系教程](docs/插件体系教程.md) | Plugin system: what it is → plug in an official plugin → write your own |
| [IPC 通信机制](docs/IPC-通信机制.md) | Protocol frames → full sequence → measured performance vs WebSocket / raw TCP |
| [Modbus tool deep-dive](docs/仓颉版Modbus调试工具-介绍与实战.md) | Scaffolding walkthrough + how the Modbus tool is built + comparison with Modbus Poll |
| [Source layout](docs/源码结构.md) | Read before changing the framework: `src/` layers and file ownership, dependency direction, when to split and when not to (Chinese) |
| [CHANGELOG](CHANGELOG.md) / [AGENTS.md](AGENTS.md) / [CONTRIBUTING](CONTRIBUTING.md) / [README.OpenSource](README.OpenSource) | Release notes / dev conventions / contributing / licenses |

## AI-assisted development (AtomCode skills)

The project's workflows, on-device evidence collection and pitfall playbook are packaged as
**AtomCode skills** (available in the plugin marketplace):

```bash
atomcode plugin marketplace add https://atomgit.com/qq8864/cj-tauri.git
atomcode plugin install cj-tauri-skills@cj-tauri-skills
```

Five skills: `cj-tauri-env` (environment detection + toolchain install guidance), `cj-tauri-app-dev`
(scaffolding / command wiring / delivery gates), `cj-tauri-verify` (build → run → stderr evidence →
asserted screenshots), `cj-tauri-troubleshoot` (field-tested pitfall quick reference),
`cj-tauri-contribute` (issue → fix → PR). See [skills/README.md](skills/README.md).

## Status & roadmap

- ✅ Linux (WebKitGTK) + Windows (WebView2) hosts; IPC and capability model fully shared
- ✅ Native Cangjie scaffolding CLI: `create / dev / build / run / info`, distributed via npm
- ✅ Plugin system v1 + five official plugins (fs / dialog / shell / serial / menu), evidence on both platforms
- ✅ Async command dispatch (slow commands never freeze the window), multi-window routing by label,
  machine-readable plugin manifest via `info --json`
- ✅ Engineering: 144 unit tests + SDK-free static gates (what CI runs) + unattended example self-checks
- 🔜 Remaining HarmonyOS host capability bits (menu already device-verified; tray / hotkeys / drag-and-drop / notification honestly report 0 — dialogs use an app-side overlay and occupy no bit), macOS WebView, more official plugins

## Repos

The same code is hosted twice; `origin` carries both push URLs, so **one `git push` updates both**:

```bash
git clone https://github.com/yangyongzhen/cj-tauri.git     # GitHub
git clone https://atomgit.com/qq8864/cj-tauri.git          # AtomGit
git ls-remote origin main && git ls-remote github main     # verify both SHAs match
```

## License

[MIT](LICENSE) © 2026 yangyongzhen
