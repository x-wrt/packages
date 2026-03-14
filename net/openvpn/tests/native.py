"""Optional real ubus/netifd C state-machine test, executed inside the sandbox."""

import json
import os
from pathlib import Path
import subprocess
import time


root = Path("/test")
Path("/var/run/ubus").mkdir(exist_ok=True)
log = (root / "native.log").open("w")
daemons = []


def call(interface, method):
    result = subprocess.check_output(["ubus", "call", f"network.interface.{interface}", method], text=True)
    return json.loads(result or "{}")


def until(predicate, label):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        try:
            value = predicate()
            if value:
                return value
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
        time.sleep(0.05)
    raise AssertionError(label)


def event(name):
    environment = dict(os.environ, script_type=name, INTERFACE="fixture", dev="tun0",
                       DEFAULTROUTE="1", IPV6="0", trusted_ip="198.51.100.10",
                       ifconfig_local="10.8.0.2", ifconfig_remote="10.8.0.1",
                       route_vpn_gateway="10.8.0.1", METRIC="2000",
                       tun_mtu="1500", NETIFD_MTU="1400",
                       foreign_option_1="dhcp-option DNS 192.0.2.53",
                       OPENVPN_GENERATION=(root / "run/openvpn-fixture/generation").read_text().strip())
    subprocess.run(["/bin/sh", "/usr/libexec/openvpn-hotplug"], env=environment, check=True)


try:
    socket = "/var/run/ubus/ubus.sock"
    daemons.append(subprocess.Popen(["/native/ubus/ubusd", "-s", socket], stdout=log, stderr=log))
    until(lambda: Path("/var/run/ubus/ubus.sock").exists(), "ubusd socket")
    daemons.append(subprocess.Popen(["/native/netifd/netifd", "-s", socket, "-p", "/lib/netifd",
                                     "-c", "/etc/config", "-h", "/sbin/hotplug-call",
                                     "-r", "/tmp/resolv.conf", "-l", "4"], stdout=log, stderr=log))
    until(lambda: (root / "daemon-pid").exists(), "netifd must launch its managed child")
    pid = int((root / "daemon-pid").read_text())
    until(lambda: call("wan", "status").get("up"), "WAN setup")
    event("up")
    status = call("fixture", "status")
    assert status["up"] and status["ipv4-address"][0]["ptpaddress"] == "10.8.0.1", status
    assert status["route"] and status["dns-server"] == ["192.0.2.53"], status
    assert status['data']['openvpn']['phase'] == 'tunnel-up', status
    assert status['data']['openvpn']['mtu'] == '1350' and status['data']['openvpn']['mtu_source'] == 'netifd', status
    assert status['data']['openvpn']['role'] == 'client', status
    event("down")
    status = call("fixture", "status")
    assert not status["up"] and status["pending"], status
    assert not status.get("route") and not status.get("dns-server"), status
    assert status['data']['openvpn']['phase'] == 'reconnecting', status
    os.kill(pid, 0)
    assert int((root / "daemon-pid").read_text()) == pid
    event("up")
    assert call("fixture", "status")["up"]
    call("fixture", "renew")
    until(lambda: (root / "signals").exists(), "renew must signal the same child")
    assert int((root / "daemon-pid").read_text()) == pid
    assert call('fixture', 'status')['data']['openvpn']['phase'] == 'renew-requested'
    event('up')
    signal_count = len((root / 'signals').read_text().splitlines())
    (root / 'paths').write_text(json.dumps({'4:eth0':{'gateway':'192.0.2.1','source':'192.0.2.3'}}))
    subprocess.run(['/bin/sh', '/usr/libexec/openvpn-hotplug', 'wan-update', 'fixture'], check=True)
    until(lambda: len((root / 'signals').read_text().splitlines()) > signal_count,
          'WAN path refresh must release the instance lock for netifd renew')
    assert int((root / 'daemon-pid').read_text()) == pid
    event('up')

    # The import path alone does not change when an included file is edited.
    # An explicit revision participates in the real netifd UCI comparison.
    old_generation = (root / 'run/openvpn-fixture/generation').read_text()
    network = Path('/etc/config/network')
    network.write_text(network.read_text().replace("option config_version 'v1'", "option config_version 'v2'"))
    subprocess.run(['ubus', 'call', 'network', 'reload', '{}'], check=True, stdout=subprocess.DEVNULL)
    until(lambda: int((root / 'daemon-pid').read_text()) != pid, 'config_version reload must replace the child')
    pid = int((root / 'daemon-pid').read_text())
    assert (root / 'run/openvpn-fixture/generation').read_text() != old_generation
    event('up')
    assert call('fixture', 'status')['data']['openvpn']['mtu'] == '1350'
    call("wan", "down")
    until(lambda: not call("fixture", "status")["up"], "WAN dependency must withdraw VPN state")
    until(lambda: not Path(f"/proc/{pid}").exists(), "WAN down must terminate the child")
    assert not json.loads((root / "routes").read_text()), "teardown must clean endpoint routes"
    call("wan", "up")
    until(lambda: int((root / "daemon-pid").read_text()) != pid, "WAN recovery must launch a new child")
    event("up")
    assert call("fixture", "status")["up"]
    call("fixture", "down")
    until(lambda: not call("fixture", "status")["up"], "explicit teardown")
    print("PASS: native ubus/netifd C lifecycle, IP/DNS withdrawal, MTU/status, renew, config_version reload and WAN recovery (dummy system backend)")
except Exception:
    log.flush()
    print((root / "native.log").read_text()[-12000:])
    raise
finally:
    for daemon in reversed(daemons):
        daemon.terminate()
        try:
            daemon.wait(timeout=3)
        except subprocess.TimeoutExpired:
            daemon.kill()
            daemon.wait()
    log.close()
