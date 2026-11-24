# lsp-profiles.nvim

Manage multiple sets of LSP settings overrides for Neovim LSP: named,
per-workspace profiles of language server config, switchable at runtime.

For example, define a `web` profile for a Rust workspace that points
rust-analyzer at `wasm32-unknown-unknown`, then switch between it and your
normal config with `:LspProfile web` / `:LspProfile none`. The affected
servers restart automatically, and the choice is remembered per workspace.

Works with any config you set up through `vim.lsp.config()` /
`vim.lsp.enable()` (or `vim.lsp.start()`). There's nothing to change in it.

## Requirements

Neovim 0.12 or newer.

## Installation

With the built-in plugin manager:

```lua
vim.pack.add({ 'https://github.com/cloone8/lsp-profiles.nvim' })
```

or with any other plugin manager. Don't lazy-load it: it needs to be loaded
before your language servers start. `setup()` is optional (see
[Global profiles](#global-profiles)).

## Defining profiles

Profiles live in `.nvim/lsp-profiles.lua` at the root of a workspace. Run
`:LspProfile edit` to create or open it. The file returns a table of profiles;
each profile maps language server names (as used with `vim.lsp.config()`) to
config to merge over that server's own:

```lua
-- <workspace>/.nvim/lsp-profiles.lua
return {
    web = {
        rust_analyzer = {
            settings = {
                ['rust-analyzer'] = {
                    cargo = { target = 'wasm32-unknown-unknown' },
                    check = { targets = 'wasm32-unknown-unknown' },
                },
            },
        },
    },
    release = {
        rust_analyzer = {
            settings = { ['rust-analyzer'] = { cargo = { cfgs = { 'release' } } } },
        },
    },
}
```

- **Anything in the config can be overridden**: `settings`, `init_options`,
  `cmd`, `cmd_env`, … The profile is merged in before the server starts.
- **Merging**: tables are merged key by key. Anything else in the profile,
  including lists (and `{}`), replaces the value.
- **Restricted, but treat it as code**: the file runs without access to `vim`
  or Lua's standard library, so it can only build a table. But that table can
  override `cmd`, which decides what program runs as the language server.
- **Trust**: like Neovim's `'exrc'` files, the file is only read after
  `vim.secure.read()` has asked whether you trust it (again after anyone else
  changes it). Saving it in Neovim trusts it, as you wrote it yourself. The
  trust check is what protects you; the restricted environment is no sandbox.

The workspace of a language server is the nearest folder at or above its root
(else above the file) that has a `.nvim/lsp-profiles.lua`. Without one, it's
the server's root folder; only [global profiles](#global-profiles) are
available there.

## Switching

| Command | |
|---|---|
| `:LspProfile` | Pick a profile with `vim.ui.select()`, previewing what each one overrides (in pickers that support `preview_item`) |
| `:LspProfile {name}` | Use profile `{name}` in the current buffer's workspace |
| `:LspProfile none` | Use no profile |
| `:LspProfile edit` | Edit the workspace's profiles file (created from a template) |

Switching restarts the servers in that workspace that the old or the new
profile affects. Other servers and workspaces keep running. Saving the
profiles file while a profile is active restarts them too, with the new
values. `:lsp restart` keeps the active profile.

The active profile per workspace is stored in
`stdpath('state')/lsp-profiles.json`, so it's still active the next time you
open that workspace.

## Global profiles

Profiles passed to `setup()` are available in every workspace. A workspace
file's profile with the same name is merged over the global one.

```lua
require('lsp-profiles').setup({
    profiles = {
        wasm = {
            rust_analyzer = {
                settings = { ['rust-analyzer'] = { cargo = { target = 'wasm32-unknown-unknown' } } },
            },
        },
    },
})
```

## Lua API

```lua
local profiles = require('lsp-profiles')
profiles.set('web')   -- like :LspProfile web (nil or 'none': no profile)
profiles.get()        -- active profile of the current buffer's workspace, or nil
profiles.list()       -- profile names available there
profiles.pick()       -- like :LspProfile
profiles.edit()       -- like :LspProfile edit
profiles.workspace()  -- the current buffer's workspace folder, or nil
profiles.status()     -- profile merged into the current buffer's servers, or nil
```

`set()`, `get()` and `list()` take an optional workspace folder, and
`workspace()` and `status()` an optional buffer number, instead of the
current buffer's.

For a statusline:

```lua
local profile = require('lsp-profiles').status()
if profile then
    -- e.g. show "[web]" next to the server names
end
```

## How it works

Neovim starts every language server through `vim.lsp.start()`, including
those enabled with `vim.lsp.enable()`. This plugin wraps that function: it
finds the server's workspace, merges in the active profile, and remembers the
config from before the merge. Restarts, its own and `:lsp restart`, start
from that again, so profiles never stack.

## Tests

```sh
tests/run.sh
```

Runs headless in throwaway XDG folders, with an in-process fake language
server.

## License

MIT
