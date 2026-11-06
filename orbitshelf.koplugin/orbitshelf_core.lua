-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local VERSION = "1.2.4"
local TAG = "orbitshelf " .. VERSION .. ":"
local SETTINGS_KEY = "orbitshelf_tweaks"
local MENU_ID = "orbitshelf_tweaks"
local SOURCE_ID = "bookorbit"

local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")

-- One table the plugin's files share.
local O = { plugin = true, VERSION = VERSION, TAG = TAG, SOURCE_ID = SOURCE_ID }
package.loaded["orbitshelf_core"] = O

-- The old patch (2-orbitshelf-tweaks.lua 1.6.1 or older) loads before plugins and sets
-- this; then it is the one running and the plugin stays off.
if package.loaded["orbitshelf_tweaks_patch"] then
    O.idle = true
    logger.warn(TAG, "the old patch patches/2-orbitshelf-tweaks.lua is still installed and running,"
        .. " so the plugin stays off. Delete that file and restart.")
end
package.loaded["orbitshelf_tweaks_patch"] = true

local DEFAULTS = {
    -- Everything is off on a new install, so Bookshelf stays as it is until you turn
    -- things on (the critter's four kinds stay on, they only matter with the critter)
    use_bookorbit = false,         -- register BookOrbit as a shelf source
    auto_rewrite_stock = false,    -- Series / Authors / Genres / Recent use BO data
    close_only_menu = false,       -- footer hamburger becomes a one-tap close X
    close_menu_side = "bottom",    -- "left" | "right" | "bottom" (= Bookshelf's own side)
    cache_ttl = 30 * 60,           -- soft refresh window (seconds)
    offline_ttl = 6 * 3600,        -- keep offline lists this long
    hero_pills = false,            -- Download / Remove / Open In BookOrbit on hero
    hero_sync = false,             -- Sync icon at the hero's bottom right
    hero_button_size = "small",    -- hero buttons and icons: "small" | "medium" | "large"
    footer_critter = false,        -- replace bottom page nav with a critter
    critter_say_page = true,       -- critter says which page / books you're on
    critter_say_witty = true,      -- witty remarks
    critter_say_recs = true,       -- picks from the books on this page
    critter_say_quotes = true,     -- shelf sayings (plus your own file)
    flash_hero = false,            -- flash the hero clean when it shows another book
    flash_shelf = false,           -- flash the shelf clean on every page turn
    offline_library = false,       -- keep every book's details and cover on the device
    diagnostics = false,           -- write what OrbitShelf does to crash.log
    offline_update = "wifi",       -- Offline Library checks for new books: "wifi" | "refresh" | "both" | "manual"
}

-- What the patch (up to 1.6.1) had on by default. Someone who used the patch but never
-- changed a setting has nothing saved; they keep what they had, not the new all-off.
local PATCH_DEFAULTS_ON = { "use_bookorbit", "auto_rewrite_stock", "hero_pills", "hero_sync", "footer_critter" }

local cfg = {}
for k, v in pairs(DEFAULTS) do cfg[k] = v end
local came_from_patch = false
do
    local saved = G_reader_settings and G_reader_settings:readSetting(SETTINGS_KEY)
    if saved == nil and G_reader_settings and (G_reader_settings:readSetting("orbitshelf_tweaks_pages_2") ~= nil
            or G_reader_settings:readSetting("orbitshelf_tweaks_pages") ~= nil
            or G_reader_settings:readSetting("orbitshelf_genres") ~= nil) then
        for _i, k in ipairs(PATCH_DEFAULTS_ON) do cfg[k] = true end
        came_from_patch = true
    end
    if type(saved) == "table" then
        for k, v in pairs(saved) do
            if DEFAULTS[k] ~= nil then cfg[k] = v end
        end
    end
end

local function saveConfig()
    if not G_reader_settings then return end
    -- every setting there is (1.5.8-1.5.11 left the two flash settings out, so they
    -- went back to off at every start)
    local out = {}
    for k in pairs(DEFAULTS) do out[k] = cfg[k] end
    G_reader_settings:saveSetting(SETTINGS_KEY, out)
    if G_reader_settings.flush then pcall(G_reader_settings.flush, G_reader_settings) end
end
-- kept from then on, so a later default can't change it
if came_from_patch then saveConfig() end


-- ---- Problems go to crash.log ------------------------------------------------------
-- Every problem is written once per start, with where it happened. When another patch
-- or plugin has changed a Bookshelf function OrbitShelf relies on, the line names that
-- file. Nothing shows on screen for these.
local seen_problem = {}

function O.problem(key, ...)
    if seen_problem[key] then return end
    seen_problem[key] = true
    logger.warn(TAG, ...)
end

-- the file a function was written in, shortened to patches/... or plugins/...
function O.fileOf(fn)
    if type(fn) ~= "function" then return "?" end
    local ok, info = pcall(debug.getinfo, fn, "S")
    local src = ok and type(info) == "table" and info.source or "?"
    src = tostring(src):gsub("^@", "")
    local short = src:match("(plugins/.+)$") or src:match("(patches/.+)$") or src:match("(frontend/.+)$")
    return short or src
end

-- OrbitShelf's own diagnostics (the plugin's, or the old patch) wraps on purpose
function O.isOwnDiag(file)
    return file:find("orbitshelf_diag", 1, true) or file:find("orbitshelf-tweaks-diagnostics", 1, true)
end

local function traceback(err)
    return tostring(err) .. "\n" .. debug.traceback("", 2)
end

local function pack(...) return { n = select("#", ...), ... } end

-- LuaJIT passes extra arguments through xpcall; plain Lua 5.1 does not
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, function() end, true)) == true

local function guardedCall(fn, ...)
    if XPCALL_ARGS then return pack(xpcall(fn, traceback, ...)) end
    local args = pack(...)
    return pack(xpcall(function() return fn(unpack(args, 1, args.n)) end, traceback))
end

-- ours runs; if it fails the error and traceback go to crash.log (once) and the
-- original runs instead (or, with no original, the error carries on as before)
function O.guard(label, ours, orig)
    return function(...)
        local res = guardedCall(ours, ...)
        if res[1] then return unpack(res, 2, res.n) end
        O.problem("err:" .. label, label .. " failed" .. (orig and ", using Bookshelf's own:" or ":"), res[2])
        if orig then return orig(...) end
        error(res[2], 0)
    end
end

-- Hooks into Bookshelf. remember() is called just before a function is replaced; arm()
-- then puts the guard around OrbitShelf's version and keeps watch on it.
local HOOK_LABELS = {
    onHold = "hero hold menu", _buildRightColumn = "hero buttons",
    _buildStartMenuIcon = "close X", _openStartMenu = "close X",
    _loadItems = "close-only menu", _activate = "close-only menu", open = "close-only menu",
    _startMenuPosition = "close control side", _buildPaginationFooter = "footer critter",
    _swapHeroInPlace = "hero flash", _pageTurnFlashDue = "shelf flash",
}
local remembered, armed = {}, {}

local function ownerName(owner)
    for name, mod in pairs(package.loaded) do
        if mod == owner and type(name) == "string" and name:find("bookshelf") then
            return (name:gsub("^lib/", ""))
        end
    end
    return "Bookshelf"
end

function O.remember(owner, name)
    if type(owner) ~= "table" then return end
    local orig = owner[name]
    if type(orig) ~= "function" then
        O.problem("missing:" .. name, (HOOK_LABELS[name] or name) .. " off: " .. ownerName(owner) .. "." .. name
            .. " not found (Bookshelf changed, or another patch removed it)")
        return
    end
    local file = O.fileOf(orig)
    -- OrbitShelf's own diagnostics wraps these too, on purpose
    if not file:find("bookshelf.koplugin", 1, true) and not O.isOwnDiag(file) then
        O.problem("pre:" .. name, ownerName(owner) .. "." .. name .. " (" .. (HOOK_LABELS[name] or name)
            .. ") was already changed by " .. file .. " before OrbitShelf loaded")
    end
    remembered[#remembered + 1] = { owner = owner, name = name, orig = orig }
end

function O.arm()
    for i = #remembered, 1, -1 do
        local r = remembered[i]
        local now = r.owner[r.name]
        if now ~= r.orig and type(now) == "function" then
            local label = HOOK_LABELS[r.name] or r.name
            local g = O.guard(label, now, r.orig)
            r.owner[r.name] = g
            armed[#armed + 1] = { owner = r.owner, name = r.name, fn = g, label = label }
        end
        table.remove(remembered, i)
    end
end

-- When the shelf opens (at most once a minute): a hook that is no longer OrbitShelf's
-- means another patch or plugin replaced or wrapped it after OrbitShelf loaded.
local last_check = 0
function O.checkHooks()
    O.arm()
    if os.time() - last_check < 60 then return end
    last_check = os.time()
    if O.spec then
        pcall(function()
            local S = require("lib/bookshelf_sources")
            local now = type(S.get) == "function" and S.get(O.SOURCE_ID) or nil
            if type(now) == "table" and now ~= O.spec then
                local file = O.fileOf(now.fetch or now.list)
                O.problem("spec:" .. file, "the BookOrbit shelf source was replaced by " .. file
                    .. "; BookOrbit shelves now come from that file")
            end
        end)
    end
    for _i, a in ipairs(armed) do
        local now = a.owner[a.name]
        local file = now ~= a.fn and O.fileOf(now) or nil
        if file and not O.isOwnDiag(file) then
            O.problem("post:" .. a.name .. file, ownerName(a.owner) .. "." .. a.name .. " (" .. a.label
                .. ") was changed after OrbitShelf by " .. file
                .. "; if " .. a.label .. " stopped working, that file is why")
        end
    end
end

-- what's installed, once at start
local function readVersion(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    return text:match('version%s*=%s*"([^"]+)"') or text:match("Version:?%s*v?([%d%.]+)")
end

-- Diagnostics: the file is run only while the switch is on
function O.startDiag(fresh)
    if fresh then os.remove(require("datastorage"):getDataDir() .. "/orbitshelf-plugin-diagnostics.state") end
    if O.diag then O.diag.restart() return end
    local path = (O.dir or "plugins/orbitshelf.koplugin") .. "/orbitshelf_diag.lua"
    local fn, err = loadfile(path)
    if not fn then O.problem("diag-load", "Diagnostics could not load " .. path .. ":", err) return end
    local ok, run_err = xpcall(fn, debug.traceback)
    if not ok then O.problem("diag-run", "Diagnostics failed to start:", run_err) end
end

function O.environment()
    pcall(function()
        local Device = require("device")
        local okV, Version = pcall(require, "version")
        local kor = okV and Version.getCurrentRevision and Version:getCurrentRevision() or "?"
        local model = Device.model or (Device.getDeviceModel and Device:getDeviceModel()) or "?"
        local function plug(dir) return readVersion("plugins/" .. dir .. "/_meta.lua") end
        logger.info(TAG, string.format("KOReader %s on %s; Bookshelf %s, BookOrbit %s, SimpleUI %s",
            tostring(kor), tostring(model),
            plug("bookshelf.koplugin") or (lfs.attributes("plugins/bookshelf.koplugin", "mode") and "?" or "not installed"),
            plug("bookorbit.koplugin") or (lfs.attributes("plugins/bookorbit.koplugin", "mode") and "?" or "not installed"),
            plug("simpleui.koplugin") or (lfs.attributes("plugins/simpleui.koplugin", "mode") and "?" or "not installed")))
        local data = require("datastorage"):getDataDir()
        local patches = {}
        if lfs.attributes(data .. "/patches", "mode") == "directory" then
            for name in lfs.dir(data .. "/patches") do
                if name:match("%.lua$") then patches[#patches + 1] = name end
            end
        end
        table.sort(patches)
        logger.info(TAG, "patches: " .. (#patches > 0 and table.concat(patches, ", ") or "none"))
        local off = G_reader_settings and G_reader_settings:readSetting("plugins_disabled") or {}
        local on_list, off_list, seen_ids = {}, {}, {}
        for _k, base in ipairs({ "plugins", data .. "/plugins" }) do
            if lfs.attributes(base, "mode") == "directory" then
                for name in lfs.dir(base) do
                    local id = name:match("^(.+)%.koplugin$")
                    if id and not seen_ids[id] then
                        seen_ids[id] = true
                        if off[id] then off_list[#off_list + 1] = id else on_list[#on_list + 1] = id end
                    end
                end
            end
        end
        table.sort(on_list); table.sort(off_list)
        logger.info(TAG, "plugins on: " .. table.concat(on_list, ", ")
            .. (#off_list > 0 and ("; off: " .. table.concat(off_list, ", ")) or ""))
    end)
end


-- shared with the other files
O.MENU_ID = MENU_ID
O.SOURCE_ID = SOURCE_ID
O.T = T
O.TAG = TAG
O.UIManager = UIManager
O._ = _
O.cfg = cfg
O.lfs = lfs
O.logger = logger
O.saveConfig = saveConfig
return O
