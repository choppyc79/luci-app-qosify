# luci-app-qosify

LuCI web interface for [qosify](https://github.com/openwrt/qosify) on OpenWrt / ImmortalWrt.

qosify is a daemon that sets up and manages CAKE together with an eBPF classifier that marks DSCP fields. This app adds a **Network → qosify** page with tabs for Overview, Config, Rules, Status, and Advanced — every option maps to a real qosify UCI key or ubus parameter, nothing is invented.

The page is built from stock LuCI markup — `div.cbi-section` sections with `h3` titles, `.table` rows, `.label` badges, `.cbi-value` form rows, `.cbi-tabmenu` sub-tabs and `.cbi-section-table` grids — and `qosify.css` draws each section as a box with a title bar using the theme's own colour variables. Option names on screen are the qosify UCI option names.

Current version: **3.5.0-dev**

## Tabs

### Overview
The **Service** section shows status, autostart, the active interfaces and `/etc/init.d/qosify`, with Enable/Disable Autostart, Start, Restart, Reload and Stop underneath; buttons that do not apply to the current state are disabled. **Files** lists both config files with their validity, section or rule count, size and modification time. Service control goes through the `rc` ubus namespace, and a start or stop that does not take effect is reported as a failure rather than a silent no-op.

The **quick settings** section (titled with the section it edits, e.g. `interface wan quick settings`) writes straight to the interface or device section in `/etc/config/qosify`, in LuCI sub-tabs: **General Settings** (QoS enabled with its state badge, `name` when the section has none, `bandwidth_up`, `bandwidth_down`, `mode`, `ingress`, `egress`), **Overhead** (`overhead_type`, `overhead`) and **Advanced Settings** (`nat`, `host_isolate`, `autorate_ingress`, `ingress_options`, `egress_options`, `options`). Values are validated before writing: overhead must be a whole number of bytes, option strings are checked for the shell metacharacters that would break the `tc` command qosify builds, and bandwidth is checked against `tc` rate syntax (including `unlimited`) but passed through with a warning rather than blocked, since `tc` is the authority. A failed read of `/etc/config/qosify` aborts the save instead of replacing the file, and a file that changed on disk since the page loaded prompts before being overwritten. The same two checks cover the Config editor: emptying it and saving truncates the file, so a save is refused when the file is non-empty on disk but the editor never loaded it, and the cleanup helper only runs once the daemon is confirmed stopped. It skips sections with `disabled 1`, as `qosify.init` does, and only removes the ifb device qosify derives from each enabled section, so a Stop never touches a device or ifb qosify did not create.

### Config
Inline editor for `/etc/config/qosify`, sized to the window height and draggable, with three **Quick Add** sections, one per stanza group, each folding away on its own and laid out as LuCI section grids with the option names across the top (the class and interface forms start with the section type and name), that build `config defaults`, `config class`, `config alias`, `config interface`, and `config device` stanzas from constrained dropdowns — DSCP codepoints, CAKE overhead types, and diffserv modes only. Under each form a collapsible panel lists every option with its description from the qosify README. A folding **Reference** section lists the defined classes, the accepted DSCP values and the defaults qosify applies when a key is absent. Each section remembers whether it was open for the browser session.

The editor lints as you go and flags keys the daemon will silently drop — an interface section with no `name`, `nat` set without `host_isolate` (qosify only emits `nat`/`nonat` inside the host isolate branch), `overhead`/`overhead_encap` set while `overhead_type` is not `manual`, both directions disabled, missing bandwidth, shell metacharacters in values, and booleans that do not survive the daemon's conversion — `option nat 'true'` reaches qosify through `json_add_boolean`, which uses `!!atoi()`, so it means *off*.

### Rules
Editor for `/etc/qosify/00-defaults.conf`, laid out like the Config tab. The folding **Quick Add** bar is a single row (`match`, value, `dscp`, `+` and Add, with each class listed alongside its DSCP value) and covers every qosify match type: `tcp:`, `udp:`, both, `dns:` patterns, `dns:/` regex, `dns_c:` CNAME-only patterns and regex, and IPv4/IPv6 addresses, with an "only if unset" toggle for the `+` prefix. Ports are range-checked to 1–65534 (qosify rejects 65535), `#` and whitespace are blocked in patterns, CIDR is rejected, and rule targets are checked against the classes actually defined in the UCI config. Raw DSCP values are read the way the daemon reads them (`strtoul` base 0, so `077` is 63) and flagged if ≥ 64. Lines with no DSCP target are reported as lines qosify will skip rather than blocking the save. Collapsible panels carry the mapping file syntax from the qosify README and the defined classes.

### Status
A per-interface summary from `ubus call qosify status` — active state, resolved device, ingress and egress — followed by the detailed `qosify-status` output with CAKE qdisc statistics for egress and ingress. The tab fetches as soon as it is opened, the summary appears before the `tc` output it does not depend on, and the scroll position survives a refresh. Polled every 10 seconds, and only while the tab is open — a tick that would overlap a still-running `qosify-status` is skipped rather than queued.

### Advanced
**Backup & Restore** is one table of both files with size, modification time, a Download button and a file picker; Upload & Apply replaces the chosen files (validated, 64 KB cap, binary rejected). **Defaults** resets both files back to qosify defaults after a confirmation.

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

A session with only *read* access to the `luci-app-qosify` ACL group gets a read-only page: the editors, Quick Add forms and service controls are disabled rather than offered and failing with a permission error. Backup downloads stay available.

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
