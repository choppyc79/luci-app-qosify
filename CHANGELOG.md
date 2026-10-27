# Changelog

All notable changes to `luci-app-qosify`. Versions are the `VERSION=` constant in `qosify-luci.sh`.
PR numbers are on openwrt/luci.

## v3.0.39 — 2026-10-27

dev 3.0.38 merged into main, plus the fixes below. The package changes went upstream as #9164.

- Values from the config, the rules file and qosify replies render as text, not innerHTML
  (notifications, table cells, badges, option labels, dynamic and DNS entries, dialogs)
- Editors: the textarea is filled as text, so a save no longer decodes `&amp;` and the like
- Quick settings: quoted option names (`'bandwidth_up'`) are replaced instead of duplicated
- Template: `option multiqueue 0`, as the qosify package ships
- Installer: `migrate` returns early when luci-app-qosify is already a package; rpcd is
  reloaded instead of restarted, so nobody is logged out

## v3.0.38 — dev (2026-10-17)

main 3.0.36 plus support for qosify `b3ee50e` (openwrt/openwrt#25696).

- Quick settings, Quick Add and lint: `multiqueue` (`cake_mq`), shown only when
  `/etc/init.d/qosify` passes it; ACL read grant for that file
- Rules: port 65535 accepted where `qosify.init` passes `multiqueue` (same qosify bump)
- Reference: `+` noted as working only from qosify `c698349`
- Counters: Traffic by CAKE Tin also reads `cake_mq` root qdiscs
- Cleanup helper: long-name ifb (`ifb-` + first two and last nine characters); ingress prefs
  kept at 272–277, the six qosify itself clears

## v3.0.36 — 2026-10-13

#9131 review fixes.

- Quick settings: the enable row is labelled **QoS Enabled** again, and the bandwidth hints say
  "same format as tc" again
- CSS: the two `#qos-qs-sect .cbi-value` blocks merged into one

## v3.0.35 — 2026-10-13

3.0.19–3.0.35 from `dev`. The multiqueue (`cake_mq`) and matching cleanup parts are held on
`dev`.

- Config/Restore refuse shell metacharacters in `overhead`, `overhead_encap` and `overhead_mpu`
  too (qosify runs them through `sh -c`), and `#*?[]~`
- Counters count qosify's `tcp_default`/`udp_default` unless the default names a class
- Lint: names over 15 characters or quoted, more than 16 classes, invalid `mode`, rates, overhead
  or `overhead_vlan` values, non-numeric integer keys
- Rules: **Dynamic Entries** fold — `ubus call qosify add`/`remove` with a timeout, live `user`
  entries from `dump`; write ACL grants `add` and `remove`
- Counters: **Traffic by DSCP** (codepoints only) and **Reset counters** from `get_stats`
- Overview: quick settings laid out like the Service table, every tab the height of the tallest,
  no line above a tab's first row; one cell padding for every box and table

## v3.0.18 — 2026-09-28

3.0.12–3.0.18 went upstream as #9082, merged 2026-09-30.

- Advanced: `sect()` copies its attributes instead of writing the class back into them, so the
  shared box class no longer repeats across Backup, Restore, Maintenance and Defaults
- `qosify.css`: the box comment names every Advanced section

## v3.0.17 — 2026-09-28

- Overview: the "Invalid CAKE options can stop qosify starting." note is dropped from the quick
  settings Advanced tab

## v3.0.16 — 2026-09-28

- Advanced: Check Devices sits on the right like the other section buttons
- Overview: quick settings rows are shallower (theme `.cbi-value` bottom margin dropped, padding
  tightened)

## v3.0.15 — 2026-09-28

- Config and Rules: Quick Add and Reference boxes fill the row again and are only slightly deeper
  than their heading; the theme's `h3` line-height no longer sets their depth

## v3.0.14 — 2026-09-28

- Advanced: Backup, Restore, Maintenance and Defaults share one layout — box, smaller heading,
  description, table with the theme's header row, buttons on the right. The Defaults table lists
  the two files Reset replaces
- Config and Rules: a closed fold shrinks to its heading, an open one takes the full row

## v3.0.13 — 2026-09-28

- Advanced: Maintenance and Defaults get the Quick Add box and smaller heading

## v3.0.12 — 2026-09-28

- Config and Rules: each Quick Add and Reference fold sits in its own box, drawn like the quick
  settings and Counters boxes, with a heading sized to the app instead of the theme's full `h3`

## v3.0.11 — 2026-09-25

Second round of #9067 review fixes.

- The config check reads statement by statement as libuci does: a `config` after an unquoted `;`
  opens a new section, so `option foo 1; config interface wan` is no longer read into the section
  before it
- A backslash outside single quotes, a line continuation or an unclosed quote blocks the Config
  save and Restore upload (libuci unescapes keywords, keys and headers too). Adjacent quoted and
  bare parts are joined as libuci joins them

## v3.0.10 — 2026-09-25

First round of #9067 review fixes.

- `bandwidth*`, `mode` and the CAKE `*options` are cut at an unquoted `#` and split at an unquoted
  `;` as uci does, and a value that is not one plain or fully quoted string blocks the save and
  upload, so `option mode x'$(id) y'` is caught
- NQB detection comment corrected: OpenWrt went from qosify `1501e09` straight to `beeb87e`

## v3.0.9 — 2026-09-24

3.0.6–3.0.9 went upstream as #9067 (four commits, with the 3.0.10–3.0.11 review fixes), merged
2026-09-27.

- Start, Restart and a save or Restore that starts qosify wait for its ubus object and send
  `reload`: on 25.12 and master `qosify.init` only pushes the config from `service_running()`.
  `install` and `reset` do the same
- Cleanup only deletes the root qdisc and qosify's filters (prefs 272–277) while qosify's bpf
  classifier is still attached, and `clsact` only once no filters are left, so it no longer takes
  SQM's qdisc on the same device
- Shell metacharacters in `bandwidth*`, `mode` and the CAKE `*options` block the Config save and
  Restore upload instead of only warning; Quick Settings checks bandwidth too
- `install`, `files`, `uninstall` and `reset` stop when `luci-app-qosify` is installed as a package

## v3.0.8 — 2026-09-22

- Package `prerm` starts a background copy of the cleanup helper that waits up to 30 s for qosify
  to exit, then removes the `clsact` and `ifb-dns` qosify's own stop leaves behind. Nothing is
  touched if qosify stays installed and running
- `uninstall` waits for qosify to exit instead of `sleep 1`; `cleanup wait` reads the device
  names before waiting

## v3.0.7 — 2026-09-21

- Rules Quick Add: the IPv4/IPv6 `match` labels were blank and `tcp:<port>[-<endport>]` and the
  other syntax labels cut short, because `E()` parsed `<ipaddr>` as a tag. Same fix in the
  Reference syntax table and the `overhead`/`overhead_mpu` descriptions

## v3.0.6 — 2026-09-21

### Fixed

- A bad `dscp_prio`, `dscp_bulk` or `dscp_icmp` in `config defaults` blocks the save and upload
  (qosify rejects the whole `config` call); bad class values and `dscp_default_*` are warned
- Rules save, Restore and Quick Add warn on lines qosify skips silently: ports outside 1–65534 or
  reversed, CIDR, `%zone`, malformed addresses, a third field
- NQB is offered only when the running qosify has it (`1501e09` does not)
- Restore turns CRLF into LF; Quick Settings reads a CRLF config without duplicating options
- Warning when `/etc/qosify/00-defaults.conf` is not matched by `list defaults`
- Quick Settings shows an inherited `bandwidth` as the placeholder and no longer warns it unset
- The 1023-byte line check counts the raw line, comment included, as `fgets` does
- Cleanup also deletes `ifb-dns` once qosify has exited

### Changed

- Quick Add `timeout` placeholder is qosify's default, 3600; Quick Add controls get `aria-label`s
- Quick Settings reuses the option descriptions (7 fewer strings)
- `qosify` template matches openwrt's `qosify.conf` byte for byte; stray `option:null` key removed
- `install` no longer reloads qosify after restarting it (put back in 3.0.9)

## v3.0.5 — 2026-09-21

- `qosify.css` no longer redraws `.cbi-section` as its own box with a grey title strip; the theme
  draws sections, their `h3` and page actions (fixes the Footstrap card). Folds keep only their
  marker and cursor

## v3.0.4 — 2026-09-21

#9046 review fixes.

- A save whose `service.list` goes unanswered restarts qosify through `rc init` instead of
  failing; only the start branch still fails, and it tells an unanswered poll from a timeout
- The "rpcd is not answering" note also shows when only `qosify status` is unanswered, on the
  first Overview row that reads Unknown

## v3.0.3 — 2026-09-20

- A class with only `ingress` or `egress` set prints both sides, `-` for the unset one, whenever
  they differ

## v3.0.2 — 2026-09-20

- `qosify.css` is the in-tree sheet byte for byte (expanded form); no rule changed

## v3.0.1 — 2026-09-20

Resync with the #9046–#9054 series, review fixes included.

### Fixed

- An unanswered `service.list` no longer reads as stopped: Start, Restart and Save say rpcd is not
  answering, and Stop and Config Clear skip the cleanup helper
- Each Overview fact goes Unknown only with the call it comes from; QoS Enabled shows Disabled
  from UCI even while the state is unknown
- Saving with qosify stopped says it is not shaping, not "could not be checked"
- `reload`, `check_devices`, `get_stats` and `dump` are declared `reject: true`, so a failed call
  is reported rather than read as success or an empty table
- Counters: the get_stats box is hidden when the reply has none of its fields (always on
  `1501e09`); a failed call says "get_stats did not answer."; a tick overlapping the tab-open
  fetch is dropped, and the Status in-flight guard is back
- DNS Entries always prints hits / packets / bytes
- Uptime advances on `performance.now()`, so a clock step no longer skews it
- Service bar keeps its order on Bootstrap
- Autostart is labelled Enabled / Disabled / Unknown and its click acts on the last refresh
- The QoS Enabled label toggles its checkbox again
- `ingress %s, egress %s` and `(alias)` are translatable again

### Changed

- Overhead tab order: preset, Manual, Encapsulation, MPU, VLAN tags
- Page description and plain `cbi-map` restored; the Files table gets an `h3` title

## v3.0.0 — 2026-09-19

First 3.x release, on top of v2.9.11. Same UCI keys, ubus calls and file paths; no config changes
needed.

- Page rebuilt on stock LuCI markup (`div.cbi-section` with `h3`, `.table`, `.label`,
  `.cbi-value`, `.cbi-section-table`, `.cbi-progressbar`); the `qos-*` classes are gone and
  `qosify.css` uses the theme's variables, including the class and tin colours in light and dark
- Six tabs: Overview, Config, Rules, Status, Counters, Advanced; page title lowercase `qosify`.
  The page description and plain `cbi-map` were dropped here and restored in 3.0.1
- Stylesheet link carries `?v=<VERSION>` (installer only)
- Overview: one Service section — status (green shaping, amber idle, red stopped), uptime from
  `/proc/<pid>/stat`, autostart, shaping count, `/etc/init.d/qosify` and the per-interface rows
  moved from Status. The service bar (Autostart, Start, Restart, Reload, Reload Rules, Stop) sits
  at the bottom of Overview only
- New **Reload Rules** (`ubus call qosify reload`) and, on Advanced, **Check Devices**
  (`ubus call qosify check_devices`)
- Files: one table listing both config files
- Quick settings in four tabs (Basic, Shaping, Overhead, Advanced) with plain labels and
  qosify-worded hints. Manual and Encapsulation overhead show only under `overhead_type manual`.
  Unset `mode` selects `diffserv4`, the daemon's default (`interface.c`), and a save writes it.
  The form writes `overhead_mpu`, `overhead_vlan` and `overhead_encap`; `overhead` may be negative
- New **Counters** tab: Traffic by Class (`get_stats`), Traffic by CAKE Tin (`qosify-status`),
  and DNS Entries (`dump`), shown only when `get_stats` has a `dns` table (`beeb87e`). Cleared
  while qosify is stopped
- Config Quick Add in three folds plus a Reference fold; Rules Quick Add one folding row; fold
  state kept for the session; editors sized to the window and resizable both ways
- Status tab shows only the `qosify-status` output
- Advanced: Backup and Restore split, with LuCI Choose file buttons; Maintenance; Defaults
- Service state is tri-state: `rc.list`, `service.list` and `qosify.status` are declared
  `reject: true`, and an unanswered call shows amber **Unknown** instead of stopped
- Overview, Status and Counters poll at `luci.main.pollinterval` instead of a fixed 10 s
- ACL: read gains `qosify` `get_stats`/`dump`, `/proc/uptime` and `/proc/[0-9]*/stat`; write gains
  `qosify` `reload`/`check_devices`
- Feed `Makefile` postinst/postrm reload rpcd as `luci.mk` does; README gains the OpenWrt package
  section and `migrate`

## v2.9.11 — 2026-09-15

- #9019 review: comment fixes only (ubus call counts, cleanup helper's ifb comment)

## v2.9.10 — 2026-09-15

- Feed `Makefile`: `PKG_MAINTAINER` in `Name <email>` form

## v2.9.9 — 2026-09-15

- Feed `Makefile`: `PKG_LICENSE` corrected to MIT; `Build/Compile` indented with tabs only

## v2.9.8 — 2026-09-15

- Feed `Makefile` installs `qosify.css`; it was missing from feed and ImageBuilder builds
- `uninstall` no longer removes every `ifb-*` device when the cleanup helper is missing

## v2.9.7 — 2026-09-15

- Cleanup skips `disabled 1` sections, as `qosify.init` does; on the shipped config a Stop could
  remove an SQM qdisc on `wan`
- Cleanup no longer sweeps every `ifb-*`; only the ifb qosify derives from each enabled section,
  even when its parent has gone

## v2.9.6 — 2026-09-11

- Status tab back on a fixed 10 s tick (2.9.3 doubled the `qosify-status` forks)
- Dead `.qos-pre` sizing removed

## v2.9.5 — 2026-09-11

- Config and Rules editors fill the window (min 320px, vertical resize)

## v2.9.4 — 2026-09-11

- `qosify-status` box fills the page (min 320px, vertical resize)

## v2.9.3 — 2026-09-11

- Status tab polls at `LuCI.env.pollinterval` instead of 10 s (reverted in 2.9.6)

## v2.9.2 — 2026-09-11

- Status tab fetches as soon as it opens and shows "Reading tc output..." until the fork returns
- The interface summary paints before the `qosify-status` fork finishes; overlapping refreshes
  are dropped
- The output is patched in place, so the scroll position survives a tick; long `tc` lines scroll
  instead of wrapping

## v2.9.1 — 2026-09-11

#9019 review fixes.

- Saving an emptied Config editor goes through the freshness check and is refused if the file
  never loaded; it only runs the cleanup helper once qosify is confirmed stopped
- Cleanup helper lock is an `flock` instead of a mkdir lock that rpcd's SIGKILL left behind

## v2.9.0 — 2026-09-10

- Service control uses the `rc` ubus namespace: `luci.setInitAction` was removed from `luci-base`
  and every button silently did nothing. Start and stop wait for the state change and report
  failure; cleanup runs only once qosify is confirmed stopped
- Data safety: a failed config read aborts a Quick Settings save instead of replacing the file;
  editors prompt before overwriting a file changed on disk; saving one file keeps unsaved edits
  in the other; Reset names the file that failed; downloads no longer hand out an empty file
- Daemon semantics: booleans linted as qosify reads them (`option nat 'true'` is off); config
  headers with `#` or `;` recognised; every shell metacharacter flagged in options; raw DSCP read
  as `strtoul` base 0; single-field rule lines reported as skipped; lines over 1023 characters
  rejected; hex ports and IPv4-mapped IPv6 accepted; bandwidth accepts `unlimited` and `tc`
  suffixes and warns rather than blocks
- LuCI conformance: read-only page for read-only sessions; `ui.showModal`/`ui.addNotification`
  instead of `confirm()`/`alert()`; no `innerHTML`; `ui.tabs.initTabGroup`; styles moved to
  `qosify.css` and follow the theme; every string through `_()`
- Performance: no forks on page load or Overview tick; the poll no longer re-reads both files and
  patches in place; saves `reload` instead of `restart`; Status ticks at 10 s
- Cleanup helper: no hardcoded `pppoe-wan`/`br-lan`; sections read with `config_foreach` and
  `network_get_device`; ifb named as qosify names it; lock against overlapping runs
- Package: `+luci-base` dependency; ACL rebuilt with `exec` in write and `rc.list`, `rc.init`,
  `qosify.status` added

## v2.8.8 — 2026-08-02

- Merged into openwrt/luci master (#8833)
- New `migrate` command: swaps the script install for the package, keeping both config files, and
  falls back to the script install if the package is not in the feeds

## v2.8.7 — 2026-08-02

- Device sections no longer prefill the name; Quick Settings shows a Device Name row marked
  required, since qosify skips a section with no name

## v2.8.6 — 2026-08-01

- Fixed an undefined `qv()` that broke Quick Settings rendering
- Class label and description helpers translated; save validates the interface/device name

## v2.8.3 – v2.8.5 — 2026-07-31

Checked against `qosify.init` and the daemon sources.

- `alias` sections treated as classes (`qosify.init` runs `add_class` over both)
- Port ceiling 65534 (`qosify_map_set_port` rejects 65535); no IPv6 `%zone`; `#` blocked in DNS
  patterns
- Rule lint accepts hex DSCP and flags values ≥ 64
- Quick Add Config `dscp_*` dropdowns rebuilt when classes refresh
- ACL: `exec` and `luci setInitAction` moved to the write group

## v2.8.2 — 2026-07-31

- Config lint flags keys qosify drops: missing `name`, `nat` without `host_isolate`,
  `overhead`/`overhead_encap` without `overhead_type manual`, both directions off, no bandwidth
- Rule targets checked against the defined classes; Quick Settings validated before save
- Config Reference covers every stanza type and qosify's defaults
- Quick Add Rule gains the `+` "only if unset" toggle; Quick Add Config refuses duplicates
- Post-save check reports applied, applied with QoS disabled, or saved but not shaping

## v2.5.6 – v2.5.7 — 2026-07-31

- Version constant dropped from the view; the installer holds it

## v2.5.5 — 2026-07-16

- All strings wrapped for LuCI i18n; submitted to openwrt/luci. No functional changes

## v2.5.4 — 2026-07-16

- New `files` mode: app files only, no package or service operations (ImageBuilder / uci-defaults)

## v2.5.1 – v2.5.3 — 2026-06-11

- Save & Apply restarts qosify; cleanup helper removes CAKE qdiscs and IFBs on stop and clear
- keep.d covers all app files; LuCI caches cleared on install and uninstall
- `overhead_type` defaults to none; BusyBox-safe IFB matching

## v2.5.0 — 2026-06-10

- Saves reload in place; status via ubus, so the UI no longer hangs with qosify stopped
- ACL fixed for non-root users; Quick Settings keeps manual overhead, decimal bandwidth and
  unknown values
- `besteffort` and `precedence` modes added; styling follows the LuCI theme

## v2.4.1 – v2.4.3 — 2026-06-05

- On-device fixes; the v2.4.0 firstboot self-heal hook rolled back to keep.d plus installer copy

## v2.4.0 — 2026-05-31

- `manual` and `docsis` overhead types; separate overhead bytes and MPU fields
- Class detection covers `alias`; rules validated before save; false "not shaping" warning fixed

## v2.3.3 — 2026-05-27

- VA and DF codepoints; inline `#` comments handled; Quick Add rejects CIDR
- Sysupgrade keeps configs and installer

## v2.3.2 — 2026-04-29

- Rewritten as a JavaScript LuCI app — no Lua or luci-compat; standard LuCI APIs; poll refresh

## v2.2 — 2026-04-17

- 25.12 support (lua + luci-compat); amber "running but not shaping"; post-save shaping check

## v2.1 — 2026-04-14

- Quick Add Config and Rule forms; Config Reference panel; corrected CAKE overhead keywords

## v2.0 — 2026-04-13

- Quick Settings form, Active indicator, config validation, backup downloads

## v1.4 — 2026-04-12

- Upload validation; active tab kept after save

## v1.3 — 2026-04-12

- Single controller and template; client-side tabs; status auto-refresh

## v1.2 — 2026-04-12

- Session fix after install/uninstall; better uninstall cleanup

## v1.1 — 2026-04-11

- Tab renames; version shown on Overview

## v1.0 — 2026-04-11

- Initial release: single-script installer, five tabs, QoS disabled on first run
