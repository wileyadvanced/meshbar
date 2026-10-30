# JNAP in MeshBar

JNAP ("JSON Network Access Protocol") is the API behind the Linksys web UI and app. This page documents what MeshBar uses, on what firmware, and the quirks found along the way. It is based on a **Pinnacle 2.2 M62CF-EU, firmware 1.2.4**, with **M60CF-EU** satellites, cross-checked against [uvjim/pyvelop](https://github.com/uvjim/pyvelop). The full catalog that router advertises (about 220 actions) is in [jnap-actions.md](jnap-actions.md).

## Request format

```http
POST /JNAP/ HTTP/1.1
Host: 192.168.1.1
Content-Type: application/json; charset=UTF-8
X-JNAP-Action: http://linksys.com/jnap/devicelist/GetDevices3
X-JNAP-Authorization: Basic YWRtaW46…            (base64 of "admin:<password>")

{"sinceRevision": 0}
```

- Always send requests to the **master** router. Satellites usually don't expose JNAP on the LAN, and the master answers for the whole mesh.
- HTTPS uses a **self-signed** certificate. When Connect finds one, MeshBar trusts it for that host only. The setting is **Trust this host's certificate** in Settings. HTTP also works, but sends the Basic credential in clear text on your LAN.
- The password is sent only in the `X-JNAP-Authorization` header. It is never put in the URL or the body.

A reply looks like:

```json
{ "result": "OK", "output": { "devices": [ … ], "revision": 1234 } }
```

Errors put a code in `result`, for example `_ErrorUnauthorized`, `_ErrorInvalidInput` or `_ErrorAbortedAction`. Some builds use `response` instead of `result`, and MeshBar accepts both. MeshBar shows its own wording for failures and never surfaces raw error payloads.

### Batching: `core/Transaction`

```json
[
  { "action": "http://linksys.com/jnap/core/GetDeviceInfo", "request": {} },
  { "action": "http://linksys.com/jnap/router/GetWANStatus3", "request": {} }
]
```

The reply is `{"result":"OK","output":{"responses":[…]}}`, with one `{result, output}` per child, in order.

## Actions MeshBar uses

### Read (every poll, default every 60 s)

| Action | Request | Used for |
| --- | --- | --- |
| `core/GetDeviceInfo` | `{}` | Model, firmware, serial of the master |
| `devicelist/GetDevices3` | `{"sinceRevision": 0}` | Nodes and clients, node roles, parents, connections, names |
| `nodes/diagnostics/GetBackhaulInfo2` | `{}` | Per-satellite parent, wired/wireless, `speedMbps`, RSSI |
| `nodes/networkconnections/GetNodesWirelessNetworkConnections2` | `{}` | Per-client band, RSSI and negotiated link rate, by node |
| `router/GetWANStatus3` | `{}` | WAN up/down, connection type, address |
| `wirelessap/GetRadioInfo3` | `{}` | Radios: band, channel, width, SSID, security mode |
| `diagnostics/GetSystemStats2` | `{}` | Uptime, CPU and memory load (when the firmware sends them) |
| `healthcheck/GetHealthCheckStatus` | `{}` | Is a speed test running? |
| `healthcheck/GetHealthCheckResults` | `{"healthCheckModule":"SpeedTest","includeModuleResults":true,"lastNumberOfResults":1}` | Last speed test |
| `nodes/topologyoptimization/GetTopologyOptimizationSettings2` | `{}` | Node-steering flags (read-only) |

### Read (on demand)

| Action | When |
| --- | --- |
| `core/CheckAdminPassword` | Once on Connect, and when a batch is refused (see quirks) |
| `core/GetAdminPasswordAuthStatus` | Unauthenticated. Reads `attemptsRemaining` so the Connect window can warn before a lockout |
| `nodes/setup/GetSelectedChannels` | Spectrum: channels each node is on right now (at most every 2 min) |
| `wirelessap/GetDFSSettings` | Spectrum: whether DFS channels are allowed |
| `sysinfo.cgi` (not JNAP) | Spectrum **Scan at router**: the router's site-survey section. It is parsed in memory and discarded, because the page also holds other settings. |

### Write (only from a button, never from polling)

| Action | Request | Button |
| --- | --- | --- |
| `nodes/diagnostics/RefreshSlaveBackhaulData` | `{}` | Refresh, and automatically at most every 5 min. It asks the master to re-measure satellite backhaul. Harmless, but it makes speeds read 0 for a few seconds. |
| `healthcheck/RunHealthCheck` | `{"runHealthCheckModule":"SpeedTest"}` | Speed test → Run |
| `nodes/setup/StartBlinkingNodeLed` | `{"deviceID": "<node>"}` | Inspector → Blink |
| `nodes/setup/StopBlinkingNodeLed` | `{}` | Stops the blink (no device ID on this firmware) |
| `devicelist/SetDeviceProperties` | `{"deviceID": "…", "propertiesToModify": [{"name":"userDeviceName","value":"…"}]}` | Inspector → Rename |
| `core/Reboot2` | `{"deviceUUID": "<node>"}` | Inspector → **Restart this node** (confirmation) |
| `core/Reboot` | `{}` | Dashboard ⋯ → **Restart entire router** (separate confirmation; takes the whole mesh down) |

`core/Reboot` and `core/Reboot2` are easy to confuse. A unit test fails if the per-node command ever points at `core/Reboot`.

## Quirks

### Pinnacle refuses whole batches

On firmware 1.2.4, `core/Transaction` sometimes comes back `_ErrorUnauthorized`. One child returns `_ErrorUnauthorized` and every other child returns `_ErrorAbortedAction`, **even with the correct password**. The same action sent on its own succeeds. A wrong password looks identical in a batch.

MeshBar handles this as follows:

1. On a refused batch, it calls `core/CheckAdminPassword` once.
2. If the password is wrong, it stops polling and shows "Wrong password" with the remaining attempts from `GetAdminPasswordAuthStatus`.
3. If the password is right, it switches to **single-action mode** for the rest of the session. Any action that is still refused is listed in the UI ("The router did not share: …"), and health shows **Partial data** instead of **Healthy**.

### Units

| Field | Unit | Example |
| --- | --- | --- |
| `GetBackhaulInfo2` → `speedMbps` | Mbit/s, as a string or number | `"158.4"` |
| `GetBackhaulInfo2` → `rssi` / `signalStrength` | dBm | `-57` |
| `GetHealthCheckResults` → `speedTestResult.downloadBandwidth` / `uploadBandwidth` | **kbit/s** | `3170000` → 3.17 Gbps |
| `GetHealthCheckResults` → `latency` | ms | `2` |
| Older builds' `downloadSpeed` / `uploadSpeed` | not consistent | MeshBar guesses the unit by magnitude |

Earlier versions of MeshBar guessed the speed-test unit by magnitude for every field. That showed sub-10 Mbps results as Mbps × 1000. A failed run (`exitCode` such as `SpeedTestExecutionError`, with zero bandwidth) is now shown as failed, not as 0 Mbps.

### Backhaul "Measuring…"

Right after `RefreshSlaveBackhaulData`, or after a satellite reconnects, `speedMbps` is `0` or missing for up to about a minute. MeshBar shows *Measuring…* rather than a scary 0 Mbps, and does not raise a weak-link alert for it.

### Radio restarts

While radios restart (after a channel change in the Linksys app, DFS events, or a node reboot), the router can answer with an HTML page or an empty body for a few seconds. MeshBar reports "The router returned something that was not JNAP JSON". The next poll normally recovers.

### Identity

`GetDevices3` uses `deviceID` (a UUID) as the stable key. MACs, IPs and names change: phones use private MAC addresses, and DHCP moves IPs. MeshBar keys client history by `deviceID`.

## What is *not* possible

- **Pinning a satellite to a parent.** There is no action for it. The topology-optimization settings are steering on/off flags, not a parent override. MeshBar shows them read-only.
- **Per-client traffic or bytes.** Firmware 1.2.4 exposes no per-client throughput counters, so MeshBar shows link rate (PHY rate), not usage.
- **Talking to satellites directly.** Satellites don't serve JNAP on the LAN in normal operation.
- **Reading Wi-Fi passphrases.** `GetRadioInfo3` can include security settings. MeshBar keeps only the security mode string, and passphrases are never stored or logged.

MeshBar also deliberately does **not** call these advertised actions: `StartAutoChannelSelection`, the `Set*` radio/WAN/admin settings, `FactoryReset*` or firmware update. Change those in the Linksys app.
