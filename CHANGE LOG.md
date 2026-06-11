## Changelog

### v2.5.0 — 2026-06-10
Full code audit against LuCI and qosify upstream sources.
- Saving no longer restarts qosify — config is reloaded in place, no traffic interruption
- Status checks moved to ubus — UI no longer hangs when qosify is stopped
- Fixed ACL permissions so the app works for non-root LuCI users
- Quick Settings data-loss fixes: manual overhead preserved, decimal bandwidths accepted, unknown values kept, checkboxes default to daemon defaults
- Quick Add Config defaults no longer writes an invalid list line
- Added besteffort and precedence queue modes
- Uninstall removes all CAKE qdiscs and IFB devices (BusyBox-safe)
- Styling now follows the active LuCI theme (light or dark)
- Smaller fixes: rules validated before save, backups download current files, local timestamps, tighter Quick Add validation

### v2.4.1 – v2.4.3
- Fixes from on-device testing
- Rolled back the v2.4.0 firstboot self-heal hook and restore action — sysupgrade survival kept to the simpler keep.d list plus installer copy

### v2.4.0 — 2026-05-31
- Added manual and docsis overhead types; separate Overhead Bytes and MPU fields with validation
- Class detection improved (alias sections, value fallback)
- Rules validated before save; fixed false "not shaping" warning after save
- BusyBox-safe IFB cleanup and root qdisc removal on uninstall
- Sysupgrade self-heal hook and restore action (later rolled back)

### v2.3.3 — 2026-05-27
- Added VA and DF DSCP codepoints
- Inline # comments handled correctly in rule counting and upload validation
- IPv4/IPv6 Quick Add rejects CIDR (qosify takes single addresses only)
- Defaults Quick Add offers class names alongside DSCP codepoints
- Sysupgrade survival: configs and installer preserved across upgrades

### v2.3.2 — 2026-04-29
- Rewritten as a modern JavaScript LuCI app — no Lua, no luci-compat needed
- Uploads, UCI access and service controls use standard LuCI APIs
- Auto-refresh via poll; notifications auto-dismiss
- Saves wait for qosify to come back up before refreshing
- All Overview sections refresh after save/upload/reset
- Old Lua files cleaned up on install

### v2.2 — 2025-04-17
- OpenWrt 25.12 compatibility (installs lua + luci-compat; no cache flushing)
- Detects "running but not shaping" (bad config) — amber warning instead of false green
- Post-save shaping check with warning banner
- Quick Add defaults gained dscp_bulk and bulk trigger options

### v2.1 — 2025-04-14
- Quick Add Config form — build defaults, class and interface stanzas from dropdowns
- Config Reference panel with live defaults and class details
- Quick Add Rule supports all qosify match types
- Corrected CAKE overhead type keywords
- AJAX service controls; much faster page loads
- Clear buttons, port validation, better banners and empty-config handling

### v2.0 — 2025-04-13
- Quick Settings form for all WAN options
- Live Active indicator and config file validation
- Quick Add Rule form and dynamic class reference
- Unsaved changes warning, Overview auto-refresh, backup downloads

### v1.4 — 2025-04-12
- Upload validation (size, binary, format) with per-file errors
- Active tab preserved after save

### v1.3 — 2025-04-12
- Single controller + template; client-side tabs with URL hash
- Status auto-refresh; green/red enable toggle

### v1.2 — 2025-04-12
- Session fix after install/uninstall; better uninstall cleanup

### v1.1 — 2025-04-11
- Tab renames; version shown on Overview

### v1.0 — Initial release
- Single-script installer with five tabs
- Installs qosify automatically; ships with QoS disabled for safe first run
- Full uninstall cleans qdiscs, IFBs, package and configs

## License

MIT
