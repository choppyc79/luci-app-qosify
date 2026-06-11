# luci-app-qosify

LuCI web interface for [qosify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → qosify** menu with tabs for Overview, Config editing, Classification Rules, Advanced, and Status.

## Screenshots

### Overview
Service status, Quick Settings form, config file validation, and service controls at a glance.

### Config
Edit the UCI configuration (`/etc/config/qosify`) directly — set bandwidth, classes, interfaces, and queue options. Includes a Config Reference panel showing all stanza types and current class details, plus a Quick Add Config form for building `config defaults`, `config class`, and `config interface` stanzas from dropdowns.

### Classification Rules
Edit DSCP classification rules (`/etc/qosify/00-defaults.conf`) — map ports, protocols, IPs, and DNS patterns to traffic classes. Includes a Quick Add form supporting all qosify match types and an Available Classes reference.

### Advanced
Backup current config files, upload replacements, or reset both configs back to defaults.

### Status
Live `qosify-status` output showing CAKE qdisc stats for egress and ingress, auto-refreshing every 5 seconds.

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
- `wget` or `curl` (for download)
- `luci-base` (preinstalled with LuCI)

## Install

SSH into your router and run:

```sh
wget -O /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

Or with curl:

```sh
curl -o /root/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
chmod +x /root/qosify-luci.sh
/root/qosify-luci.sh install
```

The installer will:
1. Install `qosify` if not already present
2. Drop the LuCI menu entry, ACL definition, and JS view into the standard LuCI paths
3. Create default config files
4. Restart rpcd and the web server so the new menu appears

Once complete, navigate to **Network → qosify** in LuCI.

## Uninstall

```sh
/root/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app. `luci-base` is left in place.

## Configuration

After install, use the **Quick Settings** form on the Overview tab to set your WAN bandwidth, enable QoS, and adjust common CAKE options — no raw config editing needed. The default config ships with QoS **disabled** for safe first-run.

For full control, the **Config** tab provides an inline editor for `/etc/config/qosify` with a Quick Add Config form for building class, defaults, and interface stanzas from dropdowns — all options are constrained to valid values (DSCP codepoints, CAKE overhead types, diffserv modes). The **Classification Rules** tab edits `/etc/qosify/00-defaults.conf` with a Quick Add form supporting all qosify match types (tcp/udp ports, DNS patterns, DNS regex, IPv4/IPv6 addresses). Alternatively, use the **Advanced** tab to upload pre-configured files.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/share/luci/menu.d/luci-app-qosify.json` | LuCI menu entry |
| `/usr/share/rpcd/acl.d/luci-app-qosify.json` | rpcd ACL grants |
| `/www/luci-static/resources/view/qosify/main.js` | LuCI JS view (single-page) |
| `/usr/share/qosify-luci/` | Default config templates (used by the Reset button) |

## License

MIT
