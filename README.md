# luci-app-qosify

A LuCI web interface for [qosify](https://github.com/openwrt/qosify) on OpenWrt and ImmortalWrt.

qosify sets up CAKE traffic shaping and uses an eBPF classifier to mark each packet's DSCP field,
so voice, video, bulk and best-effort traffic land in the right CAKE tin. This app puts all of it
on one page under **Network → qosify**: turn shaping on, set your bandwidth, edit the config and
classification rules, and watch what qosify is doing. Every setting is a real qosify option —
nothing is added on top.

Current version: **3.1.1** — see [CHANGELOG.md](CHANGELOG.md).

## Quick start

1. Install (below), then open **Network → qosify** and press Ctrl+F5 once.
2. On **Overview**, open the quick settings, tick **QoS Enabled** and set **Upload** and
   **Download bandwidth** to a little under your measured line speed.
3. Click **Save & Apply**. The Service status turns green once qosify is shaping.

The shipped config has QoS disabled, so nothing is shaped until you do this.

## Install

On snapshots, install the package: `apk add luci-app-qosify`.

On 24.10, 25.12 or any other build, use the installer:

```
wget -O /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
sh /root/qosify-luci.sh install
```

For the `dev` test build, use `dev` in place of `main` in the URL.

`curl -o /root/qosify-luci.sh <same URL>` works too. The installer adds `qosify` if it is missing,
writes the app files, creates default configs without overwriting yours, reloads rpcd and restarts
the web server.

### Installer commands

| Command | What it does |
| --- | --- |
| `install` | Install qosify if needed, the app and default configs, then restart services |
| `files` | Write the app files only — no packages, no restarts (for ImageBuilder) |
| `reset` | Put both config files back to qosify defaults and restart qosify |
| `uninstall` | Remove the app, qosify and both configs, plus the `clsact` and `ifb-dns` qosify leaves behind |
| `migrate` | Switch to the `luci-app-qosify` package, keeping both config files; restores the script install if the package is not available |

`install`, `files`, `uninstall` and `reset` refuse to run when the app is installed as a package —
use apk/opkg for it then.

### Requirements

- OpenWrt 24.10, 25.12 or snapshot with LuCI
- `wget` or `curl` for the installer

| qosify build | Class bytes, DSCP and DNS stats, NQB | `multiqueue` |
| --- | --- | --- |
| 24.10, 25.12 (`1501e09`) | – | – |
| snapshot before 2026-10-16 (`beeb87e`) | ✓ | – |
| snapshot from 2026-10-16 (`b3ee50e`) | ✓ | ✓ |

`b3ee50e` also takes port 65535 and applies `+` values as documented; the app follows the
build it finds.

The app reads what the running qosify reports and hides what it lacks.

**25.12 and snapshots:** `qosify.init` applies its config from `service_running`, which procd runs
by itself shortly after every start, respawn and boot. The app's Start, Restart and Save & Apply
also send a reload and wait for it, so the page shows the new state straight away.

## The tabs

### Overview

- **Service** — status (green shaping, amber running but idle, red stopped), uptime, autostart,
  how many interfaces are shaping, and one row per interface or device with its ingress and egress.
- **Service bar** — Autostart, Start, Restart, Reload, Reload Rules and Stop. **Reload** re-sends
  the whole config; **Reload Rules** only re-reads the rule files, which is all a rules edit needs.
- **Files** — both config files with their validity, size and last change.
- **Quick settings** — edits one interface or device section directly, in four tabs:
  - **Basic**: QoS Enabled, interface or device name, upload/download bandwidth, queueing mode
    (`diffserv4` by default)
  - **Shaping**: download and upload shaping, automatic download rate, NAT awareness, host
    isolation, and Multiqueue CAKE (`cake_mq`) where `qosify.init` passes `multiqueue` and the
    section's device has more than one queue (never on PPPoE)
  - **Overhead**: overhead preset, plus manual and encapsulation overhead (shown only for
    `manual`), MPU and VLAN tags
  - **Advanced**: extra CAKE options for ingress, egress or both

  All four tabs are the height of the tallest, so switching tabs never moves the page.

Values are checked before saving (bandwidth that `tc` might still accept only warns), and if
the file changed on disk since the page loaded you are asked before it is overwritten.

### Config

An editor for `/etc/config/qosify` that checks as you type and warns about settings qosify will
quietly ignore — a section with no `name` or a name over 15 characters, more than 16 classes,
`nat` without `host_isolate`, manual overhead without `overhead_type manual`, an invalid `mode`,
rate or overhead value, a non-numeric integer key, both directions off, no bandwidth, or
`option nat 'true'` (qosify reads that as off; use `1`). Shell metacharacters in any value that
reaches `tc`, the overhead keys included, block the save.

**Quick Add** builds `defaults`, `class`, `alias`, `interface` and `device` sections from
dropdowns, with each option explained underneath. **Reference** lists your classes, the DSCP
values qosify accepts and the defaults it uses when a key is missing.

### Rules

An editor for `/etc/qosify/00-defaults.conf`, the file that decides which traffic gets which DSCP
class. **Quick Add** builds one rule at a time for any match qosify supports: TCP/UDP ports and
ranges, IPv4/IPv6 addresses, `dns:` patterns and regex, and `dns_c:` CNAME matches, with an "only
if unset" option for the `+` prefix. Rules are checked the way qosify reads them: ports 1–65534
(1–65535 on `b3ee50e`),
single addresses (no CIDR), and targets that are defined classes or valid DSCP values. A line qosify
would skip is reported rather than silently saved.

**Dynamic Entries** sends `ubus call qosify add` straight to the running qosify — not saved,
gone after its timeout or a restart — and lists the live entries with their remaining timeout
and a Remove button (`ubus call qosify remove`).

### Status

The full `qosify-status` output — CAKE statistics for egress and ingress — refreshed at LuCI's
refresh interval while the tab is open.

### Counters

- **Traffic by Class** — packets and bytes per qosify class since the last reload, with bars
  coloured by CAKE tin, including qosify's `tcp_default`/`udp_default` unless the default names a
  class. On 24.10 and 25.12 qosify reports packets only.
- **Traffic by DSCP** — traffic per DSCP codepoint from `get_stats`. Only on snapshots.
- **Traffic by CAKE Tin** — CAKE's own per-tin packets, bytes and drops, from `qosify-status`.
- **DNS Entries** — hits and traffic per `dns:` rule. Only on snapshots (qosify `beeb87e`); on
  24.10 and 25.12 the running qosify does not report them.
- **Reset counters** — `get_stats` with `reset`; the CAKE tin counters belong to `tc` and are kept.

The two traffic views count different things and are not expected to match. While qosify is
stopped the tab is cleared rather than showing stale numbers.

### Advanced

- **Backup** — download either config file.
- **Restore** — upload a replacement file (64 KB max, checked before it is applied).
- **Maintenance** — **Check Devices** picks up a device that appeared after qosify started, without
  a restart.
- **Defaults** — reset both files to qosify defaults, after a confirmation.

## Good to know

**Read-only users** get a read-only page: editors, Quick Add and service buttons are disabled.
Backup and Counters still work, apart from Traffic by CAKE Tin. **Reset counters** is disabled
for them, but rpcd cannot limit `get_stats` by argument, so a read-only session can still zero
qosify's counters with a direct ubus call.

**Unknown status** — if rpcd does not answer a status call (often an old ACL after an upgrade), the
page shows an amber **Unknown** rather than guessing, and a Stop never cleans up on an unanswered
call. `/etc/init.d/rpcd reload` usually clears it, without logging anyone out.

**Stop and uninstall** only remove what qosify created: sections with `disabled 1` are skipped, and
another shaper such as SQM on the same device is left alone.

**Sysupgrade** — the installer lists its files and `/etc/qosify` in `/lib/upgrade/keep.d/luci-app-qosify`,
so the app and every mapping file survive sysupgrade, attended sysupgrade and owut.

## Custom firmware

**ImageBuilder:** add `qosify` to your package list, put the installer in `files/root/`, and add
`files/etc/uci-defaults/99-qosify-luci`:

```
#!/bin/sh
sh /root/qosify-luci.sh files
exit 0
```

**SDK / buildroot:** put this repo at `package/luci-app-qosify/` and run
`make package/luci-app-qosify/compile`. The `Makefile` builds the package from the installer and
takes its version from `VERSION=`.

## OpenWrt package

`luci-app-qosify` is in [openwrt/luci](https://github.com/openwrt/luci/tree/master/applications/luci-app-qosify)
master and ships in snapshots. Master is installer 3.0.43 file for file, apart from the
installer's `?v=<VERSION>` stylesheet suffix. It is not in the 24.10 or 25.12 release branches.
Merged PRs: #8833, #9019, #9054, #9067, #9082, #9131, #9164.

Translations are done on Weblate and ship as
`luci-i18n-qosify-*` packages from the in-tree build; the installer is English only.

## Files

| Path | Purpose |
| --- | --- |
| `/etc/config/qosify` | qosify config — defaults, classes, interfaces, devices |
| `/etc/qosify/00-defaults.conf` | Classification rules |
| `/www/luci-static/resources/view/qosify/main.js` | The page |
| `/www/luci-static/resources/view/qosify/qosify.css` | Its stylesheet |
| `/usr/share/luci/menu.d/luci-app-qosify.json` | Menu entry |
| `/usr/share/rpcd/acl.d/luci-app-qosify.json` | Access rights |
| `/usr/share/qosify-luci/` | Default configs and the cleanup helper |
| `/lib/upgrade/keep.d/luci-app-qosify` | Sysupgrade keep list (installer only) |

## Credits

Built on [qosify](https://github.com/openwrt/qosify) by [@nbd168](https://github.com/nbd168). This
app is only a web interface: it does not change qosify, its init script or its defaults.

## License

MIT
