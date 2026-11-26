-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.26 (TK picked the design): a book's pictures from Glimpse (glimpse.koplugin), without
-- opening the book, spoiler-free:
--   * the list of pictures is Glimpse's own saved scan of the book (its settings folder);
--     when Glimpse hasn't been through the book yet, OrbitShelf runs Glimpse's own scanner
--     over the EPUB (plain Lua, the book stays closed) and keeps the result in its cache
--   * Glimpse's settings are followed: its filter (balanced / all), the pictures you hid or
--     added for the book, and its Mode: up to your chapter (where the book was left) or the
--     whole book. Pictures past your chapter are never decoded: a grey box with a "?"
--   * the popup (counts, the pictures up to your page, Full Screen / Open In Glimpse) and a
--     full screen view: the picture big, then where each picture is in the book along a line,
--     with SimpleUI's critter where you are (a marker without SimpleUI)
-- Nothing of Glimpse's is changed.
local O = require("orbitshelf_core")
local T, _ = O.T, O._
local UIManager = O.UIManager
local Device = require("device")
local Screen = Device.screen
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")

local G = {}
O.Glimpse = G

local INK, PAPER = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local SUB = Blitbuffer.gray(0.2)
local SOFT = Blitbuffer.gray(0.55)
local function px(v) return Screen:scaleBySize(v) end
local function W(name) return require("ui/widget/" .. name) end
local function face(size) return require("ui/font"):getFace("cfont", size) end
local function text(s, size, bold, color, max_w)
    return W("textwidget"):new{ text = s, face = face(size), bold = bold, fgcolor = color or INK, max_width = max_w }
end

-- ---- Glimpse's files and settings ---------------------------------------------------------

local function gset(key)
    local grs = rawget(_G, "G_reader_settings")
    return grs and grs:readSetting(key) or nil
end

local function pluginDir()
    local dirs = { "plugins" }
    local okD, DS = pcall(require, "datastorage")
    if okD then dirs[2] = DS:getDataDir() .. "/plugins" end
    local _l1 = dirs
    for _l1_n = 1, #_l1 do local dir = _l1[_l1_n]
        local f = dir .. "/glimpse.koplugin/glimpse_scanner.lua"
        if O.lfs.attributes(f, "mode") == "file" then return dir .. "/glimpse.koplugin" end
    end
    return nil
end

local scanner_mod -- false: not there
local function scanner()
    if scanner_mod ~= nil then return scanner_mod or nil end
    scanner_mod = false
    local dir = pluginDir()
    if dir then
        local ok, mod = pcall(dofile, dir .. "/glimpse_scanner.lua")
        if ok and type(mod) == "table" and type(mod.filter) == "function" then scanner_mod = mod end
    end
    return scanner_mod or nil
end

function G.installed()
    local pluginOn = O.Stats and O.Stats.pluginOn
    if pluginOn and not pluginOn("glimpse") then return false end
    if gset("glimpse_enabled") == false then return false end
    return scanner() ~= nil
end

-- a saved Lua table, read as data only
local function readLua(file)
    local f = loadfile(file)
    if not f then return nil end
    setfenv(f, {})
    local ok, t = pcall(f)
    return ok and type(t) == "table" and t or nil
end

local function sidecar(path)
    local ok, dir = pcall(function() return require("docsettings"):getSidecarDir(path) end)
    return ok and dir or nil
end

local function docSettings(path)
    local ok, ds = pcall(function()
        local DS = require("docsettings")
        if DS.hasSidecarFile and not DS:hasSidecarFile(path) then return nil end
        return DS:open(path)
    end)
    return ok and ds or nil
end

local function cacheFile(path)
    local okD, DS = pcall(require, "datastorage")
    if not okD then return nil end
    local dir = DS:getDataDir() .. "/cache/bookorbit"
    O.lfs.mkdir(dir)
    dir = dir .. "/glimpse"
    O.lfs.mkdir(dir)
    local okM, md5 = pcall(function() return require("ffi/sha2").md5(path) end)
    return dir .. "/" .. (okM and md5 or path:gsub("[^%w]", "_")) .. ".lua"
end

local function zipReader(path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not (ok and Archiver and Archiver.Reader) then return nil end
    local r = Archiver.Reader:new()
    if not r:open(path) then return nil end
    return r
end

local memo = {} -- path -> { mtime, size, scan }

-- Glimpse's list of the book's pictures: its own save, ours, or a fresh look (EPUB only).
-- cheap: no fresh look (only what's saved)
function G.scan(path, cheap)
    if type(path) ~= "string" then return nil end
    local a = O.lfs.attributes(path)
    if not a then return nil end
    local m = memo[path]
    if m and m.mtime == a.modification and m.size == a.size then return m.scan end
    local sc = scanner()
    if not sc then return nil end
    local function fits(c)
        return c and type(c.scan) == "table" and (c.scan.version == nil or c.scan.version == sc.VERSION)
            and tonumber(c.mtime) == a.modification and tonumber(c.size) == a.size and c.scan
    end
    local dir = sidecar(path)
    local got = dir and fits(readLua(dir .. "/glimpse.scan.lua"))
    local cf = cacheFile(path)
    if not got and cf then got = fits(readLua(cf)) end
    if not got and cheap then return nil end
    if not got and path:lower():match("%.epub$") and type(sc.scan) == "function" then
        local r = zipReader(path)
        if r then
            local ok, res = pcall(sc.scan, function(p)
                local okX, data = pcall(r.extractToMemory, r, p)
                return okX and type(data) == "string" and #data > 0 and data or nil
            end)
            pcall(r.close, r)
            if ok and type(res) == "table" then
                got = res
                if cf then
                    pcall(function()
                        local LS = require("luasettings")
                        local st = LS:open(cf)
                        st:saveSetting("mtime", a.modification)
                        st:saveSetting("size", a.size)
                        st:saveSetting("scan", res)
                        st:flush()
                    end)
                end
            elseif not ok then
                O.logger.warn(O.TAG, "Glimpse scan:", tostring(res))
            end
        end
    end
    memo[path] = { mtime = a.modification, size = a.size, scan = got or nil }
    return got or nil
end

function G.saved(path, cheap)
    if not G.installed() then return false end
    local s = G.scan(path, cheap)
    return s ~= nil and type(s.images) == "table" and #s.images > 0
end

local KIND_WORDS = {
    map = { "map", "plan of", "chart" },
    tree = { "family", "tree", "genealog", "lineage", "house of" },
}
local function kindOf(im)
    local cap = ((im.caption or "") .. " " .. (im.alt or "") .. " " .. (im.title_attr or "")
        .. " " .. (im.path or "")):lower()
    for k, words in pairs(KIND_WORDS) do
        local _l2 = words
        for _l2_n = 1, #_l2 do local w = _l2[_l2_n] if cap:find(w, 1, true) then return k end end
    end
    return "pic"
end

-- the pictures to show: Glimpse's filter, your hidden / added ones, and its Mode
-- returns { list = { im, ... (im.locked past your chapter) }, shown, ahead, whole, cur, n_spine, last }
function G.pictures(path, opts)
    local sc, scan = scanner(), G.scan(path)
    if not (sc and scan and type(scan.images) == "table") then return nil end
    local level = gset("glimpse_filter") == "all" and "all" or "balanced"
    local okF, kept = pcall(sc.filter, scan.images, level)
    if not okF or type(kept) ~= "table" then kept = scan.images end
    local ds = docSettings(path)
    local hidden = ds and ds:readSetting("glimpse_hidden") or {}
    local forced = ds and ds:readSetting("glimpse_forced") or {}
    local keep = {}
    local _l3 = kept
    for _l3_n = 1, #_l3 do local im = _l3[_l3_n] keep[im.path] = true end
    local whole = (gset("glimpse_scope") == "whole_book") or (opts and opts.whole)
    local cur
    local xp = ds and ds:readSetting("last_xpointer")
    if type(xp) == "string" then cur = tonumber(xp:match("DocFragment%[(%d+)%]") or xp:match("[sS]ection%[(%d+)%]")) end
    local pct = ds and tonumber(ds:readSetting("percent_finished")) or (opts and opts.pct) or 0
    -- with nowhere to go by (never opened), nothing is shown unless Glimpse shows the whole book
    local n_spine = tonumber(scan.spine_count) or 0
    local out = { list = {}, shown = 0, ahead = 0, whole = whole, cur = cur, pct = pct, n_spine = n_spine,
        last = ds and ds:readSetting("glimpse_last") or nil }
    local _l4 = scan.images
    for _l4_n = 1, #_l4 do local im = _l4[_l4_n]
        if (keep[im.path] or forced[im.path]) and not hidden[im.path] and not im.is_cover then
            local e = {}
            for k, v in pairs(im) do e[k] = v end
            e.kind = kindOf(im)
            local si = tonumber(im.spine_index) or 0
            e.frac = n_spine > 0 and math.max(0, math.min(1, (si - 0.5) / n_spine)) or 0
            e.locked = not whole and not (cur and si <= cur)
            if e.locked then out.ahead = out.ahead + 1 else out.shown = out.shown + 1 end
            out.list[#out.list + 1] = e
        end
    end
    table.sort(out.list, function(x, y)
        local a1, b1 = tonumber(x.spine_index) or 0, tonumber(y.spine_index) or 0
        if a1 ~= b1 then return a1 < b1 end
        return (tonumber(x.order) or 0) < (tonumber(y.order) or 0)
    end)
    -- a locked one never sits behind you on the line
    local k = 0
    local _l5 = out.list
    for _l5_n = 1, #_l5 do local e = _l5[_l5_n]
        if e.locked and e.frac <= pct then k = k + 1 e.frac = math.min(1, pct + 0.05 * k) end
    end
    return out
end

-- ---- Decoding a picture (only ones up to your chapter) -------------------------------------

local thumbs, thumb_order = {}, {}
local function remember(key, bb)
    thumbs[key] = bb
    thumb_order[#thumb_order + 1] = key
    while #thumb_order > 24 do
        local old = table.remove(thumb_order, 1)
        if thumbs[old] and thumbs[old].free then pcall(thumbs[old].free, thumbs[old]) end
        thumbs[old] = nil
    end
end

function G.clear()
    for k, bb in pairs(thumbs) do if bb.free then pcall(bb.free, bb) end thumbs[k] = nil end
    thumb_order = {}
end

-- the picture fitted in w x h (keeping its shape), or nil; night mode: shown as it is,
-- unless Glimpse's Invert Images In Night Mode is on
function G.render(path, im, w, h)
    if not im or im.locked or im.format == "svg" or im.is_svg_doc then return nil end
    local key = path .. "|" .. tostring(im.path) .. "|" .. w .. "x" .. h .. (Screen.night_mode and "n" or "")
    if thumbs[key] ~= nil then return thumbs[key] or nil end
    local bb
    pcall(function()
        local r = zipReader(path)
        if not r then return end
        local okX, data = pcall(r.extractToMemory, r, im.path)
        pcall(r.close, r)
        if not (okX and type(data) == "string" and #data > 0) then return end
        local iw, ih = tonumber(im.width), tonumber(im.height)
        local fw, fh = w, h
        if iw and ih and iw > 0 and ih > 0 then
            local s = math.min(w / iw, h / ih)
            fw, fh = math.max(1, math.floor(iw * s)), math.max(1, math.floor(ih * s))
        end
        local RI = require("ui/renderimage")
        bb = RI:renderImageData(data, #data, false, fw, fh)
        if bb and Screen.night_mode and not gset("glimpse_invert_night") then
            bb:invertRect(0, 0, bb:getWidth(), bb:getHeight())
        end
    end)
    remember(key, bb or false)
    return bb
end

-- ---- Drawing helpers ----------------------------------------------------------------------

local function paintPic(bb, x, y, w, h, path, im, P)
    local Sheet = O.Sheet
    if im.locked then
        Sheet.roundFill(bb, x, y, w, h, px(8), P.colour and P.tint("purple", P.night and 0.3 or 0.25) or { v = SOFT })
        local q = text("?", math.max(14, math.floor(w / 6)), true, INK)
        q:paintTo(bb, x + math.floor((w - q:getSize().w) / 2), y + math.floor((h - q:getSize().h) / 2))
        return
    end
    local pic = G.render(path, im, w, h)
    Sheet.roundFill(bb, x, y, w, h, px(8), P.colour and P.tint("teal", P.night and 0.18 or 0.12) or { v = PAPER })
    if pic then
        local pw, ph = pic:getWidth(), pic:getHeight()
        bb:blitFrom(pic, x + math.floor((w - pw) / 2), y + math.floor((h - ph) / 2), 0, 0, pw, ph)
    else
        local what = im.kind == "map" and _("map") or (im.kind == "tree" and _("family tree") or _("picture"))
        local l = text(what, 11, false, SUB, w - px(8))
        l:paintTo(bb, x + math.floor((w - l:getSize().w) / 2), y + math.floor((h - l:getSize().h) / 2))
    end
    bb:paintBorder(x, y, w, h, px(1), SOFT, px(8))
end

local function capOf(im)
    if im.locked then return _("After your page") end
    local c = im.caption or im.title_attr or im.alt
    if type(c) ~= "string" or c == "" then
        c = ({ map = _("Map"), tree = _("Family tree") })[im.kind] or _("Picture")
    end
    return c
end

local function pctOf(e)
    if e.locked then return _("still ahead") end
    return math.floor(e.frac * 100 + 0.5) .. "%"
end

-- ---- The popup ------------------------------------------------------------------------------

local function openInGlimpse(path)
    if not O.openThen then return end
    if O.Stats and O.Stats.closeForBook then pcall(O.Stats.closeForBook) end
    O.openThen(path, function(ui)
        if ui and ui.glimpse and type(ui.glimpse.onGlimpseShow) == "function" then ui.glimpse:onGlimpseShow()
        elseif ui then ui:handleEvent(require("ui/event"):new("GlimpseShow")) end
    end)
end

function G.show(rec, path, d)
    if not G.installed() then return false end
    local whole_once = false
    local widget
    local function spec(page)
        local pics = G.pictures(path, { whole = whole_once, pct = d and d.pct })
        local title = tostring(rec and (rec.display_title or rec.title) or "")
        if not pics or #pics.list == 0 then
            return { title = _("Glimpse"), subtitle = title, cancel = false, sections = { { colour = "teal",
                items = { { kind = "text", size = 13,
                text = pics and _("Glimpse found no maps, family trees or pictures worth showing in this book.")
                    or _("This book isn't an EPUB Glimpse can look through, or it couldn't be read.") } } } } }
        end
        local maps, trees = 0, 0
        local _l6 = pics.list
        for _l6_n = 1, #_l6 do local e = _l6[_l6_n]
            if e.kind == "map" then maps = maps + 1 elseif e.kind == "tree" then trees = trees + 1 end
        end
        local counts = { { n = #pics.list, text = _("Pictures"), colour = "teal" } }
        if maps > 0 then counts[#counts + 1] = { n = maps, text = _("Maps"), colour = "blue" } end
        if trees > 0 then counts[#counts + 1] = { n = trees, text = _("Family trees"), colour = "green" } end
        if pics.ahead > 0 then counts[#counts + 1] = { n = pics.ahead, text = _("Still ahead"), colour = "gold" } end
        local per = 8
        local pages = math.max(1, math.ceil(#pics.list / per))
        page = math.max(1, math.min(pages, page or 1))
        local grid = { kind = "custom", build = function(w, P, taps)
            local cols, gap = 4, px(12)
            local cw = math.floor((w - (cols - 1) * gap) / cols)
            local ch = math.floor(cw * 1.15)
            local cap_h = text("Ag", 12, true):getSize().h * 2 + px(4)
            local first = (page - 1) * per + 1
            local n = math.min(per, #pics.list - first + 1)
            local rows = math.ceil(n / cols)
            local h = rows * (ch + cap_h + px(10))
            local cv = O.Sheet.canvas(w, h, function(bb, x, y)
                for k = 0, n - 1 do
                    local e = pics.list[first + k]
                    local cx = x + (k % cols) * (cw + gap)
                    local cy = y + math.floor(k / cols) * (ch + cap_h + px(10))
                    paintPic(bb, cx, cy, cw, ch, path, e, P)
                    if pics.last and e.path == pics.last and not e.locked then
                        bb:paintBorder(cx, cy, cw, ch, px(4), P.colour and P.hue("gold").v or INK, px(8))
                    end
                    text(capOf(e), 12, true, e.locked and SUB or INK, cw):paintTo(bb, cx, cy + ch + px(4))
                    text(pctOf(e), 11, false, SUB, cw):paintTo(bb, cx, cy + ch + px(4) + math.floor(cap_h / 2))
                end
            end)
            -- a tap on a picture (not a locked one) opens it full screen
            local tap = O.Sheet.canvas(w, h, function() end)
            local holder = W("container/widgetcontainer"):extend{}
            function holder.getSize(_s) return Geom:new{ w = w, h = h } end
            function holder.paintTo(_s, bb, x, y)
                cv:paintTo(bb, x, y)
                tap.dimen = Geom:new{ x = x, y = y, w = w, h = h }
            end
            taps[#taps + 1] = { w = tap, keep = true, callback = function()
                local pos = widget and widget._last_pos
                if not (pos and tap.dimen) then return end
                local col = math.floor((pos.x - tap.dimen.x) / (cw + gap))
                local row = math.floor((pos.y - tap.dimen.y) / (ch + cap_h + px(10)))
                local idx = first + row * cols + col
                local e = pics.list[idx]
                if e and not e.locked and col < cols then G.viewer(rec, path, d, idx, whole_once) end
            end }
            return holder:new{}
        end }
        local items = { grid }
        if pages > 1 then
            items[#items + 1] = { kind = "pills", list = {
                { text = "‹", enabled = page > 1, keep = true,
                    callback = function() widget:rebuild(spec(page - 1)) end },
                { text = T(_("%1 / %2"), page, pages), enabled = false },
                { text = "›", enabled = page < pages, keep = true,
                    callback = function() widget:rebuild(spec(page + 1)) end } } }
        end
        local note = pics.whole and _("The whole book (Glimpse's Mode).")
            or (pics.cur and _("Up to your chapter. Gold edge: the one you looked at last. Tap one for full screen.")
                or _("Open the book once so OrbitShelf knows where you are; until then the pictures stay hidden."))
        items[#items + 1] = { kind = "text", text = note, size = 11, dim = true }
        local first_open
        for i, e in ipairs(pics.list) do if not e.locked then first_open = first_open or i end end
        local acts = {}
        if first_open then
            acts[#acts + 1] = { text = _("Full Screen"), colour = "teal", fill = true,
                callback = function() G.viewer(rec, path, d, first_open, whole_once) end }
        end
        acts[#acts + 1] = { text = _("Open In Glimpse"), colour = "blue",
            callback = function() openInGlimpse(path) end }
        if pics.ahead > 0 and not pics.whole then
            acts[#acts + 1] = { text = _("Show All (spoilers)"), colour = "gold", keep = true,
                callback = function() whole_once = true widget:rebuild(spec(1)) end }
        end
        items[#items + 1] = { kind = "pills", list = acts }
        local sub = title .. "  ·  " .. (pics.whole and _("whole book") or _("up to your chapter"))
            .. "  ·  " .. _("from Glimpse")
        return { title = _("Glimpse"), subtitle = sub, cancel = false, sections = {
            { colour = "teal", plain = true, items = { { kind = "counts", list = counts } } },
            { title = pics.whole and _("All pictures") or _("Up to your page"), colour = "teal", plain = true,
                items = items },
        } }
    end
    widget = O.Sheet.new(spec(1))
    -- the grid needs where the tap was
    local orig = widget.onSheetTap
    widget.onSheetTap = function(self, arg, ges)
        self._last_pos = ges and ges.pos
        return orig(self, arg, ges)
    end
    UIManager:show(widget)
    return true
end

-- ---- Full screen ----------------------------------------------------------------------------

local Viewer = W("container/inputcontainer"):extend{ covers_fullscreen = true }

function Viewer:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.P = O.Sheet.palette()
    local GR = require("ui/gesturerange")
    self.ges_events = {
        VTap = { GR:new{ ges = "tap", range = self.dimen } },
        VSwipe = { GR:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    self.hits = {}
end

function Viewer:getSize() return self.dimen end

function Viewer:go(i)
    local list = self.pics.list
    if i < 1 or i > #list or list[i].locked then return end
    self.idx = i
    UIManager:setDirty(self, function() return "ui", self.dimen, self.P.colour or nil end)
end

function Viewer:step(dir)
    local list, i = self.pics.list, self.idx + dir
    while list[i] and list[i].locked do i = i + dir end
    if list[i] then self:go(i) end
end

function Viewer:paintTo(bb, x0, y0)
    local P, sw, sh = self.P, self.dimen.w, self.dimen.h
    local Sheet = O.Sheet
    self.hits = {}
    bb:paintRect(x0, y0, sw, sh, PAPER)
    local pad = px(24)
    -- top bar
    local back = text("‹ " .. _("Stats"), 18, true, INK)
    back:paintTo(bb, x0 + pad, y0 + px(18))
    self.hits[#self.hits + 1] = { x = x0, y = y0, w = back:getSize().w + 2 * pad, h = px(70),
        fn = function() self:close() end }
    local ttl = text(_("Glimpse"), 20, true, INK)
    ttl:paintTo(bb, x0 + math.floor((sw - ttl:getSize().w) / 2), y0 + px(16))
    local xx = text("\u{2715}", 22, true, INK)
    xx:paintTo(bb, x0 + sw - pad - xx:getSize().w, y0 + px(14))
    self.hits[#self.hits + 1] = { x = x0 + sw - px(90), y = y0, w = px(90), h = px(70),
        fn = function() self:close(true) end }
    local ly = y0 + px(62)
    if Sheet.rainbow(P) then
        local n, seg = #Sheet.CYCLE, math.floor((sw - 2 * pad) / #Sheet.CYCLE)
        for i, name in ipairs(Sheet.CYCLE) do
            Sheet.fill(bb, x0 + pad + (i - 1) * seg, ly, i == n and (sw - 2 * pad - (n - 1) * seg) or seg,
                px(4), Sheet.cycleHue and Sheet.cycleHue(P, name) or P.hue(name))
        end
    else
        bb:paintRect(x0 + pad, ly + px(1), sw - 2 * pad, px(1), INK)
    end
    -- the picture
    local e = self.pics.list[self.idx]
    local track_h = px(230)
    local bottom_h = px(70)
    local info_h = px(120)
    local iy = ly + px(16)
    local ih = sh - (iy - y0) - info_h - track_h - bottom_h - px(10)
    local iw = sw - 2 * pad
    local pic = G.render(self.path, e, iw, ih)
    if pic then
        local pw, ph = pic:getWidth(), pic:getHeight()
        bb:blitFrom(pic, x0 + pad + math.floor((iw - pw) / 2), iy + math.floor((ih - ph) / 2), 0, 0, pw, ph)
    else
        paintPic(bb, x0 + pad, iy, iw, ih, self.path, e, P)
    end
    -- left / right thirds of the picture: the one before / after
    self.hits[#self.hits + 1] = { x = x0, y = iy, w = math.floor(sw / 3), h = ih, fn = function() self:step(-1) end }
    self.hits[#self.hits + 1] = { x = x0 + sw - math.floor(sw / 3), y = iy, w = math.floor(sw / 3), h = ih,
        fn = function() self:step(1) end }
    -- caption and where it is
    local cy = iy + ih + px(10)
    local cap = text(capOf(e), 18, true, INK, iw)
    cap:paintTo(bb, x0 + pad, cy)
    local nth, open_n = 0, 0
    for i, f in ipairs(self.pics.list) do
        if not f.locked then open_n = open_n + 1 if i <= self.idx then nth = nth + 1 end end
    end
    local line = T(_("%1 of %2 so far · about %3 into the book"), nth, open_n, pctOf(e))
    if self.pics.last == e.path then line = line .. " · " .. _("you looked here last") end
    text(line, 12, false, SUB, iw):paintTo(bb, x0 + pad, cy + cap:getSize().h + px(2))
    -- dots
    local n = #self.pics.list
    if n > 1 and n <= 40 then
        local dot, gap = px(8), px(8)
        local dw = n * dot + (n - 1) * gap
        local dx = x0 + math.floor((sw - dw) / 2)
        local dy = cy + px(78)
        for i, f in ipairs(self.pics.list) do
            local k = i == self.idx and { v = INK }
            or (f.locked and { v = SOFT } or (P.colour and P.hue("teal") or { v = SUB }))
            Sheet.roundFill(bb, dx + (i - 1) * (dot + gap), dy, dot, dot, math.floor(dot / 2), k)
        end
    end
    -- where they are in the book
    local ty = sh - track_h - bottom_h + y0
    Sheet.roundFill(bb, x0 + pad, ty + px(6), px(14), px(6), px(3), P.colour and P.hue("teal") or { v = INK })
    text(_("WHERE THEY ARE IN THE BOOK"), 11, true, SUB):paintTo(bb, x0 + pad + px(22), ty)
    local tx0, tx1 = x0 + pad + px(30), x0 + sw - pad - px(30)
    local tw = tx1 - tx0
    local s = px(52)
    local liney = ty + px(40) + s + px(20)
    local pct = self.pics.pct or 0
    Sheet.roundFill(bb, tx0, liney, tw, px(10), px(5), P.colour and P.track or { v = SOFT })
    Sheet.roundFill(bb, tx0, liney, math.max(px(10), math.floor(tw * pct)), px(10), px(5),
        P.colour and P.hue("teal") or { v = INK })
    local last_x = -math.huge
    local raise = false
    for i, f in ipairs(self.pics.list) do
        local cx = tx0 + math.floor(tw * f.frac)
        raise = (cx - last_x < s + px(4)) and not raise
        local top = ty + px(36) + (raise and 0 or px(14))
        local bx = math.max(x0 + pad, math.min(x0 + sw - pad - s, cx - math.floor(s / 2)))
        paintPic(bb, bx, top, s, s, self.path, f, P)
        if i == self.idx then bb:paintBorder(bx, top, s, s, px(3), P.colour and P.hue("gold").v or INK, px(8)) end
        bb:paintRect(cx, top + s, px(2), liney - (top + s), SOFT)
        if not f.locked then
            self.hits[#self.hits + 1] = { x = bx, y = top, w = s, h = s, fn = function() self:go(i) end }
        end
        last_x = cx
    end
    local ux = tx0 + math.floor(tw * pct)
    local you = text(T(_("you · %1%"), math.floor(pct * 100 + 0.5)), 13, true, INK)
    local crit = O.critterSprite and select(2, pcall(O.critterSprite, "reading", px(58), px(58))) or nil
    if type(crit) == "table" and crit.paintTo and crit.dimen then
        crit:paintTo(bb, ux - math.floor(crit.dimen.w / 2), liney + px(14))
        you:paintTo(bb, ux - math.floor(you:getSize().w / 2), liney + px(16) + crit.dimen.h)
    else
        for k = 0, px(14) do bb:paintRect(ux - math.floor(k * 0.6), liney + px(14) + k, math.max(1,
            math.floor(k * 1.2)), 1, INK) end
        you:paintTo(bb, ux - math.floor(you:getSize().w / 2), liney + px(32))
    end
    text(_("start"), 10, false, SUB):paintTo(bb, tx0, liney + px(14))
    local en = text(_("end"), 10, false, SUB)
    en:paintTo(bb, tx1 - en:getSize().w, liney + px(14))
    -- ‹ Gallery Open In Glimpse ›
    local by = y0 + sh - bottom_h + px(10)
    local bx = x0 + pad
    local buttons = {
        { "‹", function() self:step(-1) end },
        { _("Gallery"), function() self:close() end, true },
        { _("Open In Glimpse"), function() self:close(true) openInGlimpse(self.path) end },
        { "›", function() self:step(1) end },
    }
    for bi = 1, #buttons do
        local b = buttons[bi]
        local on = b[3]
        -- 2.1.36: Look › Pill Colours
        local l = text(b[1], 15, true, on and (Sheet.pillOn and Sheet.pillOn(P) or PAPER) or INK)
        local bw, bh = l:getSize().w + px(32), l:getSize().h + px(14)
        if on then Sheet.roundFill(bb, bx, by, bw, bh, math.floor(bh / 2), Sheet.pillHue and Sheet.pillHue(P, "teal") or { v = INK })
        else bb:paintBorder(bx, by, bw, bh, px(2), INK, math.floor(bh / 2)) end
        l:paintTo(bb, bx + px(16), by + px(7))
        self.hits[#self.hits + 1] = { x = bx, y = by, w = bw, h = bh, fn = b[2] }
        bx = bx + bw + px(12)
    end
end

function Viewer:onVTap(_arg, ges)
    local pos = ges and ges.pos
    if not pos then return true end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if pos.x >= h.x and pos.x < h.x + h.w and pos.y >= h.y and pos.y < h.y + h.h then h.fn() return true end
    end
    return true
end

function Viewer:onVSwipe(_arg, ges)
    local dir = ges and ges.direction
    if dir == "west" then self:step(1) elseif dir == "east" then self:step(-1)
    elseif dir == "south" then self:close() end
    return true
end

function Viewer:onClose() self:close() return true end

function Viewer:close(all)
    UIManager:close(self, "full")
    if all and self.on_all then pcall(self.on_all) end
end

function Viewer.onCloseWidget(_s) G.clear() end

function G.viewer(rec, path, d, idx, whole)
    local pics = G.pictures(path, { whole = whole, pct = d and d.pct })
    if not pics or not pics.list[idx] then return end
    local v = Viewer:new{ rec = rec, path = path, pics = pics, idx = idx }
    UIManager:show(v, "full", nil, nil, nil, v.P.colour or nil)
    return v
end

return G
