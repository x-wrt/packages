#!/bin/sh

OPENVPN_PKG="/etc/config/openvpn"
NETWORK_PKG="/etc/config/network"

[ -f "$OPENVPN_PKG" ] || exit 0

# UCI supplies canonical shell quoting and stable names for anonymous sections.
data="$(uci -q -n export openvpn)" || exit 1
migrating=0
write_failed=0
emit() { printf "$@" || write_failed=1; }

quote_value() {
	local value="$1" head
	emit "'"
	while :; do
		case "$value" in
			*"'"*)
				head="${value%%\'*}"
				emit '%s%s' "$head" "'\\''"
				value="${value#*\'}"
			;;
			*) emit "%s'" "$value"; break ;;
		esac
	done
}

package() { :; }
config() {
	migrating=0
	[ "$1" = openvpn ] || return 0
	[ -n "$2" ] || return 1
	uci -q get "network.$2" >/dev/null 2>&1 && return 0
	migrating=1
	emit "config interface '%s'\n\toption proto 'openvpn'\n\toption auto '0'\n" "$2"
}

emit_setting() {
	local kind="$1" key="$2" value="$3"
	[ "$migrating" = 1 ] || return 0
	case "$key" in
		proto) key=ovpnproto ;;
		enable|enabled|disable|disabled|auto) return 0 ;;
	esac
	emit '\t%s %s ' "$kind" "$key"
	quote_value "$value"
	emit '\n'
}
option() { emit_setting option "$1" "$2"; }
list() { emit_setting list "$1" "$2"; }

archive="${OPENVPN_PKG}_migrated"
[ ! -e "$archive" ] && [ ! -L "$archive" ] || exit 1
umask 077
workdir="$(mktemp -d /etc/config/.openvpn-migrate.XXXXXX)" || exit 1
keep_backup=0
cleanup() { [ "$keep_backup" = 1 ] || rm -rf "$workdir"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

had_network=0
if [ -e "$NETWORK_PKG" ]; then
	uci -q export network >/dev/null || exit 1
	cp -p "$NETWORK_PKG" "$workdir/original" || exit 1
	cp -p "$NETWORK_PKG" "$workdir/network" || exit 1
	had_network=1
else
	: > "$workdir/network" || exit 1
fi

# A valid existing UCI file need not end in a newline.
emit '\n' >> "$workdir/network"
eval "$data" >> "$workdir/network" || exit 1
[ "$write_failed" = 0 ] || exit 1
mkdir "$workdir/delta" || exit 1
uci -q -c "$workdir" -t "$workdir/delta" export network >/dev/null || exit 1
mv "$workdir/network" "$NETWORK_PKG" || exit 1
if ! mv "$OPENVPN_PKG" "$archive"; then
	if [ "$had_network" = 1 ]; then
		if ! mv "$workdir/original" "$NETWORK_PKG"; then
			keep_backup=1
			logger -t openvpn-migrate -p daemon.err "network rollback failed; backup kept at $workdir/original"
		fi
	else
		rm -f "$NETWORK_PKG" || keep_backup=1
	fi
	exit 1
fi
exit 0
