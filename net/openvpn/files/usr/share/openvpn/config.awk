# Read OpenVPN tokens without evaluating configuration as shell code.
# Quotes start a new token; outside single quotes only \\, \" and whitespace may be escaped.
function tokens(line, word, newline,    i, c, state, escape, value, count, key, out) {
	for (key in word) delete word[key]
	if (newline) line = line "\n"
	state = escape = count = 0
	value = ""
	for (i = 1; i <= length(line) + 1; i++) {
		c = i <= length(line) ? substr(line, i, 1) : " "
		out = ""
		if (!escape && c == "\\" && state != 4) {
			escape = 1
			continue
		}
		if (state == 0) {
			if (c ~ /[[:space:]]/) { escape = 0; continue }
			if (c == "#" || c == ";") { escape = 0; break }
			if (!escape && c == "\"") state = 1
			else if (!escape && c == "'") state = 4
			else { state = 2; out = c }
		} else if (state == 2) {
			if (!escape && c ~ /[[:space:]]/) state = 3
			else out = c
		} else if (state == 1) {
			if (!escape && c == "\"") state = 3
			else out = c
		} else if (state == 4) {
			if (c == "'") state = 3
			else out = c
		}
		if (escape && out != "" && out != "\\" && out != "\"" && out !~ /[[:space:]]/) return -1
		escape = 0
		value = value out
		if (state == 3) { word[++count] = value; value = ""; state = 0 }
	}
	return state == 0 && !escape ? count : -1
}
function quoted(value,    i, c, result) {
	result = "\""
	for (i = 1; i <= length(value); i++) {
		c = substr(value, i, 1)
		if (c == "\\" || c == "\"") result = result "\\"
		result = result c
	}
	return result "\""
}
# Convert native command tokens to shell-quoted words for the user-hook wrapper.
function shellquoted(value,    i, c, result) {
	result = "'"
	for (i = 1; i <= length(value); i++) {
		c = substr(value, i, 1)
		if (c == "'") result = result "'\\''"
		else result = result c
	}
	return result "'"
}
function command(value,    arg, count, i, result) {
	count = tokens(value, arg, 0)
	if (count <= 0) return shellquoted(value)
	result = ""
	for (i = 1; i <= count; i++) {
		if (i > 1) result = result " "
		result = result shellquoted(arg[i])
	}
	return result
}
function collect(file, depth, connection,    line, word, n, option, inline, rc, number) {
	if (depth > 10) { failed = 1; return }
	while ((rc = getline line < file) > 0) {
		if (++number == 1) sub(/^\357\273\277/, "", line)
		if (inline != "") {
			sub(/^[[:space:]]*/, "", line)
			if (index(line, inline) == 1) inline = ""
			continue
		}
		n = tokens(line, word, 1)
		if (n < 0) { failed = 1; break }
		option = word[1]
		sub(/^--/, "", option)
		if (option == "<connection>") { connection++; continue }
		if (option == "</connection>") { connection--; continue }
		if (n == 1 && option ~ /^<[[:alnum:]_-]+>$/) { inline = "</" substr(option, 2); continue }
		if (option == "config" && n == 2) { collect(word[2], depth + 1, connection); continue }
		if (option == "remote" && n >= 2) flags["remote"] = 1
		if (!connection) {
			if (option ~ /^(client|tls-client|tls-server|server|server-bridge|server-ipv6)$/) flags[option] = 1
			if (option == "mode" && n == 2) mode = word[2]
			if (option == "setenv" && n == 3 && word[2] ~ /^user_/) managed[word[2]] = word[3]
		}
		if (!connection && n >= 2 && option ~ /^(up|down|route-up|route-pre-down|tls-verify|ipchange|learn-address|client-connect|client-crresponse|client-disconnect|auth-user-pass-verify)$/) {
			if (word[2] == "") { failed = 1; break }
			hook[option] = word[2]
			if (option == "auth-user-pass-verify" && n == 3) auth_method = word[3]
		}
	}
	close(file)
	if (rc < 0 || inline != "") failed = 1
}
BEGIN {
	action = ENVIRON["OPENVPN_CONFIG_ACTION"]
	if (action == "hooks" || action == "security" || action == "remote") {
		collect(ARGV[1], 0, 0)
		if (failed) exit 1
		if (action == "remote") { print flags["remote"] ? 1 : 0; exit }
		if (action == "security") {
			server = mode == "server" || flags["server"] || flags["server-bridge"] || flags["server-ipv6"]
			client = flags["client"] || flags["tls-client"]
			if (server) {
				enabled["learn-address"] = enabled["client-connect"] = enabled["client-crresponse"] = enabled["client-disconnect"] = 1
				if (("auth-user-pass-verify" in hook) || ("user_auth_user_pass_verify" in managed)) enabled["auth-user-pass-verify"] = 1
			}
			if (server || client || flags["tls-server"] || ("tls-verify" in hook)) enabled["tls-verify"] = 1
			if (client || ("ipchange" in hook)) enabled["ipchange"] = 1
			for (option in enabled) {
				name = "user_" option
				gsub(/-/, "_", name)
				if ((option in hook) && !(name in managed)) print "setenv " name " " quoted(command(hook[option]))
				method = ""
				if (option == "auth-user-pass-verify") method = " " ((name in managed) || auth_method == "" ? "via-file" : auth_method)
				print option " " quoted("/usr/libexec/openvpn-hotplug") method
			}
			exit
		}
		count = split("up down route-up route-pre-down", names, " ")
		for (i = 1; i <= count; i++) if (names[i] in hook) {
			name = names[i]
			gsub(/-/, "_", name)
			print "setenv user_" name " " quoted(command(hook[names[i]]))
		}
		exit
	}
}
{
	if (FNR == 1) sub(/^\357\273\277/, "")
	if (inline_end != "") {
		if (action == "rewrite" || action == "filter") print
		line = $0
		sub(/^[[:space:]]*/, "", line)
		if (index(line, inline_end) == 1) inline_end = ""
		next
	}
	n = tokens($0, word, 1)
	if (n < 0) { failed = 1; exit 1 }
	option = word[1]
	sub(/^--/, "", option)
	if (n == 1 && option ~ /^<[[:alnum:]_-]+>$/ && option != "<connection>")
		inline_end = "</" substr(option, 2)
	if (action == "includes" && option == "config" && n == 2) {
		if (index(word[2], "\n")) { failed = 1; exit 1 }
		print word[2]
	}
	if (option == "<connection>") connection_depth++
	if (option == "</connection>") connection_depth--
	if (action == "filter") {
		if (!connection_depth && (option ~ /^(script-security|ifconfig-noexec|route-noexec|up|down|route-up|route-pre-down|persist-tun|persist-key)$/ ||
			(ENVIRON["OPENVPN_REDIRECT_OVERRIDE"] == "1" && option == "redirect-gateway")))
			print "# " $0
		else print
	}
	if (action == "rewrite") {
		if (option == "config" && n == 2 && word[2] == ENVIRON["OPENVPN_CONFIG_OLD"])
			print "config " quoted(ENVIRON["OPENVPN_CONFIG_NEW"])
		else print
	}
}
END { if (failed || inline_end != "") exit 1 }
