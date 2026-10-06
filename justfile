ci:
	cargo fmt --check
	cargo test --locked
	nvim --headless --noplugin -u NONE -l tests/run.lua

nix-check:
	nix flake check

setup:
	git config core.hooksPath .githooks
