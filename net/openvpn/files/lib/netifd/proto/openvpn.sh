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
							[ "$v" = 1 ] && [ -n "$legacy" ] && v="$legacy"
							[ -n "$v" ] && append_config "--auth-gen-token $v"
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
					if [ "$f" = "auth_user_pass_verify" ]; then
						[ -n "$v" ] && append_config "--auth-user-pass-verify $(quote_config_arg "$v") via-file"
						continue
					fi
					# Do not silently drop a metadata verifier if its file is missing.
					if [ "$f" != "tls_crypt_v2_verify" ]; then
						[ -f "$v" ] || continue
					fi
					[ -n "$v" ] && append_config "--${f//_/-} $(quote_config_arg "$v")"
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
'

PROTO_INTS='
metric
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

# Rewrite literal include tokens, including quoted paths and trailing comments.
rewrite_config_line() {
	local dst="$1" tmp="$1.rewrite"
	(
		umask 077
		OPENVPN_CONFIG_ACTION=rewrite OPENVPN_CONFIG_OLD="$2" OPENVPN_CONFIG_NEW="$3" \
			awk -f /usr/share/openvpn/config.awk "$dst" > "$tmp"
	) && mv "$tmp" "$dst" && return 0
	rm -f "$tmp"
	return 1
}

# Recursively copy config files referenced by `config` directives.
# Updates the `config` paths in the destination file to point to the copies.
# Appends all copied files to the global CONFIG_FILES variable.
#
# Usage: copy_config_recursive <dst_file> <visited>
#   dst_file: the already-copied config file to scan for `config` lines
#   visited:  pipe-delimited list of source paths already processed (cycle guard)
copy_config_recursive() {
	local dst="$1"
	local visited="$2"
	local ref original_ref dst_ref fname refs

	refs="$(OPENVPN_CONFIG_ACTION=includes awk -f /usr/share/openvpn/config.awk "$dst")" || return 1
	while IFS= read -r ref; do
		# skip empty lines
		[ -n "$ref" ] || continue
		case "$ref" in
			*"$CONF_PREFIX"*) continue ;;
		esac

		original_ref="$ref"
		# expand relative path to absolute using cd_dir
		case "$ref" in
			/*) ;;
			*) ref="$cd_dir/$ref" ;;
		esac

		# cycle guard
		case "$visited" in
			*"|$ref|"*) continue ;;
		esac

		[ -f "$ref" ] || return 1

		fname="${ref##*/}"
		config_copy_id=$((config_copy_id + 1))
		dst_ref="${CONF_PREFIX}${config}.user_${config_copy_id}_${fname}"

		cp "$ref" "$dst_ref" || {
			logger -t "openvpn_$config(proto)" -p daemon.err "failed to copy config $(quote_config_arg "$ref") to $(quote_config_arg "$dst_ref")"
			return 1
		}

		# rewrite the `config` line in the parent file to point to the copy
		rewrite_config_line "$dst" "$original_ref" "$dst_ref" || return 1

		# accumulate file list
		CONFIG_FILES="$CONFIG_FILES
$dst_ref"

		# recurse
		copy_config_recursive "$dst_ref" "$visited|$ref|" || return 1

	done <<EOF
$refs
EOF
}

proto_openvpn_setup() {
	local config="$1"
	local conf_file="${CONF_PREFIX}$config.conf"
	local exec_params cd_dir cp_file auth_file

	mkdir -p "$CONF_DIR"
	exec_params=

	json_get_var config_file config
	json_get_vars dev dev_type
	if [ -z "$dev_type" ] && [ -z "$config_file" ]; then
		case "$dev" in
			tun*|tap*) ;; # Let OpenVPN infer the type from standard device names.
			*) append_config "--dev-type tun" ;;
		esac
	fi
	json_get_var ovpnproto ovpnproto
	[ -n "$ovpnproto" ] && append_config "--proto $ovpnproto"

	# shellcheck disable=SC2154
	cd_dir="${config_file%/*}"
	[ "$cd_dir" = "$config_file" ] && cd_dir="/"
	append_config "--cd $(quote_config_arg "$cd_dir")"
	append_config "--status ${CONF_PREFIX}$config.status"
	append_config "--syslog openvpn_$config"
	append_config "--tmp-dir /tmp"

	json_get_var ALLOW_DEPRECATED allow_deprecated
	[ -z "$ALLOW_DEPRECATED" ] && ALLOW_DEPRECATED=0

	# Build exec params from configured options we get from ubus values stored during init_config
	option_builder build OPENVPN_BOOLS bool
	option_builder build OPENVPN_UINTS uinteger
	option_builder build OPENVPN_INTS integer
	option_builder build OPENVPN_PARAMS_STRING string
	option_builder build OPENVPN_PARAMS_FILE file
	option_builder build OPENVPN_LIST list

	proto_add_dynamic_defaults

	json_get_vars auth_user_pass askpass username password cert_password

	# Testing option
	# ${tls_exit:+--tls-exit} \

	# Check 'script_security' option
	json_get_var script_security script_security
	[ -z "$script_security" ] && script_security=2

	# Explicit UCI commands take precedence over callbacks in imported profiles.
	if [ "$script_security" -ge 2 ]; then
		local hook command
		for hook in up down route_up route_pre_down tls_verify ipchange learn_address \
			client_connect client_crresponse client_disconnect auth_user_pass_verify; do
			json_get_var command "$hook"
			[ -n "$command" ] && append_config "--setenv user_$hook $(quote_config_arg "$command")"
		done
	fi

	# Write first-phase params to conf_file
	umask 077
	printf '%s\n' "$exec_params" > "$conf_file"
	umask 022

	local CONFIG_FILES="$conf_file" config_copy_id=0
	# Copy user config and recursively copy all referenced config files,
	# rewriting `config` directives to point to the copies in CONF_DIR.
	local user_conf="${CONF_PREFIX}$config.user.conf"
	if [ -n "$config_file" -a -e "$config_file" ]; then
		cp "$config_file" "$user_conf" || {
			logger -t "openvpn_$config(proto)" -p daemon.err "failed to copy config '$config_file'"
			return 1
		}
		CONFIG_FILES="$CONFIG_FILES
$user_conf"
		copy_config_recursive "$user_conf" "" || return 1

		# Imported callbacks retain native argv semantics; explicit UCI callbacks win later.
		local hooks="$conf_file.hooks"
		( umask 077; OPENVPN_CONFIG_ACTION=hooks awk -f /usr/share/openvpn/config.awk "$user_conf" > "$hooks" ) || return 1
		cat "$conf_file" >> "$hooks" && mv "$hooks" "$conf_file" || return 1

		# Update the `config` reference in conf_file to point to the copied user_conf.
		rewrite_config_line "$conf_file" "$config_file" "$user_conf" || return 1
	fi

	if [ "$script_security" -ge 2 ]; then
		local security="$conf_file.security"
		( umask 077; OPENVPN_CONFIG_ACTION=security awk -f /usr/share/openvpn/config.awk "$conf_file" > "$security" ) || return 1
		cat "$security" >> "$conf_file" && rm -f "$security" || return 1
	fi

	local ipv6 defaultroute metric
	exec_params=

	# combine into --askpass:
	if [ -n "$cert_password" ]; then
		cp_file="${CONF_PREFIX}$config.pass"
		umask 077
		printf '%s\n' "${cert_password:-}" > "$cp_file"
		umask 022
	elif [ -n "$askpass" ]; then
		cp_file="$askpass"
	fi

	# combine into --auth-user-pass:
	if [ -n "$username" ] || [ -n "$password" ]; then
		auth_file="${CONF_PREFIX}$config.auth"
		umask 077
		printf '%s\n' "${username:-}" "${password:-}" > "$auth_file"
		umask 022
	elif [ -n "$auth_user_pass" ]; then
		auth_file="$auth_user_pass"
	fi

	#Always Override Options
	append exec_params "--setenv INTERFACE $config"
	append exec_params "--script-security 3"
	append exec_params "--ifconfig-noexec"
	append exec_params "--route-noexec"
	append exec_params "--up '/usr/libexec/openvpn-hotplug'"
	append exec_params "--down '/usr/libexec/openvpn-hotplug'"
	append exec_params "--route-up '/usr/libexec/openvpn-hotplug'"
	append exec_params "--route-pre-down '/usr/libexec/openvpn-hotplug'"
	append exec_params "--persist-tun"
	append exec_params "--persist-key"

	local is_client file
	is_client="$(OPENVPN_CONFIG_ACTION=remote awk -f /usr/share/openvpn/config.awk "$conf_file")" || return 1

	# Filter only real directives, preserving opaque inline data.
	while IFS= read -r file; do
		[ -n "$file" ] || continue
		( umask 077; OPENVPN_CONFIG_ACTION=filter OPENVPN_REDIRECT_OVERRIDE="$is_client" awk -f /usr/share/openvpn/config.awk "$file" > "$file.filter" ) || return 1
		mv "$file.filter" "$file" || return 1
	done <<EOF
$CONFIG_FILES
EOF

	json_get_vars ipv6 defaultroute metric
	#default ipv6 is enabled
	[ -n "$ipv6" ] || ipv6=1
	append exec_params "--setenv IPV6 $ipv6"

	[ -n "$metric" ] && append exec_params "--setenv METRIC $metric"

	if [ "$is_client" = 1 ]; then
		append exec_params "--redirect-gateway def1 ipv6"
		[ -n "$defaultroute" ] || defaultroute=1
	else
		defaultroute=0
	fi
	append exec_params "--setenv DEFAULTROUTE $defaultroute"

	# Read imported options first, then apply the network-managed overrides.
	set -- openvpn --config "$conf_file" $exec_params
	[ -n "$cp_file" ] && set -- "$@" --askpass "$cp_file"
	[ -n "$auth_file" ] && set -- "$@" --auth-user-pass "$auth_file"
	proto_run_command "$config" "$@"

	# last param wins; user provided status or syslog supersedes.
}

proto_openvpn_renew() {
	config="$1"
	local sigusr1

	sigusr1="$(kill -l SIGUSR1)"
	[ -n "$sigusr1" ] && proto_kill_command "$config" "$sigusr1"
}

proto_openvpn_teardown() {
	local iface="$1"

	proto_kill_command "$iface"
	[ -n "$iface" ] && rm -f "${CONF_PREFIX}${iface}."*

	/usr/libexec/openvpn-hotplug cleanup "$iface"

	proto_init_update "*" 0
	proto_send_update "$iface"
}

[ -n "$INCLUDE_ONLY" ] || {
	add_protocol openvpn
}
