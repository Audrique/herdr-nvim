# Nix integration

The fork provides the Rust executable, matching Neovim Lua plugin, a Home
Manager module, development tools and checks. Both halves come from **one flake
revision**. Do not independently update this installation with `herdr plugin
install` or a Git checkout managed by lazy.nvim.

## Home Manager

Add the fork as an input. Following your existing nixpkgs/Home Manager inputs
avoids duplicate dependency pins:

```nix
inputs.herdr-nvim = {
  url = "github:Audrique/herdr-nvim";
  inputs.nixpkgs.follows = "nixpkgs";
  inputs.home-manager.follows = "home-manager";
};
```

Import the module in your Home Manager configuration:

```nix
{ inputs, pkgs, ... }: {
  imports = [ inputs.herdr-nvim.homeModules.default ];

  programs.herdr-nvim = {
    enable = true;
    # Reuse your existing Herdr package/overlay, not a second installation.
    herdrPackage = pkgs.herdr;
    neovimPackage = pkgs.neovim;
    settings.sidebar.position = "right";
  };
}
```

The module:

- Builds from Cargo.lock, rather than downloading a generic Linux binary.
- Bundles Lua resources and the Herdr manifest with the executable.
- Gives manifest actions absolute executable paths, including sidebar panes
  launched with a project-specific working directory.
- Removes imperative installer/build hooks from the packaged manifest.
- Adds the chosen Herdr/Neovim and Git tools to the executable's runtime PATH.
- Registers the immutable plugin bundle with `herdr plugin link` during Home
  Manager activation; no installer runs and no network is needed at activation.
- Writes `~/.config/herdr-nvim/config.toml` declaratively.
- Publishes the Lua bundle at `~/.local/share/nvim/herdr-nvim`.
- Records that it owns the plugin registration and unlinks it when disabled
  while the module remains imported. If you remove the import entirely, run
  `herdr plugin unlink chmarax.herdr-nvim` yourself.

Herdr is not in the supported nixpkgs channel, so `herdrPackage` is required when
this module is enabled. It should be the same Herdr used by your Pi runtime.
`homeManagerModules.default` is an alias for `homeModules.default`.

For a custom `NVIM_APPNAME`, set `programs.herdr-nvim.neovimAppName`. The module
publishes the bundle under the corresponding data directory and supplies the
appname to the sidebar daemon and clients. Set additional Herdr-side options
through `settings`; normal Neovim configuration remains yours.

## Neovim

Point lazy.nvim at the published bundle, not another independently pinned Git
checkout. Load it eagerly so the sidebar's VimEnter fallback preserves your
configuration:

```lua
{
  name = "herdr-nvim",
  dir = vim.fn.stdpath("data") .. "/herdr-nvim",
  lazy = false,
  opts = { keymaps = false, clear_after_send = true },
  keys = {
    { "<leader>ac", "<cmd>Herdr comment<cr>", desc = "Annotate line" },
    { "<leader>ac", ":Herdr comment<cr>", mode = "x", desc = "Annotate selection" },
    { "<leader>al", "<cmd>Herdr list<cr>", desc = "Review annotations" },
    { "<leader>as", "<cmd>Herdr send<cr>", desc = "Stage feedback in agent draft" },
    { "<leader>ai", "<cmd>Herdr ref<cr>", desc = "Reference line" },
    { "<leader>ai", ":Herdr ref<cr>", mode = "x", desc = "Reference selection" },
  },
}
```

`Herdr send` stages feedback without Enter. The example deliberately does not
map `Herdr submit`; submit the draft yourself in Pi. The explicit submit command
and upstream default mappings remain available if deliberately configured.

Use `require("herdr-nvim").statusline()` in your normal statusline to show pending
annotations. This plugin does not replace your Git/diff or remote PR tooling.

Add the standard sidebar/picker actions to your existing Herdr configuration;
the module does not take ownership of the whole `herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+e"
type = "plugin_action"
command = "chmarax.herdr-nvim.toggle"
description = "Neovim sidebar"

[[keys.command]]
key = "prefix+o"
type = "plugin_action"
command = "chmarax.herdr-nvim.pick-file"
description = "Open agent-touched file"
```

## Pairing, review and lifecycle

Keep Pi's native TUI and your guarded launcher. This integration does not start
an RPC backend, replace permissions, or install a second Pi notification bridge.

Save your edits explicitly before handing work to Pi. References point to disk;
annotation snippets are not full unsaved-buffer snapshots. Inspect completed
changes with your normal diff tooling, annotate real files/ranges, and stage
feedback into Pi's draft. Never autosave just to send context.

Target selection is workspace/tab-aware. When more than one agent is plausible,
choose explicitly rather than assuming which worker should receive feedback.
For the touched-file picker, invoke it from the intended Pi pane if the sidebar
has multiple plausible agent neighbors. The picker is advisory: it includes
dirty Git files and can include attempted tool calls, not only applied edits.

Drafts use Herdr's socket paste API with no appended keys, after fresh agent and
pane identity/state checks. Blocked dialogs, replaced/moved agents, unknown
states and unsafe control characters are refused. Displayed code snippets
expand tabs to spaces; exact code remains on disk. Literal tabs in comments or
file references are refused rather than treated as terminal keys.

Herdr 0.8.2 does not offer atomic identity-conditional delivery or expose the
terminal's bracketed-paste mode. Validation and delivery therefore retain a
small race; this is not a new permission/security boundary. Multiline LF input
relies on Pi's native editor behavior. If a socket request times out, inspect
Pi's draft before retrying: delivery may already have happened. No automatic
retry or submit is performed. Always review the staged draft yourself.

Hiding the sidebar keeps its daemon, buffers and pending notes alive. **Closing
the Herdr tab/workspace stops that daemon and can discard unsaved work and
annotations.** Notes are in memory and successful sends normally clear them.

After changing the flake pin or Neovim setup, save your buffers/notes and stop
old daemons before toggling them back on:

```sh
herdr-nvim daemons
herdr-nvim daemons stop <tab-id>
```

Healthy persistent daemons do not hot-reload Lua code after a package upgrade.
Avoid `--force` unless you intentionally want to discard unsaved work.

## Development and checks

```sh
nix develop
just ci
nix flake check
```

The shell provides Cargo, rustc, rustfmt, Clippy, rust-analyzer, Neovim, Git,
Just, nixfmt and nixd, with the native libraries needed by fff-search/libgit2.
No global Rust installation or rustup is required.

```sh
nix develop --command cargo test --locked
nix develop --command cargo clippy --all-targets --locked
nix fmt
nix build
nix run -- daemons
```

Checks cover the package's Rust tests (including real headless Neovim daemons),
the Lua suite, Rust/Nix formatting, the packaged manifest/resource layout, and
Home Manager settings/registration/disable behavior against a fake Herdr. They
do not modify your real Herdr registry, contact an agent, or rebuild your system.

The flake exposes Linux and Darwin package/dev-shell outputs. Run checks on each
platform you intend to use; passing on Linux does not validate Darwin.

For consumer testing before publishing a fork revision:

```sh
nix flake check --override-input herdr-nvim ../pi-forks/herdr-nvim
```

Publish a tested fork revision first, then update the consumer's lock file.
Normal activation needs only the resulting immutable store bundle.
