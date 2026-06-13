{
  description = "Private Internet Access VPN desktop client (Qt6), packaged as a Nix flake for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      packages.${system} = {
        pia-desktop = pkgs.callPackage ./nix/package.nix { };
        qtroot = pkgs.callPackage ./nix/qtroot.nix { };
        default = self.packages.${system}.pia-desktop;
      };

      # NixOS module: installs the package, runs the privileged daemon, and
      # wires up the groups/state/kernel bits the VPN needs.
      nixosModules.pia-desktop = import ./modules/pia-desktop.nix self;
      nixosModules.default = self.nixosModules.pia-desktop;

      checks.${system}.nixos-daemon =
        import ./tests/nixos-test.nix { inherit pkgs self; };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          ruby rake llvmPackages_18.clang llvmPackages_18.llvm
          git git-lfs which patchelf
        ];
      };

      formatter.${system} = pkgs.nixpkgs-fmt;
    };
}
