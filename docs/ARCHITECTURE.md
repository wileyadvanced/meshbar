# Architecture

MeshBar is a Swift package with two targets and one test target.

| Target | Kind | Platforms | What lives there |
| --- | --- | --- | --- |
| `MeshBarCore` | library | macOS, Linux | JNAP client, response parser, models, health scoring, alerts, client-history event derivation, history store (SQLite / JSONL), Spectrum analyzer, demo mesh |
| `MeshBar` | executable (SwiftUI app) | macOS 14+ | Menu bar, dashboard, inspector, Spectrum, client detail sheet, Connect, Settings, Keychain, notifications, CoreWLAN scan, `SMAppService` |
| `MeshBarCoreTests` | XCTest | macOS, Linux | Fixture-based tests. They never open a socket. |

`MeshBarCore` depends only on Foundation and the system `sqlite3`. On Linux it links `libsqlite3` through the `CSQLite` system-library target, so CI can test the core without a Mac. The app target is a thin view layer over the core.

`scripts/bundle.sh` runs a release build and assembles `dist/MeshBar.app`. It copies in `scripts/Info.plist` (`LSUIElement` menu-bar agent, `NSAllowsLocalNetworking`, Location usage string) and `Resources/AppIcon.icns`, then ad-hoc signs the app with a stable designated requirement, so the Keychain recognises rebuilt copies.

## Data flow

```
            ┌───────────────────────── AppModel (@MainActor, ObservableObject) ─────────────────────────┐
 timer ───▶ │ RefreshGate ─▶ JNAPClient.perform(...) ─▶ MeshSnapshotParser ─▶ MeshSnapshot              │
 Refresh ─▶ │                                                                  │                        │
            │      HealthEvaluator ◀────────────────────────────────────────────┤                        │
            │      AlertEngine (debounced notifications) ◀─────────────────────┤                        │
            │      HistoryStore.append(nodes) / appendClients(clients) ◀───────┘                        │
            └───────────────────────────────┬─────────────────────────────────────────────────────────┘
                                            ▼  @Published snapshot, health, lastRefresh
                       MenuBarView · DashboardView · NodeDetailView · SpectrumView · ClientDetailView
```

1. **Credentials.** `AppModel.makeClient()` reads the password from the Keychain (`com.meshbar.app.router-password`) and builds a `JNAPClient` for the configured host. The password is never copied to a published property or a log.
2. **Poll.** The poll reads device info, devices, backhaul, wireless connections, WAN, radios, system stats, health-check status and results, and topology settings. It uses `core/Transaction` when the router allows it, and single calls otherwise (see [JNAP.md](JNAP.md)).
3. **Parse.** `MeshSnapshotParser` turns the replies into a `MeshSnapshot`: nodes with parents, link medium, `speedMbps` and RSSI; clients with their node, band, RSSI and link rate; WAN; radios; and the last speed test. Every field is optional. A missing action becomes a `missingData` note, not an error.
4. **Evaluate.** `HealthEvaluator` scores the mesh from 0 to 100 and picks the menu glyph. `AlertEngine` compares the new snapshot with the last one, so a node going offline, changing parent or dropping under the speed/RSSI threshold sends one notification. Each alert has a 120 s debounce.
5. **Record.** `HistoryStore` appends one node sample per node and one client sample per known client, then prunes anything older than the retention period (30 days by default).
6. **Render.** Views observe `AppModel`. The client detail sheet loads 7 days of samples for one client and derives events on the fly.

## Poll gate

`RefreshGate` (in `MeshBarCore/RefreshGate.swift`) serialises polls:

- At most **one poll in flight**.
- Requests made during a poll (timer ticks, Refresh clicks, wake from sleep) collapse into **exactly one** follow-up poll. A Refresh click is never lost, and ten clicks still mean one extra poll.
- `forceBackhaul` and `userInitiated` from queued requests are OR-ed into the follow-up.
- `shouldRefreshBackhaul(force:last:interval:)` asks the master to re-measure satellite backhaul (`nodes/diagnostics/RefreshSlaveBackhaulData`) at most every **300 s** on automatic polls, and always on a manual refresh. Right after that, satellites report `speedMbps: 0` for a few seconds. The UI shows *Measuring…* instead of "0 Mbps".

Spectrum scans have their own throttle: one router site survey per minute, and the channel plan is read at most every few minutes.

## History store

Files are in `~/Library/Application Support/MeshBar/Live/`. Demo mode uses `…/MeshBar/Demo/`, so fake data never mixes with real data.

The store is `history.sqlite`. It uses the system SQLite library, with the schema version in `PRAGMA user_version`.

```sql
-- user_version 1
CREATE TABLE samples (            -- one row per node per poll
    id TEXT PRIMARY KEY,
    timestamp REAL NOT NULL,      -- seconds since 1970
    node_id TEXT NOT NULL,
    node_name TEXT NOT NULL,
    is_online INTEGER NOT NULL,
    parent_id TEXT,
    speed_mbps REAL,
    rssi_dbm INTEGER,
    connection_type TEXT,
    client_count INTEGER NOT NULL,
    wan_connected INTEGER,
    wan_type TEXT
);
CREATE INDEX idx_samples_timestamp ON samples(timestamp);
CREATE INDEX idx_samples_node ON samples(node_id, timestamp);

-- user_version 2 (added in v0.1.0, migrated in place)
CREATE TABLE client_samples (     -- one row per known client per poll
    timestamp REAL NOT NULL,
    client_id TEXT NOT NULL,      -- router device ID, stable across IP and name changes
    mac TEXT,
    name TEXT NOT NULL,
    node_id TEXT,
    node_name TEXT,
    band TEXT,                    -- raw router string, e.g. "5GHz"
    medium TEXT,                  -- wireless / wired
    rssi_dbm INTEGER,
    link_mbps REAL,
    is_online INTEGER NOT NULL,
    ip TEXT
);
CREATE INDEX idx_client_samples_client ON client_samples(client_id, timestamp);
CREATE INDEX idx_client_samples_timestamp ON client_samples(timestamp);
```

If the database can't be opened, the store falls back to JSON lines (`history.jsonl`, `client-history.jsonl`) in the same folder with the same retention. Both back ends satisfy the same `HistoryStoring` protocol and are covered by the same tests.

**Size.** At a 60 s poll, a home with about 30 clients writes about 45 k client rows a day. Thirty days of history is tens of MB.

### Client events

`ClientEventDeriver` turns the sample stream into the connection log:

- **Roam**: node changed. **Band change**: 2.4, 5 and 6 GHz family changed. **Drop-off** and **Reconnect**: online state flipped. **IP change**.
- A change only counts once it has **held for two consecutive polls** (`DebouncedValue`), so a single odd reading or a flapping client doesn't spam the log.
- A gap of more than 15 minutes between samples (Mac asleep, app quit) discards any half-confirmed change, breaks the chart line, and is not counted as time on a node.

## Launch arguments

The bundled app accepts a few arguments. They are mostly used to take screenshots and to debug without clicking:

| Argument | Effect |
| --- | --- |
| `--dashboard` | Open the dashboard at launch |
| `--view spectrum` | Start the dashboard on Spectrum |
| `--select-node <name>` | Select the first node whose name contains `<name>` |
| `--client-detail <name>` | Open the client history sheet for the first client whose name contains `<name>` |
| `--scan router` / `--scan mac` | Run one Spectrum scan after the first poll |
| `--open-window connect` / `settings` | Open that window too |
| `--open-menu` | Open the menu-bar dropdown once |

```bash
open dist/MeshBar.app --args --dashboard --select-node "Floor 3" --client-detail "MacBook"
```
