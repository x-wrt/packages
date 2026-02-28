#!/bin/sh

OPENVPN_PKG="openvpn"
NETWORK_PKG="network"

LIST_OPTS=" push route route_ipv6 remote pull_filter tls_cipher "

# Exit if no openvpn config exists
uci -q show "$OPENVPN_PKG" >/dev/null || exit 0

uci batch <<EOF
$(

# Find named openvpn sections
uci show "$OPENVPN_PKG" | \
sed -n "s/^$OPENVPN_PKG\.\\([^=]*\\)=openvpn$/\\1/p" | \
while read -r sec; do
	iface="$sec"

	# Skip if interface already exists
	uci -q get $NETWORK_PKG.$iface >/dev/null && continue

	# Create interface in network 
	echo "set $NETWORK_PKG.$iface=interface"
	# Set the interface protocol to 'openvpn'
	echo "set $NETWORK_PKG.$iface.proto='openvpn'"

	# Copy options, skipping the section header
	uci show "$OPENVPN_PKG.$sec" | \
	while IFS='=' read -r key val; do
		case "$key" in
			# section declaration: openvpn.vpn0=openvpn
			"$OPENVPN_PKG.$sec") continue ;;
			"$OPENVPN_PKG.$sec.proto")
				echo "set $NETWORK_PKG.$iface.ovpnproto=$val"
				continue
				;;
		esac

		opt="${key##*.}"

		eval "set -- $val"

		if [ $# -gt 1 ] || echo "$LIST_OPTS" | grep -q " $opt "; then
			for item in "$@"; do
				echo "add_list $NETWORK_PKG.$iface.$opt='$item'"
			done
		else
			echo "set $NETWORK_PKG.$iface.$opt='$1'"
		fi
	done
done

echo "commit $NETWORK_PKG"
)
EOF

exit 0
