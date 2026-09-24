# Changelog

All notable changes to `luci-app-qosify`. Versions are the `VERSION=` constant in `qosify-luci.sh`.

## v3.0.9 — 2026-09-24

Fixes from the 2026-09-24 audit. `dev` only for now.

### Fixed

- Start, Restart and a save or Restore that starts qosify left it running with no config
  on 25.12 and master. There `qosify.init` pushes the config from `service_running()`,
  which `rc.common` only calls for `running`, not from `start`. The app now waits for the
  qosify ubus object and sends `reload`; on 24.10 (`service_started()`) that changes nothing.
  The installer's `install` and `reset` do the same (3.0.6 had dropped the extra `reload`)
- The cleanup helper deleted the root qdisc and `clsact` on every enabled section's device,
  whoever owned them. Removing the package with qosify stopped and SQM on the same device
  took SQM's root qdisc with it. The root qdisc and qosify's filters (prefs 272-277) are now
  only deleted when qosify's bpf classifier is still attached, and `clsact` only once no
  filters are left on it
- Shell metacharacters in `bandwidth*`, `mode` and the CAKE `*options` block the Config save
  and Restore upload, and Quick Settings checks the bandwidth fields too. qosify pastes these
  unquoted into a `tc` command it runs with `sh -c` as root. Before, they were only warned
  after the file was written
- `install`, `files`, `uninstall` and `reset` stop when `luci-app-qosify` is installed as an
  apk/opkg package, instead of overwriting or deleting package-owned files

## v3.0.8 — 2026-09-22

### Fixed

- Removing the package left `clsact` on the shaped device and `ifb-dns` up under `fq_codel`.
  qosify's own stop never deletes either (`interface_clear_qdisc()` skips `clsact`, and
  `main()` never calls `qosify_dns_stop()`). A new `prerm` starts a copy of the cleanup
  helper in the background. It waits up to 30 s for qosify to exit, so it still works when
  qosify's prerm runs after this one. If qosify stays installed and running, nothing is touched
- `uninstall` waits for qosify to exit before the sweep instead of `sleep 1`, so `ifb-dns`
  is no longer skipped on a slow stop
- The cleanup helper reads the device names before it waits (`cleanup wait`). With no
  argument, as LuCI calls it, it behaves as before

## v3.0.7 — 2026-09-21

### Fixed

- Rules Quick Add `match` list: the IPv4 and IPv6 entries were blank. They now read
  "IPv4 address, e.g. 1.1.1.1" and "IPv6 address, e.g. ff01::1", as in qosify's README.
  `tcp:<port>[-<endport>]` and the other syntax labels were cut short for the same reason
  (LuCI's `E()` parses a string child as HTML, so `<ipaddr>` became a tag)
- The same fix for the Reference tables: Mapping file syntax (`<ipaddr>`, `<ipv6addr>`,
  `<port>`) and the Quick Settings `overhead`/`overhead_mpu` descriptions (`<bytes>`)

## v3.0.6 — 2026-09-21

Fixes from the 2026-09-21 audit. `dev` only for now.

### Fixed

- A bad `dscp_prio`, `dscp_bulk` or `dscp_icmp` in `config defaults` blocks the Config save and
  Restore upload. qosify rejects the whole `config` call on one of these, so interface changes
  never applied. Bad class `value`/`ingress`/`egress` (qosify drops the class) and bad
  `dscp_default_*` or class `dscp_prio`/`dscp_bulk` (ignored) are warned after save
- Rules save and Restore warn about lines qosify skips without saying so: ports outside
  1-65534 or reversed ranges, CIDR, `%zone`, malformed addresses and lines with a third field
  (qosify reads the rest of the line as the DSCP value). Quick Add uses the same checks
- NQB is only offered and accepted when the running qosify has it. 24.10 and 25.12 run
  `1501e09`, which does not; the Reference says so
- Restore turns CRLF into LF like the editors do, and Quick Settings reads a CRLF config
  correctly. Before, it added duplicate options and could not remove one
- A warning shows when `/etc/qosify/00-defaults.conf` is not matched by `list defaults`,
  because then qosify does not load it and the Rules tab has no effect
- Quick Settings shows an inherited `option bandwidth` as the placeholder, and no longer warns
  "bandwidth not set" when `bandwidth` covers it
- The 1023-byte line check counts the raw line, comment included, as qosify's `fgets` does
- The cleanup helper also deletes `ifb-dns` once qosify has exited. A stop leaves it up
  under the kernel's default `fq_codel`, so Stop and uninstall now remove it too. Only
  devices qosify creates are touched

### Changed

- Quick Add `timeout` placeholder is qosify's default, 3600
- Quick Settings reuses the option descriptions, so translators get 7 fewer near-duplicate strings
- Quick Add controls have `aria-label`s
- The `qosify` template matches openwrt's `qosify.conf` byte for byte (final blank line)
- A stray `option:null` key is gone from Quick Settings
- `install` no longer reloads qosify straight after restarting it

## v3.0.5 — 2026-09-21

### Fixed

- Sections look like the rest of LuCI on every theme. `qosify.css` no longer redraws
  `.cbi-section` as its own 4px box with a grey title strip and no top padding, which on
  Footstrap replaced the theme's card and pushed the title to the top edge instead of
  inside the card. The theme now draws each section, its `h3` and its `cbi-page-actions`;
  folding sections keep only their marker and cursor, and their `summary > h3` keeps the
  theme's heading size

## v3.0.4 — 2026-09-21

Carries the three review fixes that went into openwrt/luci#9046 after v3.0.3, so `main.js`
is again the in-tree file of the #9046–#9054 series with only the installer's
`?v=<VERSION>` stylesheet suffix added. `qosify.css`, ACL, menu, cleanup and templates were
already identical and are unchanged.

### Fixed

- A save no longer fails when `service.list` goes unanswered. The config is already written
  by then, so `applyService()` restarts qosify through `rc init` (a write grant that answers
  when the read half is stale) instead of reporting `Save failed` and leaving qosify on the
  old config. Only the start branch still fails, and it tells an unanswered poll from a
  real timeout
- The "rpcd is not answering" note now also shows when only `qosify status` goes
  unanswered, so an Unknown Shaping row no longer appears without it
- The note sits on the first Overview row that reads Unknown rather than always on Status,
  so a failed `rc.list` no longer puts it next to a known green Running badge

## v3.0.3 — 2026-09-20

### Fixed

A class with only `ingress` or only `egress` set was labelled `foo (CS1/)` or `foo (CS1)` in
the `dscp_*` and Quick Add Rule selects, the second reading as if both directions carried the
value. Both sides are now printed with `-` for the unset one whenever they differ.

## v3.0.2 — 2026-09-20

`qosify.css` is now the in-tree sheet byte for byte, in its expanded form, instead of the
same rules in compact form. The files the installer writes now match the openwrt/luci
series (#9046–#9054) exactly, apart from the installer's `?v=<VERSION>` stylesheet suffix
in `main.js`. No rule, selector or comment changed.

## v3.0.1 — 2026-09-20

Resyncs the installer with the 3.0.0 series as it stands on openwrt/luci (#9046, #9047,
#9048, #9050, #9051, #9052, #9053, #9054), review fixes included. `main.js` is the
in-tree file with only the installer's `?v=<VERSION>` stylesheet suffix added;
`qosify.css` is the in-tree sheet in compact form. ACL, menu, cleanup and templates were
already identical and are unchanged.

### Fixed

- An unanswered `service.list` no longer reads as "stopped". Start, Restart and Save
  report that rpcd is not answering instead of "qosify did not come up", and Stop and
  Config Clear no longer run the cleanup helper, which deletes the root qdisc, on a qosify that
  may still be running
- Each Overview fact goes Unknown only with the call it comes from: a lost `service`
  grant blanks Status, a lost `rc` grant blanks Autostart and `/etc/init.d/qosify`,
  rather than one failure blanking all three
- QoS Enabled shows Disabled for a disabled section even while the state is unknown,
  since that comes from UCI
- Saving with qosify stopped says it is not shaping, not "could not be checked": the
  qosify ubus object goes with the daemon, so `service.list` settles the question
- `reload`, `check_devices`, `get_stats` and `dump` are declared with `reject: true`, so a
  failed call (stale ACL) is reported instead of "Mapping files reloaded." or an empty
  table
- Counters: the get_stats box is hidden when the reply has none of its fields (always
  the case on 24.10/25.12), and a failed call says "get_stats did not answer."
- Counters drops a tick that overlaps the one fired on tab open, as Status already did,
  so `qosify-status` is not forked twice. The in-flight guard on Status is back
- DNS Entries always prints hits / packets / bytes; an idle pattern showed two values
- Uptime is advanced from `performance.now()`, so an NTP step or a date change no longer
  skews it
- Service bar buttons keep their declared order on Bootstrap, whose `.cbi-page-actions`
  floats reordered them by colour class
- Autostart is labelled with the state (Enabled, Disabled, Unknown) and its click acts on
  the last refresh, not on the state at page build
- The QoS Enabled label toggles its checkbox again
- `ingress %s, egress %s` and `(alias)` in the class lists are translatable again, and
  the bare `%s%%` format is no longer in the pot

### Changed

- Overhead tab order: preset, Manual overhead, Encapsulation overhead, MPU, VLAN tags, so
  the two manual-only rows sit together
- The page keeps its description and plain `cbi-map`; the Files table keeps an `h3`
  Files title

### Docs

- `diffserv4` is the daemon's default (`cfg->mode` in `interface.c`); `qosify.init`
  passes `mode` through and has no fallback of its own
- The 3.0.0 notes that the `qosify-status` fork is skipped while the state is unknown,
  and that tabs poll only while open and pause with LuCI's refresh toggle, were wrong or
  described what 2.9.11 already did. The change in 3.0.0 is the interval

## v3.0.0 — 2026-09-19

First release of the 3.x line. It consolidates the whole 3.x development series
(v3.5.0-dev through v3.7.10-dev) into one release on top of v2.9.11. The daemon contract
is unchanged: every option, ubus call and reply field still maps to qosify itself, and
nothing here modifies qosify, its init script or its defaults.

### Layout

- The page is rebuilt on stock LuCI markup — `div.cbi-section` sections with `h3` titles,
  `.table` rows, `.label` badges, `.cbi-value` form rows, `.cbi-section-table` grids and
  `.cbi-progressbar` bars. The `qos-*` classes are gone; `qosify.css` now only draws each
  section as a box using the theme's own colour variables, so the app follows the theme
  rather than overriding it. The active tab is left to the theme, which fixes the
  unreadable filled tab on themes that colour it with the primary colour
- Tabs are Overview, Config, Rules, Status, Counters and Advanced. The page title is
  lowercase `qosify` and the page description is dropped
- The stylesheet link carries `?v=<VERSION>`, set by the installer, so an update is never
  served from the browser cache
- One box and line standard on every tab. Sections, Quick Add folds, the quick settings
  box, the Counters boxes and the `qosify-status` output share one outline
  (`--border-color-medium`), one 4px radius, one title bar (`.45em 1em` on
  `--background-color-low`, underlined in `--border-color-low`) and one `.75em` gap.
  Every table row line is `--border-color-low` with one `.45em .75em` cell padding; only
  the Quick Add form grids stay tighter. The per-tab overrides (roomier Overview, compact
  Counters, smaller Quick Add bars) are gone
- Class and tin colours come from `qosify.css` tokens instead of hex values in `main.js`:
  bulk, best effort, video and voice use the theme's `--error-color-high`,
  `--primary-color-high`, `--warn-color-high` and `--success-color-high`; the extra
  diffserv8 and precedence tins and the per-name fallback use qosify fallbacks with light
  and dark values, switched by LuCI's `data-darkmode` or, on a theme that does not set it,
  `prefers-color-scheme`. The red `danger` badge uses the same token
- LuCI structure: the page is `cbi-map cbi-map-tabbed`, Backup and Restore descriptions
  are `cbi-section-descr`, and the `get_stats` table on Counters is boxed like the other
  three views. Table rows are not striped; every row sits on the same background
- Restore: each file gets a LuCI `cbi-button` (Choose file…) over the hidden native picker,
  which ignores the theme, with the chosen file name beside it; the name clears after an
  upload
- Counters and DNS Entries order AF codepoints by drop precedence within their class:
  AF41, AF42, AF43 top to bottom, and the same for AF3x, AF2x and AF1x. Other codepoints
  keep their order

### Overview

- Service Status and Service Controls merge into one **Service** section: status badge
  (green while shaping, amber while running idle, red when stopped), uptime, autostart,
  a shaping count, `/etc/init.d/qosify`, and one row per interface or device with its
  active state, resolved device, ingress and egress — all moved here from the Status tab
- Uptime is the qosify process's `starttime` from `/proc/<pid>/stat` set against
  `/proc/uptime`, read once per pid, so a reload keeps counting and a restart starts
  again. The ACL read group grants `/proc/uptime` and `/proc/[0-9]*/stat` `read`
- Autostart, Start, Restart, Reload, Reload Rules and Stop sit in a bar at the bottom of
  the Overview tab, so they no longer show under the other tabs; buttons that do not
  apply to the current state are disabled, and Status and Counters ticks no longer touch
  them
- **Reload Rules** is new: `ubus call qosify reload` re-reads only the files in the
  `defaults` list (`qosify_map_reload()`) and leaves the qdiscs and interface config
  alone — what a rules edit needs, without the full config push that Reload does
- **Files** is a single table whose column header is the box title bar, listing both
  config files with validity, section or rule count, size and modification time
- **Quick settings** write straight to the interface or device section of
  `/etc/config/qosify`, in one section titled with the section it edits (e.g. `interface
  wan quick settings`) holding four tabs with one Save & Apply bar under them: Basic
  (`disabled`, `name`, `bandwidth_up`, `bandwidth_down`, `mode`), Shaping (`ingress`,
  `egress`, `autorate_ingress`, `nat`, `host_isolate`), Overhead (`overhead_type`,
  `overhead_vlan`, `overhead`, `overhead_mpu`, `overhead_encap`) and Advanced
  (`ingress_options`, `egress_options`, `options`). The open tab survives the redraw
  after a save
- Quick settings use plain labels with a short description per field in qosify's own
  wording, rather than the raw UCI key. Manual overhead and Encapsulation overhead are
  shown only under `overhead_type manual` and dropped for any other type, since qosify
  ignores them there. `mode` no longer offers an empty choice: unset selects `diffserv4`,
  the value the shipped qosify config carries and `qosify.init` falls back to
- Each quick settings row puts the field and its hint on one line, hints aligned in a
  column, rows separated by the same faint `--border-color-low` hairline the Service
  table uses, and each field sized for its value — 7em for a byte count, 14em for an
  interface name or bandwidth, 18em for a select, 28em for the CAKE option strings.
  Below 600px label, control and hint stack
- Values are validated before writing: `overhead_mpu` and `overhead` must be whole
  numbers of bytes (`overhead` may be negative), option strings are checked for the shell
  metacharacters that would break the `tc` command qosify builds, and bandwidth is
  checked against `tc` rate syntax (including `unlimited`) but passed through with a
  warning rather than blocked, since `tc` is the authority

### Counters (new tab)

- **Traffic by Class** — the per-class packet totals from `ubus call qosify get_stats`:
  class, its `dscp`, a progress bar, then `packets`, `bytes` and share in right-aligned
  columns with grouped digits, and a total row. Bar length is the cube root of each row
  against the largest, so a bulk download does not flatten every other row while the
  share column stays exact. Cells and bars update in place, so nothing below them moves.
  Classes are grouped and coloured by the CAKE tin their egress codepoint lands in —
  red bulk, blue best effort, yellow video, green voice, with the extra diffserv8 and
  precedence tins in their own colours — falling back to a colour per name when the
  shaped sections do not share one mode
- **Traffic by CAKE Tin** — the `qosify-status` output in graph form, egress and ingress
  summed tin by tin from the `pkts` and `bytes` rows `tc` prints, in the same tin
  colours and the same boxed layout, with `tc`'s own `pkts`, `bytes` and `drops` columns
  and `marks` on hover. Qdiscs running a different CAKE mode get a table of their own
- **DNS Entries** — the `dns` entries from `ubus call qosify dump` with `hits`, `packets`
  and `bytes` from the `get_stats` `dns` table, in a box that drags taller or shorter
  like the editors, its header above the box so no row scrolls under it, header padded
  by the scrollbar width so the columns line up. While the entries are unchanged only
  the figures are rewritten, so the list does not move and a text selection holds
- DNS Entries is shown only when `get_stats` carries a `dns` table (qosify `beeb87e`,
  snapshots). On the 24.10 and 25.12 build (`1501e09`) it stays hidden and `dump` is
  never called; it appears by itself on any build that gains the table
- Nothing on the tab outlives the daemon: `get_stats` counts since the last reload and
  the tin figures come from qdiscs a stop removes, so while qosify is stopped the charts
  are cleared and every box but the notice is dropped rather than leaving the last poll's
  numbers on screen looking live. Running with an empty reply says
  `get_stats returned no output.`
- ACL read group grants `qosify` `get_stats` and `dump`

### Config and Rules

- Config Quick Add is three folding sections — defaults, class/alias, interface/device —
  laid out as LuCI section grids with the option names across the top, each with a
  collapsible panel listing every option and its description from the qosify README, plus
  a folding Reference section carrying the defined classes, the accepted DSCP values and
  the defaults qosify applies when a key is absent. `qacSwitch()` is gone, as each form
  now has its own type select and Add button
- Rules Quick Add is one folding row (`match`, value, `dscp`, `+`, Add) with the mapping
  file syntax and the defined classes in collapsible panels, each class listed alongside
  its DSCP value
- Fold state is kept for the browser session
- Both editors sit in their own section, sized so the whole tab fits the window by
  default and refitted when the tab opens, a section folds or the window resizes. The fit
  is measured on the following animation frame: `ui.tabs.switchTab()` walks the panes in
  document order and fires `cbi-tab-active` from inside that loop, so panes after the new
  one are still `data-tab-active` when the handler runs, and measuring in the handler
  counted the tab being left — coming back from Advanced that dropped the editor to its
  160px floor. Repeat calls coalesce, so a resize drag measures once per frame

### Status

- The tab shows only the `qosify-status` output; the per-interface summary moved to the
  Overview Service section. It fetches as soon as it is opened and the scroll position
  survives a refresh

### Advanced

- **Backup** (file, size, modified, Download) and **Restore** (file picker per file,
  Upload & Apply, validated, 64 KB cap, binary rejected) are two boxes
- **Maintenance** adds Check Devices, `ubus call qosify check_devices`, which re-runs the
  daemon's own `qosify_iface_check()` so a device that appeared after qosify started is
  picked up without rebuilding the qdiscs a restart would. The method arms a 10 ms uloop
  timer and returns an empty reply, so the page waits for the pass before refreshing and
  the result shows in the Overview Service table
- **Defaults** resets both files back to qosify defaults after a confirmation
- ACL write group grants `reload` and `check_devices` on the qosify ubus object

### Service state and polling

- Service state is tri-state: a status call rpcd never answered no longer reads as a
  stopped, unshaped, uninstalled qosify. `rc.list`, `service.list` and `qosify.status`
  are declared with `reject:true` — without it a ubus status code (6 once the session's
  ACL no longer covers the object, 4 when the object is gone) stays in `result[0]` and
  `expect{'':{}}` rewrites it to the same `{}` a working call with nothing to report
  returns, so `L.resolveDefault()` could not tell the two apart. `gatherCtx()` catches
  each rejection to `null`, and `running`, `enabled`, `hasInit`, `active` and `shaped`
  go `null` rather than `false`
- Overview shows amber **Unknown** badges for Status, Autostart, Shaping and
  `/etc/init.d/qosify`, with the cause named once on the Status row. Unknown is not
  Missing, so the service buttons stay clickable and report the call's own error
- Saving a config or rules edit no longer warns "not shaping" when the check could not
  run; the save says shaping could not be checked instead. Status and Counters say rpcd
  is not answering rather than "qosify is not running", and skip the `qosify-status` fork
  while the state is unknown
- Overview, Status and Counters tick at LuCI's poll interval
  (`luci.main.pollinterval`, 5 s unless set) instead of a fixed 10 s, and pause with
  LuCI's own header refresh toggle, each only while its tab is open. The in-flight guards
  are gone — `Poll.step()` already holds the next tick until the last promise settles

### Fixed

- Config and Rules editors no longer shrink to the theme's 210px textarea width with no
  way to widen them. Width was carried by a class (`.qos-edit` in the in-tree package,
  the inline `style` attribute here) while height and `resize` were keyed on the ids, so
  a `qosify.css` from the other tree at the same path kept the ids matching and lost the
  width, leaving the theme's `textarea{width:210px}` to win under `resize:vertical`.
  Width now sits on the id selector with `box-sizing:border-box`, and the editors are
  `resize:both` so a wrong width is correctable
- Overview threw `TypeError: Cannot read properties of null (reading 'insertBefore')` and
  the page did not render: `ui.tabs.initTabGroup()` inserts the tab menu before the
  panes' parent in its own parent, and the quick settings sub-tab group was initialised
  before it was wrapped. It is wrapped first now

### Repository

- `main` moves to 3.0.0: `dev-align-main` merged over v2.9.11, whose review fixes it
  already carried. The installer URLs in the README point at `main` again
- README: `migrate` is back in the command table, and a new OpenWrt package section says
  where the in-tree package stands (snapshots ship the 2.9.x code until the 3.0.0 series
  lands in openwrt/luci) and how to build this `Makefile` in the SDK or buildroot
- Feed `Makefile`: postinst and postrm clear the LuCI caches and reload rpcd the way
  `luci.mk` does (`/etc/init.d/rpcd reload` rather than `killall -HUP rpcd`), the
  description uses the in-tree `LUCI_DESCRIPTION` wording, and `PKG_BUILD_DIR` is dropped
  since `package.mk` sets the same path

## v2.9.11 — 2026-09-15

Review fixes for #9019. Comments only, no functional changes.

- The call counts were wrong. A page load is eight ubus calls, not five: `uci.load()`
  issues a `uci get` alongside `gatherCtx(true)`'s seven (`service.list`, `rc.list`,
  `qosify.status`, and a `file.stat` and `file.read` per config file). An Overview tick
  is six: the `uci get` plus `gatherCtx(false)`'s five. The `refreshOverview()` and
  `installPollers()` comments are corrected; the "5 calls" in v2.9.0 and "five ubus
  calls" in v2.9.3 below carry the same error
- The cleanup helper's comment claimed the ifb is removed after its parent has gone, citing a
  pppoe device. `network_get_device` reads `.l3_device`, which netifd only publishes while
  the interface is up, so for a `config interface` the name is gone with the device and
  that path is unreachable; it only holds for `config device`. The comment now says so and
  names the path that does reach the orphan: `interface_start()` in qosify's
  `interface.c` calls `interface_clear_qdisc()`, which deletes `ifb-<dev>`, before
  `cmd_add_ingress()` recreates it when the interface next comes up

## v2.9.10 — 2026-09-15

Feed `Makefile` metadata. No functional changes.

- `PKG_MAINTAINER` changed from the bare GitHub handle `choppyc79` to
  `Ash Clarke <clarkeaj@hotmail.co.uk>`, the `Name <email>` form OpenWrt expects and the
  value the in-tree `openwrt/luci` package already carries

## v2.9.9 — 2026-09-15

Feed `Makefile` tidy-up. No functional changes.

- `PKG_LICENSE` corrected from `GPL-2.0-only` to `MIT`, matching the
  `SPDX-License-Identifier` in every shipped file, the README and the in-tree
  `openwrt/luci` package
- `Build/Compile` continuation lines indented with tabs only; they mixed a tab with
  alignment spaces

## v2.9.8 — 2026-09-15

Packaging and uninstaller fixes. No new features.

- The feed `Makefile` never installed `qosify.css`. `install_view` writes it into the
  staging root alongside `main.js`, but only `main.js` was copied into the package, so a
  feed or ImageBuilder build shipped the view without its stylesheet
- `uninstall` no longer falls back to removing every `ifb-*` device on the system when the
  cleanup helper is missing. It carried the same flaw v2.9.7 removed from the helper itself,
  and it is not needed: `/etc/init.d/qosify stop` lets qosify clear its own qdiscs and ifb
  devices, and without the helper there is no safe list of names to remove

## v2.9.7 — 2026-09-15

Review fixes for the cleanup helper. No new features.

- Sections with `disabled 1` are skipped. `add_interface()` in `qosify.init` returns on
  `config_get_bool disabled` before reading `name`, so qosify never touched those devices.
  The shipped config has `config interface wan` and `config device wandev` both disabled
  with `name wan`, so on an unmodified install a Stop ran `tc qdisc del dev ... root` on a
  device qosify never shaped, taking out an sqm-scripts shaper on the same interface
- The trailing loop that removed every `ifb-*` device on the system is gone. The `ifb-`
  prefix is not exclusive to qosify, and the loop contradicted the helper's own promise to
  touch only what qosify created. Removal is now limited to the name
  `interface_ifb_name()` derives from each enabled section's device, and is no longer gated
  on that device still existing, so an ifb whose parent has gone away is still cleaned up

## v2.9.6 — 2026-09-11

Review fixes for the v2.9.5 upstream PR. No new features.

- The Status tab is back on a fixed 10 s tick. v2.9.3 moved it to `LuCI.env.pollinterval`,
  whose shipped default is 5 (`luci-base/root/etc/config/luci`), so while the tab was open
  the `qosify-status` fork — and the two `tc` forks per active interface behind it — ran
  twice as often as before, which is the opposite of what the change set out to do. The
  `|| 5` fallback was dead either way: `Poll.add()` already falls back to `env.pollinterval`
  when the interval is null
- `min-height: 340px` and `max-height: 75vh` dropped from `.qos-pre`. `#qos-st-pre` is the
  only element carrying that class, and the rule below it overrode both with
  `min-height: 320px` / `max-height: none`, so the two declarations were dead and the two
  min-heights disagreed. The now-redundant `max-height: none` goes with them

## v2.9.5 — 2026-09-11

- The Config and Classification Rules editors size to the window the same way the Status
  output now does — `height: calc(100vh - 300px)`, `min-height: 320px`, `resize: vertical` —
  instead of a fixed 28 rows. Each is the last element on its tab, so only the Save & Apply
  row sits below it. The `rows` attribute stays as the fallback for a page loaded without
  the stylesheet

## v2.9.4 — 2026-09-11

- The `qosify-status` box on the Status tab now fills the page instead of stopping at a fixed
  height: `height: calc(100vh - 310px)` for the LuCI header, the tab bar and the summary
  table above it, with `min-height: 320px` catching short screens where the calc goes
  negative, and `resize: vertical` so it can be dragged for anything the estimate gets
  wrong. The tab holds nothing else, so there is nothing below it to push off screen

## v2.9.3 — 2026-09-11

- The Status tab now polls at the interval configured for LuCI (`LuCI.env.pollinterval`,
  5 s by default) instead of a hardcoded 10 s, so the CAKE counters move at the same rate as
  every other status page. v2.9.0 slowed it to 10 s because a tick rebuilt the pane and
  re-ran the fork in series; with the summary and the `tc` output fetched separately, the
  `<pre>` patched in place and overlapping refreshes dropped, the shorter interval costs no
  more than one `qosify-status` run per tick. `Poll.step()` also withholds the next tick
  until the promise the poller returns settles, so a fork slower than the interval skips
  ticks rather than queueing them
- Overview keeps its own 10 s tick: five ubus calls, no forks, and nothing on it changes
  second to second

## v2.9.2 — 2026-09-11

Status tab responsiveness.

- Opening the Status tab fetches immediately. The `qosify-status` output was only fetched by
  the 10 s poller, so the tab could sit on "returned no output" for up to ten seconds after
  a click. `initTabGroup` dispatches `cbi-tab-active` from a `requestAnimationFrame`, so the
  pane is in the DOM and the fetch can be hung off the tab becoming active
- "Not read yet" and "read, nothing came back" are no longer the same screen: the tab shows
  "Reading tc output..." until the fork returns, and only reports no output once it has
- The per-interface summary paints as soon as `ubus call qosify status` lands instead of
  waiting behind the fork, which is the slow part — `qosify-status` runs `tc` twice per
  active interface
- The Status refresh makes its own three calls rather than reusing `gatherCtx()`'s six; the
  two file stats and `rc.list` only ever fed the Overview. `gatherCtx()` no longer carries
  the exec at all, and overlapping refreshes are dropped instead of queued
- The `<pre>` is patched in place rather than rebuilt, so a poll tick no longer resets the
  scroll position mid-read, and the box grew from a fixed 460 px to `min-height: 340px` /
  `max-height: 75vh` with horizontal scrolling instead of wrapped `tc` lines
- Template regenerated: 211 to 212 strings

## v2.9.1 — 2026-09-11

Review fixes for the v2.9.0 upstream PR. No new features.

- Emptying the Config editor and clicking Save & Apply truncates `/etc/config/qosify`, and
  that path skipped both guards the rest of the commit adds. It now goes through
  `confirmFresh()` and refuses outright when the file is non-empty on disk but the editor
  never loaded it — a failed `gatherCtx()` read leaves the editor empty while stamping the
  real size and mtime, so `fileMoved()` sees nothing wrong and one click would have wiped
  the file the notification just promised not to touch. `dataset.orig` separates "the user
  emptied it" from "it never loaded"
- The same path dropped the `waitForStopped()` result and ran the cleanup helper regardless,
  tearing down the root/clsact qdiscs and the ifb devices under a live daemon. It now only
  runs once qosify is confirmed down, the same guard `svcAction('stop')` uses, and reports
  when it is skipped
- The cleanup helper takes an `flock` on an open fd instead of an mkdir lock with an `EXIT`
  trap. rpcd SIGKILLs the script at its exec timeout (`rpc_file_exec_timeout_cb()` in
  `file.c`, 120 s by default), the trap never ran, and the leftover directory made every
  later invocation `exit 0` silently — the opposite of the lock's intent. The kernel drops
  an flock however the process dies. The lock path changed so a stale directory from an
  earlier version cannot break the new redirect, and a busybox built without `flock` runs
  unlocked rather than not at all
- Template regenerated: 209 to 211 strings

## v2.9.0 — 2026-09-10

Full audit follow-up. Every finding from the package audit is fixed, along with the
performance work that came out of it. Largest change since the upstream merge.

### Service control was silently broken

- `luci.setInitAction` was removed from `luci-base` (commit `4440b267d`, 2 Aug 2026) and
  every service button called it. Because `rpc.declare` treats a remote exception as a
  resolved value unless `reject` is set, the page reported success while doing nothing.
  All service control now uses the `rc` ubus namespace, which is compiled into the rpcd
  core binary — no new dependency
- Start and stop wait for the daemon to actually change state and report a real failure
  if it does not
- The cleanup helper only runs once the daemon is confirmed stopped

### Data loss paths

- Quick Settings read `/etc/config/qosify` with an empty-string fallback; a failed read
  became a "create" and replaced the whole file with a single section, taking every class
  and the defaults section with it. The read now aborts the save, and a save is refused if
  the file is non-empty on disk but came back empty
- Both editors record the size and mtime they loaded from and prompt before overwriting a
  file that changed underneath them
- Saving one file no longer discards unsaved edits in the other editor
- Reset writes the two files one at a time and names the one that failed
- Downloads no longer revoke the object URL before the browser has taken it, and a failed
  read no longer hands out an empty file as if it were a backup

### Daemon semantics

- Booleans are read the way their actual reader reads them: `ingress`, `egress`, `nat`,
  `host_isolate` and `autorate_ingress` go through `json_add_boolean`, which converts with
  `!!atoi()`, so `option nat 'true'` means **off**; `disabled` goes through
  `config_get_bool`, which does accept the word forms. Values that do not survive the
  conversion are now linted
- `config` headers with a trailing `# comment` or a `;` separator are valid UCI and are
  recognised — previously they were missed and a Quick Settings save could append a
  duplicate section
- The options lint flags every shell metacharacter, not just `'`: qosify assembles the `tc`
  command as a string and runs it with `sh -c`
- Raw DSCP values are read with `strtoul(base 0)` semantics, so `077` (63) is no longer
  reported as out of range
- Rule lines with a single field are reported as lines qosify will skip instead of blocking
  the save; lines over 1023 characters are rejected, since the loader reads fixed-size lines
- Ports accept hex (`0x1bb`) to match the daemon's parser, and IPv6 accepts the IPv4-mapped
  form that `inet_pton` accepts
- Bandwidth accepts `unlimited` and `tc`'s byte-rate and binary suffixes, and warns instead
  of blocking on anything else — `tc` is the authority
- `setOpts()` refuses to patch a key that exists as a `list` rather than writing an `option`
  beside it
- Quick Add reports an invalid section name instead of silently stripping characters, and
  duplicate detection parses the buffer instead of regex-matching one quoting style
- The non-existent `option option` fallback was dropped

### LuCI conformance

- Read-only sessions (`L.hasViewPermission()`) get a read-only page instead of live buttons
  that fail with permission errors
- All 15 `confirm()`/`alert()` calls replaced with `ui.showModal` and `ui.addNotification`
- The last `innerHTML` — and the `esc()` helper that existed to feed it — is gone
- Tabs use `ui.tabs.initTabGroup`; hash deep links still work, and the `setTimeout(0)` that
  waited for DOM insertion is gone
- CSS moved to a shipped `qosify.css` loaded with `L.resource`, replacing the inline
  `<style>` block, the `!important` button overrides (now `cbi-button-positive`,
  `cbi-button-negative`, `cbi-button-reload`) and the hardcoded light-theme colours. The
  status pane follows the active theme instead of a fixed dark box
- Form labels are associated with their controls
- Every user-visible string goes through `_()`, including placeholders and examples, and the
  rule count uses `N_()`. Template regenerated: 168 to 209 strings

### Performance

- A page load went from 10 backend calls with two shell forks to 5 calls with none: the dead
  `/usr/sbin/qosify` stat is gone, autostart state comes from `rc.list` with
  `skip_running_check` (a stat of `/etc/rc.d/S19qosify` instead of a fork, which also avoids
  the init script's 10 s `ubus wait_for` against rpcd's 3 s cap), and shaping state comes
  from `ubus call qosify status` instead of forking `qosify-status`, which itself forks `tc`
  twice per active interface
- The 10-second poll no longer re-reads both config files — their full contents were
  crossing the wire twice a tick — and patches the service table in place instead of
  rebuilding three fieldsets, so clicks and focus survive a refresh
- Saves issue a `reload` rather than a `restart`: `ubus call qosify config` re-reads the rule
  files and only touches interfaces whose config changed, so shaping is no longer torn down
  and rebuilt and dynamic DNS/IP map entries survive a save
- The Status tab polls every 10 s instead of 5, skips while a save holds the lock, and shows
  a fork-free per-interface summary above the detailed `tc` output

### Cleanup helper rewritten

- No longer deletes the root qdisc on a hardcoded `pppoe-wan` — or, in the uninstaller, on
  `br-lan` — which could destroy SQM's or a hand-built shaper's qdisc from a qosify Stop
- Sections are enumerated with `config_foreach`, and `config interface` names are resolved to
  their L3 device with `network_get_device`, so renamed, extra and anonymous sections are all
  handled and egress-only sections are no longer missed
- The ifb device name is derived the way qosify derives it instead of by reversing the prefix
- A mkdir-based lock stops a double click or a stop-then-start race from removing qdiscs the
  daemon has just created; orphaned `ifb-*` devices are still swept, but no foreign qdisc is
  touched

### Packaging

- `LUCI_DEPENDS` gained `+luci-base`; it was missing, so nothing guaranteed `rpcd-mod-file`,
  which the entire UI depends on
- Redundant `LUCI_PKGARCH:=all` dropped; licence header and template provenance comment added
- ACL rebuilt: `exec` grants moved to the write scope, the `/etc/init.d/qosify` and
  `/usr/sbin/qosify` grants dropped entirely (no longer used), `list` dropped from the file
  methods, `stat` paths granted the permission `file.stat` actually checks, and grants added
  for `rc.list`, `rc.init` and `qosify.status`

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
