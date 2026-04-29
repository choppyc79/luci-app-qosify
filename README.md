# luci-app-qosify

LuCI web interface for [qosify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → qosify** menu with tabs for Overview, Config editing, Classification Rules, Advanced, and Status.

## Screenshots

### Overview
Service status, Quick Settings form, config file validation, and service controls at a glance.

### Config
Edit the UCI configuration (`/etc/config/qosify`) directly — set bandwidth, classes, interfaces, and queue options. Includes a Config Reference panel showing all stanza types and current class details, plus a Quick Add Config form for building `config defaults`, `config class`, and `config interface` stanzas from dropdowns.

### Classification Rules
Edit DSCP classification rules (`/etc/qosify/00-defaults.conf`) — map ports, protocols, IPs, and DNS patterns to traffic classes. Includes a Quick Add form supporting all qosify match types and an Available Classes reference.

### Advanced
Backup current config files, upload replacements, or reset both configs back to defaults.

### Status
Live `qosify-status` output showing CAKE qdisc stats for egress and ingress, auto-refreshing every 5 seconds.

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
- `wget` or `curl` (for download)
- `luci-base` (preinstalled with LuCI)

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
2. Drop the LuCI menu entry, ACL definition, and JS view into the standard LuCI paths
3. Create default config files
4. Restart rpcd and the web server so the new menu appears

Once complete, navigate to **Network → qosify** in LuCI.

## Uninstall

```sh
/root/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app. `luci-base` is left in place.

## Configuration

After install, use the **Quick Settings** form on the Overview tab to set your WAN bandwidth, enable QoS, and adjust common CAKE options — no raw config editing needed. The default config ships with QoS **disabled** for safe first-run.

For full control, the **Config** tab provides an inline editor for `/etc/config/qosify` with a Quick Add Config form for building class, defaults, and interface stanzas from dropdowns — all options are constrained to valid values (DSCP codepoints, CAKE overhead types, diffserv modes). The **Classification Rules** tab edits `/etc/qosify/00-defaults.conf` with a Quick Add form supporting all qosify match types (tcp/udp ports, DNS patterns, DNS regex, IPv4/IPv6 addresses). Alternatively, use the **Advanced** tab to upload pre-configured files.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/share/luci/menu.d/luci-app-qosify.json` | LuCI menu entry |
| `/usr/share/rpcd/acl.d/luci-app-qosify.json` | rpcd ACL grants |
| `/www/luci-static/resources/view/qosify/main.js` | LuCI JS view (single-page) |
| `/usr/share/qosify-luci/` | Default config templates (used by the Reset button) |

## Changelog

### v2.3.2 — 2026-04-29
- **Modern JS-based LuCI app** — full rewrite from the legacy Lua controller + `.htm` template architecture to the client-side JS view shape used by current LuCI. UI lives in one `main.js` under `/www/luci-static/resources/view/qosify/`, menu entry is a JSON file under `/usr/share/luci/menu.d/`, permissions are a JSON ACL under `/usr/share/rpcd/acl.d/`. Same shape as `luci-app-firewall` and other recent official apps.
- **No more `luci-compat` dependency** — only `luci-base` is needed now.
- **File uploads handled client-side** — `FileReader` reads and validates locally, then `fs.write` writes through rpcd. No multipart POST, no CSRF/`setfilehandler` issues.
- **UCI accessed via the proper API** — `uci.load` / `uci.get` / `uci.sections` / `uci.set` / `uci.save` / `uci.apply`, no more text parsing or shelling out to `uci -q get`.
- **Service controls via `ubus call luci setInitAction`** — canonical way to drive init scripts from a LuCI app.
- **`poll.add()` for auto-refresh** — Status every 5s, Overview every 30s, pauses when the tab is hidden.
- **Notifications auto-dismiss** — info 5s, warning 8s, danger 10s.
- **Save/Upload/Reset wait for qosify to come back up** — polls `/etc/init.d/qosify running` until ready (up to 4s) before refreshing the UI, instead of a fixed sleep that could miss the daemon's startup.
- **Quick Settings, Service Controls and Service Status all refresh after save/upload/reset** — form fields and toggle buttons reflect the new on-disk state, no stale closures.
- **Legacy Lua paths cleaned on install** — upgrading from v2.2 leaves no stale `/usr/lib/lua/luci/...` files behind.

### v2.2 — 2025-04-17
- **OpenWrt 25.12 compatibility** — installer now installs `lua` and `luci-compat` alongside `qosify`, fixing `uhttpd` error `Lua controller present but no Lua runtime installed` on default 25.12 images where the Lua runtime is not preinstalled
- **No more cache flushing** — `flush_luci()` replaced with `restart_luci_services()`: restarts `rpcd` and `uhttpd`/`nginx` and asks uhttpd to reload over ubus, without purging `/tmp/luci-*` caches. Cache flushing was causing issues on OpenWrt 25.12
- **Invalid config detection** — previously if `/etc/config/qosify` contained a syntax error (e.g. missing closing quote), qosify would restart but silently fail to shape traffic and the banner still showed green. Now the Overview Running row shows amber "Running — Not Shaping" and the QoS Enabled badge shows "Enabled — Not Shaping (check config)" when the process is up but `qosify-status` reports no CAKE qdisc
- **Amber post-save warnings** — Config, Rules, and Quick Settings saves now check `qosify-status` after restart. If WAN is enabled but qosify is not shaping, the banner turns orange with "Warning: ... but qosify is not shaping traffic — check config for syntax errors" instead of the misleading green success banner
- **Config defaults — missing options added** — Quick Add Config `config defaults` stanza now offers `dscp_bulk`, `bulk_trigger_pps`, and `bulk_trigger_timeout` (all the class-level options except `ingress`/`egress` DSCP). Config Reference panel updated to list and display these values too
- **Config defaults — `+` prefix removed** — the `+` DSCP priority-override prefix is only meaningful in classification rules (`00-defaults.conf`), so the checkbox is now only on Classification Rules Quick Add, not Config Quick Add
- **Active detection improved** — now matches `qdisc cake`, `: active`, or plain `cake` in `qosify-status` output to reliably detect shaping across qosify versions
- Version bumped to 2.2

### v2.1 — 2025-04-14
- **Quick Add Config** on Config tab — build `config defaults`, `config class`, and `config interface` stanzas from dropdowns. Stanza type selector shows only the options valid for that type; all values constrained to valid choices (DSCP codepoints, CAKE overhead types, diffserv modes, 0/1 booleans). No free-text where a defined set exists
- **Config Reference** on Config tab — collapsible panel showing all stanza types with their available options, plus live view of current defaults and all class details (ingress/egress, dscp_prio, dscp_bulk, prio_max_avg_pkt_len, bulk_trigger_pps, bulk_trigger_timeout)
- **Expanded Quick Add Rule** on Classification Rules tab — now supports all qosify match types: tcp/udp/tcp+udp ports, DNS patterns, DNS regex, dns_c patterns, dns_c regex, IPv4 addresses, IPv6 addresses. Dynamic placeholder hints per type
- **CAKE overhead types fixed** — replaced incorrect values (pppoe, pppoa, docsis, atm) with correct CAKE keywords (pppoe-ptm, bridged-ptm, pppoe-vcmux, pppoe-llcsnap, pppoa-vcmux, pppoa-llc, bridged-vcmux, bridged-llcsnap, ipoa-vcmux, ipoa-llcsnap, conservative)
- **All classes shown** — Config Reference and Classification Rules now show all classes including those referenced by dscp_default_tcp/udp
- **Clear buttons** on Config and Classification Rules tabs — clear the editor for building config from scratch via Quick Add. Config clear also resets Quick Settings form on Overview
- **AJAX service controls** — start/stop/restart/reload/enable/disable now use background requests instead of full page reloads
- **UCI parser** — replaced ~70 subprocess calls (`uci -q get` per field per class) with a single Lua text parser. Significant page load speed improvement on low-end routers
- **Port validation** — Quick Add Rule now validates port numbers are within 1–65535
- **Save config validation** — non-empty config saves checked for valid UCI stanzas; empty saves allowed (intentional clear) and stop qosify
- **WAN section guard** — Quick Settings save auto-creates the WAN interface section if config was cleared/missing
- **Banner timing** — success messages auto-clear after 5s, errors after 10s; Overview auto-refresh clears any remaining banner
- **Resilient AJAX refresh** — no longer redirects to LuCI root if a selector is momentarily missing during qosify restart
- **Empty config handling** — Quick Settings correctly shows all fields blank/unchecked and dropdowns as `--` when no config exists
- Removed dead code (filtered class list, skip logic, duplicate file reads)
- Version bumped to 2.1

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
