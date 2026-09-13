# Development for Snapshot only
# luci-app-qosify

LuCI web interface for [qosify](https://github.com/openwrt/qosify) on OpenWrt / ImmortalWrt.

qosify is a daemon that sets up and manages CAKE together with an eBPF classifier that marks DSCP fields. This app adds a **Network → qosify** page with tabs for Overview, Config, Classification Rules, Advanced, Status, and Counters — every option maps to a real qosify UCI key or ubus parameter, nothing is invented.

Current version: **2.20.3**

## Tabs

### Overview
Service status badge (Active / Enabled — Not Shaping / Not Running / Disabled), start/stop/restart/reload controls, autostart toggle, and config file validation with size, mtime, and rule count. Service control goes through the `rc` ubus namespace, and a start or stop that does not take effect is reported as a failure rather than a silent no-op.

The **Quick Settings** form writes straight to the interface or device section in `/etc/config/qosify`: bandwidth up/down, overhead type and bytes, queue mode, ingress, egress, NAT, host isolate, autorate ingress, and the ingress/egress/shared CAKE option strings. Values are validated before writing: overhead must be a whole number of bytes, option strings are checked for the shell metacharacters that would break the `tc` command qosify builds, and bandwidth is checked against `tc` rate syntax (including `unlimited`) but passed through with a warning rather than blocked, since `tc` is the authority. A failed read of `/etc/config/qosify` aborts the save instead of replacing the file, and a file that changed on disk since the page loaded prompts before being overwritten. The same two checks cover the Config editor: emptying it and saving truncates the file, so a save is refused when the file is non-empty on disk but the editor never loaded it, and the cleanup helper only runs once the daemon is confirmed stopped, and only on sections qosify is actually applying — a `disabled` section is skipped, since its root qdisc belongs to whatever else set it up.

### Config
Inline editor for `/etc/config/qosify`, sized to the window height and draggable, with a **Quick Add Config** form that builds `config defaults`, `config class`, `config alias`, `config interface`, and `config device` stanzas from constrained dropdowns — DSCP codepoints, CAKE overhead types, and diffserv modes only. A Config Reference panel documents every stanza type, lists the currently defined classes, states the defaults qosify applies when a key is absent, and notes that `NQB` needs a qosify newer than the one OpenWrt pinned for 24.10, whose codepoint table has no entry for it.

The editor lints as you go and flags keys the daemon will silently drop — an interface section with no `name`, `nat` set without `host_isolate` (qosify only emits `nat`/`nonat` inside the host isolate branch), `overhead`/`overhead_encap` set while `overhead_type` is not `manual`, both directions disabled, missing bandwidth, shell metacharacters in values, and booleans that do not survive the daemon's conversion — `option nat 'true'` reaches qosify through `json_add_boolean`, which uses `!!atoi()`, so it means *off*.

Class and alias sections are linted too, against `qosify_map_create_class()` rather than the init script: a class's own `ingress`/`egress`/`value` goes through `__qosify_map_dscp_value()`, which takes a codepoint or a raw number and nothing else, so naming another class there makes the daemon free the slot and drop the whole class — and every rule pointing at it with it. A class with no `value`, `ingress` or `egress` at all is not an error either: `strtoul("")` yields 0, so it silently becomes CS0. The class map holds `QOSIFY_MAX_CLASS_ENTRIES` — 16 — slots across `class` and `alias` together, and sections past that get no slot, so the count is flagged as well.

### Classification Rules
Editor for the mapping file qosify actually loads. `add_defaults()` in `qosify.init` hands every entry of `list defaults` to the daemon and lets the shell expand the globs, so the stock `/etc/qosify/*.conf` resolves to `00-defaults.conf`, the file the package seeds — and that is the file the tab edits. The path is resolved from the defaults list before anything is read, against `/etc/qosify` only, so a list that names something else is followed rather than ignored. Upload, download and reset also work on `00-defaults.conf`. The **Quick Add Rule** form covers every qosify match type: `tcp:`, `udp:`, both, `dns:` patterns, `dns:/` regex, `dns_c:` CNAME-only patterns and regex, and IPv4/IPv6 addresses, with an "only if unset" toggle for the `+` prefix. Ports are range-checked to 1–65534 (qosify rejects 65535), `#` and whitespace are blocked in patterns, CIDR is rejected, and rule targets are checked against the classes actually defined in the UCI config. Raw DSCP values are read the way the daemon reads them (`strtoul` base 0, so `077` is 63) and flagged if ≥ 64. Lines with no DSCP target are reported as lines qosify will skip rather than blocking the save.

The editor checks the match side of a hand-typed rule against the same code, so a rule the daemon would drop in silence is flagged rather than left to be inferred from its absence in Map entries: a key with no recognised prefix and no `:` or `.` matches no branch of `qosify_map_parse_line()` at all; a bare key holding a letter was meant as a hostname and needs `dns:`, `dns_q:` or `dns_c:`; ports get the same 1–65534, range-order and base-0 treatment as Quick Add; bare addresses get the `inet_pton()` rules, prefix lengths and zone suffixes included; and a `dns:/` or `dns_c:/` regex is checked for balance and for uppercase, since `__qosify_map_alloc_entry()` lowercases the pattern *before* it calls `regcomp()`, which quietly turns `[A-Z]` into `[a-z]`. `dns_q:` is recognised as the plain-pattern form it is. A third field is flagged too: the parser ends the key at the first space and takes all of the rest as one DSCP target, so `tcp:80 voice extra` parses as nothing. Line length is held to 1022 characters of raw line, which is what `fgets()` into `char line[1024]` leaves once the newline is counted.

### Advanced
One section per job, built like the Overview sections — a ruled two-column table per box, actions in a button row under a dividing line. **Backup** downloads the current files, **Restore** uploads replacements (validated, 64 KB cap, binary rejected) and restarts qosify, **Reset** puts both files back to the package templates with QoS left disabled, and **Display** holds the Counters tab toggle.

### Status
A per-interface summary from `ubus call qosify status` — active state, resolved device, ingress and egress — followed by the detailed `qosify-status` output with CAKE qdisc statistics for egress and ingress. The tab fetches as soon as it is opened, the summary appears before the `tc` output it does not depend on, and the scroll position survives a refresh. The output box fills the page height and can be dragged taller. Polled on LuCI's own schedule, and only while the tab is open: no interval is passed to `poll.add()`, so `L.env.pollinterval` applies — `uci get luci.main.pollinterval`, 5 seconds by default — and the theme's auto-refresh toggle stops and starts it like any other LuCI page. A tick that would overlap a still-running `qosify-status` is skipped rather than queued. One poller serves the whole page, dispatched on the open tab.

### Counters

Everything the daemon counts about itself, read over ubus — no forks, so read-only sessions see it all. The counters ride the page poller at `L.env.pollinterval`; the map listing is a second queue entry at three times that interval, since it is hundreds of entries and tens of kilobytes per reply while its contents change far more slowly than the counters beside it. Both run only while the tab is open, both stop with the theme's auto-refresh toggle, and both track `luci.main.pollinterval`.

The tab is off the tab bar by default: its numbers are totals held by the daemon, so nothing is lost while it is hidden. **Advanced → Display → Counters tab** toggles it on or off, and a link straight to `#counters` counts as asking for it. The setting is a per-browser view preference kept in `localStorage`, so it survives logout — not in UCI, because qosify owns `/etc/config/qosify` and this app adds no keys of its own to it, and `/etc/config/luci` would mean a wider ACL for a cosmetic toggle. The toggle carries `data-ro-ok`, so it stays usable with read-only access.

**Daemon counters** reads `ubus call qosify get_stats` and shows exactly what that build reports. The current daemon returns the IPv4 and IPv6 address map entry count — `qosify_map_get_ebpf_entry_count()` sums those two maps only, the port maps being fixed 65536-entry arrays — last reload time, DNS cache hits/misses/size, and per-class, per-DSCP and per-DNS-pattern packet and byte counters; the build OpenWrt pinned for 24.10 returns `qosify_map_stats()` alone, which is one packet counter per class. Whatever the reply omits is left out rather than shown as a dash.

Per-class packet totals are a colour-coded horizontal bar chart rather than a table: one row per class with its own colour, sorted largest first, each showing the packet total and its share of everything the daemon has classified, and a total row closing the chart. These are the cumulative counts since the daemon's last reload, not rates, so nothing accumulates in the browser and closing the tab loses nothing. Bar length is log-scaled — a bulk class can outweigh voice by four orders of magnitude, which leaves everything else a sliver on a linear axis — while the figures beside each bar stay the daemon's own. A share under a tenth of a percent reads `<0.1%` rather than `0.0%`, and hovering a row gives the exact packet and byte totals. Plain CSS flex with a fixed eight-colour palette assigned by sorted class name, so a class keeps its colour as the bars reorder; no SVG, no charting library, nothing added to `LUCI_DEPENDS`. Below it, the DSCP and DNS-pattern tables carry the rest of the reply.

**Map entries** reads `ubus call qosify dump` in a scrollable box and lists what the daemon is matching on: the type, the match, the DSCP, whether the entry came from a file or was added dynamically, the traffic it has matched, and the remaining timeout — so a rule that failed to load shows up as an absence. `qosify_map_set_port()` stores one entry per port, so a rule like `udp:6881-7000` arrives as 120 separate entries; consecutive ports that agree on type, class, source and timeout are shown as the single range they were expanded from, and the row and entry counts are printed below the table, which is capped at 200 rows. The box is rebuilt in place on its own slower tick with its scroll offset preserved, the header is pinned to the top of the box while the rows scroll under it, and the Traffic column reuses the counters already on hand, so the listing costs exactly one ubus call. Rows are ordered by the DSCP value behind the entry, highest first, so EF and the classes above best effort are at the top and LE and CS0 at the end; a class name is resolved through the section that defined it, since `blobmsg_add_dscp()` prints the class name rather than its value. Entries the daemon added itself from a DNS lookup follow the ones the config loaded, so the 200-row cap falls on addresses that come back on the next lookup rather than on the rules. The **Traffic** column comes from the `dns` table of `get_stats`; qosify keeps per-entry counters for DNS patterns only, so port and address rows show `-` and are counted by class and by DSCP above instead. The Traffic column is present only where the daemon has per-entry counters: 24.10 pins qosify at 2024-09-20 (`1501e09`), whose `get_stats` answers with `qosify_map_stats()` at the top level — one table per class with `packets` and no `dns` table — so on that build the column is dropped rather than carrying a dash on every row, and the box says why. A DNS row shows hits as well as packets: hits counts the lookups the pattern matched, and `qosify_map_lookup_dns_entry()` counts a hit on every pattern that matches, not only the one whose DSCP wins. Packets are accounted in the datapath against the `pattern_id` held in the address map entry, which `__qosify_map_set_entry()` writes only where the DSCP changes — always true for a new address, never for one already in the map at that DSCP, so such an address keeps the `pattern_id` of whatever put it there and its packets are counted against that instead. Timeouts are shown only where the daemon reports one, which it does for dynamically added entries and not for file entries.

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

The installer installs `qosify` via apk or opkg if missing, writes the menu entry, ACL, and JS view to the standard LuCI paths, seeds default configs without overwriting existing ones, registers the app in `/lib/upgrade/keep.d/`, and restarts rpcd so the new ACL applies to the next login. Every file it writes is verified, so a full or read-only overlay fails loudly instead of leaving a half-installed app. Then open **Network → qosify** (Ctrl+F5 first).

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

A session with only *read* access to the `luci-app-qosify` ACL group gets a read-only page: the editors, Quick Add forms and service controls are disabled rather than offered and failing with a permission error. Backup downloads stay available.

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
| `/www/luci-static/resources/view/qosify/qosify.css` | View stylesheet (declared on the menu entry, so the theme loads it before the view runs) |
| `/usr/share/qosify-luci/` | Default config templates, cleanup helper |
| `/lib/upgrade/keep.d/luci-app-qosify` | Sysupgrade keep list |

## Credits

This builds on the work of [@nbd168](https://github.com/nbd168), who authored [qosify](https://github.com/openwrt/qosify). This app only adds a web interface on top of qosify — it does not modify or fork the daemon, its init script, or its defaults, and every setting it exposes is a documented qosify option.

## License

MIT
