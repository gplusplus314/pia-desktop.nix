# NixOS VM test: bring up a machine with the pia-desktop module enabled and
# confirm the privileged daemon starts, creates its control socket, and that
# piactl can talk to it. This does NOT log in or establish a real VPN tunnel
# (that needs credentials and real networking); it verifies the packaging,
# service wiring and daemon startup path.
{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "pia-desktop-daemon";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.pia-desktop ];
    services.pia-desktop.enable = true;
    services.pia-desktop.users = [ "alice" ];
    users.users.alice = { isNormalUser = true; };
    # WireGuard/tun aren't exercised here; keep the VM small.
    virtualisation.memorySize = 2048;
  };

  testScript = ''
    machine.wait_for_unit("piavpn.service")
    # Daemon must create its group-owned control socket under the hard-coded path.
    machine.wait_for_file("/opt/piavpn/var/daemon.sock")
    # Resource dir must resolve to the store via the tmpfiles symlink.
    machine.succeed("test -e /opt/piavpn/share/modern_servers.json")
    # The CLI should connect to the daemon and report a state (Disconnected).
    state = machine.succeed("piactl get connectionstate")
    print("connectionstate:", state)
    assert "Disconnected" in state, f"unexpected state: {state!r}"
    # alice is in the piavpn control group.
    machine.succeed("id -nG alice | grep -qw piavpn")
  '';
}
