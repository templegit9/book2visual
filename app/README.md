# Book2Visual — macOS App (Team B)

Native macOS SwiftUI control plane for Book2Visual. It provisions a ThunderCompute
GPU instance over the **direct REST API**, opens an **SSH tunnel** to the remote
pipeline service, submits a job, streams progress over **SSE**, downloads the
result ZIP, and shows the manga pages.

This package is **code-first**: the canonical verification on this Mac is
`swift build` / `swift test` (there is no GPU/Thunder account yet). All SwiftUI
views, services, and view models live in a library target so they type-check
headless; a thin executable target hosts the `@main` app.

## Layout

```
app/
├── Package.swift                       # SwiftPM manifest (.macOS(.v14))
├── project.yml                         # XcodeGen spec → .xcodeproj / notarizable .app (later)
├── Support/
│   ├── Info.plist                      # bundle metadata (used by the .xcodeproj)
│   └── Book2Visual.entitlements        # App Sandbox + network.client + user-selected files
├── Sources/
│   ├── Book2VisualCore/                # library target — everything testable/typecheckable
│   │   ├── Models/                     # Codable mirrors of contract/schemas (snake_case via CodingKeys)
│   │   │   ├── JobRequest.swift        #   JobRequest, CharacterInput, VRAMMode, ConsistencyMode
│   │   │   ├── ProgressEvent.swift     #   ProgressEvent + type enum + progressFraction
│   │   │   ├── SceneList.swift         #   internal text-stage shape (for future use)
│   │   │   └── ContractCoding.swift    #   shared JSON encoder/decoder
│   │   ├── Services/                   # the plumbing layer
│   │   │   ├── ThunderClient.swift     #   URLSession REST client (create/list/up/down/delete/snapshot, pollUntilRunning)
│   │   │   ├── InstanceManager.swift   #   protocol + InstanceStatus traffic-light
│   │   │   ├── ThunderRESTInstanceManager.swift  # REST-backed impl
│   │   │   ├── MockInstanceManager.swift          # in-memory state machine (tests/offline)
│   │   │   ├── SSHTunnel.swift         #   /usr/bin/ssh -N -L … ubuntu@ip process manager + reconnect
│   │   │   ├── KeychainStore.swift     #   Security-framework secret store (service id book2visual.thunder) + InMemory variant
│   │   │   ├── SSHKeyManager.swift     #   in-app ed25519 keygen; private key stays in Keychain
│   │   │   ├── JobClient.swift         #   HTTP+SSE data-plane client (health/submit/stream/cancel/download)
│   │   │   ├── MockJobClient.swift     #   scripted ProgressEvent sequence + tiny real ZIP (no network)
│   │   │   ├── OutputStore.swift       #   App Support outputs dir; unzip + enumerate PNG pages
│   │   │   └── Errors.swift            #   typed LocalizedErrors
│   │   ├── ViewModels/                 # AppState, AppSettings, InstanceViewModel, RunViewModel
│   │   └── Views/                      # RootView, SetupView, SettingsSheet, RunView, ViewerView,
│   │                                   # Book2VisualScene (Scene + MenuBarExtra + notification), AppEnvironment (DI root)
│   └── Book2VisualApp/
│       └── main.swift                  # @main App hosting Book2VisualScene
└── Tests/
    └── Book2VisualCoreTests/           # XCTest; Fixtures/ holds contract-sample JSON
```

## Build & test (SwiftPM — the verification gate)

```bash
cd app
swift build          # compiles the library + executable (clean, no warnings)
swift test           # 32 tests, all green
```

### What the tests cover
- **Contract JSON round-trips** (`ContractCodingTests`): JobRequest / ProgressEvent decode from
  contract-sample fixtures and re-encode with snake_case keys; empty `race_hint` is omitted.
- **RunViewModel against MockJobClient** (`RunViewModelTests`): submit → consume scripted events →
  progress reaches 100% → pages unzipped & loaded; the `job_error` path; the cancel path; the
  Run-enabled guard; request trimming.
- **MockInstanceManager state machine** (`MockInstanceManagerTests`): stopped→starting→running,
  stop, injected-failure→error, prepare-environment phases, status→traffic-light mapping.
- **ThunderClient** (`ThunderClientTests`): list (array + envelope), missing-token, HTTP error,
  create (sends `public_key`/`gpu_type`/`mode=production`, `Bearer` header), `pollUntilRunning`
  success-after-retries and timeout (injected sleeper, no real waiting).
- **SSE parsing + ZIP** (`SSEAndZipTests`): SSE `data:` → ProgressEvent; the in-house stored-ZIP
  writer unzips to valid PNGs; default export name format.
- **Secrets + tunnel** (`SecretAndTunnelTests`): in-memory secret round-trip; ssh argument vector
  (uses `ubuntu@`, `-L` forward, ServerAlive opts); missing-key error.

## Generate a real .app / .xcodeproj later (XcodeGen)

`swift build` cannot produce a signed/notarizable `.app` bundle (no Info.plist/entitlements/
MenuBarExtra packaging). When you need the bundle:

```bash
brew install xcodegen        # if not already installed
cd app
xcodegen generate            # reads project.yml → Book2Visual.xcodeproj
open Book2Visual.xcodeproj    # build/run/archive/notarize in Xcode
```

The generated `Book2Visual.xcodeproj` and `.build/` are gitignored — regenerate from `project.yml`
anytime. `project.yml` references the checked-in `Support/Info.plist` and `Support/Book2Visual.entitlements`
(App Sandbox, `network.client`, user-selected files, hardened runtime).

## Offline / mock dev (no Thunder account, no GPU)

The app is wired through `AppEnvironment` (the DI composition root) with two factories:

- `AppEnvironment.mock()` — `MockInstanceManager` + `MockJobClient`. Fully offline: the instance
  state machine and a scripted job (events + a real tiny ZIP) run with no network.
- `AppEnvironment.live(localPort:)` — `ThunderRESTInstanceManager` (Thunder REST) + `HTTPJobClient`
  pointed at `http://127.0.0.1:<localPort>` (the local end of the SSH tunnel).

Run the executable offline:

```bash
BOOK2VISUAL_MOCK=1 swift run Book2VisualApp     # in a GUI session
```

### Pointing at `mockserver/` over a local port
`HTTPJobClient` talks to `http://127.0.0.1:<localPort>`. To develop against the repo's
`mockserver/` (the standalone contract implementation) instead of the mock client:
1. Start `mockserver/` listening on, e.g., `127.0.0.1:8000`.
2. Use `AppEnvironment.live(localPort: 8000)` (no SSH tunnel needed — the mock server is already
   local), or open a real tunnel via `SSHTunnel` and set `localPort` to the forwarded port.
3. The data-plane HTTP/SSE/ZIP shapes are byte-compatible with the real `service/`, so swapping in
   the real instance later is a no-op.

## Architecture notes (per PRD §0 corrections)
- Thunder control plane is a **direct REST API** (`https://api.thundercompute.com:8443`,
  `Authorization: Bearer`). The app does **not** shell out to `tnr`.
- `/instances/list` is the **only** status source; `pollUntilRunning` polls it every 10s (5-min
  timeout) for `status=="RUNNING"` AND `ip != nil`.
- SSH user is **ubuntu**; `ip`/`port` come from the list response (port is not always 22).
- One-time **Prepare Environment** = provision → bootstrap → snapshot.
- Secrets (Thunder token, SSH private key) live only in the **Keychain**; the keypair is generated
  in-app and the private key is materialized to a path with `0600` only when ssh needs it.

## Contract conformance
Models mirror `contract/schemas/*.schema.json` exactly via `CodingKeys` (snake_case on the wire).
No contract deviations.
