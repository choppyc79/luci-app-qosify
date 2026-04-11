# luci-app-qosify

LuCI web interface for [QoSify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → QoSify** menu with tabs for Status, Stats, Config editing, Classification Rules, and Upload/Reset.

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
- `wget` or `curl` (for download)

## Install

SSH into your router and run:

```sh
wget -O /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
sh /root/qosify-luci.sh install
```

Or with curl:

```sh
curl -o /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
sh /root/qosify-luci.sh install
```

The installer will:
1. Install `qosify` if not already present
2. Create the LuCI controller, views, and default config files
3. Clear the LuCI cache and restart services

Once complete, navigate to **Network → QoSify** in LuCI.

## Uninstall

```sh
sh /root/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app.

## Configuration

After install, go to the **Config** tab to set your WAN bandwidth and enable QoS. The default config ships with QoS **disabled** — you must set `disabled` to `0` in the Config tab and adjust `bandwidth_up` / `bandwidth_down` to match your connection. You can also import / upload previous qosify config and 00-defaults.conf files.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/lib/lua/luci/controller/qosify.lua` | LuCI controller |
| `/usr/lib/lua/luci/view/qosify/*.htm` | LuCI view templates |

## Changelog

### v1.1 — 2025-04-11
- Confirmed ash/busybox compatibility throughout
- Validated all heredocs use single-quoted delimiters to prevent variable expansion
- No functional changes from v1.0; codebase verified stable

### v1.0 — Initial Release
- Single-script installer (`qosify-luci.sh install|uninstall`)
- Auto-installs `qosify` via opkg or apk if missing
- LuCI controller with 5 tabs: Status, Stats, Config, Classification Rules, Upload/Reset
- Status tab: service state, WAN config summary, enable/disable/start/stop/restart/reload controls, 5s auto-refresh
- Stats tab: live `qosify-status` output with auto-refresh
- Config tab: inline editor for `/etc/config/qosify` with save & restart
- Classification Rules tab: inline editor for `/etc/qosify/00-defaults.conf`
- Upload/Reset tab: file upload for both configs, factory reset to defaults
- Default DSCP classification rules: DNS/NTP → voice, SSH → +video, HTTP/QUIC → +besteffort
- Default classes: voice (CS6), video (AF41), besteffort (CS0), bulk (LE)
- Voice class includes bulk demotion (100 pps trigger)
- WAN interface ships disabled by default for safe first-run
- Full uninstall cleans up tc qdiscs, ifb devices, packages, configs, and LuCI cache

## License

MIT
