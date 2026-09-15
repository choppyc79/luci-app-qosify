#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (modern JS, ash-compatible)
VERSION="3.3.0-dev"
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

restart_luci_services() {
	rm -f /tmp/luci-indexcache /tmp/luci-indexcache.* 2>/dev/null
	rm -rf /tmp/luci-modulecache 2>/dev/null
	[ -f /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null
	sleep 1
	if [ -f /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart 2>/dev/null
	elif [ -f /etc/init.d/nginx ]; then /etc/init.d/nginx restart 2>/dev/null
	fi
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
	if ! command -v qosify >/dev/null 2>&1; then
		echo "[ERROR] qosify not found after install"; exit 1
	fi
	/etc/init.d/qosify enable 2>/dev/null
	/etc/init.d/qosify start 2>/dev/null
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
	cat > "$TPL_DIR/cleanup" << 'EOF'
#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Remove qosify qdiscs and ifb devices left behind by an unclean exit.
#
# A clean stop already does this itself: procd sends SIGTERM, qosify's main()
# calls qosify_iface_stop() and interface_clear_qdisc() removes the root qdisc,
# the bpf filters and the ifb device. This script only matters after a crash, a
# SIGKILL or a respawn loop, so it deliberately only touches the devices of
# enabled qosify sections and the ifb names qosify derives from them -- never a
# qdisc or ifb this package did not create.

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

	if [ -e "/sys/class/net/$dev" ]; then
		tc qdisc del dev "$dev" clsact 2>/dev/null
		tc qdisc del dev "$dev" root 2>/dev/null
	fi

	# An ifb outlives its parent, so this is not gated on $dev still existing.
	# That only helps a `config device`, whose name survives the netdev.
	ifb="$(ifb_name "$dev")" || return 0
	[ -e "/sys/class/net/$ifb" ] || return 0

	ip link set "$ifb" down 2>/dev/null
	ip link del "$ifb" 2>/dev/null
}

# add_interface() in qosify.init returns before reading anything else when
# disabled is set, so qosify never touched those devices.
section_enabled() {
	local disabled

	config_get_bool disabled "$1" disabled 0
	[ "$disabled" -eq 0 ]
}

# `config interface` names a netifd interface, not a device; qosify resolves it
# to .l3_device before touching tc, so resolve it the same way. netifd drops
# .l3_device when the interface goes down, so a vanished pppoe device leaves no
# name to derive the ifb from here. qosify clears that one itself: on the next
# up, interface_start() runs interface_clear_qdisc(), which deletes ifb-<dev>
# before cmd_add_ingress() creates it again.
clear_interface() {
	local cfg="$1"
	local name dev

	section_enabled "$cfg" || return 0
	config_get name "$cfg" name
	[ -n "$name" ] || return 0

	network_get_device dev "$name" || dev=""
	clear_dev "$dev"
}

# `config device` names a netdev directly.
clear_device() {
	local cfg="$1"
	local name

	section_enabled "$cfg" || return 0
	config_get name "$cfg" name
	clear_dev "$name"
}

config_load qosify
config_foreach clear_interface interface
config_foreach clear_device device

exit 0
EOF
	chmod +x "$TPL_DIR/cleanup"
}

install_defaults() {
	echo "[*] Seeding default configs (existing files preserved)..."
	mkdir -p "$CONFIG_DIR"
	[ -f "$DEFAULTS_FILE" ] || cp "$TPL_DIR/00-defaults.conf" "$DEFAULTS_FILE"
	[ -f "$UCI_CONFIG" ]    || cp "$TPL_DIR/qosify" "$UCI_CONFIG"
}

force_defaults() {
	echo "[*] Overwriting configs with qosify defaults..."
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	mkdir -p "$CONFIG_DIR"
	cp "$TPL_DIR/00-defaults.conf" "$DEFAULTS_FILE"
	cp "$TPL_DIR/qosify" "$UCI_CONFIG"
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
		"depends": {
			"acl": [ "luci-app-qosify" ],
			"fs": { "/usr/sbin/qosify": "executable" }
		}
	}
}
EOF
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
				"file": [ "read", "stat" ]
			},
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "read", "list" ],
				"/etc/qosify/00-defaults.conf": [ "read", "list" ],
				"/proc/uptime": [ "read" ],
				"/proc/[0-9]*/stat": [ "read" ],
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
				"/etc/qosify/00-defaults.conf": [ "write" ],
				"/usr/sbin/qosify-status": [ "exec" ],
				"/usr/share/qosify-luci/cleanup": [ "exec" ]
			}
		}
	}
}
EOF
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
var RULES_PATH='/etc/qosify/00-defaults.conf';
var DSCP=['CS0','CS1','CS2','CS3','CS4','CS5','CS6','CS7','AF11','AF12','AF13','AF21','AF22','AF23','AF31','AF32','AF33','AF41','AF42','AF43','EF','VA','NQB','LE','DF'];
var OVH=['none','manual','conservative','ethernet','docsis','pppoe-ptm','bridged-ptm','pppoe-vcmux','pppoe-llcsnap','pppoa-vcmux','pppoa-llc','bridged-vcmux','bridged-llcsnap','ipoa-vcmux','ipoa-llcsnap'];
var ENCAP=['atm','noatm','ptm'];
var MODES=['diffserv3','diffserv4','diffserv8','besteffort','precedence'];
var MAP_ROWS=200;
// Bar length is (row/largest row)^BAR_EXP: the largest row fills the track and a
// 0.1% row still shows at a tenth of it, so a bulk download does not hide the rest.
var BAR_EXP=1/3;
// codepoints[] in map.c.
var DSCP_VAL={CS0:0,DF:0,LE:1,CS1:8,AF11:10,AF12:12,AF13:14,CS2:16,AF21:18,AF22:20,
	AF23:22,CS3:24,AF31:26,AF32:28,AF33:30,CS4:32,AF41:34,AF42:36,AF43:38,CS5:40,
	VA:44,NQB:45,EF:46,CS6:48,CS7:56};
// Counters order: EF first, then codepoint descending. LE (1) and CS1 (8) are
// CAKE's Background tin, so they sort below best effort; -1 is anything
// __qosify_map_dscp_value() would reject and sorts below them.
var DSCP_BULK={1:1,8:1};
function dscpRank(v){return v<0?-1000:DSCP_BULK[v]?v-100:v===46?100:v;}
// Colour by sorted class name, so a class keeps its colour as the bars reorder.
var CN_COLORS=['#377eb8','#4daf4a','#ff7f00','#984ea3','#e41a1c','#17becf','#a65628','#f781bf'];
// qosify_map_stats() appends these two default slots; they are not config classes.
var CN_SKIP={tcp_default:1,udp_default:1};
// A class with no codepoint to place in a tin.
var CN_NONE='rgba(128,128,128,.45)';
// CAKE's DSCP to tin tables in sch_cake.c, already put through tin_order, so each
// digit is the column qosify-status prints that tin in. besteffort is one tin.
var TIN_MAP={besteffort:'0',
	precedence:'0000000011111111222222223333333344444444555555556666666677777777',
	diffserv8:'2012422212121212524242423232323262323232622262627222222272222222',
	diffserv4:'1011211101111111212121212121212131212121311131313111111131111111',
	diffserv3:'1011211101111111111111111111111111111111111121212111111121111111'};
// Colour per tin, same index as TIN_MAP and the qosify-status tin columns, so a
// class bar takes the colour of the tin its codepoint lands in. One colour per kind of traffic across modes: red
// bulk, blue best effort, yellow video, green voice; diffserv8 and precedence add
// their extra tins between them.
var TIN_COLORS={besteffort:['#377eb8'],
	precedence:['#377eb8','#e41a1c','#984ea3','#e6b422','#ff7f00','#4daf4a','#1b7837','#0f4d24'],
	diffserv8:['#5c5c5c','#e41a1c','#377eb8','#e6b422','#17becf','#984ea3','#4daf4a','#1b7837'],
	diffserv4:['#e41a1c','#377eb8','#e6b422','#4daf4a'],
	diffserv3:['#e41a1c','#377eb8','#4daf4a']};
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
// get_stats and dump are both in the qosify OpenWrt pins for 24.10 and master;
// the get_stats reply shape differs by build and is rendered as found.
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
function runPid(r){
	try{var i=r.qosify.instances;for(var k in i)if(i[k].running&&i[k].pid)return i[k].pid;}catch(e){}
	return 0;
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

function validateRules(d){
	if(/\x00/.test(d))return _('Binary content rejected');
	var lines=d.split('\n');
	for(var i=0;i<lines.length;i++){
		var l=lines[i],h=l.indexOf('#');
		if(h>=0)l=l.slice(0,h);
		l=trim(l);
		if(l.length>1023)return _('Line %d is longer than 1023 characters — the rule loader reads fixed-size lines and would split it').format(i+1);
	}
	return null;
}
function fmtSize(n){return n<1024?n+'B':(n/1024).toFixed(1)+'K';}
// Non-zero under a tenth of a percent says so rather than reading as 0.0%.
// The bare % strings are not wrapped in _(): msgfmt -c would reject a moved %.
function fmtShare(p){
	if(!p)return '0%';
	if(p<0.1)return '<0.1%';
	return _('%s%%').format(p<10?p.toFixed(1):Math.round(p));
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
function ruleWarn(txt,names){
	var w=[],bad=[],bare=[],lines=(txt||'').split('\n');
	for(var i=0;i<lines.length;i++){
		var l=lines[i],h=l.indexOf('#');
		if(h>=0)l=l.slice(0,h);
		l=trim(l);if(!l)continue;
		var f=l.split(/\s+/);
		if(f.length<2){if(bare.length<5)bare.push(String(i+1));continue;}
		var v=f[1].replace(/^\+/,'');
		if(names.indexOf(v)>=0||DSCP.indexOf(v)>=0)continue;
		var n=dscpNum(v);
		if(n!==null&&n<64)continue;
		if(bad.indexOf(v)<0)bad.push(v);
	}
	if(bare.length)w.push(_('No DSCP target on line %s — qosify skips single-field lines').format(bare.join(', ')));
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
// Stock LuCI markup only, so the page follows the active theme: .table rows as
// on Status > Overview, .label badges, .cbi-value form rows, .cbi-progressbar
// bars and plain pre/textarea. The app ships no stylesheet of its own.
function badge(kind,t){return E('span',{'class':kind?'label '+kind:'label'},t);}
function kvRow(k,v,id){return E('tr',{'class':'tr'},[E('td',{'class':'td left','width':'33%'},k),E('td',{'class':'td left','id':id||null},v)]);}
function emRow(t){return E('tr',{'class':'tr placeholder'},E('td',{'class':'td'},E('em',{},t)));}
function emP(t){return E('p',{},E('em',{},t));}
function descr(t){return E('div',{'class':'cbi-section-descr'},t);}
function valRow(lbl,el,help,attrs){
	var n=Array.isArray(el)?el[0]:el,a=attrs||{};
	a['class']='cbi-value';
	return E('div',a,[E('label',{'class':'cbi-value-title','for':(n&&n.id)||null},lbl),
		E('div',{'class':'cbi-value-field'},[].concat(el,help?(help.nodeType?help:E('div',{'class':'cbi-value-description'},help)):[]))]);
}
function noClassRow(){return emRow(_('No classes defined in %s').format(UCI_PATH));}

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

	load:function(){
		return Promise.all([
			uci.load('qosify').catch(function(){return null;}),
			this.gatherCtx(true)
		]);
	},

	render:function(d){
		var self=this,ctx=d[1];

		this.readonly=!L.hasViewPermission();

		if(d[0]===null)notify(_('The qosify UCI configuration could not be loaded — class and interface lists may be incomplete.'),'warning');

		var root=E('div',{'class':'cbi-map','id':'qos-app'});
		root.appendChild(E('h2',{},_('qosify')));
		root.appendChild(E('div',{'class':'cbi-map-descr'},_('Traffic shaping and DSCP classification via qosify')));

		var names={ov:'overview',cf:'config',ru:'rules',st:'status',cn:'counters',ad:'advanced'};
		var hash=(location.hash||'').slice(1),want='ov',k;
		for(k in names)if(names[k]===hash)want=k;

		var group=E('div',{});
		[['ov',_('Overview'),this.tabOverview(ctx)],
		 ['cf',_('Config'),this.tabConfig(ctx)],
		 ['ru',_('Classification Rules'),this.tabRules(ctx)],
		 ['st',_('Status'),this.tabStatus(ctx)],
		 ['cn',_('Counters'),this.tabCounters(ctx)],
		 ['ad',_('Advanced'),this.tabAdvanced(ctx)]].forEach(function(t){
			var pane=t[2];
			pane.setAttribute('data-tab',t[0]);
			pane.setAttribute('data-tab-title',t[1]);
			if(t[0]===want)pane.setAttribute('data-tab-active','true');
			pane.addEventListener('cbi-tab-active',function(){
				self.currentTab=t[0];
				try{history.replaceState(null,'','#'+names[t[0]]);}catch(e){}
				// The Status tab costs a fork per active interface, so it is fetched
				// when it is opened rather than on every page load; initTabGroup fires
				// this from a requestAnimationFrame, so the pane is in the DOM.
				if(t[0]==='st')self.refreshStatus();
				if(t[0]==='cn')self.refreshCounters();
			});
			group.appendChild(pane);
		});
		root.appendChild(group);
		ui.tabs.initTabGroup(group.childNodes);
		this.currentTab=want;

		if(this.readonly){
			this.applyReadonly(root);
			notify(_('You have read-only access to this page, so editing and service control are disabled.'),'warning');
		}

		this.installPollers();
		return root;
	},

	// All three tick at LuCI's poll interval (luci.main.pollinterval, 5 s unless
	// set) and pause with its header toggle, each only while its tab is open:
	// Overview is six ubus calls (eight on the first tick after qosify starts) and
	// no forks, Status forks qosify-status, which runs tc twice per active
	// interface, and Counters is three (service.list, get_stats, then dump)
	// plus that same qosify-status fork while qosify runs.
	// Poll.step() holds the next tick until the promise this returns settles, and
	// each refresher drops an overlapping call, so a slow tick skips rather than
	// stacks up.
	installPollers:function(){
		var self=this;
		poll.add(function(){if(self.currentTab!=='ov'||self._n)return;return self.refreshOverview();});
		poll.add(function(){if(self.currentTab!=='st'||self._n)return;return self.refreshStatus();});
		poll.add(function(){if(self.currentTab!=='cn'||self._n)return;return self.refreshCounters();});
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
			_('Common shaping settings — written straight to %s, section %s.').format(UCI_PATH,sn?'config '+sn.type+(sn.name?" '"+sn.name+"'":' '+_('(unnamed section)')):"config interface 'wan' (will be created)")));
		var node=E('div',{'class':'cbi-section-node'});
		function row(lbl,el,help){node.appendChild(valRow(lbl,el,help));}
		function chk(name,val){return E('input',{'type':'checkbox','class':'cbi-input-checkbox','id':'q-'+name,'data-q':name,'checked':val?'checked':null});}
		function txt(name,val,ph){return E('input',{'type':'text','class':'cbi-input-text','id':'q-'+name,'data-q':name,'value':val||'','placeholder':ph||''});}
		function sel(name,val,opts,def){
			val=qv(val);
			var s=E('select',{'class':'cbi-input-select','id':'q-'+name,'data-q':name});
			var sv=val||def,known=false;
			opts.forEach(function(o){var a={'value':o};if(sv===o){a.selected='selected';known=true;}s.appendChild(E('option',a,o));});
			if(val&&!known)s.appendChild(E('option',{'value':val,'selected':'selected'},_('%s (current)').format(val)));
			return s;
		}

		var enCb=chk('enabled',enChecked);
		var enBadge=E('span',{'class':'label','id':'q-en-badge'});
		this.updateEnBadge(enBadge,ctx,enChecked);
		row(_('QoS Enabled'),[enCb,' ',enBadge]);
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
			txt('name',sn?(isDev?'':sn.name):'wan',_('e.g. %s').format(isDev?'eth0':'wan')),
			_('required — qosify skips sections with no name'));
		row(_('Bandwidth Up'),txt('bw_up',w.bandwidth_up,_('e.g. %s').format('100mbit')));
		row(_('Bandwidth Down'),txt('bw_down',w.bandwidth_down,_('e.g. %s').format('100mbit')));
		row(_('Overhead Type'),sel('overhead',w.overhead_type,OVH,'none'));
		row(_('Overhead Bytes'),txt('overhead_b',w.overhead,_('manual only')),_('used only when Overhead Type is manual'));
		row(_('Queue Mode'),sel('mode',w.mode,MODES,'diffserv4'));
		row(_('Ingress'),chk('ingress',numBool(w.ingress,true)));
		row(_('Egress'),chk('egress',numBool(w.egress,true)));
		// CAKE is only given nat/nonat when host_isolate is on; otherwise it gets
		// flow isolation and nat has no effect at all.
		var natCb=chk('nat',numBool(w.nat,!isDev));
		var hiCb=chk('host_isolate',numBool(w.host_isolate,true));
		var natNote=E('div',{'class':'cbi-value-description'},
			_('qosify only passes this to CAKE together with Host Isolate — add nat to Options to force it'));
		function syncNat(){
			natNote.style.display=hiCb.checked?'none':'';
		}
		hiCb.addEventListener('change',syncNat);
		syncNat();
		row(_('NAT'),natCb,natNote);
		row(_('Host Isolate'),hiCb);
		row(_('Autorate Ingress'),chk('autorate',numBool(w.autorate_ingress,false)));
		row(_('Ingress Options'),txt('ing_opts',w.ingress_options,_('e.g. %s').format('triple-isolate memlimit 32mb')));
		row(_('Egress Options'),txt('egr_opts',w.egress_options,_('e.g. %s').format('triple-isolate memlimit 32mb wash')));
		row(_('Options'),txt('opts',w.options,_('e.g. %s').format('overhead 44 mpu 84')));
		nodes.push(node);
		nodes.push(E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveQuick();}},_('Save & Apply'))));
		return nodes;
	},

	buildCtlSect:function(ctx){
		var self=this;
		var nodes=[E('legend',{},_('Service Controls'))];
		var svcCt=E('div',{'id':'qos-svc-btns'});
		svcCt.appendChild(E('button',{
			'class':'cbi-button '+(ctx.enabled?'cbi-button-positive':'cbi-button-negative'),
			'id':'qos-btn-auto',
			'title':ctx.enabled?_('Click to disable autostart'):_('Click to enable autostart'),
			'click':function(){return self.svcAction(ctx.enabled?'disable':'enable');}
		},ctx.enabled?_('Enabled'):_('Disabled')));
		var btnCls={start:'cbi-button-apply',stop:'cbi-button-negative',restart:'cbi-button-action',reload:'cbi-button-reload'};
		['start','stop','restart','reload'].forEach(function(a){
			svcCt.appendChild(document.createTextNode(' '));
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
		var k='',t=_('Disabled');
		if(ctx.active){k='success';t=_('Active');}
		else if(ctx.running&&enChecked){k='warning';t=_('Enabled — Not Shaping (check config)');}
		else if(enChecked){k='warning';t=_('Enabled — Not Running');}
		el.className=k?'label '+k:'label';
		dom.content(el,t);
	},

	svcNodes:function(ctx){
		return {
			init:ctx.hasInit?badge('success',_('Available')):badge('warning',_('Missing')),
			auto:badge(ctx.enabled?'success':'',ctx.enabled?_('Enabled'):_('Disabled')),
			run:ctx.running&&ctx.active?badge('success',_('Running & Shaping'))
				:ctx.running?badge('warning',_('Running — Not Shaping')):badge('',_('Not Running')),
			shaped:ctx.shaped?N_(ctx.shaped,'%d interface','%d interfaces').format(ctx.shaped):E('em',{},_('none')),
			up:ctx.uptime!=null?'%t'.format(Math.floor(ctx.uptime)):''
		};
	},

	renderSvcTable:function(ctx){
		var n=this.svcNodes(ctx),up=kvRow(_('Uptime'),n.up,'qos-svc-up');
		up.id='qos-svc-up-row';
		if(ctx.uptime==null)up.style.display='none';
		return E('table',{'class':'table','id':'qos-svc-tbl'},[
			kvRow(_('Init Script'),n.init,'qos-svc-init'),
			kvRow(_('Autostart'),n.auto,'qos-svc-auto'),
			kvRow(_('Running'),n.run,'qos-svc-run'),
			up,
			kvRow(_('Shaping'),n.shaped,'qos-svc-shaped')
		]);
	},

	updateSvcTable:function(ctx){
		var n=this.svcNodes(ctx),map={init:'qos-svc-init',auto:'qos-svc-auto',run:'qos-svc-run',shaped:'qos-svc-shaped',up:'qos-svc-up'},k,el;
		for(k in map){el=$(map[k]);if(el)dom.content(el,n[k]);}
		el=$('qos-svc-up-row');
		if(el)el.style.display=ctx.uptime!=null?'':'none';
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
		var tbl=E('table',{'class':'table'});
		function fileRow(path,exists,ok,sz,mod,extra){
			var st=ok?badge('success',_('Valid')):badge('warning',exists?_('Found (empty or invalid)'):_('Missing'));
			tbl.appendChild(kvRow(path,exists?[st,' ('+(extra||'')+fmtSize(sz)+', '+mod+')']:st));
		}
		fileRow(UCI_PATH,!!ctx.cfgStat,cfgOk,ctx.cfgStat?ctx.cfgStat.size:0,ctx.cfgStat?fmtMtime(ctx.cfgStat.mtime):'');
		fileRow(RULES_PATH,!!ctx.rulesStat,rulesOk,ctx.rulesStat?ctx.rulesStat.size:0,ctx.rulesStat?fmtMtime(ctx.rulesStat.mtime):'',N_(rulesN,'%d rule','%d rules').format(rulesN)+', ');
		return tbl;
	},

	tabConfig:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-cf'});
		var classes=this.getClasses();
		var dscpChoices=classes.map(function(c){return c.name;}).concat(DSCP);
		var qacType=E('select',{'class':'cbi-input-select','id':'qac-type','change':function(){self.qacSwitch();}});
		SECT.forEach(function(o){qacType.appendChild(E('option',{'value':o[0]},o[1]));});

		// config defaults — add_defaults() in qosify.init
		var qadDef=E('div',{'id':'qac-opts-defaults'});
		this.qaInput(qadDef,'defaults','list','/etc/qosify/*.conf');
		this.qaNum(qadDef,'timeout','300');
		this.qaSelect(qadDef,'dscp_default_tcp',dscpChoices);
		this.qaSelect(qadDef,'dscp_default_udp',dscpChoices);
		this.qaSelect(qadDef,'dscp_icmp',dscpChoices);
		this.qaSelect(qadDef,'dscp_prio',dscpChoices);
		this.qaSelect(qadDef,'dscp_bulk',dscpChoices);
		this.qaNum(qadDef,'prio_max_avg_pkt_len','500');
		this.qaNum(qadDef,'bulk_trigger_pps','100');
		this.qaNum(qadDef,'bulk_trigger_timeout','5');

		// config class / config alias — add_class()
		var qadCls=E('div',{'id':'qac-opts-class','style':'display:none'});
		this.qaSelect(qadCls,'value',DSCP);
		this.qaSelect(qadCls,'ingress',DSCP);
		this.qaSelect(qadCls,'egress',DSCP);
		this.qaSelect(qadCls,'dscp_prio',dscpChoices);
		this.qaSelect(qadCls,'dscp_bulk',dscpChoices);
		this.qaNum(qadCls,'prio_max_avg_pkt_len','500');
		this.qaNum(qadCls,'bulk_trigger_pps','100');
		this.qaNum(qadCls,'bulk_trigger_timeout','5');

		// config interface / config device — add_interface()
		var qadIf=E('div',{'id':'qac-opts-interface','style':'display:none'});
		this.qaInput(qadIf,'name','option','wan');
		this.qaSelect(qadIf,'disabled',['0','1']);
		this.qaInput(qadIf,'bandwidth_up','option','100mbit');
		this.qaInput(qadIf,'bandwidth_down','option','100mbit');
		this.qaInput(qadIf,'bandwidth','option','100mbit');
		this.qaSelect(qadIf,'mode',MODES);
		this.qaSelect(qadIf,'ingress',['0','1']);
		this.qaSelect(qadIf,'egress',['0','1']);
		this.qaSelect(qadIf,'nat',['0','1']);
		this.qaSelect(qadIf,'host_isolate',['0','1']);
		this.qaSelect(qadIf,'autorate_ingress',['0','1']);
		this.qaSelect(qadIf,'overhead_type',OVH);
		this.qaNum(qadIf,'overhead','44');
		this.qaSelect(qadIf,'overhead_encap',ENCAP);
		this.qaNum(qadIf,'overhead_mpu','84');
		this.qaSelect(qadIf,'overhead_vlan',['0','1','2']);
		this.qaInput(qadIf,'ingress_options','option','triple-isolate');
		this.qaInput(qadIf,'egress_options','option','triple-isolate wash');
		this.qaInput(qadIf,'options','option','overhead 44 mpu 84');

		// Reference — option lists read back out of the panels above, so the
		// reference and the Quick Add form can never disagree.
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Quick Add Config')),
			E('details',{},[
				E('summary',{},_('Config Reference')),
				this.refTable({defaults:qadDef,'class':qadCls,'interface':qadIf}),
				E('table',{'class':'table'},[
					E('tbody',{'id':'qos-cfg-def'},this.defsNodes()),
					E('tbody',{'id':'qos-cfg-cls'},classes.map(function(c){return self.clsBoxNode(c);}))
				]),
				descr(_('DSCP codepoints: CS0–CS7, AF11–AF43, EF, VA, NQB, LE, DF. Any dscp_* value may also name a class. Prefix with + to override only when the DSCP field is zero.')),
				descr(_('Defaults qosify applies when a key is absent — interface: mode diffserv4, ingress 1, egress 1, nat 1, host_isolate 1, autorate_ingress 0. device: identical except nat 0. defaults: timeout 3600, dscp_default_tcp/udp CS0, dscp_prio/dscp_bulk/dscp_icmp unset, bulk_trigger_pps/bulk_trigger_timeout/prio_max_avg_pkt_len 0 (disabled).'))
			]),
			E('div',{'class':'cbi-section-node'},[
				valRow(_('Section type'),qacType),
				valRow(_('Section name'),E('input',{'type':'text','class':'cbi-input-text','id':'qac-name','placeholder':_('section name')}),null,{'id':'qac-nm-w','style':'display:none'}),
				qadDef,qadCls,qadIf,
				valRow('',E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qacAdd();}},_('Add')))
			])
		]));

		var ta=E('textarea',{'id':'qos-config-ta','class':'cbi-input-textarea','style':'width:100%','rows':28},ctx.cfgRaw||'');
		ta.dataset.orig=ctx.cfgRaw||'';
		stampFile(ta,ctx.cfgStat);
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Config')),
			descr([_('UCI configuration — classes, interfaces, defaults.')+' ',E('code',{},UCI_PATH)]),
			ta,
			E('div',{'class':'cbi-page-actions'},[
				E('button',{'class':'cbi-button cbi-button-reset','click':function(){return self.clearCfg();}},_('Clear')),' ',
				E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveConfig();}},_('Save & Apply'))
			])
		]));
		return section;
	},

	clsBoxNode:function(c){return kvRow(clsLabel(c),clsDesc(c));},

	refTable:function(panels){
		var note={
			'class':_('Section name is the class name that rules and dscp_* values refer to. value sets ingress and egress together.'),
			alias:_('Same options as class — gives an existing class a second name.'),
			'interface':_('name is the netifd interface. bandwidth applies only where bandwidth_up/bandwidth_down are unset. overhead and overhead_encap apply only when overhead_type is manual.'),
			device:_('Same options as interface, but name is a netdev. nat defaults to 0 here and to 1 for interfaces.')
		};
		var tbl=E('table',{'class':'table'});
		SECT.forEach(function(o){
			var div=panels[QAC_PANEL[o[0]]],els=div?div.querySelectorAll('[data-opt]'):[],out=[];
			for(var i=0;i<els.length;i++)
				out.push((els[i].getAttribute('data-pre')==='list'?'list ':'option ')+els[i].getAttribute('data-opt'));
			tbl.appendChild(kvRow(E('code',{},o[1]),[out.join(', '),
				note[o[0]]?E('div',{'class':'cbi-value-description'},note[o[0]]):'']));
		});
		return tbl;
	},

	qaId:function(parent,opt){return (parent.id||'qac')+'-'+opt;},
	qaInput:function(parent,opt,pre,ph){
		parent.appendChild(valRow(opt,E('input',{
			'id':this.qaId(parent,opt),'class':'cbi-input-text','data-opt':opt,'data-pre':pre,'type':'text',
			'value':pre==='list'?ph:'','placeholder':pre==='list'?'':ph
		})));
	},
	qaSelect:function(parent,opt,opts){
		var s=E('select',{'id':this.qaId(parent,opt),'class':'cbi-input-select','data-opt':opt},E('option',{'value':''},'--'));
		opts.forEach(function(o){s.appendChild(E('option',{'value':o},o));});
		parent.appendChild(valRow(opt,s));
	},
	qaNum:function(parent,opt,ph){
		parent.appendChild(valRow(opt,E('input',{'id':this.qaId(parent,opt),'class':'cbi-input-text','data-opt':opt,'type':'number','min':'0','placeholder':ph})));
	},

	lock:function(){this._n=(this._n||0)+1;},
	unlock:function(){this._n=Math.max(0,(this._n||0)-1);},

	defsNodes:function(){
		var d=null;
		uci.sections('qosify','defaults',function(s){if(!d)d=s;});
		if(!d)return [emRow(_('No config defaults section defined'))];
		return [kvRow(E('code',{},'config defaults'),['timeout','dscp_default_tcp','dscp_default_udp','dscp_icmp','dscp_prio','dscp_bulk',
			'prio_max_avg_pkt_len','bulk_trigger_pps','bulk_trigger_timeout'].filter(function(k){return d[k];})
			.map(function(k){return k+': '+d[k];}).join(', '))];
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
					ref.appendChild(kvRow(clsLabel(c),clsDesc(c)));
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
		var classes=this.getClasses();
		var qarType=E('select',{'class':'cbi-input-select','id':'qar-type','change':function(){self.qarPlaceholder();}});
		[['tcp:',_('tcp port')],['udp:',_('udp port')],['both:',_('tcp+udp port')],['dns:',_('dns pattern')],['dnsr:',_('dns regex')],['dns_c:',_('dns_c pattern')],['dns_cr:',_('dns_c regex')],['ipv4:',_('IPv4 address')],['ipv6:',_('IPv6 address')]].forEach(function(o){
			qarType.appendChild(E('option',{'value':o[0]},o[1]));
		});
		var qarCls=E('select',{'class':'cbi-input-select','id':'qar-cls'});
		classes.forEach(function(c){qarCls.appendChild(E('option',{'value':c.name},c.name));});
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Quick Add Rule')),
			E('details',{},[
				E('summary',{},_('Available Classes')),
				E('table',{'class':'table'},E('tbody',{'id':'qos-cls-ref'},classes.length
					?classes.map(function(c){return kvRow(clsLabel(c),clsDesc(c));}):noClassRow())),
				descr(_('Prefix with + to override only when the DSCP field is zero. Ports: tcp:443, udp:3074, ranges: tcp:5060-5061 (1-65534). DNS: dns:*teams*, regex: dns:/zoom[0-9]+, CNAME-only: dns_c:. IP: 1.1.1.1, ff01::1'))
			]),
			E('div',{'class':'cbi-section-node'},[
				valRow(_('Match type'),qarType),
				valRow(_('Match'),E('input',{'type':'text','class':'cbi-input-text','id':'qar-val','placeholder':_('e.g. %s').format('4500')})),
				valRow(_('Class'),qarCls),
				valRow(_('only if unset (+)'),E('input',{'type':'checkbox','class':'cbi-input-checkbox','id':'qar-prio'})),
				valRow('',E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qarAdd();}},_('Add')))
			])
		]));

		var ta=E('textarea',{'id':'qos-rules-ta','class':'cbi-input-textarea','style':'width:100%','rows':28},ctx.rulesText||'');
		ta.dataset.orig=ctx.rulesText||'';
		stampFile(ta,ctx.rulesStat);
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Classification Rules')),
			descr([_('DSCP mapping rules loaded by qosify on startup.')+' ',E('code',{},RULES_PATH)]),
			ta,
			E('div',{'class':'cbi-page-actions'},[
				E('button',{'class':'cbi-button cbi-button-reset','click':function(){return self.clearRules();}},_('Clear')),' ',
				E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveRules();}},_('Save & Apply'))
			])
		]));
		return section;
	},

	tabAdvanced:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-ad'});

		// Backup
		var fb=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Backup Current Files')),
			E('div',{'class':'cbi-section-descr'},_('Download current config files before making changes.'))
		]);
		fb.appendChild(this.dlRow('/etc/config/qosify','qosify'));
		fb.appendChild(this.dlRow('/etc/qosify/00-defaults.conf','00-defaults.conf'));
		section.appendChild(fb);

		// Upload
		var fu=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Upload Config Files')),
			E('div',{'class':'cbi-section-descr'},_('Select files and click Save & Apply to overwrite and restart qosify.'))
		]);
		var u1=E('input',{'type':'file','id':'qos-up-cfg'});
		var u2=E('input',{'type':'file','id':'qos-up-rules'});
		fu.appendChild(E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},'/etc/config/qosify'),
			E('div',{'class':'cbi-value-field'},u1)
		]));
		fu.appendChild(E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},'/etc/qosify/00-defaults.conf'),
			E('div',{'class':'cbi-value-field'},u2)
		]));
		fu.appendChild(E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.uploadFiles();}},_('Save & Apply'))
		));
		section.appendChild(fu);

		// Reset
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Reset to qosify Defaults')),
			E('div',{'class':'cbi-section-descr'},_('Replaces both config files with qosify defaults, qosify will be disabled.')),
			E('div',{'class':'cbi-page-actions'},
				E('button',{'class':'cbi-button cbi-button-negative','click':function(){return self.resetDefaults();}},_('Reset to Defaults')))
		]));

		return section;
	},

	dlRow:function(path,fn){
		return E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},path),
			E('div',{'class':'cbi-value-field'},
				E('button',{'class':'cbi-button cbi-button-action','data-ro-ok':'1','click':function(){
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
				}},_('Download')))
		]);
	},

	tabStatus:function(ctx){
		var section=E('div',{'id':'qos-st'});
		var fs1=E('fieldset',{'class':'cbi-section'},E('legend',{},_('qosify-status')));
		var body=E('div',{'id':'qos-st-body'},[
			E('div',{'id':'qos-st-sum'}),
			E('pre',{'id':'qos-st-pre','style':'display:none'}),
			E('div',{'id':'qos-st-msg'})
		]);
		this.fillStatus(body,ctx);
		fs1.appendChild(body);
		section.appendChild(fs1);
		return section;
	},

	// ubus call qosify get_stats. Master adds ebpf_map_entries, last_reload_time,
	// dns_cache and classes/dscp/dns tables; 24.10 (1501e09) returns
	// qosify_map_stats() at the top level, one table per class, packets only.
	// Only what the reply contains is rendered.
	isCounter:function(v){return !!v&&typeof v==='object'&&(v.packets!=null||v.bytes!=null);},
	// qosify_map_get_ebpf_entry_count() sums the IPv4 and IPv6 address maps only.
	infoNodes:function(st){
		var rows=[];
		if(st.ebpf_map_entries!=null)rows.push([_('eBPF IP map entries'),String(st.ebpf_map_entries)]);
		if(st.last_reload_time)rows.push([_('Last reload'),fmtMtime(st.last_reload_time)]);
		if(st.dns_cache)rows.push([_('DNS cache'),_('%d entries, %d hits, %d misses')
			.format(st.dns_cache.size||0,st.dns_cache.hits||0,st.dns_cache.misses||0)]);
		if(!rows.length)return emP(_('The running qosify reports no daemon-level figures.'));
		return E('table',{'class':'table'},rows.map(function(r){return kvRow(r[0],r[1]);}));
	},

	// dump lists port, address and DNS entries, but pattern_stats is the only
	// per-entry counter the datapath keeps, so only DNS patterns are listed; the
	// rest is class totals. A raw DSCP as a number, -1 for anything
	// __qosify_map_dscp_value() would reject (strtoul base 0, below 64).
	dscpVal:function(v){
		var s=String(v==null?'':v).replace(/^\+/,'').toUpperCase(),n;
		if(DSCP_VAL[s]!=null)return DSCP_VAL[s];
		n=dscpNum(s);
		return n===null||n>=64?-1:n;
	},
	// What each class marks with; ingress and egress already fall back to value.
	dscpMarks:function(){
		var m={};
		this.getClasses().forEach(function(c){
			m[c.name]=(c.ingress===c.egress)?c.ingress:c.ingress+'/'+c.egress;
		});
		return m;
	},
	dscpRanks:function(){
		var m={},self=this;
		this.getClasses().forEach(function(c){m[c.name]=dscpRank(self.dscpVal(c.egress||c.ingress));});
		return m;
	},
	// DNS rows ordered by dscpRank(). Entries added over ubus (user, no file) carry
	// a timeout and follow the file entries, so the MAP_ROWS cut falls on them.
	mapRows:function(entries){
		var rows=[],dyn=[],cls=this.dscpRanks(),self=this,i,e,a,rk;
		for(i=0;i<entries.length;i++){
			e=entries[i]||{};
			if(e.type!=='dns')continue;
			a=(e.user&&!e.file)?dyn:rows;
			rk=String(e.dscp==null?'':e.dscp).replace(/^\+/,'');
			a.push({type:e.type,addr:e.addr,dscp:e.dscp,file:!!e.file,user:!!e.user,
				timeout:e.timeout,ix:a.length,
				rk:cls[rk]!=null?cls[rk]:dscpRank(self.dscpVal(rk))});
		}
		function byDscp(x,y){return y.rk-x.rk||x.ix-y.ix;}
		return rows.sort(byDscp).concat(dyn.sort(byDscp));
	},
	// dns is the get_stats dns table keyed by pattern; a pattern with no traffic is
	// omitted from it, so it is zero once the table exists. hasDns false means the
	// daemon has no such table (24.10) and the column goes; null is not asked yet.
	// hits counts every matching lookup, packets the pattern_id in the address map
	// entry, which __qosify_map_set_entry() only writes when the DSCP changes.
	// The signature covers the listing's shape only, not the map entry total:
	// qosify adds and expires address entries for DNS results all the time, and
	// with the total in it the table was rebuilt on nearly every tick. While it
	// holds, the traffic and timeout cells and the footer are set in place.
	mapSig:function(rows,hasDns){
		var out=[rows.length,hasDns].join('|'),i,r;
		for(i=0;i<rows.length&&i<MAP_ROWS;i++){
			r=rows[i];
			out+='\n'+[r.addr,r.dscp,r.file,r.user,r.timeout!=null].join(',');
		}
		return out;
	},

	// qosify_map_dump() emits timeout for user entries only; no column without one.
	mapNodes:function(rows,hasDns){
		var tcol=hasDns!==false,cells=this._mapCells=[];
		var wcol=rows.some(function(r){return r.timeout!=null;});
		var hdr=[E('th',{'class':'th'},_('Pattern')),E('th',{'class':'th'},_('DSCP')),E('th',{'class':'th'},_('Source'))];
		if(tcol)hdr.push(E('th',{'class':'th'},_('Traffic')));
		if(wcol)hdr.push(E('th',{'class':'th'},_('Timeout')));
		var tbl=E('table',{'class':'table'},E('tr',{'class':'tr table-titles'},hdr));
		rows.slice(0,MAP_ROWS).forEach(function(r){
			var src=[],c={t:tcol?E('td',{'class':'td','style':'white-space:nowrap'}):null,w:wcol?E('td',{'class':'td'}):null};
			if(r.file)src.push(_('file'));
			if(r.user)src.push(_('dynamic'));
			cells.push(c);
			tbl.appendChild(E('tr',{'class':'tr'},[E('td',{'class':'td'},String(r.addr!=null?r.addr:'-')),
				E('td',{'class':'td'},r.dscp||'-'),E('td',{'class':'td'},src.join(', ')||'-'),c.t||'',c.w||'']));
		});
		this._mapNote=descr('');
		return [tbl,tcol?'':descr(_('The running qosify reports no per-entry counters — its get_stats has no dns table.')),this._mapNote];
	},

	mapValues:function(rows,total,dns){
		var n=this._mapNote,t;
		(this._mapCells||[]).forEach(function(c,i){
			var r=rows[i],e=(dns&&dns[r.addr])||{},t,w;
			t=!dns?'-':e.bytes==null?_('%d hits, %d packets').format(e.hits||0,e.packets||0)
				:_('%d hits, %d packets, %s').format(e.hits||0,e.packets||0,'%1024.2mB'.format(e.bytes));
			w=r.timeout!=null?_('%d s').format(r.timeout):'-';
			if(c.t&&c.t.textContent!==t)c.t.textContent=t;
			if(c.w&&c.w.textContent!==w)c.w.textContent=w;
		});
		if(!n)return;
		t=rows.length>MAP_ROWS
			?_('Showing %d of %d DNS patterns, out of %d map entries. Port and address entries are not listed — qosify keeps no per-entry counters for them.').format(MAP_ROWS,rows.length,total)
			:_('%d DNS patterns, out of %d map entries. Port and address entries are not listed — qosify keeps no per-entry counters for them.').format(rows.length,total);
		if(n.textContent!==t)n.textContent=t;
	},

	// One service list and one get_stats, then dump alongside qosify-status: the
	// map listing's traffic column reads the stats just fetched, so both are
	// chained after them, and qosify-status is only forked while qosify runs.
	// Master always opens the dns table, so its absence identifies the build
	// rather than a quiet period. fillMap() skips the rebuild while its signature
	// is unchanged, so the one-entry-per-port dump costs a compare, not a redraw.
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
			if(ctx.stats)self._cnDns=ctx.stats.dns!=null;
			self.fillCounters(ctx);
			return Promise.all([L.resolveDefault(callQosifyDump(),null),ctx.running,
				ctx.running&&!self.readonly?L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),null):null]);
		}).then(function(r){
			self.fillTins(r[1],r[2]);
			self.fillMap(r[0],self._cnStats&&self._cnStats.dns,
				self._cnDns==null?null:self._cnDns);
		}).finally(function(){self._cn=false;});
	},

	tabCounters:function(){
		var section=E('div',{'id':'qos-cn'});
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Traffic by Class')),
			E('div',{'id':'qos-cn-msg'}),
			E('div',{'id':'qos-cn-bars'}),
			E('div',{'id':'qos-cn-note'})
		]));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-cn-tin-sect','style':'display:none'},[
			E('legend',{},_('Traffic by CAKE Tin')),
			E('div',{'id':'qos-cn-tins'},emP(_('Reading tc output...')))
		]));
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Daemon')),
			E('div',{'id':'qos-cn-info'})
		]));
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},_('Map Entries')),
			E('div',{'id':'qos-cn-map'},emP(_('Reading map entries...')))
		]));
		return section;
	},

	// Cumulative totals since the last reload, EF first and bulk last. A
	// dscp_default_* naming a class is counted against that class, so the two
	// default slots would double-count and are skipped.
	// Grouped and coloured by the tin the class's egress codepoint lands in under
	// mode, highest priority tin first as the tin bars are, then by codepoint within
	// a tin. With no single mode to fold by, codepoint order and a colour per name.
	classTotals:function(st,mode){
		var cls=st&&st.classes,k,rows=[],names=[],total=0,bytes=null,self=this,
			fold=MODES.indexOf(mode)>=0,rank=this.dscpRanks(),mark=this.dscpMarks(),tin={};
		if(fold)this.getClasses().forEach(function(c){
			var v=self.dscpVal(c.egress||c.ingress);
			tin[c.name]=v<0?-1:+TIN_MAP[mode].charAt(v);
		});
		if(!cls){
			cls={};
			for(k in st)if(self.isCounter(st[k]))cls[k]=st[k];
		}
		for(k in cls)if(cls[k].packets!=null&&!CN_SKIP[k])names.push(k);
		names.sort();
		names.forEach(function(n,ix){
			var v=cls[n].packets||0;
			total+=v;
			if(cls[n].bytes!=null)bytes=(bytes||0)+cls[n].bytes;
			var t=tin[n]!=null?tin[n]:-1;
			rows.push({name:n,v:v,bytes:cls[n].bytes,tin:t,
				color:!fold?CN_COLORS[ix%CN_COLORS.length]:t<0?CN_NONE:TIN_COLORS[mode][t],
				mark:mark[n]||'',rk:rank[n]!=null?rank[n]:-1000});
		});
		rows.sort(function(a,b){return b.tin-a.tin||b.rk-a.rk||(a.name<b.name?-1:1);});
		rows.total=total;
		rows.bytes=bytes;
		return rows;
	},

	// The CAKE mode behind each shaped direction. cmd_add_qdisc() writes mode, then
	// options, then the direction's options, and tc keeps the last mode keyword.
	// cmd_add_ingress() attaches the classifier before it checks ingress, so an
	// unshaped ingress is still counted.
	cakeModes:function(){
		var r={modes:[],fwmark:false,ingress:false};
		['interface','device'].forEach(function(t){
			uci.sections('qosify',t,function(s){
				if(uciBool(s.disabled,false)||!s.name)return;
				var c=ifCfg(s,t==='device');
				if(!c.ingress)r.ingress=true;
				[[c.egress,s.egress_options],[c.ingress,s.ingress_options]].forEach(function(d){
					if(!d[0])return;
					var mode=c.mode;
					(String(s.options||'')+' '+String(d[1]||'')).split(/\s+/).forEach(function(w){
						if(MODES.indexOf(w)>=0)mode=w;
						if(w==='fwmark')r.fwmark=true;
					});
					if(r.modes.indexOf(mode)<0)r.modes.push(mode);
				});
			});
		});
		return r;
	},

	// qosify-status, as the Status tab prints it: tc -s qdisc for each shaped
	// direction. q_cake.c prints a column per tin in tin_order, lowest priority
	// first, so a column is a TIN_COLORS index; rows are reversed to put the
	// highest priority tin first, as the class bars are. Qdiscs running the same
	// mode are summed tin by tin into one chart, egress and ingress together; a
	// mode only one direction runs gets a chart of its own.
	cakeTins:function(txt){
		var blk=[],grp=[],key={},b=null;
		String(txt||'').split('\n').forEach(function(l){
			var m,w;
			if(/^===== (?:interface|device) \S+: /.test(l)||/^(egress|ingress) status:$/.test(l))b=null;
			else if(/^qdisc /.test(l)){
				w=l.split(/\s+/).filter(function(x){return MODES.indexOf(x)>=0;});
				b=/^qdisc cake /.test(l)?{mode:w.pop()}:null;
				if(b)blk.push(b);
			}
			else if(b&&!b.names&&/^\s+(Bulk|Tin 0)\b/.test(l))b.names=l.trim().split(/\s{2,}/);
			else if(b&&b.names&&(m=l.match(/^  (pkts|bytes|drops|marks)\s+(.*)$/)))
				b[m[1]]=m[2].trim().split(/\s+/).map(Number);
		});
		blk.forEach(function(b){
			if(!b.names||!b.pkts)return;
			var k=b.mode+'|'+b.names.join('|'),g=key[k];
			if(!g)grp.push(g=key[k]={mode:b.mode,names:b.names,pkts:[],bytes:[],drops:[],marks:[]});
			['pkts','bytes','drops','marks'].forEach(function(f){
				if(!b[f])g[f]=null;
				else if(g[f])b[f].forEach(function(v,i){g[f][i]=(g[f][i]||0)+v;});
			});
		});
		return grp.map(function(g){
			var c=TIN_COLORS[g.mode],n=g.names.length,rows=g.names.map(function(t,i){
				var r={name:t,v:g.pkts[i]||0,bytes:g.bytes?g.bytes[i]||0:null,
					drops:g.drops?g.drops[i]||0:null,marks:g.marks?g.marks[i]||0:null,
					color:c&&c.length===n?c[i]:CN_COLORS[i%CN_COLORS.length]};
				return r;
			}).reverse();
			rows.total=rows.reduce(function(t,r){return t+r.v;},0);
			rows.bytes=g.bytes?rows.reduce(function(t,r){return t+r.bytes;},0):null;
			return rows;
		});
	},

	// Status > Overview style: a .table of names and .cbi-progressbar bars, the
	// figures in the bar title the theme prints above it. Built again only when
	// the row names change; otherwise widths and text are set in place, so the
	// bars ease to their new length and nothing under them moves. Length is
	// (row/largest row)^BAR_EXP, with a non-zero row kept at 1%; the share in
	// the title stays exact.
	drawChart:function(box,rows,empty){
		var total=rows.total||0,max=0,c=box.qosChart,sig,t;
		if(!rows.length){box.qosChart=null;dom.content(box,emP(empty));return;}
		rows.forEach(function(r){if(r.v>max)max=r.v;});
		sig=rows.map(function(r){return r.name;}).join('\n');
		if(!c||c.sig!==sig){
			c=box.qosChart={sig:sig,rows:[],total:E('td',{'class':'td left'})};
			dom.content(box,E('table',{'class':'table'},rows.map(function(){
				var o={name:E('td',{'class':'td left','width':'33%'}),fill:E('div')};
				o.bar=E('div',{'class':'cbi-progressbar'},o.fill);
				c.rows.push(o);
				return E('tr',{'class':'tr'},[o.name,E('td',{'class':'td left'},o.bar)]);
			}).concat(E('tr',{'class':'tr'},[E('td',{'class':'td left','width':'33%'},E('strong',{},_('total'))),c.total]))));
		}
		rows.forEach(function(r,i){
			var o=c.rows[i],share=total?(r.v/total)*100:0,
				len=max&&r.v?Math.max(Math.pow(r.v/max,BAR_EXP)*100,1):0,
				f=[_('%d pkt').format(r.v)],n=r.mark?r.name+' ('+r.mark+')':r.name;
			if(r.bytes!=null)f.push('%1024.2mB'.format(r.bytes));
			if(r.drops!=null)f.push(_('%d drops, %d ECN marks').format(r.drops,r.marks||0));
			f=f.join(', ')+' ('+fmtShare(share)+')';
			if(o.name.textContent!==n)o.name.textContent=n;
			if(o.bar.title!==f)o.bar.title=f;
			o.fill.style.width=len.toFixed(2)+'%';
			o.fill.style.background=r.color;
		});
		t=_('%d pkt').format(total)+(rows.bytes!=null?', '+'%1024.2mB'.format(rows.bytes):'');
		if(c.total.textContent!==t)c.total.textContent=t;
	},

	drawBars:function(){
		var st=this._cnStats,box=$('qos-cn-bars'),n=$('qos-cn-note'),cm=this.cakeModes(),
			mode=cm.modes.length===1?cm.modes[0]:null,note=[];
		if(box){
			if(st)this.drawChart(box,this.classTotals(st,mode),_('The daemon reported no per-class counters.'));
			else{box.qosChart=null;dom.content(box,'');}
		}
		if(st&&cm.ingress)note.push(_('qosify classifies ingress even where ingress is 0, so these totals include traffic CAKE never sees.'));
		if(st&&cm.fwmark&&mode)note.push(_('fwmark is set in the CAKE options, so a firewall mark can put a packet in another tin than its class colour shows.'));
		if(n)dom.content(n,note.map(function(t){return descr(t);}));
	},

	// CAKE's own per-tin counters, per qdisc since it was created, so they need
	// not add up to the class totals, which count what the classifier matched.
	// A fork that fails keeps the last charts rather than collapsing the section.
	fillTins:function(running,r){
		var sect=$('qos-cn-tin-sect'),box=$('qos-cn-tins'),self=this,t;
		if(!sect||!box)return;
		sect.style.display=running?'':'none';
		if(!running)return;
		if(!this.readonly&&!r&&this._tinOk)return;
		t=this.readonly?[]:this.cakeTins(r&&r.stdout);
		this._tinOk=t.length>0;
		if(!t.length){
			box.qosGroups=0;
			dom.content(box,emP(this.readonly?_('The CAKE tin counters need write access to this page.')
				:r&&r.stdout?_('qosify-status shows no CAKE tin statistics.'):_('qosify-status returned no output.')));
			return;
		}
		if(box.qosGroups!==t.length){
			box.qosGroups=t.length;
			dom.content(box,t.map(function(){return E('div');}));
		}
		t.forEach(function(rows,i){self.drawChart(box.childNodes[i],rows,'');});
	},

	fillCounters:function(ctx){
		var msg=$('qos-cn-msg'),info=$('qos-cn-info');
		if(!ctx.running){
			if(info)dom.content(info,'');
			this.drawBars();
			if(msg)dom.content(msg,E('div',{'class':'alert-message warning'},
				_('qosify is not running. Start from the Overview tab.')));
			return;
		}
		if(msg)dom.content(msg,ctx.stats?'':emP(_('The daemon returned no counters.')));
		this.drawBars();
		if(info)dom.content(info,ctx.stats?this.infoNodes(ctx.stats):'');
	},

	// Rebuilt only when the listing's shape changes; otherwise only the figures
	// and footer are rewritten.
	fillMap:function(r,dns,hasDns){
		var box=$('qos-cn-map');
		if(!box)return;
		var e=(r&&r.entries)||[],rows=this.mapRows(e),sig,t;
		if(!rows.length){
			this._mapSig=this._mapCells=this._mapNote=null;
			t=e.length?_('qosify is matching %d map entries, none of them DNS patterns.').format(e.length)
				:_('The daemon reported no map entries.');
			if(box.textContent!==t)dom.content(box,emP(t));
			return;
		}
		sig=this.mapSig(rows,hasDns);
		if(sig!==this._mapSig){
			this._mapSig=sig;
			dom.content(box,this.mapNodes(rows,hasDns));
		}
		this.mapValues(rows,e.length,dns);
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
		return out;
	},

	// Runs on every poll tick and twice per open, so only the summary table is
	// rebuilt: replacing the <pre> would throw away the scroll position while it
	// is being read. ctx.qstatus null means the fork has not returned yet, '' means
	// it returned nothing -- the two used to look the same on screen.
	fillStatus:function(body,ctx){
		var sum=body.querySelector('#qos-st-sum'),pre=body.querySelector('#qos-st-pre'),msg=body.querySelector('#qos-st-msg');
		if(!sum||!pre||!msg)return;
		var note=function(t){dom.content(msg,emP(t));};
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
		var tbl=E('table',{'class':'table'});
		['interfaces','devices'].forEach(function(g){
			var t=st&&st[g],k,e;
			for(k in t){
				e=t[k]||{};
				tbl.appendChild(kvRow((g==='devices'?_('device %s'):_('interface %s')).format(k),[
					badge(e.active?'success':'',e.active?_('active'):_('inactive')),' ',
					_('device: %s, ingress: %s, egress: %s').format(e.ifname||'-',e.ingress?_('yes'):_('no'),e.egress?_('yes'):_('no'))
				]));
			}
		});
		if(!tbl.firstChild)tbl.appendChild(emRow(_('qosify has no interfaces or devices configured')));
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
		if(bwUp&&!rate.test(bwUp))notify(_('bandwidth_up does not look like a tc rate (100mbit, 12MBps, unlimited) — passing it through anyway').format(),'warning');
		if(bwDn&&!rate.test(bwDn))notify(_('bandwidth_down does not look like a tc rate (100mbit, 12MBps, unlimited) — passing it through anyway').format(),'warning');
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
		return self.confirmFresh(ta,RULES_PATH).then(function(go){
			if(!go)return null;
			return self.writeRules(ta,data,rwarn);
		});
	},

	writeRules:function(ta,data,rwarn){
		var self=this;
		self.lock();
		ui.showModal(_('Saving'),[E('p',{},_('Writing rules and reloading qosify...'))]);
		return fs.write(RULES_PATH,data).then(function(){
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
			if(el)el.style.display=(x===p)?'':'none';
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
			L.resolveDefault(fs.stat(RULES_PATH),null),
			withFiles?fs.read(UCI_PATH).catch(function(){return null;}):null,
			withFiles?fs.read(RULES_PATH).catch(function(){return null;}):null
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
			return self.uptime(d[0]).then(function(u){ctx.uptime=u;return ctx;});
		});
	},

	// Seconds since the running qosify started, or null. procd's service list
	// carries the pid but no start time, so starttime (field 22 of /proc/<pid>/stat,
	// USER_HZ ticks since boot) is set against /proc/uptime: both run on the boot
	// clock, so an NTP step does not skew it. A reload keeps the pid; the start is
	// cached per pid, so ticks read nothing until qosify is restarted.
	uptime:function(r){
		var self=this,pid=runPid(r);
		if(!pid){self._up=null;return Promise.resolve(null);}
		if(self._up&&self._up.pid===pid)return Promise.resolve(Date.now()/1000-self._up.t);
		return Promise.all([fs.read('/proc/'+pid+'/stat'),fs.read('/proc/uptime')]).then(function(d){
			var st=String(d[0]),f=st.slice(st.lastIndexOf(')')+2).split(' '),up=parseFloat(d[1])-f[19]/100;
			if(!(up>=0))return null;
			self._up={pid:pid,t:Date.now()/1000-up};
			return up;
		}).catch(function(){return null;});
	},

	// Poll path: six ubus calls (uci.get and gatherCtx(false)'s five), plus
	// uptime()'s two /proc reads the first tick after qosify starts, no shell
	// forks, and the parts of the page that hold user input or focus are patched
	// in place rather than rebuilt.
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
				self.reloadEditor('qos-rules-ta',RULES_PATH,which==='rules')
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
	[ -s "$VIEW_DIR/main.js" ] || { echo "[ERROR] Failed writing $VIEW_DIR/main.js"; exit 1; }
	# Stock LuCI markup only since 3.3.0; drop the stylesheet older installs wrote.
	rm -f "$VIEW_DIR/qosify.css"
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
EOF
}

save_installer() {
	SRC=$(readlink -f "$0" 2>/dev/null)
	[ -n "$SRC" ] && [ -f "$SRC" ] || return 0
	[ "$SRC" = "/root/qosify-luci.sh" ] && return 0
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
	/etc/init.d/qosify restart 2>/dev/null
	sleep 1
	/etc/init.d/qosify reload 2>/dev/null
	restart_luci_services
	logger -t qosify-luci "LuCI app installed v$VERSION"
	echo "[OK] qosify LuCI app installed"
	echo "[*] Refresh your browser (Ctrl+F5) to load the new menu."
}

uninstall_all() {
	echo "===== qosify LuCI Uninstaller ====="
	/etc/init.d/qosify stop 2>/dev/null
	/etc/init.d/qosify disable 2>/dev/null
	sleep 1
	# A clean stop already clears qosify's qdiscs and ifbs; cleanup only mops up
	# after an unclean exit. Without it there is no safe name list to sweep.
	[ -x "$TPL_DIR/cleanup" ] && "$TPL_DIR/cleanup"
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
	if [ -f "$VIEW_DIR/main.js" ]; then
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
	*) echo "Usage: $0 {install|uninstall|migrate|reset|files}" ;;
esac
