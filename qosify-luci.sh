#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (modern JS, ash-compatible)
VERSION="3.5.0-dev"
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
				"qosify": [ "status" ],
				"rc": [ "list" ],
				"service": [ "list" ],
				"file": [ "read", "stat" ]
			},
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "read", "list" ],
				"/etc/qosify/00-defaults.conf": [ "read", "list" ],
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
var OPT_DESC={
	defaults:_('List of files with port/IP/host mappings'),
	timeout:_('Default timeout for dynamically added entries'),
	dscp_default_tcp:_('Default DSCP value for TCP packets'),
	dscp_default_udp:_('Default DSCP value for UDP packets'),
	dscp_icmp:_('DSCP value for ICMP packets'),
	dscp_prio:_('DSCP value for priority-marked packets'),
	dscp_bulk:_('DSCP value for bulk-marked packets'),
	prio_max_avg_pkt_len:_('Maximum average packet length for marking a flow as priority'),
	bulk_trigger_pps:_('Number of packets per second to trigger bulk flow detection'),
	bulk_trigger_timeout:_('Time below bulk_trigger_pps threshold until a bulk flow mark is removed'),
	value:_('DSCP value for ingress and egress, where they are not set'),
	ingress:_('DSCP value for ingress'),
	egress:_('DSCP value for egress'),
	name:_('netifd interface (config interface) or netdev (config device) to enable QoS on'),
	disabled:_('Skip this section'),
	bandwidth_up:_('Uplink bandwidth (same format as tc)'),
	bandwidth_down:_('Downlink bandwidth (same format as tc)'),
	'if.ingress':_('Enable ingress shaping'),
	'if.egress':_('Enable egress shaping'),
	mode:_('CAKE diffserv mode'),
	nat:_('Enable CAKE NAT host detection via conntrack'),
	host_isolate:_('Enable CAKE host isolation'),
	autorate_ingress:_('Enable CAKE automatic rate estimation for ingress'),
	overhead_type:_('CAKE overhead keyword added to options; manual uses overhead and overhead_encap'),
	overhead:_('Adds overhead <bytes> when overhead_type is manual'),
	overhead_encap:_('Adds atm, noatm or ptm when overhead_type is manual'),
	overhead_mpu:_('Adds mpu <bytes>'),
	overhead_vlan:_('Adds ether-vlan once per level (1 or 2)'),
	ingress_options:_('CAKE ingress options'),
	egress_options:_('CAKE egress options'),
	options:_('CAKE options for ingress + egress')
};
// Quick Add grids hold at most this many options per table.
var QA_COLS=7;

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

function clsOpt(c){var d=c.ingress&&c.ingress!==c.egress?c.ingress+'/'+c.egress:c.egress;return c.name+(d?' ('+d+')':'');}
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
function statusNames(st){
	var out=[];
	['interfaces','devices'].forEach(function(g){for(var k in (st&&st[g]))if(st[g][k]&&st[g][k].active)out.push(k);});
	return out;
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

// Stock LuCI markup, so the page follows the active theme: .table rows as on
// Status > Overview, .label badges, .cbi-value form rows and plain pre/textarea.
// qosify.css draws each section as a box with the theme's own variables.
function badge(kind,t){return E('span',{'class':kind?'label '+kind:'label'},t);}
function kvRow(k,v,id){return E('tr',{'class':'tr'},[E('td',{'class':'td left','width':'33%'},k),E('td',{'class':'td left','id':id||null},v)]);}
function emRow(t){return E('tr',{'class':'tr placeholder'},E('td',{'class':'td'},E('em',{},t)));}
function emP(t){return E('p',{},E('em',{},t));}
function gridTable(head,rows,empty){
	return E('table',{'class':'table cbi-section-table'},[E('tr',{'class':'tr cbi-section-table-titles'},head.map(function(h){return E('th',{'class':'th'},h);}))]
		.concat(rows.length?rows.map(function(r){return E('tr',{'class':'tr cbi-section-table-row'},r.map(function(c,i){return E('td',{'class':'td','data-title':head[i]},c);}));}):[emRow(empty)]));
}
function sect(title,kids,attrs){
	var a=attrs||{};
	a['class']='cbi-section';
	return E('div',a,[E('h3',{'id':a.id?a.id+'-title':null},title)].concat(kids));
}
function fold(id,title,kids,open){
	var k='qosify.fold.'+id,st=null,d;
	try{st=sessionStorage.getItem(k);}catch(e){}
	d=E('details',{'class':'cbi-section','id':id,'open':(st==null?open:st==='1')?'':null},[E('summary',{},E('h3',{},title))].concat(kids));
	d.addEventListener('toggle',function(){try{sessionStorage.setItem(k,d.open?'1':'0');}catch(e){}});
	return d;
}
function colTable(cols,kids){
	var sum=cols.reduce(function(t,c){return t+c[1];},0);
	return E('table',{'class':'table','style':'table-layout:fixed'},[E('colgroup',{},cols.map(function(c){
		return E('col',{'style':'width:'+(c[1]*100/sum).toFixed(2)+'%'});}))].concat(kids));
}
function refBox(title,note,rows){
	return E('details',{},[E('summary',{},title),note?E('p',{},note):'',
		rows.length?E('table',{'class':'table'},rows.map(function(r){return kvRow(E('code',{},r[0]),r[1]);})):'']);
}
function valRow(lbl,el){
	var n=Array.isArray(el)?el[0]:el;
	return E('div',{'class':'cbi-value'},[E('label',{'class':'cbi-value-title','for':n.id||null},lbl),E('div',{'class':'cbi-value-field'},el)]);
}

// Remember the size/mtime an editor was loaded from, so a save can tell the
// difference between "the user changed this" and "something else changed the
// file underneath us".
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
		root.appendChild(E('link',{'rel':'stylesheet','href':L.resource('view/qosify/qosify.css')}));
		root.appendChild(E('h2',{},_('qosify')));

		var names={ov:'overview',cf:'config',ru:'rules',st:'status',ad:'advanced'};
		var hash=(location.hash||'').slice(1),want='ov',k;
		for(k in names)if(names[k]===hash)want=k;

		var group=E('div',{});
		[['ov',_('Overview'),this.tabOverview(ctx)],
		 ['cf',_('Config'),this.tabConfig(ctx)],
		 ['ru',_('Rules'),this.tabRules(ctx)],
		 ['st',_('Status'),this.tabStatus(ctx)],
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

	// Both tabs tick at 10 s: Overview is six ubus calls and no forks, Status forks
	// qosify-status, which runs tc twice per active interface. Poll.step() holds the
	// next tick until the promise this returns settles, and refreshStatus() drops an
	// overlapping call, so a fork slower than the interval skips ticks instead of
	// stacking up.
	installPollers:function(){
		var self=this;
		poll.add(function(){if(self.currentTab!=='ov'||self._n)return;return self.refreshOverview();},10);
		poll.add(function(){if(self.currentTab!=='st'||self._n)return;return self.refreshStatus();},10);
	},

	tabOverview:function(ctx){
		return E('div',{'id':'qos-ov'},[
			E('div',{'class':'cbi-section','id':'qos-svc-sect'},this.buildSvcSect(ctx)),
			E('div',{'class':'cbi-section','id':'qos-qs-sect'},this.buildQsSect(ctx)),
			E('div',{'class':'cbi-section','id':'qos-cfg-sect'},this.buildCfgSect(ctx))
		]);
	},

	buildSvcSect:function(ctx){
		var self=this,acts=E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button','id':'qos-btn-auto','click':function(){return self.svcAction(self._auto?'disable':'enable');}}));
		[['start','cbi-button-apply',_('Start')],['restart','cbi-button-action',_('Restart')],
		 ['reload','cbi-button-reload',_('Reload')],['stop','cbi-button-negative',_('Stop')]].forEach(function(b){
			acts.appendChild(document.createTextNode(' '));
			acts.appendChild(E('button',{'class':'cbi-button '+b[1],'id':'qos-btn-'+b[0],'click':function(){return self.svcAction(b[0]);}},b[2]));
		});
		this.svcButtons(ctx,acts);
		return [E('h3',{},_('Service')),this.renderSvcTable(ctx),acts];
	},

	svcButtons:function(ctx,root){
		var ro=this.readonly||!ctx.hasInit,b,g=function(id){return root?root.querySelector('#'+id):$(id);};
		this._auto=ctx.enabled;
		if((b=g('qos-btn-auto'))){
			b.className='cbi-button '+(ctx.enabled?'cbi-button-negative':'cbi-button-positive');
			dom.content(b,ctx.enabled?_('Disable Autostart'):_('Enable Autostart'));
			b.disabled=ro;
		}
		[['start',!ctx.running],['restart',ctx.running],['reload',ctx.running],['stop',ctx.running]].forEach(function(x){
			if((b=g('qos-btn-'+x[0])))b.disabled=ro||!x[1];
		});
	},

	buildCfgSect:function(ctx){
		return [E('h3',{},_('Files')),this.renderCfgFiles(ctx)];
	},

	buildQsSect:function(ctx){
		var self=this;
		var sn=ifSect();
		var w=(sn&&uci.get('qosify',sn.id))||{};
		var enChecked=(w['.name']!=null&&!uciBool(w.disabled,false));
		function chk(name,val){return E('input',{'type':'checkbox','class':'cbi-input-checkbox','id':'q-'+name,'data-q':name,'checked':val?'checked':null});}
		function txt(name,val,ph){return E('input',{'type':'text','class':'cbi-input-text','id':'q-'+name,'data-q':name,'value':val||'','placeholder':ph||''});}
		function sel(name,val,opts,def,hint){
			val=qv(val);
			var s=E('select',{'class':'cbi-input-select','id':'q-'+name,'data-q':name}),sv=val||def||'',known=false;
			if(!def)s.appendChild(E('option',{'value':''},hint?'-- ('+hint+')':'--'));
			opts.forEach(function(o){var a={'value':o};if(sv===o){a.selected='selected';known=true;}s.appendChild(E('option',a,o));});
			if(val&&!known)s.appendChild(E('option',{'value':val,'selected':'selected'},_('%s (current)').format(val)));
			return s;
		}
		function desc(t){return E('div',{'class':'cbi-value-description'},t);}
		function pane(id,title,rows){
			return E('div',{'data-tab':id,'data-tab-title':title},E('div',{'class':'cbi-section-node'},
				rows.map(function(r){return valRow(r[0],r[1]);})));
		}

		var enBadge=E('span',{'id':'q-en-badge'});
		this.updateEnBadge(enBadge,ctx,enChecked);
		var gen=[[_('QoS Enabled'),[chk('enabled',enChecked),' ',enBadge]]];
		// qosify.init passes `option name` to add_interface(); without it the daemon
		// gets an empty device and the section is never applied, so offer it here
		// whenever it is missing -- anonymous sections have no other way to set it.
		// Only `config interface` is named after the netifd interface; a `config
		// device` section names a netdev and the two differ by convention -- the
		// shipped config has `config device wandev` with `option name wan` -- so the
		// section name is never a safe prefill there. Leave it empty and let ifLint()
		// keep warning until a real netdev is entered.
		var isDev=!!(sn&&sn.type==='device');
		if(!w.name)gen.push(['name',[txt('name',sn?(isDev?'':sn.name):'wan',_('e.g. %s').format(isDev?'eth0':'wan')),
			desc(_('required — qosify skips sections with no name'))]]);
		gen.push(['bandwidth_up',txt('bw_up',w.bandwidth_up,_('e.g. %s').format('100mbit'))],
			['bandwidth_down',txt('bw_down',w.bandwidth_down,_('e.g. %s').format('100mbit'))],
			['mode',sel('mode',w.mode,MODES,null,'diffserv4')],
			['ingress',chk('ingress',numBool(w.ingress,true))],
			['egress',chk('egress',numBool(w.egress,true))]);
		// CAKE is only given nat/nonat when host_isolate is on; otherwise it gets
		// flow isolation and nat has no effect at all.
		var hiCb=chk('host_isolate',numBool(w.host_isolate,true));
		var natNote=desc(_('qosify only passes this to CAKE together with Host Isolate — add nat to Options to force it'));
		function syncNat(){
			natNote.style.display=hiCb.checked?'none':'';
		}
		hiCb.addEventListener('change',syncNat);
		syncNat();
		var grp=E('div',{},[
			pane('qs-general',_('General Settings'),gen),
			pane('qs-overhead',_('Overhead'),[
				['overhead_type',sel('overhead',w.overhead_type,OVH,'none')],
				['overhead',[txt('overhead_b',w.overhead,_('manual only')),desc(_('used only when Overhead Type is manual'))]]
			]),
			pane('qs-advanced',_('Advanced Settings'),[
				['nat',[chk('nat',numBool(w.nat,!isDev)),natNote]],
				['host_isolate',hiCb],
				['autorate_ingress',chk('autorate',numBool(w.autorate_ingress,false))],
				['ingress_options',txt('ing_opts',w.ingress_options,_('e.g. %s').format('triple-isolate memlimit 32mb'))],
				['egress_options',txt('egr_opts',w.egress_options,_('e.g. %s').format('triple-isolate memlimit 32mb wash'))],
				['options',txt('opts',w.options,_('e.g. %s').format('overhead 44 mpu 84'))]
			])
		]);
		ui.tabs.initTabGroup(grp.childNodes);
		return [
			E('h3',{},_('%s quick settings').format(sn?sn.type+(sn.name?' '+sn.name:''):'interface wan')),
			E('div',{},grp),
			E('div',{'class':'cbi-page-actions'},
				E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveQuick();}},_('Save & Apply')))
		];
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
		if(ctx.active){el.className='label success';dom.content(el,_('Active'));}
		else if(ctx.running&&enChecked){el.className='label warning';dom.content(el,_('Enabled — Not Shaping (check config)'));}
		else if(enChecked){el.className='label warning';dom.content(el,_('Enabled — Not Running'));}
		else{el.className='label';dom.content(el,_('Disabled'));}
	},

	svcNodes:function(ctx){
		var names=statusNames(ctx.status);
		return {
			run:badge(ctx.running?(ctx.active?'success':'warning'):'',ctx.running?_('Running'):_('Not running')),
			auto:badge(ctx.enabled?'success':'',ctx.enabled?_('Enabled'):_('Disabled')),
			shaped:names.length?names.join(', '):E('em',{},_('none')),
			init:ctx.hasInit?badge('success',_('Installed')):badge('warning',_('Missing'))
		};
	},

	renderSvcTable:function(ctx){
		var n=this.svcNodes(ctx);
		return E('table',{'class':'table','id':'qos-svc-tbl'},[
			kvRow(_('Status'),n.run,'qos-svc-run'),
			kvRow(_('Autostart'),n.auto,'qos-svc-auto'),
			kvRow(_('Active'),n.shaped,'qos-svc-shaped'),
			kvRow(E('code',{},'/etc/init.d/qosify'),n.init,'qos-svc-init')
		]);
	},

	updateSvcTable:function(ctx){
		var n=this.svcNodes(ctx),k,el;
		for(k in n)if((el=$('qos-svc-'+k)))dom.content(el,n[k]);
		this.svcButtons(ctx);
	},

	renderCfgFiles:function(ctx){
		var rulesN=(ctx.rulesN!=null)?ctx.rulesN:countRules(ctx.rulesText);
		var cfgOk=(ctx.cfgOk!=null)?ctx.cfgOk:((ctx.cfgRaw||'').length>10&&/(^|\n)config /.test(ctx.cfgRaw||''));
		var secN=uci.sections('qosify').length;
		function row(path,st,ok,n){
			return [E('code',{},path),st?(ok?badge('success',_('Valid')):badge('warning',_('Empty or invalid'))):badge('warning',_('Missing')),
				st?n:'-',st?fmtSize(st.size):'-',st?fmtMtime(st.mtime):'-'];
		}
		return gridTable([_('File'),_('Status'),_('Entries'),_('Size'),_('Modified')],[
			row(UCI_PATH,ctx.cfgStat,cfgOk,N_(secN,'%d section','%d sections').format(secN)),
			row(RULES_PATH,ctx.rulesStat,rulesN>0,N_(rulesN,'%d rule','%d rules').format(rulesN))
		]);
	},

	tabConfig:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-cf'});
		var classes=this.getClasses();
		var dscpChoices=classes.map(function(c){return c.name;}).concat(DSCP);
		function head(p,a,b){
			p.qaCells=[[_('section type'),E('select',{'class':'cbi-input-select','id':'qac-'+p.id.slice(9)+'-type'},
				[E('option',{'value':a},'config '+a),E('option',{'value':b},'config '+b)])],
				[_('section name'),E('input',{'type':'text','class':'cbi-input-text','id':'qac-'+p.id.slice(9)+'-name','placeholder':_('section name')})]];
		}
		function add(p){return E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qacAdd(p);}},_('Add'));}
		var qa=E('div',{'class':'qa'});

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
		var qadCls=E('div',{'id':'qac-opts-class'});
		head(qadCls,'class','alias');
		this.qaSelect(qadCls,'value',DSCP);
		this.qaSelect(qadCls,'ingress',DSCP);
		this.qaSelect(qadCls,'egress',DSCP);
		this.qaSelect(qadCls,'dscp_prio',dscpChoices);
		this.qaSelect(qadCls,'dscp_bulk',dscpChoices);
		this.qaNum(qadCls,'prio_max_avg_pkt_len','500');
		this.qaNum(qadCls,'bulk_trigger_pps','100');
		this.qaNum(qadCls,'bulk_trigger_timeout','5');

		// config interface / config device — add_interface()
		var qadIf=E('div',{'id':'qac-opts-interface'});
		head(qadIf,'interface','device');
		this.qaInput(qadIf,'name','option','wan');
		this.qaSelect(qadIf,'disabled',['0','1']);
		this.qaInput(qadIf,'bandwidth_up','option','100mbit');
		this.qaInput(qadIf,'bandwidth_down','option','100mbit');
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

		// Each stanza type folds on its own; the option reference is read back out
		// of the form, so the two can never disagree.
		[[qadDef,'defaults','config defaults',null,''],
		 [qadCls,'class','config class / config alias',_('Section name is the class name that rules and dscp_* values refer to. qosify.init reads config alias the same way as config class.'),''],
		 [qadIf,'interface','config interface / config device',_('config device takes the same options, with name set to a netdev. nat defaults to 1 for interfaces and 0 for devices.'),'if.']
		].forEach(function(p){
			var opts=p[0].qaCells.filter(function(c){return c[1].hasAttribute('data-opt');});
			self.qaGrid(p[0],p[0].qaCells);
			qa.appendChild(fold('qos-qa-'+p[1],_('Quick Add: %s').format(p[2]),[p[0],E('div',{'class':'qa-foot'},[
				refBox(_('Options'),p[3],opts.map(function(c){return [c[0],OPT_DESC[p[4]+c[0]]||OPT_DESC[c[0]]||''];})),add(p[1])])],false));
		});
		qa.appendChild(fold('qos-qa-ref',_('Reference'),[
			this.classRef('qos-cls-cfg'),
			refBox(_('DSCP values'),_('DSCP codepoints: CS0–CS7, AF11–AF43, EF, VA, NQB, LE, DF. A raw value from 0 to 63 is accepted too, and any dscp_* value may also name a class. Prefix with + to override only when the DSCP field is zero.'),[]),
			refBox(_('Defaults'),_('Defaults qosify applies when a key is absent — interface: mode diffserv4, ingress 1, egress 1, nat 1, host_isolate 1, autorate_ingress 0. device: identical except nat 0. defaults: timeout 3600, dscp_default_tcp/udp CS0, dscp_prio/dscp_bulk/dscp_icmp unset, bulk_trigger_pps/bulk_trigger_timeout/prio_max_avg_pkt_len 0 (disabled).'),[])
		],false));
		section.appendChild(qa);
		section.appendChild(this.editorSect('qos-config-ta',UCI_PATH,ctx.cfgRaw,ctx.cfgStat,function(){return self.clearCfg();},function(){return self.saveConfig();}));
		return section;
	},

	qaId:function(parent,opt){return (parent.id||'qac')+'-'+opt;},
	qaGrid:function(parent,cells){
		var n=Math.ceil(cells.length/QA_COLS),cols=Math.ceil(cells.length/n),w='width:'+(100/cols).toFixed(2)+'%',i,c;
		for(i=0;i<cells.length;i+=cols){
			c=cells.slice(i,i+cols);
			while(c.length<cols)c.push(['','']);
			parent.appendChild(E('table',{'class':'table cbi-section-table'},[
				E('tr',{'class':'tr cbi-section-table-titles'},c.map(function(x){return E('th',{'class':'th','style':w,'title':x[0]},x[0]);})),
				E('tr',{'class':'tr cbi-section-table-row'},c.map(function(x){return E('td',{'class':'td','style':w,'data-title':x[0]},x[1]);}))
			]));
		}
		return parent;
	},
	qaCell:function(parent,opt,el){(parent.qaCells=parent.qaCells||[]).push([opt,el]);},
	qaInput:function(parent,opt,pre,ph){
		this.qaCell(parent,opt,E('input',{
			'id':this.qaId(parent,opt),'class':'cbi-input-text','data-opt':opt,'data-pre':pre,'type':'text',
			'value':pre==='list'?ph:'','placeholder':pre==='list'?'':ph
		}));
	},
	qaSelect:function(parent,opt,opts){
		var s=E('select',{'id':this.qaId(parent,opt),'class':'cbi-input-select','data-opt':opt},E('option',{'value':''},'--'));
		opts.forEach(function(o){s.appendChild(E('option',{'value':o},o));});
		this.qaCell(parent,opt,s);
	},
	qaNum:function(parent,opt,ph){
		this.qaCell(parent,opt,E('input',{'id':this.qaId(parent,opt),'class':'cbi-input-text','data-opt':opt,'type':'number','min':'0','placeholder':ph}));
	},

	lock:function(){this._n=(this._n||0)+1;},
	unlock:function(){this._n=Math.max(0,(this._n||0)-1);},

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
		var classes=this.getClasses(),sel=$('qar-cls'),cur,self=this;
		if(sel){
			cur=sel.value;
			dom.content(sel,classes.map(function(c){return E('option',{'value':c.name},clsOpt(c));}));
			if(cur&&classes.some(function(c){return c.name===cur;}))sel.value=cur;
		}
		['qos-cls-cfg','qos-cls-ru'].forEach(function(id){
			var b=$(id);
			if(b)dom.content(b,self.classRows(classes));
		});
		var names=classes.map(function(c){return c.name;}).concat(DSCP);
		['qac-opts-defaults','qac-opts-class'].forEach(function(id){
			var p=$(id);if(!p)return;
			var ss=p.querySelectorAll('select[data-opt^="dscp_"]');
			for(var i=0;i<ss.length;i++){
				var s=ss[i],cur=s.value;
				dom.content(s,[E('option',{'value':''},'--')].concat(names.map(function(o){return E('option',{'value':o},o);})));
				s.value=cur;
			}
		});
	},

	classRows:function(classes){
		if(!classes.length)return emRow(_('No classes defined in %s').format(UCI_PATH));
		return classes.map(function(c){
			return kvRow(E('code',{},c.name),'ingress %s, egress %s'.format(c.ingress||'-',c.egress||'-')+(c.alias?' (alias)':''));
		});
	},

	classRef:function(id){
		return E('details',{},[E('summary',{},_('Classes')),E('table',{'class':'table'},E('tbody',{'id':id},this.classRows(this.getClasses())))]);
	},

	editorSect:function(id,path,text,st,clear,save){
		var ta=E('textarea',{'id':id,'class':'cbi-input-textarea','style':'width:100%','rows':28,'spellcheck':'false','wrap':'off'},text||'');
		ta.dataset.orig=text||'';
		stampFile(ta,st);
		return sect(path,[
			ta,
			E('div',{'class':'cbi-page-actions'},[
				E('button',{'class':'cbi-button cbi-button-reset','click':clear},_('Clear')),' ',
				E('button',{'class':'cbi-button cbi-button-apply','click':save},_('Save & Apply'))
			])
		]);
	},

	tabRules:function(ctx){
		var self=this;
		var section=E('div',{'id':'qos-ru'});
		var qarType=E('select',{'class':'cbi-input-select','id':'qar-type','change':function(){self.qarPlaceholder();}});
		[['tcp:','tcp:<port>[-<endport>]'],['udp:','udp:<port>[-<endport>]'],['both:','tcp: + udp:'],['dns:','dns:<pattern>'],['dnsr:','dns:/<regex>'],['dns_c:','dns_c:<pattern>'],['dns_cr:','dns_c:/<regex>'],['ipv4:','<ipaddr>'],['ipv6:','<ipv6addr>']].forEach(function(o){
			qarType.appendChild(E('option',{'value':o[0]},o[1]));
		});
		var qarCls=E('select',{'class':'cbi-input-select','id':'qar-cls'},this.getClasses().map(function(c){return E('option',{'value':c.name},clsOpt(c));}));
		var qr=[['match',5,qarType],['',8,E('input',{'type':'text','class':'cbi-input-text','id':'qar-val','placeholder':_('e.g. %s').format('4500')})],
			['dscp',6,qarCls],['+',1,E('input',{'type':'checkbox','class':'cbi-input-checkbox','id':'qar-prio'})],
			['',2,E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qarAdd();}},_('Add'))]];
		section.appendChild(E('div',{'class':'qa'},fold('qos-qa-rule',_('Quick Add'),[
			colTable(qr,[E('tr',{'class':'tr cbi-section-table-titles'},qr.map(function(c){return E('th',{'class':'th','title':c[0]},c[0]);})),
				E('tr',{'class':'tr cbi-section-table-row'},qr.map(function(c){return E('td',{'class':'td','data-title':c[0]},c[2]);}))]),
			E('div',{'class':'qa-foot'},[refBox(_('Mapping file syntax'),_('Each line has two whitespace separated fields, match and dscp. dscp can be a raw value, a codepoint like CS0, or a class name. DNS entries are compared in the order in which they are specified, using the first matching entry.'),[
				['tcp:<port>[-<endport>]',_('TCP single port, or range from <port> to <endport>')],
				['udp:<port>[-<endport>]',_('UDP single port, or range from <port> to <endport>')],
				['<ipaddr>',_('IPv4 address, e.g. 1.1.1.1')],
				['<ipv6addr>',_('IPv6 address, e.g. ff01::1')],
				['dns:<pattern>',_('fnmatch() pattern supporting * and ? as wildcard characters')],
				['dns:/<regex>',_('POSIX.2 extended regular expression for matching hostnames. Only works if dns lookups are passed to qosify via the add_dns_host ubus call.')],
				['dns_c:...',_('Like dns:... but only matches cname entries')],
				['+<dscp>',_('Only override the DSCP value if it is zero')]
			]),
			this.classRef('qos-cls-ru')])
		],false)));
		section.appendChild(this.editorSect('qos-rules-ta',RULES_PATH,ctx.rulesText,ctx.rulesStat,function(){return self.clearRules();},function(){return self.saveRules();}));
		return section;
	},

	tabAdvanced:function(ctx){
		var self=this;
		function row(i,path,fn,st,id){
			return [E('code',{},path),E('span',{'id':'qos-bk-sz-'+i},st?fmtSize(st.size):'-'),E('span',{'id':'qos-bk-mt-'+i},st?fmtMtime(st.mtime):'-'),
				self.dlBtn(path,fn),E('input',{'type':'file','id':id})];
		}
		return E('div',{'id':'qos-ad'},[
			sect(_('Backup & Restore'),[
				gridTable([_('File'),_('Size'),_('Modified'),_('Backup'),_('Restore')],[
					row(0,UCI_PATH,'qosify',ctx.cfgStat,'qos-up-cfg'),
					row(1,RULES_PATH,'00-defaults.conf',ctx.rulesStat,'qos-up-rules')
				]),
				E('div',{'class':'cbi-page-actions'},
					E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.uploadFiles();}},_('Upload & Apply')))
			]),
			sect(_('Defaults'),[
				E('div',{'class':'cbi-section-node'},valRow(_('Restore qosify defaults'),
					E('button',{'class':'cbi-button cbi-button-negative','click':function(){return self.resetDefaults();}},_('Reset'))))
			])
		]);
	},

	updateFiles:function(ctx){
		[ctx.cfgStat,ctx.rulesStat].forEach(function(st,i){
			var z=$('qos-bk-sz-'+i),m=$('qos-bk-mt-'+i);
			if(z)z.textContent=st?fmtSize(st.size):'-';
			if(m)m.textContent=st?fmtMtime(st.mtime):'-';
		});
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

	tabStatus:function(ctx){
		var body=E('div',{'id':'qos-st-body'},[E('div',{'id':'qos-st-sum'}),E('div',{'id':'qos-st-msg'}),E('pre',{'id':'qos-st-pre','style':'display:none'})]);
		this.fillStatus(body,ctx);
		return E('div',{'id':'qos-st'},sect('qosify-status',body));
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
		var rows=[];
		['interfaces','devices'].forEach(function(g){
			var t=st&&st[g],k,e;
			for(k in t){
				e=t[k]||{};
				rows.push(kvRow((g==='devices'?_('device %s'):_('interface %s')).format(k),[
					badge(e.active?'success':'',e.active?_('active'):_('inactive')),' ',
					_('device: %s, ingress: %s, egress: %s').format(e.ifname||'-',e.ingress?_('yes'):_('no'),e.egress?_('yes'):_('no'))
				]));
			}
		});
		return E('table',{'class':'table'},rows.length?rows:emRow(_('qosify has no interfaces or devices configured')));
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

	qacAdd:function(p){
		var tsel=$('qac-'+p+'-type'),nmEl=$('qac-'+p+'-name'),ty=tsel?tsel.value:p;
		var ta=$('qos-config-ta');if(!ta)return;
		var nm='',secs=cfgSections(ta.value);
		if(ty!=='defaults'){
			nm=trim(nmEl.value);
			if(!nm){notify(_('Enter a section name.'),'danger');return;}
			if(!/^[a-zA-Z0-9_]+$/.test(nm)){notify(_('A section name may only contain letters, digits and underscores.'),'danger');return;}
		}
		if(ty==='defaults'&&secs.some(function(x){return x.type==='defaults';})){notify(_('A config defaults section already exists.'),'danger');return;}
		if(nm&&secs.some(function(x){return x.type===ty&&x.name===nm;})){notify(_('Section %s already exists.').format(nm),'danger');return;}
		var s='config '+ty+(nm?" '"+nm+"'":'');
		var div=$('qac-opts-'+p);
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
		if(nm)nmEl.value='';
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
			return ctx;
		});
	},

	// Poll path: six ubus calls (uci.get and gatherCtx(false)'s five), no shell
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
			self.updateFiles(ctx);
			return ctx;
		}).finally(function(){self.unlock();});
	},

	refreshOverviewFull:function(){
		var self=this;
		return self.refreshOverview().then(function(ctx){
			self.fillSect('qos-svc-sect',self.buildSvcSect(ctx));
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
	cat > "$VIEW_DIR/qosify.css" << 'CSSEOF'
/* SPDX-License-Identifier: MIT */
#qos-app .cbi-tabmenu>li.cbi-tab>a{font-weight:600;color:var(--primary-color-high,inherit)}
#qos-app .cbi-section{border:1px solid var(--border-color-medium,rgba(128,128,128,.35));border-radius:6px;padding:0 1em .75em;margin:0 0 .9em;box-shadow:0 1px 2px rgba(0,0,0,.06)}
#qos-app .cbi-section>h3,#qos-app .cbi-section>summary{margin:0 -1em .75em;padding:.55em 1em;font-size:1.05em;font-weight:600;border-bottom:1px solid var(--border-color-low,rgba(128,128,128,.2));border-radius:6px 6px 0 0;background:var(--background-color-low,rgba(128,128,128,.06))}
#qos-app .cbi-section>summary{cursor:pointer;list-style:none}#qos-app .cbi-section>summary::-webkit-details-marker{display:none}
#qos-app .cbi-section>summary::before{content:"\25B8";display:inline-block;width:1.1em;transition:transform .15s}
#qos-app details.cbi-section[open]>summary::before{transform:rotate(90deg)}
#qos-app details.cbi-section:not([open]){padding-bottom:0}#qos-app details.cbi-section:not([open])>summary{margin-bottom:0;border-bottom:0;border-radius:6px}
#qos-app summary>h3{display:inline;margin:0;font-size:inherit;font-weight:inherit}
#qos-app .cbi-section .cbi-page-actions{margin:.75em -1em -.75em;border-radius:0 0 6px 6px}
#qos-app details:not(.cbi-section){margin:.75em 0 0}#qos-app details:not(.cbi-section)>summary{cursor:pointer;font-weight:600}
#qos-app details:not(.cbi-section)>p,#qos-app details:not(.cbi-section)>.table{margin:.5em 0 0}
#qos-config-ta,#qos-rules-ta{height:calc(100vh - 240px);min-height:320px;resize:vertical}
#qos-app .qa{margin:0 0 .9em}#qos-app .qa>details.cbi-section{margin:0 0 .3em;padding:0 .6em;border-radius:4px;box-shadow:none}
#qos-app .qa>details.cbi-section>summary{margin:0 -.6em;padding:.3em .6em;font-size:.95em;line-height:1.5;border-radius:4px 4px 0 0}#qos-app .qa summary>h3{line-height:inherit}
#qos-app .qa>details[open]{padding-bottom:.5em}#qos-app .qa>details[open]>summary{margin-bottom:.4em}#qos-app .qa>details:not([open])>summary{border-radius:4px}
#qos-app .qa .table{table-layout:fixed;margin:0 0 .3em}#qos-app .qa .th,#qos-app .qa .td{padding:.15em .3em;vertical-align:middle}
#qos-app .qa .th{font-size:.85em;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#qos-app .qa .td input:not([type=checkbox]),#qos-app .qa .td select{width:100%;min-width:0;box-sizing:border-box}#qos-app .qa .td input[type=checkbox]{margin:0;vertical-align:middle}
#qos-app .qa-foot{display:flex;align-items:flex-start;gap:.3em 1em}#qos-app .qa-foot>details{flex:1 1 0;min-width:0;margin:.15em 0 0}
#qos-app .qa details:not(.cbi-section)>summary{font-size:.9em}#qos-app .qa details:not(.cbi-section)>p,#qos-app .qa details:not(.cbi-section)>.table{margin:.3em 0 0}
CSSEOF
	[ -s "$VIEW_DIR/qosify.css" ] || { echo "[ERROR] Failed writing $VIEW_DIR/qosify.css"; exit 1; }
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
	*) echo "Usage: $0 {install|uninstall|migrate|reset|files}" ;;
esac
