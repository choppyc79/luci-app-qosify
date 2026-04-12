# luci-app-qosify

LuCI web interface for [qosify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → qosify** menu with tabs for Overview, Config, Classification Rules, Advanced, and Status.

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
2. Create the LuCI controller, views, and default config files
3. Clear the LuCI cache and restart services

Once complete, navigate to **Network → qosify** in LuCI.

## Uninstall

```sh
/root/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app.

## Tabs

### Overview

Service status, WAN interface configuration, config file health, and service controls (enable/disable, start, stop, restart, reload). The enable/disable toggle shows green when enabled and red when disabled.

![Overview tab](screenshots/overview.png)

### Config

Inline editor for `/etc/config/qosify` — UCI classes, interfaces, and defaults. Changes are saved and qosify is restarted on apply.

![Config tab](screenshots/config.png)

### Classification Rules

Inline editor for `/etc/qosify/00-defaults.conf` — DSCP mapping rules loaded by qosify on startup.

![Classification Rules tab](screenshots/rules.png)

### Advanced

Upload replacement config files for both `/etc/config/qosify` and `/etc/qosify/00-defaults.conf`, or reset everything to factory defaults.

![Advanced tab](screenshots/advanced.png)

### Status

Live `qosify-status` output with 5-second auto-refresh (only when qosify is running).

![Status tab](screenshots/status.png)

## Configuration

After install, go to the **Config** tab to set your WAN bandwidth and enable QoS. The default config ships with QoS **disabled** — you must set `disabled` to `0` and adjust `bandwidth_up` / `bandwidth_down` to match your connection. Alternatively, use the **Advanced** tab to upload pre-configured files for both `/etc/config/qosify` and `/etc/qosify/00-defaults.conf`.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/lib/lua/luci/controller/qosify.lua` | LuCI controller |
| `/usr/lib/lua/luci/view/qosify/*.htm` | LuCI view templates |

## Changelog

### v1.3 — 2025-04-12
- Removed config duplication: single `install_defaults` function used by both install and reset (via `reset` command)
- Removed standalone `reset_defaults.sh`; reset action now calls `qosify-luci.sh reset`
- LuCI improvements: fainter table borders and wider row spacing to match LuCI overview style
- Enable/disable button styled with green outline when enabled, red when disabled (matches System → Startup)
- Status tab moved to last position in tab bar
- Added `reset` subcommand to script usage

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
