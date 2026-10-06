{
  lib,
  rustPlatform,
  symlinkJoin,
  makeWrapper,
  pkg-config,
  cmake,
  python3,
  git,
  which,
  coreutils,
  procps,
  libgit2,
  openssl,
  zlib,
  neovim,
  stdenv,
  herdrPackage ? null,
  neovimPackage ? neovim,
}:
let
  manifest = builtins.fromTOML (builtins.readFile ../Cargo.toml);
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../src
      ../examples
      ../tests
      ../lua
      ../plugin
      ../doc
      ../herdr-plugin.toml
    ];
  };

  unwrapped = rustPlatform.buildRustPackage {
    pname = "herdr-nvim";
    inherit (manifest.package) version;
    inherit src;

    # Cargo.lock pins every crate; no mutable fetches or installer hooks.
    cargoLock.lockFile = ../Cargo.lock;

    nativeBuildInputs = [
      pkg-config
      cmake
      python3
    ];
    buildInputs = [
      libgit2
      openssl
      zlib
    ];
    nativeCheckInputs = [
      neovim
      git
      which
    ]
    ++ lib.optionals stdenv.hostPlatform.isLinux [ procps ];
    doCheck = true;
    # The tests change process-wide environment variables. Pass this to the
    # test runner explicitly; cargoCheckHook overrides RUST_TEST_THREADS.
    checkFlags = [ "--test-threads=1" ];

    preCheck = ''
      export HOME="$TMPDIR/test-home"
      export XDG_CONFIG_HOME="$HOME/.config"
      export XDG_DATA_HOME="$HOME/.local/share"
      export XDG_STATE_HOME="$HOME/.local/state"
      export XDG_RUNTIME_DIR="$TMPDIR/runtime"
      mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
      chmod 700 "$XDG_RUNTIME_DIR"

      # The upstream fff end-to-end test uses git ls-files over its source.
      # Filtered Nix sources intentionally have no .git, so supply a local
      # throwaway index without committing or indexing build artifacts.
      git init --quiet
      git add Cargo.toml Cargo.lock src examples tests lua plugin doc herdr-plugin.toml

      # Upstream's availability probe calls which. Fail rather than silently
      # skipping the real daemon tests if their native tools are missing.
      which nvim
      command -v ps
      command -v kill
    '';

    postInstall = ''
      root="$out/share/herdr-nvim"
      mkdir -p "$root/bin"
      cp -r lua plugin doc "$root/"
      ln -s "$out/bin/herdr-nvim" "$root/bin/herdr-nvim"

      # A Nix-installed plugin is already built. Keep the upstream manifest's
      # actions/events, but never let Herdr run a download/build installer.
      python3 - "$root/herdr-plugin.toml" <<'PY'
      import pathlib
      import sys
      import tomllib

      original = pathlib.Path("herdr-plugin.toml").read_text()
      manifest = original.split("\n[[build]]", 1)[0].rstrip() + "\n"
      assert "build" not in tomllib.loads(manifest)
      pathlib.Path(sys.argv[1]).write_text(manifest)
      PY
    '';

    meta = {
      description = "Persistent Neovim sidebar and code-review annotations for Herdr";
      homepage = "https://github.com/Audrique/herdr-nvim";
      license = lib.licenses.mit;
      mainProgram = "herdr-nvim";
      platforms = lib.platforms.unix;
    };
  };

  runtimeTools = [
    git
    coreutils
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [ procps ]
  ++ lib.optional (herdrPackage != null) herdrPackage
  ++ lib.optional (neovimPackage != null) neovimPackage;
in
# Keep compilation separate from host-specific runtime dependencies. Supplying
# another Herdr/Neovim package only rebuilds this small wrapper, not Rust.
symlinkJoin {
  name = unwrapped.name;
  inherit (unwrapped) pname version meta;
  paths = [ unwrapped ];
  nativeBuildInputs = [
    makeWrapper
    python3
  ];

  postBuild = ''
    wrapProgram "$out/bin/herdr-nvim" \
      --set HERDR_NVIM_PLUGIN_ROOT "$out/share/herdr-nvim" \
      --prefix PATH : ${lib.escapeShellArg (lib.makeBinPath runtimeTools)}

    # Manifest actions must invoke the wrapper, not the unwrapped executable.
    rm "$out/share/herdr-nvim/bin/herdr-nvim"
    ln -s "$out/bin/herdr-nvim" "$out/share/herdr-nvim/bin/herdr-nvim"

    # Herdr 0.8.x executes sidebar commands in the project's cwd. Relative
    # commands would resolve there instead of in the immutable plugin bundle.
    python3 - "$out" <<'PY'
    import json
    import pathlib
    import sys
    import tomllib

    output = pathlib.Path(sys.argv[1])
    path = output / "share/herdr-nvim/herdr-plugin.toml"
    executable = str(output / "bin/herdr-nvim")
    text = path.read_text().replace('["bin/herdr-nvim",', '[' + json.dumps(executable) + ',')
    for section in ("actions", "panes", "events", "startup"):
        for entry in tomllib.loads(text).get(section, []):
            assert entry["command"][0] == executable, entry
    path.unlink()  # break the symlink; never modify the unwrapped store path
    path.write_text(text)
    PY
  '';

  passthru = {
    inherit unwrapped src;
  };
}
