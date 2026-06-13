# NixOS module for the PIA Desktop client.
#
# The upstream Linux installer drops files in /opt/piavpn, creates a `piavpn`
# group, installs a systemd unit running the daemon as root, and tweaks the
# system (routing tables, NetworkManager, kernel modules). None of that applies
# cleanly on NixOS, so this module reproduces the required runtime environment
# declaratively while the actual binaries live in the Nix store.
#
# Key constraint: the daemon has /opt/piavpn hard-coded for its installation,
# resource, state and settings directories (common/src/builtin/path.cpp). The
# executable/library dirs are resolved relative to the daemon binary, so those
# come from the store automatically; we only have to provide /opt/piavpn/share
# (read-only resources, symlinked to the store) and writable var/ and etc/.
#
# `self` is the flake's own outputs, used only to pick the default package.
self:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.pia-desktop;

  desktopItem = pkgs.makeDesktopItem {
    name = "piavpn";
    desktopName = "Private Internet Access";
    exec = "${cfg.package}/bin/pia-client %u";
    icon = "piavpn";
    startupWMClass = "pia-client";
    categories = [ "Network" ];
    mimeTypes = [ "x-scheme-handler/piavpn" ];
  };
in
{
  options.services.pia-desktop = {
    enable = lib.mkEnableOption "the Private Internet Access VPN daemon and client";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.system}.pia-desktop;
      defaultText = lib.literalExpression "pia-desktop.packages.\${system}.pia-desktop";
      description = "The pia-desktop package to use.";
    };

    users = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "alice" ];
      description = ''
        Users to add to the `piavpn` group. Members of this group can control
        the VPN through the client/CLI (the daemon's control socket is owned by
        this group).
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package desktopItem ];

    # The daemon setgid()s to this group and refuses to start if it is missing;
    # the resolver helper uses the second group.
    users.groups.piavpn = { };
    users.groups.piahnsd = { };

    users.users = lib.genAttrs cfg.users (_: { extraGroups = [ "piavpn" ]; });

    # WireGuard (kernel backend, preferred) and tun (OpenVPN / userspace WG).
    boot.kernelModules = [ "tun" "wireguard" ];

    # Resource files the daemon/client read from the hard-coded /opt/piavpn/share.
    # var/ and etc/ are writable runtime state, created by systemd-tmpfiles.
    # /etc/iproute2 must be a writable directory: the daemon creates and updates
    # /etc/iproute2/rt_tables itself (picking free table indices dynamically),
    # so we only ensure the directory exists rather than seeding entries.
    systemd.tmpfiles.rules = [
      "d  /opt/piavpn       0755 root root   - -"
      "L+ /opt/piavpn/share -    -    -      - ${cfg.package}/share"
      "d  /opt/piavpn/var   0750 root piavpn - -"
      "d  /opt/piavpn/etc   0750 root piavpn - -"
      "d  /etc/iproute2     0755 root root   - -"
    ];

    # Keep NetworkManager from managing the WireGuard interfaces PIA creates.
    networking.networkmanager.unmanaged =
      lib.mkIf config.networking.networkmanager.enable [ "interface-name:wgpia*" ];

    systemd.services.piavpn = {
      description = "Private Internet Access daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # The daemon execs many system tools (ip, iptables, sysctl, resolvectl,
      # modprobe, mount, ...) by bare name; give it a complete PATH.
      path = [
        pkgs.iproute2 pkgs.iptables pkgs.procps pkgs.psmisc pkgs.kmod
        pkgs.libcap pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused
        pkgs.findutils pkgs.e2fsprogs pkgs.util-linux pkgs.systemd
        pkgs.nettools pkgs.iputils pkgs.dnsutils
      ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/pia-daemon";
        Restart = "always";
        RestartSec = 1;
        # The daemon's shell-command runners exec a hard-coded /bin/bash, which
        # NixOS does not provide (only /bin/sh). Give it /bin/bash inside the
        # service's private mount namespace only: a tmpfs over /bin makes the
        # bind-mount target writable in-namespace, so nothing touches the host
        # /bin. The daemon and its children (openvpn, the up/down script) see
        # /bin/bash; the rest of the system stays pure.
        TemporaryFileSystem = "/bin";
        BindReadOnlyPaths = [ "${pkgs.bash}/bin/bash:/bin/bash" ];
      };
    };
  };
}
