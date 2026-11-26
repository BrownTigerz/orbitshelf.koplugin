-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.15 (TK): Colour Theme. The 8 colours OrbitShelf draws with on a colour screen
-- (the popups, the stats page and its rings, the Book Page): a preset, or Custom (a
-- preset with any of its colours changed). Look › Colour Theme. Vibrant by default,
-- which keeps every colour exactly as before. Grey screens stay grey.
local O = require("orbitshelf_core")
local _ = O._

local Theme = {}
O.Theme = Theme

-- the 8 colours by name, in the order the sheets cycle them
Theme.NAMES = { "blue", "green", "gold", "red", "purple", "teal", "pink", "orange" }
Theme.LABEL = { blue = _("Blue"), green = _("Green"), gold = _("Gold"), red = _("Red"), purple = _("Purple"),
    teal = _("Teal"), pink = _("Pink"), orange = _("Orange") }

local function set(b, g, y, r, p, t, k, o)
    return { blue = b, green = g, gold = y, red = r, purple = p, teal = t, pink = k, orange = o }
end

Theme.PRESETS = {
    { id = "vibrant", name = _("Vibrant"), c = set({ 45, 135, 255 }, { 30, 200, 110 }, { 255, 180, 0 }, { 255, 70, 70 },
        { 165, 95, 245 }, { 0, 195, 205 }, { 245, 85, 165 }, { 255, 125, 30 }) },
    { id = "pastel", name = _("Pastel"), c = set({ 140, 185, 255 }, { 140, 220, 175 }, { 255, 215, 130 }, { 255, 150, 150 },
        { 195, 165, 250 }, { 140, 215, 220 }, { 250, 165, 205 }, { 255, 185, 140 }) },
    { id = "ocean", name = _("Ocean"), c = set({ 30, 110, 200 }, { 0, 170, 150 }, { 80, 200, 220 }, { 60, 90, 170 },
        { 110, 120, 220 }, { 0, 150, 170 }, { 120, 190, 255 }, { 40, 160, 200 }) },
    { id = "sunset", name = _("Sunset"), c = set({ 200, 70, 150 }, { 250, 210, 90 }, { 255, 180, 60 }, { 240, 80, 100 },
        { 180, 60, 120 }, { 255, 150, 120 }, { 255, 100, 140 }, { 255, 120, 60 }) },
    { id = "forest", name = _("Forest"), c = set({ 70, 130, 120 }, { 60, 150, 90 }, { 200, 170, 80 }, { 190, 80, 60 },
        { 120, 100, 70 }, { 80, 170, 140 }, { 170, 120, 90 }, { 170, 120, 60 }) },
    { id = "mono", name = _("Kobo Mono"), c = set({ 40, 40, 40 }, { 90, 90, 90 }, { 130, 130, 130 }, { 60, 60, 60 },
        { 110, 110, 110 }, { 150, 150, 150 }, { 75, 75, 75 }, { 120, 120, 120 }) },
}

-- the colours a custom one is picked from
Theme.SWATCHES = {
    { 45, 135, 255 }, { 30, 110, 200 }, { 120, 190, 255 }, { 110, 120, 220 }, { 0, 195, 205 }, { 0, 150, 170 },
    { 30, 200, 110 }, { 60, 150, 90 }, { 140, 200, 70 }, { 200, 220, 90 }, { 255, 215, 130 }, { 255, 180, 0 },
    { 255, 125, 30 }, { 255, 150, 120 }, { 255, 70, 70 }, { 190, 60, 60 }, { 240, 80, 100 }, { 245, 85, 165 },
    { 250, 165, 205 }, { 165, 95, 245 }, { 120, 70, 200 }, { 195, 165, 250 }, { 150, 110, 70 }, { 110, 110, 110 },
}

local function cfg() return O.cfg or {} end

function Theme.preset(id)
    for _i, p in ipairs(Theme.PRESETS) do if p.id == id then return p end end
    return Theme.PRESETS[1]
end

-- "vibrant" (the default, unchanged look), a preset's id, or "custom"
function Theme.id() return cfg().colour_theme or "vibrant" end

-- name -> { r, g, b }
function Theme.colours()
    local id = Theme.id()
    if id ~= "custom" then return Theme.preset(id).c end
    local base = Theme.preset(cfg().theme_base or "vibrant").c
    local own = type(cfg().theme_custom) == "table" and cfg().theme_custom or {}
    local out = {}
    for _i, n in ipairs(Theme.NAMES) do
        local c = own[n]
        out[n] = (type(c) == "table" and tonumber(c[1]) and tonumber(c[2]) and tonumber(c[3])) and c or base[n]
    end
    return out
end

function Theme.rgb(name) return Theme.colours()[name] or Theme.colours().blue end

-- the stats page keeps its own (slightly softer) blue / green / gold / red with Vibrant
function Theme.isDefault() return Theme.id() == "vibrant" end

function Theme.name()
    if Theme.id() == "custom" then return _("Custom") end
    return Theme.preset(Theme.id()).name
end

-- ---- Screen flashes (2.1.17, TK: popups and page changes left ghosting) ------------------
-- How each kind of screen refreshes when it opens, changes or closes: "ui" (no flash),
-- "flashui" (a quick flash) or "full" (a full flash). Look › Screen Flashes.
Theme.FLASH_KINDS = { "popup", "bookpage", "bookpage_change", "stats", "stats_change" }
Theme.FLASH_DEFAULT = { popup = "flashui", bookpage = "full", bookpage_change = "flashui", stats = "full", stats_change = "full" }
function O.flash(kind)
    local v = cfg()["flash_" .. kind]
    if v ~= "ui" and v ~= "flashui" and v ~= "full" then v = Theme.FLASH_DEFAULT[kind] or "ui" end
    return v
end

-- ---- The Colour Theme sheet (Look › Colour Theme) ------------------------------------

local function save() if O.saveConfig then O.saveConfig() end end

local function redrawAll()
    -- what's open draws its colours again next time; the shelf's pages are cleared
    if O.clearPages then pcall(O.clearPages) end
end

function Theme.show()
    local widget
    local function spec()
        local rows = {}
        for _i, p in ipairs(Theme.PRESETS) do
            local list = {}
            for _j, n in ipairs(Theme.NAMES) do list[#list + 1] = p.c[n] end
            rows[#rows + 1] = { text = p.name, colours = list, on = Theme.id() == p.id, keep = true, callback = function()
                O.cfg.colour_theme = p.id
                save()
                redrawAll()
                widget:rebuild(spec())
            end }
        end
        local cur = Theme.colours()
        local custom = {}
        for _j, n in ipairs(Theme.NAMES) do
            custom[#custom + 1] = { rgb = cur[n], label = Theme.LABEL[n], keep = true, callback = function()
                Theme.pick(n, function() widget:rebuild(spec()) end)
            end }
        end
        return {
            title = _("Colour Theme"),
            subtitle = _("The popups, the stats page and its rings, and the Book Page. Grey screens stay grey."),
            sections = {
                { title = _("Presets"), colour = "blue", items = { { kind = "swatches", list = rows } } },
                { title = Theme.id() == "custom" and _("Custom (on)") or _("Custom"), colour = "pink", items = {
                    { kind = "tiles", list = custom },
                    { kind = "text", text = _("Tap a colour to change it: the theme becomes Custom, starting from the one above."), size = 11, dim = true },
                    { kind = "pills", list = {
                        { text = _("Reset To Vibrant"), colour = "red", keep = true, callback = function()
                            O.cfg.colour_theme, O.cfg.theme_custom, O.cfg.theme_base = "vibrant", nil, nil
                            save()
                            redrawAll()
                            widget:rebuild(spec())
                        end },
                    } },
                } },
            },
        }
    end
    widget = O.Sheet.show(spec())
end

-- one colour of Custom, from the swatches
function Theme.pick(name, done)
    local widget
    local list = {}
    for _i, c in ipairs(Theme.SWATCHES) do
        list[#list + 1] = { rgb = c, callback = function()
            local cfgt = O.cfg
            if Theme.id() ~= "custom" then
                cfgt.theme_base = Theme.id()
                cfgt.theme_custom = {}
            end
            cfgt.theme_custom = type(cfgt.theme_custom) == "table" and cfgt.theme_custom or {}
            cfgt.theme_custom[name] = { c[1], c[2], c[3] }
            cfgt.colour_theme = "custom"
            save()
            redrawAll()
            if done then done() end
        end }
    end
    widget = O.Sheet.show{ title = Theme.LABEL[name] or name, subtitle = _("Pick its new colour."),
        sections = { { colour = "pink", plain = true, items = { { kind = "tiles", list = list } } } } }
    return widget
end

return Theme
