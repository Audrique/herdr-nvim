{
  pkgs,
  package,
  home-manager,
  module,
}:
let
  inherit (pkgs) lib;
  src = package.src;
  testHome = "/tmp/herdr-nvim-module-test";
  herdr = pkgs.writeShellScriptBin "herdr" ''
    printf '%s\n' "$*" >> "$HERDR_NVIM_TEST_LOG"
  '';
  home =
    enable: appname:
    home-manager.lib.homeManagerConfiguration {
      inherit pkgs;
      modules = [
        module
        {
          home.username = "test";
          home.homeDirectory = testHome;
          home.stateVersion = "26.05";
          programs.herdr-nvim = {
            inherit enable package;
            herdrPackage = herdr;
            neovimAppName = appname;
            settings.picker.max_files = 31;
          };
        }
      ];
    };
  enabled = (home true "review-nvim").config;
  disabled = (home false "review-nvim").config;
  defaults = (home true "nvim").config;
  assertionsPass = config: builtins.all (entry: entry.assertion) config.assertions;
in
{
  inherit package;

  lua =
    pkgs.runCommand "herdr-nvim-lua-tests"
      {
        nativeBuildInputs = [ pkgs.neovim ];
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        nvim --headless --noplugin -u NONE -l ${src}/tests/run.lua
        touch "$out"
      '';

  rustfmt =
    pkgs.runCommand "herdr-nvim-rustfmt"
      {
        nativeBuildInputs = [
          pkgs.cargo
          pkgs.rustfmt
        ];
      }
      ''
        cp -r ${src} source
        chmod -R u+w source
        cd source
        cargo fmt --all -- --check
        touch "$out"
      '';

  nixfmt =
    pkgs.runCommand "herdr-nvim-nixfmt"
      {
        nativeBuildInputs = [ pkgs.nixfmt ];
      }
      ''
        nixfmt --check ${../flake.nix} ${./package.nix} ${./home-manager.nix} ${./checks.nix}
        touch "$out"
      '';

  home-manager =
    assert assertionsPass enabled && assertionsPass disabled && assertionsPass defaults;
    assert
      toString enabled.xdg.dataFile."review-nvim/herdr-nvim".source == "${package}/share/herdr-nvim";
    assert toString defaults.xdg.dataFile."nvim/herdr-nvim".source == "${package}/share/herdr-nvim";
    pkgs.runCommand "herdr-nvim-home-manager"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.neovim
          pkgs.bash
        ];
        settings = enabled.xdg.configFile."herdr-nvim/config.toml".source;
        defaultSettings = defaults.xdg.configFile."herdr-nvim/config.toml".source;
        inherit package testHome;
        enableScript = pkgs.writeText "herdr-nvim-enable.sh" enabled.home.activation.herdrNvim.data;
        disableScript = pkgs.writeText "herdr-nvim-disable.sh" disabled.home.activation.herdrNvim.data;
      }
      ''
        export HOME="$TMPDIR/home"
        export HERDR_NVIM_TEST_LOG="$TMPDIR/herdr.log"
        mkdir -p "$HOME"

        python3 <<'PY'
        import json
        import os
        import pathlib
        import tomllib

        root = pathlib.Path(os.environ["package"]) / "share/herdr-nvim"
        manifest = tomllib.loads((root / "herdr-plugin.toml").read_text())
        assert "build" not in manifest
        executable = str(pathlib.Path(os.environ["package"]) / "bin/herdr-nvim")
        for section in ("actions", "panes", "events", "startup"):
            for entry in manifest.get(section, []):
                assert entry["command"][0] == executable, entry
        assert (root / "lua/herdr-nvim/init.lua").is_file()
        assert (root / "bin/herdr-nvim").resolve() == pathlib.Path(executable).resolve()
        settings = tomllib.loads(pathlib.Path(os.environ["settings"]).read_text())
        assert settings["sidebar"]["position"] == "right"
        assert settings["sidebar"]["nvim_env"] == ["NVIM_APPNAME=review-nvim"]
        assert pathlib.Path(settings["sidebar"]["nvim_bin"]).is_absolute()
        assert settings["picker"]["max_files"] == 31
        defaults = tomllib.loads(pathlib.Path(os.environ["defaultSettings"]).read_text())
        assert defaults["sidebar"]["nvim_env"] == []
        for action in ("enable", "disable"):
            source = pathlib.Path(os.environ[action + "Script"]).read_text()
            source = source.replace(os.environ["testHome"], os.environ["HOME"])
            pathlib.Path(action + ".sh").write_text("set -euo pipefail\nrun() { \"$@\"; }\n" + source)
        PY

        # No live Herdr instance: the module uses a recording fake executable.
        bash disable.sh
        test ! -e "$HERDR_NVIM_TEST_LOG"
        bash enable.sh
        grep -Fx "plugin link $package/share/herdr-nvim" "$HERDR_NVIM_TEST_LOG"
        test "$(cat "$HOME/.local/state/herdr-nvim/nix-plugin-root")" = "$package/share/herdr-nvim"
        bash disable.sh
        grep -Fx 'plugin unlink chmarax.herdr-nvim' "$HERDR_NVIM_TEST_LOG"
        test ! -e "$HOME/.local/state/herdr-nvim/nix-plugin-root"

        # Validate the bundled Lua plugin, without loading personal config or
        # contacting any agent. Eager setup must keep automatic-submit unmapped.
        export HERDR_NVIM_PLUGIN_ROOT="$package/share/herdr-nvim"
        nvim --headless --noplugin -u NONE \
          '+lua vim.opt.rtp:append(vim.env.HERDR_NVIM_PLUGIN_ROOT); require("herdr-nvim").setup({keymaps=false}); assert(vim.fn.exists(":Herdr") == 2); assert(vim.fn.maparg("<leader>aS", "n") == "")' \
          '+qa!'
        touch "$out"
      '';
}
