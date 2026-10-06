{
  description = "Nix packaging and development environment for herdr-nvim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      homeModules.default = import ./nix/home-manager.nix;
      homeManagerModules.default = self.homeModules.default;

      overlays.default = final: _: {
        herdr-nvim = final.callPackage ./nix/package.nix { };
      };

      packages = eachSystem (
        system:
        let
          package = (pkgsFor system).callPackage ./nix/package.nix { };
        in
        {
          default = package;
          herdr-nvim = package;
        }
      );

      apps = eachSystem (system: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe self.packages.${system}.default;
          meta.description = "Herdr Neovim sidebar, picker and daemon diagnostics";
        };
      });

      checks = eachSystem (
        system:
        import ./nix/checks.nix {
          pkgs = pkgsFor system;
          package = self.packages.${system}.default;
          inherit home-manager;
          module = self.homeModules.default;
        }
      );

      formatter = eachSystem (system: (pkgsFor system).nixfmt);

      devShells = eachSystem (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default.unwrapped ];
            packages = with pkgs; [
              cargo
              rustc
              rustfmt
              clippy
              rust-analyzer
              neovim
              git
              just
              nixfmt
              nixd
            ];
            RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
          };
        }
      );
    };
}
