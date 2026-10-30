# Troubleshooting

When something looks wrong, start with **Refresh** (⌘R in the menu). MeshBar polls one request at a time, so clicking it repeatedly does not load the router.

## "The router's HTTPS certificate is self-signed"

Linksys routers serve HTTPS with a self-signed certificate. When **Connect** sees this, it trusts the certificate for that host only and tells you so. If you entered the host in Settings by hand instead, turn on **Settings → Trust this host's certificate**.

MeshBar never trusts self-signed certificates in general. Only the configured router host is trusted.

## Password errors

| Message | What it means | What to do |
| --- | --- | --- |
| *The router rejected the username or password (_ErrorUnauthorized).* | The admin password is wrong. The username is always `admin`. | Use the password from the Linksys app (**Router settings → Router password**), not the Wi-Fi password. |
| *The router has paused admin logins after too many wrong passwords.* | The router locked out admin logins for a while. | Wait the time shown (about 5 minutes if the router doesn't say). Then try once. Retrying during the lockout extends it. |
| *The router refused part of the status request (_ErrorUnauthorized).* | Pinnacle firmware sometimes refuses a whole batch even with the right password (see [JNAP.md](JNAP.md#pinnacle-refuses-whole-batches)). | Nothing to do. MeshBar checks the password once and then asks action by action. If the password checks out, the error goes away on the next poll. |

The Connect window shows how many attempts the router has left before a lockout, when the router reports it. It reads this through an unauthenticated status call, so checking doesn't use up an attempt.

## "The router returned something that was not JNAP JSON"

The router sent back an HTML page or an empty body instead of a JNAP reply. This usually happens for a few seconds to a minute while radios restart:

- after a channel or setting change in the Linksys app,
- after a DFS radar event moves a 5 GHz radio,
- while a node reboots or a firmware update installs.

Wait for the next poll. If it persists:

- check the host in Settings: it must be the **master** router (usually `192.168.1.1`), not a satellite or your ISP modem;
- try opening `https://192.168.1.1/` in a browser to see whether the router web UI loads.

## Backhaul shows "Measuring…"

The satellite reported a backhaul speed of 0. Right after a refresh, MeshBar asks the master to re-measure satellite links (`RefreshSlaveBackhaulData`, at most every 5 minutes, or when you click Refresh). For a few seconds to a minute, the router reports 0 while it measures. MeshBar shows *Measuring…* and sends no weak-link alert.

If a node stays on *Measuring…* for several minutes, it may have just rejoined. Check that it's online and its light is solid.

## Spectrum: "Scan from this Mac" shows no network names

macOS only tells apps the names (SSIDs) of nearby networks if the app may use Location. MeshBar asks the first time you scan from this Mac. If you said no, open **System Settings → Privacy & Security → Location Services** and enable **MeshBar**.

Without it, channels and signal strength are still real; the networks just show without names. MeshBar never reads or stores your location.

**Scan at router** doesn't need Location. It uses the router's own site survey, at most once a minute.

## Keychain prompts

The router password is stored in your login Keychain (service `com.meshbar.app.router-password`).

- **"MeshBar wants to use your confidential information…"**: macOS asks this when a newly built or downloaded copy of the app reads the item for the first time. Click **Always Allow**.
- If you build from source, `scripts/bundle.sh` signs ad-hoc with a fixed identifier (`com.meshbar.app`), so rebuilt copies are normally recognised. A `swift run` binary is not the same app, and it will ask again.
- To remove the password, use the **Forget** button in the Connect window, or delete the item in Keychain Access.

## "MeshBar can't be opened because Apple cannot check it"

Release builds are ad-hoc signed, not notarized. **Right-click → Open** once, or allow it in **System Settings → Privacy & Security → Open Anyway**.

## Launch at login doesn't stick

Launch at login uses `SMAppService` and only works for the bundled `MeshBar.app`, not for `swift run`. Move the app to `/Applications` first, so the login item doesn't point at a build folder. Toggle it in Settings and check **System Settings → General → Login Items**.

## Still stuck

Open an issue with:

- your router model and firmware (shown in the dashboard header),
- the exact message,
- any `[MeshBar]` lines printed when you run `MeshBar.app/Contents/MacOS/MeshBar` from Terminal. They name fields only, never values or passwords.

Please don't attach raw JNAP captures. They contain MAC addresses, serials and your Wi-Fi configuration.
