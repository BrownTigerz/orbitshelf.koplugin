-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.33 (TK, mockup m1): Settings as one window; 2.1.36 (TK, mockup m5): the groups on
-- the left, the picked group's options on the right, each option in its own box, the
-- window only as tall as it needs. The same rows as before (menuItems in orbitshelf_menu.lua):
-- switches as switches, a value at the right, › for a page of its own (‹ Back). It stays
-- open until ✕ or Back (or sleep); a tap outside does nothing. Swipe left / right for the
-- next / last page or group, hold an option or a group for what it does. Edges and the
-- picked group follow Look › Popup Style (Standard plain, Rainbow, Solid).
local O = require("orbitshelf_core")
local _, T, UIManager = O._, O.T, O.UIManager

local Settings = {}
O.Settings = Settings

local function W(name) return require("ui/widget/" .. name) end
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local C = Blitbuffer.Color8
local INK, SOFT, PALE, PAPER = Blitbuffer.COLOR_BLACK, C(0xAA), C(0xDD), Blitbuffer.COLOR_WHITE
local SUB = C(0x33)

local function px(v) return Screen:scaleBySize(v) end
local function text(s, size, bold, colour, max_w)
    return W("textwidget"):new{ text = s, face = Font:getFace("cfont", size), bold = bold, fgcolor = colour or INK,
        max_width = max_w }
end

-- the colours of the cards, one per group, in order
local HUES = { "teal", "blue", "orange", "green", "gold", "purple", "red", "pink", "blue", "green" }

-- ---- reading a row ---------------------------------------------------------------------

local function call(f, ...)
    if type(f) ~= "function" then return nil end
    local ok, r = pcall(f, ...)
    if not ok then O.logger.warn(O.TAG, "settings:", tostring(r)) return nil end
    return r
end

local function words(it)
    local t = it.text_func and call(it.text_func) or it.text
    return tostring(t or "")
end

-- "Look: Value" or "Name · value" -> the name, the value (only a row whose words change:
-- "Book Page: Reading Stats" is a name)
local split
local function nameValue(it)
    if not it.text_func then return words(it), nil end
    return split(words(it))
end
split = function(t)
    local a, b = t:match("^(.-):%s+(.+)$")
    if a and #a <= 30 and not a:match("^%d+%.") then return a, b end
    a, b = t:match("^(.-) · (.+)$")
    if a and #a <= 30 then return a, b end
    return t, nil
end

local function enabled(it)
    if it.enabled == false then return false end
    if it.enabled_func then return call(it.enabled_func) ~= false end
    return true
end

local function isSwitch(it) return it.checked_func ~= nil and not it.radio end
local function isOn(it) return it.checked_func ~= nil and call(it.checked_func) and true or false end
local function hasPage(it) return it.sub_item_table ~= nil or it.sub_item_table_func ~= nil end

local function pageOf(it)
    local sub = it.sub_item_table
    if sub == nil and it.sub_item_table_func then sub = call(it.sub_item_table_func) end
    return (type(sub) == "table" and #sub > 0) and sub or nil
end

-- a switch with settings of its own, on: what's picked there ("Quotes · Witty", "Badge")
local function summary(it)
    local sub = pageOf(it)
    if not sub then return nil end
    local picked = {}
    for i = 1, #sub do
        local s = sub[i]
        if type(s) == "table" and s.checked_func and call(s.checked_func) then picked[#picked + 1] = (nameValue(s)) end
    end
    if #picked == 0 or #picked > 4 then return nil end
    return table.concat(picked, " · ")
end

-- ---- the window ------------------------------------------------------------------------

function Settings.show(items_fn)
    items_fn = items_fn or O.menuItems
    if type(items_fn) ~= "function" or not O.Sheet then return false end
    local Sheet = O.Sheet
    local widget
    -- the pages: the groups first; a row with › puts its own page on top
    local stack = { { page = 1 } }
    local cards, notes
    local spec -- below

    local function refresh()
        if widget then widget:rebuild(spec()) end
    end
    -- what a row's callback gets in place of KOReader's menu
    local tm = { updateItems = function() refresh() end, closeMenu = function() end }
    function tm:onClose() return true end

    local function help(it)
        local h = it.help_text
        if type(h) ~= "string" or h == "" then return nil end
        return function()
            UIManager:show(W("infomessage"):new{ text = (nameValue(it)) .. "\n\n" .. h })
        end
    end

    -- a tap on the words: its page, or what it does
    local function open(it, hue)
        if not enabled(it) then return end
        local sub = pageOf(it)
        if sub then
            stack[#stack + 1] = { title = (nameValue(it)), items = sub, page = 1, hue = hue }
            return refresh()
        end
        if it.callback then call(it.callback, tm) end
        refresh()
    end
    -- a tap on the switch: on or off (a switch with settings: its box)
    local function flip(it)
        if not enabled(it) then return end
        if it.checkmark_callback then call(it.checkmark_callback, tm)
        elseif it.callback then call(it.callback, tm) end
        refresh()
    end

    -- the colour a group's things take, by Popup Style (2.1.35 / 2.1.36, TK): Standard plain,
    -- Rainbow the group's own, Solid the one colour
    -- 2.1.37 (TK): Look › Colour decides, not the edge: on, the group's colour (Solid's with
    -- Popup Style Solid) whatever the edge; off, plain
    local function styleHue(P, hue)
        if not (Sheet.colourOn and Sheet.colourOn(P)) then return nil end
        return Sheet.solid(P) or P.hue(hue)
    end

    -- one option, in its own box (2.1.36, mockup m5): [switch | dot] name ……… value ›
    local RH, RGAP = px(44), px(8)
    local function row(it, w, P, taps, hue)
        local on_ok = enabled(it)
        local name, value = nameValue(it)
        local switch, radio = isSwitch(it), it.radio and it.checked_func ~= nil
        local on = isOn(it)
        local page = hasPage(it) and (not switch or on or not it.checkmark_callback)
        if switch and on and hasPage(it) and not value then value = summary(it) end
        local rh = RH
        local lead = (switch and px(64)) or (radio and px(40)) or px(12)
        local tc = on_ok and INK or SOFT
        local vt = value and text(value, 11, false, on_ok and SUB or SOFT, math.floor(w * 0.42)) or nil
        local arrow = page and text("›", 16, true, on_ok and SUB or SOFT) or nil
        local right = (vt and (vt:getSize().w + px(10)) or 0) + (arrow and px(26) or px(10))
        local nt = text(name, 13, switch, tc, w - lead - right - px(8))
        local HG = W("horizontalgroup")
        local edge = styleHue(P, hue)
        local box = Sheet.canvas(lead, rh, function(bb, x, y)
            -- the option's box: drawn here, under both halves
            local bc = edge and edge.v or (P.colour and SOFT or INK)
            bb:paintBorder(x, y, w, rh, edge and px(2) or px(1), on_ok and bc or PALE, px(12))
            if switch then
                local sw, sh = px(46), px(26)
                local sx, sy = x + px(10), y + math.floor((rh - sh) / 2)
                local r = math.floor(sh / 2)
                if on then
                    Sheet.roundFill(bb, sx, sy, sw, sh, r, not on_ok and { v = SOFT }
                        or (P.colour and P.hue("green") or { v = INK }))
                else
                    Sheet.roundFill(bb, sx, sy, sw, sh, r, P.colour and P.track or { v = PALE })
                    if not P.colour then bb:paintBorder(sx, sy, sw, sh, px(1), on_ok and INK or SOFT, r) end
                end
                local k = sh - px(6)
                local kx = on and (sx + sw - k - px(3)) or (sx + px(3))
                -- the knob: white on the screen (night mode flips the page, so black there)
                Sheet.roundFill(bb, kx, sy + px(3), k, k, math.floor(k / 2), { v = P.night and INK or PAPER })
                if not on then bb:paintBorder(kx, sy + px(3), k, k, px(1), on_ok and SUB or SOFT, math.floor(k / 2)) end
            elseif radio then
                local d = px(20)
                local dx, dy = x + px(12), y + math.floor((rh - d) / 2)
                bb:paintBorder(dx, dy, d, d, px(2), on_ok and INK or SOFT, math.floor(d / 2))
                if on then
                    local i = px(5)
                    Sheet.roundFill(bb, dx + i, dy + i, d - 2 * i, d - 2 * i, math.floor((d - 2 * i) / 2),
                        on_ok and (edge or { v = INK }) or { v = SOFT })
                end
            end
        end)
        local rest_w = w - lead
        local rest = Sheet.canvas(rest_w, rh, function(bb, x, y)
            nt:paintTo(bb, x + px(4), y + math.floor((rh - nt:getSize().h) / 2))
            local rx = x + rest_w - (arrow and px(22) or px(6))
            if arrow then arrow:paintTo(bb, rx, y + math.floor((rh - arrow:getSize().h) / 2)) end
            if vt then vt:paintTo(bb, rx - px(8) - vt:getSize().w, y + math.floor((rh - vt:getSize().h) / 2)) end
        end)
        local hold = help(it)
        if switch then
            taps[#taps + 1] = { w = box, keep = true, enabled = on_ok, hold = hold, callback = function() flip(it) end }
        else
            taps[#taps + 1] = { w = box, keep = true, enabled = on_ok, hold = hold, callback = function() open(it, hue) end }
        end
        taps[#taps + 1] = { w = rest, keep = true, enabled = on_ok, hold = hold, callback = function() open(it, hue) end }
        return HG:new{ align = "center", box, rest }
    end

    -- ---- the groups (left) and the picked group's options (right) ----
    local sel = 1 -- the picked group
    local GH, GGAP = px(40), px(6)
    local function readGroups()
        local items = call(items_fn) or {}
        cards, notes = {}, {}
        for i = 1, #items do
            local it = items[i]
            if type(it) == "table" then
                local sub = type(it.sub_item_table) == "table" and it.sub_item_table or nil
                if sub then
                    local name, value = nameValue(it)
                    cards[#cards + 1] = { title = name, note = value, list = sub, hue = HUES[(#cards % #HUES) + 1],
                        help = it.help_text }
                else
                    notes[#notes + 1] = it
                end
            end
        end
        sel = math.max(1, math.min(sel, #cards))
    end
    -- how tall the body may be, and how many options fit on one page of the right side
    local function budget()
        local avail = Screen:getHeight() - px(20) - px(22) - px(16) - px(96) - px(24)
        local head, navh = px(34), px(50)
        local per = math.max(3, math.floor((avail - head - navh + RGAP) / (RH + RGAP)))
        return avail, per, head, navh
    end
    -- the body's height: the taller of the group list and the longest group (one page);
    -- the same for every group, so the window doesn't jump; never the whole screen
    local function bodyHeight()
        local avail, per, head, navh = budget()
        local left = #cards * (GH + GGAP)
        local right = 0
        for c = 1, #cards do
            local n = #cards[c].list + ((c == 1) and #notes or 0)
            local k = math.min(n, per)
            local h = head + k * (RH + RGAP) + (n > per and navh or 0)
            if h > right then right = h end
        end
        return math.min(avail, math.max(left, right))
    end

    local function slice(list, from, to)
        local out = {}
        for i = from, to do out[#out + 1] = list[i] end
        return out
    end

    local function nav(page, n, go, w)
        local lt = text("‹", 22, true, page > 1 and INK or SOFT)
        local rt = text("›", 22, true, page < n and INK or SOFT)
        local mid = text(T(_("%1 / %2"), page, n), 13, true, SUB)
        local h, bw = px(44), px(56)
        local HG, HS = W("horizontalgroup"), W("horizontalspan")
        local lb = Sheet.canvas(bw, h, function(bb, x, y)
            lt:paintTo(bb, x + math.floor((bw - lt:getSize().w) / 2), y + math.floor((h - lt:getSize().h) / 2))
        end)
        local rb = Sheet.canvas(bw, h, function(bb, x, y)
            rt:paintTo(bb, x + math.floor((bw - rt:getSize().w) / 2), y + math.floor((h - rt:getSize().h) / 2))
        end)
        local mw = mid:getSize().w + px(16)
        local mc = Sheet.canvas(mw, h, function(bb, x, y)
            mid:paintTo(bb, x + px(8), y + math.floor((h - mid:getSize().h) / 2))
        end)
        return HG:new{ align = "center", HS:new{ width = math.max(0, math.floor((w - 2 * bw - mw) / 2)) }, lb, mc, rb },
            { { w = lb, keep = true, enabled = page > 1, callback = function() go(page - 1) end },
              { w = rb, keep = true, enabled = page < n, callback = function() go(page + 1) end } }
    end

    local function pickGroup(c)
        sel = c
        stack = { { page = 1 } }
        refresh()
    end

    local function body()
        return { kind = "custom", build = function(w, P, taps)
            local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
            local bh = bodyHeight()
            local left_w = math.floor(w * 0.3)
            local gap = px(12)
            local right_w = w - left_w - 2 * gap - px(2)
            -- left: the groups
            local lg = VG:new{ align = "left" }
            for c = 1, #cards do
                local card = cards[c]
                local on = c == sel
                local hue = styleHue(P, card.hue)
                local t = text(card.title, 12, on, on and (hue and P.on or PAPER) or INK, left_w - px(40))
                local g = Sheet.canvas(left_w, GH, function(bb, x, y)
                    local r = px(12)
                    if on then
                        Sheet.roundFill(bb, x, y, left_w, GH, r, hue or { v = INK })
                        t:paintTo(bb, x + px(14), y + math.floor((GH - t:getSize().h) / 2))
                    else
                        bb:paintBorder(x, y, left_w, GH, px(1), P.colour and SOFT or INK, r)
                        Sheet.roundFill(bb, x + px(12), y + math.floor(GH / 2) - px(4), px(8), px(8), px(4), hue or { v = INK })
                        t:paintTo(bb, x + px(28), y + math.floor((GH - t:getSize().h) / 2))
                    end
                end)
                local hold = card.help and function()
                    UIManager:show(W("infomessage"):new{ text = card.title .. "\n\n" .. card.help })
                end or nil
                taps[#taps + 1] = { w = g, keep = true, hold = hold, callback = function() pickGroup(c) end }
                if c > 1 then lg[#lg + 1] = VS:new{ width = GGAP } end
                lg[#lg + 1] = g
            end
            -- right: the picked group (or a page of its own), in pages
            local card = cards[sel]
            local top = stack[#stack]
            local per, head = select(2, budget())
            local list, title, hue
            if #stack > 1 then
                list, title, hue = top.items, top.title, top.hue or (card and card.hue)
            else
                list = {}
                if sel == 1 then for i = 1, #notes do list[#list + 1] = notes[i] end end
                for i = 1, #(card and card.list or {}) do list[#list + 1] = card.list[i] end
                title, hue = card and card.title or "", card and card.hue
            end
            local n = math.max(1, math.ceil(#list / per))
            top.page = math.max(1, math.min(top.page or 1, n))
            local rg = VG:new{ align = "left" }
            -- the heading: ‹ Back on a page of its own, the name, a dash in the group's colour
            local hh = head - px(6)
            local lab = text(string.upper(title), 11, true, SUB, right_w - px(140))
            local back_t = #stack > 1 and text("‹ " .. _("Back"), 13, true, INK) or nil
            local back_w = back_t and (back_t:getSize().w + px(24)) or 0
            local dash = styleHue(P, hue)
            local headc = Sheet.canvas(right_w, hh, function(bb, x, y)
                local lx = x
                if back_t then
                    bb:paintBorder(x, y, back_w, hh, px(1), dash and dash.v or (P.colour and SOFT or INK), math.floor(hh / 2))
                    back_t:paintTo(bb, x + px(12), y + math.floor((hh - back_t:getSize().h) / 2))
                    lx = x + back_w + px(12)
                end
                lab:paintTo(bb, lx, y + math.floor((hh - lab:getSize().h) / 2))
                if dash then
                    Sheet.roundFill(bb, lx + lab:getSize().w + px(10), y + math.floor(hh / 2) - px(3), px(22), px(6), px(3), dash)
                end
            end)
            if back_t then
                taps[#taps + 1] = { w = headc, keep = true, callback = function()
                    stack[#stack] = nil
                    refresh()
                end }
            end
            rg[#rg + 1] = headc
            rg[#rg + 1] = VS:new{ width = px(6) }
            local shown = slice(list, (top.page - 1) * per + 1, math.min(#list, top.page * per))
            for i = 1, #shown do
                if i > 1 then rg[#rg + 1] = VS:new{ width = RGAP } end
                rg[#rg + 1] = row(shown[i], right_w, P, taps, hue or "blue")
            end
            local navw, navtaps
            if n > 1 then
                navw, navtaps = nav(top.page, n, function(p) top.page = p refresh() end, right_w)
            end
            local rc = Sheet.canvas(right_w, bh, function(bb, x, y)
                rg:paintTo(bb, x, y)
                if navw then navw:paintTo(bb, x, y + bh - navw:getSize().h) end
            end)
            if navtaps then for i = 1, #navtaps do taps[#taps + 1] = navtaps[i] end end
            local lc = Sheet.canvas(left_w, bh, function(bb, x, y) lg:paintTo(bb, x, y) end)
            local div = Sheet.canvas(px(2), bh, function(bb, x, y)
                Sheet.roundFill(bb, x, y, px(2), bh, px(1), { v = P.colour and PALE or SOFT })
            end)
            return HG:new{ align = "top", lc, HS:new{ width = gap }, div, HS:new{ width = gap }, rc }
        end }
    end

    local function content()
        readGroups()
        local path = {}
        for i = 2, #stack do path[#path + 1] = stack[i].title end
        local subtitle = T(_("Settings · %1"), O.VERSION or "")
        if #path > 0 then subtitle = _("Settings") .. " › " .. (cards[sel] and cards[sel].title or "") .. " › " .. table.concat(path, " › ") end
        return { title = _("OrbitShelf"), subtitle = subtitle, sections = { { plain = true, items = { body() } } } }
    end

    spec = function()
        local s = content()
        -- 2.1.36 (TK): compact, as tall as its content (the same for every group)
        s.cancel, s.modal, s.full = false, true, false
        -- swipe left: the next page (or group); right: the last page, back out of a page, or the last group
        s.on_swipe = function(dir)
            local top = stack[#stack]
            local per = select(2, budget())
            local n = 1
            if #stack > 1 then n = math.ceil(#top.items / per)
            elseif cards[sel] then n = math.ceil((#cards[sel].list + (sel == 1 and #notes or 0)) / per) end
            if dir == "west" then
                if (top.page or 1) < n then top.page = (top.page or 1) + 1
                elseif #stack == 1 and sel < #cards then sel = sel + 1 top.page = 1 end
                refresh()
                return true
            elseif dir == "east" then
                if (top.page or 1) > 1 then top.page = top.page - 1
                elseif #stack > 1 then stack[#stack] = nil
                elseif sel > 1 then sel = sel - 1 top.page = 1 end
                refresh()
                return true
            end
            return dir == "south" or dir == "north"
        end
        s.on_back = function()
            if #stack > 1 then
                stack[#stack] = nil
                refresh()
                return true
            end
            return false
        end
        s.on_close = function() Settings.current = nil end
        return s
    end
    widget = Sheet.new(spec())
    Settings.current = widget
    UIManager:show(widget)
    return true
end

-- sleep closes it, like the Book Page
function Settings.closeOnSleep()
    if Settings.current then
        local w = Settings.current
        Settings.current = nil
        pcall(function() UIManager:close(w) end)
    end
end

return Settings
