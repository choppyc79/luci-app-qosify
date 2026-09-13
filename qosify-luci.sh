#!/bin/sh
# SPDX-License-Identifier: MIT
# qosify-luci.sh — LuCI App for qosify (modern JS, ash-compatible)
VERSION="2.20.3"
MENU_DIR="/usr/share/luci/menu.d"
ACL_DIR="/usr/share/rpcd/acl.d"
VIEW_DIR="/www/luci-static/resources/view/qosify"
TPL_DIR="/usr/share/qosify-luci"
CONFIG_DIR="/etc/qosify"
UCI_CONFIG="/etc/config/qosify"
DEFAULTS_FILE="$CONFIG_DIR/00-defaults.conf"
LEGACY_CTRL="/usr/lib/lua/luci/controller/qosify.lua"
LEGACY_VIEW="/usr/lib/lua/luci/view/qosify"
LEGACY_CBI="/usr/lib/lua/luci/model/cbi/qosify"

# Every install write goes through this: a full or read-only overlay must fail
# loudly instead of leaving a half-installed app that still reports [OK].
ck() {
	[ -s "$1" ] || { echo "[ERROR] Failed writing $1"; exit 1; }
}

# rpcd globs /usr/share/rpcd/acl.d/*.json per login (rpc_login_setup_acls in
# rpcd session.c), so a new ACL only applies to a new session -- restarting rpcd
# forces that. Nothing else needs restarting: the ucode dispatcher keys its page
# tree cache on an ino|mtime|size hash of menu.d and prunes stale files itself,
# and no webserver caches anything under /www -- only the browser does, hence
# the Ctrl+F5 note at the end of an install.
restart_luci_services() {
	[ -f /etc/init.d/rpcd ] && /etc/init.d/rpcd restart
	return 0
}

clean_legacy() {
	rm -f "$LEGACY_CTRL"
	rm -rf "$LEGACY_VIEW" "$LEGACY_CBI"
}

install_deps() {
	echo "[*] Installing qosify..."
	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1
		apk add qosify
	elif command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1
		opkg install qosify
	else
		echo "[ERROR] No supported package manager"; exit 1
	fi
	# Matches the menu entry's fs dependency, not just $PATH.
	if [ ! -x /usr/sbin/qosify ]; then
		echo "[ERROR] qosify not found after install"; exit 1
	fi
	/etc/init.d/qosify enable
	echo "[OK] qosify ready"
}

install_templates() {
	echo "[*] Writing template files..."
	mkdir -p "$TPL_DIR"
	cat > "$TPL_DIR/00-defaults.conf" << 'EOF'
# DNS
tcp:53		voice
tcp:5353	voice
udp:53		voice
udp:5353	voice

# NTP
udp:123		voice

# SSH
tcp:22		+video

# HTTP/QUIC
tcp:80		+besteffort
tcp:443		+besteffort
udp:80		+besteffort
udp:443		+besteffort
EOF
	ck "$TPL_DIR/00-defaults.conf"
	cat > "$TPL_DIR/qosify" << 'EOF'
config defaults
	list defaults /etc/qosify/*.conf
	option dscp_prio video
	option dscp_icmp +besteffort
	option dscp_default_udp besteffort
	option prio_max_avg_pkt_len 500

config class besteffort
	option ingress CS0
	option egress CS0

config class bulk
	option ingress LE
	option egress LE

config class video
	option ingress AF41
	option egress AF41

config class voice
	option ingress CS6
	option egress CS6
	option bulk_trigger_pps 100
	option bulk_trigger_timeout 5
	option dscp_bulk CS0

config interface wan
	option name wan
	option disabled 1
	option bandwidth_up 100mbit
	option bandwidth_down 100mbit
	option overhead_type none
	# defaults:
	option ingress 1
	option egress 1
	option mode diffserv4
	option nat 1
	option host_isolate 1
	option autorate_ingress 0
	option ingress_options ""
	option egress_options ""
	option options ""

config device wandev
	option disabled 1
	option name wan
	option bandwidth 100mbit
EOF
	ck "$TPL_DIR/qosify"
	cat > "$TPL_DIR/cleanup" << 'EOF'
#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Remove qosify qdiscs and ifb devices left behind by an unclean exit.
#
# A clean stop already does this itself: procd sends SIGTERM, qosify's main()
# calls qosify_iface_stop() and interface_clear_qdisc() removes the root qdisc,
# the bpf filters and the ifb device. This script only matters after a crash, a
# SIGKILL or a respawn loop, so it deliberately only touches devices qosify is
# configured for -- never a qdisc this package did not create.

. /lib/functions.sh
. /lib/functions/network.sh

# The lock is an flock on an open fd, not a directory plus an EXIT trap: rpcd
# SIGKILLs this script at its exec timeout (rpc_file_exec_timeout_cb() in
# file.c), the trap never runs, and the leftover directory would then make every
# later run exit 0 without doing anything. The kernel drops an flock on process
# exit however the process dies. The path differs from the old directory so a
# stale one left by an earlier version cannot break the redirect. Without
# busybox flock, run unlocked rather than not at all -- the worst a concurrent
# run can do is repeat a tc delete.
LOCK="/var/lock/qosify-luci-cleanup.lock"

mkdir -p /var/lock
exec 9>"$LOCK"
command -v flock >/dev/null && { flock -n 9 || exit 0; }

# Mirrors interface_ifb_name() in qosify: "ifb-<dev>" while strlen(dev) + 4 is
# below IFNAMSIZ. Longer names take a different branch upstream which we do not
# try to reproduce here.
ifb_name() {
	[ "${#1}" -lt 12 ] || return 1
	echo "ifb-$1"
}

clear_dev() {
	local dev="$1"
	local ifb

	[ -n "$dev" ] || return 0
	[ -e "/sys/class/net/$dev" ] || return 0

	tc qdisc del dev "$dev" clsact 2>/dev/null
	tc qdisc del dev "$dev" root 2>/dev/null

	ifb="$(ifb_name "$dev")" || return 0
	[ -e "/sys/class/net/$ifb" ] || return 0

	ip link set "$ifb" down 2>/dev/null
	ip link del "$ifb" 2>/dev/null
}

# `config interface` names a netifd interface, not a device; qosify resolves it
# to the l3 device before touching tc, so resolve it the same way.
clear_interface() {
	local cfg="$1"
	local name dev disabled

	# add_interface() in qosify.init returns early on disabled, so qosify never
	# created a qdisc here -- deleting the root qdisc of a disabled section would
	# take out whatever else owns the device (sqm-scripts, a manual tc setup).
	config_get_bool disabled "$cfg" disabled 0
	[ "$disabled" -gt 0 ] && return 0

	config_get name "$cfg" name
	[ -n "$name" ] || return 0

	network_get_device dev "$name" || dev=""
	clear_dev "$dev"
}

# `config device` names a netdev directly.
clear_device() {
	local cfg="$1"
	local name disabled

	config_get_bool disabled "$cfg" disabled 0
	[ "$disabled" -gt 0 ] && return 0

	config_get name "$cfg" name
	clear_dev "$name"
}

config_load qosify
config_foreach clear_interface interface
config_foreach clear_device device

# Orphaned ifb devices: qosify is the only thing that creates ifb-* names
# (sqm-scripts uses ifb4*), and removing the device on its own cannot disturb a
# qdisc belonging to anything else.
for ifb in /sys/class/net/ifb-*; do
	[ -e "$ifb" ] || continue
	ifb="${ifb##*/}"
	ip link set "$ifb" down 2>/dev/null
	ip link del "$ifb" 2>/dev/null
done

exit 0
EOF
	ck "$TPL_DIR/cleanup"
	chmod +x "$TPL_DIR/cleanup"
}

install_defaults() {
	echo "[*] Seeding default configs (existing files preserved)..."
	mkdir -p "$CONFIG_DIR"
	[ -f "$DEFAULTS_FILE" ] || { cp "$TPL_DIR/00-defaults.conf" "$DEFAULTS_FILE"; ck "$DEFAULTS_FILE"; }
	[ -f "$UCI_CONFIG" ]    || { cp "$TPL_DIR/qosify" "$UCI_CONFIG"; ck "$UCI_CONFIG"; }
}

force_defaults() {
	echo "[*] Overwriting configs with qosify defaults..."
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	mkdir -p "$CONFIG_DIR"
	cp "$TPL_DIR/00-defaults.conf" "$DEFAULTS_FILE"; ck "$DEFAULTS_FILE"
	cp "$TPL_DIR/qosify" "$UCI_CONFIG"; ck "$UCI_CONFIG"
}

install_menu() {
	echo "[*] Writing menu entry..."
	mkdir -p "$MENU_DIR"
	cat > "$MENU_DIR/luci-app-qosify.json" << 'EOF'
{
	"admin/network/qosify": {
		"title": "qosify",
		"order": 90,
		"action": {
			"type": "view",
			"path": "qosify/main"
		},
		"css": "view/qosify/qosify.css",
		"depends": {
			"acl": [ "luci-app-qosify" ],
			"fs": { "/usr/sbin/qosify": "executable" }
		}
	}
}
EOF
	ck "$MENU_DIR/luci-app-qosify.json"
}

install_acl() {
	echo "[*] Writing ACL..."
	mkdir -p "$ACL_DIR"
	cat > "$ACL_DIR/luci-app-qosify.json" << 'EOF'
{
	"luci-app-qosify": {
		"description": "Grant access to LuCI app qosify",
		"read": {
			"ubus": {
				"qosify": [ "status", "get_stats", "dump" ],
				"rc": [ "list" ],
				"service": [ "list" ],
				"file": [ "read", "stat", "list" ]
			},
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "read", "list" ],
				"/etc/qosify": [ "list" ],
				"/etc/qosify/*.conf": [ "read", "list" ],
				"/usr/share/qosify-luci/qosify": [ "read" ],
				"/usr/share/qosify-luci/00-defaults.conf": [ "read" ]
			}
		},
		"write": {
			"ubus": {
				"rc": [ "init" ],
				"uci": [ "revert" ],
				"file": [ "write", "exec" ]
			},
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "write" ],
				"/etc/qosify/*.conf": [ "write" ],
				"/usr/sbin/qosify-status": [ "exec" ],
				"/usr/share/qosify-luci/cleanup": [ "exec" ]
			}
		}
	}
}
EOF
	ck "$ACL_DIR/luci-app-qosify.json"
}

install_view() {
	echo "[*] Writing view..."
	mkdir -p "$VIEW_DIR"
	cat > "$VIEW_DIR/main.js" << 'JSEOF'
// SPDX-License-Identifier: MIT
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';
'require rpc';
'require dom';

var UCI_PATH='/etc/config/qosify';
var CONFIG_DIR='/etc/qosify';
var RULES_PATH=CONFIG_DIR+'/00-defaults.conf';
var DSCP=['CS0','CS1','CS2','CS3','CS4','CS5','CS6','CS7','AF11','AF12','AF13','AF21','AF22','AF23','AF31','AF32','AF33','AF41','AF42','AF43','EF','VA','NQB','LE','DF'];
var OVH=['none','manual','conservative','ethernet','docsis','pppoe-ptm','bridged-ptm','pppoe-vcmux','pppoe-llcsnap','pppoa-vcmux','pppoa-llc','bridged-vcmux','bridged-llcsnap','ipoa-vcmux','ipoa-llcsnap'];
var ENCAP=['atm','noatm','ptm'];
var MODES=['diffserv3','diffserv4','diffserv8','besteffort','precedence'];
var MAP_ROWS=200;
// codepoints[] in map.c. The map listing is ordered by the value behind each
// entry's DSCP, highest first, so EF sits at the top and LE and CS0 at the end.
var DSCP_VAL={CS0:0,DF:0,LE:1,CS1:8,AF11:10,AF12:12,AF13:14,CS2:16,AF21:18,AF22:20,
	AF23:22,CS3:24,AF31:26,AF32:28,AF33:30,CS4:32,AF41:34,AF42:36,AF43:38,CS5:40,
	VA:44,NQB:45,EF:46,CS6:48,CS7:56};
// The Map entries header stays at the top of the scroll box. It is inline rather
// than in qosify.css because the stylesheet the menu node declares is emitted
// without a cache-busting query, so a browser holding an older copy keeps the
// old rules; and .table is border-collapse, which drops a border on a sticky
// cell and does not paint a sticky <tr> in every browser -- so the cells carry
// the position and the rule under them is an inset shadow. A theme that defines
// neither colour variable falls back to system colours, which stay a readable
// pair either way.
var MAP_TH={'class':'th','style':'position:sticky;top:0;z-index:3;'+
	'background:var(--background-color-medium,Canvas);color:var(--text-color-high,CanvasText);'+
	'box-shadow:inset 0 -1px 0 var(--border-color-medium,rgba(128,128,128,.5))'};
// QOSIFY_MAX_CLASS_ENTRIES in qosify-bpf.h: the class map holds 16 slots, and
// qosify_map_get_class_id() returns -1 once they are all taken.
var MAX_CLASSES=16;
// One colour per class, assigned by the class name's position in the sorted set
// so a class keeps its colour when the bars reorder by size. luci-mod-status
// hardcodes its graph colours too -- the theme exposes no palette to borrow.
var CN_COLORS=['#377eb8','#4daf4a','#ff7f00','#984ea3','#e41a1c','#17becf','#a65628','#f781bf'];
// The Counters tab is a per-browser view setting, so it is kept in localStorage
// and survives logout: qosify owns /etc/config/qosify and this app adds no keys
// to it, and /etc/config/luci would mean a wider ACL for a cosmetic toggle.
// Private-mode browsers throw on access, hence the guards.
var CN_KEY='luci-app-qosify.counters';
function prefShow(){
	try{return localStorage.getItem(CN_KEY)==='1';}catch(e){return false;}
}
function prefSetShow(v){
	try{localStorage.setItem(CN_KEY,v?'1':'0');}catch(e){}
}
// qosify.init handles 'alias' with add_class and 'device' with add_interface,
// so those section types share the option set of class / interface.
var QAC_PANEL={defaults:'defaults','class':'class',alias:'class','interface':'interface',device:'interface'};
var SECT=[['defaults','config defaults'],['class','config class'],['alias','config alias'],['interface','config interface'],['device','config device']];

// luci.setInitAction was dropped from luci-base in 4440b267d; the rc namespace
// (built into the rpcd core binary, so no extra dependency) replaces it.
var callRcInit=rpc.declare({
	object:'rc',
	method:'init',
	params:['name','action'],
	reject:true
});
// skip_running_check keeps rc.list from forking `qosify running`, which waits
// on ubus for up to 10s while rpcd kills it after 3s.
var callRcList=rpc.declare({
	object:'rc',
	method:'list',
	params:['name','skip_running_check'],
	expect:{'':{}}
});
var callQosifyStatus=rpc.declare({
	object:'qosify',
	method:'status',
	expect:{'':{}}
});
// get_stats and dump are read-only and are both present in the qosify commit
// OpenWrt has pinned since 24.10; what the reply contains still varies by build,
// which statsNodes() handles. A Method-not-found reply leaves the table empty.
var callQosifyStats=rpc.declare({
	object:'qosify',
	method:'get_stats',
	expect:{'':{}}
});
var callQosifyDump=rpc.declare({
	object:'qosify',
	method:'dump',
	expect:{'':{}}
});
var callServiceList=rpc.declare({
	object:'service',
	method:'list',
	params:['name'],
	expect:{'':{}}
});
var callUciRevert=rpc.declare({
	object:'uci',
	method:'revert',
	params:['config'],
	reject:true
});
function isRunning(r){
	try{var i=r.qosify.instances;for(var k in i)if(i[k].running)return true;}catch(e){}
	return false;
}

function clsLabel(c){return c.name+(c.alias?' '+_('(alias)'):'');}
function clsDesc(c){return _('Ingress: %s / Egress: %s').format(c.ingress||'',c.egress||'');}
function trim(s){return (s||'').replace(/^\s+|\s+$/g,'');}
function $(id){return document.getElementById(id);}

// ingress/egress/nat/host_isolate/autorate_ingress reach the daemon through
// qosify.init's `add_option boolean` -> json_add_boolean -> !!atoi(), so only a
// non-zero number is true: 'true', 'on' and 'yes' all mean off.
function numBool(v,def){
	if(v==null||v==='')return !!def;
	var n=parseInt(v,10);
	return !isNaN(n)&&n!==0;
}
// `disabled` is read with config_get_bool, which does accept the word forms.
function uciBool(v,def){
	if(v==null||v==='')return !!def;
	switch(String(v).toLowerCase()){
	case '1':case 'on':case 'true':case 'yes':case 'enabled':return true;
	case '0':case 'off':case 'false':case 'no':case 'disabled':return false;
	}
	return !!def;
}
function boolNum(v){return /^-?\d+$/.test(String(v==null?'':v));}

// ubus call qosify status -> { devices:{}, interfaces:{ <name>:{ active,... } } }
function statusActive(st){
	var groups=['interfaces','devices'],i,k,t;
	for(i=0;i<groups.length;i++){
		t=st&&st[groups[i]];
		for(k in t)if(t[k]&&t[k].active)return true;
	}
	return false;
}
function statusCount(st){
	var groups=['interfaces','devices'],i,k,t,n=0;
	for(i=0;i<groups.length;i++){
		t=st&&st[groups[i]];
		for(k in t)if(t[k]&&t[k].active)n++;
	}
	return n;
}

function countRules(text){
	var n=0,lines=(text||'').split('\n');
	for(var i=0;i<lines.length;i++){
		var l=lines[i],h=l.indexOf('#');
		if(h>=0)l=l.slice(0,h);
		if(trim(l))n++;
	}
	return n;
}

// __qosify_map_load_file_data() reads with fgets() into char line[1024], so it
// takes at most 1023 bytes including the newline: 1022 characters of content.
// The comment is stripped after the read, not before, so the whole raw line
// counts towards the limit.
function validateRules(d){
	if(/\x00/.test(d))return _('Binary content rejected');
	var lines=d.split('\n');
	for(var i=0;i<lines.length;i++)
		if(lines[i].length>1022)return _('Line %d is longer than 1022 characters — the rule loader reads at most 1023 bytes per line, newline included, and would split it').format(i+1);
	return null;
}
function fmtSize(n){return n<1024?n+'B':(n/1024).toFixed(1)+'K';}
// A class can be a rounding error next to a bulk one, and 0.0% reads as nothing
// counted at all, so anything non-zero under a tenth of a percent says so.
function fmtShare(p){
	if(!p)return _('0%');
	if(p<0.1)return _('<0.1%');
	return _('%s%%').format(p<10?p.toFixed(1):Math.round(p));
}

// The mapping files qosify actually reads: every entry of every `list defaults`,
// with globs expanded the way add_defaults() leaves them for the shell. Only
// globs inside CONFIG_DIR are expanded, since that is the one directory the ACL
// grants a listing of; anything else is taken literally. Order is the order the
// daemon loads them in, so the first entry is the file the Rules tab edits.
function globRe(p){
	return new RegExp('^'+p.replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/\*/g,'[^/]*').replace(/\?/g,'[^/]')+'$');
}
function ruleFiles(names){
	var pats=[],out=[];
	uci.sections('qosify','defaults',function(s){
		var v=s.defaults;
		if(v==null)return;
		(Array.isArray(v)?v:String(v).split(/\s+/)).forEach(function(f){if(f)pats.push(f);});
	});
	pats.forEach(function(pat){
		if(!/[*?]/.test(pat)){
			if(out.indexOf(pat)<0)out.push(pat);
			return;
		}
		if(pat.indexOf(CONFIG_DIR+'/')!==0||pat.indexOf('/',CONFIG_DIR.length+1)>=0)return;
		var re=globRe(pat);
		names.forEach(function(n){
			var f=CONFIG_DIR+'/'+n;
			if(re.test(f)&&out.indexOf(f)<0)out.push(f);
		});
	});
	return out.length?out:[RULES_PATH];
}
function fmtMtime(t){if(!t)return '';return new Date(t*1000).toLocaleString();}

// The shaping section Quick Settings edits, or null. Prefers the first enabled
// section, and accepts `config device` since qosify.init feeds both section
// types through add_interface(). An anonymous section has a synthetic .name
// (cfgXXXXXX / newXXXXXX) that never appears in the file, so name is left empty
// for it and setOpts() locates the block by per-type ordinal instead.
function ifSect(){
	var a=[];
	['interface','device'].forEach(function(t){
		var i=0;
		uci.sections('qosify',t,function(s){
			a.push({type:t,id:s['.name'],name:s['.anonymous']?'':s['.name'],idx:i++,on:!uciBool(s.disabled,false)});
		});
	});
	for(var j=0;j<a.length;j++)if(a[j].on)return a[j];
	return a.length?a[0]:null;
}
// --- Mirrors qosify.init add_interface() and cmd_add_qdisc() in interface.c ---
// nat defaults to 1 for interfaces and 0 for devices; host_isolate defaults on.
function ifCfg(s,dev){
	return {
		bw_up:s.bandwidth_up||s.bandwidth||'',
		bw_dn:s.bandwidth_down||s.bandwidth||'',
		mode:s.mode||'diffserv4',
		ingress:numBool(s.ingress,true),
		egress:numBool(s.egress,true),
		host_isolate:numBool(s.host_isolate,true),
		autorate:numBool(s.autorate_ingress,false),
		nat:numBool(s.nat,!dev)
	};
}
function hasNat(v){return /(^|\s)nat(\s|$)/.test(v||'');}
// Keys the daemon will silently drop, given the rest of the section.
function ifLint(s,dev){
	var w=[],c=ifCfg(s,dev);
	if(!s.name)w.push(_('name is not set — qosify.init sends an empty device name and this section is never applied'));
	if(!c.host_isolate&&c.nat){
		var ne=hasNat(s.options)||hasNat(s.egress_options);
		var ni=hasNat(s.options)||hasNat(s.ingress_options);
		if(!ne&&!ni)w.push(_('nat is not sent: qosify only emits nat/nonat inside the host_isolate branch. CAKE does accept flows plus nat — put nat in options to apply it'));
		else if(!ne||!ni)w.push(_('nat only reaches %s — put it in options, or in both ingress_options and egress_options').format(ne?'egress':'ingress'));
	}
	if(s.overhead_type!=='manual'&&(s.overhead||s.overhead_encap))w.push(_('overhead and overhead_encap are ignored unless overhead_type is manual'));
	if(!c.ingress&&!c.egress)w.push(_('ingress and egress are both 0 — nothing is shaped'));
	if(c.egress&&!c.bw_up)w.push(_('no bandwidth_up or bandwidth — egress CAKE runs unlimited'));
	if(c.ingress&&!c.bw_dn)w.push(_('no bandwidth_down or bandwidth — ingress CAKE runs unlimited'));
	['ingress','egress','nat','host_isolate','autorate_ingress'].forEach(function(k){
		if(s[k]!=null&&s[k]!==''&&!boolNum(s[k]))w.push(_('%s is set to "%s" — qosify converts it with atoi(), so anything but a non-zero number means off').format(k,s[k]));
	});
	if(s.disabled!=null&&s.disabled!==''&&!/^(0|1|on|off|true|false|yes|no|enabled|disabled)$/i.test(String(s.disabled)))
		w.push(_('disabled is set to "%s" — config_get_bool does not recognise that, so the section stays enabled').format(s.disabled));
	['bandwidth_up','bandwidth_down','bandwidth','mode','ingress_options','egress_options','options'].forEach(function(k){
		if(s[k]&&/['"`$;&|<>(){}\\]/.test(String(s[k])))w.push(_('%s contains shell metacharacters — qosify assembles the tc command as a string and runs it with sh -c, so the command will break or execute them').format(k));
	});
	return w;
}
// --- Mirrors qosify_map_create_class() in map.c ---
// A class ingress/egress value goes through __qosify_map_dscp_value(), not
// qosify_map_dscp_value(), so it takes a codepoint or a raw number and nothing
// else: naming a class there fails and qosify frees the slot, dropping the whole
// class. An empty string is not an error -- strtoul("") yields 0 -- so a class
// with no value at all silently becomes CS0.
function clsLint(c,names){
	var w=[],both=!c.ingress&&!c.egress;
	if(both)w.push(_('no value, ingress or egress — qosify reads the empty string as 0, so this class is CS0 in both directions'));
	['ingress','egress'].forEach(function(k){
		var v=String(c[k]||'').replace(/^\+/,'');
		if(!v){
			if(!both)w.push(_('%s is unset and there is no value — qosify reads the empty string as 0, so it is CS0').format(k));
			return;
		}
		if(names.indexOf(v)>=0){
			w.push(_('%s names the class %s — a class value is never resolved against other classes, so qosify drops this class entirely').format(k,v));
			return;
		}
		if(DSCP.indexOf(v)>=0)return;
		var n=dscpNum(v);
		if(n===null||n>=64)w.push(_('%s is "%s" — neither a DSCP codepoint nor a number below 64, so qosify drops this class entirely').format(k,c[k]));
	});
	return w;
}
// Locate config blocks in raw UCI text: {type,name,start,end} (end = last non-blank
// line). Headers may be bare, single- or double-quoted — all three are valid UCI —
// and uci ends a token at # and treats ; as a statement separator, so a trailing
// comment or `config x; option y z` is a header too.
function unq(s){return String(s||'').replace(/^["']|["']$/g,'');}
function cfgSections(txt){
	var out=[],cur=null,lines=(txt||'').split('\n');
	for(var i=0;i<lines.length;i++){
		var head=lines[i].replace(/#.*$/,'').split(';')[0];
		var m=/^\s*config\s+(\S+)(?:\s+(\S+))?\s*$/.exec(head);
		if(m){cur={type:unq(m[1]),name:unq(m[2]),start:i,end:i};out.push(cur);}
		else if(cur&&trim(lines[i])!=='')cur.end=i;
	}
	return out;
}
// Values are spliced into a single-quoted UCI string: strip quotes and line breaks,
// or a stray newline injects arbitrary option/config lines into the file.
function qv(v){return v==null?'':String(v).replace(/['"\r\n]/g,'');}
// Set/remove options inside one config block, preserving every other byte of the
// file (comments, ordering, lists, unknown options). kv[key]===null deletes.
// idx = ordinal among sections of this type, used when name is empty (anonymous).
function setOpts(txt,type,name,idx,kv){
	var lines=(txt||'').split('\n'),secs=cfgSections(txt),s=null,n=0,i,k;
	for(i=0;i<secs.length;i++){
		if(secs[i].type!==type)continue;
		if(name?secs[i].name===name:n++===idx){s=secs[i];break;}
	}
	if(!s){
		var blk=["config "+type+(name?" '"+name+"'":'')];
		for(k in kv)if(kv[k]!=null)blk.push("\toption "+k+" '"+qv(kv[k])+"'");
		var t=(txt||'').replace(/\s+$/,'');
		return (t?t+'\n\n':'')+blk.join('\n')+'\n';
	}
	var out=[lines[s.start]],seen={};
	for(i=s.start+1;i<=s.end;i++){
		var lm=/^\s*list\s+(\S+)(\s|$)/.exec(lines[i]);
		if(lm&&(lm[1] in kv))throw new Error(_('%s is a list in this section — edit %s directly').format(lm[1],UCI_PATH));
		var m=/^\s*option\s+(\S+)\s+(.*)$/.exec(lines[i]);
		if(m&&(m[1] in kv)){
			seen[m[1]]=1;
			if(kv[m[1]]!=null)out.push("\toption "+m[1]+" '"+qv(kv[m[1]])+"'");
			continue;
		}
		out.push(lines[i]);
	}
	for(k in kv)if(!seen[k]&&kv[k]!=null)out.push("\toption "+k+" '"+qv(kv[k])+"'");
	return lines.slice(0,s.start).concat(out,lines.slice(s.end+1)).join('\n');
}
// Non-blocking sanity pass: flag rule targets that are neither a defined class,
// a DSCP codepoint, nor a raw numeric value.
// __qosify_map_dscp_value() parses raw values with strtoul(base 0), so a leading
// zero means octal: 077 is 63 and valid, 08 is not a number at all.
function dscpNum(v){
	if(/^0[xX][0-9a-fA-F]+$/.test(v))return parseInt(v,16);
	if(/^0[0-7]+$/.test(v))return parseInt(v,8);
	if(/^(0|[1-9]\d*)$/.test(v))return parseInt(v,10);
	return null;
}
// qosify_map_set_port() parses with strtoul(base 0), accepts <port>-<endport>,
// and rejects a zero start, an end below the start, and anything from 65535 up.
function portWarn(v){
	var p=v.split('-');
	if(p.length>2)return _('"%s" is not a port or a port range').format(v);
	var a=dscpNum(trim(p[0])),b=p.length>1?dscpNum(trim(p[1])):a;
	if(a===null||b===null)return _('"%s" is not a port or a port range').format(v);
	if(a<1)return _('port 0 is rejected — qosify requires a non-zero start port');
	if(b<a)return _('port range "%s" ends below where it starts').format(v);
	if(b>65534)return _('port %d is out of range — qosify rejects 65535 and above').format(b);
	return null;
}
// Bare addresses go to inet_pton(), which takes a single address and nothing
// else: no prefix length, no zone suffix.
function ip4Warn(v){
	// A dotted quad holds no letters, so a key with one was meant as a hostname.
	if(/[a-zA-Z]/.test(v))return _('"%s" has no prefix, so qosify reads it as an IPv4 address — a hostname needs dns:, dns_q: or dns_c:').format(v);
	var o=v.split('.');
	if(o.length!==4||o.some(function(x){return !/^\d{1,3}$/.test(x)||+x>255;}))
		return _('"%s" is not a single IPv4 address — qosify uses inet_pton() and takes no prefix length').format(v);
	return null;
}
function ip6Warn(v){
	if(!/^[0-9a-fA-F:.]+$/.test(v)||v.indexOf(':')<0||v.length>45)
		return _('"%s" is not a single IPv6 address — qosify uses inet_pton(), which takes no prefix length and no zone suffix').format(v);
	return null;
}
// __qosify_map_alloc_entry() lowercases the pattern and only then calls
// regcomp(), so uppercase inside a /regex is silently case-folded; a regex that
// does not compile takes the whole entry with it. The compile check here is
// JS RegExp rather than POSIX ERE, so it catches the unbalanced-bracket class of
// mistake and not much else.
function dnsWarn(p){
	if(!p)return _('an empty DNS pattern matches nothing');
	if(p.charAt(0)!=='/')return null;
	var re=p.slice(1);
	if(!re)return _('an empty DNS regex matches nothing');
	if(/[A-Z]/.test(re))return _('the regex "%s" is lowercased before it is compiled, so uppercase in it does not mean what it reads as').format(re);
	try{new RegExp(re);}catch(e){return _('the regex "%s" does not compile, so qosify drops the rule').format(re);}
	return null;
}
// Mirrors the prefix chain in qosify_map_parse_line(): the prefix picks the map,
// and a key with none has to hold a ':' or a '.' to be read as an address at
// all. Anything else matches no branch and the line is dropped in silence.
function keyWarn(key){
	var m=/^(?:dns|dns_q|dns_c):([\s\S]*)$/.exec(key);
	if(m)return dnsWarn(m[1]);
	m=/^(?:tcp|udp):([\s\S]*)$/.exec(key);
	if(m)return portWarn(m[1]);
	if(key.indexOf(':')>=0)return ip6Warn(key);
	if(key.indexOf('.')>=0)return ip4Warn(key);
	return _('"%s" matches nothing — qosify reads dns:, dns_q:, dns_c:, tcp:, udp: or a bare IP address').format(key);
}
function ruleWarn(txt,names){
	var w=[],bad=[],bare=[],keys=[],junk=[],lines=(txt||'').split('\n');
	for(var i=0;i<lines.length;i++){
		var l=lines[i],h=l.indexOf('#');
		if(h>=0)l=l.slice(0,h);
		l=trim(l);if(!l)continue;
		var f=l.split(/\s+/);
		if(f.length<2){if(bare.length<5)bare.push(String(i+1));continue;}
		// qosify_map_parse_line() ends the key at the first space and takes
		// everything after it as one value, so a third field is part of the value
		// and makes the whole line unparseable.
		if(f.length>2&&junk.length<5)junk.push(String(i+1));
		var kw=keyWarn(f[0]);
		if(kw&&keys.indexOf(kw)<0&&keys.length<5)keys.push(kw);
		var v=f[1].replace(/^\+/,'');
		if(names.indexOf(v)>=0||DSCP.indexOf(v)>=0)continue;
		var n=dscpNum(v);
		if(n!==null&&n<64)continue;
		if(bad.indexOf(v)<0)bad.push(v);
	}
	if(bare.length)w.push(_('No DSCP target on line %s — qosify skips single-field lines').format(bare.join(', ')));
	if(junk.length)w.push(_('More than two fields on line %s — qosify takes everything after the match as one DSCP target and drops the line').format(junk.join(', ')));
	keys.forEach(function(t){w.push(t);});
	if(bad.length)w.push(_('Unknown class/DSCP target: %s').format(bad.slice(0,5).join(', ')));
	return w;
}

var noteSeen={};
function notify(msg,kind){
	var key=String(msg);
	if(noteSeen[key])return null;
	var n=ui.addNotification(null,E('p',{},msg),kind||'info');
	if(!n)return null;
	noteSeen[key]=1;
	var ms=(kind==='danger')?10000:(kind==='warning')?8000:5000;
	setTimeout(function(){
		delete noteSeen[key];
		if(n&&n.parentNode)n.parentNode.removeChild(n);
	},ms);
	return n;
}

// Remember the size/mtime an editor was loaded from, so a save can tell the
// difference between "the user changed this" and "something else changed the
// file underneath us".
function noClassRow(){
	return E('tr',{},E('td',{'colspan':2,'class':'qos-muted'},E('em',{},_('No classes defined in %s').format(UCI_PATH))));
}

function stampFile(el,st){
	el.dataset.mtime=st?String(st.mtime):'';
	el.dataset.size=st?String(st.size):'';
}
function fileMoved(el,st){
	if(!el||el.dataset.mtime==null)return false;
	var m=st?String(st.mtime):'',z=st?String(st.size):'';
	return el.dataset.mtime!==m||el.dataset.size!==z;
}

function confirmDialog(title,text,label,negative){
	return new Promise(function(resolve){
		var done=function(v){ui.hideModal();resolve(v);};
		ui.showModal(title,[
			E('p',{},text),
			E('div',{'class':'right'},[
				E('button',{'class':'cbi-button','click':function(){done(false);}},_('Cancel')),
				' ',
				E('button',{'class':'cbi-button '+(negative?'cbi-button-negative':'cbi-button-action'),'click':function(){done(true);}},label||_('Continue'))
			])
		]);
	});
}

return view.extend({
	handleSaveApply:null,handleSave:null,handleReset:null,
	currentTab:'ov',
	readonly:false,

	rulesPath:RULES_PATH,

	// The edited file is the first entry of the defaults list -- the list qosify
	// itself loads -- which the shipped config resolves to 00-defaults.conf. It is
	// settled before anything is read, so the editor content and the path it was
	// read from cannot disagree.
	load:function(){
		var self=this;
		return uci.load('qosify').catch(function(){return null;}).then(function(r){
			return L.resolveDefault(fs.list(CONFIG_DIR),[]).then(function(l){
				self.rulesPath=ruleFiles((l||[]).filter(function(e){
					return e.type!=='directory';
				}).map(function(e){return e.name;}).sort())[0];
				return self.gatherCtx(true);
			}).then(function(ctx){return [r,ctx];});
		});
	},

	render:function(d){
		var self=this,ctx=d[1];

		this.readonly=!L.hasViewPermission();

		if(d[0]===null)notify(_('The qosify UCI configuration could not be loaded — class and interface lists may be incomplete.'),'warning');

		var root=E('div',{'class':'cbi-map','id':'qos-app'});
		// The menu entry declares this stylesheet and the theme header emits it as
		// dispatched.css, which avoids a flash of unstyled content; themes that
		// ignore the key still need the link, so add it only when it is absent.
		var cssHref=L.resource('view/qosify/qosify.css');
		if(!document.querySelector('link[rel=stylesheet][href="'+cssHref+'"]'))
			root.appendChild(E('link',{'rel':'stylesheet','href':cssHref}));
		root.appendChild(E('h2',{},_('qosify')));
		root.appendChild(E('div',{'class':'cbi-map-descr'},_('CAKE shaping with eBPF DSCP classification.')));

		var names={ov:'overview',cf:'config',ru:'rules',ad:'advanced',st:'status',cn:'counters'};
		var hash=(location.hash||'').slice(1),want='ov',k;
		for(k in names)if(names[k]===hash)want=k;
		// Counters is a diagnostic tab and stays hidden until it is asked for, since
		// its numbers are totals and nothing accumulates while it is away. A link
		// straight to #counters counts as asking.
		this.showCounters=(want==='cn')||prefShow();

		// Only the pane that opens is built here. The other four cost a reference
		// table, three Quick Add panels and two editors between them, none of which
		// is on screen; initTabGroup fires cbi-tab-active from a
		// requestAnimationFrame, so a pane is in the DOM by the time it is filled.
		var group=E('div',{});
		[['ov',_('Overview'),'tabOverview'],
		 ['cf',_('Config'),'tabConfig'],
		 ['ru',_('Classification Rules'),'tabRules'],
		 ['ad',_('Advanced'),'tabAdvanced'],
		 ['st',_('Status'),'tabStatus'],
		 ['cn',_('Counters'),'tabCounters']].forEach(function(t){
			// The placeholder child is load-bearing: initTabGroup() sets
			// display:none on the menu entry of any pane dom.isEmpty() reports as
			// empty, so a pane filled later has to hold an element before the tab
			// group is built or its tab never appears.
			var pane=E('div',{'data-tab':t[0],'data-tab-title':t[1]},E('div'));
			if(t[0]===want){
				dom.content(pane,self[t[2]](ctx));
				pane.setAttribute('data-tab-active','true');
				pane.dataset.built='1';
			}
			pane.addEventListener('cbi-tab-active',function(){
				self.currentTab=t[0];
				try{history.replaceState(null,'','#'+names[t[0]]);}catch(e){}
				if(!pane.dataset.built){
					dom.content(pane,self[t[2]](ctx));
					pane.dataset.built='1';
					self.applyReadonly(pane);
					// ctx carries the file contents read at page load, so an editor
					// built later is brought up to date from disk.
					if(t[0]==='cf')self.reloadEditor('qos-config-ta',UCI_PATH,false);
					if(t[0]==='ru')self.reloadEditor('qos-rules-ta',self.rulesPath,false);
					if(t[0]==='ov')self.refreshOverview();
				}
				// The Status tab costs a fork per active interface, so it is fetched
				// when it is opened rather than on every page load.
				if(t[0]==='st')self.refreshStatus();
				if(t[0]==='cn'){
					self.refreshCounters();
					self.refreshMapEntries();
				}
			});
			group.appendChild(pane);
		});
		root.appendChild(group);
		ui.tabs.initTabGroup(group.childNodes);
		this.currentTab=want;
		this.applyTabVisibility(root);

		if(this.readonly){
			this.applyReadonly(root);
			notify(_('You have read-only access to this page, so editing and service control are disabled.'),'warning');
		}

		this.installPollers();
		return root;
	},

	// One poller for the whole page, dispatched on the open tab: Overview is five
	// ubus calls and no forks, Status forks qosify-status, which runs tc twice per
	// active interface, Counters is three ubus calls and no forks, and the other
	// three tabs poll nothing. No interval is passed, so poll.add() uses
	// L.env.pollinterval -- the interval from `uci get luci.main.pollinterval`,
	// 5 s by default -- and the tab honours the theme's auto-refresh toggle like
	// any other LuCI page. Poll.step() holds the next tick until the promise this
	// returns settles, so a fork slower than the interval skips ticks instead of
	// stacking up.
	installPollers:function(){
		var self=this;
		poll.add(function(){
			if(self._n)return;
			if(self.currentTab==='ov')return self.refreshOverview();
			if(self.currentTab==='st')return self.refreshStatus();
			if(self.currentTab==='cn')return self.refreshCounters();
		});
		// The map listing is the one heavy read on the page: a DNS-driven config is
		// hundreds of entries and tens of kilobytes per reply, and entries change far
		// more slowly than the counters beside them. poll.add() keeps an interval per
		// queue entry, so a second entry at a multiple of the page interval is the
		// ordinary way to mix costs -- it still stops with the auto-refresh toggle
		// and still tracks luci.main.pollinterval.
		poll.add(function(){
			if(self._n||self.currentTab!=='cn')return;
			return self.refreshMapEntries();
		},(L.env.pollinterval||5)*3);
	},

	tabOverview:function(ctx){
		var section=E('div',{'id':'qos-ov'});
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-svc-sect'},this.buildSvcSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-qs-sect'},this.buildQsSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-cfg-sect'},this.buildCfgSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-ctl-sect'},this.buildCtlSect(ctx)));
		return section;
	},

	buildSvcSect:function(ctx){
		return [E('legend',{},_('Service Status')),this.renderSvcTable(ctx)];
	},

	buildCfgSect:function(ctx){
		return [E('legend',{},_('Configuration Files')),this.renderCfgFiles(ctx)];
	},

	buildQsSect:function(ctx){
		var self=this;
		var sn=ifSect();
		var w=(sn&&uci.get('qosify',sn.id))||{};
		var enChecked=(w['.name']!=null&&!uciBool(w.disabled,false));

		var nodes=[];
		nodes.push(E('legend',{},_('Quick Settings')));
		nodes.push(E('div',{'class':'cbi-section-descr'},
			_('Written to %s, %s.').format(UCI_PATH,sn?'config '+sn.type+(sn.name?" '"+sn.name+"'":' '+_('(unnamed section)')):"config interface 'wan' (will be created)")));
		var tbl=E('table',{'class':'qos-kv','width':'100%'});
		var bdy=E('tbody');tbl.appendChild(bdy);

		function row(lbl,el){
			var n=(el&&el.nodeType)?el:(Array.isArray(el)?el[0]:null);
			var id=(n&&n.id)||null;
			bdy.appendChild(E('tr',{},[E('td',{},id?E('label',{'for':id},lbl):lbl),E('td',{},el)]));
		}
		function chk(name,val){return E('input',{'type':'checkbox','id':'q-'+name,'data-q':name,'checked':val?'checked':null});}
		function txt(name,val,ph,style){return E('input',{'type':'text','id':'q-'+name,'data-q':name,'value':val||'','placeholder':ph||'','style':style||'width:140px;font-family:monospace'});}
		function sel(name,val,opts,style,def,hint){
			val=qv(val);
			var s=E('select',{'id':'q-'+name,'data-q':name,'style':style||'width:180px'});
			if(!def)s.appendChild(E('option',{'value':''},hint?'-- ('+hint+')':'--'));
			var sv=val||def||'',known=false;
			opts.forEach(function(o){var a={'value':o};if(sv===o){a.selected='selected';known=true;}s.appendChild(E('option',a,o));});
			if(val&&!known)s.appendChild(E('option',{'value':val,'selected':'selected'},_('%s (current)').format(val)));
			return s;
		}

		var enCb=chk('enabled',enChecked);
		var enBadge=E('span',{'class':'qos-badge qos-amber','style':'margin-left:8px','id':'q-en-badge'},'');
		this.updateEnBadge(enBadge,ctx,enChecked);
		row(_('QoS Enabled'),[enCb,enBadge]);
		// qosify.init passes `option name` to add_interface(); without it the daemon
		// gets an empty device and the section is never applied, so offer it here
		// whenever it is missing -- anonymous sections have no other way to set it.
		// Only `config interface` is named after the netifd interface; a `config
		// device` section names a netdev and the two differ by convention -- the
		// shipped config has `config device wandev` with `option name wan` -- so the
		// section name is never a safe prefill there. Leave it empty and let ifLint()
		// keep warning until a real netdev is entered.
		var isDev=!!(sn&&sn.type==='device');
		if(!w.name)row(isDev?_('Netdev Name'):_('Interface Name'),
			[txt('name',sn?(isDev?'':sn.name):'wan',_('e.g. %s').format(isDev?'eth0':'wan'),'width:140px'),
			E('span',{'style':'opacity:.6;font-size:11px;margin-left:8px'},_('required — qosify skips sections with no name'))]);
		row(_('Bandwidth Up'),txt('bw_up',w.bandwidth_up,_('e.g. %s').format('100mbit')));
		row(_('Bandwidth Down'),txt('bw_down',w.bandwidth_down,_('e.g. %s').format('100mbit')));
		row(_('Overhead Type'),sel('overhead',w.overhead_type,OVH,'width:180px','none'));
		row(_('Overhead Bytes'),[txt('overhead_b',w.overhead,_('manual only'),'width:100px'),
			E('span',{'style':'opacity:.6;font-size:11px;margin-left:8px'},_('used only when Overhead Type is manual'))]);
		row(_('Queue Mode'),sel('mode',w.mode,MODES,'width:170px',null,'diffserv4'));
		row(_('Ingress'),chk('ingress',numBool(w.ingress,true)));
		row(_('Egress'),chk('egress',numBool(w.egress,true)));
		// CAKE is only given nat/nonat when host_isolate is on; otherwise it gets
		// flow isolation and nat has no effect at all.
		var natCb=chk('nat',numBool(w.nat,!isDev));
		var hiCb=chk('host_isolate',numBool(w.host_isolate,true));
		var natNote=E('span',{'style':'opacity:.65;font-size:11px;margin-left:8px'},
			_('qosify only passes this to CAKE together with Host Isolate — add nat to Options to force it'));
		function syncNat(){
			natNote.style.display=hiCb.checked?'none':'';
		}
		hiCb.addEventListener('change',syncNat);
		syncNat();
		row(_('NAT'),[natCb,natNote]);
		row(_('Host Isolate'),hiCb);
		row(_('Autorate Ingress'),chk('autorate',numBool(w.autorate_ingress,false)));
		row(_('Ingress Options'),txt('ing_opts',w.ingress_options,_('e.g. %s').format('triple-isolate memlimit 32mb'),'width:100%;max-width:400px;font-family:monospace'));
		row(_('Egress Options'),txt('egr_opts',w.egress_options,_('e.g. %s').format('triple-isolate memlimit 32mb wash'),'width:100%;max-width:400px;font-family:monospace'));
		row(_('Options'),txt('opts',w.options,_('e.g. %s').format('overhead 44 mpu 84'),'width:100%;max-width:400px;font-family:monospace'));
		nodes.push(tbl);
		nodes.push(E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveQuick();}},_('Save & Apply'))));
		return nodes;
	},

	buildCtlSect:function(ctx){
		var self=this;
		var nodes=[E('legend',{},_('Service Controls'))];
		var svcCt=E('div',{'class':'qos-svc','id':'qos-svc-btns'});
		svcCt.appendChild(E('button',{
			'class':'cbi-button '+(ctx.enabled?'cbi-button-positive':'cbi-button-negative'),
			'id':'qos-btn-auto',
			'title':ctx.enabled?_('Click to disable autostart'):_('Click to enable autostart'),
			'click':function(){return self.svcAction(ctx.enabled?'disable':'enable');}
		},ctx.enabled?_('Enabled'):_('Disabled')));
		var btnCls={start:'cbi-button-apply',stop:'cbi-button-negative',restart:'cbi-button-action',reload:'cbi-button-reload'};
		['start','stop','restart','reload'].forEach(function(a){
			svcCt.appendChild(E('button',{
				'class':'cbi-button '+btnCls[a],
				'click':function(){return self.svcAction(a);}
			},({start:_('Start'),stop:_('Stop'),restart:_('Restart'),reload:_('Reload')})[a]));
		});
		nodes.push(svcCt);
		return nodes;
	},

	fillSect:function(id,nodes){
		var el=$(id);
		if(!el)return;
		dom.content(el,'');
		nodes.forEach(function(n){el.appendChild(n);});
		this.applyReadonly(el);
	},

	applyReadonly:function(el){
		if(!this.readonly||!el)return;
		el.querySelectorAll('input,select,textarea,button').forEach(function(x){
			if(!x.getAttribute('data-ro-ok'))x.setAttribute('disabled','');
		});
	},

	waitForRunning:function(timeoutMs){
		var deadline=Date.now()+(timeoutMs||3000);
		function tick(){
			return L.resolveDefault(callServiceList('qosify'),{}).then(function(r){
				if(isRunning(r))return true;
				if(Date.now()>=deadline)return false;
				return new Promise(function(res){setTimeout(res,400);}).then(tick);
			});
		}
		return tick();
	},

	waitForStopped:function(timeoutMs){
		var deadline=Date.now()+(timeoutMs||3000);
		function tick(){
			return L.resolveDefault(callServiceList('qosify'),{}).then(function(r){
				if(!isRunning(r))return true;
				if(Date.now()>=deadline)return false;
				return new Promise(function(res){setTimeout(res,400);}).then(tick);
			});
		}
		return tick();
	},

	applyService:function(){
		var self=this;
		return L.resolveDefault(callServiceList('qosify'),{}).then(function(r){
			if(isRunning(r))return callRcInit('qosify','reload');
			return callRcInit('qosify','start').then(function(){
				return self.waitForRunning(4000);
			}).then(function(up){
				if(!up)throw new Error(_('qosify did not come up — check the system log'));
			});
		});
	},

	updateEnBadge:function(el,ctx,enChecked){
		dom.content(el,'');
		if(ctx.active){el.className='qos-badge qos-green';dom.append(el,_('Active'));}
		else if(ctx.running&&enChecked){el.className='qos-badge qos-amber';dom.append(el,_('Enabled — Not Shaping (check config)'));}
		else if(enChecked){el.className='qos-badge qos-amber';dom.append(el,_('Enabled — Not Running'));}
		else{el.className='qos-badge qos-red';dom.append(el,_('Disabled'));}
	},

	svcNodes:function(ctx){
		function ok(t){return E('span',{'class':'qos-ok'},'\u2714 '+t);}
		function err(t){return E('span',{'class':'qos-err'},'\u2718 '+t);}
		function bdg(cls,t){return E('span',{'class':'qos-badge '+cls},t);}
		var run;
		if(ctx.running&&ctx.active)run=bdg('qos-green',_('Running & Shaping'));
		else if(ctx.running)run=bdg('qos-amber',_('Running — Not Shaping'));
		else run=bdg('qos-red',_('Not Running'));
		return {
			init:ctx.hasInit?ok(_('Available')):err(_('Missing')),
			auto:bdg(ctx.enabled?'qos-green':'qos-red',ctx.enabled?_('Enabled'):_('Disabled')),
			run:run,
			shaped:ctx.shaped?E('span',{},N_(ctx.shaped,'%d interface','%d interfaces').format(ctx.shaped)):E('span',{'class':'qos-muted'},_('none'))
		};
	},

	renderSvcTable:function(ctx){
		var n=this.svcNodes(ctx);
		var tbl=E('table',{'class':'qos-kv','width':'100%','id':'qos-svc-tbl'});
		var b=E('tbody');tbl.appendChild(b);
		b.appendChild(E('tr',{},[E('td',{},_('Init Script')),E('td',{'id':'qos-svc-init'},n.init)]));
		b.appendChild(E('tr',{},[E('td',{},_('Autostart')),E('td',{'id':'qos-svc-auto'},n.auto)]));
		b.appendChild(E('tr',{},[E('td',{},_('Running')),E('td',{'id':'qos-svc-run'},n.run)]));
		b.appendChild(E('tr',{},[E('td',{},_('Shaping')),E('td',{'id':'qos-svc-shaped'},n.shaped)]));
		return tbl;
	},

	updateSvcTable:function(ctx){
		var n=this.svcNodes(ctx),map={init:'qos-svc-init',auto:'qos-svc-auto',run:'qos-svc-run',shaped:'qos-svc-shaped'},k,el;
		for(k in map){el=$(map[k]);if(el)dom.content(el,n[k]);}
		el=$('qos-btn-auto');
		if(el){
			el.className='cbi-button '+(ctx.enabled?'cbi-button-positive':'cbi-button-negative');
			el.title=ctx.enabled?_('Click to disable autostart'):_('Click to enable autostart');
			dom.content(el,ctx.enabled?_('Enabled'):_('Disabled'));
		}
	},

	renderCfgFiles:function(ctx){
		var rulesN=(ctx.rulesN!=null)?ctx.rulesN:countRules(ctx.rulesText);
		var cfgOk=(ctx.cfgOk!=null)?ctx.cfgOk:((ctx.cfgRaw||'').length>10&&/(^|\n)config /.test(ctx.cfgRaw||''));
		var rulesOk=rulesN>0;
		var tbl=E('table',{'class':'qos-kv','width':'100%'});
		var b=E('tbody');tbl.appendChild(b);
		function fileRow(path,exists,ok,sz,mod,extra){
			var st;
			if(ok)st=E('span',{'class':'qos-ok'},'\u2714 '+_('Valid'));
			else if(exists)st=E('span',{'class':'qos-warn'},'\u26a0 '+_('Found (empty or invalid)'));
			else st=E('span',{'class':'qos-err'},'\u2718 '+_('Missing'));
			var meta=exists?E('span',{'style':'opacity:.7;margin-left:8px;font-size:12px'},'('+(extra||'')+fmtSize(sz)+', '+mod+')'):'';
			b.appendChild(E('tr',{},[E('td',{},path),E('td',{},[st,meta])]));
		}
		fileRow(UCI_PATH,!!ctx.cfgStat,cfgOk,ctx.cfgStat?ctx.cfgStat.size:0,ctx.cfgStat?fmtMtime(ctx.cfgStat.mtime):'');
		fileRow(this.rulesPath,!!ctx.rulesStat,rulesOk,ctx.rulesStat?ctx.rulesStat.size:0,ctx.rulesStat?fmtMtime(ctx.rulesStat.mtime):'',N_(rulesN,'%d rule','%d rules').format(rulesN)+', ');
		return tbl;
	},

	tabConfig:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-cf'});
		var fs1=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Config')),
			E('div',{'class':'cbi-section-descr'},[_('Classes, interfaces and defaults.')+' ',E('code',{},UCI_PATH)])
		]);

		// Quick Add Config — built first so the reference table can be derived from it
		var classes=this.getClasses();
		var dscpChoices=classes.map(function(c){return c.name;}).concat(DSCP);
		var qa=E('div',{'class':'qos-qa'});
		qa.appendChild(E('strong',{},_('Quick Add Config')));
		var qacRow=E('div',{'class':'qos-qa-row'});
		var qacType=E('select',{'id':'qac-type','style':'width:130px','change':function(){self.qacSwitch();}});
		SECT.forEach(function(o){qacType.appendChild(E('option',{'value':o[0]},o[1]));});
		qacRow.appendChild(qacType);
		qacRow.appendChild(E('span',{'id':'qac-nm-w','style':'display:none'},
			E('input',{'id':'qac-name','type':'text','placeholder':_('section name'),'style':'width:120px;font-family:monospace'})));
		qacRow.appendChild(E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qacAdd();}},_('Add')));
		qa.appendChild(qacRow);

		// config defaults — add_defaults() in qosify.init
		var qadDef=E('div',{'class':'qos-qa-row','id':'qac-opts-defaults'});
		this.qaInput(qadDef,'defaults','list','/etc/qosify/*.conf',180);
		this.qaNum(qadDef,'timeout','300',60);
		this.qaSelect(qadDef,'dscp_default_tcp',dscpChoices,140);
		this.qaSelect(qadDef,'dscp_default_udp',dscpChoices,140);
		this.qaSelect(qadDef,'dscp_icmp',dscpChoices,140);
		this.qaSelect(qadDef,'dscp_prio',dscpChoices,140);
		this.qaSelect(qadDef,'dscp_bulk',dscpChoices,140);
		this.qaNum(qadDef,'prio_max_avg_pkt_len','500',55);
		this.qaNum(qadDef,'bulk_trigger_pps','100',55);
		this.qaNum(qadDef,'bulk_trigger_timeout','5',45);
		qa.appendChild(qadDef);

		// config class / config alias — add_class()
		var qadCls=E('div',{'class':'qos-qa-row','id':'qac-opts-class','style':'display:none'});
		this.qaSelect(qadCls,'value',DSCP,70);
		this.qaSelect(qadCls,'ingress',DSCP,70);
		this.qaSelect(qadCls,'egress',DSCP,70);
		this.qaSelect(qadCls,'dscp_prio',dscpChoices,140);
		this.qaSelect(qadCls,'dscp_bulk',dscpChoices,140);
		this.qaNum(qadCls,'prio_max_avg_pkt_len','500',55);
		this.qaNum(qadCls,'bulk_trigger_pps','100',55);
		this.qaNum(qadCls,'bulk_trigger_timeout','5',45);
		qa.appendChild(qadCls);

		// config interface / config device — add_interface()
		var qadIf=E('div',{'class':'qos-qa-row','id':'qac-opts-interface','style':'display:none'});
		this.qaInput(qadIf,'name','option','wan',80);
		this.qaSelect(qadIf,'disabled',['0','1'],45);
		this.qaInput(qadIf,'bandwidth_up','option','100mbit',80);
		this.qaInput(qadIf,'bandwidth_down','option','100mbit',80);
		this.qaInput(qadIf,'bandwidth','option','100mbit',80);
		this.qaSelect(qadIf,'mode',MODES,100);
		this.qaSelect(qadIf,'ingress',['0','1'],45);
		this.qaSelect(qadIf,'egress',['0','1'],45);
		this.qaSelect(qadIf,'nat',['0','1'],45);
		this.qaSelect(qadIf,'host_isolate',['0','1'],45);
		this.qaSelect(qadIf,'autorate_ingress',['0','1'],45);
		this.qaSelect(qadIf,'overhead_type',OVH,130);
		this.qaNum(qadIf,'overhead','44',55);
		this.qaSelect(qadIf,'overhead_encap',ENCAP,70);
		this.qaNum(qadIf,'overhead_mpu','84',55);
		this.qaSelect(qadIf,'overhead_vlan',['0','1','2'],45);
		this.qaInput(qadIf,'ingress_options','option','triple-isolate',160);
		this.qaInput(qadIf,'egress_options','option','triple-isolate wash',160);
		this.qaInput(qadIf,'options','option','overhead 44 mpu 84',160);
		qa.appendChild(qadIf);

		// Reference panel — option lists read back out of the panels above, so the
		// reference and the Quick Add dropdown can never disagree.
		var ref=E('details',{'class':'qos-ref'});
		ref.appendChild(E('summary',{},_('Config Reference')));
		ref.appendChild(this.refTable({defaults:qadDef,'class':qadCls,'interface':qadIf}));
		var defBox=E('div',{'id':'qos-cfg-def','class':'qos-item'});
		dom.content(defBox,this.defsNodes());
		ref.appendChild(defBox);
		var clsBox=E('div',{'id':'qos-cfg-cls'});
		classes.forEach(function(c){
			clsBox.appendChild(self.clsBoxNode(c));
		});
		ref.appendChild(clsBox);
		ref.appendChild(E('div',{'class':'qos-muted','style':'margin:4px 0 2px'},
			_('DSCP codepoints: CS0–CS7, AF11–AF43, EF, VA, NQB, LE, DF. Any dscp_* value may also name a class. Prefix with + to override only when the DSCP field is zero. NQB needs a qosify newer than the one shipped with 24.10, which has no codepoint for it and drops the rule.')));
		ref.appendChild(E('div',{'class':'qos-muted','style':'margin:2px 0'},
			_('Defaults qosify applies when a key is absent — interface: mode diffserv4, ingress 1, egress 1, nat 1, host_isolate 1, autorate_ingress 0. device: identical except nat 0. defaults: timeout 3600, dscp_default_tcp/udp CS0, dscp_prio/dscp_bulk/dscp_icmp unset, bulk_trigger_pps/bulk_trigger_timeout/prio_max_avg_pkt_len 0 (disabled).')));
		fs1.appendChild(ref);
		fs1.appendChild(qa);

		// Editor
		var ta=E('textarea',{
			'id':'qos-config-ta',
			'class':'qos-edit',
			'rows':28,
			'style':'line-height:1.4;tab-size:4;padding:6px'
		},ctx.cfgRaw||'');
		ta.dataset.orig=ctx.cfgRaw||'';
		stampFile(ta,ctx.cfgStat);
		fs1.appendChild(ta);
		fs1.appendChild(E('div',{'class':'cbi-page-actions'},[
			E('button',{'class':'cbi-button cbi-button-reset','style':'margin-right:6px','click':function(){return self.clearCfg();}},_('Clear')),
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveConfig();}},_('Save & Apply'))
		]));

		section.appendChild(fs1);
		return section;
	},

	clsBoxNode:function(c){
		return E('div',{'class':'qos-item'},[
			E('strong',{},clsLabel(c)),
			E('span',{'class':'qos-muted','style':'margin-left:8px'},clsDesc(c))
		]);
	},

	refTable:function(panels){
		var note={
			'class':_('Section name is the class name that rules and dscp_* values refer to. value sets ingress and egress together.'),
			alias:_('Same options as class — gives an existing class a second name.'),
			'interface':_('name is the netifd interface. bandwidth applies only where bandwidth_up/bandwidth_down are unset. overhead and overhead_encap apply only when overhead_type is manual.'),
			device:_('Same options as interface, but name is a netdev. nat defaults to 0 here and to 1 for interfaces.')
		};
		var tbl=E('table',{'class':'qos-kv','width':'100%','style':'margin:6px 0'});
		var b=E('tbody');tbl.appendChild(b);
		SECT.forEach(function(o){
			var div=panels[QAC_PANEL[o[0]]],els=div?div.querySelectorAll('[data-opt]'):[],out=[];
			for(var i=0;i<els.length;i++)
				out.push((els[i].getAttribute('data-pre')==='list'?'list ':'option ')+els[i].getAttribute('data-opt'));
			b.appendChild(E('tr',{},[
				E('td',{'style':'width:135px;font-family:monospace;vertical-align:top'},o[1]),
				E('td',{},[
					E('div',{'style':'font-family:monospace;font-size:11px;line-height:1.6'},out.join(', ')),
					note[o[0]]?E('div',{'class':'qos-muted','style':'margin-top:3px'},note[o[0]]):''
				])
			]));
		});
		return tbl;
	},

	qaId:function(parent,opt){return (parent.id||'qac')+'-'+opt;},
	qaInput:function(parent,opt,pre,ph,w){
		var id=this.qaId(parent,opt);
		parent.appendChild(E('label',{'for':id},opt+':'));
		parent.appendChild(E('input',{
			'id':id,'data-opt':opt,'data-pre':pre,'type':'text',
			'value':pre==='list'?ph:'','placeholder':pre==='list'?'':ph,
			'style':'width:'+w+'px;font-family:monospace'
		}));
	},
	qaSelect:function(parent,opt,opts,w,required){
		var id=this.qaId(parent,opt);
		parent.appendChild(E('label',{'for':id},opt+':'));
		var s=E('select',{'id':id,'data-opt':opt,'style':'width:'+w+'px'});
		if(!required)s.appendChild(E('option',{'value':''},'--'));
		opts.forEach(function(o){s.appendChild(E('option',{'value':o},o));});
		parent.appendChild(s);
	},
	qaNum:function(parent,opt,ph,w){
		var id=this.qaId(parent,opt);
		parent.appendChild(E('label',{'for':id},opt+':'));
		parent.appendChild(E('input',{'id':id,'data-opt':opt,'type':'number','min':'0','placeholder':ph,'style':'width:'+w+'px'}));
	},

	lock:function(){this._n=(this._n||0)+1;},
	unlock:function(){this._n=Math.max(0,(this._n||0)-1);},

	defsNodes:function(){
		var d=null;
		uci.sections('qosify','defaults',function(s){if(!d)d=s;});
		if(!d)return [E('em',{'class':'qos-muted'},_('No config defaults section defined'))];
		var keys=['timeout','dscp_default_tcp','dscp_default_udp','dscp_icmp','dscp_prio','dscp_bulk','prio_max_avg_pkt_len','bulk_trigger_pps','bulk_trigger_timeout'];
		var line=E('div',{'class':'qos-muted','style':'margin:2px 0 0;font-family:monospace'}),first=true;
		keys.forEach(function(k){
			if(!d[k])return;
			if(!first)dom.append(line,'\u00a0\u00a0');
			first=false;
			dom.append(line,[k+': ',E('strong',{},String(d[k]))]);
		});
		return [E('strong',{},'config defaults'),line];
	},

	// qosify.init runs add_class() over both `class` and `alias`, so alias names
	// are equally valid rule targets and dscp_* values. ingress/egress fall back
	// to `value`, mirroring "${ingress:-$value}" in add_class().
	getClasses:function(){
		var arr=[];
		['class','alias'].forEach(function(t){
			uci.sections('qosify',t,function(s){
				arr.push({name:s['.name'],alias:t==='alias',
					ingress:s.ingress||s.value||'',egress:s.egress||s.value||'',
					dscp_prio:s.dscp_prio||'',dscp_bulk:s.dscp_bulk||'',
					prio_max_avg_pkt_len:s.prio_max_avg_pkt_len||'',
					bulk_trigger_pps:s.bulk_trigger_pps||'',
					bulk_trigger_timeout:s.bulk_trigger_timeout||''});
			});
		});
		return arr;
	},

	refreshClasses:function(){
		var classes=this.getClasses();
		var db=$('qos-cfg-def');
		if(db)dom.content(db,this.defsNodes());
		var sel=$('qar-cls');
		if(sel){
			var cur=sel.value;
			dom.content(sel,'');
			classes.forEach(function(c){sel.appendChild(E('option',{'value':c.name},c.name));});
			if(cur&&classes.some(function(c){return c.name===cur;}))sel.value=cur;
		}
		var names=classes.map(function(c){return c.name;}).concat(DSCP);
		['qac-opts-defaults','qac-opts-class'].forEach(function(id){
			var p=$(id);if(!p)return;
			var ss=p.querySelectorAll('select[data-opt^="dscp_"]');
			for(var i=0;i<ss.length;i++){
				var s=ss[i],cur=s.value;
				dom.content(s,'');
				s.appendChild(E('option',{'value':''},'--'));
				names.forEach(function(o){s.appendChild(E('option',{'value':o},o));});
				s.value=cur;
			}
		});
		var ref=$('qos-cls-ref');
		if(ref){
			dom.content(ref,'');
			if(classes.length){
				classes.forEach(function(c){
					ref.appendChild(E('tr',{},[
						E('td',{'style':'width:140px'},clsLabel(c)),
						E('td',{},clsDesc(c))
					]));
				});
			}else{
				ref.appendChild(noClassRow());
			}
		}
		var cbox=$('qos-cfg-cls'),self=this;
		if(cbox){
			dom.content(cbox,'');
			classes.forEach(function(c){cbox.appendChild(self.clsBoxNode(c));});
		}
	},

	tabRules:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-ru'});
		var fs1=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Classification Rules')),
			E('div',{'class':'cbi-section-descr'},[_('DSCP rules qosify loads at startup.')+' ',E('code',{'id':'qos-rules-path'},this.rulesPath)])
		]);

		// Available classes
		var classes=this.getClasses();
		var ref=E('details',{'class':'qos-ref'});
		ref.appendChild(E('summary',{},_('Available Classes')));
		var refTbl=E('table',{'class':'qos-kv','style':'margin:6px 0 0','width':'100%'});
		var refB=E('tbody',{'id':'qos-cls-ref'});refTbl.appendChild(refB);
		if(classes.length){
			classes.forEach(function(c){
				refB.appendChild(E('tr',{},[
					E('td',{'style':'width:140px'},clsLabel(c)),
					E('td',{},clsDesc(c))
				]));
			});
		}else{
			refB.appendChild(noClassRow());
		}
		ref.appendChild(refTbl);
		ref.appendChild(E('div',{'class':'qos-muted','style':'margin:6px 0 2px'},
			_('Prefix with + to override only when the DSCP field is zero. Ports: tcp:443, udp:3074, ranges: tcp:5060-5061 (1-65534). DNS: dns:*teams*, regex: dns:/zoom[0-9]+, CNAME-only: dns_c:. IP: 1.1.1.1, ff01::1')));
		fs1.appendChild(ref);

		// Quick Add Rule
		var qa=E('div',{'class':'qos-qa'});
		qa.appendChild(E('strong',{},_('Quick Add Rule')));
		var qarRow=E('div',{'class':'qos-qa-row'});
		var qarType=E('select',{'id':'qar-type','style':'width:140px','change':function(){self.qarPlaceholder();}});
		[['tcp:',_('tcp port')],['udp:',_('udp port')],['both:',_('tcp+udp port')],['dns:',_('dns pattern')],['dnsr:',_('dns regex')],['dns_c:',_('dns_c pattern')],['dns_cr:',_('dns_c regex')],['ipv4:',_('IPv4 address')],['ipv6:',_('IPv6 address')]].forEach(function(o){
			qarType.appendChild(E('option',{'value':o[0]},o[1]));
		});
		qarRow.appendChild(qarType);
		qarRow.appendChild(E('input',{'id':'qar-val','type':'text','placeholder':_('e.g. %s').format('4500'),'style':'width:180px;font-family:monospace'}));
		var qarCls=E('select',{'id':'qar-cls','style':'width:140px'});
		classes.forEach(function(c){qarCls.appendChild(E('option',{'value':c.name},c.name));});
		qarRow.appendChild(qarCls);
		qarRow.appendChild(E('label',{'class':'qos-muted','style':'white-space:nowrap','for':'qar-prio'},
			[E('input',{'type':'checkbox','id':'qar-prio'}),' '+_('only if unset (+)')]));
		qarRow.appendChild(E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qarAdd();}},_('Add')));
		qa.appendChild(qarRow);
		fs1.appendChild(qa);

		// Editor
		var ta=E('textarea',{
			'id':'qos-rules-ta','class':'qos-edit','rows':28,
			'style':'line-height:1.4;tab-size:4;padding:6px'
		},ctx.rulesText||'');
		ta.dataset.orig=ctx.rulesText||'';
		stampFile(ta,ctx.rulesStat);
		fs1.appendChild(ta);
		fs1.appendChild(E('div',{'class':'cbi-page-actions'},[
			E('button',{'class':'cbi-button cbi-button-reset','style':'margin-right:6px','click':function(){return self.clearRules();}},_('Clear')),
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveRules();}},_('Save & Apply'))
		]));

		section.appendChild(fs1);
		return section;
	},

	// Same shape as Overview: one cbi-section per job, each holding a single
	// ruled two-column table, with actions in a qos-svc button row underneath.
	tabAdvanced:function(){
		var self=this,section=E('div',{'id':'qos-ad'});
		function sect(title,descr,body,actions){
			var nodes=[E('legend',{},title),E('div',{'class':'cbi-section-descr'},descr),body];
			if(actions)nodes.push(E('div',{'class':'qos-svc qos-actions'},actions));
			return E('fieldset',{'class':'cbi-section'},nodes);
		}
		function fileIn(id){return E('input',{'type':'file','id':id,'class':'cbi-input-file'});}

		section.appendChild(sect(_('Backup'),_('Download the current files.'),
			this.kvTable([
				[UCI_PATH,this.dlBtn(UCI_PATH,'qosify')],
				[RULES_PATH,this.dlBtn(RULES_PATH,'00-defaults.conf')]
			])));

		section.appendChild(sect(_('Restore'),_('Overwrite a file and restart qosify.'),
			this.kvTable([
				[E('label',{'for':'qos-up-cfg'},UCI_PATH),fileIn('qos-up-cfg')],
				[E('label',{'for':'qos-up-rules'},RULES_PATH),fileIn('qos-up-rules')]
			]),
			E('button',{'class':'cbi-button cbi-button-apply',
				'click':function(){return self.uploadFiles();}},_('Save & Apply'))));

		section.appendChild(sect(_('Reset'),_('Restore qosify defaults. QoS is left disabled.'),
			this.kvTable([
				[UCI_PATH,_('replaced from the package template')],
				[RULES_PATH,_('replaced from the package template')]
			]),
			E('button',{'class':'cbi-button cbi-button-negative',
				'click':function(){return self.resetDefaults();}},_('Reset to Defaults'))));

		section.appendChild(sect(_('Display'),_('Kept in this browser, not in the qosify config.'),
			this.kvTable([[
				E('label',{'for':'qos-ad-cn'},_('Counters tab')),
				[E('input',{'id':'qos-ad-cn','type':'checkbox','class':'cbi-input-checkbox',
					'data-ro-ok':'1','checked':self.showCounters?'':null,
					'change':function(ev){
						self.showCounters=!!ev.target.checked;
						prefSetShow(self.showCounters);
						self.applyTabVisibility();
					}}),
					E('div',{'class':'qos-muted'},_('Per-class totals and the daemon map.'))]
			]])));
		return section;
	},

	// The two-column ruled table the Overview sections are built from, so every
	// tab reads the same way.
	kvTable:function(rows){
		var t=E('table',{'class':'qos-kv','width':'100%'}),b=E('tbody');
		t.appendChild(b);
		rows.forEach(function(r){
			b.appendChild(E('tr',{},[E('td',{},r[0]),E('td',{},r[1])]));
		});
		return t;
	},

	dlBtn:function(path,fn){
		return E('button',{'class':'cbi-button cbi-button-action','data-ro-ok':'1','click':function(){
			return fs.read(path).then(function(content){
				var b=new Blob([content||''],{type:'application/octet-stream'});
				var url=URL.createObjectURL(b);
				var a=E('a',{'href':url,'download':fn,'style':'display:none'});
				document.body.appendChild(a);
				a.click();
				setTimeout(function(){
					URL.revokeObjectURL(url);
					if(a.parentNode)a.parentNode.removeChild(a);
				},2000);
			}).catch(function(e){
				notify(_('Could not read %s: %s').format(path,e),'danger');
			});
		}},_('Download'));
	},

	// The daemon counters and the map listing live on the Counters tab; this one is
	// the shaper's own view of itself: ubus status plus the qosify-status fork.
	tabStatus:function(ctx){
		var section=E('div',{'id':'qos-st'});
		var fs1=E('fieldset',{'class':'cbi-section'},E('legend',{},_('qosify-status')));
		var body=E('div',{'id':'qos-st-body'},[
			E('div',{'id':'qos-st-sum'}),
			E('pre',{'id':'qos-st-pre','class':'qos-pre','style':'display:none'}),
			E('div',{'id':'qos-st-msg'})
		]);
		fs1.appendChild(body);
		section.appendChild(fs1);
		this.fillStatus(body,ctx);
		return section;
	},

	// ubus call qosify get_stats. The reply shape is whatever the installed daemon
	// emits: the current one adds ebpf_map_entries, last_reload_time, dns_cache and
	// the classes/dscp/dns tables (qosify_map_stats/_dscp_stats/_dns_stats in
	// map.c), while the build pinned by OpenWrt 24.10 returns qosify_map_stats() at
	// the top level -- one table per class, packets only. Nothing is rendered that
	// the reply does not contain, so an older daemon shows the counters it has
	// instead of a table of dashes.
	isCounter:function(v){return !!v&&typeof v==='object'&&(v.packets!=null||v.bytes!=null);},
	statsNodes:function(st){
		var out=[],b=null;
		function tbl(title){
			var t=E('table',{'class':'qos-kv','width':'100%'});
			b=E('tbody');
			t.appendChild(b);
			out.push(E('div',{'class':'qos-item'},E('strong',{},title)),t);
		}
		function row(k,v){
			b.appendChild(E('tr',{},[E('td',{},k),E('td',{},v)]));
		}
		function traffic(e){
			if(e.bytes==null)return _('%d packets').format(e.packets||0);
			return _('%d packets, %s').format(e.packets||0,'%1024.2mB'.format(e.bytes));
		}
		var head=[];
		// qosify_map_get_ebpf_entry_count() sums the IPv4 and IPv6 address maps only;
		// the port maps are fixed 65536-entry arrays and are not counted.
		if(st.ebpf_map_entries!=null)head.push([_('eBPF IP map entries'),String(st.ebpf_map_entries)]);
		if(st.last_reload_time)head.push([_('Last reload'),fmtMtime(st.last_reload_time)]);
		if(st.dns_cache)head.push([_('DNS cache'),_('%d entries, %d hits, %d misses')
			.format(st.dns_cache.size||0,st.dns_cache.hits||0,st.dns_cache.misses||0)]);
		if(head.length){
			tbl(_('Daemon'));
			head.forEach(function(r){row(r[0],r[1]);});
		}
		// Per-class totals are the bar chart above, so only the DSCP table is left.
		var k,n=0;
		for(k in st.dscp)n++;
		if(n){
			tbl(_('DSCP'));
			for(k in st.dscp)row(k,traffic(st.dscp[k]||{}));
		}
		n=0;
		for(k in st.dns)n++;
		if(n){
			tbl(_('DNS patterns'));
			for(k in st.dns){
				var e=st.dns[k]||{};
				row(k,_('%s, %d hits, %s').format(e.dscp||'-',e.hits||0,traffic(e)));
			}
		}
		return out;
	},

	// ubus call qosify dump: the entries the daemon is matching on, so a rule that
	// did not load is visible as an absence rather than having to be inferred.
	// qosify_map_set_port() in map.c loops start_port..end_port and stores one map
	// entry per port, so `udp:6881-7000` comes back as 120 entries. Runs of
	// consecutive ports that agree on type, dscp, source and timeout are shown as
	// the range they were expanded from; ports arrive in ascending order because
	// the avl key holds them in network byte order. Nothing else is merged, and a
	// reply in another order simply does not collapse.
	// A raw DSCP as a number, or -1 for anything the daemon would not have taken:
	// __qosify_map_dscp_value() reads a codepoint or a number below 64 and nothing
	// else, and dscpNum() takes the same bases strtoul(base 0) does.
	dscpVal:function(v){
		var s=String(v==null?'':v).replace(/^\+/,'').toUpperCase(),n;
		if(DSCP_VAL[s]!=null)return DSCP_VAL[s];
		n=dscpNum(s);
		return n===null||n>=64?-1:n;
	},
	// dump reports an entry's DSCP as the daemon holds it: a codepoint, a raw
	// value, or a class name -- blobmsg_add_dscp() prints map_class[]->name, with a
	// leading + where the fallback flag is set. Class names are resolved through
	// the section that defined them, egress first, both sides already falling back
	// to `value` in getClasses().
	dscpRanks:function(){
		var m={},self=this;
		this.getClasses().forEach(function(c){m[c.name]=self.dscpVal(c.egress||c.ingress);});
		return m;
	},
	// Ordered by DSCP, highest first, so the classes that matter are at the top and
	// bulk is at the end. Entries the daemon added itself from a DNS lookup carry a
	// timeout and no counters of their own, and a DNS-driven config has hundreds of
	// them, so they follow the entries the config loaded and the MAP_ROWS cut falls
	// on addresses that come back on the next lookup rather than on the rules.
	// Ports are collapsed on the way in, where the reply still has them in
	// ascending order, and ties keep that order afterwards.
	mapRows:function(entries){
		var rows=[],dyn=[],cls=this.dscpRanks(),self=this,i,e,n,a,last,rk;
		for(i=0;i<entries.length;i++){
			e=entries[i]||{};
			a=(e.user&&!e.file)?dyn:rows;
			n=((e.type==='tcp_port'||e.type==='udp_port')&&/^\d+$/.test(String(e.addr)))?parseInt(e.addr,10):null;
			last=a[a.length-1];
			if(n!==null&&last&&last.end===n-1&&last.type===e.type&&last.dscp===e.dscp&&
			   last.file===!!e.file&&last.user===!!e.user&&last.timeout===e.timeout){
				last.end=n;
				last.n++;
				continue;
			}
			rk=String(e.dscp==null?'':e.dscp).replace(/^\+/,'');
			a.push({type:e.type,addr:e.addr,dscp:e.dscp,file:!!e.file,user:!!e.user,
				timeout:e.timeout,start:n,end:n,n:1,ix:a.length,
				rk:cls[rk]!=null?cls[rk]:self.dscpVal(rk)});
		}
		function byDscp(x,y){return y.rk-x.rk||x.ix-y.ix;}
		return rows.sort(byDscp).concat(dyn.sort(byDscp));
	},
	// dns is the `dns` table of get_stats, keyed by pattern. qosify counts traffic
	// per entry for DNS patterns only -- qosify_map_dns_stats() sums the per-CPU
	// pattern_stats map -- while the port and address maps hold a DSCP byte and no
	// counters at all, so those rows have nothing to show and the class and DSCP
	// totals in Daemon counters are as far down as the daemon counts.
	// hits is on the row as well as the packet counters: hits counts the lookups
	// the pattern matched -- every matching pattern is counted, not just the one
	// whose DSCP wins -- while packets are accounted in the datapath against the
	// pattern_id in the address map entry. __qosify_map_set_entry() writes that
	// entry only where the DSCP changes, which a new address always does, so an
	// address that was already in the map at the same DSCP keeps the pattern_id
	// of whatever put it there: hits then move on the pattern while its packets
	// are counted somewhere else, or not at all.
	// hasDns false means the running daemon has no per-pattern counters at all --
	// see refreshCounters() -- so the column goes rather than carrying a dash on
	// every row. null is "not asked yet" and keeps it; the box is rebuilt on the
	// next tick anyway.
	mapNodes:function(entries,dns,hasDns){
		var tcol=hasDns!==false;
		var hdr=[E('th',MAP_TH,_('Type')),E('th',MAP_TH,_('Match')),E('th',MAP_TH,_('DSCP')),
			E('th',MAP_TH,_('Source'))];
		if(tcol)hdr.push(E('th',MAP_TH,_('Traffic')));
		hdr.push(E('th',MAP_TH,_('Timeout')));
		var tbl=E('table',{'class':'table'},E('tr',{'class':'tr table-titles'},hdr));
		// A pattern with no traffic is left out of the stats reply, so it is zero
		// rather than unknown -- but only once the reply has a dns table at all.
		function traffic(r){
			if(r.type!=='dns'||!dns)return '-';
			var e=dns[r.addr]||{};
			if(e.bytes==null)return _('%d hits, %d packets').format(e.hits||0,e.packets||0);
			return _('%d hits, %d packets, %s').format(e.hits||0,e.packets||0,'%1024.2mB'.format(e.bytes));
		}
		var rows=this.mapRows(entries);
		rows.slice(0,MAP_ROWS).forEach(function(r){
			var src=[];
			if(r.file)src.push(_('file'));
			if(r.user)src.push(_('dynamic'));
			var td=[E('td',{'class':'td'},r.type||'-'),
				E('td',{'class':'td'},r.n>1?(r.start+'-'+r.end):String(r.addr!=null?r.addr:'-')),
				E('td',{'class':'td'},r.dscp||'-'),
				E('td',{'class':'td'},src.join(', ')||'-')];
			if(tcol)td.push(E('td',{'class':'td'},traffic(r)));
			td.push(E('td',{'class':'td'},r.timeout!=null?_('%d s').format(r.timeout):'-'));
			tbl.appendChild(E('tr',{'class':'tr'},td));
		});
		var out=[tbl];
		// qosify_map_dump() only emits `timeout` for user entries, so every file
		// entry shows none -- say so once rather than leaving a column of dashes
		// looking like a failure.
		if(rows.some(function(r){return r.file&&r.timeout==null;}))
			out.push(E('div',{'class':'qos-muted'},
				_('Timeouts apply to dynamic entries only.')));
		if(!tcol)
			out.push(E('div',{'class':'qos-muted'},
				_('The running qosify reports no per-entry counters — its get_stats has no dns table.')));
		else if(rows.some(function(r){return r.type!=='dns';}))
			out.push(E('div',{'class':'qos-muted'},
				_('qosify counts traffic per entry for DNS patterns only.')));
		out.push(E('div',{'class':'qos-muted'},rows.length>MAP_ROWS
			?_('Showing %d of %d rows (%d entries). Port ranges are collapsed.').format(MAP_ROWS,rows.length,entries.length)
			:_('%d rows, %d entries.').format(rows.length,entries.length)));
		return out;
	},

	// Two ubus calls and no forks, both read-only: get_stats feeds the chart and
	// the tables. The map listing is a separate, slower queue entry -- see
	// installPollers() -- because it is an order of magnitude more data.
	refreshCounters:function(){
		var self=this;
		if(self.currentTab!=='cn'||self._cn)return Promise.resolve();
		self._cn=true;
		return Promise.all([
			L.resolveDefault(callServiceList('qosify'),{}),
			L.resolveDefault(callQosifyStats(),null)
		]).then(function(d){
			var ctx={running:isRunning(d[0]),stats:d[1]};
			self._cnStats=ctx.running?ctx.stats:null;
			// 24.10 pins qosify at 2024-09-20 (1501e09), whose get_stats answers with
			// qosify_map_stats() at the top level: one table per class with packets,
			// and no dns table anywhere. Master opens the table even when empty, so
			// its absence is the build, not a quiet period.
			if(ctx.stats)self._cnDns=ctx.stats.dns!=null;
			self.fillCounters(ctx);
		}).finally(function(){self._cn=false;});
	},

	// The DNS traffic column comes from the counters already on hand, so the
	// listing costs exactly one call.
	refreshMapEntries:function(){
		var self=this;
		if(self.currentTab!=='cn'||self._cnMap)return Promise.resolve();
		self._cnMap=true;
		return L.resolveDefault(callQosifyDump(),null).then(function(r){
			self.fillMap(r,self._cnStats&&self._cnStats.dns,
				self._cnDns==null?null:self._cnDns);
		}).finally(function(){self._cnMap=false;});
	},

	// initTabGroup() puts data-tab on each menu <li>, so a pane can be taken off
	// the menu without rebuilding the group. The pane itself stays in the DOM: it
	// is empty until it is opened.
	applyTabVisibility:function(root){
		var li=(root||document).querySelector('ul.cbi-tabmenu > li[data-tab="cn"]');
		if(li)li.style.display=this.showCounters?'':'none';
	},

	tabCounters:function(){
		var section=E('div',{'id':'qos-cn'});
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Daemon counters')),
			E('div',{'class':'cbi-section-descr'},_('Totals since qosify last reloaded.')),
			E('div',{'id':'qos-cn-bars'}),
			E('div',{'class':'qos-muted'},_('Bar length is log-scaled; the figures are exact.')),
			E('div',{'id':'qos-cn-tbl'}),
			E('div',{'id':'qos-cn-msg'})
		]));
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Map entries')),
			E('div',{'class':'cbi-section-descr'},_('Entries qosify is matching on right now.')),
			E('div',{'id':'qos-cn-map','class':'qos-scroll'},
				E('p',{'class':'qos-muted'},E('em',{},_('Reading map entries...'))))
		]));
		return section;
	},

	// Cumulative totals per class, straight from get_stats -- no sampling, so the
	// numbers are what the daemon has counted since its last reload and nothing is
	// lost by leaving the tab closed. Bars are scaled against the largest class,
	// with a sliver kept for any non-zero class so it stays visible beside one that
	// dwarfs it, and the rows are ordered by size.
	classTotals:function(st){
		var cls=st&&st.classes,k,rows=[],names=[],total=0,self=this;
		if(!cls){
			cls={};
			for(k in st)if(self.isCounter(st[k]))cls[k]=st[k];
		}
		for(k in cls)if(cls[k].packets!=null)names.push(k);
		names.sort();
		names.forEach(function(n,ix){
			var v=cls[n].packets||0;
			total+=v;
			rows.push({name:n,v:v,bytes:cls[n].bytes,color:CN_COLORS[ix%CN_COLORS.length]});
		});
		rows.sort(function(a,b){return b.v-a.v||(a.name<b.name?-1:1);});
		rows.total=total;
		return rows;
	},

	// Packet totals per class on a log axis: a bulk class can outweigh voice by
	// four orders of magnitude, and on a linear axis everything but bulk is a
	// sliver, so the bar length is log-scaled while the figures beside it stay the
	// daemon's own. Share is of all packets the daemon has classified.
	barChart:function(st){
		var rows=this.classTotals(st),max=0,total=rows.total||0;
		if(!rows.length)
			return E('p',{'class':'qos-muted'},E('em',{},_('The daemon reported no per-class counters.')));
		rows.forEach(function(r){if(r.v>max)max=r.v;});
		var box=E('div',{'class':'qos-bars'});
		rows.forEach(function(r){
			var pct=Math.max(r.v?2:0,max?(Math.log(1+r.v)/Math.log(1+max))*100:0);
			var share=total?(r.v/total)*100:0;
			box.appendChild(E('div',{'class':'qos-bar-row','title':r.bytes!=null
				?_('%s: %d packets, %s').format(r.name,r.v,'%1024.2mB'.format(r.bytes))
				:_('%s: %d packets').format(r.name,r.v)},[
				E('div',{'class':'qos-bar-label'},[
					E('span',{'class':'qos-swatch','style':'background:'+r.color}),
					E('span',{},r.name)
				]),
				E('div',{'class':'qos-bar-track'},
					E('div',{'class':'qos-bar-fill','style':'width:'+pct.toFixed(1)+'%;background:'+r.color})),
				E('div',{'class':'qos-bar-val'},[
					E('span',{'class':'qos-bar-num'},_('%d pkt').format(r.v)),
					E('span',{'class':'qos-bar-pct'},fmtShare(share))
				])
			]));
		});
		box.appendChild(E('div',{'class':'qos-bar-row qos-bar-total'},[
			E('div',{'class':'qos-bar-label'},_('total')),
			E('div',{'class':'qos-bar-track'}),
			E('div',{'class':'qos-bar-val'},[
				E('span',{'class':'qos-bar-num'},_('%d pkt').format(total)),
				E('span',{'class':'qos-bar-pct'},_('%s%%').format(100))
			])
		]));
		return box;
	},

	drawBars:function(){
		var box=$('qos-cn-bars');
		if(box)dom.content(box,this._cnStats?this.barChart(this._cnStats):'');
	},

	fillCounters:function(ctx){
		var msg=$('qos-cn-msg'),tbl=$('qos-cn-tbl');
		if(!ctx.running){
			if(tbl)dom.content(tbl,'');
			this.drawBars();
			if(msg)dom.content(msg,E('div',{'class':'alert-message warning'},
				_('qosify is not running. Start from the Overview tab.')));
			return;
		}
		if(msg)dom.content(msg,ctx.stats?'':E('p',{'class':'qos-muted'},
			E('em',{},_('The daemon returned no counters.'))));
		this.drawBars();
		if(tbl)dom.content(tbl,ctx.stats?this.statsNodes(ctx.stats):'');
	},

	// Rebuilt in place on every tick, so the scroll offset of the box is put back:
	// losing your place in 200 rows every ten seconds makes it unreadable.
	fillMap:function(r,dns,hasDns){
		var box=$('qos-cn-map');
		if(!box)return;
		var e=r&&r.entries,top=box.scrollTop;
		dom.content(box,e&&e.length?this.mapNodes(e,dns,hasDns)
			:E('p',{'class':'qos-muted'},E('em',{},_('The daemon reported no map entries.'))));
		box.scrollTop=top;
	},

	lintAll:function(){
		var out=[];
		function walk(type,dev){
			uci.sections('qosify',type,function(s){
				if(uciBool(s.disabled,false))return;
				ifLint(s,dev).forEach(function(t){out.push(s['.name']+': '+t);});
			});
		}
		walk('interface',false);
		walk('device',true);
		// qosify.init feeds class then alias to add_class() in that order, so the
		// sections past the sixteenth slot are the last ones here too.
		var cls=this.getClasses(),names=cls.map(function(c){return c.name;});
		cls.forEach(function(c){
			clsLint(c,names).forEach(function(t){out.push(c.name+': '+t);});
		});
		if(cls.length>MAX_CLASSES)
			out.push(_('%d class and alias sections are defined but qosify holds %d — the last %d are dropped, with every rule that targets them')
				.format(cls.length,MAX_CLASSES,cls.length-MAX_CLASSES));
		return out;
	},

	// Runs on every poll tick and twice per open, so only the summary table is
	// rebuilt: replacing the <pre> would throw away the scroll position while it
	// is being read. ctx.qstatus null means the fork has not returned yet, '' means
	// it returned nothing -- the two used to look the same on screen.
	fillStatus:function(body,ctx){
		var sum=body.querySelector('#qos-st-sum'),pre=body.querySelector('#qos-st-pre'),msg=body.querySelector('#qos-st-msg');
		if(!sum||!pre||!msg)return;
		var note=function(t){dom.content(msg,E('p',{'class':'qos-muted'},E('em',{},t)));};
		if(!ctx.running){
			dom.content(sum,'');
			pre.style.display='none';
			dom.content(msg,E('div',{'class':'alert-message warning'},_('qosify is not running. Start from the Overview tab.')));
			return;
		}
		dom.content(sum,this.statusSummary(ctx.status));
		pre.style.display=ctx.qstatus?'':'none';
		if(ctx.qstatus){
			if(pre.textContent!==ctx.qstatus)pre.textContent=ctx.qstatus;
			dom.content(msg,'');
		}
		else if(this.readonly)note(_('The detailed tc output needs write access to this page.'));
		else if(ctx.qstatus==null)note(_('Reading tc output...'));
		else note(_('qosify-status returned no output.'));
	},

	// ubus call qosify status, so the per-interface summary costs no forks
	statusSummary:function(st){
		var tbl=E('table',{'class':'qos-kv','width':'100%'}),b=E('tbody');
		tbl.appendChild(b);
		['interfaces','devices'].forEach(function(g){
			var t=st&&st[g],k,e;
			for(k in t){
				e=t[k]||{};
				b.appendChild(E('tr',{},[
					E('td',{},(g==='devices'?_('device %s'):_('interface %s')).format(k)),
					E('td',{},[
						E('span',{'class':'qos-badge '+(e.active?'qos-green':'qos-red')},e.active?_('active'):_('inactive')),
						E('span',{'class':'qos-muted','style':'margin-left:8px'},
							_('device: %s, ingress: %s, egress: %s').format(e.ifname||'-',e.ingress?_('yes'):_('no'),e.egress?_('yes'):_('no')))
					])
				]));
			}
		});
		if(!b.firstChild)b.appendChild(E('tr',{},E('td',{'class':'qos-muted'},E('em',{},_('qosify has no interfaces or devices configured')))));
		return tbl;
	},

	// === Actions ===

	svcAction:function(action){
		var self=this;
		self.lock();
		ui.showModal(_('Working'),[E('p',{},_('Sending %s to qosify...').format(action))]);
		var p=callRcInit('qosify',action);
		if(action==='start'||action==='restart')
			p=p.then(function(){return self.waitForRunning(4000);}).then(function(up){
				if(!up)throw new Error(_('qosify did not come up — check the system log'));
			});
		if(action==='stop')
			p=p.then(function(){return self.waitForStopped(4000);}).then(function(down){
				if(!down)throw new Error(_('qosify is still running — leaving the qdiscs alone'));
				return fs.exec('/usr/share/qosify-luci/cleanup',[]).then(function(r){
					if(r&&r.code)notify(_('Cleanup exited with code %d').format(r.code),'warning');
				});
			});
		return p.then(function(){
			return new Promise(function(r){setTimeout(r,800);});
		}).then(function(){
			return self.refreshOverview();
		}).catch(function(e){
			notify(_('Service action failed: %s').format(e),'danger');
		}).finally(function(){
			ui.hideModal();
			self.unlock();
		});
	},

	saveQuick:function(){
		var self=this;
		var get=function(id){var e=$('q-'+id);return e?e.value:'';};
		var chk=function(id){var e=$('q-'+id);return e&&e.checked;};
		var bw=function(s){return trim(s).replace(/\s+/g,'');};
		var bwUp=bw(get('bw_up')),bwDn=bw(get('bw_down'));
		var rate=/^(unlimited|\d+(\.\d+)?((k|m|g|t)?(bit|bps)|(ki|mi|gi)(bit|bps))?)$/i;
		var ovh=get('overhead'),mode=get('mode'),ovhB=trim(get('overhead_b'));
		var iopts=trim(get('ing_opts')),eopts=trim(get('egr_opts')),gopts=trim(get('opts'));
		var safe=/^[\w\s.:-]*$/;
		if(!safe.test(iopts)||!safe.test(eopts)||!safe.test(gopts)){
			notify(_('Error: invalid characters in options fields. Use alphanumeric, spaces, hyphens, dots, colons only.'),'danger');
			return;
		}
		if(bwUp&&!rate.test(bwUp))notify(_('bandwidth_up does not look like a tc rate (100mbit, 12MBps, unlimited) — passing it through anyway'),'warning');
		if(bwDn&&!rate.test(bwDn))notify(_('bandwidth_down does not look like a tc rate (100mbit, 12MBps, unlimited) — passing it through anyway'),'warning');
		if(ovh==='manual'&&ovhB&&!/^\d+$/.test(ovhB)){notify(_('Error: overhead must be a whole number of bytes'),'danger');return;}
		var en=chk('enabled');
		if(en&&(!bwUp||!bwDn))notify(_('Note: bandwidth not set — CAKE will run unlimited on that direction.'),'warning');

		var s0=ifSect(),sty=s0?s0.type:'interface',sec=s0?s0.name:'wan',sidx=s0?s0.idx:0;
		// null = remove the option, so clearing a field actually clears it
		var kv={
			disabled:en?'0':'1',
			bandwidth_up:bwUp||null,
			bandwidth_down:bwDn||null,
			overhead_type:ovh||null,
			mode:mode||null,
			ingress:chk('ingress')?'1':'0',
			egress:chk('egress')?'1':'0',
			nat:chk('nat')?'1':'0',
			host_isolate:chk('host_isolate')?'1':'0',
			autorate_ingress:chk('autorate')?'1':'0',
			ingress_options:iopts||null,
			egress_options:eopts||null,
			options:gopts||null,
			option:null
		};
		kv.overhead=(ovh==='manual'&&ovhB)?ovhB:null;
		var nmEl=$('q-name');
		if(nmEl){
			var nm=trim(nmEl.value);
			if(nm&&!/^[\w.@:-]+$/.test(nm)){notify(_('Error: name must be a device or interface name'),'danger');return;}
			kv.name=nm||null;
		}

		self.lock();
		ui.showModal(_('Saving'),[E('p',{},_('Saving settings and applying...'))]);
		return callUciRevert('qosify').then(function(){
			return Promise.all([fs.read(UCI_PATH),L.resolveDefault(fs.stat(UCI_PATH),null)]);
		}).then(function(r){
			var txt=r[0]||'',st=r[1];
			if(!trim(txt)&&st&&st.size>0)
				throw new Error(_('%s came back empty although it is %d bytes on disk — refusing to overwrite it').format(UCI_PATH,st.size));
			return fs.write(UCI_PATH,setOpts(txt,sty,sec,sidx,kv));
		}).then(function(){
			uci.unload('qosify');
			return uci.load('qosify');
		}).then(function(){
			return self.applyService();
		}).then(function(){
			return self.checkShapingForSave(_('Settings saved'));
		}).then(function(msg){
			ui.hideModal();
			notify(msg.text,msg.kind);
			self.lintAll().forEach(function(t){notify(t,'warning');});
			return self.refreshAll();
		}).catch(function(e){
			ui.hideModal();
			notify(_('Save failed: %s').format(e),'danger');
		}).finally(function(){self.unlock();});
	},

	confirmFresh:function(el,path){
		return L.resolveDefault(fs.stat(path),null).then(function(st){
			if(!fileMoved(el,st))return true;
			return confirmDialog(_('File changed on disk'),
				_('%s has changed since this editor was loaded. Saving now discards those changes.').format(path),
				_('Overwrite'),true);
		});
	},

	saveConfig:function(){
		var self=this;
		var ta=$('qos-config-ta');
		if(!ta)return;
		var data=ta.value.replace(/\r\n/g,'\n');
		if(data.length===0)return self.clearConfig(ta);
		if(!/(^|\n)config /.test(data)){
			notify(_('Error: No valid config stanzas found.'),'danger');return;
		}
		return self.confirmFresh(ta,UCI_PATH).then(function(go){
			if(!go)return null;
			return self.writeConfig(ta,data);
		});
	},

	// Truncating the file gets the file-changed check every other write gets, plus
	// one of its own: when gatherCtx()'s read fails the editor is left empty but
	// still carries the size and mtime it found on disk, so fileMoved() sees
	// nothing wrong and confirmFresh() would wave a wipe through. dataset.orig is
	// what separates "the user emptied it" from "it never loaded".
	clearConfig:function(ta){
		var self=this;
		return L.resolveDefault(fs.stat(UCI_PATH),null).then(function(st){
			if(st&&st.size>0&&!(ta.dataset.orig||'').length){
				notify(_('%s is %d bytes on disk but was never loaded into the editor — refusing to truncate it. Reload the page first.').format(UCI_PATH,st.size),'danger');
				return null;
			}
			return self.confirmFresh(ta,UCI_PATH).then(function(go){
				if(!go)return null;
				return confirmDialog(_('Clear configuration'),
					_('An empty %s stops all shaping. Continue?').format(UCI_PATH),_('Write empty file'),true);
			}).then(function(go){
				if(!go)return null;
				var stopped=false;
				self.lock();
				return callUciRevert('qosify').then(function(){
					return fs.write(UCI_PATH,'');
				}).then(function(){
					return callRcInit('qosify','stop');
				}).then(function(){
					return self.waitForStopped(4000);
				}).then(function(down){
					// cleanup deletes the root and clsact qdiscs and the ifb devices, so
					// it only runs once the daemon is confirmed down -- the same guard
					// svcAction() applies to a plain stop.
					stopped=down;
					if(!down){notify(_('qosify is still running — leaving the qdiscs alone'),'warning');return null;}
					return L.resolveDefault(fs.exec('/usr/share/qosify-luci/cleanup',[]),null);
				}).then(function(){
					uci.unload('qosify');
					return uci.load('qosify');
				}).then(function(){
					ta.dataset.orig='';
					notify(stopped?_('Config cleared, qosify stopped.'):_('Config cleared.'),'info');
					return self.refreshAll('cfg');
				}).catch(function(e){
					notify(_('Save failed: %s').format(e),'danger');
				}).finally(function(){self.unlock();});
			});
		});
	},

	writeConfig:function(ta,data){
		var self=this;
		self.lock();
		ui.showModal(_('Saving'),[E('p',{},_('Writing config and reloading qosify...'))]);
		return callUciRevert('qosify').then(function(){
			return fs.write(UCI_PATH,data);
		}).then(function(){
			uci.unload('qosify');
			return uci.load('qosify');
		}).then(function(){
			return self.applyService();
		}).then(function(){
			return self.checkShapingForSave(_('Config saved'));
		}).then(function(msg){
			ta.dataset.orig=data;
			ui.hideModal();
			notify(msg.text,msg.kind);
			self.lintAll().forEach(function(t){notify(t,'warning');});
			return self.refreshAll('cfg');
		}).catch(function(e){
			ui.hideModal();
			notify(_('Save failed: %s').format(e),'danger');
		}).finally(function(){self.unlock();});
	},

	waitForShaping:function(tries){
		var self=this;
		return L.resolveDefault(callQosifyStatus(),{}).then(function(st){
			if(statusActive(st)||tries<=1)return statusActive(st);
			return new Promise(function(res){setTimeout(res,700);}).then(function(){return self.waitForShaping(tries-1);});
		});
	},

	checkShapingForSave:function(prefix){
		var sn=ifSect(),w=(sn&&uci.get('qosify',sn.id))||{};
		if(uciBool(w.disabled,false))return Promise.resolve({text:_('%s, applied (QoS disabled).').format(prefix),kind:'info'});
		return this.waitForShaping(3).then(function(active){
			if(active)return {text:_('%s, applied.').format(prefix),kind:'info'};
			return {text:_('Warning: %s but qosify is not shaping traffic — check the Status tab.').format(prefix),kind:'warning'};
		});
	},


	saveRules:function(){
		var self=this;
		var ta=$('qos-rules-ta');
		if(!ta)return;
		var data=ta.value.replace(/\r\n/g,'\n');
		var verr=validateRules(data);
		if(verr){notify(_('Error: %s').format(verr),'danger');return;}
		var rwarn=ruleWarn(data,self.getClasses().map(function(c){return c.name;}));
		return self.confirmFresh(ta,self.rulesPath).then(function(go){
			if(!go)return null;
			return self.writeRules(ta,data,rwarn);
		});
	},

	writeRules:function(ta,data,rwarn){
		var self=this;
		self.lock();
		ui.showModal(_('Saving'),[E('p',{},_('Writing rules and reloading qosify...'))]);
		return fs.write(self.rulesPath,data).then(function(){
			return self.applyService();
		}).then(function(){
			return self.checkShapingForSave(_('Rules saved'));
		}).then(function(msg){
			ta.dataset.orig=data;
			ui.hideModal();
			notify(msg.text,msg.kind);
			rwarn.forEach(function(t){notify(t,'warning');});
			return self.refreshAll('rules');
		}).catch(function(e){
			ui.hideModal();
			notify(_('Save failed: %s').format(e),'danger');
		}).finally(function(){self.unlock();});
	},

	clearCfg:function(){
		return confirmDialog(_('Clear editor'),_('Empty the config editor? Nothing is written until you click Save & Apply.'),_('Clear')).then(function(go){
			var ta=$('qos-config-ta');
			if(go&&ta)ta.value='';
		});
	},
	clearRules:function(){
		return confirmDialog(_('Clear editor'),_('Empty the rules editor? Nothing is written until you click Save & Apply.'),_('Clear')).then(function(go){
			var ta=$('qos-rules-ta');
			if(go&&ta)ta.value='';
		});
	},

	uploadFiles:function(){
		var self=this;
		var u1=$('qos-up-cfg'),u2=$('qos-up-rules');
		var f1=u1&&u1.files[0],f2=u2&&u2.files[0];
		if(!f1&&!f2){notify(_('No files selected.'),'warning');return;}
		return confirmDialog(_('Overwrite config files'),
			_('The selected files replace the ones on the router and qosify is reloaded. Download a backup from this tab first if you need one.'),
			_('Upload and apply'),true).then(function(go){
			if(!go)return null;
			return self.doUpload(u1,u2,f1,f2);
		});
	},

	doUpload:function(u1,u2,f1,f2){
		var self=this;

		function readFile(f){
			return new Promise(function(res,rej){
				if(f.size<1)return rej(_('Empty file'));
				if(f.size>65536)return rej(_('File too large (max 64KB)'));
				var r=new FileReader();
				r.onload=function(){res(r.result);};
				r.onerror=function(){rej(_('Read error'));};
				r.readAsText(f);
			});
		}
		function validateUci(d){
			if(/\x00/.test(d))return _('Binary content rejected');
			if(!/(^|\n)config /.test(d))return _('No valid UCI config stanzas');
			return null;
		}
		self.lock();
		ui.showModal(_('Uploading'),[E('p',{},_('Reading and validating files...'))]);
		var names=[],errs=[],warns=[];
		// Sequential on purpose: the uploaded UCI config is written and reloaded
		// first, so ruleWarn() below sees the uploaded classes, not the old ones.
		var p=Promise.resolve();
		if(f1)p=p.then(function(){return readFile(f1).then(function(d){
			var e=validateUci(d);
			if(e){errs.push(_('Config: %s').format(e));return null;}
			return callUciRevert('qosify').then(function(){
				return fs.write(UCI_PATH,d);
			}).then(function(){
				names.push(UCI_PATH);
				uci.unload('qosify');
				return uci.load('qosify');
			});
		},function(e){errs.push(_('Config: %s').format(e));});});
		if(f2)p=p.then(function(){return readFile(f2).then(function(d){
			var e=validateRules(d);
			if(e){errs.push(_('Rules: %s').format(e));return null;}
			ruleWarn(d,self.getClasses().map(function(c){return c.name;})).forEach(function(t){warns.push(t);});
			return fs.write(RULES_PATH,d).then(function(){names.push('00-defaults.conf');});
		},function(e){errs.push(_('Rules: %s').format(e));});});

		return p.then(function(){
			if(names.length===0){
				ui.hideModal();
				notify(_('Upload error: %s').format(errs.join('; ')),'danger');
				return;
			}
			uci.unload('qosify');
			return uci.load('qosify').then(function(){
				return self.applyService();
			}).then(function(){
				ui.hideModal();
				var msg=_('%s uploaded, qosify reloaded.').format(names.join(' & '));
				if(errs.length)msg+=' '+_('Errors:')+' '+errs.join('; ');
				notify(msg,errs.length?'warning':'info');
				warns.forEach(function(t){notify(t,'warning');});
				if(u1)u1.value='';
				if(u2)u2.value='';
				return self.refreshAll();
			});
		}).catch(function(e){
			ui.hideModal();
			notify(_('Upload failed: %s').format(e),'danger');
		}).finally(function(){self.unlock();});
	},

	resetDefaults:function(){
		var self=this;
		return confirmDialog(_('Reset to defaults'),
			_('%s and %s are replaced with the templates shipped by the qosify package, and shaping is left disabled.').format(UCI_PATH,RULES_PATH),
			_('Reset'),true).then(function(go){
			if(!go)return null;
			return self.doReset();
		});
	},

	doReset:function(){
		var self=this;
		self.lock();
		ui.showModal(_('Resetting'),[E('p',{},_('Restoring defaults...'))]);
		return callUciRevert('qosify').then(function(){
			return Promise.all([
				fs.read('/usr/share/qosify-luci/qosify'),
				fs.read('/usr/share/qosify-luci/00-defaults.conf')
			]);
		}).then(function(t){
			return fs.write(UCI_PATH,t[0]).catch(function(e){
				throw new Error(_('%s was not written: %s').format(UCI_PATH,e));
			}).then(function(){
				return fs.write(RULES_PATH,t[1]).catch(function(e){
					throw new Error(_('%s was reset but %s was not written: %s').format(UCI_PATH,RULES_PATH,e));
				});
			});
		}).then(function(){
			uci.unload('qosify');
			return uci.load('qosify');
		}).then(function(){
			return self.applyService();
		}).then(function(){
			ui.hideModal();
			notify(_('Reset to defaults, applied.'),'info');
			return self.refreshAll();
		}).catch(function(e){
			ui.hideModal();
			notify(_('Reset failed: %s').format(e),'danger');
		}).finally(function(){self.unlock();});
	},

	// === Quick Add handlers ===

	qarPlaceholder:function(){
		var t=$('qar-type').value;
		var v=$('qar-val');
		var eg=function(x){return _('e.g. %s').format(x);};
		var ph={'tcp:':eg('4500'),'udp:':eg('4500'),'both:':eg('5060-5061'),
			'dns:':eg('*teams*'),'dnsr:':eg('zoom[0-9]+\\.us'),'dns_c:':eg('*cdn*'),'dns_cr:':eg('cdn[0-9]+'),
			'ipv4:':eg('1.1.1.1'),'ipv6:':eg('ff01::1')};
		v.placeholder=ph[t]||'';
	},

	qarAdd:function(){
		var ty=$('qar-type').value;
		var val=trim($('qar-val').value);
		var cls=$('qar-cls').value;
		var pr=$('qar-prio').checked;
		if(!val){notify(_('Enter a value.'),'danger');return;}
		if(!cls){notify(_('No classes defined. Add classes in the Config tab first.'),'danger');return;}
		var pt=(ty==='tcp:'||ty==='udp:'||ty==='both:');
		if(pt){
			var pp=val.split('-'),pn=[],j,n;
			if(pp.length>2){notify(_('Port must be a number or a range (4500, 5060-5061).'),'danger');return;}
			for(j=0;j<pp.length;j++){
				n=dscpNum(trim(pp[j]));
				if(n===null){notify(_('Port must be a number or a range (4500, 5060-5061).'),'danger');return;}
				if(n<1||n>65534){notify(_('Port must be 1-65534 (qosify rejects 65535).'),'danger');return;}
				pn.push(n);
			}
			if(pn.length===2&&pn[0]>pn[1]){notify(_('Range start must not exceed end.'),'danger');return;}
		}else if(/[\s#]/.test(val)){notify(_('No spaces or # allowed in patterns or addresses.'),'danger');return;}
		if(ty==='ipv4:'){
			var oc=val.split('.');
			if(oc.length!==4||oc.some(function(x){return !/^\d{1,3}$/.test(x)||+x>255;})){notify(_('Enter a single IPv4 address (qosify does not accept CIDR).'),'danger');return;}
		}
		// inet_pton(AF_INET6) also takes the IPv4-mapped form, so allow dots here
		if(ty==='ipv6:'&&(!/^[0-9a-fA-F:.]+$/.test(val)||val.indexOf(':')<0||val.length>45)){notify(_('Enter a single IPv6 address (qosify does not accept CIDR or a %zone suffix).'),'danger');return;}
		var pfx=pr?'+':'';
		var ta=$('qos-rules-ta');if(!ta)return;
		var lines=[];
		if(ty==='both:'){lines.push('tcp:'+val+'\t'+pfx+cls);lines.push('udp:'+val+'\t'+pfx+cls);}
		else if(ty==='ipv4:'||ty==='ipv6:')lines.push(val+'\t'+pfx+cls);
		else if(ty==='dnsr:')lines.push('dns:/'+val+'\t'+pfx+cls);
		else if(ty==='dns_cr:')lines.push('dns_c:/'+val+'\t'+pfx+cls);
		else lines.push(ty+val+'\t'+pfx+cls);
		var v=ta.value.replace(/\s+$/,'');
		ta.value=v+(v?'\n\n':'')+lines.join('\n')+'\n';
		$('qar-val').value='';
		$('qar-prio').checked=false;
		ta.scrollTop=ta.scrollHeight;
	},

	qacSwitch:function(){
		var ty=$('qac-type').value,p=QAC_PANEL[ty];
		['defaults','class','interface'].forEach(function(x){
			var el=$('qac-opts-'+x);
			if(el)el.style.display=(x===p)?'flex':'none';
		});
		$('qac-nm-w').style.display=(ty==='defaults')?'none':'';
	},

	qacAdd:function(){
		var ty=$('qac-type').value;
		var ta=$('qos-config-ta');if(!ta)return;
		var nm='',secs=cfgSections(ta.value);
		if(ty!=='defaults'){
			nm=trim($('qac-name').value);
			if(!nm){notify(_('Enter a section name.'),'danger');return;}
			if(!/^[a-zA-Z0-9_]+$/.test(nm)){notify(_('A section name may only contain letters, digits and underscores.'),'danger');return;}
		}
		if(ty==='defaults'&&secs.some(function(x){return x.type==='defaults';})){notify(_('A config defaults section already exists.'),'danger');return;}
		if(nm&&secs.some(function(x){return x.type===ty&&x.name===nm;})){notify(_('Section %s already exists.').format(nm),'danger');return;}
		var s='config '+ty+(nm?" '"+nm+"'":'');
		var div=$('qac-opts-'+QAC_PANEL[ty]);
		var els=div.querySelectorAll('[data-opt]');
		for(var i=0;i<els.length;i++){
			var v=els[i].value;if(!v)continue;
			v=qv(v);
			var opt=els[i].getAttribute('data-opt');
			var pre=els[i].getAttribute('data-pre')||'option';
			s+="\n\t"+pre+" "+opt+" '"+v+"'";
		}
		var cv=ta.value.replace(/\s+$/,'');
		ta.value=cv+(cv?'\n\n':'')+s+'\n';
		if(nm)$('qac-name').value='';
		for(i=0;i<els.length;i++){
			if(els[i].tagName==='SELECT')els[i].selectedIndex=0;
			else els[i].value=els[i].defaultValue||'';
		}
		ta.scrollTop=ta.scrollHeight;
	},

	// === Refreshers ===

	gatherCtx:function(withFiles){
		var self=this;
		return Promise.all([
			L.resolveDefault(callServiceList('qosify'),{}),
			L.resolveDefault(callRcList('qosify',true),{}),
			L.resolveDefault(callQosifyStatus(),{}),
			L.resolveDefault(fs.stat(UCI_PATH),null),
			L.resolveDefault(fs.stat(self.rulesPath),null),
			withFiles?fs.read(UCI_PATH).catch(function(){return null;}):null,
			withFiles?fs.read(self.rulesPath).catch(function(){return null;}):null
		]).then(function(d){
			var rc=d[1]&&d[1].qosify;
			var ctx={
				running:isRunning(d[0]),
				enabled:!!(rc&&rc.enabled),
				hasInit:!!rc,
				status:d[2]||{},
				active:statusActive(d[2]),
				shaped:statusCount(d[2]),
				cfgStat:d[3],
				rulesStat:d[4],
				cfgRaw:d[5],
				rulesText:d[6],
				qstatus:null
			};
			if(withFiles){
				self._rulesN=countRules(ctx.rulesText);
				self._cfgOk=(ctx.cfgRaw||'').length>10&&/(^|\n)config /.test(ctx.cfgRaw||'');
				if(ctx.cfgRaw===null)notify(_('%s could not be read — the editor is left empty and will not be saved over it.').format(UCI_PATH),'danger');
			}
			ctx.rulesN=self._rulesN;
			ctx.cfgOk=self._cfgOk;
			return ctx;
		});
	},

	// Poll path: five ubus calls, no shell forks, and the parts of the page that
	// hold user input or focus are patched in place rather than rebuilt.
	refreshOverview:function(){
		var self=this;
		self.lock();
		uci.unload('qosify');
		return uci.load('qosify').then(function(){
			return self.gatherCtx(false);
		}).then(function(ctx){
			self.updateSvcTable(ctx);
			self.fillSect('qos-cfg-sect',self.buildCfgSect(ctx));
			var bd=$('q-en-badge');
			if(bd){
				var sn=ifSect(),w=(sn&&uci.get('qosify',sn.id))||{};
				self.updateEnBadge(bd,ctx,w['.name']!=null&&!uciBool(w.disabled,false));
			}
			return ctx;
		}).finally(function(){self.unlock();});
	},

	refreshOverviewFull:function(){
		var self=this;
		return self.refreshOverview().then(function(ctx){
			self.fillSect('qos-svc-sect',self.buildSvcSect(ctx));
			self.fillSect('qos-ctl-sect',self.buildCtlSect(ctx));
			self.fillSect('qos-qs-sect',self.buildQsSect(ctx));
			return ctx;
		});
	},

	refreshStatus:function(){
		var self=this;
		if(self.currentTab!=='st'||self._st)return Promise.resolve();
		self._st=true;
		var ex=self.readonly?Promise.resolve(null):L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),null);
		return Promise.all([
			L.resolveDefault(callServiceList('qosify'),{}),
			L.resolveDefault(callQosifyStatus(),{})
		]).then(function(d){
			var ctx={running:isRunning(d[0]),status:d[1]||{},qstatus:self.readonly?'':null};
			var stb=$('qos-st-body');
			if(stb)self.fillStatus(stb,ctx);
			return ex.then(function(r){
				ctx.qstatus=self.readonly?'':((r&&r.stdout)||'');
				if(stb)self.fillStatus(stb,ctx);
			});
		}).finally(function(){self._st=false;});
	},

	// which = 'cfg' | 'rules' | undefined: the editor for the file just written is
	// reloaded, the other one keeps whatever the user has typed.
	refreshAll:function(which){
		var self=this;
		return self.refreshOverviewFull().then(function(){
			self.refreshClasses();
			return Promise.all([
				self.reloadEditor('qos-config-ta',UCI_PATH,which==='cfg'),
				self.reloadEditor('qos-rules-ta',self.rulesPath,which==='rules')
			]);
		});
	},

	reloadEditor:function(id,path,force){
		var el=$(id);
		if(!el)return Promise.resolve();
		return Promise.all([
			L.resolveDefault(fs.read(path),null),
			L.resolveDefault(fs.stat(path),null)
		]).then(function(r){
			var disk=r[0];
			if(disk==null)return;
			var dirty=(el.dataset.orig!=null&&el.value!==el.dataset.orig);
			if(dirty&&!force&&el.value!==disk){
				notify(_('%s changed on disk — your unsaved edits are still in the editor.').format(path),'warning');
				return;
			}
			el.value=disk;
			el.dataset.orig=disk;
			stampFile(el,r[1]);
		});
	}
});
JSEOF
	ck "$VIEW_DIR/main.js"
	cat > "$VIEW_DIR/qosify.css" << 'CSSEOF'
/* SPDX-License-Identifier: MIT */

.qos-badge {
	display: inline-block;
	padding: 2px 10px;
	border-radius: 3px;
	font-size: 12px;
	font-weight: bold;
}

.qos-green {
	background: var(--success-color-medium, #009a4c);
	color: var(--on-success-color, #fff);
}

.qos-red {
	background: var(--error-color-medium, #e8210d);
	color: var(--on-error-color, #fff);
}

.qos-amber {
	background: var(--warn-color-medium, #f0c629);
	color: var(--on-warn-color, #000);
}

.qos-ok {
	color: var(--success-color-medium, #009a4c);
}

.qos-err {
	color: var(--error-color-medium, #e8210d);
}

.qos-warn {
	color: var(--warn-color-low, #f2d24f);
}

.qos-muted {
	font-size: 11px;
	color: var(--text-color-medium, inherit);
	opacity: .75;
}

.qos-kv td {
	padding: 7px 12px;
	border-bottom: 1px solid var(--border-color-medium, rgba(128, 128, 128, .35));
}

.qos-kv td:first-child {
	font-weight: bold;
	opacity: .7;
	width: 200px;
}

.qos-kv tr:last-child td {
	border-bottom: none;
}

.qos-svc > * {
	display: inline-block;
	margin: 0 3px 3px 0;
}

/* Button row under a section table: the table's last row drops its own rule, so
   the border here continues the ruled look instead of doubling it. */
.qos-actions {
	margin-top: 10px;
	padding-top: 10px;
	border-top: 1px solid var(--border-color-medium, rgba(128, 128, 128, .35));
}

.qos-ref,
.qos-qa {
	margin: 0 0 10px;
	padding: 8px 10px;
	border: 1px solid var(--border-color-medium, rgba(128, 128, 128, .5));
	border-radius: 4px;
}

.qos-ref summary {
	cursor: pointer;
	font-weight: bold;
	font-size: 13px;
}

.qos-qa label {
	font-size: 11px;
	opacity: .7;
}

.qos-qa-row {
	display: flex;
	gap: 6px;
	align-items: center;
	margin: 6px 0 0;
	flex-wrap: wrap;
}

.qos-edit {
	width: 100%;
	font-family: var(--font-mono, monospace);
	font-size: 12px;
	border: 1px solid var(--border-color-medium, rgba(128, 128, 128, .5));
}

.qos-scroll {
	max-height: 24rem;
	overflow: auto;
	border: 1px solid rgba(128,128,128,.35);
	border-radius: 3px;
	padding: 0 .5em;
}

.qos-bars {
	margin: .5em 0 .5em;
}

.qos-bar-row {
	display: flex;
	align-items: center;
	gap: .75em;
	padding: .2em .25em;
	border-radius: 3px;
}

.qos-bar-row:hover {
	background: rgba(128,128,128,.08);
}

.qos-bar-label {
	flex: 0 0 10em;
	display: flex;
	align-items: center;
	overflow: hidden;
	text-overflow: ellipsis;
	white-space: nowrap;
	font-family: monospace;
}

.qos-swatch {
	flex: 0 0 auto;
	display: inline-block;
	width: .7em;
	height: .7em;
	border-radius: 2px;
	margin-right: .5em;
}

.qos-bar-track {
	flex: 1 1 auto;
	min-width: 4em;
	height: 1.15em;
	border-radius: 3px;
	background: rgba(128,128,128,.14);
	overflow: hidden;
}

.qos-bar-fill {
	height: 100%;
	border-radius: 3px;
	opacity: .85;
}

.qos-bar-val {
	flex: 0 0 11em;
	display: flex;
	justify-content: flex-end;
	gap: .6em;
	font-variant-numeric: tabular-nums;
	white-space: nowrap;
}

.qos-bar-num {
	font-family: monospace;
}

.qos-bar-pct {
	flex: 0 0 3.2em;
	text-align: right;
	opacity: .65;
}

.qos-bar-total {
	margin-top: .3em;
	padding-top: .45em;
	border-top: 1px solid rgba(128,128,128,.3);
	font-weight: bold;
}

.qos-bar-total:hover {
	background: none;
}

@media (max-width: 600px) {
	.qos-bar-label { flex-basis: 7em; }
	.qos-bar-val { flex-basis: 9em; }
}

.qos-pre {
	margin: 0;
	padding: 10px;
	overflow: auto;
	white-space: pre;
	font-family: var(--font-mono, monospace);
	font-size: 12px;
	background: var(--background-color-low, rgba(128, 128, 128, .12));
	color: inherit;
	border: 1px solid var(--border-color-medium, rgba(128, 128, 128, .5));
	border-radius: 3px;
}

/* The tc output is the only thing on the Status tab, so it takes the rest of the
   window: the viewport less the LuCI header, the tab bar and the summary table
   above it. calc() going negative on a short screen is caught by min-height, and
   the box is draggable for anything the estimate gets wrong. */
#qos-st-pre {
	height: calc(100vh - 310px);
	min-height: 320px;
	resize: vertical;
}

/* Each editor is the last thing on its tab, with only the action buttons under
   it, so it takes the rest of the window instead of a fixed 28 rows; the
   reference and Quick Add panels above it scroll off first. The rows attribute
   stays as the fallback if this sheet does not load. */
#qos-config-ta,
#qos-rules-ta {
	height: calc(100vh - 300px);
	min-height: 320px;
	resize: vertical;
}

.qos-item {
	margin: 4px 0;
	padding: 4px 8px;
	border: 1px solid var(--border-color-medium, rgba(128, 128, 128, .5));
	border-radius: 3px;
}
CSSEOF
	ck "$VIEW_DIR/qosify.css"
}

install_keepd() {
	echo "[*] Writing sysupgrade keep list..."
	mkdir -p /lib/upgrade/keep.d
	cat > /lib/upgrade/keep.d/luci-app-qosify << 'EOF'
/etc/config/qosify
/etc/qosify/00-defaults.conf
/root/qosify-luci.sh
/lib/upgrade/keep.d/luci-app-qosify
/usr/share/luci/menu.d/luci-app-qosify.json
/usr/share/rpcd/acl.d/luci-app-qosify.json
/usr/share/qosify-luci/qosify
/usr/share/qosify-luci/00-defaults.conf
/usr/share/qosify-luci/cleanup
/www/luci-static/resources/view/qosify/main.js
/www/luci-static/resources/view/qosify/qosify.css
EOF
	ck /lib/upgrade/keep.d/luci-app-qosify
}

save_installer() {
	SRC=$(readlink -f "$0" 2>/dev/null)
	[ -n "$SRC" ] && [ -f "$SRC" ] || return 0
	[ "$SRC" = "/root/qosify-luci.sh" ] && return 0
	# $0 is the shell, not this file, when the script is piped into sh -- only
	# copy something that really is this installer.
	grep -q "^VERSION=\"$VERSION\"" "$SRC" 2>/dev/null || return 0
	cp "$SRC" /root/qosify-luci.sh 2>/dev/null
	chmod +x /root/qosify-luci.sh 2>/dev/null
}

install_files() {
	echo "===== qosify LuCI file install v$VERSION (no package ops) ====="
	clean_legacy
	install_templates
	install_defaults
	install_menu
	install_acl
	install_view
	install_keepd
	save_installer
	logger -t qosify-luci "LuCI app files installed v$VERSION"
	echo "[OK] qosify LuCI app files written"
}

install_all() {
	echo "===== qosify LuCI Installer v$VERSION ====="
	clean_legacy
	install_deps
	install_templates
	install_defaults
	install_menu
	install_acl
	install_view
	install_keepd
	save_installer
	# service_running() in qosify.init waits for the ubus object and calls
	# reload_service() itself, so restart already pushes the config.
	/etc/init.d/qosify restart
	restart_luci_services
	logger -t qosify-luci "LuCI app installed v$VERSION"
	echo "[OK] qosify LuCI app installed"
	echo "[*] Refresh your browser (Ctrl+F5) to load the new menu."
}

uninstall_all() {
	echo "===== qosify LuCI Uninstaller ====="
	/etc/init.d/qosify stop 2>/dev/null
	/etc/init.d/qosify disable 2>/dev/null
	# qosify removes its own qdiscs on SIGTERM, so cleanup is only useful once the
	# daemon is gone: wait for its ubus object to disappear instead of guessing.
	i=0
	while ubus -t 1 list qosify >/dev/null 2>&1 && [ "$i" -lt 5 ]; do
		sleep 1
		i=$((i+1))
	done
	if [ -x "$TPL_DIR/cleanup" ]; then
		"$TPL_DIR/cleanup"
	else
		for ifb in /sys/class/net/ifb-*; do
			[ -e "$ifb" ] || continue
			ifb="${ifb##*/}"
			ip link set "$ifb" down 2>/dev/null
			ip link del "$ifb" 2>/dev/null
		done
	fi
	if command -v apk >/dev/null 2>&1; then apk del qosify 2>/dev/null
	elif command -v opkg >/dev/null 2>&1; then opkg remove qosify 2>/dev/null; fi
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	rmdir "$CONFIG_DIR" 2>/dev/null
	rm -rf "$VIEW_DIR" "$TPL_DIR"
	rm -f "$MENU_DIR/luci-app-qosify.json"
	rm -f "$ACL_DIR/luci-app-qosify.json"
	rm -f /lib/upgrade/keep.d/luci-app-qosify
	rm -f /root/qosify-luci.sh
	clean_legacy
	restart_luci_services
	logger -t qosify-luci "LuCI app and qosify fully removed"
	echo "[OK] qosify fully uninstalled"
	echo "[*] Go to the LuCI main page and refresh (Ctrl+F5) — the old /qosify URL no longer exists."
}

migrate_pkg() {
	echo "===== qosify LuCI migration to package v$VERSION ====="
	echo "[*] Removing script-installed app files (configs preserved)..."
	rm -f "$MENU_DIR/luci-app-qosify.json" "$ACL_DIR/luci-app-qosify.json"
	rm -rf "$VIEW_DIR" "$TPL_DIR"
	rm -f /lib/upgrade/keep.d/luci-app-qosify
	clean_legacy
	echo "[*] Installing luci-app-qosify..."
	if command -v apk >/dev/null 2>&1; then
		apk update >/dev/null 2>&1
		apk add luci-app-qosify
	elif command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1
		opkg install luci-app-qosify
	else
		echo "[ERROR] No supported package manager"
	fi
	if [ -f "$VIEW_DIR/main.js" ] && [ -f "$VIEW_DIR/qosify.css" ]; then
		restart_luci_services
		logger -t qosify-luci "migrated to luci-app-qosify package"
		echo "[OK] Migrated — the package owns the app files now"
		echo "[*] /root/qosify-luci.sh is no longer needed and can be deleted."
	else
		echo "[!] Package install failed — restoring the script install"
		install_files
		restart_luci_services
	fi
	echo "[*] Refresh your browser (Ctrl+F5)."
}

case "$1" in
	install) install_all ;;
	uninstall) uninstall_all ;;
	migrate) migrate_pkg ;;
	reset) install_templates; force_defaults; /etc/init.d/qosify restart 2>/dev/null ;;
	files) install_files ;;
	*) echo "Usage: $0 {install|uninstall|migrate|reset|files}"; exit 1 ;;
esac
