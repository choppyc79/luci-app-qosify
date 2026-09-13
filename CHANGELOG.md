# Changelog

All notable changes to `luci-app-qosify`. Versions are the `VERSION=` constant in `qosify-luci.sh`.

## v2.20.3 — 2026-09-13

- Map entries: the Traffic column is dropped where the running daemon has no
  per-entry counters, with one line saying why, instead of a dash on every row.
  24.10 pins qosify at 2024-09-20 (`1501e09`), whose `get_stats` answers with
  `qosify_map_stats()` at the top level — one table per class with `packets`, no
  `dns` table anywhere. Master opens that table even when it is empty, so its
  absence identifies the build rather than a quiet period; before the first
  counters reply the column is kept, and the box is rebuilt on the next tick

## v2.20.2 — 2026-09-13

- Map entries: the header is pinned properly now. The declarations moved out of
  `qosify.css` and onto the header cells themselves: the stylesheet a menu node
  declares is emitted with no cache-busting query, so a browser holding the old
  copy keeps the old rules, and the theme variable the background came from is
  not defined by every theme — a variable that *is* defined but invalid computes
  to `unset`, which leaves the cell transparent and the rows visible through it.
  The cells now set `position: sticky`, `z-index: 3` and a background/colour pair
  that falls back to the system colours together, so it stays a readable pair
- Map entries: rows are ordered by the DSCP value behind the entry, highest
  first — EF at the top, LE and CS0 at the end. `blobmsg_add_dscp()` prints a
  class name where the class flag is set, so class names are resolved through the
  section that defined them (`egress`, then `ingress`, both falling back to
  `value` as `add_class()` does); a raw value goes through the same bases
  `strtoul(base 0)` takes, and anything `__qosify_map_dscp_value()` would have
  rejected sorts last. Dynamic entries keep their place below the file entries
  and are ordered the same way within that block. Port ranges still collapse —
  they are merged on the way in, while the reply is still in ascending order

## v2.20.1 — 2026-09-13

- Map entries: the table header stays at the top of the scroll box instead of
  scrolling away with the rows. `.table` is `border-collapse`, so the cells carry
  `position: sticky` rather than the `<tr>`, and the rule under the header is an
  inset shadow — a border on a sticky cell is dropped
- Map entries: entries the daemon added itself from a DNS lookup are listed after
  the ones the config loaded. They carry a timeout and no counters of their own,
  and a DNS-driven config has hundreds of them, so the 200-row cap now falls on
  addresses that come back on the next lookup rather than on the rules. Port
  ranges still collapse, and an entry present in both a file and the dynamic set
  stays with the file entries
- Map entries: a DNS row shows hits as well as packets. `qosify_map_dns_stats()`
  reports both, and `qosify_map_lookup_dns_entry()` counts a hit on every pattern
  that matches a name, not only the one whose DSCP wins. Packets are accounted in
  the eBPF datapath against the `pattern_id` in the address map entry, which
  `__qosify_map_set_entry()` writes only where the DSCP changes — always true for
  a new address, never for one already in the map at that DSCP, which keeps the
  `pattern_id` of whatever put it there

## v2.20.0 — 2026-09-13

- The Classification Rules editor now checks the match side of a rule, not just
  the DSCP target. Everything it flags is something `qosify_map_parse_line()`
  drops without a word, so the only symptom used to be a rule missing from
  Map entries:
  - a key with no recognised prefix and no `:` or `.` matches no branch at all
  - a bare key with a letter in it was meant as a hostname — a dotted quad holds
    none — so it needs `dns:`, `dns_q:` or `dns_c:`
  - ports get the `qosify_map_set_port()` rules: base-0 parsing, non-zero start,
    end not below start, nothing from 65535 up
  - bare addresses get the `inet_pton()` rules — no prefix length, no zone suffix
  - a `dns:/` or `dns_c:/` regex is checked for balance, and for uppercase:
    `__qosify_map_alloc_entry()` lowercases the pattern *before* `regcomp()`, so
    `[A-Z]` silently becomes `[a-z]`
  - an empty `dns:` pattern or empty regex matches nothing
- `dns_q:` is recognised. It sets `CL_MAP_DNS` with `only_cname` clear, so it is
  the plain-pattern form and behaves exactly like `dns:`
- A third field on a rule line is flagged. The parser ends the key at the first
  space and takes all of the remainder as one DSCP target, so `tcp:80 voice extra`
  parses as nothing

## v2.19.0 — 2026-09-13

- Class and alias sections are linted, against `qosify_map_create_class()` in
  `map.c` rather than the init script:
  - a class's own `ingress`/`egress`/`value` goes through
    `__qosify_map_dscp_value()`, not `qosify_map_dscp_value()`, so it takes a
    codepoint or a raw number and nothing else. Naming another class there fails
    and the daemon frees the slot, dropping the whole class — and every rule that
    targets it. Quick Add already offered codepoints only; a hand-edited config
    had nothing to warn it
  - a class with no `value`, `ingress` or `egress` is not an error to qosify:
    `json_add_string` always emits the key and `strtoul("")` yields 0, so the
    class silently becomes CS0
  - `QOSIFY_MAX_CLASS_ENTRIES` is 16 and covers `class` and `alias` together;
    `qosify_map_get_class_id()` returns -1 once the slots are gone, so sections
    past the sixteenth are dropped. The count is flagged with how many are lost

## v2.18.2 — 2026-09-13

- The Counters row reads **eBPF IP map entries**.
  `qosify_map_get_ebpf_entry_count()` sums the IPv4 and IPv6 address maps and
  nothing else — the port maps are fixed 65536-entry arrays and are never
  counted — so the old label over-claimed
- The Config Reference notes that `NQB` needs a qosify newer than the one
  OpenWrt pinned for 24.10. `1501e09` has no `NQB` entry in its codepoint table,
  so `__qosify_map_dscp_value()` rejects the value and the rule disappears
- The rule line-length limit is 1022 characters of raw line, not 1023 of the
  comment-stripped remainder. `__qosify_map_load_file_data()` reads with
  `fgets()` into `char line[1024]`, which takes at most 1023 bytes *including*
  the newline, and the comment is stripped after the read rather than before

## v2.18.1 — 2026-09-12

- Advanced is laid out like Overview: every section is a `cbi-section` holding one
  ruled two-column `qos-kv` table, with its buttons in a `qos-svc` row under a
  dividing line, instead of the mix of `cbi-value` rows and bare page actions it
  had. Both tabs now read the same way
- The file rows carry `<label for>` on the upload inputs and the Counters
  checkbox, so the label is clickable
- `dlRow()` became `dlBtn()` and the shared `kvTable()` helper now builds these
  tables, so the Advanced sections are declarative and the download button can
  sit in the same table as everything else
- Reset spells out what it replaces, one row per file

## v2.18.0 — 2026-09-12

- The Counters tab toggle survives logout. It moved from `session` (sessionStorage,
  cleared with the browser session) to `localStorage`, so it is a per-browser view
  preference that stays put — still not in UCI, since qosify owns
  `/etc/config/qosify` and `/etc/config/luci` would mean widening the ACL for a
  cosmetic setting. Access is guarded, because a private-mode browser throws on
  it. `'require session'` is gone with it
- Advanced is one section per job, in the order you would use them: **Backup**,
  **Restore**, **Reset**, **Display**. The toggle lives under Display with the
  what-it-does line beside the checkbox instead of above the section
- Descriptions shortened across the app and kept to what qosify actually does —
  the page header, Quick Settings, Config, Classification Rules, both Counters
  sections, the bar-chart note and the three map-table footnotes. Examples:
  the map footnote is now "Timeouts apply to dynamic entries only.", and the
  Counters section reads "Totals since qosify last reloaded."

## v2.17.0 — 2026-09-12

- The map listing has its own poll queue entry at three times the page interval,
  rather than riding the page tick. It is the one heavy read here — a DNS-driven
  config is hundreds of entries and tens of kilobytes per reply — while its
  contents change far more slowly than the counters beside it, so at the 5 s
  default the counters still move every 5 s and the listing every 15 s
- `poll.add()` keeps an interval per queue entry, so this stays inside LuCI's own
  machinery: the slower entry still stops with the auto-refresh toggle, still
  tracks `luci.main.pollinterval` as a multiple of it, and still gets
  `poll.step()`'s overlap protection. No timers of our own
- The listing's Traffic column reuses the `get_stats` reply the counters just
  fetched instead of asking again, so `refreshMapEntries()` is exactly one ubus
  call and `refreshCounters()` is two
- Opening the tab fetches both at once, and the box shows a reading placeholder
  until the first listing lands rather than sitting empty

## v2.16.0 — 2026-09-12

- The page poller follows LuCI rather than its own clock. `poll.add()` is called
  with no interval, so `L.env.pollinterval` applies — `uci get
  luci.main.pollinterval`, 5 s by default (`header.ut` falls back to 5, and
  `poll.add()` substitutes `env.pollinterval` for a null interval) — instead of
  the hardcoded 10 s. Both Status and Counters follow it, as does Overview
- That also means the theme's auto-refresh toggle stops and starts these tabs
  like any other LuCI page, and changing `luci.main.pollinterval` changes them
  with it
- Unchanged: one poller for the whole page dispatched on the open tab, and
  `poll.step()` holding the next tick until the current one settles, so a
  `qosify-status` fork slower than the interval skips ticks rather than stacking
  up — which matters more now the default interval is half what it was

## v2.15.1 — 2026-09-12

- Fixed `TypeError: Cannot read properties of undefined (reading 'getLocalData')`
  when the page loaded. `session` is one of luci-base's preloadable classes, not
  a property of `L`: it is reached through the module header, so the view now
  declares `'require session'` and calls `session.getLocalData()` /
  `setLocalData()` directly. Present on every supported branch — 22.03, 23.05,
  24.10 and master all ship it

## v2.15.0 — 2026-09-12

- The per-class chart is packet totals on a log axis and nothing else: the unit
  and scale select is gone, along with the linear and byte modes behind it
- Each class gets its own colour, assigned by the class name's position in the
  sorted set so a class keeps its colour as the bars reorder by size, with a
  matching swatch in the label
- The **Classes** counters table is gone — it duplicated the chart. The chart now
  carries the figures: packet total and share of all classified packets per row,
  and a total row closing it out. A non-zero share under a tenth of a percent
  reads `<0.1%` instead of `0.0%`, which read as nothing counted at all
- Row hover gives the exact packet and byte totals, and highlights the row
- Restyled: taller tracks, rounded fills at 85% opacity, swatch in a monospace
  label column, tabular-aligned figures with the share in its own right-aligned
  column, a ruled total row, and wider columns on narrow screens
- The DSCP and DNS-pattern tables are unchanged and still carry the rest of the
  `get_stats` reply

## v2.14.0 — 2026-09-12

- The Counters graph is now a horizontal bar chart of **totals per class**, not
  packets per second. `get_stats` reports cumulative counts, so the totals are
  the daemon's own numbers since its last reload — no sampling, no history kept
  in the browser, and nothing lost by leaving the tab closed. The rate sampler,
  its 60-sample window and the SVG polyline graph are gone
- One select drives the chart: packets or bytes, linear or log scale. A bulk
  class can outweigh voice by four orders of magnitude, which leaves every other
  bar a sliver on a linear axis, so the log option is offered and labelled as one
  rather than quietly distorting the linear bars. Bars are sorted by size, scaled
  against the largest class, and keep a sliver for any non-zero class. Byte
  options are taken off the select unless the reply carries byte totals, which
  the 24.10 daemon does not
- Plain CSS flex bars using `currentColor` over a neutral track, tabular-aligned
  values and a monospace label column, narrowing on small screens. No SVG, no
  charting library, nothing added to `LUCI_DEPENDS`
- The Counters tab is hidden by default and shown from **Advanced → Page**, which
  is only sensible now the numbers are totals. `initTabGroup()` puts `data-tab`
  on each menu `<li>`, so the entry is taken off the menu without rebuilding the
  group; the preference lives in `L.session` (luci-base's per-session store), not
  in `/etc/config/qosify`, which qosify owns. A link to `#counters` shows the tab
  regardless
- The visibility checkbox and the chart select carry `data-ro-ok`, so read-only
  sessions keep both — the whole tab works without write access

## v2.13.0 — 2026-09-12

- New **Counters** tab. Daemon counters and Map entries move off the Status tab,
  which goes back to being the shaper's own view of itself — ubus status plus the
  `qosify-status` fork. The new tab is two ubus calls and no forks, so it works
  under read-only access, and it polls on the same single 10 s tick only while it
  is open
- Packets-per-second graph per class, plotted over the last 60 samples. `get_stats`
  reports cumulative counts, so each point is the difference between two samples
  over the elapsed time; a count that goes backwards means the daemon restarted,
  so that class is dropped from the sample rather than drawn as a spike
- The graph is inline SVG built through `createElementNS` — `E()` goes through
  `createElement()`, which cannot make SVG nodes, and `innerHTML` is not an
  option. No charting library, no new dependency. Gridlines, labels and the time
  caption use `currentColor` so the theme decides; only the series colours are
  fixed, which is what luci-mod-status does for its realtime graphs
- Map entries sits in a scrollable box, rebuilt in place on each tick with its
  scroll offset preserved, so a 200-row listing stays readable while it updates
- `refreshStatus()` dropped its `get_stats` call, since the Status tab no longer
  renders counters

## v2.12.0 — 2026-09-12

- **Map entries** gained a Traffic column: the packets and bytes each DNS pattern
  has matched, read from the `dns` table of `get_stats` and joined to the dump
  rows by pattern. `refreshMap()` now fetches both methods together so the
  numbers and the entries come from the same moment
- The column is honest about where the daemon stops counting.
  `qosify_map_dns_stats()` sums the per-CPU `pattern_stats` map, which exists for
  DNS patterns only; the port and address maps hold a DSCP byte and no counters,
  so those rows show `-` and a note points at the class and DSCP totals in Daemon
  counters. A pattern missing from the stats reply is shown as zero, since
  `qosify_map_dns_stats()` omits patterns with no hits and no traffic — but only
  when the reply has a `dns` table at all, otherwise every row shows `-`

## v2.11.4 — 2026-09-12

- Removed the **File** selector and its file count from the Classification Rules
  tab, along with `switchRules()` and `loadRules()` behind it — one mapping file
  is what the shipped `list defaults` resolves to, so the selector was scaffolding
- The edited path is now resolved from the defaults list in `load()`, before the
  file is read, rather than after it in `gatherCtx()`: the editor content and the
  path shown in the section description can no longer come from different files

## v2.11.3 — 2026-09-12

- Map entries notes once, under the table, that qosify only reports a timeout for
  dynamically added entries (`qosify_map_dump()` emits `timeout` for `user`
  entries only), instead of leaving a column of dashes against every file entry
  looking like a fault

## v2.11.2 — 2026-09-12

- **Map entries** collapses expanded port ranges. `qosify_map_set_port()` in
  `map.c` loops `start_port..end_port` and stores one map entry per port, so a
  single `udp:6881-7000` rule filled 120 of the table's 200 rows and pushed
  everything else past the cap. Consecutive ports that agree on type, DSCP,
  source and timeout are now shown as the range they came from — ports arrive in
  ascending order because the avl key holds them in network byte order, and a
  reply in any other order simply does not collapse. Nothing else is merged
- The table now always prints its row and entry counts, so an empty panel is
  distinguishable from one that has not been fetched
- The open Map entries panel refreshes with the rest of the Status tab instead of
  only when it is toggled, so dynamically added entries and their timeouts move
  while it is on screen

## v2.11.1 — 2026-09-12

- **Daemon counters** now render only what `get_stats` actually returns. The
  reply shape follows the daemon build: the commit OpenWrt pins on master
  (2026-06-22) reports `ebpf_map_entries`, `last_reload_time`, `dns_cache` and
  the `classes`/`dscp`/`dns` tables, while the commit pinned for 24.10
  (2024-09-20, `1501e09`) returns `qosify_map_stats()` at the top level — one
  table per class, `packets` only, no wrapper and none of the other keys. On that
  older daemon the panel showed `eBPF map entries -`, `Last reload -` and no
  counter tables at all; it now shows the per-class packet counts the daemon
  does report, and omits the rows it does not
- Byte totals are only printed when the daemon sends `bytes`, since the 24.10
  build counts packets only
- Map entries no longer disappears with the counters: it comes from `dump`, which
  is identical in both commits, so the panel follows the running state instead of
  the counters reply
- Corrected the `rpc.declare` comment: `get_stats` and `dump` are both present in
  the 24.10-pinned commit — it is the fields inside `get_stats` that are newer,
  not the methods

## v2.11.0 — 2026-09-12

Audit pass over the installer itself rather than the view: the shell wrapper, the
service lifecycle and the cleanup helper, each finding checked against `luci-base`,
`rpcd` and `qosify` source before it was changed.

- The cleanup helper now skips `disabled` sections. `add_interface()` in
  `qosify.init` returns early on `disabled`, so qosify never created a qdisc on
  those devices — deleting the root qdisc there took out whatever else owned the
  device (sqm-scripts, a manual `tc` setup), which is exactly what the helper's
  own comment promises it will not do. Their `ifb-*` devices are still swept up
  by the orphan pass, which only removes devices qosify creates
- `install` no longer restarts the web server. ACL files are globbed per login in
  `rpc_login_setup_acls()` (rpcd `session.c`), the ucode dispatcher keys its page
  tree cache on an ino/mtime/size hash of `menu.d` and prunes stale entries
  itself (`dispatcher.uc`), and nothing but the browser caches `/www` — so the
  `uhttpd`/`nginx` restart only dropped every in-flight connection, including the
  session running the install. `rpcd restart` and the Ctrl+F5 note stay
- One service transition per install instead of four. `install_deps` no longer
  starts qosify before the templates are written, and the `sleep 1; reload` after
  the final `restart` is gone: `service_running()` in `qosify.init` waits for the
  ubus object and calls `reload_service()` itself, so the manual reload fired
  while the daemon was often still absent and its `ubus call qosify config`
  failed silently
- Every install write is verified through one `ck()` helper — templates, menu,
  ACL, keep list, seeded configs and both view files. Previously only `main.js`
  and `qosify.css` were checked, so a full or read-only overlay produced a
  half-installed app that still printed `[OK]`
- `uninstall` waits for the qosify ubus object to disappear (up to 5 s) before
  running cleanup, instead of a fixed `sleep 1` — the same guard the UI applies
  to a stop
- The stylesheet is declared as `"css"` on the menu entry, which the theme header
  emits as `dispatched.css` before the view runs, removing the flash of unstyled
  content; the view still injects the link, but only when it is absent
- A poll tick no longer lists `/etc/qosify`. The listing feeds the Rules tab file
  selector only, which is built from the load-time context, so the 10 s Overview
  tick is back to the five ubus calls its comment claims
- `save_installer` checks that `$0` really is this installer before copying it to
  `/root`, which it is not when the script is piped into `sh`
- An unknown or missing command exits 1 instead of 0
- `qosify.pot` regenerated with the upstream `i18n-scan.pl`: it was 30 msgids
  behind the view
- SPDX identifier added to the installer, which every file it writes already had

## v2.10.1 — 2026-09-12

- Fixes the Config, Classification Rules, Advanced and Status tabs disappearing in
  v2.10.0. `ui.tabs.initTabGroup()` sets `display:none` on the menu entry of any pane
  `dom.isEmpty()` reports as empty, and v2.10.0 handed it four panes that were empty
  by design, to be filled when first activated. Each pane now holds a placeholder
  element before the tab group is built, and the fill replaces it with `dom.content()`

## v2.10.0 — 2026-09-12

Shipped upstream as a six-patch series against `openwrt/luci` master; the installer
carries the same view, stylesheet and ACL.

- The in-tree package was several releases behind this repo, so the sync brings the
  2.9.6 view, the split stylesheet and the audited ACL with it. The ACL fix matters
  on its own: in-tree still granted `exec` on `qosify-status` and on the cleanup
  helper, plus `luci setInitAction`, from the **read** group, so a read-only ACL
  user could run both
- `LUCI_DEPENDS` gains `+luci-base`. `luci.mk` copies `LUCI_DEPENDS` straight into
  `DEPENDS` and adds no implicit base dependency, so the package could be installed
  without the JS runtime its view needs
- The in-tree `cleanup` helper hardcoded `qosify.wan`, `qosify.wandev` and a literal
  `pppoe-wan`; it missed every section not named that and deleted the root qdisc on
  `pppoe-wan` whether or not qosify put it there. This repo's `config_foreach` /
  `network_get_device` version replaces it
- Tab panes are built when first activated instead of all five before the page is
  shown, so a page load no longer pays for the Config Reference table, three Quick
  Add panels and both editors when nobody opens those tabs. A pane built later gets
  `applyReadonly()`, an editor is brought up to date from disk rather than showing
  what was read at page load, and Overview refreshes itself the way the poller would
- The two 10 s pollers become one, dispatched on the open tab — the second only ever
  tested the same `currentTab` and returned, and one poller cannot interleave an
  Overview refresh with a Status fork
- The Rules tab can edit any file in the `defaults` list, not just
  `00-defaults.conf`. Files dropped in `/etc/qosify` were loaded by the daemon and
  invisible here. ACL read/write widen to `/etc/qosify/*.conf` with a `list` grant on
  the directory, and UCI is loaded before the first `gatherCtx()` rather than
  alongside it, since the defaults list is what says which files to look for
- Status gains **Daemon counters** (`ubus call qosify get_stats`) and **Map entries**
  (`ubus call qosify dump`), both read-only and both feature-detected. `get_stats`
  rides the existing tick; `dump` is fetched when expanded, since a DNS-driven map
  runs to thousands of entries
- `po/templates/qosify.pot` is regenerated with the upstream `i18n-scan.pl`. The
  previously shipped template was missing `Config cleared.` and
  `Reading tc output...`

Considered and not done: moving Quick Settings from a text rewrite of
`/etc/config/qosify` to `uci.set`/`uci.save`. Doing it properly means `uci.apply()`
and LuCI's rollback flow, which replaces the app's own service handling and sits
awkwardly beside two editors that write files directly — an architecture change to
the write path, not a fix, so it wants its own PR.

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
