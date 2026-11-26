-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- The Book Page (1.3.3): one full-screen page for a BookOrbit book, opened by holding
-- it (Hold A Book Opens: Book Page) or from the quick menu's Book Page row.
--
-- Everything on it comes from what's already on the device (the saved lists and the
-- Offline Library), so it opens the same with Wi-Fi off; nothing is fetched to draw
-- it. Plain black and white, cover on the left, details on the right, two rows of
-- buttons (grey = doesn't apply to this book right now), the description, the series
-- in order (5 at a time, swipe or the arrows for more) and more by the author.
-- Tapping a book in either strip shows that book here instead (no page stack); the X
-- closes back to the shelf. Opens and closes with a full refresh, so no ghosting.
local O = require("orbitshelf_core")
local T, TAG, UIManager, _, logger = O.T, O.TAG, O.UIManager, O._, O.logger

local BookPage = {}
O.BookPage = BookPage

local page        -- the widget while it's up
local page_id     -- its book's id
local page_ctx    -- the shelf's ctx (Bulk needs the shelf widget)
local strip_from = {} -- series key -> first index shown in the strip
local strip_owner = {} -- series key -> the book whose page set strip_from
local strip_sim = {} -- 2.0.0: book id -> true while its page shows Similar books (not the series / More by)
local stats_dirty = false -- 2.1.0: the book changed under the stats page: drawn again on the way back
local stats_opener -- 2.1.28: the page's Stats / All Time opener (BookPage.openStats)

local STATUS_TEXT = {
    read = _("Read"), skimmed = _("Skimmed"), reading = _("Reading"), rereading = _("Rereading"),
    on_hold = _("On Hold"), abandoned = _("Abandoned"), want_to_read = _("Want To Read"), unread = _("Unread"),
}


local similarBooks -- below

local function idOf(book)
    if type(book) ~= "table" then return nil end
    return tonumber(book.bookorbit_id) or tonumber(book.id)
        or (O.bookIdForPath and tonumber(O.bookIdForPath(book.filepath)))
end

-- the fullest saved copy of a book (Bookshelf may hand over a trimmed one)
local function recordFor(id, fallback)
    local best
    for _k, entry in pairs(O.page_cache or {}) do
        for _i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            if type(r) == "table" and tonumber(r.bookorbit_id) == id then
                if r.description or r.pages or not best then best = r end
                if r.description and r.pages then return r end
            end
        end
    end
    return best or fallback
end

-- every saved book once (the library list first: it has them all)
local function allBooks()
    local out, seen = {}, {}
    local function take(items)
        for _i, r in ipairs(items or {}) do
            local id = type(r) == "table" and not r.is_folder and tonumber(r.bookorbit_id)
            if id and not seen[id] then seen[id] = true out[#out + 1] = r end
        end
    end
    local lib = O.page_cache and O.page_cache["sort=title"]
    take(type(lib) == "table" and lib.items)
    for _k, entry in pairs(O.page_cache or {}) do take(type(entry) == "table" and entry.items) end
    return out
end

local function lower(s) return type(s) == "string" and s ~= "" and s:lower() or nil end

local function onDevice(id)
    if O.liveBookPath and O.liveBookPath(id) then return true end
    local set = O.onDeviceIdSet and O.onDeviceIdSet() or {}
    return set[id] == true
end

-- 1.3.11: a book on this Kobo shows KOReader's own status (finished, on hold,
-- reading + %), read once per book while the page is open
local device_state = {} -- path -> { s, pct } (false: no status)
local KO_STATUS = { complete = "read", abandoned = "on_hold", reading = "reading" }

local function deviceStatus(id)
    local path = id and O.liveBookPath and O.liveBookPath(id)
    if not path then return nil end
    local got = device_state[path]
    if got == nil then
        got = false
        pcall(function()
            local DocSettings = require("docsettings")
            if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return end
            local ds = DocSettings:open(path)
            local summary = ds:readSetting("summary")
            local st = KO_STATUS[type(summary) == "table" and summary.status or ""]
            local pct = tonumber(ds:readSetting("percent_finished"))
            if not st and pct and pct > 0 then st = pct >= 1 and "read" or "reading" end
            -- 1.3.22: KOReader keeps the day the status last changed (YYYY-MM-DD):
            -- for a finished book, the day it was finished
            local day = type(summary) == "table" and summary.modified
            if st then got = { st, pct, st == "read" and type(day) == "string" and day or nil } end
        end)
        device_state[path] = got
    end
    if got then return got[1], got[2], got[3] end
end

-- status + progress (0-1): KOReader's on this Kobo, else the queued one, else BookOrbit's
local function statusOf(rec)
    local id = tonumber(rec.bookorbit_id)
    local ds, dp, dday = deviceStatus(id)
    if ds then return ds, dp, dday end
    local q = O.Queue and id and O.Queue.statusOf(id)
    local s = q or rec.bookorbit_status
    if s == "" then s = nil end
    local p = tonumber(rec.bookorbit_pct)
    if not s and p and p > 0 and p < 1 then s = "reading" end
    return s, p
end

-- 1.3.11: the status on the cover itself (TK: every book shows it, like Bookshelf's
-- own marks): Read, On Hold, Reading 45%, ... Nothing for Unread.
local function badgeText(rec)
    local s, p = statusOf(rec)
    if not s or s == "unread" then return nil end
    local word = STATUS_TEXT[s] or s
    if (s == "reading" or s == "rereading" or s == "on_hold") and p and p > 0 and p < 1 then
        word = word .. " " .. math.floor(p * 100 + 0.5) .. "%"
    end
    return word
end

-- On device or Queued for a strip book (1.3.16: shown on its cover, at the top)
local function stripLines(rec, rid)
    local lines = {}
    if rid and onDevice(rid) then lines[#lines + 1] = _("On device")
    elseif rid and O.Queue and O.Queue.has(rid) then lines[#lines + 1] = _("Queued") end
    return lines
end

local function fileExists(p)
    return type(p) == "string" and p ~= "" and O.lfs.attributes(p, "mode") == "file"
end

local function shortDate(t)
    t = tonumber(t)
    if not t or t <= 0 then return nil end
    return os.date("%b ", t) .. tonumber(os.date("%d", t)) .. (os.date("%Y", t) ~= os.date("%Y") and os.date(", %Y", t) or "")
end

local function seriesKey(rec) return lower(rec.series) end

-- the series in order (only books with a number; duplicates and gaps kept as they are)
local function seriesOf(rec)
    local key = seriesKey(rec)
    if not key then return nil end
    local list = {}
    for _i, r in ipairs(allBooks()) do
        if lower(r.series) == key and tonumber(r.series_index) then list[#list + 1] = r end
    end
    table.sort(list, function(a, b)
        local x, y = tonumber(a.series_index), tonumber(b.series_index)
        if x ~= y then return x < y end
        return tostring(a.title) < tostring(b.title)
    end)
    return #list > 0 and list or nil
end

-- every author a record names, lower case
local function authorsOf(r)
    local set = {}
    if type(r.authors) == "table" then
        for _i, a in ipairs(r.authors) do
            local l = lower(type(a) == "table" and a.name or a)
            if l then set[l] = true end
        end
    end
    local one = lower(r.author)
    if one then set[one] = true end
    return set
end

-- other books by any of its authors (not the series strip's books when it has one)
local function moreByAuthor(rec, max, skip_series)
    local mine = authorsOf(rec)
    if next(mine) == nil then return {} end
    local id = tonumber(rec.bookorbit_id)
    local key = skip_series and seriesKey(rec) or nil
    local out = {}
    for _i, r in ipairs(allBooks()) do
        if tonumber(r.bookorbit_id) ~= id and not (key and lower(r.series) == key) then
            for a in pairs(authorsOf(r)) do
                if mine[a] then
                    out[#out + 1] = r
                    break
                end
            end
            if #out >= max then break end
        end
    end
    return out
end

-- ---- Similar books (1.3.8) -----------------------------------------------------------
-- BookOrbit's book page has "Similar books" (its own recommendations, up to 8, not the
-- series or the author's). Looked up once per book with Wi-Fi on, only for a book the
-- page has nothing else to show under, in the background; saved, so they show offline
-- too, and looked up again after 2 weeks. Until then (or offline): the saved library's
-- books sharing the most genres with it (general ones like Fiction don't count), same
-- language first.
local SIMILAR_TTL = 14 * 86400
local similar_store -- LuaSettings, opened on first use
local similar_busy = {}

local function similarFile()
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = ok and DataStorage:getDataDir() or "."
    return dir .. "/cache/bookorbit/orbitshelf_similar.lua"
end

local function similarStore()
    if similar_store == nil then
        local ok, LuaSettings = pcall(require, "luasettings")
        similar_store = ok and LuaSettings:open(similarFile()) or false
    end
    return similar_store or nil
end

local GENERIC = { fiction = true, general = true, nonfiction = true, ["non-fiction"] = true,
    books = true, ebook = true, ebooks = true, novel = true, novels = true }

local function genreSet(r)
    local set, n = {}, 0
    for _i, g in ipairs(type(r.genres) == "table" and r.genres or {}) do
        local l = lower(type(g) == "table" and g.name or g)
        if l and not GENERIC[l] then set[l] = true n = n + 1 end
    end
    return set, n
end

local function localSimilar(rec, max)
    local mine, n = genreSet(rec)
    if n == 0 then return {} end
    local id = tonumber(rec.bookorbit_id)
    local scored = {}
    for _i, r in ipairs(allBooks()) do
        if tonumber(r.bookorbit_id) ~= id then
            local score = 0
            for g in pairs(genreSet(r)) do if mine[g] then score = score + 1 end end
            if score > 0 then
                if rec.lang and r.lang and rec.lang == r.lang then score = score + 0.5 end
                scored[#scored + 1] = { r = r, s = score }
            end
        end
    end
    table.sort(scored, function(a, b)
        if a.s ~= b.s then return a.s > b.s end
        return tostring(a.r.title) < tostring(b.r.title)
    end)
    local out = {}
    for i = 1, math.min(max, #scored) do out[i] = scored[i].r end
    return out
end

local again_for -- set below: redraw the page if it still shows this book

local function fetchSimilar(id)
    if similar_busy[id] or not O.isWifiOn() then return end
    local client = O.boApiClient and O.boApiClient()
    if not client or type(O.runWorker) ~= "function" then return end
    similar_busy[id] = true
    O.runWorker(client, function()
        local d = client:catalogBook(id)
        if type(d) ~= "table" then return nil end
        local ids = {}
        for _i, sec in ipairs(type(d.relatedSections) == "table" and d.relatedSections or {}) do
            if type(sec) == "table" and sec.id == "similar" then
                for _j, b in ipairs(type(sec.books) == "table" and sec.books or {}) do
                    local bid = type(b) == "table" and tonumber(b.id)
                    if bid then ids[#ids + 1] = bid end
                end
            end
        end
        return { ids = ids }
    end, function(res)
        similar_busy[id] = nil
        if type(res) ~= "table" or type(res.ids) ~= "table" then return end
        local st = similarStore()
        if st then
            st:saveSetting(tostring(id), { ids = res.ids, t = os.time() })
            pcall(st.flush, st)
        end
        if again_for then again_for(id) end
    end, 30)
end

similarBooks = function(rec, max)
    local id = tonumber(rec.bookorbit_id)
    local st = similarStore()
    local saved = st and id and st:readSetting(tostring(id))
    if id and (type(saved) ~= "table" or os.time() - (tonumber(saved.t) or 0) > SIMILAR_TTL) then
        fetchSimilar(id)
    end
    if type(saved) == "table" and type(saved.ids) == "table" and #saved.ids > 0 then
        local by = {}
        for _i, r in ipairs(allBooks()) do by[tonumber(r.bookorbit_id) or -1] = r end
        local out = {}
        for _i, bid in ipairs(saved.ids) do
            if by[bid] and bid ~= id then out[#out + 1] = by[bid] end
            if #out >= max then break end
        end
        if #out > 0 then return out end
    end
    return localSimilar(rec, max)
end

-- ---- Building blocks ----------------------------------------------------------------

local function W(name) return require("ui/widget/" .. name) end

-- plain (the strips, 1.3.5) and thick (the series strip's own book): bottom-aligned
local function coverWidget(rec, w, h, thick, plain, badge_size, show_where)
    local Blitbuffer = require("ffi/blitbuffer")
    local Screen = require("device").screen
    local FrameContainer = W("container/framecontainer")
    local inner
    local path = rec.cover_image_path
    if not fileExists(path) and O.coverPathFor and rec.bookorbit_id then
        local p = O.coverPathFor(rec.bookorbit_id, rec.bookorbit_cv)
        if fileExists(p) then path = p end
    end
    -- 1.3.7: no borders (in night mode they showed white), and the picture's box is the
    -- picture itself: KOReader flips an image's whole box for night mode, so empty
    -- room beside a narrow cover showed as white bars
    local border = 0
    local Geom = require("ui/geometry")
    local pic_w, pic_h = w, h -- the picture's own size, for the status badge
    if fileExists(path) then
        local img = W("imagewidget"):new{ file = path, width = w, height = h,
            scale_factor = 0, file_do_cache = false }
        pcall(function()
            img:getSize() -- renders it, scaled to fit
            local bb = img._bb
            local bw, bh = bb and bb:getWidth(), bb and bb:getHeight()
            if bw and bh and bw > 0 and bh > 0 and (bw < w or bh < h) then
                img.width, img.height = bw, bh
                img._offset_x, img._offset_y = 0, 0
            end
            if bw and bh and bw > 0 and bh > 0 then pic_w, pic_h = math.min(bw, w), math.min(bh, h) end
        end)
        -- centred in the space it was given (bottom-aligned in the strips, so the
        -- labels line up)
        local CenterContainer = W("container/centercontainer")
        inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, img }
        if plain or thick then
            local BottomContainer = W("container/bottomcontainer")
            inner = BottomContainer:new{ dimen = Geom:new{ w = w, h = h }, img }
        end
    else
        local Font = require("ui/font")
        inner = W("container/centercontainer"):new{
            dimen = Geom:new{ w = w - 2 * border, h = h - 2 * border },
            W("textboxwidget"):new{ text = tostring(rec.title or ""), face = Font:getFace("cfont", 12),
                width = w - 2 * border - Screen:scaleBySize(8), alignment = "center" },
        }
    end
    local framed = FrameContainer:new{ bordersize = border, padding = 0, margin = 0,
        background = (not fileExists(path)) and Blitbuffer.COLOR_LIGHT_GRAY or nil, inner }
    local text = badge_size and badgeText(rec)
    -- 1.3.16 (TK): On device / Queued is on the cover too (top), not a line under it,
    -- so a strip with a book on the device is no taller than one without
    local where = badge_size and show_where and stripLines(rec, tonumber(rec.bookorbit_id))[1]
    if not text and not where then return framed, pic_h end
    local Font = require("ui/font")
    local inset = Screen:scaleBySize(4)
    local bottom_aligned = (plain or thick) and true or false
    local pic_top = bottom_aligned and (h - pic_h) or math.floor((h - pic_h) / 2)
    local pic_bottom = pic_top + pic_h
    local function pill(str, dark)
        local label = W("textwidget"):new{ text = str, face = Font:getFace("cfont", badge_size), bold = true,
            fgcolor = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            max_width = math.max(10, pic_w - 2 * inset - Screen:scaleBySize(12)) }
        return FrameContainer:new{ bordersize = dark and 0 or 1, color = Blitbuffer.COLOR_BLACK,
            margin = 0, radius = Screen:scaleBySize(6),
            background = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE, padding = 0,
            padding_left = Screen:scaleBySize(6), padding_right = Screen:scaleBySize(6),
            padding_top = Screen:scaleBySize(2), padding_bottom = Screen:scaleBySize(2), label }
    end
    local group = W("overlapgroup"):new{ dimen = Geom:new{ w = w, h = h }, allow_mirroring = false, framed }
    -- the status: a dark pill along the bottom of the picture (night mode flips it with the page)
    if text then
        local p = pill(text, true)
        local ps = p:getSize()
        p.overlap_offset = { math.floor((w - ps.w) / 2), math.max(0, pic_bottom - ps.h - inset) }
        group[#group + 1] = p
    end
    -- where it is: a light pill at the top
    if where then
        local p = pill(where, false)
        local ps = p:getSize()
        p.overlap_offset = { math.floor((w - ps.w) / 2), math.max(0, pic_top + inset) }
        group[#group + 1] = p
    end
    return group, pic_h
end

-- a tappable book in a strip: its cover with a line under it
local function miniBook(rec, w, h, label, current, on_tap, sub)
    local Screen = require("device").screen
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local VerticalGroup = W("verticalgroup")
    local group = VerticalGroup:new{ align = "center",
        coverWidget(rec, w, h, current, not current, 10, true),
        W("verticalspan"):new{ width = Screen:scaleBySize(3) },
        W("textwidget"):new{ text = label, face = Font:getFace("cfont", current and 13 or 12),
            bold = current, max_width = w },
    }
    -- sub: one line or a list (1.3.9: status, then On device / Queued)
    for _i, line in ipairs(type(sub) == "table" and sub or { sub }) do
        group[#group + 1] = W("textwidget"):new{ text = line, face = Font:getFace("cfont", 11),
            fgcolor = require("ffi/blitbuffer").Color8(0x33), max_width = w }
    end
    local size = group:getSize()
    local box = W("container/inputcontainer"):new{ dimen = Geom:new{ w = w, h = size.h }, group }
    box.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return box.dimen end } } }
    function box:onTap()
        if on_tap then on_tap() end
        return true
    end
    return box
end

-- ---- The page -----------------------------------------------------------------------

local render -- below

local function close(refresh)
    if not page then return end
    local p = page
    page, page_id = nil, nil
    device_state = {}
    strip_sim = {} -- opened again, the strip starts on the series
    strip_owner = {} -- ... around the book
    stats_dirty = false
    if O.Stats then
        if O.Stats.isShown() then O.Stats.close(false) end
        O.Stats.reset()
    end
    UIManager:close(p, refresh ~= false and (O.flash and O.flash("bookpage") or "full") or nil)
end

local function again()
    if page and page_id then
        local id, ctx = page_id, page_ctx
        render(recordFor(id, { bookorbit_id = id }), ctx, true)
    end
end

again_for = function(id)
    if page and page_id == id then
        if O.Stats and O.Stats.isShown() then stats_dirty = true return end
        pcall(again)
    end
end

-- 2.1.0: Reading Stats for this book (Books > Book Page: Reading Stats), or nil
local function statsFor(rec)
    if not (O.cfg and O.cfg.bookpage_stats) then return nil end
    local ok, Stats = pcall(require, "orbitshelf_stats")
    if not ok then logger.warn(TAG, "Reading Stats:", tostring(Stats)) return nil end
    local id = tonumber(rec.bookorbit_id)
    local path = id and O.liveBookPath and O.liveBookPath(id)
    local st, pct, kobo_day = statusOf(rec)
    local finished = st == "read" or st == "skimmed"
    local fin_t
    if finished and type(kobo_day) == "string" then
        local y, mo, d = kobo_day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
        if y then fin_t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 } end
    end
    local got
    ok, got = pcall(Stats.forBook, rec, path, (not finished) and pct or nil, finished, fin_t)
    return ok and got or nil
end

local function legend()
    UIManager:show(W("infomessage"):new{
        text = _("On covers") .. "\n"
            .. _("• Arrow: not on this device") .. "\n"
            .. _("• Clock: waiting in the Queue (a download or a status, sent on the next Wi-Fi)") .. "\n"
            .. _("• Bookshelf's own badges: progress bar, bookmark = reading, tick = read, pause = on hold") .. "\n\n"
            .. _("In the series strip") .. "\n"
            .. _("Under each book: its number and status (Read, Reading, On Hold, Want), and On device or Queued. This book's number is in bold. Arrows show when the series has more than 5.") .. "\n\n"
            .. _("On this page") .. "\n"
            .. _("• Grey buttons don't apply to this book right now (Open and Remove need it on the device).") .. "\n"
            .. _("• Tap a book in a strip to see it here; swipe the series strip (or the arrows) for more.") .. "\n"
            .. _("• ✕ or ‹ OrbitShelf goes back to the shelf; a swipe down brings KOReader's top menu."),
    })
end

-- 2.1.15 (TK): the top bar and the buttons are drawn in render (the redesign): ‹ · Book |
-- Stats · More ▾ · ✕; the main button beside the cover; Queue / Status / Collection /
-- BookOrbit under it; the Files line. Downloads (the shelf's) is under More ▾.

render = function(rec, ctx, replace)
    local Device = require("device")
    local Screen = Device.screen
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local FrameContainer = W("container/framecontainer")
    local VerticalGroup = W("verticalgroup")
    local HorizontalGroup = W("horizontalgroup")
    local VerticalSpan = W("verticalspan")
    local HorizontalSpan = W("horizontalspan")
    local TextWidget = W("textwidget")
    local TextBoxWidget = W("textboxwidget")
    local Button = W("button")

    local id = tonumber(rec.bookorbit_id)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    local gap = Screen:scaleBySize(10)
    local inner_w = sw - 2 * pad
    local old = page
    local widget = W("container/inputcontainer"):new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        covers_fullscreen = true,
        orbitshelf_perf = "book page", -- 2.1.15: diagnostics times its first draw
    }
    page, page_id, page_ctx = widget, id, ctx or page_ctx

    -- ---- 2.1.15 (TK): the redesign. Colour from the sheets' palette (the Colour Theme),
    -- grey on a grey screen. Top: ‹ · Book | Stats · More ▾ · ✕. The cover with the
    -- details and one main button beside it; Queue / Status / Collection / BookOrbit
    -- under; the Files line (what downloads, by Book Type or this book's own pick).
    local Sheet = O.Sheet
    local P = Sheet.palette()
    local canvas, roundFill = Sheet.canvas, Sheet.roundFill
    local function px(v) return Screen:scaleBySize(v) end
    local INK, SOFT, PAPER = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_GRAY, Blitbuffer.COLOR_WHITE
    local ON_COLOUR = P.on or INK -- 2.1.22 (TK): words on a colour are black
    -- 2.1.24 (TK): outlined pills and chips edged in their colour only with Popup Style
    -- Rainbow; Standard edges them in black (white in night mode)
    local RAINBOW = Sheet.rainbow and Sheet.rainbow(P) or false
    -- 2.1.34 (TK): Popup Style Solid: every pill (filled or outlined) in its one colour
    local SOLID = Sheet.solid and Sheet.solid(P) or nil
    -- 2.1.36 (TK): Look › Pill Colours (off: plain pills, the words white on black)
    local PILLS = Sheet.pillsColoured and Sheet.pillsColoured(P) or false
    local function pillFill(hue) return PILLS and (SOLID or P.hue(hue)) or { v = INK } end
    local PILL_ON = PILLS and ON_COLOUR or PAPER
    -- 2.1.20 (TK: grey text is hard to read): small text near black
    local SUB = Blitbuffer.Color8(0x33)
    local function tw(s, size, bold, color, maxw)
        return TextWidget:new{ text = s, face = Font:getFace("cfont", size), bold = bold, fgcolor = color or INK, max_width = maxw }
    end
    local function tapBox(w, fn)
        local sz = w:getSize()
        local box = W("container/inputcontainer"):new{ dimen = Geom:new{ w = sz.w, h = sz.h }, w }
        box.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return box.dimen end } } }
        box.onTap = function(_, arg, ges) fn(ges, arg) return true end
        return box
    end
    -- a pill: filled (the main thing) or outlined, in a colour; greyed when not enabled
    local function pillW(label, hue, filled, w, h, size, enabled)
        enabled = enabled ~= false
        local t = tw(label, size or 14, true, (filled and enabled) and PILL_ON or (enabled and INK or SOFT),
            w and (w - px(16)) or nil)
        w = w or (t:getSize().w + px(30))
        h = h or px(34)
        local c = canvas(w, h, function(bb, x, y)
            if filled and enabled then
                roundFill(bb, x, y, w, h, math.floor(h / 2), pillFill(hue))
            else
                local edge = (PILLS and RAINBOW) and (SOLID or P.hue(hue)).v or INK
                bb:paintBorder(x, y, w, h, px(2), enabled and edge or SOFT, math.floor(h / 2))
            end
            t:paintTo(bb, x + math.floor((w - t:getSize().w) / 2), y + math.floor((h - t:getSize().h) / 2))
        end)
        return c
    end
    -- a colour box holding widgets that take taps (a canvas can't)
    local BgBox = W("container/widgetcontainer"):extend{}
    function BgBox:getSize() return Geom:new{ w = self.w, h = self.h } end
    function BgBox:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
        self.draw(bb, x, y, self.w, self.h)
        if self[1] then self[1]:paintTo(bb, x + self.padx, y + self.pady) end
    end
    local function card(child, w, hue, k)
        local padx, pady = px(12), px(8)
        local h = child:getSize().h + 2 * pady
        return BgBox:new{ w = w, h = h, padx = padx, pady = pady, child, draw = function(bb, x, y, cw, ch)
            -- 2.1.37 (TK): Look › Colour off: a plain card
            roundFill(bb, x, y, cw, ch, px(14), (P.colour and PILLS) and P.tint(hue, k) or { v = Blitbuffer.gray(0.06) })
        end }
    end
    -- a section's coloured tag and its name
    local function tagHead(text, hue, w, right)
        local t = tw(string.upper(text), 11, true, P.colour and INK or INK)
        local r = right and tw(right, 11, false, SUB) or nil
        local hh = math.max(t:getSize().h, r and r:getSize().h or 0)
        return canvas(w, hh, function(bb, x, y)
            roundFill(bb, x, y + math.floor(hh / 2) - px(3), px(14), px(6), px(3), P.colour and P.hue(hue) or { v = INK })
            t:paintTo(bb, x + px(20), y)
            if r then r:paintTo(bb, x + w - r:getSize().w, y + math.floor((hh - r:getSize().h) / 2)) end
        end)
    end

    local here = onDevice(id)
    local path = here and O.liveBookPath and O.liveBookPath(id) or nil
    local Q = O.Queue
    local queued = Q and Q.has(id)
    local wifi = O.isWifiOn()
    local sdata = statsFor(rec)

    -- top bar: ‹ · Book | Stats · More ▾ · ✕
    -- 2.1.17 (TK): "‹ OrbitShelf", a bigger target than the bare arrow
    local back_t = tw("‹ " .. _("OrbitShelf"), 15, true)
    local back_b = tapBox(canvas(back_t:getSize().w + px(12), px(40), function(bb, x, y)
        back_t:paintTo(bb, x + px(2), y + math.floor((px(40) - back_t:getSize().h) / 2))
    end), function() close() end)
    -- 2.1.17 (TK): a book not read on this Kobo (not downloaded) still has BookOrbit's stats
    local bo_stats = not sdata and O.cfg and O.cfg.bookpage_stats and O.Stats and O.Stats.hasBookOrbit
        and O.Stats.hasBookOrbit(rec) or false
    -- 2.1.28 (TK): Book | Stats | All Time
    local seg_w, seg_h = px(270), px(34)
    local b_t, s_t = tw(_("Book"), 14, true, PILL_ON), tw(_("Stats"), 14, true, (sdata or bo_stats) and INK or SOFT)
    local a_t = tw(_("All Time"), 14, true, INK)
    local function openMore()
        if O.BookMore and O.BookMore.more then
            O.BookMore.more(rec, path or rec.filepath, { legend = legend, close = function() close() end,
                downloads = (O.Bulk and O.Bulk.manage and id) and function()
                    O.Bulk.manage(rec, page_ctx and page_ctx.widget, function() pcall(again) end)
                end or nil })
        else
            legend()
        end
    end
    local function openStats(view)
        -- 2.1.35 (a Kobo crashed here): with Reading Stats off the stats page isn't loaded
        if not (O.cfg and O.cfg.bookpage_stats and O.Stats) then
            UIManager:show(W("infomessage"):new{ text = _("Reading Stats is off.\n\nTurn it on in OrbitShelf's Settings › Books › Book Page: Reading Stats."), timeout = 4 })
            return
        end
        if view ~= "all" and not sdata and not bo_stats then
            UIManager:show(W("infomessage"):new{ text = _("No reading stats for this book yet (on this device or saved from BookOrbit)."), timeout = 3 })
            return
        end
        O.Stats.show(rec, sdata, function()
            if stats_dirty then stats_dirty = false pcall(again) end
        end, function() close() end,
            { view = view, more = openMore, has_stats = (sdata or bo_stats) and true or false })
    end
    stats_opener = openStats
    local seg_box
    local third = math.floor(seg_w / 3)
    local seg = tapBox(canvas(seg_w, seg_h, function(bb, x, y)
        roundFill(bb, x, y, seg_w, seg_h, math.floor(seg_h / 2), P.colour and P.tint("blue", 0.18) or { v = Blitbuffer.gray(0.1) })
        roundFill(bb, x + px(3), y + px(3), third - px(3), seg_h - px(6), math.floor(seg_h / 2) - px(3),
            pillFill("blue"))
        local list = { b_t, s_t, a_t }
        for k = 1, 3 do
            local t = list[k]
            t:paintTo(bb, x + math.floor(third * (k - 0.5) - t:getSize().w / 2),
                y + math.floor((seg_h - t:getSize().h) / 2))
        end
    end), function(ges)
        local pos = ges and ges.pos
        local sx = seg_box and seg_box.dimen and seg_box.dimen.x
        local k = (pos and sx) and math.floor((pos.x - sx) / third) + 1 or 2
        if k <= 1 then return end
        openStats(k >= 3 and "all" or "stats")
    end)
    seg_box = seg
    local more_b = tapBox(pillW(_("More ▾"), "gold", false, nil, px(34), 13), openMore)
    local x_t = tw("\u{2715}", 20, true)
    local bx = tapBox(canvas(x_t:getSize().w + px(16), px(40), function(bb, x, y)
        x_t:paintTo(bb, x + px(8), y + math.floor((px(40) - x_t:getSize().h) / 2))
    end), function() close() end)
    local right_w = more_b:getSize().w + px(8) + bx:getSize().w
    local mid_l = math.floor((inner_w - seg_w) / 2) - back_b:getSize().w
    local top = HorizontalGroup:new{ align = "center",
        back_b, HorizontalSpan:new{ width = math.max(0, mid_l) }, seg,
        HorizontalSpan:new{ width = math.max(0, inner_w - back_b:getSize().w - mid_l - seg_w - right_w) },
        more_b, HorizontalSpan:new{ width = px(8) }, bx,
    }
    local function hline()
        return VerticalSpan:new{ width = 1 }
    end

    -- cover left, details right
    -- 2.1.15b: a smaller cover, so the strips and the description keep their room
    local cover_w = math.floor(inner_w * 0.29)
    local cover_h = math.floor(cover_w * 1.45)
    local info_w = inner_w - cover_w - gap
    local info = VerticalGroup:new{ align = "left" }
    local function add(w) info[#info + 1] = w end
    local function space(n) add(VerticalSpan:new{ width = Screen:scaleBySize(n) }) end
    -- the title: 2 lines at most, tap it for all of it
    do
        local full = tostring(rec.display_title or rec.title or "")
        local tb = TextBoxWidget:new{ text = full, face = Font:getFace("cfont", 22),
            bold = true, width = info_w, height = Screen:scaleBySize(62), height_overflow_show_ellipsis = true,
            height_adjust = true }
        add(tapBox(tb, function() UIManager:show(W("infomessage"):new{ text = full }) end))
    end
    local who = rec.author
    if (type(who) ~= "string" or who == "") and type(rec.authors) == "table" then who = rec.authors[1] end
    if type(who) == "string" and who ~= "" then
        space(2)
        add(tw(who, 17, false, SUB, info_w))
    end
    -- series · year · pages
    local t_lists = O.perfNow and O.perfNow()
    local series = seriesOf(rec)
    if O.perf then O.perf("book page: lists", t_lists) end
    local meta = {}
    if type(rec.series) == "string" and rec.series ~= "" then
        local n = tonumber(rec.series_index)
        local of = series and #series or nil
        meta[#meta + 1] = rec.series .. (n and (" " .. (of and of >= n and T(_("#%1 of %2"), tostring(n), of) or ("#" .. tostring(n)))) or "")
    end
    if rec.published then meta[#meta + 1] = tostring(rec.published):sub(1, 4) end
    local pages = tonumber(rec.pages) or tonumber(rec.page_count)
    if pages then meta[#meta + 1] = T(_("%1 pages"), pages) end
    if #meta > 0 then
        space(4)
        add(tw(table.concat(meta, "  ·  "), 13, false, SUB, info_w))
    end
    -- chips: rating, two genres, the language
    do
        local list = {}
        if tonumber(rec.rating) then list[#list + 1] = { "★ " .. string.format("%.1f", tonumber(rec.rating)), "gold" } end
        if type(rec.genres) == "table" then
            for i = 1, math.min(2, #rec.genres) do list[#list + 1] = { tostring(rec.genres[i]), i == 1 and "purple" or "pink" } end
        end
        if rec.lang then list[#list + 1] = { tostring(rec.lang), "teal" } end
        if #list > 0 then
            local row = HorizontalGroup:new{ align = "center" }
            local used = 0
            for _i, c in ipairs(list) do
                local t = tw(c[1], 11, true, INK)
                local cw2, ch2 = t:getSize().w + px(16), t:getSize().h + px(6)
                if used + cw2 > info_w then break end
                if used > 0 then row[#row + 1] = HorizontalSpan:new{ width = px(6) } used = used + px(6) end
                row[#row + 1] = canvas(cw2, ch2, function(bb, x, y)
                    if P.colour then roundFill(bb, x, y, cw2, ch2, math.floor(ch2 / 2), P.tint(c[2], 0.3)) end
                    bb:paintBorder(x, y, cw2, ch2, px(1), P.colour and P.hue(c[2]).v or INK, math.floor(ch2 / 2))
                    t:paintTo(bb, x + px(8), y + px(3))
                end)
                used = used + cw2
            end
            space(8)
            add(row)
        end
    end
    -- the status, its progress, and when it was last read / finished
    local st, pct, kobo_day = statusOf(rec)
    local head_bits = {}
    if here then
        head_bits[#head_bits + 1] = st and (STATUS_TEXT[st] or st) or _("On this device")
    else
        head_bits[#head_bits + 1] = _("Not on this device")
        if st then head_bits[#head_bits + 1] = STATUS_TEXT[st] or st end
    end
    if pct and pct > 0 and st ~= "read" then head_bits[#head_bits + 1] = math.floor(pct * 100 + 0.5) .. "%" end
    space(8)
    add(tw(table.concat(head_bits, "  ·  "), 15, true, INK, info_w))
    if pct and pct > 0 and pct < 1 then
        space(5)
        local pw, ph = info_w, px(8)
        add(canvas(pw, ph, function(bb, x, y)
            roundFill(bb, x, y, pw, ph, px(4), P.colour and P.track or { v = Blitbuffer.gray(0.2) })
            roundFill(bb, x, y, math.max(ph, math.floor(pw * pct)), ph, px(4), P.colour and P.hue("green") or { v = INK })
        end))
    end
    local sub_bits = {}
    local bo_t = tonumber(rec.last_read_time)
    local ko_t
    local RH = path and package.loaded["readhistory"]
    if RH and type(RH.hist) == "table" then
        for _i, hh in ipairs(RH.hist) do
            if type(hh) == "table" and hh.file == path then ko_t = tonumber(hh.time) break end
        end
    end
    if st == "read" or st == "skimmed" then
        local y, mo, d
        if type(kobo_day) == "string" then y, mo, d = kobo_day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)") end
        if y and mo and d then
            local t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }
            if shortDate(t) then sub_bits[#sub_bits + 1] = T(_("finished %1"), shortDate(t)) end
        end
    end
    if ko_t and (not bo_t or ko_t >= bo_t) then
        if shortDate(ko_t) then sub_bits[#sub_bits + 1] = T(_("last read %1"), shortDate(ko_t)) end
    elseif bo_t and shortDate(bo_t) then
        sub_bits[#sub_bits + 1] = T(_("last read %1 (BookOrbit)"), shortDate(bo_t))
    end
    if queued then sub_bits[#sub_bits + 1] = _("queued for Wi-Fi") end
    -- this book's own pick (the Files line)
    local pick = O.bookPick and O.bookPick(id) or nil
    local PICK_WORDS = { text = _("text only"), narration = _("with narration"), both = _("text + with narration") }
    if pick and (pick.mode or pick.file) then
        sub_bits[#sub_bits + 1] = T(_("this book only: %1"), pick.mode and PICK_WORDS[pick.mode] or _("another file"))
    end
    if #sub_bits > 0 then
        space(4)
        add(tw(table.concat(sub_bits, "  ·  "), 12, false, SUB, info_w))
    end

    -- the files: what BookOrbit has, what's here, what Download takes
    local AUDIO = { m4b = true, mp3 = true, m4a = true, opus = true, ogg = true, flac = true, aac = true }
    local okU, CU = pcall(require, "bookorbit_catalog_util")
    local function supported(fmt) return not okU or CU.isSupportedFormat(fmt) end
    local bt = (O.cfg or {}).readalong_download or "text"
    local bt_shown = bt == "bookorbit" and "text" or bt
    local mode = pick and pick.mode or bt_shown
    local narr_here
    do
        local m = G_reader_settings:readSetting("orbitshelf_narrated_copies")
        local p2 = type(m) == "table" and m[tostring(id)]
        narr_here = type(p2) == "string" and fileExists(p2) or false
    end
    local file_chips = {}
    local dl_size = 0
    local primary_id
    for _i, f in ipairs(type(rec.files) == "table" and rec.files or {}) do
        if f.role == "primary" and supported(f.fmt) then primary_id = primary_id or f.id end
    end
    for _i, f in ipairs(type(rec.files) == "table" and rec.files or {}) do
        if not primary_id and supported(f.fmt) and not AUDIO[f.fmt] then primary_id = f.id end
    end
    local function savePick(p2) if O.setBookPick then O.setBookPick(id, p2) end pcall(again) end
    for _i, f in ipairs(type(rec.files) == "table" and rec.files or {}) do
        local FMT = string.upper(f.fmt)
        local size = f.size and O.mb and O.mb(f.size) or nil
        if AUDIO[f.fmt] then
            file_chips[#file_chips + 1] = { label = FMT .. " · " .. _("can't play"), hue = "orange", off = true }
        elseif f.fmt == "epub" and f.ra then
            local want_t = mode == "text" or mode == "both"
            local want_n = mode == "narration" or mode == "both"
            local function toggle(which)
                local t2, n2 = want_t, want_n
                if which == "t" then t2 = not t2 else n2 = not n2 end
                if not t2 and not n2 then return end
                local m2 = (t2 and n2) and "both" or (t2 and "text" or "narration")
                local p2 = pick and { file = pick.file } or {}
                p2.mode = m2 ~= bt_shown and m2 or nil
                savePick(p2)
            end
            file_chips[#file_chips + 1] = { label = FMT, hue = "blue", on = want_t, here = here and (not narr_here or path ~= nil),
                tap = function() toggle("t") end }
            file_chips[#file_chips + 1] = { label = "♪ " .. _("Read-along") .. (size and (" · " .. size) or ""), hue = "purple",
                on = want_n, here = narr_here, tap = function() toggle("n") end }
            if want_n and f.size then dl_size = dl_size + f.size end
        elseif supported(f.fmt) then
            local chosen = (pick and pick.file) and (pick.file == f.id) or (not (pick and pick.file) and f.id == primary_id)
            file_chips[#file_chips + 1] = { label = FMT .. (size and (" · " .. size) or ""), hue = "blue", on = chosen,
                here = here and chosen, tap = function()
                    local p2 = pick and { mode = pick.mode } or {}
                    p2.file = f.id ~= primary_id and f.id or nil
                    savePick(p2)
                end }
            if chosen and f.size then dl_size = dl_size + f.size end
        else
            file_chips[#file_chips + 1] = { label = FMT .. " · " .. _("can't open"), hue = "orange", off = true }
        end
    end

    -- the main button
    local main
    local main_w, main_h = info_w, px(40)
    if here then
        main = tapBox(pillW((pct and pct > 0 and st ~= "read") and _("▶  Continue Reading") or _("▶  Start Reading"),
            "green", true, main_w, main_h, 16), function()
            close()
            require("apps/reader/readerui"):showReader(path)
        end)
    elseif queued then
        main = tapBox(pillW(_("Remove From Queue"), "teal", false, main_w, main_h, 16), function() Q.removeDownload(id) again() end)
    elseif Q and not wifi then
        main = tapBox(pillW(_("Queue Download") .. "  ·  " .. _("no Wi-Fi"), "teal", true, main_w, main_h, 15),
            function() Q.addDownload(rec) again() end)
    else
        local lab = _("↓  Download")
        if mode == "both" and #file_chips > 0 then lab = _("↓  Download 2 files") end
        if dl_size > 0 and O.mb then lab = lab .. "  ·  " .. O.mb(dl_size) end
        main = tapBox(pillW(lab, "blue", true, main_w, main_h, 16), function()
            O.downloadBookOrbitBook(rec, function() again() end)
        end)
    end
    space(10)
    add(main)

    -- Queue / Status / Collection / BookOrbit, under the cover
    local row_w = math.floor((inner_w - 3 * px(8)) / 4)
    local acts = HorizontalGroup:new{ align = "center" }
    local function act(i, label, hue, enabled, fn)
        if i > 1 then acts[#acts + 1] = HorizontalSpan:new{ width = px(8) } end
        local p2 = pillW(label, hue, false, row_w, px(32), 13, enabled)
        acts[#acts + 1] = enabled and tapBox(p2, fn) or p2
    end
    if here then
        act(1, _("Remove"), "red", true, function()
            O.removeFromDevice({ bookorbit_id = id, filepath = path or rec.filepath, title = rec.title }, again)
        end)
    else
        act(1, queued and _("Unqueue") or _("Queue"), "teal", Q ~= nil, function()
            if queued then Q.removeDownload(id) else Q.addDownload(rec) end
            again()
        end)
    end
    act(2, _("Status ▾"), "gold", O.pickReadStatus ~= nil, function() O.pickReadStatus(id, rec.display_title or rec.title) end)
    act(3, _("Collection +"), "pink", O.canAddToCollection and O.canAddToCollection(rec) and true or false,
        function() O.addToCollection(rec) end)
    act(4, _("BookOrbit ↗"), "blue", true, function() O.openInBookOrbit(rec) end)

    -- the Files line
    local free = O.freeBytes and O.freeBytes()
    local BT_NAMES = { text = _("Text Only"), narration = _("With Narration"), both = _("Both"), bookorbit = _("Same As BookOrbit") }
    local files_box
    do
        local fw = inner_w - px(24)
        local right = T(_("Book Type: %1"), BT_NAMES[bt] or bt) .. (free and ("  ·  " .. T(_("%1 free"), O.mb(free))) or "")
            .. (#file_chips > 0 and ("  ·  " .. _("tap a file: this book only")) or "")
        local g2 = VerticalGroup:new{ align = "left", tagHead(_("Files"), "blue", fw, right) }
        g2[#g2 + 1] = VerticalSpan:new{ width = px(6) }
        if #file_chips == 0 then
            g2[#g2 + 1] = tw(_("BookOrbit's list of files shows here after the shelf next refreshes."), 12, false, SUB, fw)
        else
            local row = HorizontalGroup:new{ align = "center" }
            local used = 0
            for _i, c in ipairs(file_chips) do
                local label = ((c.here and c.on) and "✓ " or "") .. c.label
                local t = tw(label, 12, true, (c.on and P.colour) and ON_COLOUR or ((c.on and not P.colour) and PAPER or (c.off and SOFT or INK)))
                local cw2, ch2 = t:getSize().w + px(22), t:getSize().h + px(12)
                if used + cw2 > fw then break end
                local chip = canvas(cw2, ch2, function(bb, x, y)
                    if c.on then
                        roundFill(bb, x, y, cw2, ch2, math.floor(ch2 / 2), P.colour and P.hue(c.hue) or { v = INK })
                    else
                        local edge = (P.colour and RAINBOW) and P.hue(c.hue).v or INK
                        bb:paintBorder(x, y, cw2, ch2, px(2), c.off and SOFT or edge, math.floor(ch2 / 2))
                    end
                    t:paintTo(bb, x + px(11), y + px(6))
                end)
                if used > 0 then row[#row + 1] = HorizontalSpan:new{ width = px(8) } used = used + px(8) end
                row[#row + 1] = c.tap and tapBox(chip, c.tap) or chip
                used = used + cw2
            end
            g2[#g2 + 1] = row
        end
        files_box = card(g2, inner_w, "blue", P.night and 0.16 or 0.1)
    end
    local buttons = VerticalGroup:new{ align = "left", acts, VerticalSpan:new{ width = px(8) }, files_box }

    local cover = coverWidget(rec, cover_w, cover_h, false, nil, 15)
    local hero = HorizontalGroup:new{ align = "top",
        cover, HorizontalSpan:new{ width = gap }, info }

    -- 2.0.0: Similar books are their own section, one tap ("Similar ›") or swipe left
    -- away from the series strip or More by; "‹ Series" / "‹ More by" or a swipe right
    -- goes back. Opened, the page always starts on the series (or More by).
    local sims = {}
    local t_sims = O.perfNow and O.perfNow()
    do
        local in_series = {}
        for _i, r in ipairs(series or {}) do in_series[tonumber(r.bookorbit_id) or -1] = true end
        for _i, r in ipairs(similarBooks(rec, 12) or {}) do
            local rid = tonumber(r.bookorbit_id)
            if rid and rid ~= id and not in_series[rid] then sims[#sims + 1] = r end
            if #sims >= 8 then break end
        end
    end
    if O.perf then O.perf("book page: lists", t_sims) end
    local sim_mode = #sims > 0 and strip_sim[id] == true
    local function setSim(on)
        strip_sim[id] = on and true or nil
        again()
    end
    -- a section heading, with a small button on the right
    local function headRow(text, btn_text, on_btn)
        if not btn_text then
            return tagHead(text, "pink", inner_w)
        end
        local btn = Button:new{ text = btn_text, bordersize = 0, padding = 0, margin = 0,
            text_font_face = "cfont", text_font_size = 14, text_font_bold = false,
            callback = on_btn, show_parent = widget }
        local bw = btn:getSize().w
        local title = tagHead(text, "pink", math.max(1, inner_w - bw - gap))
        return HorizontalGroup:new{ align = "center", title,
            HorizontalSpan:new{ width = math.max(0, inner_w - title:getSize().w - bw) }, btn }
    end

    -- the series strip: 5 at a time, around this book; swipe or the arrows for more
    local strip, strip_head
    local SHOW = 5
    if series and #series > 1 and not sim_mode then
        local key = seriesKey(rec)
        local mine = 1
        for i, r in ipairs(series) do if tonumber(r.bookorbit_id) == id then mine = i end end
        -- around this book when its page opens; after that where the swipes / arrows
        -- put it (not back around this book, or a page without it could never show)
        local from = strip_from[key]
        if not from or strip_owner[key] ~= id then
            from = math.max(1, math.min(mine - 2, #series - SHOW + 1))
        end
        strip_owner[key] = id
        from = math.max(1, math.min(from, math.max(1, #series - SHOW + 1)))
        strip_from[key] = from
        local read_n = 0
        for _i, r in ipairs(series) do
            local s = statusOf(r)
            if s == "read" or s == "skimmed" then read_n = read_n + 1 end
        end
        local arrow_w = Screen:scaleBySize(28)
        local many = #series > SHOW
        local avail = inner_w - (many and 2 * arrow_w or 0)
        local mw = math.floor((avail - (SHOW - 1) * gap) / SHOW)
        local mh = math.floor(mw * 1.2)
        local row = HorizontalGroup:new{ align = "top" }
        local function shift(by)
            strip_from[key] = math.max(1, math.min(from + by, #series - SHOW + 1))
            again()
        end
        if many then
            row[#row + 1] = Button:new{ text = "‹", bordersize = 0, width = arrow_w, enabled = from > 1,
                callback = function() shift(-SHOW) end, show_parent = widget }
        end
        for i = from, math.min(#series, from + SHOW - 1) do
            local r = series[i]
            local rid = tonumber(r.bookorbit_id)
            -- 1.3.9: BookOrbit's status words (Read, On Hold, Abandoned, Want To Read ...)
            -- on their own line under #N, then On device / Queued
            local label = "#" .. tostring(tonumber(r.series_index))
            if i > from then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = miniBook(r, mw, mh, label, rid == id, function()
                if rid ~= id then render(recordFor(rid, r), page_ctx, true) end
            end)
        end
        if many then
            row[#row + 1] = Button:new{ text = "›", bordersize = 0, width = arrow_w,
                enabled = from + SHOW - 1 < #series, callback = function() shift(SHOW) end, show_parent = widget }
        end
        strip = W("container/inputcontainer"):new{ dimen = Geom:new{ w = inner_w, h = row:getSize().h }, row }
        strip.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = function() return strip.dimen end } } }
        function strip:onSwipe(_arg, ges)
            local dir = ges and ges.direction
            if dir == "west" and from + SHOW - 1 < #series then shift(SHOW) return true end
            -- past the series' last books: Similar books
            if dir == "west" and #sims > 0 then setSim(true) return true end
            if dir == "east" and from > 1 then shift(-SHOW) return true end
            return false
        end
        strip_head = headRow(tostring(rec.series) .. "  ·  " .. T(_("%1 of %2 read"), read_n, #series)
                .. (many and ("  ·  " .. T(_("%1–%2 of %3"), from, math.min(#series, from + SHOW - 1), #series)) or ""),
            #sims > 0 and _("Similar ›") or nil, function() setSim(true) end)
    end

    -- the fixed parts' height, so the description gets what's left (3 lines at least)
    local function h(w) return w and w:getSize().h or 0 end
    local s4, s8, s12 = Screen:scaleBySize(4), Screen:scaleBySize(8), Screen:scaleBySize(12)
    local fixed = pad + h(top) + s4 + 1 + s12 + math.max(cover_h, h(info)) + s12 + (buttons and (h(buttons) + s12) or 0)
    if strip then fixed = fixed + h(strip_head) + s4 + 1 + s8 + h(strip) + s12 end
    local desc_face = Font:getFace("cfont", 16)
    -- the description box's own line height (two lines, halved)
    local line_h = math.max(1, math.floor(TextBoxWidget:new{ text = "A\nA", face = desc_face, width = inner_w }:getSize().h / 2))
    -- 2.1.12 (TK): the box shows the description only (Stats is in the top bar)
    local desc_head
    desc_head = tagHead(_("Description"), "gold", inner_w)
    local desc_room = sh - fixed - pad - h(desc_head) - s4 - 1 - s8

    -- more by the author. With the series strip: one row of 4 when there's still room
    -- for 4 lines of description. Without one (1.3.4): it takes the strip's place,
    -- two rows of 4 when they fit (else one), the description keeping 3 lines.
    local more, more_head
    local no_strip = strip == nil
    local more_books, more_title, more_btn, more_swipe
    if sim_mode then
        -- 2.0.0: Similar books in their own section, back to the series / More by
        more_books, more_title = sims, _("Similar books")
        local back = (series and #series > 1) and _("‹ Series") or _("‹ More by")
        more_btn = { back, function() setSim(false) end }
        more_swipe = { east = function() setSim(false) end }
    else
        local t_more = O.perfNow and O.perfNow()
        more_books = moreByAuthor(rec, no_strip and 8 or 4, not no_strip)
        if O.perf then O.perf("book page: lists", t_more) end
        -- 1.3.8: no series and nothing else by the author: Similar books (BookOrbit's own
        -- picks once looked up, else the saved library's closest by genre)
        more_title = T(_("More by %1"), tostring(who or ""))
        if no_strip and #more_books == 0 then
            more_books = similarBooks(rec, 8)
            more_title = _("Similar books")
        elseif no_strip and #sims > 0 then
            -- 2.0.0: More by first, Similar books one tap or swipe left away
            more_btn = { _("Similar ›"), function() setSim(true) end }
            more_swipe = { west = function() setSim(true) end }
        end
    end
    if #more_books > 0 then
        local mw = math.floor((inner_w - 3 * gap) / 4)
        local mh = math.floor(mw * (no_strip and 1.05 or 0.85))
        local function rowOf(a, b)
            local row = HorizontalGroup:new{ align = "top" }
            for i = a, math.min(b, #more_books) do
                local r = more_books[i]
                if i > a then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                local rid = tonumber(r.bookorbit_id)
                row[#row + 1] = miniBook(r, mw, mh, tostring(r.title or ""), false, function()
                    render(recordFor(rid, r), page_ctx, true)
                end)
            end
            return row
        end
        more_head = headRow(more_title, more_btn and more_btn[1], more_btn and more_btn[2])
        -- 2.1.15b: the description keeps 2 lines (was 3 or 4): the page's top is taller now
        local keep = 2 * line_h
        local head_need = h(more_head) + s4 + 1 + s8 + s12
        -- 2.0.0: a swipe on the section switches More by <-> Similar books
        local function swipeable(g)
            if not (g and more_swipe) then return g end
            local box = W("container/inputcontainer"):new{ dimen = Geom:new{ w = inner_w, h = g:getSize().h }, g }
            box.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = function() return box.dimen end } } }
            function box:onSwipe(_arg, ges)
                local fn = more_swipe[ges and ges.direction]
                if fn then fn() return true end
                return false
            end
            return box
        end
        local one = swipeable(rowOf(1, 4))
        local two = #more_books > 4 and swipeable(VerticalGroup:new{ align = "left", rowOf(1, 4),
            VerticalSpan:new{ width = gap }, rowOf(5, 8) }) or nil
        if two and desc_room - head_need - h(two) >= keep then
            more = two
        elseif desc_room - head_need - h(one) >= keep then
            more = one
        end
        if more then
            desc_room = desc_room - head_need - h(more)
        else
            more_head = nil
        end
    end

    local desc = rec.description
    if type(desc) ~= "string" or desc == "" then desc = nil end
    local body, body_text, body_lines
    local function makeBody(lines)
        return TextBoxWidget:new{ text = body_text, face = desc_face, width = inner_w,
            height = lines * line_h, height_overflow_show_ellipsis = true }
    end
    if desc and desc_room >= line_h then
        local text = desc:gsub("\r", ""):gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n"):gsub("<[^>]+>", "")
            :gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#0*39;", "'"):gsub("&amp;", "&")
            :gsub("\n\n+", "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        local lines = math.max(1, math.floor(desc_room / line_h))
        body_text, body_lines = text, lines
        body = TextBoxWidget:new{ text = text, face = desc_face, width = inner_w, height = lines * line_h,
            height_overflow_show_ellipsis = true }
    else
        body = TextWidget:new{ text = O.isWifiOn() and _("Tap here to look up the description in BookOrbit.")
            or _("No description saved (Offline Library keeps them)."), face = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.Color8(0x33), max_width = inner_w }
    end

    -- 1.3.7: tapping the description opens all of it (Book Description); 2.1.0:
    -- on the stats side, the stats page. A swipe turns the box over.
    local function tappable(w)
        local sz = w:getSize()
        local box = W("container/inputcontainer"):new{ dimen = Geom:new{ w = inner_w, h = sz.h }, w }
        box.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return box.dimen end } } }
        function box:onTap()
            O.showDescription(rec)
            return true
        end
        return box
    end
    local col = VerticalGroup:new{ align = "left",
        top, VerticalSpan:new{ width = s4 }, hline(), VerticalSpan:new{ width = s12 },
        hero, VerticalSpan:new{ width = s12 },
    }
    if buttons then
        col[#col + 1] = buttons
        col[#col + 1] = VerticalSpan:new{ width = s12 }
    end
    col[#col + 1] = desc_head
    col[#col + 1] = VerticalSpan:new{ width = s4 }
    col[#col + 1] = hline()
    col[#col + 1] = VerticalSpan:new{ width = s8 }
    col[#col + 1] = tappable(body)
    col[#col + 1] = VerticalSpan:new{ width = s12 }
    if strip then
        col[#col + 1] = strip_head
        col[#col + 1] = VerticalSpan:new{ width = s4 }
        col[#col + 1] = hline()
        col[#col + 1] = VerticalSpan:new{ width = s8 }
        col[#col + 1] = strip
        col[#col + 1] = VerticalSpan:new{ width = s12 }
    end
    if more then
        col[#col + 1] = more_head
        col[#col + 1] = VerticalSpan:new{ width = s4 }
        col[#col + 1] = hline()
        col[#col + 1] = VerticalSpan:new{ width = s8 }
        col[#col + 1] = more
    end
    local body_at
    for i, c in ipairs(col) do if c == body or c[1] == body then body_at = i end end
    -- measured, not guessed (1.3.5): the description gets exactly the room that's left
    -- (more lines when there's space, fewer when it's tight); under 2 lines, More by
    -- goes and it's measured again
    local room = sh - 2 * pad
    local function fit()
        if not (body_lines and body_at) then return end
        local rest = col:getSize().h - col[body_at]:getSize().h
        local lines = math.floor((room - rest) / line_h)
        if lines < 2 and more then
            for _i = 1, 5 do table.remove(col) end
            more = nil
            if col.resetLayout then col:resetLayout() end
            rest = col:getSize().h - col[body_at]:getSize().h
            lines = math.floor((room - rest) / line_h)
        end
        lines = math.max(1, lines)
        if lines ~= body_lines then
            body_lines = lines
            col[body_at] = tappable(makeBody(lines))
            if col.resetLayout then col:resetLayout() end
        end
    end
    fit()
    if more and col:getSize().h > room then
        for _i = 1, 5 do table.remove(col) end
        more = nil
        if col.resetLayout then col:resetLayout() end
        fit()
    end
    widget[1] = FrameContainer:new{
        dimen = Geom:new{ w = sw, h = sh },
        width = sw, height = sh,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0, padding = pad, padding_top = pad, margin = 0,
        col,
    }
    widget.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    function widget:onClose() close() return true end
    -- a swipe down: KOReader's top menu over the page (2.1.23, TK; it used to close the page)
    widget.ges_events = { SwipeClose = { GestureRange:new{ ges = "swipe", range = widget.dimen } } }
    function widget:onSwipeClose(_arg, ges)
        if ges and ges.direction == "south" then
            if not (O.showTopMenu and O.showTopMenu()) then close() end
            return true
        end
        return false
    end

    -- 1.3.6: a full flash only when the page opens (and closes); swiping the strip,
    -- tapping another book or a button's change redraws it without the flash
    if replace and old then
        -- 2.1.17 (TK): another book, series <-> similar, a strip's swipe: a quick flash by
        -- default (it left ghosting with none); Look › Screen Flashes
        UIManager:close(old)
        UIManager:show(widget, O.flash and O.flash("bookpage_change") or "ui")
    else
        UIManager:show(widget, O.flash and O.flash("bookpage") or "full")
    end
end

-- open the page for a book (a trimmed shelf record is fine: the saved one is used)
function BookPage.show(book, ctx)
    local id = idOf(book)
    if not id then return false end
    local ok, err = pcall(render, recordFor(id, book), ctx, page ~= nil)
    if not ok then
        logger.warn(TAG, "Book Page:", tostring(err))
        page, page_id = nil, nil
        if O.showNotOnDevice then O.showNotOnDevice(book, ctx) end
        return false
    end
    return true
end

-- something about the book changed (a status saved, the queue, a download): drawn again
function BookPage.changed(id)
    device_state = {}
    if page and (id == nil or tonumber(id) == page_id) then
        if O.Stats and O.Stats.isShown() then stats_dirty = true return end
        pcall(again)
    end
end

function BookPage.isShown() return page ~= nil end

-- 2.1.28: the shown page's Stats (Your Year's book popup: Stats)
function BookPage.openStats(view)
    if page and stats_opener then pcall(stats_opener, view or "stats") end
end

-- going to sleep (1.3.10): the page closes, so waking up never finds it left
-- behind the home screen (it showed glitched over the shelf after). No
-- refresh: the sleep screen draws over it.
function BookPage.close()
    if page then close(false) end
end

return BookPage
