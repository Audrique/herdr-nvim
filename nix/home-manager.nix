{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.herdr-nvim;
  toml = pkgs.formats.toml { };
  pluginRoot = "${cfg.package}/share/herdr-nvim";
  marker = "${config.xdg.stateHome}/herdr-nvim/nix-plugin-root";
  herdr = if cfg.herdrPackage == null then "herdr" else lib.getExe cfg.herdrPackage;
in
{
  options.programs.herdr-nvim = {
    enable = lib.mkEnableOption "the Nix-managed Herdr Neovim sidebar and annotations";

    herdrPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        Herdr package used for registration and by the sidebar. Set this to
        your existing Herdr package (for example, from its flake overlay).
        Herdr is not currently packaged in the supported nixpkgs channel.
      '';
    };

    neovimPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.neovim;
      defaultText = lib.literalExpression "pkgs.neovim";
      description = "Neovim used by the sidebar; it still loads your normal editor configuration.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix {
        inherit (cfg) herdrPackage neovimPackage;
      };
      defaultText = lib.literalExpression "the bundled herdr-nvim package with the configured runtime dependencies";
      description = "Package containing the matching binary, Lua plugin and Herdr manifest.";
    };

    neovimAppName = lib.mkOption {
      type = lib.types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.-]*";
      default = "nvim";
      description = ''
        Neovim's NVIM_APPNAME. Publishes the Lua bundle at
        XDG_DATA_HOME/<appname>/herdr-nvim, and sets the sidebar environment
        when using a non-default appname.
      '';
    };

    settings = lib.mkOption {
      type = toml.type;
      default = { };
      example = lib.literalExpression ''
        {
          sidebar.position = "right";
          picker.max_files = 30;
        }
      '';
      description = "Herdr-side settings written to herdr-nvim/config.toml. Neovim keymaps/setup remain in your editor configuration.";
    };
  };

  config = lib.mkMerge [
    {
      # Only unlink on disable if this module previously registered the plugin.
      # Do not remove a user's separately installed plugin on a first import.
      home.activation.herdrNvim = lib.hm.dag.entryAfter [ "writeBoundary" ] (
        if cfg.enable then
          ''
            run ${herdr} plugin link ${lib.escapeShellArg pluginRoot}
            run mkdir -p ${lib.escapeShellArg (builtins.dirOf marker)}
            run ${lib.getExe pkgs.bash} -c ${lib.escapeShellArg "printf '%s\\n' ${lib.escapeShellArg pluginRoot} > ${lib.escapeShellArg marker}"}
          ''
        else
          ''
            if [[ -f ${lib.escapeShellArg marker} ]]; then
              run ${herdr} plugin unlink chmarax.herdr-nvim
              run rm -f ${lib.escapeShellArg marker}
            fi
          ''
      );
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = cfg.herdrPackage != null;
          message = "programs.herdr-nvim.herdrPackage must be set to your existing Herdr package.";
        }
      ];

      home.packages = [ cfg.package ];

      programs.herdr-nvim.settings = {
        sidebar = {
          nvim_bin = lib.mkDefault (lib.getExe cfg.neovimPackage);
          nvim_env = lib.mkDefault (
            lib.optional (cfg.neovimAppName != "nvim") "NVIM_APPNAME=${cfg.neovimAppName}"
          );
          position = lib.mkDefault "right";
        };
        picker = {
          scan_lines = lib.mkDefault 300;
          max_files = lib.mkDefault 20;
          frecency = lib.mkDefault true;
        };
      };

      xdg.configFile."herdr-nvim/config.toml".source =
        toml.generate "herdr-nvim-config.toml" cfg.settings;
      xdg.dataFile."${cfg.neovimAppName}/herdr-nvim".source = pluginRoot;
    })
  ];
}
