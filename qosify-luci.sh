#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (ash-compatible)
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/qosify"
CONFIG_DIR="/etc/qosify"
UCI_CONFIG="/etc/config/qosify"
DEFAULTS_FILE="$CONFIG_DIR/00-defaults.conf"
VERSION="2.0"

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
		elseif a=="save_quick" then
			local bwu=(http.formvalue("bw_up")or""):lower():gsub("[^%d%a]","")
			local bwd=(http.formvalue("bw_down")or""):lower():gsub("[^%d%a]","")
			local dis=http.formvalue("qos_enabled") and "0" or "1"
			local ovh=http.formvalue("overhead")or""
			local mod=http.formvalue("mode")or""
			local ing=http.formvalue("q_ingress") and "1" or "0"
			local egr=http.formvalue("q_egress") and "1" or "0"
			local nat=http.formvalue("q_nat") and "1" or "0"
			local hiso=http.formvalue("q_host_isolate") and "1" or "0"
			local arate=http.formvalue("q_autorate") and "1" or "0"
			local iopts=(http.formvalue("q_ing_opts")or""):gsub("[^%w%s%-%.]",""):gsub("^%s+",""):gsub("%s+$","")
			local eopts=(http.formvalue("q_egr_opts")or""):gsub("[^%w%s%-%.]",""):gsub("^%s+",""):gsub("%s+$","")
			local gopts=(http.formvalue("q_opts")or""):gsub("[^%w%s%-%.]",""):gsub("^%s+",""):gsub("%s+$","")
			local ovh_ok={none=1,ethernet=1,docsis=1,atm=1,pppoa=1,pppoe=1}
			local mod_ok={diffserv3=1,diffserv4=1,diffserv8=1}
			local errs={}
			if iopts~="" and not iopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Ingress Options" end
			if eopts~="" and not eopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Egress Options" end
			if gopts~="" and not gopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Options" end
			if #errs>0 then
				msg="Error: invalid characters in "..table.concat(errs,", ")..". Use alphanumeric, spaces, hyphens, dots only."
			else
				local cmds={"uci set qosify.wan.disabled='"..dis.."'"}
				if bwu:match("^%d+[kmg]?bit$") then cmds[#cmds+1]="uci set qosify.wan.bandwidth_up='"..bwu.."'" end
				if bwd:match("^%d+[kmg]?bit$") then cmds[#cmds+1]="uci set qosify.wan.bandwidth_down='"..bwd.."'" end
				if ovh_ok[ovh] then
					cmds[#cmds+1]="uci set qosify.wan.overhead_type='"..ovh.."'"
					cmds[#cmds+1]="(uci -q delete qosify.wan.overhead || true)"
				end
				if mod_ok[mod] then cmds[#cmds+1]="uci set qosify.wan.mode='"..mod.."'" end
				cmds[#cmds+1]="uci set qosify.wan.ingress='"..ing.."'"
				cmds[#cmds+1]="uci set qosify.wan.egress='"..egr.."'"
				cmds[#cmds+1]="uci set qosify.wan.nat='"..nat.."'"
				cmds[#cmds+1]="uci set qosify.wan.host_isolate='"..hiso.."'"
				cmds[#cmds+1]="uci set qosify.wan.autorate_ingress='"..arate.."'"
				cmds[#cmds+1]="uci set qosify.wan.ingress_options='"..iopts.."'"
				cmds[#cmds+1]="uci set qosify.wan.egress_options='"..eopts.."'"
				cmds[#cmds+1]="uci set qosify.wan.options='"..gopts.."'"
				cmds[#cmds+1]="(uci -q delete qosify.wan.option || true)"
				cmds[#cmds+1]="uci commit qosify"
				sys.call(table.concat(cmds," && ").." >/dev/null 2>&1")
				sys.call("/etc/init.d/qosify restart >/dev/null 2>&1")
				msg="Settings saved, qosify restarted."
			end
		elseif a=="upload" then
			local did_u,did_d,errs=false,false,{}
			if fs.access("/tmp/.qos_up_u") then
				local ok,e=vf("/tmp/.qos_up_u","uci")
				if ok then fs.copy("/tmp/.qos_up_u","/etc/config/qosify");did_u=true
				elseif e then errs[#errs+1]="Config: "..e end
				fs.remove("/tmp/.qos_up_u")
			end
			if fs.access("/tmp/.qos_up_d") then
				local ok,e=vf("/tmp/.qos_up_d","def")
				if ok then fs.copy("/tmp/.qos_up_d","/etc/qosify/00-defaults.conf");did_d=true
				elseif e then errs[#errs+1]="Rules: "..e end
				fs.remove("/tmp/.qos_up_d")
			end
			local did=did_u or did_d
			if did then sys.call("/etc/init.d/qosify restart >/dev/null 2>&1") end
			local names={}
			if did_u then names[#names+1]="/etc/config/qosify" end
			if did_d then names[#names+1]="00-defaults.conf" end
			if #errs>0 and did then msg=table.concat(names," & ").." applied. Errors: "..table.concat(errs,"; ")..". qosify restarted."
			elseif #errs>0 then msg="Upload error: "..table.concat(errs,"; ")
			elseif did then msg=table.concat(names," & ").." uploaded, qosify restarted."
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
	local active=false
	if running then
		status_out=r("qosify-status 2>/dev/null")
		active=(status_out:find(": active")~=nil)
	end
	local uci_ok=false
	if has_uci then
		local d=fs.readfile("/etc/config/qosify")or""
		uci_ok=(#d>10 and (d:find("\nconfig ") or d:match("^config "))~=nil)
	end
	local def_ok=(has_def and num_rules>0)
	local uci_st=has_uci and fs.stat("/etc/config/qosify") or nil
	local def_st=has_def and fs.stat("/etc/qosify/00-defaults.conf") or nil
	local uci_sz=uci_st and uci_st.size or 0
	local def_sz=def_st and def_st.size or 0
	local uci_mod=uci_st and os.date("%Y-%m-%d %H:%M",uci_st.mtime) or ""
	local def_mod=def_st and os.date("%Y-%m-%d %H:%M",def_st.mtime) or ""
	local classes={}
	local cfg_raw=fs.readfile("/etc/config/qosify")or""
	local skip={}
	local dt=r("uci -q get qosify.@defaults[0].dscp_default_tcp")
	local du=r("uci -q get qosify.@defaults[0].dscp_default_udp")
	if dt~="" then skip[dt]=true end
	if du~="" then skip[du]=true end
	for c in cfg_raw:gmatch("config%s+class%s+'?([%w_]+)'?") do
		if not skip[c] then
			local ci=r("uci -q get qosify."..c..".ingress")
			local ce=r("uci -q get qosify."..c..".egress")
			classes[#classes+1]={name=c,ingress=ci,egress=ce}
		end
	end
	local ovh_v=u("overhead_type") if ovh_v=="" then ovh_v=u("overhead") end
	local wo=u("options") if wo=="" then wo=u("option") end
	tpl.render("qosify/main",{
		msg=msg,running=running,enabled=enabled,active=active,
		has_bin=has_bin,has_uci=has_uci,has_def=has_def,has_init=has_init,
		uci_ok=uci_ok,def_ok=def_ok,classes=classes,
		uci_sz=uci_sz,def_sz=def_sz,uci_mod=uci_mod,def_mod=def_mod,
		wan_iface=u("name"),bw_up=u("bandwidth_up"),bw_down=u("bandwidth_down"),
		mode=u("mode"),wan_dis=(u("disabled")=="1"),
		overhead=ovh_v,autorate=u("autorate_ingress"),
		ingress=u("ingress"),egress=u("egress"),
		wan_nat=u("nat"),host_iso=u("host_isolate"),
		ing_opts=u("ingress_options"),egr_opts=u("egress_options"),wan_opts=wo,
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
.qos-green{background:#4caf50}.qos-red{background:#e53935}.qos-amber{background:#ff9800}.qos-ok{color:#4caf50}.qos-err{color:#e53935}.qos-warn{color:#ff9800}
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
<% if msg then %><div class="qos-msg <%= msg:lower():find('error') and 'qos-msg-err' or 'qos-msg-ok' %>" id="qos-msg"><%=pcdata(msg)%></div><% end %>
<ul class="cbi-tabmenu">
<li class="cbi-tab" id="th-ov"><a href="#" onclick="qT('ov');return false">Overview</a></li>
<li class="cbi-tab-disabled" id="th-cf"><a href="#" onclick="qT('cf');return false">Config</a></li>
<li class="cbi-tab-disabled" id="th-ru"><a href="#" onclick="qT('ru');return false">Classification Rules</a></li>
<li class="cbi-tab-disabled" id="th-ad"><a href="#" onclick="qT('ad');return false">Advanced</a></li>
<li class="cbi-tab-disabled" id="th-st"><a href="#" onclick="qT('st');return false">Status</a></li>
</ul>

<div id="qos-ov" class="qos-tab active">
<fieldset class="cbi-section" id="qos-svc-sect">
<legend>Service Status</legend>
<table class="qos-kv" width="100%" id="qos-svc-tbl">
<tr><td>Package</td><td><% if has_bin then %><span class="qos-ok">&#x2714; Installed</span><% else %><span class="qos-err">&#x2718; Not installed</span><% end %></td></tr>
<tr><td>Init Script</td><td><% if has_init then %><span class="qos-ok">&#x2714; Available</span><% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>Autostart</td><td><% if enabled then %><span class="qos-badge qos-green">Enabled</span><% else %><span class="qos-badge qos-red">Disabled</span><% end %></td></tr>
<tr><td>Running</td><td><% if running then %><span class="qos-badge qos-green">Running</span><% else %><span class="qos-badge qos-red">Not Running</span><% end %></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Quick Settings</legend>
<div class="cbi-section-descr">Common WAN settings &mdash; edit and apply without touching raw config.</div>
<form method="post" action="<%=REQUEST_URI%>" id="qos-quick-form">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_quick"/>
<table class="qos-kv" width="100%">
<tr><td>QoS Enabled</td><td><input type="checkbox" name="qos_enabled" value="1"<%= wan_dis and '' or ' checked="checked"' %>/>
<% if active then %><span class="qos-badge qos-green" style="margin-left:8px">Active</span>
<% elseif not wan_dis then %><span class="qos-badge qos-amber" style="margin-left:8px">Enabled &mdash; Not Active</span>
<% else %><span class="qos-badge qos-red" style="margin-left:8px">Disabled</span><% end %></td></tr>
<tr><td>Bandwidth Up</td><td><input type="text" name="bw_up" value="<%=pcdata(bw_up)%>" style="width:140px;font-family:monospace" placeholder="e.g. 100mbit"/></td></tr>
<tr><td>Bandwidth Down</td><td><input type="text" name="bw_down" value="<%=pcdata(bw_down)%>" style="width:140px;font-family:monospace" placeholder="e.g. 100mbit"/></td></tr>
<tr><td>Overhead Type</td><td><select name="overhead" style="width:148px">
<% local ovh_list={"none","ethernet","docsis","atm","pppoa","pppoe"}
for _,v in ipairs(ovh_list) do %><option value="<%=v%>"<%= (overhead==v) and ' selected="selected"' or '' %>><%=v%></option>
<% end %></select></td></tr>
<tr><td>Queue Mode</td><td><select name="mode" style="width:148px">
<% local mod_list={"diffserv3","diffserv4","diffserv8"}
for _,v in ipairs(mod_list) do %><option value="<%=v%>"<%= (mode==v) and ' selected="selected"' or '' %>><%=v%></option>
<% end %></select></td></tr>
<tr><td>Ingress</td><td><input type="checkbox" name="q_ingress" value="1"<%= (ingress=="1") and ' checked="checked"' or '' %>/></td></tr>
<tr><td>Egress</td><td><input type="checkbox" name="q_egress" value="1"<%= (egress=="1") and ' checked="checked"' or '' %>/></td></tr>
<tr><td>NAT</td><td><input type="checkbox" name="q_nat" value="1"<%= (wan_nat=="1") and ' checked="checked"' or '' %>/></td></tr>
<tr><td>Host Isolate</td><td><input type="checkbox" name="q_host_isolate" value="1"<%= (host_iso=="1") and ' checked="checked"' or '' %>/></td></tr>
<tr><td>Autorate Ingress</td><td><input type="checkbox" name="q_autorate" value="1"<%= (autorate=="1") and ' checked="checked"' or '' %>/></td></tr>
<tr><td>Ingress Options</td><td><input type="text" name="q_ing_opts" value="<%=pcdata(ing_opts)%>" style="width:100%;max-width:400px;font-family:monospace" placeholder="e.g. triple-isolate memlimit 32mb"/></td></tr>
<tr><td>Egress Options</td><td><input type="text" name="q_egr_opts" value="<%=pcdata(egr_opts)%>" style="width:100%;max-width:400px;font-family:monospace" placeholder="e.g. triple-isolate memlimit 32mb wash"/></td></tr>
<tr><td>Options</td><td><input type="text" name="q_opts" value="<%=pcdata(wan_opts)%>" style="width:100%;max-width:400px;font-family:monospace" placeholder="e.g. overhead 44 mpu 84"/></td></tr>
</table>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply" onclick="return confirm('Save settings and restart qosify?')"/>
</div>
</form>
</fieldset>
<fieldset class="cbi-section" id="qos-cfg-sect">
<legend>Configuration Files</legend>
<table class="qos-kv" width="100%">
<tr><td>/etc/config/qosify</td><td><% if uci_ok then %><span class="qos-ok">&#x2714; Valid</span>
<span style="color:#aaa;margin-left:8px;font-size:12px">(<%=uci_sz%>B, <%=uci_mod%>)</span>
<% elseif has_uci then %><span class="qos-warn">&#x26a0; Found (empty or invalid)</span>
<span style="color:#aaa;margin-left:8px;font-size:12px">(<%=uci_sz%>B, <%=uci_mod%>)</span>
<% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>/etc/qosify/00-defaults.conf</td><td><% if def_ok then %><span class="qos-ok">&#x2714; Valid</span>
<span style="color:#aaa;margin-left:8px;font-size:12px">(<%=num_rules%> rules, <%=def_sz%>B, <%=def_mod%>)</span>
<% elseif has_def then %><span class="qos-warn">&#x26a0; Found (empty or no rules)</span>
<span style="color:#aaa;margin-left:8px;font-size:12px">(<%=def_sz%>B, <%=def_mod%>)</span>
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
<form method="post" action="<%=REQUEST_URI%>" id="qos-config-form">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_config"/>
<textarea name="data" id="qos-config-ta" rows="28" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px"><%=pcdata(cfg_content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply" onclick="return confirm('Save config and restart qosify?')"/>
</div>
</form>
</fieldset>
</div>

<div id="qos-ru" class="qos-tab">
<fieldset class="cbi-section">
<legend>Classification Rules</legend>
<div class="cbi-section-descr">DSCP mapping rules loaded by qosify on startup. <code>/etc/qosify/00-defaults.conf</code></div>
<details style="margin:0 0 10px;padding:6px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a">
<summary style="cursor:pointer;font-weight:bold;font-size:13px;color:#aaa">DSCP Class Reference</summary>
<table class="qos-kv" style="margin:6px 0 0" width="100%">
<% if classes and #classes>0 then for _,cl in ipairs(classes) do %>
<tr><td style="width:120px"><%=pcdata(cl.name)%></td><td>Ingress: <strong><%=pcdata(cl.ingress)%></strong> / Egress: <strong><%=pcdata(cl.egress)%></strong></td></tr>
<% end else %>
<tr><td colspan="2" style="color:#888"><em>No classes defined in /etc/config/qosify</em></td></tr>
<% end %>
</table>
<div style="color:#888;font-size:11px;margin:6px 0 2px">Prefix with <code>+</code> to flag as priority within class. Ports: <code>tcp:443</code>, <code>udp:3074</code>, ranges: <code>tcp:5060-5061</code>. DNS: <code>dns:*teams*</code>, <code>dns:*.zoom*</code></div>
</details>
<div style="margin:0 0 8px;padding:8px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a">
<strong style="font-size:13px;color:#aaa">Quick Add Rule</strong>
<div style="display:flex;gap:6px;align-items:center;margin:6px 0 0;flex-wrap:wrap">
<select id="qar-type" style="width:130px" onchange="document.getElementById('qar-val').placeholder=this.value==='dns:'?'e.g. *teams* or *.zoom*':'e.g. 4500 or 5060-5061'">
<option value="tcp:">tcp port</option>
<option value="udp:">udp port</option>
<option value="both:">tcp+udp port</option>
<option value="dns:">dns pattern</option>
</select>
<input id="qar-val" type="text" placeholder="e.g. 4500 or 5060-5061" style="width:160px;font-family:monospace"/>
<select id="qar-cls" style="width:140px">
<% if classes then for _,cl in ipairs(classes) do %>
<option value="<%=pcdata(cl.name)%>"><%=pcdata(cl.name)%></option>
<% end end %>
</select>
<label style="font-size:12px;color:#aaa;white-space:nowrap"><input type="checkbox" id="qar-prio"/> priority (+)</label>
<input class="cbi-button cbi-button-add" type="button" value="Add" onclick="qAR()"/>
</div>
</div>
<form method="post" action="<%=REQUEST_URI%>" id="qos-rules-form">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_rules"/>
<textarea name="data" id="qos-rules-ta" rows="28" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px"><%=pcdata(def_content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply" onclick="return confirm('Save rules and restart qosify?')"/>
</div>
</form>
</fieldset>
</div>

<div id="qos-ad" class="qos-tab">
<fieldset class="cbi-section">
<legend>Backup Current Files</legend>
<div class="cbi-section-descr">Download current config files before making changes.</div>
<div class="cbi-value">
<label class="cbi-value-title">/etc/config/qosify</label>
<div class="cbi-value-field"><input class="cbi-button cbi-button-action" type="button" value="Download" onclick="qDl('cfg_bk','qosify')"/></div>
</div>
<div class="cbi-value">
<label class="cbi-value-title">/etc/qosify/00-defaults.conf</label>
<div class="cbi-value-field"><input class="cbi-button cbi-button-action" type="button" value="Download" onclick="qDl('def_bk','00-defaults.conf')"/></div>
</div>
<textarea id="cfg_bk" style="display:none"><%=pcdata(cfg_content)%></textarea>
<textarea id="def_bk" style="display:none"><%=pcdata(def_content)%></textarea>
</fieldset>
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
<input class="cbi-button cbi-button-apply" type="submit" value="Save &amp; Apply" onclick="return confirm('Upload and overwrite config files? qosify will restart.')"/>
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
<span style="float:right;color:#888;font-size:11px;display:none" id="qos-rf"><span id="qos-rf-txt">Auto-refresh in <span id="qos-cd">5</span>s</span></span>
</div>
</div>

<script type="text/javascript">//<![CDATA[
(function(){
var tabs=['ov','cf','ru','ad','st'],
	names=['overview','config','rules','advanced','status'],
	cur='ov',tmr,otmr,dirty=false;
var cta=document.getElementById('qos-config-ta');
var rta=document.getElementById('qos-rules-ta');
if(cta)cta.dataset.orig=cta.value;
if(rta)rta.dataset.orig=rta.value;
function chkD(){
	dirty=(cta&&cta.value!==cta.dataset.orig)||(rta&&rta.value!==rta.dataset.orig);
}
if(cta)cta.addEventListener('input',chkD);
if(rta)rta.addEventListener('input',chkD);
window.addEventListener('beforeunload',function(e){if(dirty){e.preventDefault();e.returnValue='';}});
function qT(t){
	if(dirty&&(cur==='cf'||cur==='ru')&&t!==cur){
		if(!confirm('You have unsaved changes. Leave this tab?'))return;
	}
	cur=t;
	for(var i=0;i<tabs.length;i++){
		var el=document.getElementById('qos-'+tabs[i]);
		var th=document.getElementById('th-'+tabs[i]);
		if(tabs[i]===t){el.className='qos-tab active';th.className='cbi-tab';}
		else{el.className='qos-tab';th.className='cbi-tab-disabled';}
	}
	var rf=document.getElementById('qos-rf');
	if(rf)rf.style.display=(t==='st'||t==='ov')?'':'none';
	location.hash=names[tabs.indexOf(t)];
	clearTimeout(tmr);clearTimeout(otmr);
	if(t==='st')startR();
	if(t==='ov')startO();
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
	ajaxRefresh('#qos-st',function(){if(cur==='st')startR();});
}
function startO(){
	var c=30;
	(function tick(){
		var el=document.getElementById('qos-cd');
		if(el)el.textContent=c;
		if(c<=0)doO();
		else{c--;otmr=setTimeout(tick,1000);}
	})();
}
function doO(){
	ajaxRefresh('#qos-svc-sect,#qos-cfg-sect',function(){if(cur==='ov')startO();});
}
function ajaxRefresh(sels,cb){
	var x=new XMLHttpRequest();
	x.open('GET',location.href.split('#')[0],true);
	x.onload=function(){
		if(x.status===200){
			var d=document.createElement('div');d.innerHTML=x.responseText;
			var arr=sels.split(','),ok=true;
			for(var i=0;i<arr.length;i++){
				var n=d.querySelector(arr[i]),o=document.querySelector(arr[i]);
				if(n&&o)o.innerHTML=n.innerHTML;else ok=false;
			}
			if(ok&&cb)cb();else if(!ok)location.href='/cgi-bin/luci/';
		}else location.href='/cgi-bin/luci/';
	};
	x.onerror=function(){location.href='/cgi-bin/luci/';};
	x.send();
}
document.addEventListener('submit',function(e){
	var f=e.target;if(f.tagName==='FORM'){
	dirty=false;
	var h=location.hash;if(h)f.action=f.action.split('#')[0]+h;}
});
var h=location.hash.slice(1),idx=names.indexOf(h);
if(idx>=0)qT(tabs[idx]);else{var rf=document.getElementById('qos-rf');if(rf)rf.style.display='';startO();}
var m=document.getElementById('qos-msg');
if(m)setTimeout(function(){window.location=location.pathname+location.hash;},5000);
window.qT=qT;
window.qDl=function(id,fn){
	var t=document.getElementById(id);if(!t)return;
	var b=new Blob([t.value],{type:'application/octet-stream'});
	var a=document.createElement('a');a.href=URL.createObjectURL(b);
	a.download=fn;a.click();URL.revokeObjectURL(a.href);
};
window.qAR=function(){
	var ty=document.getElementById('qar-type').value;
	var vl=document.getElementById('qar-val').value.replace(/\s/g,'');
	var cl=document.getElementById('qar-cls').value;
	var pr=document.getElementById('qar-prio').checked;
	if(!vl){alert('Enter a port number or DNS pattern.');return;}
	if(!cl){alert('No classes defined. Add classes in the Config tab first.');return;}
	if(ty!=='dns:' && !/^\d+(-\d+)?$/.test(vl)){alert('Port must be a number or range (e.g. 4500 or 5060-5061).');return;}
	if(ty==='dns:' && !/[a-z0-9.*_-]/i.test(vl)){alert('Enter a DNS pattern (e.g. *teams* or *.zoom*).');return;}
	var pfx=pr?'+':'';
	var ta=document.getElementById('qos-rules-ta');if(!ta)return;
	var lines=[];
	if(ty==='both:'){
		lines.push('tcp:'+vl+'\t'+pfx+cl);
		lines.push('udp:'+vl+'\t'+pfx+cl);
	}else{
		lines.push(ty+vl+'\t'+pfx+cl);
	}
	var v=ta.value.replace(/\s+$/,'');
	ta.value=v+(v?'\n':'')+lines.join('\n')+'\n';
	chkD();
	document.getElementById('qar-val').value='';
	document.getElementById('qar-prio').checked=false;
	ta.scrollTop=ta.scrollHeight;
};
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
	rm -f "$CTRL_DIR/qosify.lua"
	rm -rf /usr/lib/lua/luci/model/cbi/qosify "$VIEW_DIR"
	flush_luci
	logger -t qosify-luci "LuCI app and qosify fully removed"
	echo "[OK] qosify fully uninstalled"
	echo "[*] Refresh your browser (Ctrl+F5) to clear the old menu."
}

case "$1" in
	install) install_all ;;
	uninstall) uninstall_all ;;
	reset) install_defaults ;;
	*) echo "Usage: $0 {install|uninstall|reset}" ;;
esac