#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (ash-compatible)
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/qosify"
CONFIG_DIR="/etc/qosify"
UCI_CONFIG="/etc/config/qosify"
DEFAULTS_FILE="$CONFIG_DIR/00-defaults.conf"
VERSION="2.1"

restart_luci_services() {
    [ -f /etc/init.d/rpcd ] && /etc/init.d/rpcd restart 2>/dev/null
    sleep 1
    if [ -f /etc/init.d/uhttpd ]; then
        /etc/init.d/uhttpd restart 2>/dev/null
    elif [ -f /etc/init.d/nginx ]; then
        /etc/init.d/nginx restart 2>/dev/null
    fi
    # best-effort: ask ubus/uhttpd to reload if available (ignore errors)
    if command -v ubus >/dev/null 2>&1; then
        ubus call uhttpd reload 2>/dev/null || true
    fi
}


install_qosify() {
	echo "[*] Checking qosify..."
	if command -v qosify >/dev/null 2>&1; then
		echo "[OK] qosify found"
	else
		echo "[*] Installing qosify, lua, luci-compat..."
		if command -v opkg >/dev/null 2>&1; then
			opkg update && opkg install qosify lua luci-compat
		elif command -v apk >/dev/null 2>&1; then
			apk update && apk add qosify lua luci-compat
		else
			echo "[ERROR] No supported package manager"
			exit 1
		fi
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
local function parse_uci(raw)
	local named,typed={},{}
	local cur
	for line in raw:gmatch("[^\n]+") do
		local t,n=line:match("^config%s+(%S+)%s+'([%w_]+)'")
		if not t then t,n=line:match("^config%s+(%S+)%s+([%w_]+)") end
		if not t then t=line:match("^config%s+(%S+)%s*$") end
		if t then
			cur={_type=t,_name=n}
			if n then named[n]=cur end
			if not typed[t] then typed[t]={} end
			typed[t][#typed[t]+1]=cur
		elseif cur then
			local k,v=line:match("^%s+option%s+(%S+)%s+'(.-)'")
			if not k then k,v=line:match("^%s+option%s+(%S+)%s+(%S+)") end
			if k then cur[k]=v end
		end
	end
	return named,typed
end
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
			if d then
				d=d:gsub("\r\n","\n")
				if #d>0 then
					local ok,e=true,nil
					if d:find("%z") then ok,e=false,"Binary content rejected"
					elseif not d:find("config ") then ok,e=false,"No valid config stanzas found" end
					if ok then fs.writefile("/etc/config/qosify",d)
						sys.call("/etc/init.d/qosify restart >/dev/null 2>&1"); msg="Config saved, qosify restarted."
					else msg="Error: "..e end
				else fs.writefile("/etc/config/qosify","")
					sys.call("/etc/init.d/qosify stop >/dev/null 2>&1"); msg="Config cleared, qosify stopped."
				end
			end
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
			local ovh_ok={none=1,conservative=1,ethernet=1,["pppoe-ptm"]=1,["bridged-ptm"]=1,["pppoe-vcmux"]=1,["pppoe-llcsnap"]=1,["pppoa-vcmux"]=1,["pppoa-llc"]=1,["bridged-vcmux"]=1,["bridged-llcsnap"]=1,["ipoa-vcmux"]=1,["ipoa-llcsnap"]=1}
			local mod_ok={diffserv3=1,diffserv4=1,diffserv8=1}
			local errs={}
			if iopts~="" and not iopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Ingress Options" end
			if eopts~="" and not eopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Egress Options" end
			if gopts~="" and not gopts:match("^[%w%s%-%.]+$") then errs[#errs+1]="Options" end
			if #errs>0 then
				msg="Error: invalid characters in "..table.concat(errs,", ")..". Use alphanumeric, spaces, hyphens, dots only."
			else
				local cmds={"(uci -q get qosify.wan >/dev/null || (uci add qosify interface >/dev/null && uci rename qosify.@interface[-1]=wan && uci set qosify.wan.name=wan))"}
				cmds[#cmds+1]="uci set qosify.wan.disabled='"..dis.."'"
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
	local cfg_raw=has_uci and (fs.readfile("/etc/config/qosify")or"") or ""
	local def_raw=has_def and (fs.readfile("/etc/qosify/00-defaults.conf")or"") or ""
	local num_rules=0
	if has_def then for l in def_raw:gmatch("[^\n]+") do local s=l:match("^%s*(.-)%s*$") if s~="" and s:sub(1,1)~="#" then num_rules=num_rules+1 end end end
	local status_out=""
	local active=false
	if running then
		status_out=r("qosify-status 2>/dev/null")
		active=(status_out:find(": active")~=nil)
	end
	local uci_ok=false
	if has_uci then uci_ok=(#cfg_raw>10 and (cfg_raw:find("\nconfig ") or cfg_raw:match("^config "))~=nil) end
	local def_ok=(has_def and num_rules>0)
	local uci_st=has_uci and fs.stat("/etc/config/qosify") or nil
	local def_st=has_def and fs.stat("/etc/qosify/00-defaults.conf") or nil
	local uci_sz=uci_st and uci_st.size or 0
	local def_sz=def_st and def_st.size or 0
	local uci_mod=uci_st and os.date("%Y-%m-%d %H:%M",uci_st.mtime) or ""
	local def_mod=def_st and os.date("%Y-%m-%d %H:%M",def_st.mtime) or ""
	local named,typed=parse_uci(cfg_raw)
	local wan=named["wan"] or {}
	local defs_s=(typed["defaults"] and typed["defaults"][1]) or {}
	local function g(t,k) return t[k] or "" end
	local all_classes={}
	local all_cls={}
	for c in cfg_raw:gmatch("config%s+class%s+'?([%w_]+)'?") do
		local cs=named[c] or {}
		all_classes[#all_classes+1]={name=c,ingress=g(cs,"ingress"),egress=g(cs,"egress"),
			dscp_prio=g(cs,"dscp_prio"),dscp_bulk=g(cs,"dscp_bulk"),
			prio_max_avg_pkt_len=g(cs,"prio_max_avg_pkt_len"),
			bulk_trigger_pps=g(cs,"bulk_trigger_pps"),
			bulk_trigger_timeout=g(cs,"bulk_trigger_timeout")}
		all_cls[#all_cls+1]=c
	end
	local defs={dscp_icmp=g(defs_s,"dscp_icmp"),
		dscp_default_tcp=g(defs_s,"dscp_default_tcp"),dscp_default_udp=g(defs_s,"dscp_default_udp"),
		dscp_prio=g(defs_s,"dscp_prio"),
		prio_max_avg_pkt_len=g(defs_s,"prio_max_avg_pkt_len")}
	local ovh_v=g(wan,"overhead_type") if ovh_v=="" then ovh_v=g(wan,"overhead") end
	local wo=g(wan,"options") if wo=="" then wo=g(wan,"option") end
	tpl.render("qosify/main",{
		msg=msg,running=running,enabled=enabled,active=active,
		has_bin=has_bin,has_uci=has_uci,has_def=has_def,has_init=has_init,
		uci_ok=uci_ok,def_ok=def_ok,defs=defs,all_cls=all_cls,all_classes=all_classes,
		uci_sz=uci_sz,def_sz=def_sz,uci_mod=uci_mod,def_mod=def_mod,
		wan_iface=g(wan,"name"),bw_up=g(wan,"bandwidth_up"),bw_down=g(wan,"bandwidth_down"),
		mode=g(wan,"mode"),wan_dis=(g(wan,"disabled")=="1"),
		overhead=ovh_v,autorate=g(wan,"autorate_ingress"),
		ingress=g(wan,"ingress"),egress=g(wan,"egress"),
		wan_nat=g(wan,"nat"),host_iso=g(wan,"host_isolate"),
		ing_opts=g(wan,"ingress_options"),egr_opts=g(wan,"egress_options"),wan_opts=wo,
		num_rules=num_rules,status_out=status_out,
		cfg_content=cfg_raw,def_content=def_raw,
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
<tr><td>QoS Enabled</td><td><input type="checkbox" name="qos_enabled" value="1"<%= (wan_iface~="" and not wan_dis) and ' checked="checked"' or '' %>/>
<% if active then %><span class="qos-badge qos-green" style="margin-left:8px">Active</span>
<% elseif wan_iface~="" and not wan_dis then %><span class="qos-badge qos-amber" style="margin-left:8px">Enabled &mdash; Not Active</span>
<% else %><span class="qos-badge qos-red" style="margin-left:8px">Disabled</span><% end %></td></tr>
<tr><td>Bandwidth Up</td><td><input type="text" name="bw_up" value="<%=pcdata(bw_up)%>" style="width:140px;font-family:monospace" placeholder="e.g. 100mbit"/></td></tr>
<tr><td>Bandwidth Down</td><td><input type="text" name="bw_down" value="<%=pcdata(bw_down)%>" style="width:140px;font-family:monospace" placeholder="e.g. 100mbit"/></td></tr>
<tr><td>Overhead Type</td><td><select name="overhead" style="width:180px">
<% if overhead=="" then %><option value="" selected="selected">--</option><% end %>
<% local ovh_list={"none","conservative","ethernet","pppoe-ptm","bridged-ptm","pppoe-vcmux","pppoe-llcsnap","pppoa-vcmux","pppoa-llc","bridged-vcmux","bridged-llcsnap","ipoa-vcmux","ipoa-llcsnap"}
for _,v in ipairs(ovh_list) do %><option value="<%=v%>"<%= (overhead==v) and ' selected="selected"' or '' %>><%=v%></option>
<% end %></select></td></tr>
<tr><td>Queue Mode</td><td><select name="mode" style="width:148px">
<% if mode=="" then %><option value="" selected="selected">--</option><% end %>
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
<div class="qos-svc" id="qos-svc-btns">
<input class="cbi-button <%= enabled and 'qos-btn-en' or 'qos-btn-dis' %>" type="button" id="qos-en-btn"
 value="<%= enabled and 'Enabled' or 'Disabled' %>"
 title="<%= enabled and 'Click to disable autostart' or 'Click to enable autostart' %>"
 onclick="qSvc('<%= enabled and 'disable' or 'enable' %>')"/>
<% local btns={"start","stop","restart","reload"} for _,a in ipairs(btns) do %>
<input class="cbi-button cbi-button-<%= (a=='stop') and 'reset' or 'apply' %>" type="button" value="<%=a:sub(1,1):upper()..a:sub(2)%>" onclick="qSvc('<%=a%>')"/>
<% end %>
</div>
</fieldset>
</div>

<div id="qos-cf" class="qos-tab">
<fieldset class="cbi-section">
<legend>Config</legend>
<div class="cbi-section-descr">UCI configuration &mdash; classes, interfaces, defaults. <code>/etc/config/qosify</code></div>
<% local dscp_codes={"CS0","CS1","CS2","CS3","CS4","CS5","CS6","CS7","AF11","AF12","AF13","AF21","AF22","AF23","AF31","AF32","AF33","AF41","AF42","AF43","EF","LE"}
local ovh_types={"none","conservative","ethernet","pppoe-ptm","bridged-ptm","pppoe-vcmux","pppoe-llcsnap","pppoa-vcmux","pppoa-llc","bridged-vcmux","bridged-llcsnap","ipoa-vcmux","ipoa-llcsnap"}
local mode_types={"diffserv3","diffserv4","diffserv8"} %>
<details style="margin:0 0 10px;padding:6px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a">
<summary style="cursor:pointer;font-weight:bold;font-size:13px;color:#aaa">Config Reference</summary>
<div style="font-size:11px;color:#bbb;margin:6px 0;font-family:monospace;line-height:1.8">
<strong style="color:#8ab4f8">config defaults</strong><br/>
&nbsp; list defaults, option dscp_prio, option dscp_icmp, option dscp_default_tcp, option dscp_default_udp, option prio_max_avg_pkt_len<br/>
<strong style="color:#8ab4f8">config class</strong> &lsquo;name&rsquo;<br/>
&nbsp; option ingress, option egress, option dscp_prio, option dscp_bulk, option prio_max_avg_pkt_len, option bulk_trigger_pps, option bulk_trigger_timeout<br/>
<strong style="color:#8ab4f8">config interface</strong> &lsquo;name&rsquo;<br/>
&nbsp; option name, option disabled, option bandwidth_up, option bandwidth_down, option overhead_type, option mode, option ingress, option egress, option nat, option host_isolate, option autorate_ingress, option ingress_options, option egress_options, option options<br/>
<strong style="color:#8ab4f8">config device</strong> &lsquo;name&rsquo;<br/>
&nbsp; option name, option disabled, option bandwidth
</div>
<% if defs then %>
<div style="margin:6px 0 4px;padding:4px 8px;border:1px solid #444;border-radius:3px;background:#222">
<strong style="font-size:12px;color:#8ab4f8">config defaults</strong>
<div style="font-size:11px;color:#bbb;margin:2px 0 0;font-family:monospace">
<% if defs.dscp_default_tcp~="" then %>dscp_default_tcp: <strong><%=pcdata(defs.dscp_default_tcp)%></strong> &nbsp; <% end %>
<% if defs.dscp_default_udp~="" then %>dscp_default_udp: <strong><%=pcdata(defs.dscp_default_udp)%></strong> &nbsp; <% end %>
<% if defs.dscp_icmp~="" then %>dscp_icmp: <strong><%=pcdata(defs.dscp_icmp)%></strong> &nbsp; <% end %>
<% if defs.dscp_prio~="" then %>dscp_prio: <strong><%=pcdata(defs.dscp_prio)%></strong> &nbsp; <% end %>
<% if defs.prio_max_avg_pkt_len~="" then %>prio_max_avg_pkt_len: <strong><%=pcdata(defs.prio_max_avg_pkt_len)%></strong><% end %>
</div></div>
<% end %>
<% if all_classes and #all_classes>0 then for _,cl in ipairs(all_classes) do %>
<div style="margin:4px 0;padding:4px 8px;border:1px solid #444;border-radius:3px;background:#222">
<strong style="font-size:12px;color:#8ab4f8"><%=pcdata(cl.name)%></strong>
<span style="font-size:11px;color:#bbb;margin-left:8px">Ingress: <strong><%=pcdata(cl.ingress)%></strong> / Egress: <strong><%=pcdata(cl.egress)%></strong></span>
<% if cl.dscp_prio~="" or cl.prio_max_avg_pkt_len~="" or cl.bulk_trigger_pps~="" or cl.dscp_bulk~="" then %>
<div style="font-size:11px;color:#888;margin:2px 0 0;font-family:monospace">
<% if cl.dscp_prio~="" then %>dscp_prio: <strong style="color:#bbb"><%=pcdata(cl.dscp_prio)%></strong> &nbsp; <% end %>
<% if cl.prio_max_avg_pkt_len~="" then %>prio_max_avg_pkt_len: <strong style="color:#bbb"><%=pcdata(cl.prio_max_avg_pkt_len)%></strong> &nbsp; <% end %>
<% if cl.bulk_trigger_pps~="" then %>bulk_trigger_pps: <strong style="color:#bbb"><%=pcdata(cl.bulk_trigger_pps)%></strong> &nbsp; <% end %>
<% if cl.bulk_trigger_timeout~="" then %>bulk_trigger_timeout: <strong style="color:#bbb"><%=pcdata(cl.bulk_trigger_timeout)%></strong> &nbsp; <% end %>
<% if cl.dscp_bulk~="" then %>dscp_bulk: <strong style="color:#bbb"><%=pcdata(cl.dscp_bulk)%></strong><% end %>
</div>
<% end %>
</div>
<% end end %>
<div style="color:#888;font-size:11px;margin:4px 0 2px">DSCP codepoints: CS0&ndash;CS7, AF11&ndash;AF43, EF, LE. Prefix with <code>+</code> for priority boost.</div>
</details>
<div style="margin:0 0 8px;padding:8px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a">
<strong style="font-size:13px;color:#aaa">Quick Add Config</strong>
<div style="display:flex;gap:6px;align-items:center;margin:6px 0 0;flex-wrap:wrap">
<select id="qac-type" style="width:130px" onchange="qCS()">
<option value="defaults">config defaults</option>
<option value="class">config class</option>
<option value="interface">config interface</option>
</select>
<span id="qac-nm-w" style="display:none"><input id="qac-name" type="text" placeholder="section name" style="width:120px;font-family:monospace"/></span>
<input class="cbi-button cbi-button-add" type="button" value="Add" onclick="qAC()"/>
</div>
<div id="qac-opts-defaults" style="display:flex;gap:4px;align-items:center;flex-wrap:wrap;margin:6px 0 0;font-size:11px;color:#888">
<label>list defaults:</label><input data-opt="defaults" data-pre="list" type="text" value="/etc/qosify/*.conf" style="width:180px;font-family:monospace"/>
<label>dscp_prio:</label><select data-opt="dscp_prio" style="width:120px"><option value="">--</option><% for _,c in ipairs(all_cls) do %><option><%=pcdata(c)%></option><% end %></select>
<label>dscp_icmp:</label><select data-opt="dscp_icmp" data-pfx="qac-icmp-pf" style="width:120px"><option value="">--</option><% for _,c in ipairs(all_cls) do %><option><%=pcdata(c)%></option><% end %></select><label><input type="checkbox" id="qac-icmp-pf"/> +</label>
<label>dscp_default_tcp:</label><select data-opt="dscp_default_tcp" style="width:120px"><option value="">--</option><% for _,c in ipairs(all_cls) do %><option><%=pcdata(c)%></option><% end %></select>
<label>dscp_default_udp:</label><select data-opt="dscp_default_udp" style="width:120px"><option value="">--</option><% for _,c in ipairs(all_cls) do %><option><%=pcdata(c)%></option><% end %></select>
<label>prio_max_avg_pkt_len:</label><input data-opt="prio_max_avg_pkt_len" type="number" min="0" style="width:55px" placeholder="500"/>
</div>
<div id="qac-opts-class" style="display:none;gap:4px;align-items:center;flex-wrap:wrap;margin:6px 0 0;font-size:11px;color:#888">
<label>Ingress:</label><select data-opt="ingress" style="width:70px"><% for _,d in ipairs(dscp_codes) do %><option><%=d%></option><% end %></select>
<label>Egress:</label><select data-opt="egress" style="width:70px"><% for _,d in ipairs(dscp_codes) do %><option><%=d%></option><% end %></select>
<label>dscp_prio:</label><select data-opt="dscp_prio" style="width:70px"><option value="">--</option><% for _,d in ipairs(dscp_codes) do %><option><%=d%></option><% end %></select>
<label>dscp_bulk:</label><select data-opt="dscp_bulk" style="width:70px"><option value="">--</option><% for _,d in ipairs(dscp_codes) do %><option><%=d%></option><% end %></select>
<label>prio_max_avg_pkt_len:</label><input data-opt="prio_max_avg_pkt_len" type="number" min="0" style="width:55px" placeholder="500"/>
<label>bulk_trigger_pps:</label><input data-opt="bulk_trigger_pps" type="number" min="0" style="width:55px" placeholder="100"/>
<label>bulk_trigger_timeout:</label><input data-opt="bulk_trigger_timeout" type="number" min="0" style="width:45px" placeholder="5"/>
</div>
<div id="qac-opts-interface" style="display:none;gap:4px;align-items:center;flex-wrap:wrap;margin:6px 0 0;font-size:11px;color:#888">
<label>name:</label><input data-opt="name" type="text" style="width:80px;font-family:monospace" placeholder="wan"/>
<label>disabled:</label><select data-opt="disabled" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>bandwidth_up:</label><input data-opt="bandwidth_up" type="text" style="width:80px;font-family:monospace" placeholder="100mbit"/>
<label>bandwidth_down:</label><input data-opt="bandwidth_down" type="text" style="width:80px;font-family:monospace" placeholder="100mbit"/>
<label>overhead_type:</label><select data-opt="overhead_type" style="width:130px"><option value="">--</option><% for _,v in ipairs(ovh_types) do %><option><%=v%></option><% end %></select>
<label>mode:</label><select data-opt="mode" style="width:100px"><option value="">--</option><% for _,v in ipairs(mode_types) do %><option><%=v%></option><% end %></select>
<label>ingress:</label><select data-opt="ingress" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>egress:</label><select data-opt="egress" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>nat:</label><select data-opt="nat" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>host_isolate:</label><select data-opt="host_isolate" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>autorate_ingress:</label><select data-opt="autorate_ingress" style="width:45px"><option value="">--</option><option>0</option><option>1</option></select>
<label>ingress_options:</label><input data-opt="ingress_options" type="text" style="width:160px;font-family:monospace" placeholder="e.g. triple-isolate"/>
<label>egress_options:</label><input data-opt="egress_options" type="text" style="width:160px;font-family:monospace" placeholder="e.g. triple-isolate wash"/>
<label>options:</label><input data-opt="options" type="text" style="width:160px;font-family:monospace" placeholder="e.g. overhead 44 mpu 84"/>
</div>
</div>
<form method="post" action="<%=REQUEST_URI%>" id="qos-config-form">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="save_config"/>
<textarea name="data" id="qos-config-ta" rows="28" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px"><%=pcdata(cfg_content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-reset" type="button" value="Clear" onclick="qClrCfg()" style="margin-right:6px"/>
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
<summary style="cursor:pointer;font-weight:bold;font-size:13px;color:#aaa">Available Classes</summary>
<table class="qos-kv" style="margin:6px 0 0" width="100%">
<% if all_classes and #all_classes>0 then for _,cl in ipairs(all_classes) do %>
<tr><td style="width:140px"><%=pcdata(cl.name)%></td><td>Ingress: <strong><%=pcdata(cl.ingress)%></strong> / Egress: <strong><%=pcdata(cl.egress)%></strong></td></tr>
<% end else %>
<tr><td colspan="2" style="color:#888"><em>No classes defined in /etc/config/qosify</em></td></tr>
<% end %>
</table>
<div style="color:#888;font-size:11px;margin:6px 0 2px">Prefix with <code>+</code> for priority within class. Ports: <code>tcp:443</code>, <code>udp:3074</code>, ranges: <code>tcp:5060-5061</code>. DNS: <code>dns:*teams*</code>, regex: <code>dns:/zoom[0-9]+</code>. IP: <code>1.1.1.1</code>, <code>ff01::1</code></div>
</details>
<div style="margin:0 0 8px;padding:8px 10px;border:1px solid #555;border-radius:4px;background:#2a2a2a">
<strong style="font-size:13px;color:#aaa">Quick Add Rule</strong>
<div style="display:flex;gap:6px;align-items:center;margin:6px 0 0;flex-wrap:wrap">
<select id="qar-type" style="width:140px" onchange="qTP()">
<option value="tcp:">tcp port</option>
<option value="udp:">udp port</option>
<option value="both:">tcp+udp port</option>
<option value="dns:">dns pattern</option>
<option value="dnsr:">dns regex</option>
<option value="dns_c:">dns_c pattern</option>
<option value="dns_cr:">dns_c regex</option>
<option value="ipv4:">IPv4 address</option>
<option value="ipv6:">IPv6 address</option>
</select>
<input id="qar-val" type="text" placeholder="e.g. 4500 or 5060-5061" style="width:180px;font-family:monospace"/>
<select id="qar-cls" style="width:140px">
<% if all_classes then for _,cl in ipairs(all_classes) do %>
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
<input class="cbi-button cbi-button-reset" type="button" value="Clear" onclick="qClrRules()" style="margin-right:6px"/>
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
	var mb=document.getElementById('qos-msg');if(mb)mb.style.display='none';
	ajaxRefresh('#qos-svc-sect,#qos-cfg-sect',function(){if(cur==='ov')startO();});
}
function ajaxRefresh(sels,cb){
	var x=new XMLHttpRequest();
	x.open('GET',location.href.split('#')[0],true);
	x.onload=function(){
		if(x.status===200){
			var d=document.createElement('div');d.innerHTML=x.responseText;
			var arr=sels.split(',');
			for(var i=0;i<arr.length;i++){
				var n=d.querySelector(arr[i]),o=document.querySelector(arr[i]);
				if(n&&o)o.innerHTML=n.innerHTML;
			}
			if(cb)cb();
		}
	};
	x.onerror=function(){};
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
if(m){var mt=m.className.match('qos-msg-err')?10000:5000;setTimeout(function(){m.style.display='none';},mt);}
window.qT=qT;
window.qSvc=function(a){
	var btns=document.getElementById('qos-svc-btns');
	var els=btns.querySelectorAll('input');
	for(var i=0;i<els.length;i++)els[i].disabled=true;
	var x=new XMLHttpRequest();
	x.open('POST',location.href.split('#')[0],true);
	x.setRequestHeader('Content-Type','application/x-www-form-urlencoded');
	x.onload=function(){
		for(var i=0;i<els.length;i++)els[i].disabled=false;
		ajaxRefresh('#qos-svc-sect,#qos-cfg-sect,#qos-svc-btns',function(){});
	};
	x.onerror=function(){for(var i=0;i<els.length;i++)els[i].disabled=false;};
	var tk=document.querySelector('#qos-quick-form input[name=token]');
	x.send('token='+(tk?tk.value:'')+'&action='+a);
};
window.qClrCfg=function(){
	if(!confirm('Clear config editor and reset Quick Settings? Content will not be saved until you click Save.'))return;
	document.getElementById('qos-config-ta').value='';
	chkD();
	var f=document.getElementById('qos-quick-form');
	if(f){var x=f.querySelectorAll('input:not([type=hidden]),select');
	for(var i=0;i<x.length;i++){
		if(x[i].type==='checkbox')x[i].checked=false;
		else if(x[i].tagName==='SELECT')x[i].selectedIndex=0;
		else x[i].value='';
	}}
};
window.qClrRules=function(){
	if(!confirm('Clear rules editor? Content will not be saved until you click Save.'))return;
	document.getElementById('qos-rules-ta').value='';
	chkD();
};
window.qDl=function(id,fn){
	var t=document.getElementById(id);if(!t)return;
	var b=new Blob([t.value],{type:'application/octet-stream'});
	var a=document.createElement('a');a.href=URL.createObjectURL(b);
	a.download=fn;a.click();URL.revokeObjectURL(a.href);
};
window.qAR=function(){
	var ty=document.getElementById('qar-type').value;
	var vl=document.getElementById('qar-val').value.replace(/^\s+|\s+$/g,'');
	var cl=document.getElementById('qar-cls').value;
	var pr=document.getElementById('qar-prio').checked;
	if(!vl){alert('Enter a value.');return;}
	if(!cl){alert('No classes defined. Add classes in the Config tab first.');return;}
	var pt=(ty==='tcp:'||ty==='udp:'||ty==='both:');
	if(pt&&!/^\d+(-\d+)?$/.test(vl)){alert('Port must be a number or range (e.g. 4500 or 5060-5061).');return;}
	if(pt){var pp=vl.split('-');for(var j=0;j<pp.length;j++){var pn=parseInt(pp[j]);if(pn<1||pn>65535){alert('Port must be 1-65535.');return;}}}
	if(ty==='ipv4:'&&!/^\d{1,3}(\.\d{1,3}){3}(\/\d{1,2})?$/.test(vl)){alert('Enter a valid IPv4 address (e.g. 1.1.1.1 or 192.168.1.0/24).');return;}
	if(ty==='ipv6:'&&!/^[0-9a-fA-F:]+(%[a-zA-Z0-9]+)?(\/\d{1,3})?$/.test(vl)){alert('Enter a valid IPv6 address (e.g. ff01::1).');return;}
	var pfx=pr?'+':'';
	var ta=document.getElementById('qos-rules-ta');if(!ta)return;
	var lines=[];
	if(ty==='both:'){
		lines.push('tcp:'+vl+'\t'+pfx+cl);
		lines.push('udp:'+vl+'\t'+pfx+cl);
	}else if(ty==='ipv4:'||ty==='ipv6:'){
		lines.push(vl+'\t'+pfx+cl);
	}else if(ty==='dnsr:'){
		lines.push('dns:/'+vl+'\t'+pfx+cl);
	}else if(ty==='dns_cr:'){
		lines.push('dns_c:/'+vl+'\t'+pfx+cl);
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
window.qTP=function(){
	var ty=document.getElementById('qar-type').value;
	var el=document.getElementById('qar-val');
	var ph={'tcp:':'e.g. 4500 or 5060-5061','udp:':'e.g. 4500 or 5060-5061','both:':'e.g. 4500 or 5060-5061',
		'dns:':'e.g. *teams* or *.zoom*','dnsr:':'e.g. zoom[0-9]+\\.us','dns_c:':'e.g. *cdn*','dns_cr:':'e.g. cdn[0-9]+',
		'ipv4:':'e.g. 1.1.1.1 or 192.168.1.0/24','ipv6:':'e.g. ff01::1'};
	el.placeholder=ph[ty]||'';
};
window.qCS=function(){
	var ty=document.getElementById('qac-type').value;
	var ids=['defaults','class','interface'];
	for(var i=0;i<ids.length;i++){
		var el=document.getElementById('qac-opts-'+ids[i]);
		el.style.display=(ids[i]===ty)?'flex':'none';
	}
	document.getElementById('qac-nm-w').style.display=(ty==='defaults')?'none':'';
};
window.qAC=function(){
	var ty=document.getElementById('qac-type').value;
	var ta=document.getElementById('qos-config-ta');if(!ta)return;
	var nm='';
	if(ty!=='defaults'){
		nm=document.getElementById('qac-name').value.replace(/[^a-zA-Z0-9_]/g,'');
		if(!nm){alert('Enter a section name (alphanumeric/underscore).');return;}
	}
	var s='\nconfig '+ty+(nm?" '"+nm+"'":'');
	var div=document.getElementById('qac-opts-'+ty);
	var els=div.querySelectorAll('[data-opt]');
	for(var i=0;i<els.length;i++){
		var v=els[i].value;if(!v)continue;
		var opt=els[i].getAttribute('data-opt');
		var pre=els[i].getAttribute('data-pre')||'option';
		var pfx=els[i].getAttribute('data-pfx');
		if(pfx){var cb=document.getElementById(pfx);if(cb&&cb.checked)v='+'+v;}
		s+="\n\t"+pre+" "+opt+" '"+v+"'";
	}
	var cv=ta.value.replace(/\s+$/,'');
	ta.value=cv+s+'\n';
	chkD();
	if(nm)document.getElementById('qac-name').value='';
	for(var i=0;i<els.length;i++){
		if(els[i].tagName==='SELECT')els[i].selectedIndex=0;
		else els[i].value=els[i].defaultValue||'';
	}
	var pf=document.getElementById('qac-icmp-pf');if(pf)pf.checked=false;
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
	rm -f "$CTRL_DIR/qosify.lua"
	rm -rf /usr/lib/lua/luci/model/cbi/qosify "$VIEW_DIR"
	restart_luci_services
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