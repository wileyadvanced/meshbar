# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-10-30

First public release.

### Added

- **Menu bar.** The health glyph and score, WAN state and every node with its backhaul are shown in a dropdown. Refresh is ⌘R.
- **Dashboard.**
  - Live topology map with wired/wireless backhaul, speeds and signal.
  - Collapsible sidebar with nodes and clients.
  - Collapsible bottom bar with clients, history and speed test.
- **Inspector.** Per-node details: model, firmware, parent, backhaul, clients, uptime.
  - Actions: **Blink**, **Rename**, **Restart this node** (`core/Reboot2`).
  - **Restart entire router** (`core/Reboot`) has its own confirmation.
- **Spectrum.**
  - Shows the channel plan per node.
  - Scans nearby networks from this Mac (CoreWLAN) or at the router (site survey, at most once a minute).
  - Shows the per-channel congestion score and a recommendation. It only advises; it does not change channels.
- **Client history.** Each poll records every client's node, band, signal, link rate, IP and online state. The client detail sheet shows:
  - 1 h / 24 h / 7 d charts for signal and link rate,
  - time on each node,
  - a connection log (roams, band changes, drop-offs, reconnects, IP changes) with a two-poll debounce.
- **History store.** SQLite (`history.sqlite`, schema v2) with a JSON-lines fallback and configurable retention (30 days by default).
- **Speed test.** Run the router's built-in speed test and show the last result in Mbps or Gbps with latency.
- **Alerts.** Notifications for a node going offline, changing parent, or degraded backhaul (below your speed or signal threshold). Debounced to one alert per issue per 2 minutes.
- **Connect window.** It finds the router, detects the self-signed certificate, checks the password once, and warns about remaining attempts before a lockout.
- **Settings.** Host, HTTPS and certificate trust, poll interval, alert thresholds, history retention, launch at login, and demo mode.
- **Demo mode.** A fictional mesh, with no network access, for screenshots and development.
- **Launch arguments** for screenshots and debugging: `--dashboard`, `--view spectrum`, `--select-node`, `--client-detail`, `--scan`, `--open-window`, `--open-menu`.
- **Docs.** README, [Architecture](ARCHITECTURE.md), [JNAP notes](JNAP.md), [Troubleshooting](TROUBLESHOOTING.md), and real screenshots.
- **CI.** GitHub Actions builds, tests and bundles on macOS.

### Router behaviour handled

- Pinnacle 2.2 firmware 1.2.4 refuses `core/Transaction` batches. MeshBar checks the password once, then uses single-action mode.
- Speed-test bandwidth is reported in kbit/s. Failed runs show as failed, not 0 Mbps.
- Satellite backhaul reads 0 while it re-measures. MeshBar shows *Measuring…* and does not alert.
- At most one poll is in flight. Refresh requests made during a poll collapse into one follow-up.

[0.1.0]: https://github.com/wileyadvanced/meshbar/releases/tag/v0.1.0
