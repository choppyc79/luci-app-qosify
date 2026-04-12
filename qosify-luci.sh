#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (ash-compatible)
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/qosify"
CONFIG_DIR="/etc/qosify"
UCI_CONFIG="/etc/config/qosify"
DEFAULTS_FILE="$CONFIG_DIR/00-defaults.conf"
VERSION="1.4"

flush_luci() {
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache \
		/tmp/luci-templatecache /tmp/luci-sessions \
		/tmp/luci-store 2>/dev/null
	if command -v ubus >/dev/null 2>&1; then
		for sid in $(ubus list 2>/dev/null | grep session); do
			ubus call session destroy '{}' 2>/dev/null
		done
	fi
	[ -f /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null
	sleep 1
	if [ -f /etc/init.d/uhttpd ]; then /etc/init.d/uhttpd restart
	elif [ -f /etc/init.d/nginx ]; then /etc/init.d/nginx restart
	fi
}

install_qosify() {
	echo "[*] Checking qosify..."
	if command -v qosify >/dev/null 2>&1; then
		echo "[OK] qosify found"
	else
		echo "[*] Installing qosify..."
		if command -v opkg >/dev/null 2>&1; then opkg update && opkg install qosify
		elif command -v apk >/dev/null 2>&1; then apk update && apk add qosify
		else echo "[ERROR] No supported package manager"; exit 1; fi
	fi
	/etc/init.d/qosify enable 2>/dev/null
	/etc/init.d/qosify start 2>/dev/null
}

install_defaults() {
	echo "[*] Writing default configs..."
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	mkdir -p "$CONFIG_DIR"
	cat > "$DEFAULTS_FILE" << 'EOF'
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
	cat > "$UCI_CONFIG" << 'EOF'
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

install_controller() {
	echo "[*] Setting up controller..."
	mkdir -p "$CTRL_DIR"
	cat > "$CTRL_DIR/qosify.lua" << 'LUAEOF'
module("luci.controller.qosify",package.seeall)
local fs=require"nixio.fs"
local sys=require"luci.sys"
local http=require"luci.http"
local tpl=require"luci.template"
local function r(c) local h=io.popen(c.." 2>&1") local o=h:read("*a")or"" h:close() return(o:gsub("%s+$","")) end
local function u(k) return r("uci -q get qosify.wan."..k) end
local function vf(p,t)
	local s=fs.stat(p,"size")or 0
	if s<1 then return nil,"Empty file" end
	if s>65536 then return nil,"File too large (max 64KB)" end
	local d=fs.readfile(p)or""
	if d:find("%z") then return nil,"Binary file rejected" end
	if t=="uci" then
		if not d:find("\nconfig ") and not d:match("^config ") then return nil,"No valid UCI config stanzas found" end
	elseif t=="def" then
		for l in d:gmatch("[^\n]+") do
			l=l:match("^%s*(.-)%s*$")
			if l~="" and l:sub(1,1)~="#" then
				if not l:match("^%S+%s+%S") then return nil,"Invalid rule line: "..l:sub(1,40) end
			end
		end
	end
	return true
end

function index()
	entry({"admin","network","qosify"},call("act"),"qosify",90)
end

function act()
	local msg
	local fp_u,fp_d
	http.setfilehandler(function(m,c,e)
		if not m or not m.name then return end
		if m.name=="uci_file" then
			if not fp_u and c then fp_u=io.open("/tmp/.qos_up_u","w") end
			if fp_u and c then fp_u:write(c) end
			if fp_u and e then fp_u:close();fp_u=nil end
		elseif m.name=="def_file" then
			if not fp_d and c then fp_d=io.open("/tmp/.qos_up_d","w") end
			if fp_d and c then fp_d:write(c) end
			if fp_d and e then fp_d:close();fp_d=nil end
		end
	end)
	if http.getenv("REQUEST_METHOD")=="POST" then
		local a=http.formvalue("action")
		if a=="start" or a=="stop" or a=="restart" or a=="reload" then
			sys.call("/etc/init.d/qosify "..a.." >/dev/null 2>&1")
			msg="qosify "..a.."ed."
		elseif a=="enable" then
			sys.call("/etc/init.d/qosify enable >/dev/null 2>&1"); msg="Enabled at boot."
		elseif a=="disable" then
			sys.call("/etc/init.d/qosify disable >/dev/null 2>&1"); msg="Disabled at boot."
		elseif a=="save_config" then
			local d=http.formvalue("data")
			if d then fs.writefile("/etc/config/qosify",d:gsub("\r\n","\n"))
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1"); msg="Config saved, qosify restarted." end
		elseif a=="save_rules" then
			local d=http.formvalue("data")
			if d then fs.writefile("/etc/qosify/00-defaults.conf",d:gsub("\r\n","\n"))
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1"); msg="Rules saved, qosify restarted." end
		elseif a=="upload" then
			local did,errs=false,{}
			if fs.access("/tmp/.qos_up_u") then
				local ok,e=vf("/tmp/.qos_up_u","uci")
				if ok then fs.copy("/tmp/.qos_up_u","/etc/config/qosify");did=true
				elseif e then errs[#errs+1]="Config: "..e end
				fs.remove("/tmp/.qos_up_u")
			end
			if fs.access("/tmp/.qos_up_d") then
				local ok,e=vf("/tmp/.qos_up_d","def")
				if ok then fs.copy("/tmp/.qos_up_d","/etc/qosify/00-defaults.conf");did=true
				elseif e then errs[#errs+1]="Rules: "..e end
				fs.remove("/tmp/.qos_up_d")
			end
			if did then sys.call("/etc/init.d/qosify restart >/dev/null 2>&1") end
			if #errs>0 then msg="Upload error: "..table.concat(errs,"; ")
			elseif did then msg="Uploaded, qosify restarted."
			else msg="No valid files received." end
		elseif a=="reset" then
			sys.call("/bin/sh /root/qosify-luci.sh reset >/dev/null 2>&1")
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1"); msg="Reset to defaults, qosify restarted."
		end
	end
	local running=(sys.call("/etc/init.d/qosify running >/dev/null 2>&1")==0)
	if not running then running=(sys.call("pgrep -x qosify >/dev/null 2>&1")==0) end
	local enabled=(sys.call("/etc/init.d/qosify enabled 2>/dev/null")==0)
	local has_bin=fs.access("/usr/sbin/qosify")or(sys.call("which qosify >/dev/null 2>&1")==0)
	local has_uci=fs.access("/etc/config/qosify")
	local has_def=fs.access("/etc/qosify/00-defaults.conf")
	local has_init=fs.access("/etc/init.d/qosify")
	local num_rules=0
	if has_def then num_rules=tonumber(r("grep -c '^[^#]' /etc/qosify/00-defaults.conf 2>/dev/null"))or 0 end
	local status_out=""
	if running then status_out=r("qosify-status 2>/dev/null") end
	tpl.render("qosify/main",{
		msg=msg,running=running,enabled=enabled,
		has_bin=has_bin,has_uci=has_uci,has_def=has_def,has_init=has_init,
		wan_iface=u("name"),bw_up=u("bandwidth_up"),bw_down=u("bandwidth_down"),
		mode=u("mode"),wan_dis=(u("disabled")=="1"),
		overhead=u("overhead_type"),autorate=u("autorate_ingress"),
		ingress=u("ingress"),egress=u("egress"),
		wan_nat=u("nat"),host_iso=u("host_isolate"),
		ing_opts=u("ingress_options"),egr_opts=u("egress_options"),opts=u("options"),
		num_rules=num_rules,status_out=status_out,
		cfg_content=fs.readfile("/etc/config/qosify")or"",
		def_content=fs.readfile("/etc/qosify/00-defaults.conf")or"",
		ver="__VERSION__"
	})
end
LUAEOF
	sed -i "s/__VERSION__/$VERSION/" "$CTRL_DIR/qosify.lua"
}

install_views() {
	echo "[*] Setting up views..."
	mkdir -p "$VIEW_DIR"
	cat > "$VIEW_DIR/main.htm" << 'HTMEOF'
<%+header%>
<style>
.qos-badge{display:inline-block;padding:2px 10px;border-radius:3px;font-size:12px;font-weight:bold;color:#fff}
.qos-green{background:#4caf50}.qos-red{background:#e53935}.qos-ok{color:#4caf50}.qos-err{color:#e53935}
.qos-tab{display:none}.qos-tab.active{display:block}
.qos-kv td{padding:7px 12px;border-bottom:1px solid #eee}
.qos-kv td:first-child{font-weight:bold;color:#888;width:200px}
.qos-kv tr:last-child td{border-bottom:none}
.qos-svc form{display:inline-block;margin:0 3px 3px 0}
.qos-btn-en{background:transparent !important;border:2px solid #4caf50 !important;color:#4caf50 !important;font-weight:bold}
.qos-btn-en:hover{background:#4caf50 !important;color:#fff !important}
.qos-btn-dis{background:transparent !important;border:2px solid #e53935 !important;color:#e53935 !important;font-weight:bold}
.qos-btn-dis:hover{background:#e53935 !important;color:#fff !important}
.qos-msg{padding:10px 15px;border-radius:4px;font-weight:bold;margin:8px 0}
.qos-msg-ok{background:#2e7d32;color:#fff;border:1px solid #1b5e20}
.qos-msg-err{background:#c62828;color:#fff;border:1px solid #b71c1c}
</style>
<div class="cbi-map" id="qos-app">
<h2>qosify</h2>
<div class="cbi-map-descr">Traffic shaping and DSCP classification via qosify</div>
<% if msg then %><div class="qos-msg <%= msg:find('^Upload error') and 'qos-msg-err' or 'qos-msg-ok' %>" id="qos-msg"><%=pcdata(msg)%></div><% end %>
<ul class="cbi-tabmenu">
<li class="cbi-tab" id="th-ov"><a href="#" onclick="qT('ov');return false">Overview</a></li>
<li class="cbi-tab-disabled" id="th-cf"><a href="#" onclick="qT('cf');return false">Config</a></li>
<li class="cbi-tab-disabled" id="th-ru"><a href="#" onclick="qT('ru');return false">Classification Rules</a></li>
<li class="cbi-tab-disabled" id="th-ad"><a href="#" onclick="qT('ad');return false">Advanced</a></li>
<li class="cbi-tab-disabled" id="th-st"><a href="#" onclick="qT('st');return false">Status</a></li>
</ul>

<div id="qos-ov" class="qos-tab active">
<fieldset class="cbi-section">
<legend>Service Status</legend>
<table class="qos-kv" width="100%">
<tr><td>Package</td><td><% if has_bin then %><span class="qos-ok">&#x2714; Installed</span><% else %><span class="qos-err">&#x2718; Not installed</span><% end %></td></tr>
<tr><td>Init Script</td><td><% if has_init then %><span class="qos-ok">&#x2714; Available</span><% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>Autostart</td><td><% if enabled then %><span class="qos-badge qos-green">Enabled</span><% else %><span class="qos-badge qos-red">Disabled</span><% end %></td></tr>
<tr><td>Status</td><td><% if running then %><span class="qos-badge qos-green">Running</span><% else %><span class="qos-badge qos-red">Not Running</span><% end %></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Interface Configuration</legend>
<table class="qos-kv" width="100%">
<tr><td>WAN Interface</td><td><strong><%=pcdata(wan_iface)%></strong>
<% if wan_dis then %><span class="qos-badge qos-red" style="margin-left:8px">QoS Disabled</span>
<% else %><span class="qos-badge qos-green" style="margin-left:8px">QoS Active</span><% end %></td></tr>
<tr><td>Bandwidth Up</td><td><%=pcdata(bw_up)%></td></tr>
<tr><td>Bandwidth Down</td><td><%=pcdata(bw_down)%></td></tr>
<tr><td>Overhead Type</td><td><%=pcdata(overhead)%></td></tr>
<tr><td>Autorate Ingress</td><td><%=pcdata(autorate)%></td></tr>
<tr><td>Ingress</td><td><%=pcdata(ingress)%></td></tr>
<tr><td>Egress</td><td><%=pcdata(egress)%></td></tr>
<tr><td>Queue Mode</td><td><%=pcdata(mode)%></td></tr>
<tr><td>NAT</td><td><%=pcdata(wan_nat)%></td></tr>
<tr><td>Host Isolate</td><td><%=pcdata(host_iso)%></td></tr>
<tr><td>Ingress Options</td><td><%=pcdata(ing_opts)%></td></tr>
<tr><td>Egress Options</td><td><%=pcdata(egr_opts)%></td></tr>
<tr><td>Options</td><td><%=pcdata(opts)%></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Configuration Files</legend>
<table class="qos-kv" width="100%">
<tr><td>/etc/config/qosify</td><td><% if has_uci then %><span class="qos-ok">&#x2714; Found</span><% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>/etc/qosify/00-defaults.conf</td><td><% if has_def then %><span class="qos-ok">&#x2714; Found</span>
<% if num_rules and num_rules>0 then %><span style="color:#aaa;margin-left:8px;font-size:12px">(<%=num_rules%> active rules)</span><% end %>
<% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Service Controls</legend>
<div class="qos-svc">
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="<%= enabled and 'disable' or 'enable' %>"/>
<input class="cbi-button <%= enabled and 'qos-btn-en' or 'qos-btn-dis' %>" type="submit"
 value="<%= enabled and 'Enabled' or 'Disabled' %>"
 title="<%= enabled and 'Click to disable autostart' or 'Click to enable autostart' %>"/>
</form>
<% local btns={"start","stop","restart","reload"} for _,a in ipairs(btns) do %>
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="<%=a%>"/>
<input class="cbi-button cbi-button-<%= (a=='stop') and 'reset' or 'apply' %>" type="submit" value="<%=a:sub(1,1):upper()..a:sub(2)%>"/>
</form>
<% end %>
</div>
</fieldset>
</div>

<div id="qos-cf" class="qos-tab">
<fieldset class="cbi-section">
<legend>Config</legend>
<div class="cbi-section-descr">UCI configuration &mdash; classes, interfaces, defaults. <code>/etc/config/qosify</code></div>
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_config"/>
<textarea name="data" rows="28" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px"><%=pcdata(cfg_content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply"/>
</div>
</form>
</fieldset>
</div>

<div id="qos-ru" class="qos-tab">
<fieldset class="cbi-section">
<legend>Classification Rules</legend>
<div class="cbi-section-descr">DSCP mapping rules loaded by qosify on startup. <code>/etc/qosify/00-defaults.conf</code></div>
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_rules"/>
<textarea name="data" rows="28" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px"><%=pcdata(def_content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply"/>
</div>
</form>
</fieldset>
</div>

<div id="qos-ad" class="qos-tab">
<fieldset class="cbi-section">
<legend>Upload Config Files</legend>
<div class="cbi-section-descr">Select files and click Save &amp; Apply to overwrite and restart qosify.</div>
<form method="post" enctype="multipart/form-data" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="upload"/>
<div class="cbi-value">
<label class="cbi-value-title">/etc/config/qosify</label>
<div class="cbi-value-field"><input type="file" name="uci_file" accept=".conf,text/plain"/></div>
</div>
<div class="cbi-value">
<label class="cbi-value-title">/etc/qosify/00-defaults.conf</label>
<div class="cbi-value-field"><input type="file" name="def_file" accept=".conf,text/plain"/></div>
</div>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply"/>
</div>
</form>
</fieldset>
<fieldset class="cbi-section">
<legend>Reset to qosify Defaults</legend>
<div class="cbi-section-descr">Replaces both config files with qosify defaults, qosify will be disabled.</div>
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="reset"/>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-negative" type="submit" value="Reset to Defaults" onclick="return confirm('Reset qosify config to defaults?')"/>
</div>
</form>
</fieldset>
</div>

<div id="qos-st" class="qos-tab">
<fieldset class="cbi-section">
<legend>qosify-status</legend>
<% if not running then %>
<div class="alert-message warning">qosify is not running. Start from the Overview tab.</div>
<% elseif status_out=="" then %>
<p style="color:#888"><em>qosify-status returned no output.</em></p>
<% else %>
<pre style="background:#1e1e1e;color:#e0e0e0;padding:12px;border:1px solid #333;border-radius:4px;overflow-x:auto;font-size:12px;line-height:1.5;white-space:pre-wrap"><%=pcdata(status_out)%></pre>
<% end %>
</fieldset>
</div>

<div style="margin:8px 0 0">
<span style="color:#888;font-size:12px">luci-app-qosify v<%=pcdata(ver)%></span>
<span style="float:right;color:#888;font-size:11px;display:none" id="qos-rf">Auto-refresh in <span id="qos-cd">5</span>s</span>
</div>
</div>

<script type="text/javascript">//<![CDATA[
(function(){
var tabs=['ov','cf','ru','ad','st'],
	names=['overview','config','rules','advanced','status'],
	cur='ov',tmr;
function qT(t){
	cur=t;
	for(var i=0;i<tabs.length;i++){
		var el=document.getElementById('qos-'+tabs[i]);
		var th=document.getElementById('th-'+tabs[i]);
		if(tabs[i]===t){el.className='qos-tab active';th.className='cbi-tab';}
		else{el.className='qos-tab';th.className='cbi-tab-disabled';}
	}
	var rf=document.getElementById('qos-rf');
	if(rf)rf.style.display=(t==='st')?'':'none';
	location.hash=names[tabs.indexOf(t)];
	clearTimeout(tmr);
	if(t==='st')startR();
}
function startR(){
	var c=5;
	(function tick(){
		var el=document.getElementById('qos-cd');
		if(el)el.textContent=c;
		if(c<=0)doR();
		else{c--;tmr=setTimeout(tick,1000);}
	})();
}
function doR(){
	var x=new XMLHttpRequest();
	x.open('GET',location.href.split('#')[0],true);
	x.onload=function(){
		if(x.status===200){
			var d=document.createElement('div');d.innerHTML=x.responseText;
			var n=d.querySelector('#qos-st');
			var o=document.getElementById('qos-st');
			if(n&&o){o.innerHTML=n.innerHTML;if(cur==='st')startR();}
			else location.href='/cgi-bin/luci/';
		}else location.href='/cgi-bin/luci/';
	};
	x.onerror=function(){location.href='/cgi-bin/luci/';};
	x.send();
}
document.addEventListener('submit',function(e){
	var f=e.target;if(f.tagName==='FORM'){
	var h=location.hash;if(h)f.action=f.action.split('#')[0]+h;}
});
var h=location.hash.slice(1),idx=names.indexOf(h);
if(idx>=0)qT(tabs[idx]);
var m=document.getElementById('qos-msg');
if(m)setTimeout(function(){window.location=location.pathname+location.hash;},5000);
window.qT=qT;
})();
//]]></script>
<%+footer%>
HTMEOF
}

install_all() {
	echo "===== qosify LuCI Installer v$VERSION ====="
	install_qosify
	install_controller
	install_views
	install_defaults
	/etc/init.d/qosify restart 2>/dev/null
	flush_luci
	logger -t qosify-luci "LuCI app installed v$VERSION"
	echo "[OK] qosify LuCI app installed"
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
	rm -f "$CTRL_DIR/qosify.lua"
	rm -rf /usr/lib/lua/luci/model/cbi/qosify "$VIEW_DIR"
	flush_luci
	logger -t qosify-luci "LuCI app and qosify fully removed"
	echo "[OK] qosify fully uninstalled"
}

case "$1" in
	install) install_all ;;
	uninstall) uninstall_all ;;
	reset) install_defaults ;;
	*) echo "Usage: $0 {install|uninstall|reset}" ;;
esac