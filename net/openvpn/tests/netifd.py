#!/usr/bin/env python3
"""Isolated netifd regression tests; see README.md for prerequisites."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--openwrt", type=Path, required=True)
parser.add_argument("--busybox", type=Path, required=True)
parser.add_argument("--native-dir", type=Path, help="optional directory containing native ubus/ and netifd/ builds")
args = parser.parse_args()
openwrt = args.openwrt.resolve()
busybox = args.busybox.resolve()
source = Path(__file__).resolve().parents[1] / "files"
netifd = next(openwrt.glob("build_dir/target-*/netifd-*/scripts"))
jshn = next(openwrt.glob("build_dir/target-*/libubox-*/sh/jshn.sh"))
assert shutil.which("bwrap"), "bubblewrap is required"
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


# All writes and simulated network operations stay in this disposable namespace.
with tempfile.TemporaryDirectory(prefix="openvpn-netifd-test-") as directory:
    work = Path(directory)

    def write(name, text, executable=False):
        path = work / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o755)
        return path

    for name in ("bin", "run", "lock", "profiles", "etc/hotplug.d/openvpn"):
        (work / name).mkdir(parents=True)
    shutil.copyfile(source / "etc/hotplug.d/openvpn/01-user", work / "etc/hotplug.d/openvpn/01-user")
    shutil.copyfile(source / "usr/libexec/openvpn-hotplug", work / "openvpn-hotplug")
    (work / "openvpn-hotplug").chmod(0o755)
    write("openvpn", "#!/bin/sh\nexit 0\n", True)
    write("logger", '#!/bin/sh\nprintf "%s\\n" "$*" >> /test/log\n', True)
    write("uci", '#!/bin/sh\ncat /test/uci-export\n', True)
    write("uci-export", "package network\n")
    write("hotplug-call", '#!/bin/sh\nexit "${HOTPLUG_RC:-0}"\n', True)
    # Python models only the external command/ubus boundary; shell API and JSON
    # serialization are the actual versions used by the consuming OpenWrt tree.
    write("boundary", r'''#!/usr/bin/python3
import json, os, sys, time
from pathlib import Path
root = Path('/test')
kind = Path(sys.argv[0]).name
argv = sys.argv[1:]
def read(name, default):
    p = root / name
    return json.loads(p.read_text()) if p.exists() else default
def save(name, value):
    (root / name).write_text(json.dumps(value))
def log(value):
    with (root / 'calls').open('a') as f: f.write(json.dumps(value) + '\n')
if kind == 'ubus':
    argv = [s for s in argv if s != '-S']
    if len(argv) >= 3 and argv[1].startswith('network.interface.'):
        if argv[2] == 'renew':
            log(argv); sys.exit(1 if os.getenv('RENEW_FAIL') else 0)
        if argv[2] == 'set_data':
            msg = json.loads(argv[3]); log({'set_data': msg, 'interface': argv[1]})
            save('status-' + argv[1].rsplit('.',1)[-1], msg)
            sys.exit(0)
    if argv[:3] == ['call', 'network.interface', 'dump']:
        if os.getenv('DUMP_DELAY'): (root / 'slow-dump-started').touch()
        time.sleep(float(os.getenv('DUMP_DELAY', '0')))
        own = read('published', {})
        print(json.dumps({'interface': [
            {'interface':'wan', 'l3_device':'eth0', 'up':True, 'metric':10,
             'route':[{'target':'0.0.0.0','mask':0}, {'target':'::','mask':0}]},
            {'interface':'wan2', 'l3_device':'eth1', 'up':True, 'metric':20,
             'route':[{'target':'0.0.0.0','mask':0}]},
            {'interface':'fixture', 'l3_device':'tun0', 'up':own.get('link-up',False),
             'metric':0, 'route':[{'target':'0.0.0.0','mask':0}, {'target':'::','mask':0}]}]}))
        sys.exit(0)
    assert argv[:3] == ['call', 'network.interface', 'notify_proto'], argv
    msg = json.loads(argv[3]); log(msg)
    if msg['action'] == 0:
        if os.getenv('NOTIFY_FAIL') or (root / 'teardown').exists(): sys.exit(1)
        save('published', msg)
    if msg['action'] == 6 and os.getenv('DEPENDENCY_FAIL'): sys.exit(1)
    sys.exit(0)
assert kind == 'ip', kind
log(argv)
if argv[:2] == ['link', 'set']: sys.exit(0)
family, _, action, target, *rest = argv
family = family[-1:]
match = action == 'show' and target == 'match'
if match: target = rest.pop(0)
target = target.split('/')[0]
routes = read('routes', [])
def value(key, default=''):
    return rest[rest.index(key)+1] if key in rest else default
if action == 'get':
    if os.getenv('GET_FAIL') == family: sys.exit(1)
    device = value('oif')
    own = read('published', {})
    if not device:
        device = 'tun0' if os.getenv('GET_SELF') or own.get('link-up') else 'eth0'
    path = read('paths', {}).get(family+':'+device, {})
    gateway = path.get('gateway', ('192.0.2.1' if family == '4' else '2001:db8::1') if device != 'tun0' else '10.8.0.1')
    source = path.get('source', '192.0.2.2' if family == '4' else '2001:db8::2')
    for r in routes:
        if r[0] == family and r[1] == target and r[3] == device: gateway = r[2]
    print(f'{target} via {gateway} dev {device} src {source}')
elif action == 'show':
    if os.getenv('SHOW_FAIL'): sys.exit(1)
    if match:
        for device in ('eth0','eth1'):
            path = read('paths', {}).get(family+':'+device, {})
            gateway = path.get('gateway', '192.0.2.1' if family == '4' else '2001:db8::1')
            print(f'default via {gateway} dev {device} metric 10')
    for row in routes:
        if row[0] == family and row[1] == target:
            line = f'{target} via {row[2]} dev {row[3]}'
            if row[4]: line += f' metric {row[4]}'
            print(line)
else:
    row = [family,target,value('via'),value('dev'),value('metric')]
    if action == 'add':
        if os.getenv('ADD_FAIL') == family or (os.getenv('ADD_FAIL_GATEWAY') and os.getenv('ADD_FAIL_GATEWAY') == row[2]) or any(r[:2] == row[:2] and r[4] == row[4] for r in routes): sys.exit(1)
        routes.append(row)
    elif action == 'del':
        if os.getenv('DELETE_FAIL') or row not in routes: sys.exit(1)
        routes.remove(row)
    else: raise AssertionError(argv)
    save('routes', routes)
''', True)
    applets = "sh ash awk flock grep cat cp rm mv mkdir chmod rmdir sleep env kill dirname basename sed cut tr mktemp date".split()
    for name in applets:
        (work / "bin" / name).symlink_to("/test/busybox")
    for name, target in {"ubus":"/test/boundary", "logger":"/test/logger", "python3":"/host-python3", "jshn":"/host-jshn"}.items():
        (work / "bin" / name).unlink(missing_ok=True)
        (work / "bin" / name).symlink_to(target)
    shutil.copyfile(busybox, work / "busybox")
    (work / "busybox").chmod(0o755)
    # Retain the host loader and tools read-only, overlay only test commands.
    base = ["bwrap", "--unshare-all", "--uid", "0", "--gid", "0", "--die-with-parent", "--new-session",
            "--dir", "/usr", "--dir", "/usr/lib", "--dir", "/usr/sbin",
            "--ro-bind", str(work / "bin"), "/usr/bin",
            "--ro-bind", "/usr/bin/python3", "/host-python3",
            "--symlink", "usr/lib", "/lib", "--symlink", "usr/lib64", "/lib64",
            "--symlink", "usr/bin", "/bin",
            "--symlink", "usr/sbin", "/sbin", "--bind", str(work), "/test",
            "--ro-bind", str(source), "/source",
            "--ro-bind", str(source / "usr/share/openvpn"), "/usr/share/openvpn",
            "--ro-bind", str(netifd / "netifd-proto.sh"), "/lib/netifd/netifd-proto.sh",
            "--ro-bind", str(netifd / "utils.sh"), "/lib/netifd/utils.sh",
            "--ro-bind", str(source / "lib/netifd/proto/openvpn.sh"), "/lib/netifd/proto/openvpn.sh",
            "--ro-bind", str(work / "openvpn-hotplug"), "/usr/libexec/openvpn-hotplug",
            "--ro-bind", str(openwrt / "package/base-files/files/lib/functions.sh"), "/lib/functions.sh",
            "--ro-bind", str(openwrt / "package/system/uci/files/lib/config/uci.sh"), "/lib/config/uci.sh",
            "--ro-bind", str(work / "uci"), "/usr/sbin/uci",
            "--ro-bind", str(jshn), "/usr/share/libubox/jshn.sh",
            "--ro-bind", str(openwrt / "staging_dir/host/bin/jshn"), "/host-jshn",
            "--ro-bind", str(openwrt / "staging_dir/host/lib"), "/host-lib",
            "--ro-bind", str(work / "openvpn"), "/usr/sbin/openvpn",
            "--ro-bind", str(work / "hotplug-call"), "/usr/sbin/hotplug-call",
            "--ro-bind", str(work / "boundary"), "/usr/sbin/ip",
            "--bind", str(work / "etc"), "/etc", "--dir", "/var",
            "--bind", str(work / "run"), "/var/run", "--bind", str(work / "lock"), "/var/lock",
            "--dev", "/dev", "--proc", "/proc", "--tmpfs", "/tmp", "--clearenv",
            "--setenv", "PATH", "/test/bin:/usr/sbin:/usr/bin",
            "--setenv", "LC_ALL", "C", "--setenv", "LD_LIBRARY_PATH", "/host-lib"]
    for library in list(Path("/usr/lib").glob("*-linux-gnu")) + list(Path("/usr/lib").glob("python3.*")) + [Path("/usr/lib64")]:
        if library.exists():
            base += ["--ro-bind", str(library), str(library)]

    def run(script, env=None, expected=0):
        cmd = base.copy()
        for key, value in (env or {}).items():
            cmd += ["--setenv", key, str(value)]
        cmd += ["--", "/test/busybox", "ash", "-c", script]
        result = subprocess.run(cmd, text=True, capture_output=True, timeout=20)
        detail = ""
        if result.returncode != expected:
            for name in ("log", "calls"):
                path = work / name
                if path.exists():
                    detail += f"\n{name}:\n" + path.read_text()[-6000:]
        check(result.returncode == expected,
              f"expected {expected}, got {result.returncode}: {result.stderr[-16000:]}\n{result.stdout}{detail}")
        return result.stdout

    def calls():
        path = work / "calls"
        return [json.loads(row) for row in path.read_text().splitlines()] if path.exists() else []

    def published():
        return json.loads((work / "published").read_text())

    def routes():
        path = work / "routes"
        return json.loads(path.read_text()) if path.exists() else []

    def event(name, expected=0, **env):
        context = dict(script_type=name, INTERFACE="fixture", dev="tun0", DEFAULTROUTE="1",
                       IPV6="1", trusted_ip="198.51.100.10", ifconfig_local="10.8.0.2",
                       ifconfig_remote="10.8.0.1", route_vpn_gateway="10.8.0.1", METRIC="2000")
        token = work / ("run/openvpn-" + env.get("INTERFACE", "fixture")) / "generation"
        if token.exists():
            context["OPENVPN_GENERATION"] = token.read_text().strip()
        context.update(env)
        return run("/test/busybox ash /usr/libexec/openvpn-hotplug", context, expected)

    common = """INCLUDE_ONLY=1
. /lib/functions.sh
. /usr/share/openvpn/openvpn.options
. /lib/netifd/netifd-proto.sh
. /source/lib/netifd/proto/openvpn.sh
"""
    registration = json.loads(run("cd /lib/netifd/proto; /test/busybox ash ./openvpn.sh openvpn dump"))
    check(sum(row[0].split(":")[0] == "route" for row in registration["config"]) == 1,
          "route must be registered once")
    for value in (["10.20.0.0 255.255.0.0", "10.30.0.0 255.255.0.0"], "10.20.0.0 255.255.0.0"):
        payload = json.dumps({"route": value})
        generated = run(common + f"json_load '{payload}'\nALLOW_DEPRECATED=0\nexec_params=\n"
                        "option_builder build OPENVPN_PARAMS_STRING string\n"
                        "option_builder build OPENVPN_LIST list\nprintf '%s' \"$exec_params\"")
        check("J_A" not in generated and generated.count("route ") == (len(value) if isinstance(value, list) else 1),
              "route scalar/list must serialize without internal JSON identifiers")

    for config, expected in [({"auth_gen_token":"1"}, "auth-gen-token"),
                             ({"auth_gen_token":"1", "auth_gen_token_lifetime":3600}, "auth-gen-token 3600"),
                             ({"auth_gen_token":"3600 1800"}, "auth-gen-token 3600 1800")]:
        generated = run(common + f"json_load '{json.dumps(config)}'\nALLOW_DEPRECATED=0\nexec_params=\n"
                        "option_builder build OPENVPN_PARAMS_STRING string\nprintf '%s' \"$exec_params\"")
        check(generated == expected, "legacy token enable must not become a one-second lifetime")

    (work / "profiles/ccd").mkdir()
    write("profiles/ca.pem", "test certificate placeholder\n")
    config = {name: "/test/profiles/ccd" for name in ("capath", "client_config_dir", "chroot", "tls_export_cert", "tmp_dir")}
    config.update(dh="none", ca="ca.pem", replay_persist="/test/profiles/new-replay")
    generated = run(common + f"json_load '{json.dumps(config)}'\ncd_dir=/test/profiles\n"
                    "ALLOW_DEPRECATED=0\nexec_params=\noption_builder build OPENVPN_PARAMS_FILE file\n"
                    "printf '%s' \"$exec_params\"")
    for name in config:
        check(name.replace("_", "-") + ' "' in generated, f"must preserve {name}")
    generated = run(common + "json_load '{\"capath\":\"/inside-chroot/ca\",\"ca\":\"/missing.pem\"}'\n"
                    "exec_params=\noption_builder build OPENVPN_PARAMS_FILE file\nprintf '%s' \"$exec_params\"")
    check('capath "/inside-chroot/ca"' in generated and 'ca "/missing.pem"' in generated,
          "path serialization must not silently drop paths that OpenVPN will validate")
    before = len(calls())
    run(common + "json_load '{\"config\":\"/missing.conf\"}'\nproto_openvpn_setup fixture", expected=1)
    check(not any(isinstance(c, dict) and c.get("action") == 1 for c in calls()[before:]), "missing main profile must fail before process launch")

    write("profiles/main.conf", 'client\nremote 198.51.100.10\ndaemon profile\nscript-security 0\n'
          'ipchange "/test/check hook"\npull-filter accept ""\nredirect-private ipv6\nroute-ipv6 fc00::/7\n')
    run(common + "json_load '{\"config\":\"/test/profiles/main.conf\",\"dev\":\"tun0\",\"script_security\":0,\"tls_verify\":\"/test/custom-verify\"}'\nproto_openvpn_setup fixture")
    copied = (work / "run/openvpn.fixture.conf").read_text()
    check("\ndaemon profile\n" not in copied and "# daemon profile" in copied, "import must remain in foreground")
    command = [c["command"] for c in calls() if isinstance(c, dict) and c.get("action") == 1][-1]
    check("--up-restart" in command and "--ipchange" in command, "managed reconnect callbacks must always run")
    check("NETIFD_REDIRECT_GATEWAY" in command and "--redirect-gateway" in command,
          "managed clients must mark the redirect fallback for OpenVPN versions without native flags")
    check("user_ipchange" in (work / "run/openvpn.fixture.conf").read_text(), "imported ipchange hook must survive wrapping")
    generated = (work / "run/openvpn.fixture.conf").read_text()
    check('setenv user_tls_verify "/test/custom-verify"' in generated and '\ntls-verify "/usr/libexec/openvpn-hotplug"' in generated,
          "managed script-security 3 must allow UCI callbacks despite imported lower levels")

    run(common + "json_load '{\"config\":\"/test/profiles/main.conf\",\"dev\":\"tun0\",\"defaultroute\":false}'\nproto_openvpn_setup fixture")
    command = [c["command"] for c in calls() if isinstance(c, dict) and c.get("action") == 1][-1]
    check("--ipchange" in command and "--redirect-gateway" not in command and "NETIFD_REDIRECT_GATEWAY" not in command,
          "split-tunnel setup must retain reconnect callbacks without adding a redirect or fallback marker")
    generated = (work / "run/openvpn.fixture.conf").read_text()
    check(command[1:command.index('--config')] == ['--pull-filter', 'ignore', 'redirect-gateway',
                                                 '--pull-filter', 'ignore', 'redirect-private'] and
          '\nredirect-private ipv6\n' not in generated and '\n# redirect-private ipv6\n' in generated and
          '\npull-filter accept ""\n' in generated and '\nroute-ipv6 fc00::/7\n' in generated,
          "managed redirect filters must precede imported accept rules and preserve explicit business routes")

    # Without an active redirect, same-prefix routes are explicit user routes.
    event('up', DEFAULTROUTE='0', route_ipv6_network_1='fc00::/7',
          route_ipv6_gateway_1='fe80::1', route_ipv6_network_2='fd42::/48',
          route_ipv6_gateway_2='fe80::1')
    check({r['target'] for r in published().get('routes6', [])} == {'fc00::', 'fd42::'},
          "explicit ULA routes must survive when redirect handling is inactive")

    redirect_routes = dict(
        route_network_1='0.0.0.0', route_netmask_1='128.0.0.0', route_gateway_1='10.8.0.1',
        route_network_2='10.20.0.0', route_netmask_2='255.255.0.0', route_gateway_2='10.8.0.1',
        route_ipv6_network_1='::/3', route_ipv6_network_2='2000::/4',
        route_ipv6_network_3='3000::/4', route_ipv6_network_4='fc00::/7',
        route_ipv6_network_5='fd42::/48', route_ipv6_gateway_5='fe80::1')
    event('up', DEFAULTROUTE='1', NETIFD_REDIRECT_GATEWAY='1', **redirect_routes)
    check({r['target'] for r in published().get('routes6', [])} == {'fd42::'} and
          not any(r['target'] == '0.0.0.0' and str(r['netmask']) == '1' for r in published().get('routes', [])),
          "managed redirect fallback must filter native default-route fragments")
    event('up', DEFAULTROUTE='1', route_redirect_gateway_ipv4='1', route_redirect_gateway_ipv6='1', **redirect_routes)
    check({r['target'] for r in published().get('routes6', [])} == {'fd42::'} and
          not any(r['target'] == '0.0.0.0' and str(r['netmask']) == '1' for r in published().get('routes', [])),
          "native redirect flags must filter default-route fragments when exported")
    event('up', DEFAULTROUTE='1', NETIFD_REDIRECT_GATEWAY='1',
          route_redirect_gateway_ipv4='1', route_redirect_gateway_ipv6='0', **redirect_routes)
    check({r['target'] for r in published().get('routes6', [])} == {'::', '2000::', '3000::', 'fc00::', 'fd42::'} and
          not any(r['target'] == '0.0.0.0' and str(r['netmask']) == '1' for r in published().get('routes', [])),
          "each native family flag must override the managed fallback, including an explicit zero")

    event("up", foreign_option_1="dhcp-option DNS 192.0.2.53", foreign_option_2="dhcp-option DNS6 2001:db8::53")
    check(published()["ipaddr"][0]["ptp"] == "10.8.0.1", "P2P peer must reach netifd")
    check(published()["dns"] == ["192.0.2.53", "2001:db8::53"], "DNS6 must be published alongside DNS")
    check(len(routes()) == 1, "endpoint protection must be created")
    check(any(isinstance(c, dict) and c.get("action") == 6 and c.get("host") == "" and c.get("ifname") == "wan" for c in calls()),
          "must register WAN liveness without netifd-created host routes")
    event("up")
    check(len(routes()) == 1, "repeated up must preserve route ownership")
    with ThreadPoolExecutor(max_workers=2) as workers:
        list(workers.map(lambda _: event("up"), range(2)))
    check(len(routes()) == 1, "concurrent callbacks must serialize ownership changes")
    event("ipchange", trusted_ip="198.51.100.20")
    check([r[1] for r in routes()] == ["198.51.100.20"], "float must replace old endpoint protection")
    check(any(isinstance(c, list) and c[:4] == ["-4", "route", "get", "198.51.100.20"] and c[-2:] == ["oif", "eth0"] for c in calls()),
          "float must look up the external path despite an active tunnel default")
    event("down")
    check(not published()["link-up"] and not routes(), "soft disconnect must clear network state and owned routes")
    before = len(calls())
    run(". /source/etc/hotplug.d/iface/90-openvpn", {"ACTION":"ifupdate", "IFUPDATE_ROUTES":"1", "INTERFACE":"wan"})
    check(not any(isinstance(c, list) and c[:3] == ["call", "network.interface.fixture", "renew"] for c in calls()[before:]), "WAN events while already reconnecting must not restart the process")
    before = len(calls())
    run(". /source/etc/hotplug.d/iface/90-openvpn", {"ACTION":"ifupdate", "IFUPDATE_DATA":"1", "INTERFACE":"wan"})
    check(len(calls()) == before, "unrelated WAN data updates must not reconnect")
    event("up", trusted_ip="198.51.100.30", ifconfig_remote="", ifconfig_netmask="255.255.255.0")
    check(published()["ipaddr"][0].get("ptp") is None and published()["ipaddr"][0]["mask"] == "255.255.255.0", "subnet topology must retain its mask without peer")
    event("down")

    event("up", expected=1, NOTIFY_FAIL="1")
    check(not routes(), "failed notification must roll back newly created routes")
    event("up", expected=1, trusted_ip6="2001:db8::10", ADD_FAIL="6")
    check(not routes(), "IPv6 failure must roll back IPv4 protection")
    # A previous successful WAN registration is cached until the next setup.
    # Reinitialize to exercise that failure rather than reusing the cache.
    run("/test/busybox ash /usr/libexec/openvpn-hotplug prepare fixture")
    event("up", expected=1, DEPENDENCY_FAIL="1")
    check(not routes(), "failed initial WAN dependency must abort up")
    event("up", trusted_ip="", trusted_ip6="2001:db8::10", IPV6="0")
    check([r[0] for r in routes()] == ["6"], "IPv6 outer transport still needs protection with inner IPv6 disabled")
    event("down")
    event("up", GET_SELF="1", trusted_ip="198.51.100.40")
    check(routes()[0][3] == "eth0", "uncached paths must exclude the tunnel's own default route")
    event("down")

    # Reuse administrator-owned routes without deleting them on failure/cleanup.
    foreign = ["4", "198.51.100.10", "192.0.2.1", "eth0", "2000"]
    write("routes", json.dumps([foreign]))
    event("up", expected=1, NOTIFY_FAIL="1")
    check(routes() == [foreign], "rollback must preserve existing foreign routes")
    event("up")
    event("down")
    check(routes() == [foreign], "down must preserve existing foreign routes")
    write("routes", "[]")

    # Shared endpoint/metric must remain protected until the last instance stops.
    event("up")
    event("up", INTERFACE="fixture2", NOTIFY_FAIL="1", expected=1)
    check(len(routes()) == 1 and not (work / "run/openvpn-fixture2/routes").read_text(),
          "failed publication must release newly shared ownership while protecting the other instance")
    event("up", INTERFACE="fixture2")
    check(len(routes()) == 1, "identical managed routes must be shared")
    event("down")
    check(len(routes()) == 1, "first owner must not remove a route used by another instance")
    event("down", INTERFACE="fixture2")
    check(not routes(), "last owner must remove the shared route")
    event("up")
    event("down", expected=1, NOTIFY_FAIL="1")
    check(not routes(), "down notification failure must still clean endpoint protection")

    event("up")
    run("/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture", {"DELETE_FAIL":"1"}, expected=1)
    check(bool((work / "run/openvpn-fixture/routes").read_text()), "failed cleanup must retain ownership for retry")
    event("up", expected=1)
    run("/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture")
    check(not routes(), "cleanup must work independently of netifd status data")
    check((work / "run/openvpn-fixture/phase").read_text().strip() == "stopping",
          "cleanup must publish the stopping phase")
    event("down")
    check(not routes(), "late down after teardown must be harmless")
    check((work / "run/openvpn-fixture/phase").read_text().strip() == "stopping",
          "late down must not replace the stopping phase")
    event("tls-verify", expected=1)
    run("/test/busybox ash /usr/libexec/openvpn-hotplug prepare fixture")
    event("up", TUNLINK="wan2")
    check(routes()[0][3] == "eth1", "explicit tunlink must select its external device")
    event("ipchange", expected=1, trusted_ip="198.51.100.90", GET_FAIL="4")
    check(any(isinstance(c, dict) and c.get("action") == 7 for c in calls()), "ipchange failure must request teardown because OpenVPN ignores its return value")
    run("/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture")
    write("teardown", "")
    run(common + "proto_openvpn_teardown fixture")
    check(not routes(), "teardown must finish without rejected link updates")

    # One compilation pass follows process-wide cd across nested includes.
    (work / "teardown").unlink(missing_ok=True)
    (work / "profiles/sub dir").mkdir()
    (work / "profiles/certs").mkdir()
    write("profiles/sub dir/child.conf", 'cd "../certs"\nconfig leaf.conf\n')
    write("profiles/certs/leaf.conf", 'route 10.70.0.0 255.255.0.0\nup "/test/imported hook"\n')
    write("profiles/native.conf", 'client\nremote 198.51.100.10\ncd "sub dir"\nconfig child.conf\nca cert.pem\n'
          'user nobody\ngroup nogroup\nchroot /jail\n<ca>\nconfig missing-inline.conf\nuser inline-data\n</ca>\n')
    run(common + "json_load '{\"config\":\"/test/profiles/native.conf\",\"dev\":\"tun0\",\"up\":\"/test/uci-hook\",\"config_version\":\"v2\"}'\nproto_openvpn_setup fixture")
    compiled = (work / "run/openvpn.fixture.conf").read_text()
    check('cd "/test/profiles/sub dir/../certs"' in compiled and 'route 10.70.0.0 255.255.0.0' in compiled,
          "nested includes must inherit and update the native process cwd")
    check('setenv user_up "/test/uci-hook"' in compiled and 'setenv user_up "\'/test/imported hook\'"' not in compiled,
          "explicit UCI callback must override an imported callback")
    check('# netifd overrides user nobody' in compiled and '# netifd overrides chroot /jail' in compiled,
          "incompatible privilege/chroot options must be filtered before launch")
    check('config missing-inline.conf\nuser inline-data' in compiled, "inline certificate data must remain opaque")
    check('config-version' not in compiled and any(row[0].split(':')[0] == 'config_version' for row in registration['config']),
          "config_version must trigger netifd config comparison without becoming a native option")
    check(not list((work / "run").glob('openvpn.fixture.build.*')), "successful setup must remove its private staging directory")
    write('profiles/crlf.conf', 'client\r\nremote 198.51.100.10\r\n<ca>\r\nopaque-data\r\n</ca>  # native closing tag\r\nuser nobody\r\n')
    payload = {'config':'/test/profiles/crlf.conf','dev':'tun0','user':'nobody','group':'nogroup','chroot':'/jail',
               'username':'test-user','password':'test-password','cert_password':'test-passphrase',
               'mtu':1400,'metric':2000,'tunlink':'wan'}
    run(common + f"json_load '{json.dumps(payload)}'\nproto_openvpn_setup fixture")
    generated = (work / 'run/openvpn.fixture.conf').read_text()
    check('opaque-data' in generated and '# netifd overrides user nobody' in generated and '# netifd overrides group nogroup' in generated,
          "CRLF inline boundaries and UCI privilege/chroot inputs must use the same compiler")
    command = [c['command'] for c in calls() if isinstance(c,dict) and c.get('action') == 1][-1]
    check(len(command) < 63 and command[command.index('NETIFD_MTU') + 1] == '1400',
          "all optional overrides must fit netifd's argv limit and preserve MTU")
    # Restore the role/ignored-options snapshot used by subsequent lifecycle tests.
    run(common + "json_load '{\"config\":\"/test/profiles/native.conf\",\"dev\":\"tun0\",\"up\":\"/test/uci-hook\"}'\nproto_openvpn_setup fixture")
    old_conf = compiled
    for name, content, code in [('cycle.conf', 'config ./cycle.conf\n', 'CONFIG_CYCLE'),
                                ('missing-include.conf', 'config absent.conf\n', 'CONFIG_READ_FAILED'),
                                ('syntax.conf', 'up "unterminated\n', 'INVALID_CONFIG'),
                                ('bad-cd.conf', 'cd absent-directory\n', 'INVALID_OPTION')]:
        write('profiles/' + name, content)
        before = len(calls())
        run(common + f"json_load '{json.dumps({'config':'/test/profiles/'+name})}'\nproto_openvpn_setup fixture", expected=1)
        check(not any(isinstance(c, dict) and c.get('action') == 1 for c in calls()[before:]), "invalid import must not start a child")
        check(any(isinstance(c, dict) and c.get('action') == 3 and c['error'][0] == code for c in calls()[before:]),
              "import failure must report a structured reason")
        check((work / 'run/openvpn.fixture.conf').read_text() == old_conf and not list((work / 'run').glob('openvpn.fixture.build.*')),
              "failed preparation must preserve the prior snapshot and remove partial files")
    run(common + "json_load '{}'\nCONF_DIR=/source\nCONF_PREFIX=/source/openvpn.\nproto_openvpn_setup fixture", expected=1)
    check(any(isinstance(c, dict) and c.get('action') == 3 and c['error'][0] == 'CONFIG_WRITE_FAILED' for c in calls()),
          "unwritable runtime storage must report a structured error")
    run(common + "json_load '{\"mtu\":12}'\nproto_openvpn_setup fixture", expected=1)
    check((work / 'run/openvpn.fixture.conf').read_text() == old_conf, "invalid netifd MTU must fail before publishing a snapshot")

    # Highest MTU priority is explicit netifd configuration, including on repeats.
    event('up', tun_mtu='1500', NETIFD_MTU='1400')
    check(['link','set','dev','tun0','mtu','1400'] in calls(), "interface MTU must override the OpenVPN MTU")
    write('uci-export', "package network\nconfig device 'vpn_dev'\n option name 'tun0'\n option mtu '1320'\n")
    event('up', tun_mtu='1500', NETIFD_MTU='1400')
    event('up', tun_mtu='1500', NETIFD_MTU='1400')
    status = json.loads((work / 'status-fixture').read_text())['openvpn']
    check(status['mtu'] == '1320' and status['mtu_source'] == 'netifd', "device MTU must retain highest priority on repeated up")
    check(status['role'] == 'client' and status['phase'] == 'tunnel-up' and status['ignored_options'] == 'user,group,chroot',
          "status must expose the role, callback phase and overridden options")
    write('uci-export', 'package network\n')
    event('up', tun_mtu='1480')
    check(json.loads((work / 'status-fixture').read_text())['openvpn']['mtu'] == '1480', "OpenVPN MTU must apply when netifd has no explicit MTU")
    before = len(calls())
    event('up', OPENVPN_GENERATION='stale', expected=1)
    event('down', OPENVPN_GENERATION='stale')
    check(len(calls()) == before and bool(routes()), "stale callbacks must not publish or remove current state")

    # Unchanged paths and unrelated address updates must not signal the child.
    before = len(calls())
    run('. /source/etc/hotplug.d/iface/90-openvpn', {'ACTION':'ifupdate','IFUPDATE_ROUTES':'1','INTERFACE':'wan'})
    check(not any(isinstance(c,list) and c[:3] == ['call','network.interface.fixture','renew'] for c in calls()[before:]),
          "unchanged WAN paths must not reconnect")
    write('paths', json.dumps({'4:eth0':{'gateway':'192.0.2.254','source':'192.0.2.2'}}))
    before = len(calls())
    run('. /source/etc/hotplug.d/iface/90-openvpn', {'ACTION':'ifupdate','IFUPDATE_ROUTES':'1','INTERFACE':'wan'})
    check(routes()[0][2] == '192.0.2.254', "gateway-only changes must refresh endpoint protection")
    check(not any(isinstance(c,list) and c[:3] == ['call','network.interface.fixture','renew'] for c in calls()[before:]),
          "gateway-only changes must retain the transport session")
    write('paths', json.dumps({'4:eth0':{'gateway':'192.0.2.254','source':'192.0.2.3'}}))
    before = len(calls())
    for _ in range(2):
        run('. /source/etc/hotplug.d/iface/90-openvpn', {'ACTION':'ifupdate','IFUPDATE_ADDRESSES':'1','INTERFACE':'wan'})
    check(sum(isinstance(c,list) and c[:3] == ['call','network.interface.fixture','renew'] for c in calls()[before:]) == 1,
          "source changes must coalesce into one renew until the next up")
    event('down')
    event('up')
    check(not (work / 'run/openvpn-fixture/renew_pending').exists(), "successful reconnect must clear the pending request")

    # Shared routes cannot be replaced in place; retain ownership and request renew.
    event('up', INTERFACE='fixture2')
    old_routes = routes()
    old_path = (work / 'run/openvpn-fixture/path4').read_text()
    write('paths', json.dumps({'4:eth0':{'gateway':'192.0.2.253','source':'192.0.2.3'}}))
    before = len(calls())
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture')
    check(routes() == old_routes and (work / 'run/openvpn-fixture/path4').read_text() == old_path,
          "shared route refresh failure must restore ownership and path metadata")
    check(any(isinstance(c,list) and c[:3] == ['call','network.interface.fixture','renew'] for c in calls()[before:]),
          "shared route gateway conflicts must fall back to renew")
    event('down', INTERFACE='fixture2')
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture')
    check(routes()[0][2] == '192.0.2.253', "restored old path must allow a later gateway refresh")
    event('down')
    event('up')

    # A dual-stack refresh can fail after one family succeeded. Restore both.
    event('up', trusted_ip6='2001:db8::10')
    old_routes = routes()
    old_path = (work / 'run/openvpn-fixture/path4').read_text()
    write('paths', json.dumps({'4:eth0':{'gateway':'192.0.2.252','source':'192.0.2.3'},
                               '6:eth0':{'gateway':'2001:db8::254','source':'2001:db8::2'}}))
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture', {'ADD_FAIL_GATEWAY':'2001:db8::254'})
    check(sorted(routes()) == sorted(old_routes) and (work / 'run/openvpn-fixture/path4').read_text() == old_path,
          "partial refresh must restore both families and the original path")
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture')
    check({r[2] for r in routes()} == {'192.0.2.252','2001:db8::254'}, "a later dual-stack refresh must retry the failed path")
    event('ipchange')
    check(not (work / 'run/openvpn-fixture/path6').exists() and all(r[0] == '4' for r in routes()),
          "endpoint family changes must discard the old WAN path and protection")
    event('down')

    # Non-default VPNs still monitor their WAN, without creating host routes.
    event('up', DEFAULTROUTE='0')
    check(not routes() and (work / 'run/openvpn-fixture/path4').exists(), "split tunnels must track their outer path without taking route ownership")
    write('paths', json.dumps({'4:eth0':{'gateway':'192.0.2.252','source':'192.0.2.4'}}))
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture', {'RENEW_FAIL':'1'}, expected=1)
    check(not (work / 'run/openvpn-fixture/renew_pending').exists(), "failed renew requests must remain retryable")
    run('/test/busybox ash /usr/libexec/openvpn-hotplug wan-update fixture')
    check((work / 'run/openvpn-fixture/renew_pending').exists(), "a later WAN event must retry a failed renew")
    event('down')
    event('up')

    event('down')
    event('up', METRIC='0', trusted_ip='', trusted_ip6='2001:db8::10')
    event('up', METRIC='0', trusted_ip='', trusted_ip6='2001:db8::10')
    check(routes()[0][4] == '1024', "IPv6 zero metric must use Linux's effective metric for repeated up and cleanup")
    event('down')
    check(not routes(), "IPv6 default-metric ownership must be removable")
    event('up')

    # Queries for one instance must not hold the shared route lock.
    write('slow-dump-started', '')
    (work / 'slow-dump-started').unlink()
    with ThreadPoolExecutor(max_workers=2) as workers:
        slow = workers.submit(event, 'up', DUMP_DELAY='1')
        import time
        deadline = time.monotonic() + 3
        while not (work / 'slow-dump-started').exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        event('up', INTERFACE='fixture2')
        check(not slow.done(), "a slow ubus query must not block another instance's route updates")
        slow.result()
    event('down', INTERFACE='fixture2')
    event('down')

    # A handler may daemonize. Its child must not retain the shared instance lock.
    write('etc/hotplug.d/openvpn/99-lock-check',
          '( sleep 2 ) </dev/null >/dev/null 2>&1 &\n')
    event('tls-verify')
    with ThreadPoolExecutor(max_workers=1) as workers:
        cleanup = workers.submit(run, '/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture')
        check(cleanup.result(timeout=1) == "", "background callback children must not retain the instance lock")
    (work / 'etc/hotplug.d/openvpn/99-lock-check').unlink()
    run('/test/busybox ash /usr/libexec/openvpn-hotplug prepare fixture')

    # Authentication that waited behind prepare must recheck its generation.
    token = work / 'run/openvpn-fixture/generation'
    old_token = token.read_text()
    write('etc/hotplug.d/openvpn/99-lock-check', 'echo executed >> /test/security-executed\n')
    with (work / 'lock/openvpn-fixture.lock').open('w') as lock, ThreadPoolExecutor(max_workers=1) as workers:
        fcntl.flock(lock, fcntl.LOCK_EX)
        old_log = (work / 'log').read_text()
        callback = workers.submit(event, 'tls-verify', expected=1)
        deadline = time.monotonic() + 3
        while 'event=tls-verify phase=start' not in (work / 'log').read_text()[len(old_log):] and time.monotonic() < deadline:
            time.sleep(0.01)
        check('event=tls-verify phase=start' in (work / 'log').read_text()[len(old_log):],
              "security callback must pass the initial generation check before waiting for the lock")
        token.write_text('replacement-generation\n')
        fcntl.flock(lock, fcntl.LOCK_UN)
        callback.result()
    check(not (work / 'security-executed').exists(), "callbacks from a replaced generation must not execute user handlers")
    token.write_text(old_token)

    # cleanup must wait for an already running security handler, then stop later ones.
    write('etc/hotplug.d/openvpn/99-lock-check', ': > /test/security-started\n'
          'while [ ! -e /test/release-security ]; do sleep 1; done\n')
    with ThreadPoolExecutor(max_workers=2) as workers:
        callback = workers.submit(event, 'tls-verify')
        deadline = time.monotonic() + 3
        while not (work / 'security-started').exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        check((work / 'security-started').exists(), "security handler must begin while holding the shared instance lock")
        old_log = (work / 'log').read_text()
        cleanup = workers.submit(run, '/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture')
        deadline = time.monotonic() + 3
        while 'event=cleanup phase=start' not in (work / 'log').read_text()[len(old_log):] and time.monotonic() < deadline:
            time.sleep(0.01)
        check(not cleanup.done() and not (work / 'run/openvpn-fixture/stopping').exists(),
              "cleanup must wait until the running security handler releases the instance lock")
        write('release-security', '')
        callback.result()
        cleanup.result()
    (work / 'security-started').unlink()
    event('tls-verify', expected=1)
    check(not (work / 'security-started').exists(), "stopping instances must reject security handlers")
    (work / 'etc/hotplug.d/openvpn/99-lock-check').unlink()
    run('/test/busybox ash /usr/libexec/openvpn-hotplug cleanup fixture')
    write('paths', '{}')

    if args.native_dir:
        write("etc/passwd", "root:x:0:0:root:/root:/bin/sh\n")
        write("etc/group", "root:x:0:\n")
        (work / "bin/ubus").unlink()
        (work / "bin/ubus").symlink_to("/native/ubus/ubus")
        base += ["--ro-bind", str(args.native_dir.resolve()), "/native",
                 "--ro-bind", str(Path(__file__).resolve().parent), "/tests",
                 "--setenv", "LD_LIBRARY_PATH", "/host-lib:/native/ubus:/native/uci",
                 "--ro-bind", str(args.native_dir.resolve() / "uci/uci"), "/usr/sbin/uci"]
        write("openvpn", '''#!/bin/sh
echo $$ > /test/daemon-pid
trap 'echo USR1 >> /test/signals' USR1
trap 'exit 0' TERM
while :; do sleep 1; done
''', True)
        write("etc/config/network", '''config interface 'wan'
 option proto 'static'
 option ifname 'eth0'
 option ipaddr '192.0.2.2'
 option netmask '255.255.255.0'
 option gateway '192.0.2.1'
 option metric '10'
config interface 'fixture'
 option proto 'openvpn'
 option dev 'tun0'
 list remote '198.51.100.10'
 option client '1'
 option metric '2000'
 option mtu '1400'
 option config_version 'v1'
config device 'vpn_device'
 option name 'tun0'
 option mtu '1350'
''')
        print(run("/host-python3 /tests/native.py").strip())

print(f"PASS: {checks} assertions (BusyBox ash/awk/flock, native jshn and netifd shell API)")
