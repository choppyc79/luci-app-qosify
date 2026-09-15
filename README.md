# Development for Snapshot only
# luci-app-qosify

LuCI web interface for [qosify](https://github.com/openwrt/qosify) on OpenWrt / ImmortalWrt.

qosify is a daemon that sets up and manages CAKE together with an eBPF classifier that marks DSCP fields. This app adds a **Network → qosify** page with tabs for Overview, Config, Classification Rules, Status, Counters, and Advanced — every option maps to a real qosify UCI key or ubus parameter, nothing is invented.

Current version: **3.2.1-dev**

## Tabs

### Overview
Service status badge (Active / Enabled — Not Shaping / Not Running / Disabled), start/stop/restart/reload controls, autostart toggle, qosify uptime, and config file validation with size, mtime, and rule count. Uptime is measured from the process start in `/proc/<pid>/stat` against `/proc/uptime`, both on the boot clock, so it survives a reload, resets on a restart and is not thrown off by an NTP step. Service control goes through the `rc` ubus namespace, and a start or stop that does not take effect is reported as a failure rather than a silent no-op.

The **Quick Settings** form writes straight to the interface or device section in `/etc/config/qosify`: bandwidth up/down, overhead type and bytes, queue mode, ingress, egress, NAT, host isolate, autorate ingress, and the ingress/egress/shared CAKE option strings. Values are validated before writing: overhead must be a whole number of bytes, option strings are checked for the shell metacharacters that would break the `tc` command qosify builds, and bandwidth is checked against `tc` rate syntax (including `unlimited`) but passed through with a warning rather than blocked, since `tc` is the authority. A failed read of `/etc/config/qosify` aborts the save instead of replacing the file, and a file that changed on disk since the page loaded prompts before being overwritten. The same two checks cover the Config editor: emptying it and saving truncates the file, so a save is refused when the file is non-empty on disk but the editor never loaded it, and the cleanup helper only runs once the daemon is confirmed stopped. It skips sections with `disabled 1`, as `qosify.init` does, and only removes the ifb device qosify derives from each enabled section, so a Stop never touches a device or ifb qosify did not create.

### Config
Inline editor for `/etc/config/qosify`, sized to the window height and draggable, with a **Quick Add Config** form that builds `config defaults`, `config class`, `config alias`, `config interface`, and `config device` stanzas from constrained dropdowns — DSCP codepoints, CAKE overhead types, and diffserv modes only. A Config Reference panel documents every stanza type, lists the currently defined classes, and states the defaults qosify applies when a key is absent.

The editor lints as you go and flags keys the daemon will silently drop — an interface section with no `name`, `nat` set without `host_isolate` (qosify only emits `nat`/`nonat` inside the host isolate branch), `overhead`/`overhead_encap` set while `overhead_type` is not `manual`, both directions disabled, missing bandwidth, shell metacharacters in values, and booleans that do not survive the daemon's conversion — `option nat 'true'` reaches qosify through `json_add_boolean`, which uses `!!atoi()`, so it means *off*.

### Classification Rules
Editor for `/etc/qosify/00-defaults.conf`. The **Quick Add Rule** form covers every qosify match type: `tcp:`, `udp:`, both, `dns:` patterns, `dns:/` regex, `dns_c:` CNAME-only patterns and regex, and IPv4/IPv6 addresses, with an "only if unset" toggle for the `+` prefix. Ports are range-checked to 1–65534 (qosify rejects 65535), `#` and whitespace are blocked in patterns, CIDR is rejected, and rule targets are checked against the classes actually defined in the UCI config. Raw DSCP values are read the way the daemon reads them (`strtoul` base 0, so `077` is 63) and flagged if ≥ 64. Lines with no DSCP target are reported as lines qosify will skip rather than blocking the save.

### Status
A per-interface summary from `ubus call qosify status` — active state, resolved device, ingress and egress — followed by the detailed `qosify-status` output with CAKE qdisc statistics for egress and ingress. The tab fetches as soon as it is opened, the summary appears before the `tc` output it does not depend on, and the scroll position survives a refresh. The output box fills the page height and can be dragged taller. Polled at LuCI's refresh interval (`luci.main.pollinterval`, 5 seconds by default) and paused with LuCI's own refresh toggle, only while the tab is open — a tick that would overlap a still-running `qosify-status` is skipped rather than queued.

### Counters
Always on the tab bar, and polled like the other tabs at LuCI's refresh interval while open. The two traffic views come from different places and are not expected to match: **Traffic by Class** is qosify's own classifier statistics, **Traffic by CAKE Tin** is CAKE's queue statistics as `qosify-status` prints them.

**Traffic by Class** shows the per-class packet totals from `ubus call qosify get_stats` as bars with exact packets, bytes and share beside each bar and a total row. Bar length is the cube root of each row against the largest, so the biggest row fills the track and a row at 0.1% of it still shows at a tenth of the track, and a bulk download does not flatten everything else; the share column stays exact. Each class is grouped and coloured by the CAKE tin its egress codepoint lands in, highest priority tin first and by codepoint within a tin, matching the tin bars: red bulk, blue best effort, yellow video and green voice, with the extra diffserv8 and precedence tins in their own colours. When the shaped sections do not share one mode, classes fall back to a colour per name. Notes appear when ingress is classified but not shaped, or when `fwmark` lets firewall marks choose the tin. They are totals since qosify last reloaded, not rates, so nothing is lost while the tab is closed. **Daemon** lists the eBPF IP map entry count, last reload time and DNS cache figures where the running daemon reports them. The qosify OpenWrt 24.10 ships returns per-class packets only, and the tab shows just that.

**Traffic by CAKE Tin** graphs the `qosify-status` output shown on the Status tab as one chart: egress and ingress are summed tin by tin from the `pkts` and `bytes` rows `tc` prints, highest priority tin first, in the tin colours above, with the qdiscs it covers listed underneath. Qdiscs running a different CAKE mode, whose tins do not line up, get a chart of their own. A tin with drops shows the count beside its name, and hovering a bar adds drops and ECN marks. These are CAKE's counters for each qdisc since it was created, so they count what CAKE queued after any re-marking and firewall marks, not the rule a packet matched. `qosify-status` is forked once per tick only while qosify runs, and a tick where it fails keeps the last chart; it needs write access, as on the Status tab, so a read-only session sees a note in its place.

**Map Entries** lists the DNS patterns from `ubus call qosify dump` with the hits, packets and bytes from the `get_stats` `dns` table. Port and address entries are left out, because qosify keeps no per-entry counters for them. The list is read on each tick after the counters; while its entries are unchanged only the traffic and timeout figures are rewritten in place, so the box does not redraw or move, and the scroll position and any text selection hold.

### Advanced
Download the current config files as a backup, upload replacements (validated, 64 KB cap, binary rejected), or reset both files back to qosify defaults.

## Requirements

- OpenWrt 22.03+ (snapshot only with latest qosify) with LuCI
- `luci-base` (preinstalled with LuCI) — the app uses the `rc` ubus namespace from the rpcd core, so nothing extra is needed
- `wget` or `curl` to fetch the installer

## Install

```
wget -O /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/dev/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

Or with curl:

```
curl -o /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/dev/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

The installer installs `qosify` via apk or opkg if missing, writes the menu entry, ACL, and JS view to the standard LuCI paths, seeds default configs without overwriting existing ones, registers the app in `/lib/upgrade/keep.d/`, and restarts rpcd and the web server. Then open **Network → qosify** (Ctrl+F5 first).

## Commands

| Command | Action |
| --- | --- |
| `install` | Full install — package, files, configs, service restart |
| `files` | App files only, no package operations and no service restarts |
| `reset` | Restore both config files to qosify defaults and restart |
| `uninstall` | Remove the app, qosify, configs, and qosify's own leftover qdiscs |

## ImageBuilder / custom firmware builds

Use `files` mode. Include `qosify` in your package list, place the installer in `files/root/`, and add `files/etc/uci-defaults/99-qosify-luci`:

```
#!/bin/sh
/root/qosify-luci.sh files
exit 0
```

## Sysupgrade

The app registers every file it owns, including the stylesheet, in `/lib/upgrade/keep.d/luci-app-qosify`, so it survives sysupgrade — including attended sysupgrade and owut — with no runtime hooks or self-healing logic.

## Read-only access

A session with only *read* access to the `luci-app-qosify` ACL group gets a read-only page: the editors, Quick Add forms and service controls are disabled rather than offered and failing with a permission error. Backup downloads and the Counters tab stay available, apart from Traffic by CAKE Tin, which needs the `qosify-status` exec grant.

## Configuration

The shipped config has QoS **disabled** for a safe first run. Set your WAN bandwidth in Quick Settings on the Overview tab and enable it there; no raw editing is needed for common setups. The Config and Classification Rules tabs are there when you want full control, and the Advanced tab accepts pre-built files.

## Translations

All user-visible strings go through LuCI's i18n system, so the app translates like any official LuCI app. The template is `po/templates/qosify.pot`, generated with the upstream `i18n-scan.pl`.

## Files

| File | Purpose |
| --- | --- |
| `/etc/config/qosify` | UCI config (defaults, classes, interfaces, devices) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/share/luci/menu.d/luci-app-qosify.json` | LuCI menu entry |
| `/usr/share/rpcd/acl.d/luci-app-qosify.json` | rpcd ACL grants |
| `/www/luci-static/resources/view/qosify/main.js` | LuCI JS view (single page) |
| `/www/luci-static/resources/view/qosify/qosify.css` | View stylesheet (theme variables, no inline styles) |
| `/usr/share/qosify-luci/` | Default config templates, cleanup helper |
| `/lib/upgrade/keep.d/luci-app-qosify` | Sysupgrade keep list |

## Credits

This builds on the work of [@nbd168](https://github.com/nbd168), who authored [qosify](https://github.com/openwrt/qosify). This app only adds a web interface on top of qosify — it does not modify or fork the daemon, its init script, or its defaults, and every setting it exposes is a documented qosify option.

## License

MIT
