# Tailscale
This readme should help you with tailscale client setup.

> [!NOTE]
> The firewall backend is selected by `fw_mode` in `/etc/config/tailscale`:
> `iptables` or `nftables`. Restart the service after changing it.

## Routing settings

The default configuration installs Tailscale routes in the main routing table
with metric 4096, without Tailscale policy routing rules or throw routes:

```uci
config settings 'settings'
	option route_table 'main'
	option route_metric '4096'
```

The init script also uses these defaults when upgrading an existing config
that does not contain the new options. The `20261030` source tag lets tailscaled
read `TS_ROUTE_TABLE` and `TS_ROUTE_METRIC` before installing any routes, so an old
saved profile cannot briefly enable table 52 during startup. These service
settings override the profile's `tailscale up/set` routing preferences;
`tailscale get` still displays the saved profile values.

Choose a metric higher than the LAN route's metric. LAN routes with the same
prefix then win; a more specific Tailscale prefix still takes priority. Main
mode changes exit-node behavior because transport bypass and exit-node LAN
exclusions normally depend on policy routing. A Tailscale default route with a
higher metric also loses to an existing WAN default route.

To use the standard table 52 and policy rules instead:

```sh
uci set tailscale.settings.route_table='52'
uci set tailscale.settings.route_metric='0'
uci commit tailscale
/etc/init.d/tailscale restart
```

## First setup

First, enable and run daemon

```
/etc/init.d/tailscale enable
/etc/init.d/tailscale start
```

Then you should use tailscale utility to get a login link for your device.

Run command and finish device registration with the given URL.
```
tailscale up
```

See the [OpenWrt wiki](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start) for more detailed setup instructions
