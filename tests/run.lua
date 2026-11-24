-- Headless tests, with an in-process fake language server. Run with
--   tests/run.sh
-- (throwaway XDG folders; it runs this file twice: phase 1, then phase 2 as a
-- fresh Neovim, to check that the active profile is remembered).

local phase = _G.arg[1] or '1'
local tmp = assert(vim.env.LSP_PROFILES_TEST_DIR, 'run through tests/run.sh')
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)
vim.cmd.runtime('plugin/lsp-profiles.lua')
local profiles = require('lsp-profiles')

local failures = 0
local print = function(msg) io.stdout:write(msg, '\n') end
local function check(cond, what, detail)
    if cond then
        print('ok   ' .. what)
    else
        failures = failures + 1
        print('FAIL ' .. what .. (detail and (': ' .. vim.inspect(detail)) or ''))
    end
end

local function wait(what, fn)
    if not vim.wait(5000, fn, 20) then
        failures = failures + 1
        print('FAIL timed out waiting for ' .. what)
        return false
    end
    return true
end

-- Fake server: answers initialize/shutdown, records initialize params
local inits = {}
local function fake_cmd(dispatchers)
    local closing = false
    return {
        request = function(method, params, callback)
            if method == 'initialize' then
                table.insert(inits, params)
                vim.schedule(function() callback(nil, { capabilities = {} }) end)
            elseif method == 'shutdown' then
                vim.schedule(function() callback(nil, nil) end)
            end
            return true, 1
        end,
        notify = function(method)
            if method == 'exit' then
                closing = true
                vim.schedule(function() dispatchers.on_exit(0, 15) end)
            end
            return true
        end,
        is_closing = function() return closing end,
        terminate = function()
            if not closing then
                closing = true
                vim.schedule(function() dispatchers.on_exit(0, 15) end)
            end
        end,
    }
end

for _, name in ipairs({ 'fake', 'other' }) do
    vim.lsp.config(name, {
        cmd = fake_cmd,
        filetypes = { 'fakelang' },
        root_markers = { '.root' },
        settings = {
            fake = { base = 'yes', target = 'native', list = { 'a', 'b', 'c' } },
        },
    })
end
vim.lsp.enable({ 'fake', 'other' })

-- Workspace A (with a profiles file) and B (without)
local ws_a = vim.fs.joinpath(tmp, 'a')
local ws_b = vim.fs.joinpath(tmp, 'b')
local file_a = vim.fs.joinpath(ws_a, '.nvim', 'lsp-profiles.lua')
if phase == '1' then
    for _, dir in ipairs({ ws_a .. '/.nvim', ws_a .. '/src', ws_b }) do
        vim.fn.mkdir(dir, 'p')
    end
    vim.fn.writefile({}, ws_a .. '/.root')
    vim.fn.writefile({}, ws_b .. '/.root')
    vim.fn.writefile({
        'return {',
        '  web = {',
        '    fake = { settings = { fake = { target = "wasm", list = { "z" } } }, init_options = { web = true } },',
        '  },',
        '  other_only = { other = { settings = { fake = { target = "other" } } } },',
        '}',
    }, file_a)
    vim.secure.trust({ action = 'allow', path = file_a })
end

local function open(path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    vim.bo.filetype = 'fakelang'
    return vim.api.nvim_get_current_buf()
end

local function client_for(buf, name)
    local c
    wait(name .. ' to attach', function()
        c = vim.lsp.get_clients({ bufnr = buf, name = name })[1]
        return c ~= nil and c.initialized
    end)
    return c
end

--- Waits for `old` to be replaced by a new, initialized client
local function restarted(buf, name, old)
    local c
    wait(name .. ' to restart', function()
        c = vim.lsp.get_clients({ bufnr = buf, name = name })[1]
        return c ~= nil and c.id ~= old.id and c.initialized
    end)
    return c
end

local s = function(c) return c and c.settings.fake or {} end

if phase == '1' then
    check(vim.deep_equal(profiles._merge({ a = { b = 1, l = { 1, 2 } } }, { a = { c = 2, l = { 3 } } }),
        { a = { b = 1, c = 2, l = { 3 } } }), 'merge: dicts merge, lists replace')

    local buf_a = open(ws_a .. '/src/main.fake')
    local buf_b = open(ws_b .. '/main.fake')
    local a = client_for(buf_a, 'fake')
    local b = client_for(buf_b, 'fake')
    local a_other = client_for(buf_a, 'other')
    check(s(a).target == 'native' and s(b).target == 'native', 'no profile: base settings')
    check(profiles.workspace(buf_a) == ws_a, 'workspace of a buffer in A', profiles.workspace(buf_a))
    check(vim.deep_equal(profiles.list(ws_a), { 'other_only', 'web' }), 'list', profiles.list(ws_a))
    check(profiles.status(buf_a) == nil, 'status: none')

    -- none -> web
    vim.api.nvim_set_current_buf(buf_a)
    vim.cmd('LspProfile web')
    a = restarted(buf_a, 'fake', a)
    check(s(a).target == 'wasm' and s(a).base == 'yes', 'web: override merged over base', s(a))
    check(vim.deep_equal(s(a).list, { 'z' }), 'web: list replaced, not merged', s(a).list)
    check(inits[#inits].initializationOptions and inits[#inits].initializationOptions.web == true,
        'web: init_options sent in initialize')
    check(profiles.status(buf_a) == 'web', 'status: web')
    check(vim.lsp.get_client_by_id(a_other.id) ~= nil, 'server not in the profile kept running')
    check(vim.lsp.get_clients({ bufnr = buf_b, name = 'fake' })[1].id == b.id, 'other workspace untouched')
    check(s(vim.lsp.get_clients({ bufnr = buf_b, name = 'fake' })[1]).target == 'native', 'other workspace: base')
    check(#vim.lsp.get_clients({ name = 'fake' }) == 2, 'no duplicate clients')

    -- A new buffer in A reuses the web client
    local buf_a2 = open(ws_a .. '/src/lib.fake')
    check(client_for(buf_a2, 'fake').id == a.id, 'new buffer reuses the profiled client')

    -- :lsp restart keeps exactly one layer (base + web)
    vim.api.nvim_set_current_buf(buf_a)
    vim.cmd('lsp restart fake')
    a = restarted(buf_a, 'fake', a)
    check(s(a).target == 'wasm' and vim.deep_equal(s(a).list, { 'z' }), ':lsp restart keeps the profile', s(a))
    check(#vim.lsp.get_clients({ name = 'fake' }) == 2, 'no duplicate clients after :lsp restart')
    check(vim.lsp.get_clients({ bufnr = buf_a2, name = 'fake' })[1].id == a.id, 'all buffers reattached')

    -- web -> none removes the override
    vim.cmd('LspProfile none')
    a = restarted(buf_a, 'fake', a)
    check(s(a).target == 'native' and vim.deep_equal(s(a).list, { 'a', 'b', 'c' }), 'none: back to base', s(a))
    check(profiles.status(buf_a) == nil, 'status: none again')

    -- :lsp restart after switching back keeps base
    vim.cmd('lsp restart fake')
    a = restarted(buf_a, 'fake', a)
    check(s(a).target == 'native', ':lsp restart after none: base')

    -- Unknown profile
    check(profiles.set('nope', ws_a) == false, 'unknown profile refused')

    -- Editing the file while a profile is active restarts with the new values
    vim.cmd('LspProfile web')
    a = restarted(buf_a, 'fake', a)
    local edit_buf = vim.fn.bufadd(file_a)
    vim.fn.bufload(edit_buf)
    vim.api.nvim_buf_call(edit_buf, function()
        vim.cmd([[silent %s/"wasm"/"wasm64"/]])
        vim.cmd('silent write')
    end)
    a = restarted(buf_a, 'fake', a)
    check(s(a).target == 'wasm64', 'written profiles file applied', s(a))

    -- Leave "web" active for phase 2
    print('phase 1 done')
elseif phase == '2' then
    local buf_a = open(ws_a .. '/src/main.fake')
    local a = client_for(buf_a, 'fake')
    check(profiles.get(ws_a) == 'web', 'active profile remembered')
    check(s(a).target == 'wasm64', 'remembered profile applied at startup', s(a))
    check(profiles.status(buf_a) == 'web', 'status after restart of Neovim')

    -- Picker: items, and the preview of each profile
    local select_items, select_opts
    local orig_select = vim.ui.select
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts) select_items, select_opts = items, opts end
    profiles.pick()
    vim.ui.select = orig_select
    check(vim.deep_equal(select_items, { 'none', 'other_only', 'web' }), 'pick: items', select_items)
    local function preview(item)
        local buf = select_opts.preview_item(item).buf
        return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'), vim.bo[buf].filetype
    end
    local web, ft = preview('web')
    check(ft == 'lua', 'preview: lua buffer')
    check(web:find('-- web (active)', 1, true) and web:find('target = "wasm64"', 1, true)
        and web:find('fake = {', 1, true) and not web:find('restarts', 1, true), 'preview: active profile', web)
    local none = preview('none')
    check(none:find('restarts: fake', 1, true) and none:find('No overrides', 1, true), 'preview: none', none)
    local other = preview('other_only')
    check(other:find('restarts: fake', 1, true) and other:find('other = {', 1, true), 'preview: other profile', other)

    -- :LspProfile edit on a workspace without a file gives the template
    local buf_b = open(ws_b .. '/main.fake')
    client_for(buf_b, 'fake')
    vim.cmd('LspProfile edit')
    check(vim.api.nvim_buf_get_name(0) == vim.fs.joinpath(ws_b, '.nvim', 'lsp-profiles.lua'), 'edit opens B\'s file')
    check(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find('lsp-profiles', 1, true) ~= nil, 'edit: template')
    vim.cmd('silent write')
    check(vim.uv.fs_stat(ws_b .. '/.nvim/lsp-profiles.lua') ~= nil, 'edit: folder created on write')

    -- An untrusted (denied) profiles file: not loaded, one warning, base config
    local ws_c = vim.fs.joinpath(tmp, 'c')
    local file_c = vim.fs.joinpath(ws_c, '.nvim', 'lsp-profiles.lua')
    vim.fn.mkdir(ws_c .. '/.nvim', 'p')
    vim.fn.writefile({}, ws_c .. '/.root')
    vim.fn.writefile({ 'return { web = { fake = { settings = { fake = { target = "evil" } } } } }' }, file_c)
    vim.secure.trust({ action = 'deny', path = file_c })
    local warnings = 0
    local orig_notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, ...)
        if msg:find('not trusted', 1, true) then
            warnings = warnings + 1
        end
        return orig_notify(msg, ...)
    end
    local c = client_for(open(ws_c .. '/main.fake'), 'fake')
    check(s(c).target == 'native', 'untrusted file: base config')
    check(profiles.set('web', ws_c) == false, 'untrusted file: its profiles are unavailable')
    profiles.list(ws_c)
    open(ws_c .. '/other.fake')
    check(warnings == 1, 'untrusted file: warned once', warnings)
    vim.notify = orig_notify

    -- Trusted afterwards (:trust, file unchanged): set() reads it again
    vim.secure.trust({ action = 'allow', path = file_c })
    local buf_c = vim.api.nvim_get_current_buf()
    check(profiles.set('web', ws_c) == true, 'trusted later: set() works without changing the file')
    c = restarted(buf_c, 'fake', c)
    check(s(c).target == 'evil', 'trusted later: profile applied', s(c))

    -- Setting the profile that is already applied restarts nothing
    vim.api.nvim_set_current_buf(buf_a)
    local before = vim.lsp.get_clients({ bufnr = buf_a, name = 'fake' })[1]
    check(profiles.set('web') == true, 'set active profile again')
    vim.wait(300)
    check(vim.lsp.get_clients({ bufnr = buf_a, name = 'fake' })[1].id == before.id, 'already applied: no restart')
    print('phase 2 done')
end

print(failures == 0 and 'ALL PASSED' or (failures .. ' FAILED'))
vim.cmd(failures == 0 and 'qa!' or 'cq')
