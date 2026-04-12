#!/bin/sh
# qosify-luci.sh — LuCI App for qosify (ash-compatible)
CTRL_DIR="/usr/lib/lua/luci/controller"
VIEW_DIR="/usr/lib/lua/luci/view/qosify"
CONFIG_DIR="/etc/qosify"
UCI_CONFIG="/etc/config/qosify"
DEFAULTS_FILE="$CONFIG_DIR/00-defaults.conf"
VERSION="1.1"

flush_luci() {
	echo "[*] Clearing LuCI cache & sessions..."
	rm -rf /tmp/luci-indexcache /tmp/luci-modulecache \
		/tmp/luci-templatecache /tmp/luci-sessions 2>/dev/null
	# invalidate rpcd sessions (modern OpenWrt)
	if [ -f /etc/init.d/rpcd ]; then
		/etc/init.d/rpcd restart 2>/dev/null
	fi
	echo "[*] Restarting web server..."
	if [ -f /etc/init.d/uhttpd ]; then
		/etc/init.d/uhttpd restart
	elif [ -f /etc/init.d/nginx ]; then
		/etc/init.d/nginx restart
	else
		echo "[!] No supported web server found"
	fi
}

install_qosify() {
	echo "[*] Checking qosify..."
	if command -v qosify >/dev/null 2>&1; then
		echo "[OK] qosify found"
	else
		echo "[*] Installing qosify..."
		if command -v opkg >/dev/null 2>&1; then
			opkg update && opkg install qosify
		elif command -v apk >/dev/null 2>&1; then
			apk update && apk add qosify
		else
			echo "[ERROR] No supported package manager"; exit 1
		fi
	fi
	/etc/init.d/qosify enable 2>/dev/null
	/etc/init.d/qosify start 2>/dev/null
}

install_config_files() {
	echo "[*] Checking config files..."
	mkdir -p "$CONFIG_DIR"
	[ -f "$DEFAULTS_FILE" ] || cat > "$DEFAULTS_FILE" << 'EOF'
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
	[ -f "$UCI_CONFIG" ] || cat > "$UCI_CONFIG" << 'EOF'
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
module("luci.controller.qosify", package.seeall)
local fs=require"nixio.fs"
local sys=require"luci.sys"
local http=require"luci.http"
local tpl=require"luci.template"
local disp=require"luci.dispatcher"

local function runcmd(c)
	local h=io.popen(c.." 2>&1")
	local o=h:read("*a") or ""
	h:close()
	return o:gsub("%s+$","")
end

function index()
	entry({"admin","network","qosify"},firstchild(),"qosify",90).dependent=false
	entry({"admin","network","qosify","overview"},call("action_overview"),"Overview",1)
	entry({"admin","network","qosify","status"},call("action_status"),"Status",2)
	entry({"admin","network","qosify","config"},call("action_config"),"Config",3)
	entry({"admin","network","qosify","defaults"},call("action_defaults"),"Classification Rules",4)
	entry({"admin","network","qosify","upload"},call("action_upload"),"Advanced",5)
end

function action_overview()
	local msg=nil
	if http.getenv("REQUEST_METHOD")=="POST" then
		local act=http.formvalue("action")
		if act=="start" then
			sys.call("/etc/init.d/qosify start >/dev/null 2>&1"); msg="qosify started."
		elseif act=="stop" then
			sys.call("/etc/init.d/qosify stop >/dev/null 2>&1"); msg="qosify stopped."
		elseif act=="restart" then
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1"); msg="qosify restarted."
		elseif act=="reload" then
			sys.call("/etc/init.d/qosify reload >/dev/null 2>&1"); msg="qosify reloaded."
		elseif act=="enable" then
			sys.call("/etc/init.d/qosify enable >/dev/null 2>&1"); msg="qosify enabled at boot."
		elseif act=="disable" then
			sys.call("/etc/init.d/qosify disable >/dev/null 2>&1"); msg="qosify disabled at boot."
		end
	end
	local proc_status=runcmd("/etc/init.d/qosify status")
	local running=(sys.call("/etc/init.d/qosify running >/dev/null 2>&1")==0)
	if not running then running=(sys.call("pgrep -x qosify >/dev/null 2>&1")==0) end
	if not running then running=(proc_status:match("running")~=nil) end
	local enabled=(sys.call("/etc/init.d/qosify enabled 2>/dev/null")==0)
	local has_bin=fs.access("/usr/sbin/qosify") or (sys.call("which qosify >/dev/null 2>&1")==0)
	local has_uci=fs.access("/etc/config/qosify")
	local has_def=fs.access("/etc/qosify/00-defaults.conf")
	local has_init=fs.access("/etc/init.d/qosify")
	local wan_iface=runcmd("uci -q get qosify.wan.name") or ""
	local bw_up=runcmd("uci -q get qosify.wan.bandwidth_up") or ""
	local bw_down=runcmd("uci -q get qosify.wan.bandwidth_down") or ""
	local mode=runcmd("uci -q get qosify.wan.mode") or ""
	local wan_disabled=(runcmd("uci -q get qosify.wan.disabled")=="1")
	local overhead=runcmd("uci -q get qosify.wan.overhead_type") or ""
	local autorate=runcmd("uci -q get qosify.wan.autorate_ingress") or ""
	local ingress=runcmd("uci -q get qosify.wan.ingress") or ""
	local egress=runcmd("uci -q get qosify.wan.egress") or ""
	local wan_nat=runcmd("uci -q get qosify.wan.nat") or ""
	local host_iso=runcmd("uci -q get qosify.wan.host_isolate") or ""
	local ing_opts=runcmd("uci -q get qosify.wan.ingress_options") or ""
	local egr_opts=runcmd("uci -q get qosify.wan.egress_options") or ""
	local opts=runcmd("uci -q get qosify.wan.options") or ""
	local num_rules=0
	if has_def then
		local rc=runcmd("grep -c '^[^#]' /etc/qosify/00-defaults.conf 2>/dev/null")
		num_rules=tonumber(rc) or 0
	end
	tpl.render("qosify/status",{
		msg=msg,proc_status=proc_status,running=running,enabled=enabled,
		has_bin=has_bin,has_uci=has_uci,has_def=has_def,has_init=has_init,
		wan_iface=wan_iface,bw_up=bw_up,bw_down=bw_down,mode=mode,wan_disabled=wan_disabled,
		overhead=overhead,autorate=autorate,ingress=ingress,egress=egress,
		wan_nat=wan_nat,host_iso=host_iso,ing_opts=ing_opts,egr_opts=egr_opts,opts=opts,
		num_rules=num_rules,qos_ver="1.1"
	})
end

function action_status()
	local running=(sys.call("/etc/init.d/qosify running >/dev/null 2>&1")==0)
	if not running then running=(sys.call("pgrep -x qosify >/dev/null 2>&1")==0) end
	local status_out=""
	if running then status_out=runcmd("qosify-status 2>/dev/null") end
	tpl.render("qosify/stats",{running=running,status_out=status_out})
end

local function handle_file_edit(filepath,title,desc)
	local msg=nil
	if http.getenv("REQUEST_METHOD")=="POST" then
		local data=http.formvalue("data")
		local apply=http.formvalue("apply")
		if data and apply then
			data=data:gsub("\r\n","\n")
			fs.writefile(filepath,data)
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1")
			msg="Saved and qosify restarted."
		end
	end
	local content=fs.readfile(filepath) or ""
	tpl.render("qosify/fileedit",{title=title,desc=desc,path=filepath,content=content,msg=msg})
end

function action_config()
	handle_file_edit("/etc/config/qosify","Config","UCI configuration — classes, interfaces, defaults.")
end

function action_defaults()
	handle_file_edit("/etc/qosify/00-defaults.conf","Classification Rules","DSCP mapping rules loaded by qosify on startup.")
end

function action_upload()
	local msg=nil
	local fp_uci=nil
	local fp_def=nil
	http.setfilehandler(function(meta,chunk,eof)
		if not meta or not meta.name then return end
		if meta.name=="uci_file" then
			if not fp_uci and chunk then fp_uci=io.open("/tmp/.qosify_upload_uci","w") end
			if fp_uci and chunk then fp_uci:write(chunk) end
			if fp_uci and eof then fp_uci:close() end
		elseif meta.name=="def_file" then
			if not fp_def and chunk then fp_def=io.open("/tmp/.qosify_upload_def","w") end
			if fp_def and chunk then fp_def:write(chunk) end
			if fp_def and eof then fp_def:close() end
		end
	end)
	if http.getenv("REQUEST_METHOD")=="POST" then
		local action=http.formvalue("action")
		if action=="upload" then
			local did=false
			if fs.access("/tmp/.qosify_upload_uci") then
				local sz=fs.stat("/tmp/.qosify_upload_uci","size") or 0
				if sz>0 then fs.copy("/tmp/.qosify_upload_uci","/etc/config/qosify"); did=true end
				fs.remove("/tmp/.qosify_upload_uci")
			end
			if fs.access("/tmp/.qosify_upload_def") then
				local sz=fs.stat("/tmp/.qosify_upload_def","size") or 0
				if sz>0 then fs.copy("/tmp/.qosify_upload_def","/etc/qosify/00-defaults.conf"); did=true end
				fs.remove("/tmp/.qosify_upload_def")
			end
			if did then
				sys.call("/etc/init.d/qosify restart >/dev/null 2>&1")
				msg="Files uploaded and qosify restarted."
			else msg="No valid files received." end
		elseif action=="reset" then
			sys.call("/bin/sh /usr/lib/lua/luci/view/qosify/reset_defaults.sh >/dev/null 2>&1")
			sys.call("/etc/init.d/qosify restart >/dev/null 2>&1")
			msg="Config reset to defaults and qosify restarted."
		end
	end
	tpl.render("qosify/upload",{msg=msg})
end
LUAEOF
}

install_views() {
	echo "[*] Setting up views..."
	mkdir -p "$VIEW_DIR"

	# Tab 1: Overview
	cat > "$VIEW_DIR/status.htm" << 'HTMEOF'
<%+header%>
<style>
.qos-tbl{width:100%;border-collapse:collapse;margin-bottom:4px;}
.qos-tbl td{padding:5px 10px;border-bottom:1px solid #e5e5e5;vertical-align:middle;}
.qos-tbl td:first-child{font-weight:bold;color:#555;width:180px;}
.qos-ok{color:#4caf50;} .qos-err{color:#e53935;} .qos-warn{color:#ff9800;}
.qos-badge{display:inline-block;padding:2px 10px;border-radius:3px;font-size:12px;font-weight:bold;color:#fff;}
.qos-badge-green{background:#4caf50;} .qos-badge-red{background:#e53935;} .qos-badge-grey{background:#999;}
.qos-actions{margin-top:4px;padding:4px 0;}
.qos-actions form{display:inline-block;margin:0 3px 3px 0;}
.qos-btn-enabled{background:#4caf50;color:#fff;border:1px solid #388e3c;border-radius:3px;padding:3px 12px;font-weight:bold;cursor:pointer;font-size:12px;}
.qos-btn-disabled{background:#e53935;color:#fff;border:1px solid #c62828;border-radius:3px;padding:3px 12px;font-weight:bold;cursor:pointer;font-size:12px;}
</style>
<div id="qos-content">
<h2>qosify — Overview</h2>
<% if msg then %><div class="alert-message notice"><%=pcdata(msg)%></div><% end %>
<fieldset class="cbi-section">
<legend>Service Status</legend>
<table class="qos-tbl">
<tr><td>Package</td>
<td><% if has_bin then %><span class="qos-ok">&#x2714; Installed</span><% else %><span class="qos-err">&#x2718; Not Installed</span><% end %></td></tr>
<tr><td>Init Script</td>
<td><% if has_init then %><span class="qos-ok">&#x2714; Available</span><% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>Autostart</td>
<td><% if enabled then %><span class="qos-badge qos-badge-green">Enabled</span><% else %><span class="qos-badge qos-badge-red">Disabled</span><% end %></td></tr>
<tr><td>Status</td>
<td><% if running then %><span class="qos-badge qos-badge-green">Running</span><% else %><span class="qos-badge qos-badge-red">Not Running</span><% end %></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Interface Configuration</legend>
<table class="qos-tbl">
<tr><td>WAN Interface</td>
<td><strong><%=pcdata(wan_iface)%></strong>
<% if wan_disabled then %><span class="qos-badge qos-badge-red" style="margin-left:8px;">QoS Disabled</span>
<% else %><span class="qos-badge qos-badge-green" style="margin-left:8px;">QoS Active</span><% end %></td></tr>
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
<table class="qos-tbl">
<tr><td>/etc/config/qosify</td>
<td><% if has_uci then %><span class="qos-ok">&#x2714; Found</span><% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
<tr><td>/etc/qosify/00-defaults.conf</td>
<td><% if has_def then %><span class="qos-ok">&#x2714; Found</span>
<% if num_rules and num_rules>0 then %><span style="color:#888;margin-left:8px;font-size:12px;">(<%=num_rules%> active rules)</span><% end %>
<% else %><span class="qos-err">&#x2718; Missing</span><% end %></td></tr>
</table>
</fieldset>
<fieldset class="cbi-section">
<legend>Service Controls</legend>
<div class="qos-actions">
<form method="post" action="<%=REQUEST_URI%>" style="display:inline;">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="<%= enabled and 'disable' or 'enable' %>"/>
<input class="<%= enabled and 'qos-btn-enabled' or 'qos-btn-disabled' %>" type="submit"
 value="<%= enabled and 'Enabled' or 'Disabled' %>"
 title="<%= enabled and 'Click to disable autostart' or 'Click to enable autostart' %>"/>
</form>
<% local btns={"start","stop","restart","reload"} %>
<% for _,a in ipairs(btns) do %>
<form method="post" action="<%=REQUEST_URI%>" style="display:inline;">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="<%=a%>"/>
<input class="cbi-button cbi-button-<%= (a=='stop') and 'reset' or 'apply' %>" type="submit" value="<%=a:sub(1,1):upper()..a:sub(2)%>"/>
</form>
<% end %>
</div>
</fieldset>
<p style="font-size:14px;color:#888;margin:12px 0 4px 0;"><strong>Luci-app-qosify</strong> version <%=pcdata(qos_ver)%></p>
<div style="text-align:right;color:#888;font-size:11px;margin-top:8px;">Auto-refresh in <span id="qos-countdown">5</span>s</div>
</div>
<script type="text/javascript">
(function(){var t=5;function refresh(){var x=new XMLHttpRequest();x.open('GET',location.href,true);x.onload=function(){if(x.status===200){var d=document.createElement('div');d.innerHTML=x.responseText;var n=d.querySelector('#qos-content');var o=document.getElementById('qos-content');if(n&&o){o.innerHTML=n.innerHTML;t=5;tick();}else{location.reload();}}else{location.reload();}};x.onerror=function(){location.reload();};x.send();}function tick(){var e=document.getElementById('qos-countdown');if(e)e.textContent=t;if(t<=0){refresh();}else{t--;setTimeout(tick,1000);}}tick();})();
</script>
<%+footer%>
HTMEOF

	# Tab 2: Status
	cat > "$VIEW_DIR/stats.htm" << 'HTMEOF'
<%+header%>
<div id="qos-content">
<h2>qosify — Status</h2>
<fieldset class="cbi-section">
<legend>qosify-status</legend>
<% if not running then %>
<div class="alert-message warning"><strong>qosify is not running.</strong> Start from the <a href="<%=luci.dispatcher.build_url("admin/network/qosify/overview")%>">Overview</a> tab.</div>
<% elseif status_out=="" then %>
<p style="color:#888;"><em>qosify-status returned no output.</em></p>
<% else %>
<pre style="background:#1e1e1e;color:#e0e0e0;padding:12px;border:1px solid #333;border-radius:4px;overflow-x:auto;font-size:12px;line-height:1.5;white-space:pre-wrap;"><%=pcdata(status_out)%></pre>
<% end %>
</fieldset>
<div style="text-align:right;color:#888;font-size:11px;margin-top:8px;">Auto-refresh in <span id="qos-countdown">5</span>s</div>
</div>
<script type="text/javascript">
(function(){var t=5;function refresh(){var x=new XMLHttpRequest();x.open('GET',location.href,true);x.onload=function(){if(x.status===200){var d=document.createElement('div');d.innerHTML=x.responseText;var n=d.querySelector('#qos-content');var o=document.getElementById('qos-content');if(n&&o){o.innerHTML=n.innerHTML;t=5;tick();}else{location.reload();}}else{location.reload();}};x.onerror=function(){location.reload();};x.send();}function tick(){var e=document.getElementById('qos-countdown');if(e)e.textContent=t;if(t<=0){refresh();}else{t--;setTimeout(tick,1000);}}tick();})();
</script>
<%+footer%>
HTMEOF

	# Shared: File editor (Tab 3+4)
	cat > "$VIEW_DIR/fileedit.htm" << 'HTMEOF'
<%+header%>
<h2>qosify — <%=pcdata(title)%></h2>
<p class="cbi-section-descr"><%=desc%> &mdash; <code><%=pcdata(path)%></code></p>
<% if msg then %>
<div class="alert-message success"><%=pcdata(msg)%></div>
<script type="text/javascript">setTimeout(function(){location.href=location.href;},5000);</script>
<div style="text-align:right;color:#888;font-size:11px;">Refreshing in 5s...</div>
<% end %>
<fieldset class="cbi-section">
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<textarea name="data" rows="30" style="width:100%;font-family:monospace;font-size:12px;line-height:1.4;tab-size:4;border:1px solid #ccc;padding:6px;"><%=pcdata(content)%></textarea>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" name="apply" value="Save & Apply"/>
</div>
</form>
</fieldset>
<%+footer%>
HTMEOF

	# Tab 5: Advanced
	cat > "$VIEW_DIR/upload.htm" << 'HTMEOF'
<%+header%>
<h2>qosify — Advanced</h2>
<% if msg then %>
<div class="alert-message <% if msg:match("restart") then %>success<% else %>warning<% end %>"><%=pcdata(msg)%></div>
<% if msg:match("restart") then %>
<script type="text/javascript">setTimeout(function(){location.href=location.href;},5000);</script>
<div style="text-align:right;color:#888;font-size:11px;">Refreshing in 5s...</div>
<% end %>
<% end %>
<fieldset class="cbi-section">
<legend>Upload Config Files</legend>
<p class="cbi-section-descr">Select files and click Save &amp; Apply to overwrite and restart qosify.</p>
<form method="post" enctype="multipart/form-data" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="upload"/>
<div class="cbi-value">
<label class="cbi-value-title" style="width:260px;">/etc/config/qosify</label>
<div class="cbi-value-field"><input type="file" name="uci_file"/></div>
</div>
<div class="cbi-value">
<label class="cbi-value-title" style="width:260px;">/etc/qosify/00-defaults.conf</label>
<div class="cbi-value-field"><input type="file" name="def_file"/></div>
</div>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-apply" type="submit" value="Save & Apply"/>
</div>
</form>
</fieldset>
<fieldset class="cbi-section">
<legend>Reset to Factory Defaults</legend>
<p class="cbi-section-descr">Replaces both config files with qosify defaults, qosify will be disabled.</p>
<form method="post" action="<%=REQUEST_URI%>">
<input type="hidden" name="token" value="<%=token%>"/>
<input type="hidden" name="action" value="reset"/>
<div class="cbi-page-actions">
<input class="cbi-button cbi-button-negative" type="submit" value="Reset to Defaults" onclick="return confirm('Reset all qosify config to defaults?')"/>
</div>
</form>
</fieldset>
<%+footer%>
HTMEOF
}

install_reset_script() {
	echo "[*] Setting up reset script..."
	cat > "$VIEW_DIR/reset_defaults.sh" << 'SHEOF'
#!/bin/sh
cat > /etc/qosify/00-defaults.conf << 'CONF'
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
CONF
cat > /etc/config/qosify << 'UCI'
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
UCI
SHEOF
	chmod +x "$VIEW_DIR/reset_defaults.sh"
}

install_all() {
	echo "===== qosify LuCI Installer ====="
	install_qosify
	install_controller
	install_views
	install_reset_script
	install_config_files
	/etc/init.d/qosify restart 2>/dev/null
	flush_luci
	logger -t qosify-luci "LuCI app installed"
	echo "[OK] qosify LuCI app installed"
	echo "[*] Refresh your browser to reach the login page"
}

uninstall_all() {
	echo "===== qosify LuCI Uninstaller ====="
	/etc/init.d/qosify stop 2>/dev/null
	/etc/init.d/qosify disable 2>/dev/null
	# clean tc qdiscs on wan device (read from uci, fallback to common names)
	WAN_DEV=$(uci -q get qosify.wandev.name 2>/dev/null)
	for dev in ${WAN_DEV:-wan} pppoe-wan br-lan; do
		tc qdisc del dev "$dev" clsact 2>/dev/null
	done
	# clean ifb devices created by qosify
	for ifb in $(ip -o link show type ifb 2>/dev/null | awk -F': ' '{print $2}'); do
		ip link set "$ifb" down 2>/dev/null
		ip link delete "$ifb" type ifb 2>/dev/null
	done
	if command -v apk >/dev/null 2>&1; then
		apk del qosify 2>/dev/null
	elif command -v opkg >/dev/null 2>&1; then
		opkg remove qosify 2>/dev/null
	fi
	rm -f "$UCI_CONFIG" "$DEFAULTS_FILE"
	rmdir "$CONFIG_DIR" 2>/dev/null
	rm -f "$CTRL_DIR/qosify.lua"
	rm -rf /usr/lib/lua/luci/model/cbi/qosify "$VIEW_DIR"
	flush_luci
	logger -t qosify-luci "LuCI app and qosify fully removed"
	echo "[OK] qosify fully uninstalled"
	echo "[*] Refresh your browser to reach the login page"
}

case "$1" in
	install) install_all ;;
	uninstall) uninstall_all ;;
	*) echo "Usage: $0 {install|uninstall}" ;;
esac