<div align="center">

# cj-tauri · Tauri, in Cangjie

**English** · [**简体中文**](./README.zh-CN.md)

**A hybrid desktop-app framework in the Cangjie language — statically compiled Cangjie backend + system WebView front end.**
Keep writing the front end as the Web; the back end is a statically compiled Cangjie binary —
no bundled Chromium, 4.7–32.8 MB artifacts, verified on real hardware across Windows, Linux and
HarmonyOS PC (2in1).

Write the page in Web, the logic in Cangjie: one IPC bridge joins the two, with four whitelist
gates (commands / events / paths / egress) holding the security line — plus 14 official plugins
and twenty-odd runnable examples, each with an unattended self-check.

<p>
  <a href="https://atomgit.com/qq8864/cj-tauri"><img alt="AtomGit Stars" src="https://atomgit.com/qq8864/cj-tauri/star/new_badge.svg"></a>
  <a href="https://yangyongzhen.github.io/cj-tauri/"><img alt="Website" src="https://img.shields.io/badge/website-24_on-device_screenshots-blue"></a>
  <img alt="QQ group" src="https://img.shields.io/badge/QQ_group-92381027-eb1923">
</p>

[![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Linux%20%7C%20HarmonyOS%20PC-blue)](#examples)
[![Cangjie](https://img.shields.io/badge/SDK-1.2.0%2B-ff69b4)](https://cangjie-lang.cn)
[![License](https://img.shields.io/badge/license-MIT-green)](./LICENSE)

[Get started](#getting-started) · [Why cj-tauri](#why-cj-tauri) · [Security](#security-model-claims-you-can-check) ·
[Examples](#examples) · [Architecture](#architecture) · [Docs](#documentation)

</div>

## Getting started

Three paths, pick by need: **just want to see it run** → Option 1; **write your own app** → Option 2;
**no npm / want to hack the framework** → Option 3.

### Option 1: download a ready-made tool (no SDK, no install)

Statically-linked single-file Windows tools ship with the repo — ten artifacts, all measured:

| Tool | What it is |
|---|---|
| [ai-chat.exe](examples/ai-chat/dist-single/ai-chat.exe) (25.3 MB) | AI chat client: multi-provider streaming Markdown chat + a local-Agent mode, one click to switch; **nine model web versions embedded in the same window** (DeepSeek / Kimi / Qwen / Zhipu / Ernie / Doubao / Yuanbao / MiniMax / ChatGPT — tab strip, logins remembered) |
| [cj-link.exe](examples/cj-link/dist-single/cj-link.exe) (5.6 MB) | Serial + TCP/UDP combined debug assistant ([docs](examples/cj-link/README.md), Chinese) |
| [modbus-poll.exe](examples/modbus-poll/dist-single/modbus-poll.exe) (5.7 MB) | Modbus TCP/RTU debugging tool ([docs](examples/modbus-poll/README.md), Chinese) |
| [serial-waveform.exe](examples/serial-waveform/dist-single/serial-waveform.exe) (4.7 MB) | Real-time serial waveform scope ([docs](examples/serial-waveform/README.md), Chinese) |
| [markdown-notes.exe](examples/markdown-notes/dist-single/markdown-notes.exe) (5.0 MB) | Markdown notes: tree / editor / live preview ([docs](examples/markdown-notes/README.md), Chinese) |
| [leetcode-gui.exe](examples/leetcode-gui/dist-single/leetcode-gui.exe) (9.9 MB) | Desktop LeetCode-style practice: the judge is `cjc` itself ([docs](examples/leetcode-gui/README.md), Chinese) |
| [music.exe](examples/music/dist-single/music.exe) (9.7 MB) | Music player: charts / playlists / favorites + synced lyrics + 4 themes |
| [movie.exe](examples/movie/dist-single/movie.exe) (9.6 MB) | Movie browsing (third-party public APIs, [for study/research only](examples/movie/README.md#用途与免责声明)) |
| [typing-poem.exe](examples/typing-poem/dist-single/typing-poem.exe) (5.7 MB) | Chinese-poem typing practice for kids: three.js 3D cards |
| [cjnote.exe](examples/cjnote/dist-single/cjnote.exe) (32.8 MB) | AI-native Markdown notes: three panes + native menu bar + **embedded cjh AI backend** (works right after install); big because the whole backend ships inside the exe |

Size and dependencies are **measured**, not claimed: ten artifacts at 4.7–32.8 MB, all single-file,
no bundled third-party runtimes, double-click to run. How they were verified:
[`docs/分发形态实测.md`](docs/分发形态实测.md), re-check with `bash scripts/dist-report.sh`.

### Option 2: npm, write your own app (recommended)

```bash
npx cj-tauri doctor              # names what is missing and how to fix it — first thing on a new machine
npx cj-tauri create myapp        # no install needed
cd myapp && npx cj-tauri dev     # takes over the Vite dev server (Vue/React templates), HMR in-window
```

Prerequisites: the [Cangjie SDK](docs/使用文档.md#2-环境准备) 1.0.5+ and stdx (Windows additionally
needs mingw gcc and the WebView2 Runtime, bundled with Win11; Linux needs `libwebkit2gtk-4.1-dev`).
If the SDK is missing, the CLI prints setup instructions and a `CANGJIE_HOME` example instead of
`command not found`. The same directory also has `cj-tauri build/run/info/doctor`.

HarmonyOS PC (2in1) shares the same business code as the desktop: `create --template ohos` still
generates a **unified project** (`cj-tauri.toml` manifest + business static package + `assets/`),
the hap skeleton is derived by `sync` into `targets/ohos/`, and the build entry is the
`build-hap.sh` inside it (**not in the project root**):

```bash
npx cj-tauri create myohosapp --template ohos --bundle com.example.myohosapp --label "My App"
cd myohosapp
npx cj-tauri sync ohos             # derive targets/ohos (desktop: sync desktop)
export CANGJIE_STDX_OHOS=<HarmonyOS stdx>/linux_ohos_aarch64_cjnative/dynamic/stdx
cd targets/ohos && npx cj-tauri run
# equivalent: bash build-hap.sh --install (build hap → install to device → launch)
```

### Option 3: build from source

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git && cd cj-tauri
native/build_win.bat               # Windows: build the C bridge (native/build_linux.sh on Linux)

cli\cj-tauri.bat info              # self-check: framework/project/stdx/SDK/cjpm/bridge all resolved?
cli\cj-tauri.bat create myapp && cd myapp
..\cli\cj-tauri.bat dev            # use cli/cj-tauri.sh on Linux/macOS/Git Bash
```

> The repo's `cjpm.toml` references stdx via `${CANGJIE_STDX}` (machine-independent): set it to
> `<stdx>/<triple>/dynamic/stdx` before building (e.g. `$HOME/.cangjie/stdx/*/dynamic/stdx` on
> Linux). Projects generated by `cj-tauri create` don't need it — the scaffold writes the
> detected path into the generated `cjpm.toml`.

To run a repo example (hello): `native\build_win.bat` → `cd examples\hello && cjpm build` → `run_win.bat` from the repo root.

![cj-tauri hello example](docs/images/cj_tauri.png)

*The hello example: dark card UI, invoke on button click, live events pushed from the Cangjie backend.*

## Why cj-tauri

- **Three hosts verified on real hardware, HarmonyOS PC closed-loop**: Windows (WebView2),
  Linux (WebKitGTK) and HarmonyOS PC (ArkWeb, 2in1 desktop window) — IPC, capability model and
  command dispatch are fully shared; platform differences live only in conditional compilation and
  the C bridge. The HarmonyOS host runs on the Cangjie side (no C bridge), and the `music` /
  `movie` examples plus template-generated projects all build into installable haps
- **Statically compiled backend** — no VM, no GC-jitter concerns; the protocol layer is a few
  hundred auditable lines of Cangjie.
- **No bundled Chromium** — uses the system WebView (WebKitGTK on Linux, WebView2 on Windows);
  single-example binaries are 4–10 MB.
- **Capability security model** — `capabilities/` whitelists with default-deny; unlisted commands
  are rejected. Independent of the host implementation.
- **Plugin system** — 14 official plugins (`fs` / `dialog` / `shell` / `serial` / `store` /
  `clipboard` / `notification` / `menu` / `mqtt` / `redis` / `log` / `http` / `ws` / `sqlite`),
  one line to plug in; permissions still come from the manifest.
- **Verifiable end to end** — instant evidence on the bridge's stderr, page-side self-checks that
  assert and report back; every example runs an unattended self-check.
- **Batteries-included scaffolding** — `cj-tauri create/dev/build/run/info/doctor`; capability
  manifests, the Windows GUI subsystem and cross-platform link flags are handled for you, and
  `doctor` prints what is missing line by line — the first thing to run on a new machine.

## Security model: claims you can check

Security claims are worth little as prose, so every row below maps to a real test case under
`src/tests/` — rerun them with `bash scripts/test.sh` (currently **349 tests, all green**; the
long-form design lives in `docs/安全模型.md`, Chinese).

| Threat | Defence | Assertion (test case) |
|---|---|---|
| Page invokes an unauthorized command | capability manifest is default-deny; undeclared = rejected | `testHubRejectsCommandNotAllowed` / `testRegistryEmptyDeniesEverything` |
| Page invokes an unregistered command | a command must be implemented + registered + allowed | `testHubRejectsUnregisteredCommand` |
| Page emits an undeclared event | events pass the same whitelist | `testEmitRequiresDeclaredEvent` / `testFrontendEmitDeniedEventIsRejected` |
| Permission set registered but never referenced | declaring a set is not granting it | `testRegisteredPermissionSetNotReferencedStaysDenied` |
| Manifest references a set nobody provides | warn only — never silently granted | `testPermissionSetWithoutProviderIsInert` |
| Path traversal / out-of-scope I/O | path scope: deny first, then allow; `..` folded lexically and canonicalized | `scope_test.cj` (`*` does not cross a separator, `**` does, any deny hit rejects) |
| Runtime allow-list abused into a wildcard | the registry rejects wildcards and accepts concrete values only | `testRuntimeAllowExtendsManifestScope` |
| Page-controlled URL egress (SSRF) | http / ws host allow-list; nothing declared = deny everything | `plugin_http_test.cj`, 9 assertions (userinfo spoofing / non-http schemes / IPv6 literals …) |
| A slow command freezing the UI thread | commands dispatch asynchronously and run on a worker | `testDispatchReturnsBeforeSlowCommandFinishes` |
| Exceptions swallowed silently | rejections and exceptions both return to the page and leave a stderr line | `testHubReportsCommandException` / `testHubReportsUnexpectedException` |

## Examples

28 runnable example projects live in `examples/` (Windows / Linux), plus 4 HarmonyOS PC projects
under `examples/ohos*` sharing the same page code, and three scaffolding templates in
`cli/templates/` (`app`, `app-vue`, `app-react`). Each example's directory has its own README with
full details and self-check instructions. Most docs are in Chinese; the code and logs are the
universal language.

**Showcase** — an **AI chat client** built with cj-tauri (`examples/ai-chat`; single-file package
≈25 MB, see [Option 1](#option-1-download-a-ready-made-tool-no-sdk-no-install)):

![ai-chat mode switch](docs/images/ai-chat-mode-switch.gif)

*Chat (direct to provider) → Agent (local cjh) with one click: the sidebar rebrands, four panels appear, the badge shows cjh's real model.*

![ai-chat missing-cjh guide](docs/images/ai-chat-guide.gif)

*When cjh is missing, switching to Agent shows a guide card: the download artifact for this platform, and picking the executable once starts it and remembers the path.*

**End-user tools & apps**:

| Example | In one line |
|---|---|
| [modbus-poll](examples/modbus-poll) | **Modbus TCP/RTU debugging tool**: multi-panel monitors (as many groups as you want on one screen), FC 01-04/05/06/15/16, message trace, CSV logging, byte-order option, built-in slave simulator — fills in Modbus Poll's long-standing pain points |
| [mqtt-client](examples/mqtt-client) | **MQTT debug console**: connect / subscribe / publish / message timeline (dedup by `seq`, filterable pause), protocol implemented purely in Cangjie by the `mqtt` plugin; ships a mock broker peer, Linux E2E 27 assertions matched on both sides |
| [redis-client](examples/redis-client) | **Redis debug console**: key-space browsing (SCAN cursor pagination + MATCH + TYPE filter, per-row type & TTL), typed get/set, pub/sub stream, INFO · DBSIZE · SLOWLOG — RESP2 over dual sockets in the `redis` plugin; mock redis peer, Linux E2E 47 assertions |
| [markdown-notes](examples/markdown-notes) | **Markdown notes**: file tree / editor / live preview (marked + Highlight.js, three highlight themes); three view states (`Ctrl+1/2/3`) and file ops via native menus; **path scope in action** — the manifest pins `fs` to the workspace, out-of-scope and `..` escapes rejected by the shared layer; Linux E2E 25 assertions |
| [cjnote](examples/cjnote) | **AI-native Markdown notes**: three panes (library / CodeMirror editor / AI assistant); native menus (File / View / Help) + `setTitlebarSubtitle` (falls back to the in-page bar); view states & theme **bidirectionally synced with menu checks**; `Ctrl+O` opens out-of-library files in memory only — the first `Ctrl+S` creates a new note, **never silently rewriting the file on disk**; **AI goes only through cjh** — the settings page writes address / key / model and pushes whitelist fields to the running instance live (a "test connection" button verifies without touching config); prebuilt cjh makes AI work out of the box; zero `fetch` in the page, all traffic on cjh's ws; 90 self-checks |
| [http-client](examples/http-client) | **HTTP API client** (Postman-like): request builder / response viewer (raw · JSON tree · headers) / collections & history — **all network from the Cangjie side** (zero `fetch`, TLS via the system trust store, verification never disabled); allow-list and body cap enforced on the host, out-of-scope reads rejected by path scope; mock peer, Linux E2E 55 assertions (incl. truncation checked on three sides) |
| [sqlite-browser](examples/sqlite-browser) | **SQLite database browser**: schema / paginated grid (sorting, type coloring, truncation markers) / SQL console (read-only & writable buttons); **Cangjie FFI straight to the system `libsqlite3`** (a repo first, no C bridge); command allow-list + path scope, read-only via a kernel-level connection, `ATTACH` rejected by an authorizer; Linux E2E 49 assertions (incl. an out-of-process read-only re-check of page writes) |
| [serial-assistant](examples/serial-assistant) | **Serial terminal**: parameter panel, color-coded TX/RX log, scheduled send, probe self-check |
| [cj-link](examples/cj-link) | **Serial/network two-in-one assistant**: serial (serial plugin) + three network modes (TCP client / TCP server with multi-client broadcast / UDP) sharing one log, HEX/ASCII dual display, send queue, checksums (CRC16 etc.), scheduled send, panel persistence; built-in peer simulator, Linux self-check 33 assertions |
| [ai-chat](examples/ai-chat) | **AI chat client**: chat (direct to providers, streaming Markdown) / Agent (local [cjh](https://atomgit.com/qq8864/cjh): sessions/skills/MCP/files panels + approvals + model passthrough) one-click switch, with a guide that can actually be completed when cjh is missing; streaming via the `ws` plugin, the four panels via the `http` plugin; multi-conversation + multi-provider (custom Base URL / API Key / model), streaming Markdown rendering (escaped before markup), tray + global hotkeys + minimize-to-tray + file logging, **zero new commands**; **nine model web versions embedded in one window** (GIFs above); cjh prebuilt ships with the repo, plus a Linux portable package (page self-check **56/56**) |
| [clipboard-history](examples/clipboard-history) | **Clipboard history manager**: first consumer of the **tray** + **global hotkey** capability bits, **verified on both Windows and Linux** — tray menu and `Ctrl+Alt+V` recall via framework events, **"minimize to tray" is a framework primitive** (falls back to a plain minimize when no tray exists); clicking a history item writes it back, verified by reading the clipboard externally; Linux E2E 15/15, Windows also has a minimize → hide → hotkey-recall chain |
| [serial-waveform](examples/serial-waveform) | **Real-time serial waveform scope**: `serial` plugin + double-buffered canvas, line protocol `<seq>,<value>`; at a 400 Hz sample stream the page computes rate / threshold crossings / drops itself, evidence in its README |
| [movie](examples/movie) | Movie browsing (list/search/detail/play) — all data fetched by the Cangjie side, zero `fetch` in the front-end |
| [music](examples/music) | Music player: charts/playlists/favorites/sharing + synced lyrics + 4 themes, covers fetched by the host with the right Referer |
| [typing-poem](examples/typing-poem) | Chinese-poem typing practice for kids: 108 poems with per-character pinyin, three.js 3D cards, streaks raise the pitch and the world reacts |
| [leetcode-gui](examples/leetcode-gui) | **Desktop algorithm practice**: questions grouped by category / question + Cangjie editor / judge terminal — "Run" hands the code to **cjc itself** and checks each case, results with expected values and timing, fully offline |

**Framework capability demos**:

| Example | Demonstrates |
|---|---|
| [hello](examples/hello) | Minimal loop: invoke + event push + permission denial |
| [todo_check](examples/todo_check) / [vue_todo](examples/vue_todo) | Todo app — zero-Node version vs Vue 3 + Vite version, same commands |
| [plugin-fs](examples/plugin-fs) / [plugin-dialog](examples/plugin-dialog) / [plugin-shell](examples/plugin-shell) / [plugin-serial](examples/plugin-serial) | Official plugins: file I/O / native dialogs / open-URL & subprocess / serial, each with permission contrasts |
| [menu](examples/menu) | Native menu bar (real click evidence on Windows + Linux) |
| [ipc-bench](examples/ipc-bench) | IPC benchmark: round-trip latency / throughput / payload scaling / event cost |
| [ipc-coalesce](examples/ipc-coalesce) | Event coalescing probe: under high-frequency pushes `emitLatest` merges into single-digit callbacks (last value always lands) while `emit` keeps every one — shown side by side, default behavior unchanged |
| [multi-window](examples/multi-window) | Multi-window: one HTML, two windows, roles decided by each window's own label; both windows open a native dialog at the same time to prove host callbacks route by handle |

**Built-in plugins** (ship with the framework, no example directory of their own; design in the [plugin tutorial](docs/插件体系教程.md), Chinese):

- Persistent key-value `store` plugin (RFC-003 phase 2): arbitrary JSON, atomic writes (tmp + rename), named permission sets `store:readonly` / `store:default`; `examples/music` migrated to it
- `clipboard` / `notification` plugins (phase 3): system clipboard read/write / system notifications, verified on Linux (external clipboard read-back, notifications received on the session bus); Windows stubs report capability bits honestly
- `log` plugin + file logging (phase 5): `app.setLogFile(...)` lands Cangjie-side and C-bridge diagnostics in one file with automatic rotation; already-distributed exes can enable it via the `CJ_TAURI_LOG` env var; page `log:write` uses the same outlet
- `http` plugin (SEC-006 egress gate): the page-controlled network point — `http:get` / `http:post` / `http:delete` / `http:postStream` (SSE streamed back as `http:chunk` events), host allow-list in `scopes.http` (**nothing declared = deny all**), no auto-redirect, 8 MiB cap; `examples/ai-chat` is the first consumer
- `ws` plugin (long-connection egress): `ws:connect` / `ws:send` / `ws:close` + `ws:frame` / `ws:state` events, host allow-list in `scopes.ws` (**deny-all by default**, same shape as `http`, sharing the core `urlHostOf`); handshake uses stdx's `WebSocket.upgradeFromClient`, no hand-written protocol

**Ecosystem projects** (separate repos built on cj-tauri, not part of `examples/`):

| Project | In one line |
|---|---|
| [cjnote](https://atomgit.com/qq8864/cjnote) | **AI-native Markdown notes**: three panes (note library / editor / AI assistant) + three view states (`Ctrl+1/2/3`); **native menu bar plus a subtitle** — File / View / Help, with title · saved-state · word count pushed into the system menu row; an Outline tab that jumps to 1–3 level headings; AI context from the whole note or from `note:search` hits, with rewrite / continue / translate going through a **diff confirm** strip; `Ctrl+O` opens an external `.md` as an in-memory draft (never rewriting the original), `Ctrl+P` quick-opens library notes; every network call is made by the Cangjie side with a host whitelist behind it; page self-check **31/31 on Linux hardware** |

**Screenshot wall** (all on-device; full sets in each example's README):

| [markdown-notes](examples/markdown-notes): tree / editor / live preview | [sqlite-browser](examples/sqlite-browser): paginated grid + SQL console |
|---|---|
| ![Markdown notes](docs/images/example-markdown-notes.png) | ![SQLite browser](docs/images/example-sqlite-browser.png) |
| [leetcode-gui](examples/leetcode-gui): questions / editor / judge terminal | [cj-link](examples/cj-link): serial + network, two-in-one |
| ![Cangjie LeetCode](docs/images/example-leetcode-gui.png) | ![Serial/network assistant](docs/images/example-cj-link.png) |
| [serial-assistant](examples/serial-assistant): parameter panel + color-coded TX/RX | [http-client](examples/http-client): request builder / response viewer |
| ![Serial assistant](docs/images/example-serial-assistant.png) | ![HTTP client](docs/images/example-http-client.png) |
| [serial-waveform](examples/serial-waveform): 400 Hz serial waveform | [typing-poem](examples/typing-poem): poem typing practice (three.js 3D) |
| ![Serial waveform](docs/images/example-serial-waveform.png) | ![Poem typing](docs/images/example-typing-poem-typing.png) |
| [movie](examples/movie): movie browsing | [music](examples/music): music player (synced lyrics) |
| ![Movie app](docs/images/example-movie.png) | ![Music playing](docs/images/example-music-playing.png) |
| [ai-chat](examples/ai-chat): chat mode (direct, streaming Markdown) | [ai-chat](examples/ai-chat): Agent mode (cjh connected + four panels) |
| ![AI chat: chat mode](docs/images/example-ai-chat-chat.png) | ![AI chat: Agent mode](docs/images/example-ai-chat-agent.png) |
| [modbus-poll](examples/modbus-poll): multi-panel monitors + streaming Tx/Rx message trace | [cjnote](https://atomgit.com/qq8864/cjnote) (ecosystem): split editing + AI assistant, native menu row |
| ![Modbus Poll (cj-tauri)](examples/modbus-poll/images/modbus-poll-main.png) | ![cjnote: split + AI](docs/images/example-cjnote.png) |
| [cjnote](https://atomgit.com/qq8864/cjnote) (ecosystem): native View menu synced with view state | [ohos-music](examples/ohos/ohos-music): HarmonyOS PC music player (synced lyrics) |
| ![cjnote: native view menu](docs/images/example-cjnote-menu.png) | ![Cangjie Music (HarmonyOS PC)](docs/images/example-ohos-music.jpg) |
| [ohos-movie](examples/ohos/ohos-movie): HarmonyOS PC movie app (covers fetched via the host with Referer/UA) | [ohos unified project](examples/ohos): `create --template ohos` output, `sync ohos` derives a buildable hap |
| ![Cangjie Movie (HarmonyOS PC)](docs/images/example-ohos-movie.jpg) | ![ohos template output](docs/images/example-ohos-template.jpg) |

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

**Getting started**:

| Doc | Contents |
|---|---|
| [使用文档](docs/使用文档.md) | Setup → create → develop → troubleshoot (the canonical guide, Chinese) |
| [前端入门教程](docs/前端入门教程.md) | Front-end from zero: layout → bridge API → events → capabilities → full walkthrough |
| [hello-world 入门教程](docs/hello-world-入门教程.md) | npm-CLI starter guide: from `create` to a window on real hardware (two pitfalls included) |
| [插件体系教程](docs/插件体系教程.md) | Plugin system: what it is → plug in an official plugin → write your own |
| [IPC 通信机制](docs/IPC-通信机制.md) | Protocol frames → full sequence → measured performance vs WebSocket / raw TCP |

**Design & reference**:

| Doc | Contents |
|---|---|
| [安全模型](docs/安全模型.md) | Threat model, layered defences (default-deny / permission sets / path scopes / egress gate), comparison with Tauri 2 (Chinese) |
| [设计决策记录](docs/设计决策记录.md) | Why it looks like this: 12 ADRs — same-process bridge, capability tiers, scope semantics, costs and re-evaluation triggers (Chinese) |
| [与 Tauri 的差异清单](docs/与Tauri的差异.md) | Coming from Tauri 2: concept mapping, behavior differences, platform capability differences, migration checklist (Chinese) |
| [平台能力矩阵](docs/平台能力矩阵.md) | Commands / plugins / host capabilities × Windows / Linux / HarmonyOS: usable, unverified, or unsupported (Chinese) |
| [需求追踪矩阵](docs/需求追踪.md) | Where each capability stands: five states + verifiable evidence (Chinese) |
| [源码结构](docs/源码结构.md) | Read before changing the framework: `src/` layers and file ownership, dependency direction, when to split and when not to (Chinese) |

**Walkthroughs & records**:

| Doc | Contents |
|---|---|
| [Modbus tool deep-dive](docs/仓颉版Modbus调试工具-介绍与实战.md) | Scaffolding walkthrough + how the Modbus tool is built + comparison with Modbus Poll |
| [技术方案](docs/技术方案.md) / [踩坑与实施记录](docs/踩坑与实施记录.md) | Feasibility study / the full development pitfall log (Chinese) |
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

- ✅ **Three hosts**: Linux (WebKitGTK), Windows (WebView2) and HarmonyOS PC (ArkWeb, 2in1 desktop
  window) — IPC, capability model and command dispatch are fully shared; platform differences live
  only in conditional compilation and the C bridge
- ✅ Native Cangjie scaffolding CLI: `create / dev / build / run / info / doctor`, distributed via npm
- ✅ Plugin system v1 + 14 official plugins (fs / dialog / shell / serial / store / clipboard /
  notification / menu / mqtt / redis / log / http / ws / sqlite); three gates — command whitelist,
  named permission sets, and **path scopes** (RFC-003 phase 4) — with on-device evidence on Windows
  and Linux
- ✅ Async command dispatch (slow commands never freeze the window), multi-window routing by label,
  machine-readable plugin manifest via `info --json`
- ✅ Host capability bits: menu / **tray** / **global hotkeys** / file drag-in / notifications —
  implemented on both Windows and Linux and reported honestly by `system:host`; "minimize to tray"
  is a host primitive (`minimizeToTray`) that degrades to a plain minimize with one stderr line when
  no tray is available
- ✅ Engineering: 349 unit tests + SDK-free static gates (what CI runs) + unattended example self-checks
- ✅ HarmonyOS PC (ArkWeb, 2in1): page-side `system:version` round trip, multi-window label routing,
  `music` / `movie` examples closed-loop on device; `cj-tauri create --template ohos` generates a
  project that builds into an installable hap
- 🔜 Remaining HarmonyOS host capability bits (menu already device-verified; tray / hotkeys / drag-and-drop / notification honestly report 0 — dialogs use an app-side overlay and occupy no bit), macOS WebView, more official plugins

## Repos

The same code is hosted twice; `origin` carries both push URLs, so **one `git push` updates both**:

```bash
git clone https://atomgit.com/qq8864/cj-tauri.git          # AtomGit (direct connection recommended in CN)
git clone https://github.com/yangyongzhen/cj-tauri.git     # GitHub
git ls-remote origin main && git ls-remote github main     # verify both SHAs match
```

## License

[MIT](LICENSE) © 2026 yangyongzhen
