#!/usr/bin/env sh
# Runs the tests headless, in throwaway XDG folders (your own Neovim state and
# trust database are not touched).
set -eu

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
export XDG_CONFIG_HOME="$dir/config" XDG_DATA_HOME="$dir/data" \
    XDG_STATE_HOME="$dir/state" XDG_CACHE_HOME="$dir/cache"
export LSP_PROFILES_TEST_DIR="$dir/work"
mkdir -p "$LSP_PROFILES_TEST_DIR"

here=$(dirname "$0")
nvim --clean --headless -l "$here/run.lua" 1
nvim --clean --headless -l "$here/run.lua" 2
