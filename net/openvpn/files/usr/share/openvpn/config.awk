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
# Build one snapshot in native load order. cd is process-wide, including across
# includes; keep filesystem resolution (not lexical .. reduction through symlinks).
function absolute(path) { return substr(path, 1, 1) == "/" ? path : cwd "/" path }
function compile_error(code, option) {
	if (!failed) print code, option > ENVIRON["OPENVPN_CONFIG_ERROR"]
	failed = 1
}
function compile_file(file, depth,    line, word, n, option, inline, rc, number) {
	if (depth > 10 || active[file]) { compile_error("CONFIG_CYCLE", "config"); return }
	active[file] = 1
	while (!failed && (rc = getline line < file) > 0) {
		if (++number == 1) sub(/^\357\273\277/, "", line)
		if (inline != "") {
			program[++lines] = line
			sub(/^[[:space:]]*/, "", line)
			if (index(line, inline) == 1) inline = ""
			continue
		}
		n = tokens(line, word, 1)
		if (n < 0) { compile_error("INVALID_CONFIG", "syntax"); break }
		option = word[1]; sub(/^--/, "", option)
		if (n == 1 && option ~ /^<[[:alnum:]_-]+>$/ && option != "<connection>")
			inline = "</" substr(option, 2)
		if (option == "config" && n == 2) {
			if (index(word[2], "\n")) { compile_error("INVALID_CONFIG", "config"); break }
			compile_file(absolute(word[2]), depth + 1)
			continue
		}
		if (option == "cd" && n == 2) {
			if (index(word[2], "\n")) { compile_error("INVALID_CONFIG", "cd"); break }
			cwd = absolute(word[2])
			print cwd > ENVIRON["OPENVPN_CONFIG_DIRS"]
			line = "cd " quoted(cwd)
		}
		if (option == "<connection>") connection++
		if (option == "</connection>" && --connection < 0) { compile_error("INVALID_CONFIG", "connection"); break }
		program[++lines] = line
		if (option == "remote" && n >= 2) flags["remote"] = 1
		if (!connection) {
			if (option ~ /^(client|tls-client|tls-server|server|server-bridge|server-ipv6)$/) flags[option] = 1
			if (option == "mode" && n == 2) mode = word[2]
			if (option == "setenv" && n == 3 && word[2] ~ /^user_/) managed[word[2]] = word[3]
			if (option ~ /^(user|group|chroot)$/) {
				ignored[option] = 1
				program[lines] = "# netifd overrides " line
			}
			if (n >= 2 && option ~ /^(up|down|route-up|route-pre-down|tls-verify|ipchange|learn-address|client-connect|client-crresponse|client-disconnect|auth-user-pass-verify)$/) {
				if (word[2] == "") { compile_error("INVALID_CONFIG", option); break }
				hook[option] = word[2]
				if (option == "auth-user-pass-verify" && n == 3) auth_method = word[3]
			}
		}
	}
	close(file); delete active[file]
	if (rc < 0) compile_error("CONFIG_READ_FAILED", "config")
	if (inline != "") compile_error("INVALID_CONFIG", "inline")
}
function managed_option(option) {
	return option ~ /^(daemon|script-security|ifconfig-noexec|route-noexec|up|down|route-up|route-pre-down|persist-tun|persist-key|up-restart)$/ ||
		(flags["remote"] && option ~ /^(ipchange|redirect-gateway|redirect-private)$/)
}
function compile_output(    i, word, option, name, count, ignored_names) {
	server = mode == "server" || flags["server"] || flags["server-bridge"] || flags["server-ipv6"]
	client = flags["client"] || flags["tls-client"]
	for (i = 1; i <= lines; i++) {
		# Skip opaque data using the same inline boundary as the input pass.
		if (inline_end != "") {
			print program[i]
			line = program[i]; sub(/^[[:space:]]*/, "", line)
			if (index(line, inline_end) == 1) inline_end = ""
			continue
		}
		count = tokens(program[i], word, 1)
		option = word[1]; sub(/^--/, "", option)
		if (count == 1 && option ~ /^<[[:alnum:]_-]+>$/ && option != "<connection>") inline_end = "</" substr(option, 2)
		print (managed_option(option) ? "# " : "") program[i]
	}
	if (server) {
		enabled["learn-address"] = enabled["client-connect"] = enabled["client-crresponse"] = enabled["client-disconnect"] = 1
		if (("auth-user-pass-verify" in hook) || ("user_auth_user_pass_verify" in managed)) enabled["auth-user-pass-verify"] = 1
	}
	if (server || client || flags["tls-server"] || ("tls-verify" in hook)) enabled["tls-verify"] = 1
	if (client || flags["remote"] || ("ipchange" in hook)) enabled["ipchange"] = 1
	count = split("up down route-up route-pre-down", names, " ")
	for (i = 1; i <= count; i++) if (names[i] in hook) enabled[names[i]] = 1
	for (option in enabled) {
		name = "user_" option; gsub(/-/, "_", name)
		if ((option in hook) && !(name in managed)) print "setenv " name " " quoted(command(hook[option]))
		if (option ~ /^(up|down|route-up|route-pre-down)$/) continue
		method = option == "auth-user-pass-verify" ? " " ((name in managed) || auth_method == "" ? "via-file" : auth_method) : ""
		print option " " quoted("/usr/libexec/openvpn-hotplug") method
	}
	count = split("user group chroot", names, " ")
	for (i = 1; i <= count; i++) if (names[i] in ignored) ignored_names = sprintf("%s%s%s", ignored_names, ignored_names == "" ? "" : ",", names[i])
	print (flags["remote"] ? 1 : 0), (server ? "server" : client ? "client" : "peer"), (ignored_names == "" ? "-" : ignored_names) > ENVIRON["OPENVPN_CONFIG_META"]
}
BEGIN {
	cwd = "/"
	compile_file(ARGV[1], 0)
	if (connection) compile_error("INVALID_CONFIG", "connection")
	if (!failed) compile_output()
	exit failed ? 1 : 0
}
