#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (modern JS, ash-compatible)
VERSION="2.3.2"
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
	[ -f /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null
	sleep 1
	if [ -f /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart 2>/dev/null
	elif [ -f /etc/init.d/nginx ]; then /etc/init.d/nginx restart 2>/dev/null
	fi
	command -v ubus >/dev/null 2>&1 && ubus call uhttpd reload 2>/dev/null
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
tcp:53 voice
tcp:5353 voice
udp:53 voice
udp:5353 voice
# NTP
udp:123 voice
# SSH
tcp:22 +video
# HTTP/QUIC
tcp:80 +besteffort
tcp:443 +besteffort
udp:80 +besteffort
udp:443 +besteffort
EOF
	cat > "$TPL_DIR/qosify" << 'EOF'
config defaults
	list defaults '/etc/qosify/*.conf'
	option dscp_prio 'video'
	option dscp_icmp '+besteffort'
	option dscp_default_udp 'besteffort'
	option prio_max_avg_pkt_len '500'

config class 'besteffort'
	option ingress 'CS0'
	option egress 'CS0'

config class 'bulk'
	option ingress 'LE'
	option egress 'LE'

config class 'video'
	option ingress 'AF41'
	option egress 'AF41'

config class 'voice'
	option ingress 'CS6'
	option egress 'CS6'
	option bulk_trigger_pps '100'
	option bulk_trigger_timeout '5'
	option dscp_bulk 'CS0'

config interface 'wan'
	option name 'wan'
	option disabled '1'
	option bandwidth_up '100mbit'
	option bandwidth_down '100mbit'
	option overhead_type 'none'
	option ingress '1'
	option egress '1'
	option mode 'diffserv4'
	option nat '1'
	option host_isolate '1'
	option autorate_ingress '0'
	option ingress_options ''
	option egress_options ''
	option options ''

config device 'wandev'
	option disabled '1'
	option name 'wan'
	option bandwidth '100mbit'
EOF
}

install_defaults() {
	echo "[*] Writing default configs..."
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
			"acl": [ "luci-app-qosify" ]
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
				"luci": [ "setInitAction", "getInitList" ]
			},
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "read" ],
				"/etc/qosify/00-defaults.conf": [ "read" ],
				"/etc/init.d/qosify": [ "exec" ],
				"/usr/sbin/qosify": [ "read" ],
				"/usr/sbin/qosify-status": [ "exec" ],
				"/usr/share/qosify-luci/qosify": [ "read" ],
				"/usr/share/qosify-luci/00-defaults.conf": [ "read" ]
			}
		},
		"write": {
			"uci": [ "qosify" ],
			"file": {
				"/etc/config/qosify": [ "write" ],
				"/etc/qosify/00-defaults.conf": [ "write" ]
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
'use strict';
'require view';
'require fs';
'require ui';
'require uci';
'require poll';
'require rpc';
'require dom';

var VER='__VERSION__';
var UCI_PATH='/etc/config/qosify';
var RULES_PATH='/etc/qosify/00-defaults.conf';
var DSCP=['CS0','CS1','CS2','CS3','CS4','CS5','CS6','CS7','AF11','AF12','AF13','AF21','AF22','AF23','AF31','AF32','AF33','AF41','AF42','AF43','EF','LE'];
var OVH=['none','conservative','ethernet','pppoe-ptm','bridged-ptm','pppoe-vcmux','pppoe-llcsnap','pppoa-vcmux','pppoa-llc','bridged-vcmux','bridged-llcsnap','ipoa-vcmux','ipoa-llcsnap'];
var MODES=['diffserv3','diffserv4','diffserv8'];

var callInit=rpc.declare({
	object:'luci',
	method:'setInitAction',
	params:['name','action'],
	expect:{result:false}
});

function esc(s){return (s==null?'':String(s)).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]});}
function trim(s){return (s||'').replace(/^\s+|\s+$/g,'');}
function $(id){return document.getElementById(id);}

function detectActive(out){return /qdisc cake|: active|cake/.test(out||'');}

function countRules(text){
	var n=0,lines=(text||'').split('\n');
	for(var i=0;i<lines.length;i++){
		var l=trim(lines[i]);
		if(l&&l.charAt(0)!=='#')n++;
	}
	return n;
}

function fmtSize(n){return n<1024?n+'B':(n/1024).toFixed(1)+'K';}
function fmtMtime(t){if(!t)return '';var d=new Date(t*1000);return d.toISOString().replace('T',' ').slice(0,16);}

function getWan(){
	var w=uci.get('qosify','wan');
	if(!w){
		uci.add('qosify','interface','wan');
		uci.set('qosify','wan','name','wan');
	}
	return 'wan';
}

function notify(msg,kind){
	var n=ui.addNotification(null,E('p',{},msg),kind||'info');
	var ms=(kind==='danger')?10000:(kind==='warning')?8000:5000;
	if(n)setTimeout(function(){if(n&&n.parentNode)n.parentNode.removeChild(n);},ms);
	return n;
}

return view.extend({
	handleSaveApply:null,handleSave:null,handleReset:null,
	currentTab:'ov',
	pollers:[],

	load:function(){
		return Promise.all([
			uci.load('qosify').catch(function(){return null;}),
			L.resolveDefault(fs.read(RULES_PATH),''),
			L.resolveDefault(fs.read(UCI_PATH),''),
			L.resolveDefault(fs.stat(UCI_PATH),null),
			L.resolveDefault(fs.stat(RULES_PATH),null),
			L.resolveDefault(fs.exec('/etc/init.d/qosify',['running']),{code:1}),
			L.resolveDefault(fs.exec('/etc/init.d/qosify',['enabled']),{code:1}),
			L.resolveDefault(fs.stat('/usr/sbin/qosify'),null),
			L.resolveDefault(fs.stat('/etc/init.d/qosify'),null),
			L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),{stdout:''})
		]);
	},

	render:function(d){
		var ctx={
			rulesText:d[1]||'',
			cfgRaw:d[2]||'',
			cfgStat:d[3],
			rulesStat:d[4],
			running:d[5].code===0,
			enabled:d[6].code===0,
			hasBin:d[7]!=null,
			hasInit:d[8]!=null,
			qstatus:(d[9]&&d[9].stdout)||'',
		};
		ctx.active=detectActive(ctx.qstatus);

		var root=E('div',{'class':'cbi-map','id':'qos-app'});
		root.appendChild(E('style',{},this.css()));
		root.appendChild(E('h2',{},'qosify'));
		root.appendChild(E('div',{'class':'cbi-map-descr'},'Traffic shaping and DSCP classification via qosify'));

		var tabs=E('ul',{'class':'cbi-tabmenu'});
		var tabDef=[['ov','Overview'],['cf','Config'],['ru','Classification Rules'],['ad','Advanced'],['st','Status']];
		var self=this;
		tabDef.forEach(function(t){
			var li=E('li',{'class':'cbi-tab-disabled','id':'th-'+t[0]},
				E('a',{'href':'#','click':function(ev){ev.preventDefault();self.showTab(t[0]);}},t[1]));
			tabs.appendChild(li);
		});
		root.appendChild(tabs);

		root.appendChild(this.tabOverview(ctx));
		root.appendChild(this.tabConfig(ctx));
		root.appendChild(this.tabRules(ctx));
		root.appendChild(this.tabAdvanced(ctx));
		root.appendChild(this.tabStatus(ctx));

		root.appendChild(E('div',{'style':'margin:8px 0 0'},[
			E('span',{'style':'color:#888;font-size:12px'},'luci-app-qosify v'+VER)
		]));

		var hash=(location.hash||'').slice(1);
		var map={overview:'ov',config:'cf',rules:'ru',advanced:'ad',status:'st'};
		setTimeout(function(){self.showTab(map[hash]||'ov');},0);

		this.installPollers();
		return root;
	},

	installPollers:function(){
		var self=this;
		poll.add(function(){return self.refreshOverview();},10);
		poll.add(function(){return self.refreshStatus();},5);
	},

	showTab:function(t){
		var dirty=this.dirty();
		if(dirty&&(this.currentTab==='cf'||this.currentTab==='ru')&&t!==this.currentTab){
			if(!confirm('You have unsaved changes. Leave this tab?'))return;
		}
		this.currentTab=t;
		['ov','cf','ru','ad','st'].forEach(function(x){
			var el=$('qos-'+x),th=$('th-'+x);
			if(!el||!th)return;
			if(x===t){el.style.display='block';th.className='cbi-tab';}
			else{el.style.display='none';th.className='cbi-tab-disabled';}
		});
		var rev={ov:'overview',cf:'config',ru:'rules',ad:'advanced',st:'status'};
		try{history.replaceState(null,'','#'+rev[t]);}catch(e){}
	},

	dirty:function(){
		var c=$('qos-config-ta'),r=$('qos-rules-ta');
		if(c&&c.dataset.orig!=null&&c.value!==c.dataset.orig)return true;
		if(r&&r.dataset.orig!=null&&r.value!==r.dataset.orig)return true;
		return false;
	},

	css:function(){return [
		'.qos-badge{display:inline-block;padding:2px 10px;border-radius:3px;font-size:12px;font-weight:bold;color:#fff}',
		'.qos-green{background:#4caf50}.qos-red{background:#e53935}.qos-amber{background:#ff9800}',
		'.qos-ok{color:#4caf50}.qos-err{color:#e53935}.qos-warn{color:#ff9800}',
		'.qos-tab{display:none}.qos-kv td{padding:7px 12px;border-bottom:1px solid #eee}',
		'.qos-kv td:first-child{font-weight:bold;color:#888;width:200px}',
		'.qos-kv tr:last-child td{border-bottom:none}',
		'.qos-svc>*{display:inline-block;margin:0 3px 3px 0}',
		'.qos-btn-en{background:transparent !important;border:2px solid #4caf50 !important;color:#4caf50 !important;font-weight:bold}',
		'.qos-btn-en:hover{background:#4caf50 !important;color:#fff !important}',
		'.qos-btn-dis{background:transparent !important;border:2px solid #e53935 !important;color:#e53935 !important;font-weight:bold}',
		'.qos-btn-dis:hover{background:#e53935 !important;color:#fff !important}',
		'.qos-ref{margin:0 0 10px;padding:6px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a}',
		'.qos-ref summary{cursor:pointer;font-weight:bold;font-size:13px;color:#aaa}',
		'.qos-qa{margin:0 0 8px;padding:8px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a}',
		'.qos-qa label{font-size:11px;color:#888}',
		'.qos-qa-row{display:flex;gap:6px;align-items:center;margin:6px 0 0;flex-wrap:wrap}'
	].join('');},

	tabOverview:function(ctx){
		var section=E('div',{'class':'qos-tab','id':'qos-ov'});
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-svc-sect'},this.buildSvcSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-qs-sect'},this.buildQsSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-cfg-sect'},this.buildCfgSect(ctx)));
		section.appendChild(E('fieldset',{'class':'cbi-section','id':'qos-ctl-sect'},this.buildCtlSect(ctx)));
		return section;
	},

	buildSvcSect:function(ctx){
		return [E('legend',{},'Service Status'),this.renderSvcTable(ctx)];
	},

	buildCfgSect:function(ctx){
		return [E('legend',{},'Configuration Files'),this.renderCfgFiles(ctx)];
	},

	buildQsSect:function(ctx){
		var self=this;
		var w=uci.get('qosify','wan')||{};
		var wanDis=(w.disabled==='1');
		var enChecked=(uci.get('qosify','wan','name')&&!wanDis);

		var nodes=[];
		nodes.push(E('legend',{},'Quick Settings'));
		nodes.push(E('div',{'class':'cbi-section-descr'},'Common WAN settings — edit and apply without touching raw config.'));
		var tbl=E('table',{'class':'qos-kv','width':'100%'});
		var bdy=E('tbody');tbl.appendChild(bdy);

		function row(lbl,el){bdy.appendChild(E('tr',{},[E('td',{},lbl),E('td',{},el)]));}
		function chk(name,val){return E('input',{'type':'checkbox','id':'q-'+name,'data-q':name,'checked':val?'checked':null});}
		function txt(name,val,ph,style){return E('input',{'type':'text','id':'q-'+name,'data-q':name,'value':val||'','placeholder':ph||'','style':style||'width:140px;font-family:monospace'});}
		function sel(name,val,opts,style){
			var s=E('select',{'id':'q-'+name,'data-q':name,'style':style||'width:180px'});
			if(!val)s.appendChild(E('option',{'value':'','selected':'selected'},'--'));
			opts.forEach(function(o){var a={'value':o};if(val===o)a.selected='selected';s.appendChild(E('option',a,o));});
			return s;
		}

		var enCb=chk('enabled',enChecked);
		var enBadge=E('span',{'class':'qos-badge qos-amber','style':'margin-left:8px','id':'q-en-badge'},'');
		this.updateEnBadge(enBadge,ctx,enChecked);
		row('QoS Enabled',[enCb,enBadge]);
		row('Bandwidth Up',txt('bw_up',w.bandwidth_up,'e.g. 100mbit'));
		row('Bandwidth Down',txt('bw_down',w.bandwidth_down,'e.g. 100mbit'));
		row('Overhead Type',sel('overhead',w.overhead_type||w.overhead,OVH,'width:180px'));
		row('Queue Mode',sel('mode',w.mode,MODES,'width:148px'));
		row('Ingress',chk('ingress',w.ingress==='1'));
		row('Egress',chk('egress',w.egress==='1'));
		row('NAT',chk('nat',w.nat==='1'));
		row('Host Isolate',chk('host_isolate',w.host_isolate==='1'));
		row('Autorate Ingress',chk('autorate',w.autorate_ingress==='1'));
		row('Ingress Options',txt('ing_opts',w.ingress_options,'e.g. triple-isolate memlimit 32mb','width:100%;max-width:400px;font-family:monospace'));
		row('Egress Options',txt('egr_opts',w.egress_options,'e.g. triple-isolate memlimit 32mb wash','width:100%;max-width:400px;font-family:monospace'));
		row('Options',txt('opts',w.options||w.option,'e.g. overhead 44 mpu 84','width:100%;max-width:400px;font-family:monospace'));
		nodes.push(tbl);
		nodes.push(E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveQuick();}},'Save & Apply')));
		return nodes;
	},

	buildCtlSect:function(ctx){
		var self=this;
		var nodes=[E('legend',{},'Service Controls')];
		var svcCt=E('div',{'class':'qos-svc','id':'qos-svc-btns'});
		svcCt.appendChild(E('button',{
			'class':'cbi-button '+(ctx.enabled?'qos-btn-en':'qos-btn-dis'),
			'title':ctx.enabled?'Click to disable autostart':'Click to enable autostart',
			'click':function(){return self.svcAction(ctx.enabled?'disable':'enable');}
		},ctx.enabled?'Enabled':'Disabled'));
		['start','stop','restart','reload'].forEach(function(a){
			svcCt.appendChild(E('button',{
				'class':'cbi-button cbi-button-'+(a==='stop'?'reset':'apply'),
				'click':function(){return self.svcAction(a);}
			},a.charAt(0).toUpperCase()+a.slice(1)));
		});
		nodes.push(svcCt);
		return nodes;
	},

	fillSect:function(id,nodes){
		var el=$(id);
		if(!el)return;
		dom.content(el,'');
		nodes.forEach(function(n){el.appendChild(n);});
	},

	waitForRunning:function(timeoutMs){
		var deadline=Date.now()+(timeoutMs||3000);
		function tick(){
			return L.resolveDefault(fs.exec('/etc/init.d/qosify',['running']),{code:1}).then(function(r){
				if(r.code===0)return true;
				if(Date.now()>=deadline)return false;
				return new Promise(function(res){setTimeout(res,400);}).then(tick);
			});
		}
		return tick();
	},

	updateEnBadge:function(el,ctx,enChecked){
		dom.content(el,'');
		if(ctx.active){el.className='qos-badge qos-green';dom.append(el,'Active');}
		else if(ctx.running&&enChecked){el.className='qos-badge qos-amber';dom.append(el,'Enabled — Not Shaping (check config)');}
		else if(enChecked){el.className='qos-badge qos-amber';dom.append(el,'Enabled — Not Running');}
		else{el.className='qos-badge qos-red';dom.append(el,'Disabled');}
	},

	renderSvcTable:function(ctx){
		function ok(t){return E('span',{'class':'qos-ok'},'\u2714 '+t);}
		function err(t){return E('span',{'class':'qos-err'},'\u2718 '+t);}
		function bdg(cls,t){return E('span',{'class':'qos-badge '+cls},t);}
		var tbl=E('table',{'class':'qos-kv','width':'100%','id':'qos-svc-tbl'});
		var b=E('tbody');tbl.appendChild(b);
		b.appendChild(E('tr',{},[E('td',{},'Package'),E('td',{},ctx.hasBin?ok('Installed'):err('Not installed'))]));
		b.appendChild(E('tr',{},[E('td',{},'Init Script'),E('td',{},ctx.hasInit?ok('Available'):err('Missing'))]));
		b.appendChild(E('tr',{},[E('td',{},'Autostart'),E('td',{},bdg(ctx.enabled?'qos-green':'qos-red',ctx.enabled?'Enabled':'Disabled'))]));
		var run;
		if(ctx.running&&ctx.active)run=bdg('qos-green','Running & Shaping');
		else if(ctx.running)run=bdg('qos-amber','Running — Not Shaping');
		else run=bdg('qos-red','Not Running');
		b.appendChild(E('tr',{},[E('td',{},'Running'),E('td',{},run)]));
		return tbl;
	},

	renderCfgFiles:function(ctx){
		var cfgRules=countRules(ctx.cfgRaw);
		var rulesN=countRules(ctx.rulesText);
		var cfgOk=ctx.cfgRaw.length>10&&/(^|\n)config /.test(ctx.cfgRaw);
		var rulesOk=rulesN>0;
		var tbl=E('table',{'class':'qos-kv','width':'100%'});
		var b=E('tbody');tbl.appendChild(b);
		function fileRow(path,exists,ok,sz,mod,extra){
			var st;
			if(ok)st=E('span',{'class':'qos-ok'},'\u2714 Valid');
			else if(exists)st=E('span',{'class':'qos-warn'},'\u26a0 Found (empty or invalid)');
			else st=E('span',{'class':'qos-err'},'\u2718 Missing');
			var meta=exists?E('span',{'style':'color:#aaa;margin-left:8px;font-size:12px'},'('+(extra||'')+fmtSize(sz)+', '+mod+')'):'';
			b.appendChild(E('tr',{},[E('td',{},path),E('td',{},[st,meta])]));
		}
		fileRow(UCI_PATH,!!ctx.cfgStat,cfgOk,ctx.cfgStat?ctx.cfgStat.size:0,ctx.cfgStat?fmtMtime(ctx.cfgStat.mtime):'');
		fileRow(RULES_PATH,!!ctx.rulesStat,rulesOk,ctx.rulesStat?ctx.rulesStat.size:0,ctx.rulesStat?fmtMtime(ctx.rulesStat.mtime):'',rulesN+' rules, ');
		return tbl;
	},

	tabConfig:function(ctx){
		var self=this;
		var section=E('div',{'class':'qos-tab','id':'qos-cf','style':'display:none'});
		var fs1=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},'Config'),
			E('div',{'class':'cbi-section-descr'},['UCI configuration — classes, interfaces, defaults. ',E('code',{},UCI_PATH)])
		]);

		// Reference panel
		var ref=E('details',{'class':'qos-ref'});
		ref.appendChild(E('summary',{},'Config Reference'));
		var refBody=E('div',{'style':'font-size:11px;color:#bbb;margin:6px 0;font-family:monospace;line-height:1.8'});
		refBody.innerHTML=[
			'<strong style="color:#8ab4f8">config defaults</strong><br/>',
			'&nbsp; list defaults, option dscp_prio, option dscp_icmp, option dscp_bulk, option dscp_default_tcp, option dscp_default_udp, option prio_max_avg_pkt_len, option bulk_trigger_pps, option bulk_trigger_timeout<br/>',
			'<strong style="color:#8ab4f8">config class</strong> &lsquo;name&rsquo;<br/>',
			'&nbsp; option ingress, option egress, option dscp_prio, option dscp_bulk, option prio_max_avg_pkt_len, option bulk_trigger_pps, option bulk_trigger_timeout<br/>',
			'<strong style="color:#8ab4f8">config interface</strong> &lsquo;name&rsquo;<br/>',
			'&nbsp; option name, option disabled, option bandwidth_up, option bandwidth_down, option overhead_type, option mode, option ingress, option egress, option nat, option host_isolate, option autorate_ingress, option ingress_options, option egress_options, option options<br/>',
			'<strong style="color:#8ab4f8">config device</strong> &lsquo;name&rsquo;<br/>',
			'&nbsp; option name, option disabled, option bandwidth'
		].join('');
		ref.appendChild(refBody);

		// Live defaults & classes
		var defs={};
		uci.sections('qosify','defaults',function(s){if(!defs['.name'])defs=s;});
		if(defs['.name']){
			var defBox=E('div',{'style':'margin:6px 0 4px;padding:4px 8px;border:1px solid #444;border-radius:3px;background:#222'});
			defBox.appendChild(E('strong',{'style':'font-size:12px;color:#8ab4f8'},'config defaults'));
			var defLine=E('div',{'style':'font-size:11px;color:#bbb;margin:2px 0 0;font-family:monospace'});
			var keys=['dscp_default_tcp','dscp_default_udp','dscp_icmp','dscp_prio','dscp_bulk','prio_max_avg_pkt_len','bulk_trigger_pps','bulk_trigger_timeout'];
			var parts=[];
			keys.forEach(function(k){if(defs[k])parts.push(k+': <strong>'+esc(defs[k])+'</strong>');});
			defLine.innerHTML=parts.join(' &nbsp; ');
			defBox.appendChild(defLine);
			ref.appendChild(defBox);
		}
		var classes=this.getClasses();
		classes.forEach(function(c){
			var box=E('div',{'style':'margin:4px 0;padding:4px 8px;border:1px solid #444;border-radius:3px;background:#222'});
			box.appendChild(E('strong',{'style':'font-size:12px;color:#8ab4f8'},c.name));
			box.appendChild(E('span',{'style':'font-size:11px;color:#bbb;margin-left:8px'},'Ingress: '+(c.ingress||'')+' / Egress: '+(c.egress||'')));
			ref.appendChild(box);
		});
		ref.appendChild(E('div',{'style':'color:#888;font-size:11px;margin:4px 0 2px'},
			'DSCP codepoints: CS0–CS7, AF11–AF43, EF, LE. Prefix with + for priority boost (rules only).'));
		fs1.appendChild(ref);

		// Quick Add Config
		var qa=E('div',{'class':'qos-qa'});
		qa.appendChild(E('strong',{'style':'font-size:13px;color:#aaa'},'Quick Add Config'));
		var qacRow=E('div',{'class':'qos-qa-row'});
		var qacType=E('select',{'id':'qac-type','style':'width:130px','change':function(){self.qacSwitch();}});
		[['defaults','config defaults'],['class','config class'],['interface','config interface']].forEach(function(o){
			qacType.appendChild(E('option',{'value':o[0]},o[1]));
		});
		qacRow.appendChild(qacType);
		qacRow.appendChild(E('span',{'id':'qac-nm-w','style':'display:none'},
			E('input',{'id':'qac-name','type':'text','placeholder':'section name','style':'width:120px;font-family:monospace'})));
		qacRow.appendChild(E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qacAdd();}},'Add'));
		qa.appendChild(qacRow);

		var clsNames=classes.map(function(c){return c.name;});
		// defaults options
		var qadDef=E('div',{'class':'qos-qa-row','id':'qac-opts-defaults'});
		this.qaInput(qadDef,'list','defaults','/etc/qosify/*.conf','list',180);
		this.qaSelect(qadDef,'dscp_prio',clsNames,120);
		this.qaSelect(qadDef,'dscp_icmp',clsNames,120);
		this.qaSelect(qadDef,'dscp_bulk',clsNames,120);
		this.qaSelect(qadDef,'dscp_default_tcp',clsNames,120);
		this.qaSelect(qadDef,'dscp_default_udp',clsNames,120);
		this.qaNum(qadDef,'prio_max_avg_pkt_len','500',55);
		this.qaNum(qadDef,'bulk_trigger_pps','100',55);
		this.qaNum(qadDef,'bulk_trigger_timeout','5',45);
		qa.appendChild(qadDef);

		// class options
		var qadCls=E('div',{'class':'qos-qa-row','id':'qac-opts-class','style':'display:none'});
		this.qaSelect(qadCls,'ingress',DSCP,70,true);
		this.qaSelect(qadCls,'egress',DSCP,70,true);
		this.qaSelect(qadCls,'dscp_prio',DSCP,70);
		this.qaSelect(qadCls,'dscp_bulk',DSCP,70);
		this.qaNum(qadCls,'prio_max_avg_pkt_len','500',55);
		this.qaNum(qadCls,'bulk_trigger_pps','100',55);
		this.qaNum(qadCls,'bulk_trigger_timeout','5',45);
		qa.appendChild(qadCls);

		// interface options
		var qadIf=E('div',{'class':'qos-qa-row','id':'qac-opts-interface','style':'display:none'});
		this.qaInput(qadIf,'name','option','wan','option',80);
		this.qaSelect(qadIf,'disabled',['0','1'],45);
		this.qaInput(qadIf,'bandwidth_up','option','100mbit','option',80);
		this.qaInput(qadIf,'bandwidth_down','option','100mbit','option',80);
		this.qaSelect(qadIf,'overhead_type',OVH,130);
		this.qaSelect(qadIf,'mode',MODES,100);
		this.qaSelect(qadIf,'ingress',['0','1'],45);
		this.qaSelect(qadIf,'egress',['0','1'],45);
		this.qaSelect(qadIf,'nat',['0','1'],45);
		this.qaSelect(qadIf,'host_isolate',['0','1'],45);
		this.qaSelect(qadIf,'autorate_ingress',['0','1'],45);
		this.qaInput(qadIf,'ingress_options','option','triple-isolate','option',160);
		this.qaInput(qadIf,'egress_options','option','triple-isolate wash','option',160);
		this.qaInput(qadIf,'options','option','overhead 44 mpu 84','option',160);
		qa.appendChild(qadIf);

		fs1.appendChild(qa);

		// Editor
		var ta=E('textarea',{
			'id':'qos-config-ta',
			'rows':28,
			'style':'width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px'
		},ctx.cfgRaw);
		ta.dataset.orig=ctx.cfgRaw;
		fs1.appendChild(ta);
		fs1.appendChild(E('div',{'class':'cbi-page-actions'},[
			E('button',{'class':'cbi-button cbi-button-reset','style':'margin-right:6px','click':function(){return self.clearCfg();}},'Clear'),
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveConfig();}},'Save & Apply')
		]));

		section.appendChild(fs1);
		return section;
	},

	qaInput:function(parent,opt,pre,ph,preVal,w){
		parent.appendChild(E('label',{},opt+':'));
		parent.appendChild(E('input',{
			'data-opt':opt,'data-pre':pre,'type':'text',
			'value':opt==='list'?ph:'','placeholder':opt==='list'?'':ph,
			'style':'width:'+w+'px;font-family:monospace'
		}));
	},
	qaSelect:function(parent,opt,opts,w,required){
		parent.appendChild(E('label',{},opt+':'));
		var s=E('select',{'data-opt':opt,'style':'width:'+w+'px'});
		if(!required)s.appendChild(E('option',{'value':''},'--'));
		opts.forEach(function(o){s.appendChild(E('option',{'value':o},o));});
		parent.appendChild(s);
	},
	qaNum:function(parent,opt,ph,w){
		parent.appendChild(E('label',{},opt+':'));
		parent.appendChild(E('input',{'data-opt':opt,'type':'number','min':'0','placeholder':ph,'style':'width:'+w+'px'}));
	},

	getClasses:function(){
		var arr=[];
		uci.sections('qosify','class',function(s){
			arr.push({name:s['.name'],ingress:s.ingress||'',egress:s.egress||'',
				dscp_prio:s.dscp_prio||'',dscp_bulk:s.dscp_bulk||'',
				prio_max_avg_pkt_len:s.prio_max_avg_pkt_len||'',
				bulk_trigger_pps:s.bulk_trigger_pps||'',
				bulk_trigger_timeout:s.bulk_trigger_timeout||''});
		});
		return arr;
	},

	tabRules:function(ctx){
		var self=this;
		var section=E('div',{'class':'qos-tab','id':'qos-ru','style':'display:none'});
		var fs1=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},'Classification Rules'),
			E('div',{'class':'cbi-section-descr'},['DSCP mapping rules loaded by qosify on startup. ',E('code',{},RULES_PATH)])
		]);

		// Available classes
		var classes=this.getClasses();
		var ref=E('details',{'class':'qos-ref'});
		ref.appendChild(E('summary',{},'Available Classes'));
		var refTbl=E('table',{'class':'qos-kv','style':'margin:6px 0 0','width':'100%'});
		var refB=E('tbody');refTbl.appendChild(refB);
		if(classes.length){
			classes.forEach(function(c){
				refB.appendChild(E('tr',{},[
					E('td',{'style':'width:140px'},c.name),
					E('td',{},'Ingress: '+(c.ingress||'')+' / Egress: '+(c.egress||''))
				]));
			});
		}else{
			refB.appendChild(E('tr',{},E('td',{'colspan':2,'style':'color:#888'},E('em',{},'No classes defined in /etc/config/qosify'))));
		}
		ref.appendChild(refTbl);
		ref.appendChild(E('div',{'style':'color:#888;font-size:11px;margin:6px 0 2px'},
			'Prefix with + for priority within class. Ports: tcp:443, udp:3074, ranges: tcp:5060-5061. DNS: dns:*teams*, regex: dns:/zoom[0-9]+. IP: 1.1.1.1, ff01::1'));
		fs1.appendChild(ref);

		// Quick Add Rule
		var qa=E('div',{'class':'qos-qa'});
		qa.appendChild(E('strong',{'style':'font-size:13px;color:#aaa'},'Quick Add Rule'));
		var qarRow=E('div',{'class':'qos-qa-row'});
		var qarType=E('select',{'id':'qar-type','style':'width:140px','change':function(){self.qarPlaceholder();}});
		[['tcp:','tcp port'],['udp:','udp port'],['both:','tcp+udp port'],['dns:','dns pattern'],['dnsr:','dns regex'],['dns_c:','dns_c pattern'],['dns_cr:','dns_c regex'],['ipv4:','IPv4 address'],['ipv6:','IPv6 address']].forEach(function(o){
			qarType.appendChild(E('option',{'value':o[0]},o[1]));
		});
		qarRow.appendChild(qarType);
		qarRow.appendChild(E('input',{'id':'qar-val','type':'text','placeholder':'e.g. 4500 or 5060-5061','style':'width:180px;font-family:monospace'}));
		var qarCls=E('select',{'id':'qar-cls','style':'width:140px'});
		classes.forEach(function(c){qarCls.appendChild(E('option',{'value':c.name},c.name));});
		qarRow.appendChild(qarCls);
		qarRow.appendChild(E('label',{'style':'font-size:12px;color:#aaa;white-space:nowrap'},
			[E('input',{'type':'checkbox','id':'qar-prio'}),' priority (+)']));
		qarRow.appendChild(E('button',{'class':'cbi-button cbi-button-add','click':function(){return self.qarAdd();}},'Add'));
		qa.appendChild(qarRow);
		fs1.appendChild(qa);

		// Editor
		var ta=E('textarea',{
			'id':'qos-rules-ta','rows':28,
			'style':'width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px'
		},ctx.rulesText);
		ta.dataset.orig=ctx.rulesText;
		fs1.appendChild(ta);
		fs1.appendChild(E('div',{'class':'cbi-page-actions'},[
			E('button',{'class':'cbi-button cbi-button-reset','style':'margin-right:6px','click':function(){return self.clearRules();}},'Clear'),
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.saveRules();}},'Save & Apply')
		]));

		section.appendChild(fs1);
		return section;
	},

	tabAdvanced:function(ctx){
		var self=this;
		var section=E('div',{'class':'qos-tab','id':'qos-ad','style':'display:none'});

		// Backup
		var fb=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},'Backup Current Files'),
			E('div',{'class':'cbi-section-descr'},'Download current config files before making changes.')
		]);
		fb.appendChild(this.dlRow('/etc/config/qosify','qosify',ctx.cfgRaw));
		fb.appendChild(this.dlRow('/etc/qosify/00-defaults.conf','00-defaults.conf',ctx.rulesText));
		section.appendChild(fb);

		// Upload
		var fu=E('fieldset',{'class':'cbi-section'},[
			E('legend',{},'Upload Config Files'),
			E('div',{'class':'cbi-section-descr'},'Select files and click Save & Apply to overwrite and restart qosify.')
		]);
		var u1=E('input',{'type':'file','id':'qos-up-cfg','accept':'.conf,text/plain'});
		var u2=E('input',{'type':'file','id':'qos-up-rules','accept':'.conf,text/plain'});
		fu.appendChild(E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},'/etc/config/qosify'),
			E('div',{'class':'cbi-value-field'},u1)
		]));
		fu.appendChild(E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},'/etc/qosify/00-defaults.conf'),
			E('div',{'class':'cbi-value-field'},u2)
		]));
		fu.appendChild(E('div',{'class':'cbi-page-actions'},
			E('button',{'class':'cbi-button cbi-button-apply','click':function(){return self.uploadFiles();}},'Save & Apply')
		));
		section.appendChild(fu);

		// Reset
		section.appendChild(E('fieldset',{'class':'cbi-section'},[
			E('legend',{},'Reset to qosify Defaults'),
			E('div',{'class':'cbi-section-descr'},'Replaces both config files with qosify defaults, qosify will be disabled.'),
			E('div',{'class':'cbi-page-actions'},
				E('button',{'class':'cbi-button cbi-button-negative','click':function(){return self.resetDefaults();}},'Reset to Defaults'))
		]));
		return section;
	},

	dlRow:function(path,fn,content){
		return E('div',{'class':'cbi-value'},[
			E('label',{'class':'cbi-value-title'},path),
			E('div',{'class':'cbi-value-field'},
				E('button',{'class':'cbi-button cbi-button-action','click':function(){
					var b=new Blob([content||''],{type:'application/octet-stream'});
					var a=document.createElement('a');
					a.href=URL.createObjectURL(b);a.download=fn;a.click();URL.revokeObjectURL(a.href);
				}},'Download'))
		]);
	},

	tabStatus:function(ctx){
		var section=E('div',{'class':'qos-tab','id':'qos-st','style':'display:none'});
		var fs1=E('fieldset',{'class':'cbi-section'},E('legend',{},'qosify-status'));
		var body=E('div',{'id':'qos-st-body'});
		this.fillStatus(body,ctx);
		fs1.appendChild(body);
		section.appendChild(fs1);
		return section;
	},

	fillStatus:function(body,ctx){
		dom.content(body,'');
		if(!ctx.running){
			body.appendChild(E('div',{'class':'alert-message warning'},'qosify is not running. Start from the Overview tab.'));
		}else if(!ctx.qstatus){
			body.appendChild(E('p',{'style':'color:#888'},E('em',{},'qosify-status returned no output.')));
		}else{
			body.appendChild(E('pre',{'style':'background:#1e1e1e;color:#e0e0e0;padding:12px;border:1px solid #333;border-radius:4px;overflow-x:auto;font-size:12px;line-height:1.5;white-space:pre-wrap'},ctx.qstatus));
		}
	},

	// === Actions ===

	svcAction:function(action){
		var self=this;
		ui.showModal('Working',[E('p',{},'Sending ' +action+ ' to qosify...')]);
		return callInit('qosify',action).then(function(){
			return new Promise(function(r){setTimeout(r,800);});
		}).then(function(){
			return self.refreshOverview();
		}).finally(function(){
			ui.hideModal();
		});
	},

	saveQuick:function(){
		var self=this;
		var get=function(id){var e=$('q-'+id);return e?e.value:'';};
		var chk=function(id){var e=$('q-'+id);return e&&e.checked;};
		var bw=function(s){return (s||'').toLowerCase().replace(/[^0-9a-z]/g,'');};
		var bwUp=bw(get('bw_up')),bwDn=bw(get('bw_down'));
		var ovh=get('overhead'),mode=get('mode');
		var iopts=trim(get('ing_opts')),eopts=trim(get('egr_opts')),gopts=trim(get('opts'));
		var safe=/^[\w\s\-\.]*$/;
		if(!safe.test(iopts)||!safe.test(eopts)||!safe.test(gopts)){
			notify('Error: invalid characters in options fields. Use alphanumeric, spaces, hyphens, dots only.','danger');
			return;
		}
		if(bwUp&&!/^\d+[kmg]?bit$/.test(bwUp)){notify('Error: bandwidth_up must look like 100mbit','danger');return;}
		if(bwDn&&!/^\d+[kmg]?bit$/.test(bwDn)){notify('Error: bandwidth_down must look like 100mbit','danger');return;}

		var sec=getWan();
		uci.set('qosify',sec,'disabled',chk('enabled')?'0':'1');
		if(bwUp)uci.set('qosify',sec,'bandwidth_up',bwUp);
		if(bwDn)uci.set('qosify',sec,'bandwidth_down',bwDn);
		if(ovh){uci.set('qosify',sec,'overhead_type',ovh);uci.unset('qosify',sec,'overhead');}
		if(mode)uci.set('qosify',sec,'mode',mode);
		uci.set('qosify',sec,'ingress',chk('ingress')?'1':'0');
		uci.set('qosify',sec,'egress',chk('egress')?'1':'0');
		uci.set('qosify',sec,'nat',chk('nat')?'1':'0');
		uci.set('qosify',sec,'host_isolate',chk('host_isolate')?'1':'0');
		uci.set('qosify',sec,'autorate_ingress',chk('autorate')?'1':'0');
		uci.set('qosify',sec,'ingress_options',iopts);
		uci.set('qosify',sec,'egress_options',eopts);
		uci.set('qosify',sec,'options',gopts);
		uci.unset('qosify',sec,'option');

		ui.showModal('Saving',[E('p',{},'Saving settings and restarting qosify...')]);
		return uci.save().then(function(){return uci.apply(0);}).then(function(){
			return callInit('qosify','restart');
		}).then(function(){
			return self.waitForRunning(4000);
		}).then(function(){
			return self.checkShapingForSave('Settings saved');
		}).then(function(msg){
			ui.hideModal();
			notify(msg.text,msg.kind);
			return self.refreshOverviewFull();
		}).catch(function(e){
			ui.hideModal();
			notify('Save failed: '+e,'danger');
		});
	},

	saveConfig:function(){
		var self=this;
		var ta=$('qos-config-ta');
		if(!ta)return;
		var data=ta.value.replace(/\r\n/g,'\n');
		if(data.length===0){
			if(!confirm('Empty config will stop qosify. Continue?'))return;
			return fs.write(UCI_PATH,'').then(function(){
				return callInit('qosify','stop');
			}).then(function(){
				ta.dataset.orig='';
				notify('Config cleared, qosify stopped.','info');
				return self.refreshOverview();
			});
		}
		if(!/(^|\n)config /.test(data)){
			notify('Error: No valid config stanzas found.','danger');return;
		}
		ui.showModal('Saving',[E('p',{},'Writing config and restarting qosify...')]);
		return fs.write(UCI_PATH,data).then(function(){
			uci.unload('qosify');
			return uci.load('qosify');
		}).then(function(){
			return callInit('qosify','restart');
		}).then(function(){
			return self.waitForRunning(4000);
		}).then(function(){
			return self.checkShapingForSave('Config saved');
		}).then(function(msg){
			ta.dataset.orig=data;
			ui.hideModal();
			notify(msg.text,msg.kind);
			return self.refreshOverviewFull();
		}).catch(function(e){
			ui.hideModal();
			notify('Save failed: '+e,'danger');
		});
	},

	checkShapingForSave:function(prefix){
		return Promise.all([
			L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),{stdout:''}),
			uci.load('qosify')
		]).then(function(r){
			var st=r[0].stdout||'';
			var w=uci.get('qosify','wan')||{};
			if(w.disabled==='1')return {text:prefix+', qosify restarted (QoS disabled).',kind:'info'};
			if(detectActive(st))return {text:prefix+', qosify restarted.',kind:'info'};
			return {text:'Warning: '+prefix+' but qosify is not shaping traffic — check for syntax errors.',kind:'warning'};
		});
	},

	saveRules:function(){
		var self=this;
		var ta=$('qos-rules-ta');
		if(!ta)return;
		var data=ta.value.replace(/\r\n/g,'\n');
		ui.showModal('Saving',[E('p',{},'Writing rules and restarting qosify...')]);
		return fs.write(RULES_PATH,data).then(function(){
			return callInit('qosify','restart');
		}).then(function(){
			return self.waitForRunning(4000);
		}).then(function(){
			return self.checkShapingForSave('Rules saved');
		}).then(function(msg){
			ta.dataset.orig=data;
			ui.hideModal();
			notify(msg.text,msg.kind);
			return self.refreshOverview();
		}).catch(function(e){
			ui.hideModal();
			notify('Save failed: '+e,'danger');
		});
	},

	clearCfg:function(){
		if(!confirm('Clear config editor and reset Quick Settings? Content will not be saved until you click Save.'))return;
		var ta=$('qos-config-ta');if(ta)ta.value='';
		document.querySelectorAll('#qos-ov [data-q]').forEach(function(el){
			if(el.type==='checkbox')el.checked=false;
			else if(el.tagName==='SELECT')el.selectedIndex=0;
			else el.value='';
		});
	},
	clearRules:function(){
		if(!confirm('Clear rules editor? Content will not be saved until you click Save.'))return;
		var ta=$('qos-rules-ta');if(ta)ta.value='';
	},

	uploadFiles:function(){
		var self=this;
		var u1=$('qos-up-cfg'),u2=$('qos-up-rules');
		var f1=u1&&u1.files[0],f2=u2&&u2.files[0];
		if(!f1&&!f2){notify('No files selected.','warning');return;}
		if(!confirm('Upload and overwrite config files? qosify will restart.'))return;

		function readFile(f){
			return new Promise(function(res,rej){
				if(f.size<1)return rej('Empty file');
				if(f.size>65536)return rej('File too large (max 64KB)');
				var r=new FileReader();
				r.onload=function(){res(r.result);};
				r.onerror=function(){rej('Read error');};
				r.readAsText(f);
			});
		}
		function validateUci(d){
			if(/\x00/.test(d))return 'Binary content rejected';
			if(!/(^|\n)config /.test(d))return 'No valid UCI config stanzas';
			return null;
		}
		function validateRules(d){
			if(/\x00/.test(d))return 'Binary content rejected';
			var lines=d.split('\n');
			for(var i=0;i<lines.length;i++){
				var l=trim(lines[i]);
				if(l&&l.charAt(0)!=='#'&&!/^\S+\s+\S/.test(l))return 'Invalid rule line: '+l.slice(0,40);
			}
			return null;
		}

		ui.showModal('Uploading',[E('p',{},'Reading and validating files...')]);
		var ops=[],names=[],errs=[];
		if(f1)ops.push(readFile(f1).then(function(d){
			var e=validateUci(d);
			if(e){errs.push('Config: '+e);return null;}
			return fs.write(UCI_PATH,d).then(function(){names.push('/etc/config/qosify');});
		},function(e){errs.push('Config: '+e);}));
		if(f2)ops.push(readFile(f2).then(function(d){
			var e=validateRules(d);
			if(e){errs.push('Rules: '+e);return null;}
			return fs.write(RULES_PATH,d).then(function(){names.push('00-defaults.conf');});
		},function(e){errs.push('Rules: '+e);}));

		return Promise.all(ops).then(function(){
			if(names.length===0){
				ui.hideModal();
				notify('Upload error: '+errs.join('; '),'danger');
				return;
			}
			return callInit('qosify','restart').then(function(){
				return self.waitForRunning(4000);
			}).then(function(){
				ui.hideModal();
				var msg=names.join(' & ')+' uploaded, qosify restarted.';
				if(errs.length)msg+=' Errors: '+errs.join('; ');
				notify(msg,errs.length?'warning':'info');
				if(u1)u1.value='';if(u2)u2.value='';
				return self.refreshAll();
			});
		}).catch(function(e){
			ui.hideModal();
			notify('Upload failed: '+e,'danger');
		});
	},

	resetDefaults:function(){
		var self=this;
		if(!confirm('Reset qosify config to defaults?'))return;
		ui.showModal('Resetting',[E('p',{},'Restoring defaults...')]);
		return Promise.all([
			fs.read('/usr/share/qosify-luci/qosify'),
			fs.read('/usr/share/qosify-luci/00-defaults.conf')
		]).then(function(t){
			return Promise.all([
				fs.write(UCI_PATH,t[0]),
				fs.write(RULES_PATH,t[1])
			]);
		}).then(function(){
			return callInit('qosify','restart');
		}).then(function(){
			return self.waitForRunning(4000);
		}).then(function(){
			ui.hideModal();
			notify('Reset to defaults, qosify restarted.','info');
			return self.refreshAll();
		}).catch(function(e){
			ui.hideModal();
			notify('Reset failed: '+e,'danger');
		});
	},

	// === Quick Add handlers ===

	qarPlaceholder:function(){
		var t=$('qar-type').value;
		var v=$('qar-val');
		var ph={'tcp:':'e.g. 4500 or 5060-5061','udp:':'e.g. 4500 or 5060-5061','both:':'e.g. 4500 or 5060-5061',
			'dns:':'e.g. *teams* or *.zoom*','dnsr:':'e.g. zoom[0-9]+\\.us','dns_c:':'e.g. *cdn*','dns_cr:':'e.g. cdn[0-9]+',
			'ipv4:':'e.g. 1.1.1.1 or 192.168.1.0/24','ipv6:':'e.g. ff01::1'};
		v.placeholder=ph[t]||'';
	},

	qarAdd:function(){
		var ty=$('qar-type').value;
		var val=trim($('qar-val').value);
		var cls=$('qar-cls').value;
		var pr=$('qar-prio').checked;
		if(!val){alert('Enter a value.');return;}
		if(!cls){alert('No classes defined. Add classes in the Config tab first.');return;}
		var pt=(ty==='tcp:'||ty==='udp:'||ty==='both:');
		if(pt&&!/^\d+(-\d+)?$/.test(val)){alert('Port must be a number or range (e.g. 4500 or 5060-5061).');return;}
		if(pt){
			var pp=val.split('-');
			for(var j=0;j<pp.length;j++){var n=parseInt(pp[j]);if(n<1||n>65535){alert('Port must be 1-65535.');return;}}
		}
		if(ty==='ipv4:'&&!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(val)){alert('Enter a valid IPv4 address.');return;}
		if(ty==='ipv6:'&&!/^[0-9a-fA-F:]+(%[a-zA-Z0-9]+)?(\/\d{1,3})?$/.test(val)){alert('Enter a valid IPv6 address.');return;}
		var pfx=pr?'+':'';
		var ta=$('qos-rules-ta');if(!ta)return;
		var lines=[];
		if(ty==='both:'){lines.push('tcp:'+val+'\t'+pfx+cls);lines.push('udp:'+val+'\t'+pfx+cls);}
		else if(ty==='ipv4:'||ty==='ipv6:')lines.push(val+'\t'+pfx+cls);
		else if(ty==='dnsr:')lines.push('dns:/'+val+'\t'+pfx+cls);
		else if(ty==='dns_cr:')lines.push('dns_c:/'+val+'\t'+pfx+cls);
		else lines.push(ty+val+'\t'+pfx+cls);
		var v=ta.value.replace(/\s+$/,'');
		ta.value=v+(v?'\n':'')+lines.join('\n')+'\n';
		$('qar-val').value='';
		$('qar-prio').checked=false;
		ta.scrollTop=ta.scrollHeight;
	},

	qacSwitch:function(){
		var ty=$('qac-type').value;
		['defaults','class','interface'].forEach(function(x){
			var el=$('qac-opts-'+x);
			if(el)el.style.display=(x===ty)?'flex':'none';
		});
		$('qac-nm-w').style.display=(ty==='defaults')?'none':'';
	},

	qacAdd:function(){
		var ty=$('qac-type').value;
		var ta=$('qos-config-ta');if(!ta)return;
		var nm='';
		if(ty!=='defaults'){
			nm=$('qac-name').value.replace(/[^a-zA-Z0-9_]/g,'');
			if(!nm){alert('Enter a section name (alphanumeric/underscore).');return;}
		}
		var s='\nconfig '+ty+(nm?" '"+nm+"'":'');
		var div=$('qac-opts-'+ty);
		var els=div.querySelectorAll('[data-opt]');
		for(var i=0;i<els.length;i++){
			var v=els[i].value;if(!v)continue;
			var opt=els[i].getAttribute('data-opt');
			var pre=els[i].getAttribute('data-pre')||'option';
			s+="\n\t"+pre+" "+opt+" '"+v+"'";
		}
		var cv=ta.value.replace(/\s+$/,'');
		ta.value=cv+s+'\n';
		if(nm)$('qac-name').value='';
		for(var i=0;i<els.length;i++){
			if(els[i].tagName==='SELECT')els[i].selectedIndex=0;
			else els[i].value=els[i].defaultValue||'';
		}
		ta.scrollTop=ta.scrollHeight;
	},

	// === Refreshers ===

	gatherCtx:function(){
		return Promise.all([
			L.resolveDefault(fs.read(UCI_PATH),''),
			L.resolveDefault(fs.read(RULES_PATH),''),
			L.resolveDefault(fs.stat(UCI_PATH),null),
			L.resolveDefault(fs.stat(RULES_PATH),null),
			L.resolveDefault(fs.exec('/etc/init.d/qosify',['running']),{code:1}),
			L.resolveDefault(fs.exec('/etc/init.d/qosify',['enabled']),{code:1}),
			L.resolveDefault(fs.stat('/usr/sbin/qosify'),null),
			L.resolveDefault(fs.stat('/etc/init.d/qosify'),null),
			L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),{stdout:''})
		]).then(function(d){
			var ctx={
				cfgRaw:d[0]||'',rulesText:d[1]||'',
				cfgStat:d[2],rulesStat:d[3],
				running:d[4].code===0,enabled:d[5].code===0,
				hasBin:d[6]!=null,hasInit:d[7]!=null,
				qstatus:(d[8]&&d[8].stdout)||''
			};
			ctx.active=detectActive(ctx.qstatus);
			return ctx;
		});
	},

	refreshOverview:function(){
		var self=this;
		uci.unload('qosify');
		return uci.load('qosify').then(function(){
			return self.gatherCtx();
		}).then(function(ctx){
			self.fillSect('qos-svc-sect',self.buildSvcSect(ctx));
			self.fillSect('qos-cfg-sect',self.buildCfgSect(ctx));
			self.fillSect('qos-ctl-sect',self.buildCtlSect(ctx));
			var stb=$('qos-st-body');
			if(stb)self.fillStatus(stb,ctx);
			return ctx;
		});
	},

	refreshOverviewFull:function(){
		var self=this;
		return self.refreshOverview().then(function(ctx){
			self.fillSect('qos-qs-sect',self.buildQsSect(ctx));
			return ctx;
		});
	},

	refreshStatus:function(){
		if(this.currentTab!=='st')return;
		var self=this;
		return Promise.all([
			L.resolveDefault(fs.exec('/etc/init.d/qosify',['running']),{code:1}),
			L.resolveDefault(fs.exec('/usr/sbin/qosify-status',[]),{stdout:''})
		]).then(function(d){
			var ctx={running:d[0].code===0,qstatus:(d[1]&&d[1].stdout)||''};
			var stb=$('qos-st-body');
			if(stb)self.fillStatus(stb,ctx);
		});
	},

	refreshAll:function(){
		var self=this;
		return self.refreshOverviewFull().then(function(){
			return Promise.all([
				L.resolveDefault(fs.read(UCI_PATH),''),
				L.resolveDefault(fs.read(RULES_PATH),'')
			]);
		}).then(function(d){
			var c=$('qos-config-ta'),r=$('qos-rules-ta');
			if(c){c.value=d[0]||'';c.dataset.orig=c.value;}
			if(r){r.value=d[1]||'';r.dataset.orig=r.value;}
		});
	}
});
JSEOF
	sed -i "s/__VERSION__/$VERSION/" "$VIEW_DIR/main.js"
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
	/etc/init.d/qosify restart 2>/dev/null
	restart_luci_services
	logger -t qosify-luci "LuCI app installed v$VERSION"
	echo "[OK] qosify LuCI app installed"
	echo "[*] Refresh your browser (Ctrl+F5) to load the new menu."
}

uninstall_all() {
	echo "===== qosify LuCI Uninstaller ====="
	/etc/init.d/qosify stop 2>/dev/null
	/etc/init.d/qosify disable 2>/dev/null
	WAN_DEV=$(uci -q get qosify.wandev.name 2>/dev/null)
	for dev in ${WAN_DEV:-wan} pppoe-wan br-lan; do
		tc qdisc del dev "$dev" clsact 2>/dev/null
	done
	for ifb in $(ip -o link show type ifb 2>/dev/null | awk -F': ' '{print $2}'); do
		ip link set "$ifb" down 2>/dev/null
		ip link delete "$ifb" type ifb 2>/dev/null
	done
	if command -v apk >/dev/null 2>&1; then apk del qosify 2>/dev/null
	elif command -v opkg >/dev/null 2>&1; then opkg remove qosify 2>/dev/null; fi
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	rmdir "$CONFIG_DIR" 2>/dev/null
	rm -rf "$VIEW_DIR" "$TPL_DIR"
	rm -f "$MENU_DIR/luci-app-qosify.json"
	rm -f "$ACL_DIR/luci-app-qosify.json"
	clean_legacy
	restart_luci_services
	logger -t qosify-luci "LuCI app and qosify fully removed"
	echo "[OK] qosify fully uninstalled"
	echo "[*] Refresh your browser (Ctrl+F5) to clear the old menu."
}

case "$1" in
	install) install_all ;;
	uninstall) uninstall_all ;;
	reset) install_templates; install_defaults ;;
	*) echo "Usage: $0 {install|uninstall|reset}" ;;
esac
