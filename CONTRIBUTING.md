# Contributing

MeshBar is a small macOS app. The useful change is usually a parser fix for a firmware build whose JSON is shaped a bit differently.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit, and [docs/JNAP.md](docs/JNAP.md) for the router API and its quirks.

## Setup

macOS 14 or later, Xcode 15 or later.

```bash
swift test
swift build --product MeshBar
```

`swift test` covers parsing, health, alerts, history, and the reboot commands. It does not talk to a router. Demo mode is what you run when you want to see the windows.

`swift test` needs Xcode's XCTest. With only the Command Line Tools selected, use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.

### Checking your own router's JSON

`LiveCaptureTests` is skipped unless `MESHBAR_LIVE_DIR` is set. Point it at a folder **outside the repo** holding the raw JNAP responses (full `{"result": "OK", "output": …}` envelopes) named `device-info.json`, `devices.json`, `backhaul.json`, `wireless.json`, `wan.json`, `radios.json`, `stats.json`, `health-status.json`, `health-results.json`, `topology.json`. Missing files are skipped.

```bash
MESHBAR_LIVE_DIR=~/meshbar-captures MESHBAR_LIVE_IP=192.168.1.50 swift test --filter LiveCaptureTests
```

It prints the parsed tree (names, parents, link speed and RSSI, client counts), WAN state, the health colour, and which node hosts `MESHBAR_LIVE_IP`. Unknown field names are logged as `[MeshBar] Unknown …` lines. Those captures hold MACs, serials and your Wi-Fi settings: never commit them.

Please don't commit passwords, serial numbers, real MAC addresses, SSIDs, or a capture from your home network. Fixtures in `Tests/MeshBarCoreTests/Fixtures` use example values (`02:11:22:…`, `DEMO-…`, `203.0.113.10`).

## Reboot

`core/Reboot` restarts the whole router. `core/Reboot2` with `{"deviceUUID": "..."}` restarts one node. The per-node button must keep calling `MeshCommands.rebootNode`. There is a unit test that fails if those URIs get swapped. There is no API to pin a parent; don't add a control that claims to.

## A new or messy model

1. Capture redacted `output` JSON for the actions that look wrong. Strip secrets before it leaves your machine.
2. Add a fixture under `Tests/MeshBarCoreTests/Fixtures` and a test that shows the field you had to accept (string vs number, a new parent key, RSSI under a different name).
3. Teach `MeshSnapshotParser` to read the alias. Keep the field optional. Log the key name through `MeshLog.unknownShape` if you still don't model it. Do not log values.
4. Run `swift test`.

`MeshBarCore` is the place for protocol and health code. The app target should stay a view over that library.

## Pull requests

Open them against `main`. The GitHub Actions workflow builds and tests on a macOS runner, then runs `scripts/bundle.sh`.

Launch at login and the local-network Info.plist only apply to the bundled `.app`.
