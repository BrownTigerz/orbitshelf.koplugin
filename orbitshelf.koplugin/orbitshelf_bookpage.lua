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
            fgcolor = require("ffi/blitbuffer").COLOR_DARK_GRAY, max_width = w }
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
    UIManager:close(p, refresh ~= false and "full" or nil)
end

local function again()
    if page and page_id then
        local id, ctx = page_id, page_ctx
        render(recordFor(id, { bookorbit_id = id }), ctx, true)
    end
end

again_for = function(id)
    if page and page_id == id then pcall(again) end
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
            .. _("• X or swipe down goes back to the shelf."),
    })
end

-- 1.3.12: what was under More is the top bar's left side (TK): Bulk Download…
-- (or Stop), Bulk Remove…, Help. Only X on the right. 1.3.13: no Description button
-- (tapping the description opens all of it).
local function topActions(rec)
    local acts = {}
    -- 1.3.4: the Bulk window opens over the page; its X comes back here (only the
    -- page's own X closes the page)
    local widget = page_ctx and page_ctx.widget
    -- 1.3.14: both, whatever this book is (TK: no Bulk Remove on a book not on the device)
    local bulk = O.Bulk and O.Bulk.row(rec, widget, nil, true)
    if bulk then acts[#acts + 1] = bulk end
    local brem = O.Bulk and O.Bulk.removeRow(rec, widget, nil, true)
    if brem then acts[#acts + 1] = brem end
    acts[#acts + 1] = { text = _("Help"), callback = function() legend() end }
    -- 1.3.15 (TK): no "…" up here (Bulk Download / Bulk Remove)
    for _i, act in ipairs(acts) do
        if type(act.text) == "string" then act.text = act.text:gsub("…$", "") end
    end
    return acts
end

-- compact (1.3.18): beside the cover, 3 rows of 2, "Open In BookOrbit" is "BookOrbit"
local function buttonRows(rec, width, compact)
    local id = tonumber(rec.bookorbit_id)
    local here = onDevice(id)
    local path = O.liveBookPath and O.liveBookPath(id)
    local Q = O.Queue
    local queued = Q and Q.has(id)
    local wifi = O.isWifiOn()
    local get
    if here then
        get = { text = _("Download"), enabled = false, callback = function() end }
    elseif queued then
        get = { text = _("Remove Queue"), callback = function() Q.removeDownload(id) again() end }
    elseif Q and not wifi then
        get = { text = _("Queue"), callback = function() Q.addDownload(rec) again() end }
    else
        get = { text = _("Download"), callback = function()
            O.downloadBookOrbitBook(rec, function() again() end)
        end }
    end
    local row1 = {
        get,
        { text = _("Open"), enabled = path ~= nil, callback = function()
            close()
            require("apps/reader/readerui"):showReader(path)
        end },
        -- 1.3.21 (TK): the page stays open under BookOrbit, so closing BookOrbit comes back here
        { text = _("Open In BookOrbit"), callback = function() O.openInBookOrbit(rec) end },
    }
    local row2 = {
        { text = _("Remove"), enabled = here and true or false, callback = function()
            -- the page is drawn again only once it's removed, so the question stays on top
            O.removeFromDevice({ bookorbit_id = id, filepath = path or rec.filepath, title = rec.title }, again)
        end },
        { text = _("Reading Status"), callback = function()
            if O.pickReadStatus then O.pickReadStatus(id, rec.display_title or rec.title) end
        end },
        { text = _("Collection"), enabled = O.canAddToCollection and O.canAddToCollection(rec) and true or false,
          callback = function() O.addToCollection(rec) end },
    }
    if compact then
        row1[3].text = _("BookOrbit")
        local rows = {
            { row1[1], row1[2] },
            { row2[2], row2[3] },
            { row1[3], row2[1] },
        }
        return W("buttontable"):new{ width = width, buttons = rows, zero_sep = true, show_parent = page }
    end
    return W("buttontable"):new{ width = width, buttons = { row1, row2 }, zero_sep = true, show_parent = page }
end

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
    local LineWidget = W("linewidget")

    local id = tonumber(rec.bookorbit_id)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(14)
    local gap = Screen:scaleBySize(10)
    local inner_w = sw - 2 * pad
    local old = page
    local widget = W("container/inputcontainer"):new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        covers_fullscreen = true,
    }
    page, page_id, page_ctx = widget, id, ctx or page_ctx

    -- top bar (1.3.12): Bulk Download… · Bulk Remove… · Help on the
    -- left, X on the right (was "Book" with a More menu)
    local function topButton(text, cb, size, enabled)
        return Button:new{ text = text, bordersize = 0, padding = Screen:scaleBySize(6),
            text_font_size = size or 20, callback = cb, show_parent = widget,
            enabled = enabled ~= false }
    end
    local bx = topButton("\u{2715}", function() close() end)
    -- 1.3.20 (TK): where the book is and the free space, beside the X
    local here = onDevice(id)
    local where = here and _("On this device") or _("Not on device")
    if not here and O.Queue and O.Queue.has(id) then where = _("Not on device · Queued") end
    local free = O.freeBytes and O.freeBytes()
    if free then where = where .. " · " .. T(_("%1 free"), O.mb(free)) end
    local where_w = TextWidget:new{ text = where, face = Font:getFace("cfont", 13), bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = math.floor(inner_w * 0.42) }
    local where_gap = Screen:scaleBySize(8)
    local left_room = inner_w - bx:getSize().w - where_w:getSize().w - where_gap
    local acts = topActions(rec)
    local left
    for size = 18, 13, -1 do
        left = HorizontalGroup:new{ align = "center" }
        for i, a in ipairs(acts) do
            if i > 1 then left[#left + 1] = HorizontalSpan:new{ width = Screen:scaleBySize(4) } end
            left[#left + 1] = topButton(a.text, a.callback, size, a.enabled)
        end
        if left:getSize().w <= left_room then break end
    end
    local top = HorizontalGroup:new{ align = "center",
        left,
        HorizontalSpan:new{ width = math.max(0, left_room - left:getSize().w) },
        where_w, HorizontalSpan:new{ width = where_gap },
        bx,
    }
    local function hline()
        return LineWidget:new{ dimen = Geom:new{ w = inner_w, h = Screen:scaleBySize(1) },
            background = Blitbuffer.COLOR_BLACK }
    end

    -- cover left, details right
    local cover_w = math.floor(inner_w * 0.34)
    local cover_h = math.floor(cover_w * 1.5)
    local info_w = inner_w - cover_w - gap
    local info = VerticalGroup:new{ align = "left" }
    local function add(w) info[#info + 1] = w end
    local function space(n) add(VerticalSpan:new{ width = Screen:scaleBySize(n) }) end
    -- the title: 2 lines at most (1.3.18), tap it for all of it
    do
        local full = tostring(rec.display_title or rec.title or "")
        local tb = TextBoxWidget:new{ text = full, face = Font:getFace("cfont", 24),
            bold = true, width = info_w, height = Screen:scaleBySize(90), height_overflow_show_ellipsis = true,
            height_adjust = true }
        local box = W("container/inputcontainer"):new{ dimen = Geom:new{ w = info_w, h = tb:getSize().h }, tb }
        box.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = function() return box.dimen end } } }
        function box:onTap()
            UIManager:show(W("infomessage"):new{ text = full })
            return true
        end
        add(box)
    end
    local who = rec.author
    if (type(who) ~= "string" or who == "") and type(rec.authors) == "table" then who = rec.authors[1] end
    if type(who) == "string" and who ~= "" then
        space(4)
        add(TextWidget:new{ text = who, face = Font:getFace("cfont", 17), max_width = info_w })
    end
    local series = seriesOf(rec)
    if type(rec.series) == "string" and rec.series ~= "" then
        space(6)
        local n = tonumber(rec.series_index)
        local of = series and #series or nil
        local s = rec.series
        if n then
            s = s .. " · " .. (of and of >= n and T(_("Book %1 of %2"), tostring(n), of) or T(_("Book %1"), tostring(n)))
        end
        add(TextWidget:new{ text = s, face = Font:getFace("cfont", 15), max_width = info_w })
    end
    -- status (and its progress), from BookOrbit or waiting in the Queue, and when it was
    -- last read: the newer of this Kobo's history and BookOrbit's (1.3.20: one line;
    -- where it is and the free space moved to the top bar)
    local st, pct, kobo_day = statusOf(rec)
    local chips = {}
    if st then chips[#chips + 1] = STATUS_TEXT[st] or st end
    if pct and pct > 0 and st ~= "read" then chips[#chips + 1] = math.floor(pct * 100 + 0.5) .. "%" end
    if O.Queue and O.Queue.statusOf(id) then chips[#chips + 1] = _("waiting for Wi-Fi") end
    local bo_t = tonumber(rec.last_read_time)
    local ko_t
    local path = here and O.liveBookPath and O.liveBookPath(id)
    local RH = path and package.loaded["readhistory"]
    if RH and type(RH.hist) == "table" then
        for _i, hh in ipairs(RH.hist) do
            if type(hh) == "table" and hh.file == path then ko_t = tonumber(hh.time) break end
        end
    end
    local last
    if ko_t and (not bo_t or ko_t >= bo_t) then
        last = shortDate(ko_t) and T(_("Last read %1 (Kobo)"), shortDate(ko_t))
    elseif bo_t then
        last = shortDate(bo_t) and T(_("Last read %1 (BookOrbit)"), shortDate(bo_t))
    end
    if last then chips[#chips + 1] = last end
    -- 1.3.21 (TK): the line keeps its room when there's nothing to show, so every
    -- page lines up the same
    space(10)
    add(TextWidget:new{ text = #chips > 0 and table.concat(chips, " · ") or " ", face = Font:getFace("cfont", 14),
        bold = true, max_width = info_w })
    if pct and pct > 0 and pct < 1 then
        space(4)
        add(W("progresswidget"):new{ width = info_w, height = Screen:scaleBySize(6), percentage = pct,
            margin_h = 0, margin_v = 0, radius = 0, bordersize = Screen:scaleBySize(1) })
    end
    -- pages · year · language · genres (1.3.20: genres here, up to 4, cut with … if long)
    local meta = {}
    local pages = tonumber(rec.pages) or tonumber(rec.page_count)
    if pages then meta[#meta + 1] = T(_("%1 pages"), pages) end
    if rec.published then meta[#meta + 1] = tostring(rec.published):sub(1, 4) end
    if rec.lang then meta[#meta + 1] = tostring(rec.lang) end
    if type(rec.genres) == "table" then
        for i = 1, math.min(4, #rec.genres) do meta[#meta + 1] = tostring(rec.genres[i]) end
    end
    if #meta > 0 then
        space(8)
        add(TextWidget:new{ text = table.concat(meta, " · "), face = Font:getFace("cfont", 14), max_width = info_w })
    end
    -- 1.3.22 (TK): when it was finished, in the room a progress bar would take: the
    -- Kobo's own date for a book finished here
    if st == "read" or st == "skimmed" then
        local fin
        -- 1.3.23: matched on its own line ("x and s:match()" kept only the year, and
        -- os.time without a day crashed KOReader on a finished book's page)
        local y, mo, d
        if type(kobo_day) == "string" then y, mo, d = kobo_day:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)") end
        if y and mo and d then
            local t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }
            fin = shortDate(t) and T(_("Finished %1 (Kobo)"), shortDate(t))
        end
        -- (1.3.24: BookOrbit's list has no finished date, checked in TK's log; only the Kobo's)
        if fin then
            space(8)
            add(TextWidget:new{ text = fin, face = Font:getFace("cfont", 14), max_width = info_w })
        end
    end
    -- 1.3.18 (TK): the buttons beside the cover, under the details, when they fit
    -- there; a tall book (long title + series + progress + genres) keeps the full-width
    -- rows under the cover
    local beside = buttonRows(rec, info_w, true)
    local buttons
    -- 1.3.21 (TK): the last row lines up with the bottom of the cover picture
    local cover, pic_h = coverWidget(rec, cover_w, cover_h, false, nil, 15)
    local pic_bottom = math.floor((cover_h + math.min(pic_h or cover_h, cover_h)) / 2)
    local gap_left = pic_bottom - info:getSize().h - beside:getSize().h
    if gap_left >= Screen:scaleBySize(10) then
        info[#info + 1] = VerticalSpan:new{ width = gap_left }
        add(beside)
        -- 1.3.19: measuring keeps the group's layout; it has to be redone now that it
        -- has two more rows, or painting it fails (1.3.18 crashed here)
        if info.resetLayout then info:resetLayout() else info._size, info._offsets = nil, {} end
    else
        buttons = buttonRows(rec, inner_w)
    end
    local hero = HorizontalGroup:new{ align = "top",
        cover, HorizontalSpan:new{ width = gap }, info }


    -- 2.0.0: Similar books are their own section, one tap ("Similar ›") or swipe left
    -- away from the series strip or More by; "‹ Series" / "‹ More by" or a swipe right
    -- goes back. Opened, the page always starts on the series (or More by).
    local sims = {}
    do
        local in_series = {}
        for _i, r in ipairs(series or {}) do in_series[tonumber(r.bookorbit_id) or -1] = true end
        for _i, r in ipairs(similarBooks(rec, 12) or {}) do
            local rid = tonumber(r.bookorbit_id)
            if rid and rid ~= id and not in_series[rid] then sims[#sims + 1] = r end
            if #sims >= 8 then break end
        end
    end
    local sim_mode = #sims > 0 and strip_sim[id] == true
    local function setSim(on)
        strip_sim[id] = on and true or nil
        again()
    end
    -- a section heading, with a small button on the right
    local function headRow(text, btn_text, on_btn)
        local face = Font:getFace("cfont", 14)
        if not btn_text then
            return TextWidget:new{ text = text, face = face, bold = true, max_width = inner_w }
        end
        local btn = Button:new{ text = btn_text, bordersize = 0, padding = 0, margin = 0,
            text_font_face = "cfont", text_font_size = 14, text_font_bold = false,
            callback = on_btn, show_parent = widget }
        local bw = btn:getSize().w
        local title = TextWidget:new{ text = text, face = face, bold = true,
            max_width = math.max(1, inner_w - bw - gap) }
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
        local mh = math.floor(mw * 1.45)
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
    local desc_head = TextWidget:new{ text = _("Description"), face = Font:getFace("cfont", 14), bold = true }
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
        more_books = moreByAuthor(rec, no_strip and 8 or 4, not no_strip)
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
        local mh = math.floor(mw * (no_strip and 1.2 or 0.9))
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
        local keep = (no_strip and 3 or 4) * line_h
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
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, max_width = inner_w }
    end

    -- 1.3.7: tapping the description opens all of it (Book Description)
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
            col[body_at] = tappable(TextBoxWidget:new{ text = body_text, face = desc_face, width = inner_w,
                height = lines * line_h, height_overflow_show_ellipsis = true })
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
    -- a swipe down closes too (like Bookshelf's own pages)
    widget.ges_events = { SwipeClose = { GestureRange:new{ ges = "swipe", range = widget.dimen } } }
    function widget:onSwipeClose(_arg, ges)
        if ges and ges.direction == "south" then close() return true end
        return false
    end

    -- 1.3.6: a full flash only when the page opens (and closes); swiping the strip,
    -- tapping another book or a button's change redraws it without the flash
    if replace and old then
        UIManager:close(old)
        UIManager:show(widget, "ui")
    else
        UIManager:show(widget, "full")
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
    if page and (id == nil or tonumber(id) == page_id) then pcall(again) end
end

function BookPage.isShown() return page ~= nil end

-- going to sleep (1.3.10): the page closes, so waking up never finds it left
-- behind the home screen (it showed glitched over the shelf after). No
-- refresh: the sleep screen draws over it.
function BookPage.close()
    if page then close(false) end
end

return BookPage
