# luci-app-qosify

LuCI web interface for [qosify](https://github.com/openwrt/qosify) on OpenWrt / ImmortalWrt.

qosify is a daemon that sets up and manages CAKE together with an eBPF classifier that marks DSCP fields. This app adds a **Network → qosify** page with tabs for Overview, Config, Rules, Status, Counters, and Advanced — every option maps to a real qosify UCI key or ubus parameter, nothing is invented.

The page is built from stock LuCI markup — `div.cbi-section` sections with `h3` titles, `.table` rows, `.label` badges, `.cbi-value` form rows, `.cbi-section-table` grids and `.cbi-progressbar` bars — and `qosify.css` draws each section as a box with a title bar using the theme's own colour variables. Option names on screen are the qosify UCI option names, except the Overview quick settings, which use plain labels with a short description under each field in qosify's own wording.

Current version: **3.7.10-dev**

## Tabs

### Overview
The **Service** section shows status (green while shaping, amber while running idle, red when stopped), uptime, autostart, how many interfaces are shaping, one row per interface or device from `ubus call qosify status` (active state, resolved device, ingress and egress) and `/etc/init.d/qosify`. Uptime is the qosify process's `starttime` from `/proc/<pid>/stat` set against `/proc/uptime`, read once per pid, so a reload keeps counting and a restart starts again. Enable/Disable Autostart, Start, Restart, Reload, Reload Rules and Stop sit in a bar at the bottom of the Overview tab; buttons that do not apply to the current state are disabled. **Reload** is the init script's `reload_service()`, a full `ubus call qosify config` push that re-sends `/etc/config/qosify` and re-reads the mapping files, ending in a device check. **Reload Rules** is `ubus call qosify reload`, which re-reads only the files in the `defaults` list (`qosify_map_reload()`) and leaves the qdiscs and interface config alone — what a rules edit needs, without the config push. **Files** is a single table whose column header is the box title bar, listing both config files with their validity, section or rule count, size and modification time. Service control goes through the `rc` ubus namespace, and a start or stop that does not take effect is reported as a failure rather than a silent no-op.

The **quick settings** write straight to the interface or device section in `/etc/config/qosify`, in one section titled with the section it edits (e.g. `interface wan quick settings`) holding four tabs with one Save & Apply bar under them: **Basic** (QoS Enabled with its state badge, writing `disabled` `0` when ticked and `1` when not; Interface, or Device for a `config device` section, `name`; Upload/Download bandwidth, `bandwidth_up`/`bandwidth_down`; Queueing mode `mode`, defaulting to `diffserv4` as in the shipped qosify config), **Shaping** (Download shaping `ingress`, Upload shaping `egress`, Automatic download rate `autorate_ingress`, NAT awareness `nat`, Host isolation `host_isolate`), **Overhead** (Overhead preset `overhead_type`, VLAN tags `overhead_vlan` 0–2, Manual overhead `overhead`, Minimum packet unit `overhead_mpu`, Encapsulation overhead `overhead_encap`) and **Advanced** (Ingress, Egress and Common CAKE options, `ingress_options`/`egress_options`/`options`, under a warning that bad options can stop qosify starting). The overhead presets are the `overhead_type` values `qosify.init` accepts; Manual overhead and Encapsulation overhead (`atm`, `noatm` or `ptm`) show only under `manual` and are dropped for any other type, since qosify ignores them. Each row puts the field and its hint on one line, hints aligned in a column and rows separated by the same faint line as the Service table, and each field is sized for its value — a byte count gets a small box, the CAKE option strings a long one. The open tab is kept when the section redraws after a save. None of `wash`, `triple-isolate`, `ack-filter`, `split-gso`, `rtt`, `memlimit` or `fwmark` is added for you; they go in the Advanced fields. Values are validated before writing: `overhead_mpu` and `overhead` must be whole numbers of bytes (`overhead` may be negative), option strings are checked for the shell metacharacters that would break the `tc` command qosify builds, and bandwidth is checked against `tc` rate syntax (including `unlimited`) but passed through with a warning rather than blocked, since `tc` is the authority. A failed read of `/etc/config/qosify` aborts the save instead of replacing the file, and a file that changed on disk since the page loaded prompts before being overwritten. The same two checks cover the Config editor: emptying it and saving truncates the file, so a save is refused when the file is non-empty on disk but the editor never loaded it, and the cleanup helper only runs once the daemon is confirmed stopped. It skips sections with `disabled 1`, as `qosify.init` does, and only removes the ifb device qosify derives from each enabled section, so a Stop never touches a device or ifb qosify did not create.

### Config
Inline editor for `/etc/config/qosify`, sized so the whole tab fits the window (refitted when the tab opens, a section folds or the window resizes) and draggable, the fit measured on the following animation frame so the tab being left is not counted, with three **Quick Add** sections, one per stanza group, each folding away on its own and laid out as LuCI section grids with the option names across the top (the class and interface forms start with the section type and name), that build `config defaults`, `config class`, `config alias`, `config interface`, and `config device` stanzas from constrained dropdowns — DSCP codepoints, CAKE overhead types, and diffserv modes only. Under each form a collapsible panel lists every option with its description from the qosify README. A folding **Reference** section lists the defined classes, the accepted DSCP values and the defaults qosify applies when a key is absent. Each section remembers whether it was open for the browser session.

The editor lints as you go and flags keys the daemon will silently drop — an interface section with no `name`, `nat` set without `host_isolate` (qosify only emits `nat`/`nonat` inside the host isolate branch), `overhead`/`overhead_encap` set while `overhead_type` is not `manual`, both directions disabled, missing bandwidth, shell metacharacters in values, and booleans that do not survive the daemon's conversion — `option nat 'true'` reaches qosify through `json_add_boolean`, which uses `!!atoi()`, so it means *off*.

### Rules
Editor for `/etc/qosify/00-defaults.conf`, laid out and sized like the Config tab. The folding **Quick Add** bar is a single row (`match`, value, `dscp`, `+` and Add, with each class listed alongside its DSCP value) and covers every qosify match type: `tcp:`, `udp:`, both, `dns:` patterns, `dns:/` regex, `dns_c:` CNAME-only patterns and regex, and IPv4/IPv6 addresses, with an "only if unset" toggle for the `+` prefix. Ports are range-checked to 1–65534 (qosify rejects 65535), `#` and whitespace are blocked in patterns, CIDR is rejected, and rule targets are checked against the classes actually defined in the UCI config. Raw DSCP values are read the way the daemon reads them (`strtoul` base 0, so `077` is 63) and flagged if ≥ 64. Lines with no DSCP target are reported as lines qosify will skip rather than blocking the save. Collapsible panels carry the mapping file syntax from the qosify README and the defined classes.

### Status
The detailed `qosify-status` output with CAKE qdisc statistics for egress and ingress; the per-interface summary is in the Overview Service section. The tab fetches as soon as it is opened and the scroll position survives a refresh. Polled at LuCI's refresh interval (`luci.main.pollinterval`, 5 seconds by default) and paused with LuCI's own refresh toggle, only while the tab is open — LuCI's poll loop skips a tick while the last one is still running.

### Counters
Always on the tab bar, and polled like the other tabs at LuCI's refresh interval while open. Nothing on this tab outlives the daemon — `get_stats` counts since the last reload and the tin figures come from qdiscs a stop removes — so while qosify is stopped the charts are cleared and every box but the notice is dropped, as on the Status tab, rather than leaving the last poll's numbers on screen looking live. With qosify running but `get_stats` returning nothing, the tab says so instead. The two traffic views come from different places and are not expected to match: **Traffic by Class** is qosify's own classifier statistics, **Traffic by CAKE Tin** is CAKE's queue statistics as `qosify-status` prints them.

**Traffic by Class** shows the per-class packet totals from `ubus call qosify get_stats` as a compact box with its header above the rows, as on DNS Entries: class, its `dscp`, a progress bar, then `packets`, `bytes` and share with grouped digits in right-aligned columns, and a total row. Bar length is the cube root of each row against the largest, so the biggest row fills the track and a row at 0.1% of it still shows at a tenth of the track, and a bulk download does not flatten everything else; the share column stays exact. Cells and bars are updated in place, so the bars ease to their new length and nothing below them moves. Each class is grouped and coloured by the CAKE tin its egress codepoint lands in, highest priority tin first and by codepoint within a tin, matching the tin bars: red bulk, blue best effort, yellow video and green voice, with the extra diffserv8 and precedence tins in their own colours. When the shaped sections do not share one mode, classes fall back to a colour per name. They are totals since qosify last reloaded, not rates, so nothing is lost while the tab is closed. **get_stats** lists `ebpf_map_entries`, `last_reload_time` and `dns_cache` where the running daemon reports them. The qosify OpenWrt 24.10 and 25.12 ship (`1501e09`) returns per-class packets only, and the tab shows just that.

**Traffic by CAKE Tin** graphs the `qosify-status` output shown on the Status tab as one chart: egress and ingress are summed tin by tin from the `pkts` and `bytes` rows `tc` prints, highest priority tin first, in the tin colours above, in the same boxed layout with `tc`'s own `pkts`, `bytes` and `drops` columns, and `marks` on hover. Qdiscs running a different CAKE mode, whose tins do not line up, get a table of their own. These are CAKE's counters for each qdisc since it was created, so they count what CAKE queued after any re-marking and firewall marks, not the rule a packet matched. `qosify-status` is forked once per tick only while qosify runs, and a tick where it fails keeps the last chart; it needs write access, as on the Status tab.

**DNS Entries** only appears when `get_stats` has a `dns` table (qosify `beeb87e`, OpenWrt snapshots); on 25.12 and 24.10 it stays hidden and `dump` is never called, and it appears by itself once a release or backport ships the newer qosify. It lists the `dns` entries from `ubus call qosify dump` with `hits`, `packets` and `bytes` from the `get_stats` `dns` table, under the field names qosify uses. Port and address entries are left out, because qosify keeps no per-entry counters for them. The section title carries the entry count, and the table sits in a box that can be dragged taller or shorter like the editors, with its header above the box rather than inside it, so no rows scroll under it; header and rows share fixed column widths, and the header is padded by the scrollbar width so they line up. The list is read on each tick after the counters; while its entries are unchanged only the figures are rewritten in place, so it does not redraw or move and a text selection holds.

### Advanced
**Backup** lists both files with size, modification time and a Download button. **Restore** is a file picker per file; Upload & Apply replaces the chosen files (validated, 64 KB cap, binary rejected). **Maintenance** has Check Devices, `ubus call qosify check_devices`, which re-runs the daemon's own `qosify_iface_check()`: each `config device` section is looked up with `if_nametoindex()` and each `config interface` section through netifd, then started if its device now exists and stopped if it has gone. It picks up a device that appeared after qosify started without rebuilding the qdiscs a restart would. The method arms a 10 ms uloop timer and returns an empty reply, so the call reports nothing itself — the page waits for the pass to run and then refreshes, and the result shows in the Service table on the Overview tab. **Defaults** resets both files back to qosify defaults after a confirmation.

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
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

If rpcd answers for none of the app's status calls — an ACL left behind by an older install, a session that predates it, or rpcd itself not running — the page reports **Unknown** instead of guessing. Status, Autostart, Shaping and `/etc/init.d/qosify` show an amber Unknown badge with one line naming the cause, the service buttons stay clickable so the failing call reports its own error, and a save says shaping could not be checked rather than warning that qosify is not shaping. Restarting rpcd after an upgrade (`/etc/init.d/rpcd restart`) is what the installer does at the end of an install.

## Configuration

The shipped config has QoS **disabled** for a safe first run. Set your WAN bandwidth in Quick Settings on the Overview tab and enable it there; no raw editing is needed for common setups. The Config and Rules tabs are there when you want full control, and the Advanced tab accepts pre-built files.

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
| `/www/luci-static/resources/view/qosify/qosify.css` | View stylesheet (section boxes, theme variables) |
| `/usr/share/qosify-luci/` | Default config templates, cleanup helper |
| `/lib/upgrade/keep.d/luci-app-qosify` | Sysupgrade keep list |

## Credits

This builds on the work of [@nbd168](https://github.com/nbd168), who authored [qosify](https://github.com/openwrt/qosify). This app only adds a web interface on top of qosify — it does not modify or fork the daemon, its init script, or its defaults, and every setting it exposes is a documented qosify option.

## License

MIT
