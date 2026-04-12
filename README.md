# luci-app-qosify

LuCI web interface for [qosify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → qosify** menu with tabs for Overview, Config editing, Classification Rules, Advanced, and Status.

## Screenshots

### Overview
<img width="400" height="400" alt="Overview" src="https://github.com/user-attachments/assets/3a28b142-7377-4d9d-a84f-fb68137465ce" />

### Config
<img width="400" height="400" alt="Config" src="https://github.com/user-attachments/assets/52020192-1fb4-43c4-87e7-cc23a7525eb9" />

### Classification Rules
<img width="400" height="400" alt="Classification" src="https://github.com/user-attachments/assets/82806906-be31-45f6-96f2-e94b3e091622" />

### Advanced
<img width="400" height="400" alt="Advanced" src="https://github.com/user-attachments/assets/800f21b2-36b0-4c06-b5fd-14368941d8e9" />

### Status
<img width="400" height="400" alt="Status" src="https://github.com/user-attachments/assets/77170bb0-4558-44ed-afec-294d3fc6c820" />

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
- `wget` or `curl` (for download)

## Install

SSH into your router and run:

```sh
wget -O /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

Or with curl:

```sh
curl -o /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

The installer will:
1. Install `qosify` if not already present
2. Create the LuCI controller, view template, and default config files
3. Clear the LuCI cache and restart services

Once complete, navigate to **Network → qosify** in LuCI.

## Uninstall

```sh
/root/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app.

## Configuration

After install, go to the **Config** tab to set your WAN bandwidth and enable QoS. The default config ships with QoS **disabled** — you must set `disabled` to `0` and adjust `bandwidth_up` / `bandwidth_down` to match your connection. Alternatively, use the **Advanced** tab to upload pre-configured files for both `/etc/config/qosify` and `/etc/qosify/00-defaults.conf`.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/lib/lua/luci/controller/qosify.lua` | LuCI controller |
| `/usr/lib/lua/luci/view/qosify/main.htm` | LuCI view template (single-page) |

## Changelog

### v1.4 — 2025-04-12
- Added server-side file upload validation: rejects empty files, files >64KB, binary files
- UCI config upload validated for presence of `config` stanzas
- Rules file upload validated for correct `pattern class` line format per non-comment line
- Error messages from failed uploads shown in red banner with per-file detail
- Partial upload support: if one file passes and the other fails, the valid file is still applied
- Added `accept` attribute hints on file inputs to guide browser file picker toward text files
- Improved `setfilehandler` reliability — file handles now nil-reset on close to prevent stale state
- Action message banner now styled green (success) / red (error) for visibility
- Fixed tab resetting to Overview after banner auto-clear — GET redirect with `pathname+hash` preserves active tab without POST resubmission
- Install and reset now remove old config files before writing fresh defaults

### v1.3 — 2025-04-12
- Consolidated all tabs into a single controller function (`act()`) and single view template (`main.htm`)
- Removed separate CBI models and per-tab view files — entire LuCI app is now one controller + one template
- Client-side JavaScript tab switching (no page reload between tabs)
- URL hash persistence (`#overview`, `#config`, `#rules`, `#advanced`, `#status`) — active tab survives page refresh and form submissions
- AJAX auto-refresh on Status tab — polls `qosify-status` output every 5 seconds without full page reload
- Styled enable/disable toggle button with green/red outline indicating current state
- Version string uses `__VERSION__` placeholder in Lua heredoc, replaced by `sed` from the shell `$VERSION` variable
- File upload handling via `setfilehandler` for both UCI config and defaults files in a single form
- Action message auto-clears after 5 seconds via page refresh
- Reduced installed footprint: only 2 files deployed (controller + template) instead of multiple models/views

### v1.2 — 2025-04-12
- Fixed session invalidation: restart rpcd to force browser back to login page after install/uninstall
- Added luci-templatecache to cache clearing
- Dynamic interface cleanup on uninstall: reads WAN device from UCI, cleans all ifb devices
- Deduplicated cache/web-server restart into shared flush_luci() helper
- Version display updated to v1.2

### v1.1 — 2025-04-11
- Renamed tabs: Status → Overview, Stats → Status, Upload/Reset → Advanced
- Added version display (v1.1) to Overview tab
- Expanded Interface Configuration in Overview to show all `config interface wan` options
- Standardised all display text to use lowercase "qosify" throughout

### v1.0 — Initial Release
- Single-script installer (`qosify-luci.sh install|uninstall`)
- Auto-installs `qosify` via opkg or apk if missing
- LuCI controller with 5 tabs: Overview, Status, Config, Classification Rules, Advanced
- Overview tab: service state, full WAN interface config, enable/disable/start/stop/restart/reload controls, 5s auto-refresh
- Status tab: live `qosify-status` output with auto-refresh
- Config tab: inline editor for `/etc/config/qosify` with save & restart
- Classification Rules tab: inline editor for `/etc/qosify/00-defaults.conf`
- Advanced tab: file upload for both configs, factory reset to defaults
- Default DSCP classification rules: DNS/NTP → voice, SSH → +video, HTTP/QUIC → +besteffort
- Default classes: voice (CS6), video (AF41), besteffort (CS0), bulk (LE)
- Voice class includes bulk demotion (100 pps trigger)
- WAN interface ships disabled by default for safe first-run
- Full uninstall cleans up tc qdiscs, ifb devices, packages, configs, and LuCI cache

## License

MIT
