# luci-app-qosify

LuCI web interface for [qosify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → qosify** menu with tabs for Overview, Config editing, Classification Rules, Advanced, and Status.

## Screenshots

### Overview


Service status, Quick Settings form, config file validation, and service controls at a glance.

### Config


Edit the UCI configuration (`/etc/config/qosify`) directly — set bandwidth, classes, interfaces, and queue options.

### Classification Rules


Edit DSCP classification rules (`/etc/qosify/00-defaults.conf`) — map ports, protocols, and DNS patterns to traffic classes. Includes a Quick Add form and dynamic DSCP class reference.

### Advanced


Backup current config files, upload replacements, or reset both configs back to defaults.

### Status


Live `qosify-status` output showing CAKE qdisc stats for egress and ingress, auto-refreshing every 5 seconds.

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

After install, use the **Quick Settings** form on the Overview tab to set your WAN bandwidth, enable QoS, and adjust common CAKE options — no raw config editing needed. The default config ships with QoS **disabled** for safe first-run.

For full control, the **Config** tab provides an inline editor for `/etc/config/qosify` (UCI classes, interfaces, queue options). The **Classification Rules** tab edits `/etc/qosify/00-defaults.conf` with a Quick Add form for appending port/DNS rules by class. Alternatively, use the **Advanced** tab to upload pre-configured files.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/lib/lua/luci/controller/qosify.lua` | LuCI controller |
| `/usr/lib/lua/luci/view/qosify/main.htm` | LuCI view template (single-page) |

## Changelog

### v2.0 — 2025-04-13
- **Quick Settings form** on Overview tab — edit all WAN interface options (QoS enable, bandwidth up/down, overhead type, queue mode, ingress, egress, NAT, host isolate, autorate ingress, ingress options, egress options, CAKE options) without touching raw config
- **QoS Active indicator** next to the QoS Enabled checkbox — shows green Active, amber Enabled but Not Active, or red Disabled based on live `qosify-status` output
- **Active status detection** — parses `qosify-status` for `: active` to distinguish process running from actually shaping traffic
- **Config file validation** on Overview — files now show Valid, Found (empty or invalid), or Missing with file size and last-modified timestamp
- **Quick Add Rule form** on Classification Rules tab — select type (tcp/udp/tcp+udp/dns), enter port or pattern, pick class from dropdown, optional priority (+) flag. Input validation for port numbers/ranges and DNS patterns
- **Dynamic DSCP class reference** on Classification Rules tab — collapsible panel auto-populated from `config class` entries in UCI config with ingress/egress DSCP codes. Default/fallback classes (referenced by `dscp_default_tcp`/`dscp_default_udp`) are excluded from dropdown and reference
- **Unsaved changes warning** on Config and Classification Rules tabs — prompts before tab switch or page close if textarea content has been modified
- **Auto-refresh Overview** every 30 seconds — AJAX updates Service Status and Configuration Files sections without disrupting Quick Settings form
- **Backup download buttons** on Advanced tab — download current `/etc/config/qosify` and `00-defaults.conf` as local files before uploading or resetting
- **Confirm dialogs** on all destructive actions — Config save, Rules save, Upload, Reset
- **Upload banner** now names which files were uploaded (e.g. `/etc/config/qosify & 00-defaults.conf uploaded, qosify restarted.`)
- **Option name normalisation** — reads both `overhead_type`/`overhead` and `options`/`option` from UCI; on save, writes canonical names and deletes alternates to prevent config duplication after upload
- **Improved error banner detection** — catches `error` anywhere in message text, not just `Upload error` prefix
- Removed Interface Configuration section (replaced by editable Quick Settings)
- Version bumped to 2.0

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
