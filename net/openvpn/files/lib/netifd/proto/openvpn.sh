#!/bin/sh
# OpenVPN netifd proto handler for OpenWrt
# Copyright (C) 2026
# shellcheck disable=SC1091,2046,2091,3043,3060

[ -x /usr/sbin/openvpn ] || exit 0

[ -n "$INCLUDE_ONLY" ] || {
	. /lib/functions.sh
	. /usr/share/openvpn/openvpn.options # OPENVPN_* options
	. ../netifd-proto.sh
	. /usr/share/libubox/jshn.sh
	init_proto "$@"
}

CONF_DIR="/var/run"
CONF_PREFIX="${CONF_DIR}/openvpn."

quote_config_arg() {
	local value="$1"
	value="${value//\\/\\\\}"
	value="${value//\"/\\\"}"
	printf '"%s"' "$value"
}

append_config() {
	# Each call contributes one complete directive; values may contain -- or backslashes.
	append exec_params "${1#--}" "
"
}

# Helper to DRY up repeated option handling in init/setup
option_builder() {
	# option_builder <action:add|build> <LIST_VAR_NAME> <type>
	local action="$1"; shift
	local list_var="$1"; shift
	local opt_type="$1"; shift
	local f v legacy

	for f in $(eval echo \$"$list_var")
	do
		if [ "$action" = "add" ]; then
			f=${f%%:*}
			case "$opt_type" in
				bool) proto_config_add_boolean "$f:bool" ;;
				protobool) proto_config_add_boolean "$f:protobool" ;;
				uinteger) proto_config_add_int "$f:uinteger" ;;
				integer) proto_config_add_int "$f:integer" ;;
				string) proto_config_add_string "$f:string" ;;
				protostring) proto_config_add_string "$f:protostring" ;;
				file) proto_config_add_string "$f:file" ;;
				list) proto_config_add_array "$f:list" ;;
			esac
		elif [ "$action" = "build" ]; then
			[ "${f#*:}" = "d" ] && [ "$ALLOW_DEPRECATED" = 0 ] && continue
			f=${f%%:*}
			case "$opt_type" in
				bool)
					json_get_var v "$f"
					[ "$v" = 1 ] && append_config "--${f//_/-}"
					;;
				uinteger|integer|string)
					json_get_var v "$f"
					case $f in
						tun_mtu_max)
							[ -n "$v" ] || json_get_var v tun_max_mtu
							[ -n "$v" ] && append_config "--tun-mtu-max $v"
						;;
						auth_gen_token)
							# Older UCI configurations split the enable flag and lifetime.
							json_get_var legacy auth_gen_token_lifetime
							if [ "$v" = 1 ]; then
								append_config "--auth-gen-token${legacy:+ $legacy}"
							elif [ -n "$v" ]; then
								append_config "--auth-gen-token $v"
							fi
						;;
						push_remove)
							[ -n "$v" ] && append_config "--${f//_/-} $(quote_config_arg "$v")"
						;;
						*)
							[ -n "$v" ] && append_config "--${f//_/-} $v"
						;;
					esac
					;;
				file)
					json_get_var v "$f"
					[ -n "$v" ] || continue
					if [ "$f" = "auth_user_pass_verify" ]; then
						append_config "--auth-user-pass-verify $(quote_config_arg "$v") via-file"
						continue
					fi
					# These include directories, output paths, commands and special values
					# (e.g. dh none). Let OpenVPN validate them in its working directory.
					append_config "--${f//_/-} $(quote_config_arg "$v")"
					;;
				list)
					local type
					json_get_type type "$f"
					case "$type" in
					object|array)
						local keys key joined=
						json_select "$f"
						json_get_keys keys
						for key in $keys; do
							json_get_var val "$key"
							case $f in
								data_ciphers|tls_cipher|tls_ciphersuites|tls_groups)
									[ -n "$val" ] && append joined "$val" ':'
								;;
								push)
									append_config "--${f//_/-} $(quote_config_arg "$val")"
								;;
								*)
									append_config "--${f//_/-} $val"
								;;
							esac
						done
						json_select ..
						[ -n "$joined" ] && append_config "--${f//_/-} $(quote_config_arg "$joined")"
						;;
					string)
						case "$f" in
							route)
								json_get_var v "$f"
								[ -n "$v" ] && append_config "--route $v"
								;;
							data_ciphers|tls_cipher|tls_ciphersuites|tls_groups)
								json_get_var v "$f"
								[ -n "$v" ] && append_config "--${f//_/-} $(quote_config_arg "$v")"
							;;
						esac
						;;
					*)  ;;
					esac
					;;
			esac
		fi
	done
	return 0
}

# Not real config params used by openvpn - only by our proto handler
PROTO_BOOLS='
allow_deprecated
defaultroute
ipv6
'

PROTO_STRINGS='
username
password
cert_password
ovpnproto
tunlink
config_version
'

PROTO_INTS='
metric
mtu
'

# Legacy names are accepted as inputs, never emitted as OpenVPN options.
PROTO_UINTS='
auth_gen_token_lifetime
tun_max_mtu
'

proto_openvpn_init_config() {
	available=1
	no_device=1
	lasterror=1
	renew_handler=1

	# There may be opvnvpn options which mean that a tap L2 device exists.
	# TODO: Set no_device to depend on tap device

	proto_add_dynamic_defaults

	# Add proto config options - netifd compares these for changes between interface events
	option_builder add PROTO_BOOLS protobool
	option_builder add PROTO_STRINGS string
	option_builder add PROTO_INTS integer
	option_builder add PROTO_UINTS uinteger
	option_builder add OPENVPN_BOOLS bool
	option_builder add OPENVPN_UINTS uinteger
	option_builder add OPENVPN_INTS integer
	option_builder add OPENVPN_PARAMS_STRING string
	option_builder add OPENVPN_PARAMS_FILE file
	option_builder add OPENVPN_LIST list
}

# Build privately, then publish only after all inputs and credentials are ready.
proto_openvpn_setup() (
	local config="$1" conf_file="${CONF_PREFIX}$1.conf" stage generation
	local exec_params cd_dir cp_file auth_file config_file error option directory
	local is_client role ignored ipv6 defaultroute metric tunlink mtu command hook
	local published=0 prepared=0

	case "$config" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac

	setup_error() {
		logger -t "openvpn_$config(proto)" -p daemon.err "setup failed: $1 ${2:-}"
		[ "$published" = 0 ] || rm -f "$conf_file" "${CONF_PREFIX}$config.auth" "${CONF_PREFIX}$config.pass"
		[ "$prepared" = 0 ] || /usr/libexec/openvpn-hotplug cleanup "$config"
		proto_notify_error "$config" "$@"
		proto_setup_failed "$config"
		return 1
	}

	umask 077
	mkdir -p "$CONF_DIR" || { setup_error CONFIG_WRITE_FAILED; return 1; }
	stage="$(mktemp -d "${CONF_PREFIX}$config.build.XXXXXX")" || { setup_error CONFIG_WRITE_FAILED; return 1; }
	trap 'rm -rf "$stage"' EXIT
	trap 'exit 1' HUP INT TERM

	json_get_var config_file config
	if [ -n "$config_file" ] && [ ! -f "$config_file" ]; then
		setup_error INVALID_OPTION config
		return 1
	fi
	cd_dir="${config_file%/*}"
	[ -n "$cd_dir" ] && [ "$cd_dir" != "$config_file" ] || cd_dir=/
	case "$cd_dir" in /*) ;; *) cd_dir="$PWD/$cd_dir" ;; esac
	# config is resolved before OpenVPN's initial cd, so keep its input absolute.
	case "$config_file" in ''|/*) ;; *) config_file="$PWD/$config_file"; json_add_string config "$config_file" ;; esac
	exec_params=
	append_config "--cd $(quote_config_arg "$cd_dir")"
	append_config "--status ${CONF_PREFIX}$config.status"
	append_config "--syslog openvpn_$config"
	append_config "--tmp-dir /tmp"
	json_get_vars dev dev_type ovpnproto
	if [ -z "$dev_type" ] && [ -z "$config_file" ]; then
		case "$dev" in tun*|tap*) ;; *) append_config "--dev-type tun" ;; esac
	fi
	[ -z "$ovpnproto" ] || append_config "--proto $ovpnproto"
	json_get_var ALLOW_DEPRECATED allow_deprecated
	: "${ALLOW_DEPRECATED:=0}"
	option_builder build OPENVPN_BOOLS bool
	option_builder build OPENVPN_UINTS uinteger
	option_builder build OPENVPN_INTS integer
	option_builder build OPENVPN_PARAMS_STRING string
	option_builder build OPENVPN_PARAMS_FILE file
	option_builder build OPENVPN_LIST list
	for hook in up down route_up route_pre_down tls_verify ipchange learn_address \
		client_connect client_crresponse client_disconnect auth_user_pass_verify; do
		json_get_var command "$hook"
		[ -z "$command" ] || append_config "--setenv user_$hook $(quote_config_arg "$command")"
	done
	printf '%s\n' "$exec_params" > "$stage/input" || { setup_error CONFIG_WRITE_FAILED; return 1; }
	if ! OPENVPN_CONFIG_META="$stage/meta" \
		OPENVPN_CONFIG_DIRS="$stage/dirs" OPENVPN_CONFIG_ERROR="$stage/error" \
		awk -f /usr/share/openvpn/config.awk "$stage/input" > "$stage/config"; then
		error=INVALID_CONFIG option=config
		[ ! -s "$stage/error" ] || read -r error option < "$stage/error"
		setup_error "$error" "$option"
		return 1
	fi
	while IFS= read -r directory; do
		[ -d "$directory" ] || { setup_error INVALID_OPTION cd; return 1; }
	done < "$stage/dirs"
	read -r is_client role ignored < "$stage/meta" || { setup_error INVALID_CONFIG; return 1; }
	[ "$ignored" = - ] || logger -t "openvpn_$config(proto)" -p daemon.warn "netifd overrides incompatible options: $ignored"

	json_get_vars auth_user_pass askpass username password cert_password
	if [ -n "$cert_password" ]; then
		printf '%s\n' "$cert_password" > "$stage/pass" || { setup_error CONFIG_WRITE_FAILED askpass; return 1; }
		cp_file="${CONF_PREFIX}$config.pass"
	else
		cp_file="$askpass"
	fi
	if [ -n "$username" ] || [ -n "$password" ]; then
		printf '%s\n' "$username" "$password" > "$stage/auth" || { setup_error CONFIG_WRITE_FAILED auth_user_pass; return 1; }
		auth_file="${CONF_PREFIX}$config.auth"
	else
		auth_file="$auth_user_pass"
	fi
	json_get_vars ipv6 defaultroute metric tunlink mtu
	case "$mtu" in ''|*[!0-9]*) [ -z "$mtu" ] || { setup_error INVALID_OPTION mtu; return 1; } ;; esac
	[ -z "$mtu" ] || { [ "$mtu" -ge 68 ] && [ "$mtu" -le 65535 ]; } || { setup_error INVALID_OPTION mtu; return 1; }
	: "${ipv6:=1}"
	if [ "$is_client" = 1 ]; then
		: "${defaultroute:=1}"
	else
		defaultroute=0
	fi
	generation="$(cat /proc/sys/kernel/random/uuid)" || { setup_error STATE_INIT_FAILED; return 1; }
	[ -n "$generation" ] || { setup_error STATE_INIT_FAILED; return 1; }
	OPENVPN_GENERATION="$generation" ROLE="$role" IGNORED_OPTIONS="$ignored" \
		DEFAULTROUTE="$defaultroute" METRIC="$metric" TUNLINK="$tunlink" \
		/usr/libexec/openvpn-hotplug prepare "$config" || { setup_error STATE_INIT_FAILED; return 1; }
	prepared=1
	published=1
	mv "$stage/config" "$conf_file" || { setup_error CONFIG_WRITE_FAILED; return 1; }
	[ ! -e "$stage/auth" ] || mv "$stage/auth" "$auth_file" || { setup_error CONFIG_WRITE_FAILED auth_user_pass; return 1; }
	[ ! -e "$stage/pass" ] || mv "$stage/pass" "$cp_file" || { setup_error CONFIG_WRITE_FAILED askpass; return 1; }

	# All overrides are argv entries; imported configuration has already been filtered.
	set -- openvpn
	if [ "$is_client" = 1 ] && [ "$defaultroute" = 0 ]; then
		# Filters use the first match. Put these before imported accept rules so
		# pushed IPv6 redirect fragments cannot bypass netifd's default-route policy.
		set -- "$@" --pull-filter ignore redirect-gateway --pull-filter ignore redirect-private
	fi
	set -- "$@" --config "$conf_file" \
		--setenv INTERFACE "$config" --setenv OPENVPN_GENERATION "$generation" \
		--script-security 3 --ifconfig-noexec --route-noexec \
		--up /usr/libexec/openvpn-hotplug --down /usr/libexec/openvpn-hotplug \
		--route-up /usr/libexec/openvpn-hotplug --route-pre-down /usr/libexec/openvpn-hotplug \
		--persist-tun --persist-key --up-restart \
		--setenv IPV6 "$ipv6" --setenv DEFAULTROUTE "$defaultroute"
	[ -z "$metric" ] || set -- "$@" --setenv METRIC "$metric"
	[ -z "$tunlink" ] || set -- "$@" --setenv TUNLINK "$tunlink"
	[ -z "$mtu" ] || set -- "$@" --setenv NETIFD_MTU "$mtu"
	if [ "$is_client" = 1 ]; then
		set -- "$@" --ipchange /usr/libexec/openvpn-hotplug
		if [ "$defaultroute" = 1 ]; then
			set -- "$@" --setenv NETIFD_REDIRECT_GATEWAY 1 --redirect-gateway def1 ipv6
		fi
	fi
	[ -z "$cp_file" ] || set -- "$@" --askpass "$cp_file"
	[ -z "$auth_file" ] || set -- "$@" --auth-user-pass "$auth_file"
	proto_run_command "$config" "$@" || { setup_error PROCESS_START_FAILED; return 1; }
)

proto_openvpn_renew() {
	config="$1"
	local sigusr1

	sigusr1="$(kill -l SIGUSR1)"
	/usr/libexec/openvpn-hotplug renew "$config" || return 1
	[ -n "$sigusr1" ] && proto_kill_command "$config" "$sigusr1"
}

proto_openvpn_teardown() {
	local iface="$1" stage file

	proto_kill_command "$iface"

	/usr/libexec/openvpn-hotplug cleanup "$iface"
	case "$iface" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	for file in "${CONF_PREFIX}${iface}."*; do
		[ ! -f "$file" ] || rm -f "$file"
	done
	for stage in "${CONF_PREFIX}${iface}.build."*; do
		[ ! -d "$stage" ] || rm -rf "$stage"
	done

	# netifd completes link-down itself; updates are rejected during teardown.
	return 0
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol openvpn
}
