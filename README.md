# luci-app-qosify

LuCI web interface for [QoSify](https://openwrt.org/docs/guide-user/network/traffic-shaping/qosify) on OpenWrt.

Adds a **Network → QoSify** menu with tabs for Status, Stats, Config editing, Classification Rules, and Upload/Reset.

## Requirements

- OpenWrt 22.03+ (or snapshot) with LuCI
- `wget` or `curl` (for download)

## Install

SSH into your router and run:

```sh
wget -O /tmp/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
sh /tmp/qosify-luci.sh install
```

Or with curl:

```sh
curl -o /tmp/qosify-luci.sh https://raw.githubusercontent.com/choppyc79/luci-app-qosify/main/qosify-luci.sh
sh /tmp/qosify-luci.sh install
```

The installer will:
1. Install `qosify` if not already present
2. Create the LuCI controller, views, and default config files
3. Clear the LuCI cache and restart services

Once complete, navigate to **Network → QoSify** in LuCI.

## Uninstall

```sh
sh /tmp/qosify-luci.sh uninstall
```

This removes qosify, all config files, and the LuCI app.

## Configuration

After install, go to the **config** tab to set your WAN bandwidth and enable QoS. The default config ships with QoS **disabled** — you must set `disabled` to `0` in the Config tab and adjust `bandwidth_up` / `bandwidth_down` to match your connection.
or you can upload qosify config and 00-defaults.conf files.

## Files

| File | Purpose |
|---|---|
| `/etc/config/qosify` | UCI config (classes, interfaces) |
| `/etc/qosify/00-defaults.conf` | DSCP classification rules |
| `/usr/lib/lua/luci/controller/qosify.lua` | LuCI controller |
| `/usr/lib/lua/luci/view/qosify/*.htm` | LuCI view templates |

## License

MIT
