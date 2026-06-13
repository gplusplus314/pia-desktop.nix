# PIA Desktop for NixOS

A thin Nix flake that packages the [Private Internet Access desktop client](https://github.com/pia-foss/desktop)
for NixOS. It builds the real Qt6 client, daemon, `piactl` CLI and support tool
from upstream source, and ships a NixOS module that runs the privileged daemon.

This repo carries no upstream code. Instead, `nix/package.nix` fetches
`pia-foss/desktop` at a pinned release tag via `fetchFromGitHub` and applies a
few small build-script patches (`nix/patches/`). Tracking a new release is a
version + hash bump with no merge; run `scripts/update`.

## Install on NixOS

Add the flake as an input and enable the module:

```nix
{
  inputs.pia-desktop.url = "github:gplusplus314/pia-desktop.nix";

  outputs = { self, nixpkgs, pia-desktop, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pia-desktop.nixosModules.pia-desktop
        {
          services.pia-desktop.enable = true;
          # Users allowed to control the VPN (added to the `piavpn` group):
          services.pia-desktop.users = [ "alice" ];
        }
      ];
    };
  };
}
```

After a rebuild, the `piavpn.service` daemon runs as root. Launch the GUI with
`pia-client`, or use the CLI: `piactl login`, `piactl connect`,
`piactl get connectionstate`.

## Limitations

This is `x86_64-linux` on NixOS only. Not that it's not possible to add others,
but this is all I personally have right now.
