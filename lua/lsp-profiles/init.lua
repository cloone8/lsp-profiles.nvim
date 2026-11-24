--- lsp-profiles.nvim: named, per-workspace sets of language server config
--- overrides, switchable at runtime.
---
--- How it works: Neovim starts every language server through vim.lsp.start()
--- (also the ones enabled with vim.lsp.enable()). This plugin wraps that
--- function and merges the workspace's active profile into the server's
--- config just before it starts. Switching profiles restarts the affected
--- servers, from the config they had before the old profile was merged in.

local M = {}

local api, uv = vim.api, vim.uv

--- The workspace's profiles file, relative to the workspace folder
M.file = '.nvim/lsp-profiles.lua'

--- Names that can't be profiles: they're arguments of :LspProfile
local reserved = { none = true, edit = true }

--- Profiles from setup(), available in every workspace
local global_profiles = {}

--- Active profile per workspace folder, persisted in the state folder
--- (loaded on first use)
---@type table<string, string>?
local state

--- Parsed profiles files: path -> { stamp = string, profiles = table|false }
local file_cache = {}

--- Merged config -> the config before the profile was merged in. Restarts
--- (ours, and :lsp restart, which passes `client.config` back to
--- vim.lsp.start()) start from that, so profiles never stack.
local bases = setmetatable({}, { __mode = 'k' })

--- Client id -> { workspace = folder, profile = name of the profile merged
--- into its config and override = what it merged in (if any) }
---@alias lsp-profiles.ClientInfo { workspace: string, profile: string?, override: table? }
---@type table<integer, lsp-profiles.ClientInfo>
local clients = {}

local original_start ---@type fun(config: vim.lsp.ClientConfig, opts?: vim.lsp.start.Opts): integer?

local function notify(msg, level)
    vim.notify('lsp-profiles: ' .. msg, level or vim.log.levels.INFO)
end

local function display(path)
    return vim.fn.fnamemodify(path, ':~')
end

local function sorted_keys(t)
    local keys = vim.tbl_keys(t)
    table.sort(keys)
    return keys
end

local function warn_no_workspace()
    notify('no workspace here: no language server attached and no ' .. M.file .. ' found', vim.log.levels.WARN)
end

---@param bufnr integer?
---@return integer
local function resolve_buf(bufnr)
    if bufnr == nil or bufnr == 0 then
        return api.nvim_get_current_buf()
    end
    return bufnr
end

-------------------------------------------------------------------------------
-- Merging
-------------------------------------------------------------------------------

local function is_dict(v)
    return type(v) == 'table' and not vim.islist(v)
end

local function merge_into(dst, override)
    for k, v in pairs(override) do
        if is_dict(v) and is_dict(dst[k]) then
            merge_into(dst[k], v)
        else
            dst[k] = vim.deepcopy(v)
        end
    end
    return dst
end

--- `base` with `override` merged in, as a new table. Dictionaries are merged
--- key by key; anything else in `override` (strings, numbers, lists, `{}`,
--- functions) replaces the value in `base`.
local function merge(base, override)
    return merge_into(vim.deepcopy(base), override)
end
M._merge = merge

-------------------------------------------------------------------------------
-- State (active profile per workspace)
-------------------------------------------------------------------------------

local function state_path()
    return vim.fs.joinpath(vim.fn.stdpath('state'), 'lsp-profiles.json')
end

--- The active profiles (read from disk on first use, or when `reload`: before
--- changing them, so another Neovim's changes aren't overwritten)
---@param reload? boolean
---@return table<string, string>
local function load_state(reload)
    if state and not reload then
        return state
    end
    state = {}
    local f = io.open(state_path(), 'r')
    if f then
        local ok, data = pcall(vim.json.decode, f:read('*a'))
        f:close()
        if ok and type(data) == 'table' then
            for ws, name in pairs(data) do
                if type(ws) == 'string' and type(name) == 'string' then
                    state[ws] = name
                end
            end
        end
    end
    return state
end

local function save_state()
    local path = state_path()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local f, err = io.open(path, 'w')
    if not f then
        notify('could not save the active profiles: ' .. tostring(err), vim.log.levels.WARN)
        return
    end
    -- An empty table would be encoded as `[]`; fine, it decodes to {} again
    f:write(vim.json.encode(state))
    f:close()
end

-------------------------------------------------------------------------------
-- Workspaces and their profiles files
-------------------------------------------------------------------------------

--- The nearest folder at or above `path` with a profiles file, or nil
---@param path string?
---@return string?
local function find_workspace(path)
    if not path or path == '' then
        return nil
    end
    path = vim.fs.normalize(vim.fs.abspath(path))
    local stat = uv.fs_stat(path)
    local dir = (stat and stat.type == 'directory') and path or vim.fs.dirname(path)
    while dir do
        if uv.fs_stat(vim.fs.joinpath(dir, M.file)) then
            return dir
        end
        local parent = vim.fs.dirname(dir)
        if parent == dir then
            return nil
        end
        dir = parent
    end
end

--- Checks the shape: { [profile] = { [server] = config table } }
---@return string? error
local function validate(profiles)
    if type(profiles) ~= 'table' then
        return 'must return a table of profiles'
    end
    for name, servers in pairs(profiles) do
        if type(name) ~= 'string' or name == '' or name:find('%s') then
            return ('invalid profile name %s: must be a string without spaces'):format(vim.inspect(name))
        end
        if reserved[name] then
            return ('"%s" is reserved and can\'t be a profile name'):format(name)
        end
        if type(servers) ~= 'table' then
            return ('profile "%s" must be a table of language servers'):format(name)
        end
        for server, config in pairs(servers) do
            if type(server) ~= 'string' or type(config) ~= 'table' then
                return ('profile "%s": %s must map to a table of config'):format(name, vim.inspect(server))
            end
        end
    end
end

--- The profiles in a workspace's profiles file, or nil (no file, not trusted,
--- or invalid; the last two with a warning, once per version of the file).
--- The file is only read after Neovim's trust check (vim.secure.read()),
--- and must return a plain table. A file that failed is not read again until
--- it changes, unless `retry` (for explicit actions, like after :trust).
---@param path string
---@param retry? boolean
---@return table?
local function read_file(path, retry)
    local stat = uv.fs_stat(path)
    if not stat then
        file_cache[path] = nil
        return nil
    end
    local stamp = ('%d:%d:%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
    local cached = file_cache[path]
    if cached and cached.stamp == stamp and (cached.profiles or not retry) then
        return cached.profiles or nil
    end

    local profiles, err = false, nil
    local text = vim.secure.read(path)
    if type(text) ~= 'string' then
        err = 'not trusted, so not loaded (open it and run :trust to allow it)'
    else
        -- Text only (no bytecode), with an empty environment: the file is
        -- meant to be data. This is no sandbox though; the trust check is
        -- what protects you.
        local chunk, load_err = load(text, '@' .. path, 't', {})
        if not chunk then
            err = load_err
        else
            local ok, result = pcall(chunk)
            if not ok then
                err = tostring(result)
            else
                err = validate(result)
                if not err then
                    profiles = result
                end
            end
        end
    end

    file_cache[path] = { stamp = stamp, profiles = profiles }
    if err then
        notify(display(path) .. ': ' .. err, vim.log.levels.WARN)
    end
    return profiles or nil
end

--- All profiles for a workspace: the global ones, with the workspace file's
--- merged over them (a profile in both is merged, the file's values winning)
---@param ws string?
---@param retry? boolean Read the file again if it failed before
---@return table<string, table<string, table>>
local function profiles_for(ws, retry)
    local from_file = ws and read_file(vim.fs.joinpath(ws, M.file), retry)
    return from_file and merge(global_profiles, from_file) or global_profiles
end

--- The override for `server` from `ws`'s active profile, and that profile's
--- name; nil if the profile doesn't override it (or there's none)
---@return table? override, string? profile
local function active_override(ws, server)
    local name = load_state()[ws]
    if not name then
        return nil
    end
    local profile = profiles_for(ws)[name]
    if not profile then
        -- Unless its file failed to load (that already warned)
        local cached = file_cache[vim.fs.joinpath(ws, M.file)]
        if not (cached and cached.profiles == false) then
            vim.notify_once(('lsp-profiles: profile "%s" for %s no longer exists; using none'):format(name, display(ws)),
                vim.log.levels.WARN)
        end
        return nil
    end
    if profile[server] then
        return profile[server], name
    end
end

-------------------------------------------------------------------------------
-- The vim.lsp.start() wrapper
-------------------------------------------------------------------------------

--- The config and options to start a server with: `config` with its
--- workspace's active profile merged in. Also what to record about the
--- client (nil outside a workspace).
---@param config vim.lsp.ClientConfig
---@param opts vim.lsp.start.Opts
---@return vim.lsp.ClientConfig, vim.lsp.start.Opts, lsp-profiles.ClientInfo?
local function resolve(config, opts)
    local bufnr = resolve_buf(opts.bufnr)

    -- vim.lsp.enable() leaves finding the root from `root_markers` to
    -- vim.lsp.start(). Do it here, as we need the root, and so that
    -- vim.lsp.start() doesn't copy the config (which would lose its entry
    -- in `bases`).
    ---@diagnostic disable-next-line: invisible (internal, from vim.lsp.enable())
    local markers = opts._root_markers
    if markers then
        opts = vim.tbl_extend('force', {}, opts)
        opts._root_markers = nil
        if not config.root_dir then
            local root = vim.fs.root(bufnr, markers)
            if root then
                config = vim.tbl_extend('force', {}, config, { root_dir = root })
            end
        end
    end

    local root = config.root_dir
    if type(root) ~= 'string' then
        root = nil
    end
    local ws = find_workspace(root or api.nvim_buf_get_name(bufnr)) or root
    if not ws then
        return config, opts, nil
    end

    local override, profile = active_override(ws, config.name)
    if not override then
        return config, opts, { workspace = ws }
    end
    local merged = merge(config, override)
    bases[merged] = config
    return merged, opts, { workspace = ws, profile = profile, override = override }
end

---@param config vim.lsp.ClientConfig
---@param opts? vim.lsp.start.Opts
---@return integer? client_id
local function start(config, opts)
    opts = opts or {}
    -- A config we merged a profile into (from :lsp restart): start over from
    -- the one before
    config = bases[config] or config

    -- A bug here must not keep the server from starting: then start it
    -- without a profile
    local ok, start_config, start_opts, info = pcall(resolve, config, opts)
    if not ok then
        vim.notify_once('lsp-profiles: ' .. tostring(start_config) .. ' (starting without a profile)',
            vim.log.levels.ERROR)
        return original_start(config, opts)
    end

    local id = original_start(start_config, start_opts)
    if id and info and not clients[id] then
        clients[id] = info
    end
    return id
end

-------------------------------------------------------------------------------
-- Restarting servers
-------------------------------------------------------------------------------

--- Stops `client`, waits for it to exit, then starts it again (with the
--- workspace's current profile) and attaches the same buffers
---@param client vim.lsp.Client
local function restart(client)
    local id = client.id
    local buffers = vim.tbl_keys(client.attached_buffers)
    local config = bases[client.config] or client.config
    clients[id] = nil
    client:stop()

    local timer = assert(uv.new_timer())
    local waited, done = 0, false
    timer:start(50, 50, vim.schedule_wrap(function()
        if done then
            return
        end
        if vim.lsp.get_client_by_id(id) then
            waited = waited + 50
            -- Not gone after 5 s: kill it (stop() does nothing if it's already
            -- killed). Still there after 10 s: give up.
            if waited == 5000 then
                client:stop(true)
            elseif waited >= 10000 then
                done = true
                timer:stop()
                timer:close()
                notify(('%s did not stop; not restarting it'):format(client.name), vim.log.levels.WARN)
            end
            return
        end
        done = true
        timer:stop()
        timer:close()

        local new_id = start(config, { bufnr = buffers[1], attach = false })
        if new_id then
            for _, buf in ipairs(buffers) do
                if api.nvim_buf_is_valid(buf) then
                    vim.lsp.buf_attach_client(buf, new_id)
                end
            end
        end
    end))
end

--- The running servers in `ws` that profile `name` (nil: none) needs
--- restarted: those whose merged-in override differs from what the profile
--- (as it is now) has for them. Sorted by name.
---@param ws string
---@param name string?
---@return vim.lsp.Client[]
local function needing_restart(ws, name)
    local profile = name and profiles_for(ws)[name] or {}
    local list = {}
    for id, info in pairs(clients) do
        local client = vim.lsp.get_client_by_id(id)
        if not client then
            clients[id] = nil
        elseif info.workspace == ws and not vim.deep_equal(info.override, profile[client.name]) then
            table.insert(list, client)
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

local function client_names(list)
    return vim.tbl_map(function(client) return client.name end, list)
end

--- Restarts the servers in `ws` that need it for its active profile (see
--- needing_restart())
---@param ws string
---@return string[] names of the restarted servers
local function restart_workspace(ws)
    local list = needing_restart(ws, load_state()[ws])
    for _, client in ipairs(list) do
        restart(client)
    end
    return client_names(list)
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- The workspace of a buffer: the one of the language servers attached to
--- it, else the nearest folder above it with a profiles file. Nil when
--- neither exists.
---@param bufnr? integer (default: current buffer)
---@return string?
function M.workspace(bufnr)
    bufnr = resolve_buf(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        local info = clients[client.id]
        if info then
            return info.workspace
        end
    end
    local name = api.nvim_buf_get_name(bufnr)
    return find_workspace(name ~= '' and name or uv.cwd())
end

--- Names of the profiles available in a workspace, sorted
---@param ws? string (default: the current buffer's)
---@return string[]
function M.list(ws)
    return sorted_keys(profiles_for(ws or M.workspace()))
end

--- The active profile of a workspace, or nil
---@param ws? string (default: the current buffer's)
---@return string?
function M.get(ws)
    ws = ws or M.workspace()
    return ws and load_state()[ws] or nil
end

--- Makes `name` the active profile of a workspace (nil or 'none': no profile),
--- remembers that, and restarts the servers it affects
---@param name string?
---@param ws? string (default: the current buffer's)
---@return boolean ok
function M.set(name, ws)
    if name == 'none' then
        name = nil
    end
    ws = ws or M.workspace()
    if not ws then
        warn_no_workspace()
        return false
    end
    if name and not profiles_for(ws, true)[name] then
        notify(('no profile "%s" for %s'):format(name, display(ws)), vim.log.levels.WARN)
        return false
    end

    local st = load_state(true)
    local changed = st[ws] ~= name
    if changed then
        st[ws] = name
        save_state()
    end

    local restarted = restart_workspace(ws)
    local label = name and ('profile "' .. name .. '"') or 'no profile'
    if not changed and #restarted == 0 then
        notify('already using ' .. label)
    else
        notify(('%s for %s%s'):format(label, display(ws),
            #restarted > 0 and ('; restarting ' .. table.concat(restarted, ', ')) or ''))
    end
    return true
end

--- Preview of profile `name` ('none': no profile) in the picker, as Lua:
--- what it overrides per server, and which running servers choosing it
--- restarts
---@param ws string
---@param name string
---@param active string Active profile, or 'none'
---@param profiles table<string, table<string, table>>
---@return string[]
function M._preview_lines(ws, name, active, profiles)
    local lines = { '-- ' .. name .. (name == active and ' (active)' or '') }
    local restarts = client_names(needing_restart(ws, name ~= 'none' and name or nil))
    if #restarts > 0 then
        table.insert(lines, '-- Choosing it restarts: ' .. table.concat(restarts, ', '))
    elseif name ~= active then
        table.insert(lines, '-- Choosing it restarts nothing (none of its servers are running here)')
    end
    table.insert(lines, '')

    if name == 'none' then
        table.insert(lines, '-- No overrides: every server uses its own config')
        return lines
    end
    local profile = profiles[name] or {}
    for i, server in ipairs(sorted_keys(profile)) do
        if i > 1 then
            table.insert(lines, '')
        end
        vim.list_extend(lines, vim.split(server .. ' = ' .. vim.inspect(profile[server]), '\n'))
    end
    return lines
end

--- Picks the active profile of the current buffer's workspace with
--- vim.ui.select(), previewing each profile's overrides (in pickers that
--- support `preview_item`)
function M.pick()
    local ws = M.workspace()
    if not ws then
        warn_no_workspace()
        return
    end
    local active = M.get(ws) or 'none'
    local profiles = profiles_for(ws, true)
    local items = vim.list_extend({ 'none' }, sorted_keys(profiles))
    vim.ui.select(items, {
        prompt = 'LSP profile',
        kind = 'lsp-profiles',
        format_item = function(item)
            return item == active and (item .. ' (active)') or item
        end,
        preview_item = function(item)
            local buf = api.nvim_create_buf(false, true)
            api.nvim_buf_set_lines(buf, 0, -1, false, M._preview_lines(ws, item, active, profiles))
            vim.bo[buf].bufhidden = 'wipe'
            vim.bo[buf].filetype = 'lua'
            return { buf = buf }
        end,
    }, function(choice)
        if choice then
            M.set(choice, ws)
        end
    end)
end

local template = {
    '-- LSP profiles for this workspace (lsp-profiles.nvim). Switch with :LspProfile.',
    '--',
    '-- Each profile maps language server names (as in vim.lsp.config()) to config',
    '-- that is merged over that server\'s own: settings, init_options, cmd, cmd_env, ...',
    '-- Tables are merged key by key; anything else, including lists, replaces.',
    '-- It runs without access to `vim` or the standard library, but it can set `cmd`',
    '-- (the program that runs), so Neovim asks whether you trust it before loading it.',
    'return {',
    '    -- example = {',
    '    --     rust_analyzer = {',
    '    --         settings = {',
    '    --             [\'rust-analyzer\'] = { cargo = { target = \'wasm32-unknown-unknown\' } },',
    '    --         },',
    '    --     },',
    '    -- },',
    '}',
}

--- Opens the workspace's profiles file; a new one starts from a template.
--- Without a workspace: in the repository root (else the current folder).
function M.edit()
    local ws = M.workspace() or vim.fs.root(0, '.git') or uv.cwd()
    local path = vim.fs.joinpath(ws, M.file)
    local exists = uv.fs_stat(path) ~= nil
    vim.cmd.edit(vim.fn.fnameescape(path))
    if not exists and api.nvim_buf_line_count(0) == 1 and api.nvim_buf_get_lines(0, 0, 1, false)[1] == '' then
        api.nvim_buf_set_lines(0, 0, -1, false, template)
    end
end

--- The profile merged into the servers attached to a buffer, for a
--- statusline. Nil when there's none.
---@param bufnr? integer (default: current buffer)
---@return string?
function M.status(bufnr)
    bufnr = resolve_buf(bufnr)
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
        local info = clients[client.id]
        if info and info.profile then
            return info.profile
        end
    end
end

---@class lsp-profiles.Opts
---@field profiles? table<string, table<string, table>> Profiles for every workspace

--- Optional: sets the global profiles (available in every workspace). A
--- workspace file's profile with the same name is merged over it.
---@param opts? lsp-profiles.Opts
function M.setup(opts)
    opts = opts or {}
    local profiles = opts.profiles or {}
    local err = validate(profiles)
    if err then
        notify('setup(): ' .. err, vim.log.levels.ERROR)
        return
    end
    global_profiles = profiles
end

-------------------------------------------------------------------------------
-- Installation (from plugin/lsp-profiles.lua)
-------------------------------------------------------------------------------

local function complete(lead)
    local items = { 'none', 'edit' }
    local ws = M.workspace()
    if ws then
        vim.list_extend(items, M.list(ws))
    end
    return vim.tbl_filter(function(item)
        return vim.startswith(item, lead)
    end, items)
end

function M._install()
    if original_start then
        return
    end
    original_start = vim.lsp.start
    vim.lsp.start = start

    api.nvim_create_user_command('LspProfile', function(cmd)
        if cmd.args == '' then
            M.pick()
        elseif cmd.args == 'edit' then
            M.edit()
        else
            M.set(cmd.args)
        end
    end, {
        nargs = '?',
        complete = complete,
        desc = 'Switch LSP profile (none: no profile; edit: edit the profiles file)',
    })

    local group = api.nvim_create_augroup('lsp-profiles', {})
    local pattern = '*/' .. M.file
    api.nvim_create_autocmd('BufWritePre', {
        group = group,
        pattern = pattern,
        desc = 'Create the folder of a new profiles file',
        callback = function(ev)
            vim.fn.mkdir(vim.fs.dirname(api.nvim_buf_get_name(ev.buf)), 'p')
        end,
    })
    api.nvim_create_autocmd('BufWritePost', {
        group = group,
        pattern = pattern,
        desc = 'Trust a profiles file written in Neovim, and apply the changes',
        callback = function(ev)
            local path = vim.fs.normalize(api.nvim_buf_get_name(ev.buf))
            -- You wrote it yourself, so don't ask whether to trust it. (The
            -- write changed its mtime, so it's read again.)
            vim.secure.trust({ action = 'allow', bufnr = ev.buf })
            local ws = vim.fs.dirname(vim.fs.dirname(path))
            -- If it doesn't load now (say, a half-done edit), read_file()
            -- warned; leave the servers as they are
            if load_state()[ws] and read_file(path) then
                local restarted = restart_workspace(ws)
                if #restarted > 0 then
                    notify('profiles changed; restarting ' .. table.concat(restarted, ', '))
                end
            end
        end,
    })
end

return M
