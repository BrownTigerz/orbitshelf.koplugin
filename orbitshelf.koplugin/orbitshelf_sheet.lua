-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.12: the sheet. OrbitShelf's popups (a book's popup, Manage Downloads, Reading
-- Status, collections, the queue, Select, the shelf pickers) rise from the bottom as one
-- rounded sheet: a title, a line of colour under it, and rounded sections, each with a
-- coloured tag, words, chips, bars, pill buttons (filled for the main thing, outlined
-- for the rest) and list rows. Colours on a colour screen (pre-flipped in night mode,
-- dithered refresh), greys otherwise. A tap outside it, a swipe down, ✕ or Back closes it.
--
--   Sheet.new{ title, subtitle, sections = { { title, colour, tint, items = {...} } },
--              cancel = true, on_close = fn }  -> a widget for UIManager:show / :close
--   items: { kind = "text", text, size, bold, dim }
--          { kind = "chip", text, colour, after }        a coloured label and a note
--          { kind = "bar", frac, colour }
--          { kind = "pills", list = { { text, callback, colour, fill, enabled, keep } } }
--          { kind = "list", list = { { text, callback, colour, enabled, note, keep } } }
--          { kind = "action", list = { { text, sub, button, callback, colour, enabled, keep } } }  (2.1.14)
--          { kind = "quote", list = { { page, text, note, hint, colour, max_chars, callback } } }    (2.1.14)
--          { kind = "counts", list = { { n, text, colour, callback } } }         (2.1.23) number tiles
--          { kind = "trio", list = { { label, value, note } } }                  (2.1.23) up to 3 big values
--          { kind = "columns", values, labels, now, colour, caption }           (2.1.23) bars, after `now` not yet
--   2.1.33: spec.modal (outside taps and a swipe down don't close it), spec.full (full
--   height), spec.on_swipe(dir) / spec.on_back() (true: handled), a tap's hold = fn.
--   Sheet.dialog{ title, buttons } builds one from ButtonDialog-style rows.
--   2.1.23 (TK): Look › Popup Style: Rainbow (a rainbow edge and grab bar, the colour line
--   under the title) or Standard (a plain edge, no colour line). Sheet.rainbow() says which.
local O = require("orbitshelf_core")
local _, UIManager = O._, O.UIManager

local Sheet = {}
O.Sheet = Sheet

local function W(name) return require("ui/widget/" .. name) end
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local C = Blitbuffer.Color8
local INK, SOFT, PALE, PAPER = Blitbuffer.COLOR_BLACK, C(0xAA), C(0xDD), Blitbuffer.COLOR_WHITE
-- 2.1.20 (TK: grey text is hard to read, night mode most of all): small text near black
local SUB = C(0x33)

local function px(v) return Screen:scaleBySize(v) end
local function text(s, size, bold, color, max_w)
    return W("textwidget"):new{ text = s, face = Font:getFace("cfont", size), bold = bold, fgcolor = color or INK, max_width = max_w }
end

-- ---- Colours -------------------------------------------------------------------------------

-- as seen on the page (night mode: the dark page), flipped first in night mode
local HUES = {
    blue = { 45, 135, 255 }, green = { 30, 200, 110 }, gold = { 255, 180, 0 }, red = { 255, 70, 70 },
    purple = { 165, 95, 245 }, teal = { 0, 195, 205 }, pink = { 245, 85, 165 }, orange = { 255, 125, 30 },
}
Sheet.CYCLE = { "blue", "green", "gold", "red", "purple", "teal", "pink", "orange" }

local function palette()
    local colour = Screen.isColorEnabled and Screen:isColorEnabled() and Blitbuffer.ColorRGB32 ~= nil
    local night = Screen.night_mode == true
    local P = { colour = colour, night = night }
    local function rgb(r, g, b)
        if night then r, g, b = 255 - r, 255 - g, 255 - b end
        return { v = Blitbuffer.ColorRGB32(r, g, b, 0xFF), rgb = true }
    end
    local base = night and { 26, 28, 38 } or { 240, 243, 249 }
    -- 2.1.15: the Colour Theme's (Vibrant = these HUES)
    local T = O.Theme and O.Theme.colours and O.Theme.colours() or HUES
    local function hueOf(name) return T[name] or HUES[name] or T.blue or HUES.blue end
    function P.hue(name)
        if not colour then return { v = INK } end
        local h = hueOf(name)
        return rgb(h[1], h[2], h[3])
    end
    -- any { r, g, b } (the theme's swatches); grey on a grey screen
    function P.rgbOf(c)
        if not colour then
            local l = math.floor(0.3 * c[1] + 0.59 * c[2] + 0.11 * c[3])
            return { v = C(l) }
        end
        return rgb(c[1], c[2], c[3])
    end
    -- a section's background: the base tinted a little with its colour
    function P.tint(name, k)
        if not colour then return { v = C(0xEE) } end
        local h = hueOf(name)
        k = k or (night and 0.16 or 0.12)
        return rgb(math.floor(base[1] + (h[1] - base[1]) * k), math.floor(base[2] + (h[2] - base[2]) * k),
            math.floor(base[3] + (h[3] - base[3]) * k))
    end
    P.paper = { v = PAPER }
    P.ink = { v = INK }
    P.track = colour and (night and rgb(60, 64, 78) or rgb(215, 220, 230)) or { v = PALE }
    -- 2.1.22 (TK): words on a colour: black on the screen (night mode flips the page, so white there)
    P.on = night and PAPER or INK
    return P
end
Sheet.palette = palette

local function fill(bb, x, y, w, h, k)
    if w <= 0 or h <= 0 then return end
    if k.rgb and bb.paintRectRGB32 then bb:paintRectRGB32(x, y, w, h, k.v) else bb:paintRect(x, y, w, h, k.v) end
end

local function roundFill(bb, x, y, w, h, r, k)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    for dy = 0, r - 1 do
        local inset = r - math.floor(math.sqrt(r * r - (r - dy - 0.5) ^ 2) + 0.5)
        fill(bb, x + inset, y + dy, w - 2 * inset, 1, k)
        fill(bb, x + inset, y + h - 1 - dy, w - 2 * inset, 1, k)
    end
    fill(bb, x, y + r, w, h - 2 * r, k)
end
Sheet.roundFill, Sheet.fill = roundFill, fill

local Canvas = W("widget"):extend{ width = 0, height = 0 }
function Canvas:getSize() return Geom:new{ w = self.width, h = self.height } end
function Canvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.draw(bb, x, y, self.width, self.height)
end
local function canvas(w, h, draw) return Canvas:new{ width = w, height = h, draw = draw } end
Sheet.canvas = canvas

-- 2.1.23 (TK): Popup Style. "rainbow", "solid" (2.1.34: one colour you pick) or
-- "standard" (the default: new looks stay off). Colour styles only on a colour screen.
function Sheet.style(P)
    local s = O.cfg and O.cfg.popup_style
    if (P ~= nil and not P.colour) or (s ~= "rainbow" and s ~= "solid") then return "standard" end
    return s
end
-- true: edges and outlines in colour (Rainbow or Solid)
function Sheet.rainbow(P) return Sheet.style(P) ~= "standard" end
-- 2.1.34 (TK): Solid's colour ({ v, rgb }), or nil. Edges, colour lines and pills all take it.
function Sheet.solid(P)
    if Sheet.style(P) ~= "solid" then return nil end
    return palette().hue(O.cfg.popup_colour or "blue")
end
-- 2.1.36 (TK): Look › Pill Colours; 2.1.37 (TK): renamed Colour, and it covers more. Off (the
-- default, "standard"): pills plain, black (white at night) with the words in white; the
-- popups' sections outlined, not filled; the settings window plain. On: all of those in
-- colour (each its own, or Solid's with Popup Style Solid), whatever the edge. The edge stays
-- Popup Style's; charts and rings keep their colours either way (they're the data).
function Sheet.pillsColoured(P)
    return (P == nil or P.colour) and O.cfg ~= nil and O.cfg.pill_colours == true or false
end
-- a pill's fill: { v } (ink when Pill Colours is off)
function Sheet.pillHue(P, name)
    if not Sheet.pillsColoured(P) then return { v = INK } end
    return Sheet.solid(P) or palette().hue(name or "blue")
end
-- the words on a filled pill
Sheet.colourOn = function(P) return Sheet.pillsColoured(P) end
function Sheet.pillOn(P)
    if not Sheet.pillsColoured(P) then return PAPER end
    return palette().on
end
-- a rainbow part's colour: the 8 in turn, or Solid's
function Sheet.cycleHue(P, name) return Sheet.solid(P) or palette().hue(name) end

-- an edge in the 8 colours, clockwise from the top left (Rainbow), or a plain one
function Sheet.edge(bb, x, y, w, h, t, r, P)
    if not Sheet.rainbow(P) then bb:paintBorder(x, y, w, h, t, INK, r) return end
    local solid = Sheet.solid(P)
    if solid then bb:paintBorder(x, y, w, h, t, solid.v, r) return end
    local n = #Sheet.CYCLE
    bb:paintBorder(x, y, w, h, t, P.hue(Sheet.CYCLE[1]).v, r)
    -- the straight runs between the corners, two colours to a side
    local runs = {
        { x + r, y, w - 2 * r, t, true }, { x + w - t, y + r, t, h - 2 * r, false },
        { x + r, y + h - t, w - 2 * r, t, true }, { x, y + r, t, h - 2 * r, false },
    }
    local k = 0
    for side, rn in ipairs(runs) do
        for half = 0, 1 do
            k = k + 1
            local hue = P.hue(Sheet.CYCLE[(k - 1) % n + 1])
            local rev = side == 3 or side == 4 -- bottom and left run back towards the start
            local hh = rev and (1 - half) or half
            if rn[5] then
                local seg = math.floor(rn[3] / 2)
                fill(bb, rn[1] + hh * seg, rn[2], hh == 1 and (rn[3] - seg) or seg, rn[4], hue)
            else
                local seg = math.floor(rn[4] / 2)
                fill(bb, rn[1], rn[2] + hh * seg, rn[3], hh == 1 and (rn[4] - seg) or seg, hue)
            end
        end
    end
end

-- ---- The sheet ------------------------------------------------------------------------------

local SheetWidget = W("container/inputcontainer"):extend{}
local build -- below

function SheetWidget:paintTo(bb, _x, _y)
    if self[1] then self[1]:paintTo(bb, self.region.x, self.region.y) end
end

-- 2.1.17 (TK): a quick flash when a popup opens and closes (Look › Screen Flashes)
local function flashMode() return O.flash and O.flash("popup") or "ui" end

function SheetWidget:onShow()
    local P = self.P
    local mode = flashMode()
    UIManager:setDirty(self, function() return mode, self.region, P.colour or nil end)
    return true
end

function SheetWidget:onCloseWidget()
    local r = self.region
    local mode = flashMode()
    UIManager:setDirty(nil, function() return mode, r end)
    if self.on_close then pcall(self.on_close) end
end

function SheetWidget:hit(pos)
    for _i, t in ipairs(self.taps) do
        local dm = t.w.dimen
        if dm and pos.x >= dm.x and pos.x < dm.x + dm.w and pos.y >= dm.y and pos.y < dm.y + dm.h then return t end
    end
end

function SheetWidget:onSheetTap(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    local r = self.region
    if pos.x < r.x or pos.x >= r.x + r.w or pos.y < r.y then
        -- 2.1.33: a window (Settings) stays open until ✕ or Back
        if not (self.spec and self.spec.modal) then UIManager:close(self) end
        return true
    end
    local t = self:hit(pos)
    if t and t.enabled ~= false and t.callback then
        if not t.keep then UIManager:close(self) end
        t.callback()
    end
    return true
end

function SheetWidget:onSheetSwipe(_arg, ges)
    local spec = self.spec or {}
    -- 2.1.33: a window's own swipes (Settings' pages)
    if ges and spec.on_swipe and spec.on_swipe(ges.direction) then return true end
    if ges and ges.direction == "south" and not spec.modal then UIManager:close(self) return true end
    return true
end

-- 2.1.33: hold a row for what it does (Settings)
function SheetWidget:onSheetHold(_arg, ges)
    local pos = ges and ges.pos
    local t = pos and self:hit(pos)
    if t and t.hold then t.hold() end
    return true
end

-- new content in the same sheet (a list's next page)
function SheetWidget:rebuild(spec)
    build(self, spec)
    local r = self.redraw_region or self.region
    UIManager:setDirty("all", function() return "ui", r, self.P.colour or nil end)
end

function SheetWidget:onClose()
    -- 2.1.33: Back in a window goes back a page first
    if self.spec and self.spec.on_back and self.spec.on_back() then return true end
    UIManager:close(self)
    return true
end

-- the rows a section draws, each a widget; taps collected in taps
local function sectionBody(sec, w, P, taps)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g = VG:new{ align = "left" }
    for idx, it in ipairs(sec.items or {}) do
        if idx > 1 then g[#g + 1] = VS:new{ width = px(6) } end
        if it.kind == "text" then
            g[#g + 1] = W("textboxwidget"):new{ text = it.text or "", face = Font:getFace("cfont", it.size or 13),
                bold = it.bold, width = w, fgcolor = it.dim and SUB or INK }
        elseif it.kind == "chip" then
            local t = text(it.text or "", 10, true, INK)
            local cw, ch = t:getSize().w + px(18), t:getSize().h + px(6)
            local after = it.after and text(it.after, 11, false, SUB) or nil
            g[#g + 1] = canvas(w, ch, function(bb, x, y)
                roundFill(bb, x, y, cw, ch, math.floor(ch / 2), Sheet.pillHue(P, it.colour or "green")) -- 2.1.36
                local tc = Sheet.pillOn(P)
                local tt = text(it.text or "", 10, true, tc)
                tt:paintTo(bb, x + px(9), y + px(3))
                if after then after:paintTo(bb, x + cw + px(10), y + math.floor((ch - after:getSize().h) / 2)) end
            end)
        elseif it.kind == "bar" then
            g[#g + 1] = canvas(w, px(10), function(bb, x, y)
                roundFill(bb, x, y, w, px(10), px(5), P.track)
                local f = math.max(0, math.min(1, tonumber(it.frac) or 0))
                if f > 0 then roundFill(bb, x, y, math.max(px(10), math.floor(w * f)), px(10), px(5), P.hue(it.colour or sec.colour)) end
            end)
        elseif it.kind == "pills" then
            -- pill buttons, wrapped onto lines as needed
            local line = HG:new{ align = "center" }
            local used = 0
            local lines = {}
            for _j, b in ipairs(it.list or {}) do
                local f = b.fill
                local enabled = b.enabled ~= false
                local t = text(b.text or "", 14, true, (f and enabled) and Sheet.pillOn(P) or (enabled and INK or SOFT))
                local pw = math.min(w, t:getSize().w + px(30))
                local ph = px(36)
                local solid = Sheet.pillsColoured(P) and Sheet.solid(P) or nil
                local col = Sheet.pillHue(P, b.colour or sec.colour or "blue") -- 2.1.36: Pill Colours
                local pc = canvas(pw, ph, function(bb, x, y)
                    if f and enabled then
                        roundFill(bb, x, y, pw, ph, math.floor(ph / 2), col)
                    else
                        -- 2.1.34: Solid edges the outlined ones in its colour too
                        bb:paintBorder(x, y, pw, ph, px(2), enabled and (solid and solid.v or INK) or SOFT, math.floor(ph / 2))
                    end
                    t:paintTo(bb, x + math.floor((pw - t:getSize().w) / 2), y + math.floor((ph - t:getSize().h) / 2))
                end)
                taps[#taps + 1] = { w = pc, callback = b.callback, enabled = enabled, keep = b.keep }
                if used > 0 and used + px(10) + pw > w then
                    lines[#lines + 1] = line
                    line, used = HG:new{ align = "center" }, 0
                end
                if used > 0 then line[#line + 1] = HS:new{ width = px(10) } used = used + px(10) end
                line[#line + 1] = pc
                used = used + pw
            end
            if used > 0 then lines[#lines + 1] = line end
            for k, l in ipairs(lines) do
                if k > 1 then g[#g + 1] = VS:new{ width = px(8) } end
                g[#g + 1] = l
            end
        elseif it.kind == "list" then
            -- full-width rows: a coloured dot, the words, a note at the right, ›
            for j, b in ipairs(it.list or {}) do
                if j > 1 then g[#g + 1] = VS:new{ width = px(6) } end
                local enabled = b.enabled ~= false
                local note = b.note and text(b.note, 11, false, SUB) or nil
                local room = w - px(56) - (note and (note:getSize().w + px(10)) or 0)
                local t = text(b.text or "", 14, b.bold, enabled and INK or SOFT, room)
                local rh = math.max(px(40), t:getSize().h + px(14))
                local hue = b.colour or Sheet.CYCLE[(j - 1) % #Sheet.CYCLE + 1]
                local rc = canvas(w, rh, function(bb, x, y)
                    -- 2.1.37: Colour off: outlined, a plain dot
                    local col = Sheet.colourOn(P)
                    roundFill(bb, x, y, w, rh, px(12), col and P.tint(hue, P.night and 0.22 or 0.2) or { v = PAPER })
                    if not col then bb:paintBorder(x, y, w, rh, px(1), enabled and (P.colour and SOFT or INK) or SOFT, px(12)) end
                    roundFill(bb, x + px(12), y + math.floor(rh / 2) - px(5), px(10), px(10), px(5),
                        enabled and (col and P.hue(hue) or { v = INK }) or { v = SOFT })
                    t:paintTo(bb, x + px(32), y + math.floor((rh - t:getSize().h) / 2))
                    if note then note:paintTo(bb, x + w - px(28) - note:getSize().w, y + math.floor((rh - note:getSize().h) / 2)) end
                    if b.arrow ~= false then
                        local ch = text("›", 16, true, enabled and SUB or SOFT)
                        ch:paintTo(bb, x + w - px(18), y + math.floor((rh - ch:getSize().h) / 2))
                    end
                end)
                taps[#taps + 1] = { w = rc, callback = b.callback, enabled = enabled, keep = b.keep }
                g[#g + 1] = rc
            end
        elseif it.kind == "swatches" then
            -- 2.1.15: a choice with its colours (Colour Theme's presets): ● name, then the swatches
            for j, b in ipairs(it.list or {}) do
                if j > 1 then g[#g + 1] = VS:new{ width = px(6) } end
                local t = text((b.on and "● " or "○ ") .. (b.text or ""), 14, true, INK)
                local rh = math.max(px(40), t:getSize().h + px(14))
                local n = #(b.colours or {})
                local sz = px(18)
                local rc = canvas(w, rh, function(bb, x, y)
                    roundFill(bb, x, y, w, rh, px(12), P.colour and P.tint(b.on and "gold" or "blue", b.on and 0.22 or 0.1) or { v = PAPER })
                    bb:paintBorder(x, y, w, rh, px(b.on and 2 or 1), b.on and INK or PALE, px(12))
                    t:paintTo(bb, x + px(12), y + math.floor((rh - t:getSize().h) / 2))
                    local sx = x + w - px(10) - n * (sz + px(4))
                    for k2, c in ipairs(b.colours or {}) do
                        roundFill(bb, sx + (k2 - 1) * (sz + px(4)), y + math.floor((rh - sz) / 2), sz, sz, px(4), P.rgbOf(c))
                    end
                end)
                taps[#taps + 1] = { w = rc, callback = b.callback, enabled = true, keep = b.keep }
                g[#g + 1] = rc
            end
        elseif it.kind == "tiles" then
            -- 2.1.15: colour tiles in rows (Custom's 8, the picker's swatches), a label under each
            local per = #(it.list or {}) <= 8 and 8 or 6
            local tw = math.floor((w - (per - 1) * px(8)) / per)
            local th = math.min(tw, px(46))
            local line, used = nil, 0
            for j, b in ipairs(it.list or {}) do
                if (j - 1) % per == 0 then
                    if line then g[#g + 1] = line g[#g + 1] = VS:new{ width = px(8) } end
                    line, used = HG:new{ align = "top" }, 0
                end
                local lab = b.label and text(b.label, 9, false, SUB, tw) or nil
                local hh = th + (lab and (lab:getSize().h + px(2)) or 0)
                local tc = canvas(tw, hh, function(bb, x, y)
                    roundFill(bb, x, y, tw, th, px(8), P.rgbOf(b.rgb))
                    bb:paintBorder(x, y, tw, th, px(1), PALE, px(8))
                    if lab then lab:paintTo(bb, x + math.floor((tw - lab:getSize().w) / 2), y + th + px(2)) end
                end)
                taps[#taps + 1] = { w = tc, callback = b.callback, enabled = true, keep = b.keep }
                if used > 0 then line[#line + 1] = HS:new{ width = px(8) } end
                line[#line + 1] = tc
                used = used + 1
            end
            if line then g[#g + 1] = line end
        elseif it.kind == "action" then
            -- 2.1.14: a row with what it is, a line under it, and a button at the right;
            -- a tap anywhere on the row is the button
            for j, b in ipairs(it.list or {}) do
                -- 2.1.37 (TK): a thin line between the items, so each one is easy to tell apart
                if j > 1 then
                    -- 2.1.37 / 2.2.0 (TK): black with Look › Colour on (white at night), grey without
                    g[#g + 1] = canvas(w, px(9), function(bb, x, y)
                        fill(bb, x, y + px(4), w, px(1), { v = Sheet.colourOn(P) and INK or SOFT })
                    end)
                end
                local enabled = b.enabled ~= false and b.callback ~= nil
                -- 2.1.22 (TK): a button that can't do anything (no highlights yet, nothing waiting) isn't drawn; the line under says why
                local bt = (b.button and enabled) and text(b.button, 12, true, Sheet.pillOn(P)) or nil
                local bw = bt and (bt:getSize().w + px(26)) or 0
                local room = w - bw - px(16)
                local t = text(b.text or "", 15, true, INK, room)
                local s = b.sub and W("textboxwidget"):new{ text = b.sub, face = Font:getFace("cfont", 11), width = room, fgcolor = SUB } or nil
                local rh = math.max(px(42), t:getSize().h + (s and s:getSize().h or 0) + px(10))
                local hue = b.colour or sec.colour or "blue"
                local solid = Sheet.pillHue(P, hue) -- 2.1.34: Solid's colour for the button too; 2.1.36: Pill Colours
                local rc = canvas(w, rh, function(bb, x, y)
                    t:paintTo(bb, x + px(4), y + px(4))
                    if s then s:paintTo(bb, x + px(4), y + px(4) + t:getSize().h) end
                    if bt then
                        local bh = px(32)
                        local bx, by = x + w - bw, y + math.floor((rh - bh) / 2)
                        if enabled and P.colour then
                            roundFill(bb, bx, by, bw, bh, math.floor(bh / 2), solid)
                        elseif enabled then
                            roundFill(bb, bx, by, bw, bh, math.floor(bh / 2), { v = INK })
                        else
                            bb:paintBorder(bx, by, bw, bh, px(2), SOFT, math.floor(bh / 2))
                        end
                        bt:paintTo(bb, bx + math.floor((bw - bt:getSize().w) / 2), by + math.floor((bh - bt:getSize().h) / 2))
                    end
                end)
                if b.callback then taps[#taps + 1] = { w = rc, callback = b.callback, enabled = enabled, keep = b.keep } end
                g[#g + 1] = rc
            end
        elseif it.kind == "counts" then
            -- 2.1.23: number tiles in a row (X-Ray's Characters, Places, ...): tap for the list
            local list = it.list or {}
            local n = math.max(1, #list)
            local gap = px(8)
            local tw = math.floor((w - (n - 1) * gap) / n)
            local line = HG:new{ align = "top" }
            for j, b in ipairs(list) do
                local num = text(tostring(b.n or 0), 20, true, INK, tw - px(16))
                local lab = text(b.text or "", 10, true, SUB, tw - px(16))
                local th = num:getSize().h + lab:getSize().h + px(16)
                local hue = b.colour or Sheet.CYCLE[(j - 1) % #Sheet.CYCLE + 1]
                local tc = canvas(tw, th, function(bb, x, y)
                    -- 2.1.37: Look › Colour off: outlined
                    local col = Sheet.colourOn(P)
                    roundFill(bb, x, y, tw, th, px(12), col and P.tint(hue, P.night and 0.3 or 0.26) or { v = PAPER })
                    if not col then bb:paintBorder(x, y, tw, th, px(P.colour and 2 or 1), P.colour and SOFT or INK, px(12)) end
                    num:paintTo(bb, x + px(8), y + px(6))
                    lab:paintTo(bb, x + px(8), y + px(8) + num:getSize().h)
                end)
                if b.callback then taps[#taps + 1] = { w = tc, callback = b.callback, enabled = true, keep = b.keep } end
                if j > 1 then line[#line + 1] = HS:new{ width = gap } end
                line[#line + 1] = tc
            end
            g[#g + 1] = line
        elseif it.kind == "trio" then
            -- 2.1.23: up to three big values side by side (a label over each, a note under)
            local list = it.list or {}
            local n = math.max(1, #list)
            local cw2 = math.floor(w / n)
            local cells, hmax = {}, 0
            for j, b in ipairs(list) do
                local l = text(string.upper(b.label or ""), 9, true, SUB, cw2 - px(8))
                local v = text(b.value or "", 17, true, INK, cw2 - px(8))
                local nt = b.note and text(b.note, 11, false, SUB, cw2 - px(8)) or nil
                cells[j] = { l, v, nt }
                hmax = math.max(hmax, l:getSize().h + v:getSize().h + (nt and nt:getSize().h or 0) + px(4))
            end
            g[#g + 1] = canvas(w, hmax, function(bb, x, y)
                for j, c in ipairs(cells) do
                    local cx = x + (j - 1) * cw2
                    c[1]:paintTo(bb, cx, y)
                    c[2]:paintTo(bb, cx, y + c[1]:getSize().h + px(2))
                    if c[3] then c[3]:paintTo(bb, cx, y + c[1]:getSize().h + c[2]:getSize().h + px(2)) end
                end
            end)
        elseif it.kind == "columns" then
            -- 2.1.23: a bar for each (a chapter), labels under; after `now`, not yet (an outline)
            local vals = it.values or {}
            local n = math.max(1, #vals)
            local gap = n > 20 and px(2) or px(5)
            local bw = math.max(px(3), math.floor((w - (n - 1) * gap) / n))
            local bh = px(60)
            local mx = 0
            for _j, v in ipairs(vals) do mx = math.max(mx, v) end
            local labs = {}
            local every = n > 24 and 5 or (n > 12 and 2 or 1)
            for j = 1, n do
                if j == 1 or j % every == 0 or j == it.now then
                    labs[j] = text(it.labels and it.labels[j] or tostring(j), 9, j == it.now, j == it.now and INK or SUB)
                end
            end
            local lab_h = px(16)
            local hue = it.colour or sec.colour or "blue"
            g[#g + 1] = canvas(w, bh + lab_h, function(bb, x, y)
                for j, v in ipairs(vals) do
                    local bx = x + (j - 1) * (bw + gap)
                    if it.now and j > it.now then
                        bb:paintBorder(bx, y + bh - px(6), bw, px(6), px(1), SOFT, px(2))
                    elseif v > 0 then
                        local hh = math.max(px(4), math.floor(bh * v / math.max(1, mx)))
                        roundFill(bb, bx, y + bh - hh, bw, hh, math.min(px(4), math.floor(bw / 2)),
                            P.colour and P.hue(hue) or { v = INK })
                    else
                        fill(bb, bx, y + bh - px(3), bw, px(3), { v = SOFT })
                    end
                    local l = labs[j]
                    if l then l:paintTo(bb, bx + math.floor((bw - l:getSize().w) / 2), y + bh + px(3)) end
                end
            end)
            if it.caption then g[#g + 1] = text(it.caption, 10, false, SUB, w) end
        elseif it.kind == "quote" then
            -- 2.1.14: a highlight (or bookmark): its colour down the side, the page, the
            -- words, a note under them
            for j, b in ipairs(it.list or {}) do
                if j > 1 then g[#g + 1] = VS:new{ width = px(6) } end
                local pg = text(b.page or "", 12, true, INK)
                local pw = math.max(px(54), pg:getSize().w + px(8))
                local room = w - pw - px(28)
                local words = b.text or ""
                if b.max_chars and #words > b.max_chars then
                    words = words:sub(1, b.max_chars):gsub("[\128-\191]*$", ""):gsub("%s+%S*$", "") .. "…”"
                end
                local q = W("textboxwidget"):new{ text = words, face = Font:getFace("cfont", 13), width = room, fgcolor = INK }
                local hint = b.hint and text(b.hint, 10, false, SUB, room) or nil
                local nt = b.note and text("✎ " .. b.note, 12, true, INK, room) or nil
                local rh = q:getSize().h + (hint and hint:getSize().h or 0) + (nt and (nt:getSize().h + px(4)) or 0) + px(16)
                local hue = b.colour or Sheet.CYCLE[(j - 1) % #Sheet.CYCLE + 1]
                local rc = canvas(w, rh, function(bb, x, y)
                    roundFill(bb, x, y, w, rh, px(12), P.colour and P.tint(hue, P.night and 0.2 or 0.16) or { v = PAPER })
                    if not P.colour then bb:paintBorder(x, y, w, rh, px(1), INK, px(12)) end
                    roundFill(bb, x, y, px(7), rh, px(3), P.colour and P.hue(hue) or { v = INK })
                    pg:paintTo(bb, x + px(16), y + px(8))
                    local tx, ty = x + pw + px(18), y + px(8)
                    q:paintTo(bb, tx, ty)
                    ty = ty + q:getSize().h
                    if hint then hint:paintTo(bb, tx, ty) ty = ty + hint:getSize().h end
                    if nt then nt:paintTo(bb, tx, ty + px(4)) end
                end)
                if b.callback then taps[#taps + 1] = { w = rc, callback = b.callback, enabled = true, keep = b.keep } end
                g[#g + 1] = rc
            end
        elseif it.kind == "custom" then
            -- 2.1.26: a widget the caller builds at this width (Glimpse's pictures); it adds
            -- its own taps as { w = widget, callback, keep }
            local okC, cw2 = pcall(it.build, w, P, taps)
            if okC and cw2 then g[#g + 1] = cw2
            elseif not okC then O.logger.warn(O.TAG, "popup part:", tostring(cw2)) end
        end
    end
    return g
end

-- (re)build the sheet's content into widget
build = function(widget, spec)
    local P = widget.P
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local side = px(8)
    local sheet_w = sw - 2 * side
    local ip = px(16)                -- inside the sheet
    local cw = sheet_w - 2 * ip       -- content width
    local sp = px(12)                -- inside a section
    local VG, VS = W("verticalgroup"), W("verticalspan")
    local taps = {}
    widget.taps = taps
    widget.spec = spec

    local body = VG:new{ align = "left" }
    -- the title, a subtitle, ✕
    local title = text(spec.title or "", 19, true, INK, cw - px(40))
    local x_t = text("\u{2715}", 18, true, INK)
    local sub = spec.subtitle and spec.subtitle ~= "" and W("textboxwidget"):new{ text = spec.subtitle,
        face = Font:getFace("cfont", 12), width = cw - px(40), fgcolor = SUB } or nil
    local head_h = title:getSize().h + (sub and sub:getSize().h or 0) + px(4)
    local xbox = canvas(x_t:getSize().w + px(16), x_t:getSize().h + px(12), function(bb, x, y) x_t:paintTo(bb, x + px(8), y + px(6)) end)
    taps[#taps + 1] = { w = xbox, callback = function() end }
    body[#body + 1] = canvas(cw, head_h, function(bb, x, y)
        title:paintTo(bb, x, y)
        if sub then sub:paintTo(bb, x, y + title:getSize().h) end
        xbox:paintTo(bb, x + cw - xbox.width + px(8), y - px(4))
    end)
    body[#body + 1] = VS:new{ width = px(8) }
    -- the line of colour under the title
    body[#body + 1] = canvas(cw, px(5), function(bb, x, y)
        if not Sheet.rainbow(P) then fill(bb, x, y + px(2), cw, px(1), { v = P.colour and SOFT or INK }) return end
        y = y + px(1) -- 2.1.30: a 3 px line, centred where the 5 px one was
        local n = #Sheet.CYCLE
        local seg = math.floor(cw / n)
        for i, name in ipairs(Sheet.CYCLE) do
            local sx = x + (i - 1) * seg
            fill(bb, sx, y, i == n and (x + cw - sx) or seg, px(3), Sheet.cycleHue(P, name))
        end
    end)
    body[#body + 1] = VS:new{ width = px(12) }
    -- the sections
    for i, sec in ipairs(spec.sections or {}) do
        if i > 1 then body[#body + 1] = VS:new{ width = px(10) } end
        local inner = sectionBody(sec, cw - 2 * sp, P, taps)
        local lab = sec.title and text(string.upper(sec.title), 10, true, SUB) or nil
        local lab_h = lab and (lab:getSize().h + px(6)) or 0
        local h = sp + lab_h + inner:getSize().h + sp
        -- 2.1.37 (TK): Look › Colour off: the sections outlined, not filled, no colour dash
        local col = Sheet.colourOn(P)
        local bg = (sec.plain or not col) and { v = PAPER } or P.tint(sec.colour or "blue", sec.strong and (P.night and 0.26 or 0.22) or nil)
        body[#body + 1] = canvas(cw, h, function(bb, x, y)
            roundFill(bb, x, y, cw, h, px(16), bg)
            if not col and not sec.plain then bb:paintBorder(x, y, cw, h, px(P.colour and 2 or 1), P.colour and SOFT or PALE, px(16)) end
            local top = y + sp
            if lab then
                if col then roundFill(bb, x + sp, top + px(3), px(16), px(7), px(3), P.hue(sec.colour or "blue")) end
                lab:paintTo(bb, x + (col and (sp + px(22)) or sp), top)
                top = top + lab_h
            end
            inner:paintTo(bb, x + sp, top)
        end)
    end
    if spec.cancel ~= false then
        body[#body + 1] = VS:new{ width = px(12) }
        local ct = text(spec.cancel_text or _("Cancel"), 14, true, INK)
        local cb = canvas(cw, px(38), function(bb, x, y)
            bb:paintBorder(x, y, cw, px(38), px(2), INK, px(19))
            ct:paintTo(bb, x + math.floor((cw - ct:getSize().w) / 2), y + math.floor((px(38) - ct:getSize().h) / 2))
        end)
        taps[#taps + 1] = { w = cb, callback = function() end }
        body[#body + 1] = cb
    end
    local content_h = body:getSize().h
    local grab = px(22)
    local sheet_h = math.min(sh - px(20), grab + content_h + ip)
    -- 2.1.33: a window keeps one height from page to page
    if spec.full then sheet_h = sh - px(20) end
    local region = Geom:new{ x = side, y = sh - sheet_h, w = sheet_w, h = sheet_h }
    -- a smaller sheet after a page change: the old area is redrawn too
    local old = widget.region
    if old then
        local top = math.min(old.y, region.y)
        widget.redraw_region = Geom:new{ x = side, y = top, w = sheet_w, h = sh - top }
    end
    widget.region = region
    widget[1] = canvas(sheet_w, sheet_h + px(30), function(bb, x, y)
        -- the sheet: paper, rounded top, an outline, a grab bar
        bb:paintRoundedRect(x, y, sheet_w, sheet_h + px(30), PAPER, px(22))
        -- 2.1.30 (TK): a thinner, sleeker rainbow edge (was 4)
        Sheet.edge(bb, x, y, sheet_w, sheet_h + px(30), px(2), px(22), P)
        if Sheet.rainbow(P) then
            local n, gw = #Sheet.CYCLE, px(64)
            local gx = x + math.floor((sheet_w - gw) / 2)
            for i, name in ipairs(Sheet.CYCLE) do
                fill(bb, gx + math.floor((i - 1) * gw / n), y + px(8), math.ceil(gw / n), px(4), Sheet.cycleHue(P, name))
            end
        else
            bb:paintRoundedRect(x + math.floor(sheet_w / 2) - px(24), y + px(8), px(48), px(5), SOFT, px(2))
        end
        body:paintTo(bb, x + ip, y + grab)
    end)
end

function Sheet.new(spec)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local widget = SheetWidget:new{ dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }, P = palette(), taps = {},
        on_close = spec.on_close, orbitshelf_perf = "popup" }
    build(widget, spec)
    local GestureRange = require("ui/gesturerange")
    local Device = require("device")
    widget.ges_events = {
        SheetTap = { GestureRange:new{ ges = "tap", range = widget.dimen } },
        SheetSwipe = { GestureRange:new{ ges = "swipe", range = widget.dimen } },
        SheetHold = { GestureRange:new{ ges = "hold", range = widget.dimen } },
    }
    widget.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    return widget
end

function Sheet.show(spec)
    local w = Sheet.new(spec)
    UIManager:show(w)
    return w
end

-- a sheet from ButtonDialog-style rows ({ { { text, callback, enabled } }, ... }): one list,
-- "Cancel" rows dropped (the sheet has its own); the title's first line is the title
function Sheet.dialog(t)
    local lines = {}
    for l in tostring(t.title or ""):gmatch("[^\n]+") do lines[#lines + 1] = l end
    local list = {}
    for _i, row in ipairs(t.buttons or {}) do
        for _j, b in ipairs(row) do
            if type(b) == "table" and b.text and b.text ~= _("Cancel") then
                list[#list + 1] = { text = b.text, callback = b.callback, enabled = b.enabled }
            end
        end
    end
    -- the callbacks close the dialog themselves (UIManager:close on this widget)
    for _i, b in ipairs(list) do b.keep = true end
    -- a long list: pages of PER rows in the same sheet
    local PER = 9
    local pages = math.max(1, math.ceil(#list / PER))
    local widget
    local function spec(page)
        local part = {}
        for i = (page - 1) * PER + 1, math.min(#list, page * PER) do part[#part + 1] = list[i] end
        local items = { { kind = "list", list = part } }
        if pages > 1 then
            local nav = {}
            if page > 1 then nav[#nav + 1] = { text = _("‹ Back"), keep = true, colour = "purple",
                callback = function() widget:rebuild(spec(page - 1)) end } end
            if page < pages then nav[#nav + 1] = { text = _("More ›"), keep = true, fill = true, colour = "purple",
                callback = function() widget:rebuild(spec(page + 1)) end } end
            items[#items + 1] = { kind = "pills", list = nav }
        end
        local sub = #lines > 1 and table.concat(lines, " · ", 2) or nil
        if pages > 1 then sub = (sub and (sub .. " · ") or "") .. page .. " / " .. pages end
        return { title = lines[1] or "", subtitle = sub,
            sections = { { colour = t.colour or "blue", plain = true, items = items } } }
    end
    widget = Sheet.new(spec(1))
    return widget
end

-- a ButtonDialog-style popup, as a sheet (2.1.12): same { title, buttons } table
function O.dialog(t) return Sheet.dialog(t) end

return Sheet
