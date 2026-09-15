# Changelog

All notable changes to `luci-app-qosify`. Versions are the `VERSION=` constant in `qosify-luci.sh`.

## v3.2.1-dev — 2026-09-15

Tabs follow LuCI's refresh logic; Counters is a fixed tab.

- Overview, Status and Counters poll at LuCI's `pollinterval` (`luci.main.pollinterval`,
  5 s by default) instead of a fixed 10 s, so they pause and resume with the header's
  refresh toggle like any other LuCI page
- Map Entries loses its Refresh button. `dump` now follows `get_stats` on every
  Counters tick; `fillMap()` still compares its signature first, so an unchanged map
  is not redrawn and the scroll position holds. A tick is three ubus calls
  (`service.list`, `get_stats`, `dump`) and no forks. `refreshCountersAll()` and
  `refreshMapEntries()` are folded into `refreshCounters()`
- Advanced loses its Display section. Counters is always on the tab bar; the
  `luci-app-qosify.counters` localStorage key, `applyTabVisibility()` and the unused
  `.qos-actions` style are gone
- Tab order is Overview, Config, Classification Rules, Status, Counters, Advanced.
  `#hash` links are unchanged

## v3.2.0-dev — 2026-09-15

Sync with main v2.9.11 (openwrt-ai review of #9019). Comments only, no functional changes.

- Call counts corrected, with dev's uptime reads counted. A page load is eight ubus
  calls, ten while qosify runs: `uci.load()` adds a `uci get` to `gatherCtx(true)`'s
  seven, and `uptime()` reads `/proc/<pid>/stat` and `/proc/uptime`. An Overview tick
  is six, eight on the first tick after qosify starts, and a Counters tick is two, not
  one: `refreshCounters()` issues `service.list` alongside `get_stats`. The
  `installPollers()` and `refreshOverview()` comments are fixed
- The cleanup helper's comment claimed the ifb is removed after its parent has gone.
  `network_get_device` reads `.l3_device`, which netifd drops when the interface goes
  down, so that only holds for `config device`. For `config interface` qosify clears it
  itself: `interface_start()` runs `interface_clear_qdisc()`, which deletes `ifb-<dev>`,
  before `cmd_add_ingress()` recreates it

## v3.1.9-dev — 2026-09-15

Overview: Queue Mode select. No functional changes.

- Quick Settings Queue Mode no longer lists a `-- (diffserv4)` entry above
  `diffserv4`. With `mode` unset, `diffserv4` is selected, qosify's own default,
  the way Overhead Type falls back to `none`; saving then writes `option mode
  diffserv4`, which qosify treats the same as no `mode`
- `sel()` loses its hint argument and blank entry, which only that select used;
  both callers now pass a default

## v3.1.8-dev — 2026-09-15

Counters tab: bars follow the share. No functional changes.

- Bar length in Traffic by Class and Traffic by CAKE Tin is the row's share of
  the total, the same figure as the share column, so a view's bars add up to one
  track. It was log-scaled against the largest row, which drew a 1% tin at over
  half the length of a 90% one
- A non-zero row keeps a 2px sliver; a zero row draws no fill

## v3.1.7-dev — 2026-09-15

Counters tab: class order follows the tins. No functional changes.

- Traffic by Class is grouped by the tin each class's codepoint lands in under the
  CAKE mode in use, highest priority tin first as in Traffic by CAKE Tin, then by
  codepoint within the tin (EF first, as before). On diffserv4 that is Voice,
  Video, Best Effort, Bulk; on diffserv3 CS4 and AF4x classes sort into Best
  Effort, since that is where diffserv3 puts them; on diffserv8 CS6/CS7 classes
  lead, then Minimum Latency, then CS2 ahead of the video classes
- Classes with no valid codepoint go last. With no single mode to fold by, the
  previous codepoint-only order is kept

## v3.1.6-dev — 2026-09-15

Counters tab: tin order. No functional changes.

- Traffic by CAKE Tin lists tins highest priority first, the order `sch_cake.c`
  documents its classes in and the reverse of the `qosify-status` columns.
  diffserv4 runs Voice, Video, Best Effort, Bulk; diffserv3 Voice, Best Effort,
  Bulk; diffserv8 and precedence Tin 7 down to Tin 0 — on diffserv8 that is
  Network Control (CS6/CS7), Minimum Latency (EF/VA/CS5/CS4), Interactive Shell
  (CS2), Low Latency Transactions (AF2x), Video Streaming (AF3x/AF4x/CS3), Best
  Effort, High Throughput (CS1/AF1x), Background (LE)
- Colours stay with their tin

## v3.1.5-dev — 2026-09-15

Overview: qosify uptime.

- Service Status has an **Uptime** row while qosify runs. procd's `service list`
  gives the instance pid but no start time, so the start comes from field 22 of
  `/proc/<pid>/stat` (clock ticks since boot) set against `/proc/uptime`. Both are
  on the boot clock, so an NTP step after boot does not skew it. A reload keeps
  the pid and the uptime; a restart starts it again
- The start is cached per pid: the first tick after a start reads the two `/proc`
  files and later ticks read nothing, so the 10 s Overview poll gains no calls
  and still no forks. The row is hidden while qosify is stopped or the read fails
- ACL read group: `/proc/uptime` and `/proc/[0-9]*/stat` granted `read`, so
  read-only sessions see it too

## v3.1.4-dev — 2026-09-15

Counters tab colours. No functional changes.

- Bulk is red and voice green, in both the class and tin bars. diffserv8 High
  Throughput (CS1/AF1x) takes the red, Minimum Latency (EF/VA/CS4/CS5) the green
  and Network Control (CS6/CS7) a darker green; precedence CS1 is red and CS5 to
  CS7 run light to dark green. Best effort blue, video yellow and the other
  diffserv8 and precedence tins are unchanged

## v3.1.3-dev — 2026-09-15

Counters tab: class and tin bars share one colour scheme.

- Traffic by Class colours each class by the tin its codepoint lands in under the
  shaped sections' CAKE mode — the same `TIN_MAP` fold the tin bars use, taken on
  `egress` (falling back to `ingress`, then `value`), as the class ordering already
  is. CS4 `gaming` is red on diffserv4 and diffserv8, orange on precedence
- Colours follow the kind of traffic rather than the tin number: grey bulk, blue
  best effort, yellow video, red voice. diffserv8 adds dark grey Background (LE),
  teal Low Latency Transactions (AF2x), purple Interactive Shell (CS2) and magenta
  Network Control (CS6/CS7); precedence runs CS0 to CS7 through the same hues
- A class whose codepoint is not a valid DSCP is drawn neutral grey. With no
  single mode to fold by, both views keep the per-name palette
- The class colour is the one CAKE would pick from the class's own codepoint;
  traffic `dscp_prio` or `dscp_bulk` re-marks is shown in its new tin only in the
  tin bars
- The log-scale comment is back above `barChart()`, where v3.1.1-dev displaced it

## v3.1.2-dev — 2026-09-15

Counters tab trimmed. No functional changes.

- Traffic by CAKE Tin rows show the tin only; the codepoint list beside each tin
  and in its tooltip is gone. With no single mode to fold by, rows are still one
  per codepoint, since there is no tin to name
- Section descriptions dropped from Traffic by Class, Traffic by CAKE Tin, Daemon
  and Map Entries. The conditional tin notes (mixed modes, unshaped ingress,
  `fwmark`) stay

## v3.1.1-dev — 2026-09-15

Counters tab: a per-tin view that lines up with `qosify-status`.

- New **Traffic by CAKE Tin** section. The class bars count at the first
  `dscp_lookup_class()` in `classify()`, before `check_flow()` re-marks a flow to
  `dscp_prio` or `dscp_bulk`, so they cannot be matched against CAKE's tins. The
  new section reads the `get_stats` `dscp` table,
  which `account_dscp()` fills from the packet's DSCP at the end of `classify()`,
  segment-counted since `e57b340` and covering unclassified defaults since `44ce40f`
- Codepoints are folded with CAKE's own `besteffort`, `precedence`, `diffserv8`,
  `diffserv4` and `diffserv3` tables from `sch_cake.c`, put through `tin_order`, so
  the rows are the columns `qosify-status` prints, under the same Bulk / Best
  Effort / Video / Voice or Tin *n* labels. Each row names the codepoints behind it,
  with per-codepoint packets in the tooltip
- The mode is taken per shaped direction the way `cmd_add_qdisc()` builds the `tc`
  command — `mode`, then `options`, then the direction's options, last keyword
  wins. Sections on different modes, or an unknown one, get one row per codepoint
  instead of a guess
- Notes where the two cannot agree: `cmd_add_ingress()` attaches the classifier
  before it checks `ingress`, so an unshaped ingress is still counted; `fwmark` in
  the CAKE options lets a firewall mark pick the tin. The window also differs — the
  `dscp` map lives from daemon start and survives reloads, CAKE's counters from
  qdisc creation
- Hidden when the reply has no `dscp` table, as on 24.10 (`1501e09`). No new ubus
  calls, forks or ACL grants: it reuses the `get_stats` reply the tab already polls
- `barChart()` takes its rows, empty message and column title from the caller, so
  the class and tin views share it

## v3.1.0-dev — 2026-09-15

Dev realigned on main v2.9.10, which supersedes the v2.10.0 – v3.0.0-dev line.
Everything outside the Counters tab is main's code as shipped: cleanup helper,
config templates, menu entry, feed `Makefile` and installer. The diff against
main is the Counters tab, its stylesheet rules and two ACL grants.

- New **Counters** tab, off the tab bar by default. **Advanced → Display →
  Counters tab** shows it, and a link to `#counters` does too. The choice is kept
  in the browser's `localStorage`, not in `/etc/config/qosify`, which qosify owns
- **Traffic by Class**: packet totals per class from `ubus call qosify get_stats`,
  as log-scaled bars with the exact packets, bytes and share beside each, the
  codepoint the class marks with, and a total row. Totals since the last reload,
  not rates. Ordered EF first and LE/CS1 last; the `tcp_default`/`udp_default`
  slots are skipped, since a default that names a class is already counted there
- **Daemon**: eBPF IP map entries, last reload and DNS cache, where the reply has
  them. OpenWrt 24.10 pins qosify at `1501e09`, whose `get_stats` returns
  `qosify_map_stats()` at the top level with packets only; the tab renders that
  shape and omits the rest
- **Map Entries**: the DNS patterns from `ubus call qosify dump`, with hits,
  packets and bytes from the `get_stats` `dns` table, source and timeout.
  Port and address entries are not listed — qosify keeps no per-entry counters
  for them, and `qosify_map_set_port()` stores one entry per port. Read on first
  open and by a Refresh button, not on the tick; capped at 200 rows, dynamic
  entries last. The Traffic column is dropped on a daemon with no `dns` table
- The tab polls `get_stats` every 10 s while open, like Status, and makes no
  forks, so it works with read-only access
- ACL read group: `get_stats` and `dump` added to the `qosify` ubus grant

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
