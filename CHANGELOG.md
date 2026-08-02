# Changelog

All notable changes to `luci-app-qosify`. Versions are the `VERSION=` constant in `qosify-luci.sh`.

## v2.8.7 — 2026-08-02

- Device sections no longer prefill the name field — a netdev name must be entered deliberately
- Quick Settings shows a Device Name row with an inline "required" hint; qosify skips any section with no name

## v2.8.6 — 2026-08-01

- Fixed an undefined helper (`qv()`) that broke Quick Settings rendering on some pages
- Class label and description helpers routed through i18n
- Save validates the interface/device name before writing

## v2.8.3 – v2.8.5 — 2026-07-31

Audit pass against upstream `qosify.init` and the daemon C sources.

- Alias sections are now treated as classes, matching `qosify.init`, which runs `add_class` over both `class` and `alias`
- Port ceiling corrected to 65534 — `qosify_map_set_port` rejects an end port of 65535
- IPv6 `%zone` syntax removed from Quick Add — `inet_pton` rejects it
- `#` blocked in DNS patterns — the loader truncates at `#`
- Rule linting accepts hex DSCP values (`strtoul` base 0) and flags anything ≥ 64
- Refreshing classes now rebuilds the `dscp_*` dropdowns in Quick Add Config
- ACL corrected: `exec` entries and `luci setInitAction` moved from the read group to the write group

## v2.8.2 — 2026-07-31

Large validation and reference overhaul.

- Config linting flags keys the daemon will silently drop: missing `name`, `nat` set without `host_isolate`, `overhead`/`overhead_encap` without `overhead_type manual`, both directions disabled, missing bandwidth, and quotes inside values
- Rule targets checked against the classes actually defined in `/etc/config/qosify`
- Quick Settings writes are validated before save — bandwidth format, whole-number overhead, and option strings restricted to characters qosify accepts
- Config Reference panel documents every stanza type (`defaults`, `class`, `alias`, `interface`, `device`) and states the defaults qosify applies when a key is absent
- Quick Add Rule gained an "only if unset" toggle for the `+` prefix
- Quick Add Config refuses duplicate section names and a second `config defaults`
- Post-save shaping check distinguishes "applied", "applied, QoS disabled", and "saved but not shaping"
- Editors warn when reloaded from disk with unsaved changes

## v2.5.6 – v2.5.7 — 2026-07-31

- Version constant dropped from the view — the installer is the single source of truth
- Minor installer tidy-up

## v2.5.5 — 2026-07-16

- Full translation support — all user-visible strings wrapped for LuCI's i18n system
- Submitted to the official OpenWrt LuCI feed (openwrt/luci pull request)
- No functional changes

## v2.5.4 — 2026-07-16

- New `files` install mode — writes only the app files, no package manager operations and no service restarts
- Enables ImageBuilder / custom firmware builds: bake `qosify` in via PACKAGES and run `qosify-luci.sh files` from a uci-defaults firstboot script

## v2.5.1 – v2.5.3 — 2026-06-11

- Save & Apply restarts qosify so config changes reliably take effect
- Cleanup helper removes leftover CAKE qdiscs and IFB devices on service stop and config clear
- Sysupgrade survival: keep.d list expanded to cover all app files
- LuCI caches cleared on install and uninstall so menu changes appear immediately, without forcing a logout
- Overhead Type defaults to none; stale file-type filter removed from rules upload
- BusyBox-safe IFB sweep (glob matching) in uninstall and the cleanup helper

## v2.5.0 — 2026-06-10

Full code audit against LuCI and qosify upstream sources.

- Saving reloads config in place instead of restarting — no traffic interruption
- Status checks moved to ubus — the UI no longer hangs when qosify is stopped
- ACL permissions fixed so the app works for non-root LuCI users
- Quick Settings data-loss fixes: manual overhead preserved, decimal bandwidths accepted, unknown values kept, checkboxes default to daemon defaults
- Quick Add Config defaults no longer writes an invalid list line
- Added besteffort and precedence queue modes
- Uninstall removes all CAKE qdiscs and IFB devices (BusyBox-safe)
- Styling follows the active LuCI theme, light or dark
- Smaller fixes: rules validated before save, backups download current files, local timestamps, tighter Quick Add validation

## v2.4.1 – v2.4.3 — 2026-06-05

- Fixes from on-device testing
- Rolled back the v2.4.0 firstboot self-heal hook and restore action — sysupgrade survival kept to the simpler keep.d list plus installer copy

## v2.4.0 — 2026-05-31

- Added manual and docsis overhead types; separate Overhead Bytes and MPU fields with validation
- Class detection improved (alias sections, value fallback)
- Rules validated before save; fixed a false "not shaping" warning after save
- BusyBox-safe IFB cleanup and root qdisc removal on uninstall
- Sysupgrade self-heal hook and restore action (later rolled back)

## v2.3.3 — 2026-05-27

- Added VA and DF DSCP codepoints
- Inline `#` comments handled correctly in rule counting and upload validation
- IPv4/IPv6 Quick Add rejects CIDR — qosify takes single addresses only
- Defaults Quick Add offers class names alongside DSCP codepoints
- Sysupgrade survival: configs and installer preserved across upgrades

## v2.3.2 — 2026-04-29

- Rewritten as a modern JavaScript LuCI app — no Lua, no luci-compat needed
- Uploads, UCI access and service controls use standard LuCI APIs
- Auto-refresh via poll; notifications auto-dismiss
- Saves wait for qosify to come back up before refreshing
- All Overview sections refresh after save, upload or reset
- Old Lua files cleaned up on install

## v2.2 — 2025-04-17

- OpenWrt 25.12 compatibility (installs lua + luci-compat; no cache flushing)
- Detects "running but not shaping" and shows an amber warning instead of a false green
- Post-save shaping check with warning banner
- Quick Add defaults gained dscp_bulk and bulk trigger options

## v2.1 — 2025-04-14

- Quick Add Config form — build defaults, class and interface stanzas from dropdowns
- Config Reference panel with live defaults and class details
- Quick Add Rule supports all qosify match types
- Corrected CAKE overhead type keywords
- AJAX service controls; much faster page loads
- Clear buttons, port validation, better banners and empty-config handling

## v2.0 — 2025-04-13

- Quick Settings form for all WAN options
- Live Active indicator and config file validation
- Quick Add Rule form and dynamic class reference
- Unsaved changes warning, Overview auto-refresh, backup downloads

## v1.4 — 2025-04-12

- Upload validation (size, binary, format) with per-file errors
- Active tab preserved after save

## v1.3 — 2025-04-12

- Single controller and template; client-side tabs with URL hash
- Status auto-refresh; green/red enable toggle

## v1.2 — 2025-04-12

- Session fix after install and uninstall; better uninstall cleanup

## v1.1 — 2025-04-11

- Tab renames; version shown on Overview

## v1.0 — 2025-04-11

- Initial release: single-script installer with five tabs
- Installs qosify automatically; ships with QoS disabled for a safe first run
- Full uninstall cleans qdiscs, IFBs, package and configs
