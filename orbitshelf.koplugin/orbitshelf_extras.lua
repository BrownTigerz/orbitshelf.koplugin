-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Reading Status, Next In Series and the Not On Device mark (settings, all off by
-- default).
local O = require("orbitshelf_core")
local T, TAG, UIManager, _, cfg, logger = O.T, O.TAG, O.UIManager, O._, O.cfg, O.logger

local Extras = {}
O.Extras = Extras

local function runConnected(fn)
    local okN, NetworkMgr = pcall(require, "ui/network/manager")
    if okN and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(fn)
    else
        fn()
    end
end

-- ---- Reading Status ------------------------------------------------------------------
-- BookOrbit's own statuses, set on the server (for books read somewhere else).

local STATUSES = {
    { "want_to_read", _("Want To Read") },
    { "reading", _("Reading") },
    { "on_hold", _("On Hold") },
    { "read", _("Read") },
    { "abandoned", _("Abandoned") },
    { "unread", _("Unread") },
}

local function statusLabel(id, fallback)
    local okU, CU = pcall(require, "bookorbit_catalog_util")
    local labels = okU and type(CU) == "table" and CU.READ_STATUS_LABELS
    local l = type(labels) == "table" and labels[id]
    return type(l) == "string" and l ~= "" and l or fallback
end

local function setStatus(id, status, label, title)
    -- 1.3.1: Wi-Fi off, it waits in the Queue (the cover changes now)
    if O.Queue and not O.isWifiOn() then
        O.Queue.addStatus(id, status, label, title)
        return
    end
    local client = O.boApiClient()
    if not client or type(O.runWorker) ~= "function" then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("BookOrbit is not signed in") })
        return
    end
    runConnected(function()
        O.runWorker(client, function()
            local body, err = client:catalogSetReadStatus(id, status)
            return { ok = body ~= nil and body ~= false, err = err and tostring(err) or nil }
        end, function(res)
            if type(res) == "table" and res.ok then
                -- an older queued status for it is now out of date
                if O.Queue then pcall(O.Queue.removeStatus, id) end
                pcall(function()
                    local SM = require("bookorbit_state_manager")
                    if type(SM.invalidate) == "function" then SM.invalidate() end
                end)
                if O.noteReadStatus then pcall(O.noteReadStatus, id, status) end
                O.Genres.note(T(_("Marked %1"), label))
            else
                logger.warn(TAG, "reading status failed:", type(res) == "table" and res.err or "no answer")
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Couldn't save the reading status. Check Wi-Fi and try again."),
                })
            end
        end, 30)
    end)
end

local function pickStatus(id, title)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local rows = {}
    -- 2.0.1: a status waiting for Wi-Fi can be dropped here (the covers go back)
    local queued = O.Queue and O.Queue.statusEntry and O.Queue.statusEntry(id)
    if queued then
        rows[#rows + 1] = {{ text = T(_("Don't Send %1 (Waiting For Wi-Fi)"), tostring(queued.label or queued.status)),
            callback = function()
                UIManager:close(dlg)
                O.Queue.removeStatus(id, true)
            end }}
    end
    for _i, s in ipairs(STATUSES) do
        local label = statusLabel(s[1], s[2])
        rows[#rows + 1] = {{ text = label, callback = function()
            UIManager:close(dlg)
            setStatus(id, s[1], label, title)
        end }}
    end
    rows[#rows + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = T(_("Reading Status: %1"), tostring(title or "")), buttons = rows }
    UIManager:show(dlg)
end

-- the Book Page's Reading Status button (1.3.3)
O.pickReadStatus = pickStatus

-- the row for a hold menu (any BookOrbit book), or nil
function O.readStatusRow(book, close)
    if type(book) ~= "table" or book.is_folder then return nil end
    local id = tonumber(book.bookorbit_id) or tonumber(O.bookIdForPath(book.filepath))
    if not id then return nil end
    return { text = _("Reading Status…"), callback = function()
        if close then close() end
        pickStatus(id, book.display_title or book.title)
    end }
end

-- 1.3.8: the More… row of the quick menu and the hero's hold menu: Add To Collection,
-- Reading Status… and Bulk Download / Remove… in a small menu of their own
function O.moreRow(book, widget, close)
    if type(book) ~= "table" or book.is_folder then return nil end
    return { text = _("More…"), callback = function()
        if close then close() end
        local ButtonDialog = require("ui/widget/buttondialog")
        local dlg
        local function shut() if dlg then UIManager:close(dlg) end end
        local rows = {}
        if O.canAddToCollection and O.canAddToCollection(book) then
            rows[#rows + 1] = {{ text = _("Add To Collection"), callback = function() shut() O.addToCollection(book) end }}
        end
        local status = O.readStatusRow(book, shut)
        if status then rows[#rows + 1] = { status } end
        local bulk = O.Bulk and (O.Bulk.row(book, widget, shut) or O.Bulk.removeRow(book, widget, shut))
        if bulk then rows[#rows + 1] = { bulk } end
        rows[#rows + 1] = {{ text = _("Cancel"), callback = shut }}
        dlg = ButtonDialog:new{ title = tostring(book.display_title or book.title or ""), buttons = rows }
        UIManager:show(dlg)
    end }
end

-- ---- Next In Series ------------------------------------------------------------------
-- Reaching the end of a BookOrbit book remembers the next one in its series (from the
-- saved lists, no network) when it isn't on the device. Nothing pops up in the book:
-- back on the home screen, one question offers to download it.

local pending -- { rec, finished }
local dialog  -- the question, while it's up
local hookShow -- below

local function lower(s) return type(s) == "string" and s ~= "" and s:lower() or nil end

local function findRecord(id)
    for k, entry in pairs(O.page_cache) do
        for i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            if type(r) == "table" and tonumber(r.bookorbit_id) == id then return r end
        end
    end
    return nil
end

local function nextInSeries(series, index, skip_id)
    local best
    for k, entry in pairs(O.page_cache) do
        for i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            local n = type(r) == "table" and tonumber(r.series_index)
            if n and n > index and lower(r.series) == series and tonumber(r.bookorbit_id) ~= skip_id
                    and (not best or n < tonumber(best.series_index)) then
                best = r
            end
        end
    end
    return best
end

function Extras.endOfBook(ui)
    if not cfg.next_in_series then return end
    local file = ui and ui.document and ui.document.file
    local id = tonumber(O.bookIdForPath(file))
    if not id then return end
    local rec = findRecord(id)
    local props = ui.doc_props or {}
    local series = lower(rec and rec.series) or lower(props.series)
    local index = tonumber(rec and rec.series_index) or tonumber(props.series_index)
    if not (series and index) then return end
    local nxt = nextInSeries(series, index, id)
    if not nxt or O.liveBookPath(nxt.bookorbit_id) then return end
    -- 1.3.8: Next Book In Series: Add To Queue: no question, it waits in the Queue
    -- (runs now if Wi-Fi is on, else on the next connect)
    if cfg.next_series_mode == "queue" and O.Queue then
        if not O.Queue.has(nxt) then
            O.Queue.addDownload(nxt)
            if O.isWifiOn() then UIManager:scheduleIn(2, function() O.Queue.run(false) end) end
        end
        return
    end
    pending = { rec = nxt, finished = (rec and rec.title) or props.display_title or props.title or "" }
    hookShow()
end

local function shown(w)
    if type(UIManager.isWidgetShown) == "function" then
        local ok, yes = pcall(UIManager.isWidgetShown, UIManager, w)
        if ok then return yes end
    end
    for i, item in ipairs(UIManager._window_stack or {}) do
        if item.widget == w then return true end
    end
    return false
end

-- back home (SimpleUI's home screen, Bookshelf, the library: whichever shows first)
-- or off the sleep screen there: ask once. Already asked and something full screen
-- opened over it: brought back on top.
function Extras.offerNext()
    if dialog and shown(dialog) then
        UIManager:close(dialog)
        UIManager:show(dialog)
        return
    end
    dialog = nil
    if not pending or not cfg.next_in_series then return end
    if require("device").screen_saver_mode then return end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if type(ReaderUI) == "table" and ReaderUI.instance then return end
    local p = pending
    pending = nil
    if O.liveBookPath(p.rec.bookorbit_id) then return end
    local n = tonumber(p.rec.series_index)
    local head = p.finished ~= "" and T(_("You finished %1."), tostring(p.finished)) or _("You finished the book.")
    dialog = require("ui/widget/confirmbox"):new{
        text = head .. "\n\n" .. T(_("Next in %1: #%2 %3 (not on this device).\n\nDownload it?"),
            tostring(p.rec.series or ""), n and tostring(n) or "?", tostring(p.rec.title or "")),
        ok_text = _("Download"),
        cancel_text = _("Not Now"),
        ok_callback = function()
            dialog = nil
            if O.Queue then O.Queue.downloadOrQueue(p.rec) else O.downloadBookOrbitBook(p.rec) end
        end,
        cancel_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

function Extras.hasPending()
    return pending ~= nil or dialog ~= nil
end

-- Something full screen opening (Bookshelf, SimpleUI's home, the library) while one
-- is waiting or up: offer it / bring it back on top, a tick later. Hooked the first
-- time a book ends with one to offer; the check is one table lookup otherwise.
local show_hooked = false
hookShow = function()
    if show_hooked then return end
    show_hooked = true
    local orig = UIManager.show
    UIManager.show = function(self, w, ...)
        local r = orig(self, w, ...)
        if (pending or dialog) and type(w) == "table" and w ~= dialog and w.covers_fullscreen then
            UIManager:nextTick(function() pcall(Extras.offerNext) end)
        end
        return r
    end
end

-- ---- Not On Device mark (1.2.25) -------------------------------------------------
-- BookOrbit's download mark (the Side Panel's) on the bottom-left of a BookOrbit
-- cover whose book isn't on the device; nothing on books that are. Bottom-left
-- because the page count sits bottom-right. Covers grid only (Bookshelf's own
-- badges have the same rule), drawn into the card Bookshelf builds, so it follows
-- the cover and its redraws; Bookshelf's Cover badge size scales it. Mark Style
-- (1.2.26): Auto (black or white by the cover, the default) or Badge.

local mark_file -- path of BookOrbit's download icon, false when missing
local function markFile()
    if mark_file ~= nil then return mark_file end
    mark_file = false
    local lfs = require("libs/libkoreader-lfs")
    for _i, p in ipairs({ "plugins/bookorbit.koplugin/assets/bookorbit.download.svg",
                          "plugins/bookorbit.koplugin/bookorbit.download.svg" }) do
        if lfs.attributes(p, "mode") == "file" then mark_file = p break end
    end
    if not mark_file then logger.warn(TAG, "Not On Device mark: BookOrbit's download icon not found") end
    return mark_file
end

-- Which BookOrbit book a cover is. A book that isn't on the device has the
-- address bookorbit://<id> instead of a file (Bookshelf keeps that even when it
-- rebuilds the record and drops OrbitShelf's own fields); the id field when it
-- survived.
local function boIdOf(book)
    local fp = book.filepath
    local id = type(fp) == "string" and tonumber(fp:match("^bookorbit://(%d+)$"))
    if id then return id, true end
    if book.is_bookorbit or book.source_kind == O.SOURCE_ID then
        return tonumber(book.bookorbit_id), false
    end
    return nil
end

-- With OrbitShelf's Diagnostics on: the first covers it decides on, to see why a
-- mark does or doesn't show.
local mark_logged = 0
local function markTrace(sw, book, id, remote, want)
    local d = O.diag
    if not (cfg.diagnostics and type(d) == "table" and type(d.log) == "function") or mark_logged >= 12 then return end
    mark_logged = mark_logged + 1
    pcall(d.log, "Not On Device mark: %q id=%s remote=%s is_bookorbit=%s show_progress=%s -> %s",
        tostring(book.title or "?"), tostring(id), tostring(remote), tostring(book.is_bookorbit),
        tostring(sw.show_progress), want == "clock" and "clock" or (want and "mark" or "no mark"))
end

-- The icon as a coverage mask (8-bit, ink = high), one per size, so it can be drawn
-- in any colour. Built once from BookOrbit's SVG.
local masks = {}
local clock_masks = {}
-- 1.3.1: the Queue's clock, drawn (no icon file needed): a ring and two hands
local function clockMaskFor(size)
    local m = clock_masks[size]
    if m ~= nil then return m or nil end
    clock_masks[size] = false
    pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        local c = math.floor(size / 2)
        local r = math.floor(size / 2) - 1
        local w = math.max(1, math.floor(size / 9))
        bb:paintCircle(c, c, r, Blitbuffer.COLOR_BLACK, w)
        local hw = math.max(1, math.floor(size / 10))
        -- hands: 12 o'clock and 3 o'clock
        bb:paintRect(c - math.floor(hw / 2), c - math.floor(r * 0.65), hw, math.floor(r * 0.65) + 1, Blitbuffer.COLOR_BLACK)
        bb:paintRect(c, c - math.floor(hw / 2), math.floor(r * 0.5), hw, Blitbuffer.COLOR_BLACK)
        bb:invertRect(0, 0, size, size)
        clock_masks[size] = bb
    end)
    return clock_masks[size] or nil
end
local function maskFor(size)
    local m = masks[size]
    if m ~= nil then return m or nil end
    masks[size] = false
    local ok = pcall(function()
        local Blitbuffer = require("ffi/blitbuffer")
        local IconWidget = require("ui/widget/iconwidget")
        local bb = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        bb:fill(Blitbuffer.COLOR_WHITE)
        local icon = IconWidget:new{ file = mark_file, width = size, height = size }
        icon:paintTo(bb, 0, 0)
        if icon.free then icon:free() end
        bb:invertRect(0, 0, size, size)
        masks[size] = bb
    end)
    if not ok then masks[size] = false end
    return masks[size] or nil
end

local function blitInk(bb, mask, x, y, size, color)
    local okF, ffi = pcall(require, "ffi")
    local okT, RGB32 = false, nil
    if okF and ffi then okT, RGB32 = pcall(ffi.typeof, "ColorRGB32") end
    if okT and RGB32 and ffi.istype(RGB32, color) and bb.colorblitFromRGB32 then
        bb:colorblitFromRGB32(mask, x, y, 0, 0, size, size, color)
    else
        bb:colorblitFrom(mask, x, y, 0, 0, size, size, color)
    end
end

-- How light the cover is under the mark, 0-255, from a 4 x 4 sample of what's
-- already drawn there (the buffer as stored: night mode inverts the cover and the
-- mark together, so the contrast holds either way).
local function lightnessUnder(bb, x, y, size)
    local okC, ClipBB = pcall(require, "lib/bookshelf_clip_bb")
    local real = (okC and type(ClipBB.real) == "function") and ClipBB.real(bb) or bb
    local sum, n = 0, 0
    for i = 0, 3 do
        for j = 0, 3 do
            local ok, c = pcall(real.getPixel, real, x + math.floor((i + 0.5) * size / 4),
                y + math.floor((j + 0.5) * size / 4))
            if ok and c then
                local okv, v = pcall(function() return c:getColor8().a end)
                if okv and v then sum, n = sum + v, n + 1 end
            end
        end
    end
    return n > 0 and sum / n or 255
end

-- The mark itself. Auto: black on a light corner, white on a dark one, with a thin
-- outline in the other colour so it reads on a busy corner too. Badge: on a small
-- round disc in Bookshelf's badge colours (like its page-count pill).
local Mark
local function newMark(size, clock)
    if not Mark then
        local Widget = require("ui/widget/widget")
        local Geom = require("ui/geometry")
        Mark = Widget:extend{}
        function Mark:getSize() return Geom:new{ w = self.size, h = self.size } end
        function Mark:paintTo(bb, x, y)
            self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
            pcall(function()
                local Blitbuffer = require("ffi/blitbuffer")
                local size = self.size
                if cfg.mark_style == "badge" then
                    local okp, CP = pcall(require, "lib/bookshelf_cover_progress")
                    local colors = okp and type(CP.resolvedColors) == "function" and CP.resolvedColors() or {}
                    local okc, Color = pcall(require, "lib/bookshelf_color")
                    local bg = colors.badge_bg or Blitbuffer.COLOR_WHITE
                    local fg = colors.badge_fg or Blitbuffer.COLOR_BLACK
                    local edge = colors.border or Blitbuffer.COLOR_BLACK
                    local r = math.floor(size / 2)
                    if okc and Color.paintRoundedRect then
                        Color.paintRoundedRect(bb, x, y, size, size, bg, r)
                        Color.paintBorder(bb, x, y, size, size, 1, edge, r)
                    else
                        bb:paintRoundedRect(x, y, size, size, bg, r)
                        bb:paintBorder(x, y, size, size, 1, edge, r)
                    end
                    local inner = math.floor(size * 0.68)
                    local mask = self.clock and clockMaskFor(inner) or maskFor(inner)
                    if mask then
                        local o = math.floor((size - inner) / 2)
                        blitInk(bb, mask, x + o, y + o, inner, fg)
                    end
                    return
                end
                local mask = self.clock and clockMaskFor(size) or maskFor(size)
                if not mask then return end
                local dark = lightnessUnder(bb, x, y, size) < 128
                local ink = dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
                local halo = dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
                for dx = -1, 1 do
                    for dy = -1, 1 do
                        if dx ~= 0 or dy ~= 0 then blitInk(bb, mask, x + dx, y + dy, size, halo) end
                    end
                end
                blitInk(bb, mask, x, y, size, ink)
            end)
        end
    end
    return Mark:new{ size = size, clock = clock }
end

-- "mark" (not on the device), "clock" (in the Queue, 1.3.1: shown even with the
-- mark off, since it's what the reader just did), or false
local function wantsMark(sw)
    local book = sw.book
    if not (sw.show_progress and type(book) == "table") then return false end
    if sw.is_bulk_selected then return false end
    local Q = O.Queue
    local any_queued = Q and not Q.isEmpty()
    if not (cfg.mark_not_on_device or any_queued) then return false end
    local id, remote = boIdOf(book)
    if not id then markTrace(sw, book, nil, false, false) return false end
    local set = O.onDeviceIdSet and O.onDeviceIdSet() or {}
    -- on the device since the list was saved: the id set says so
    if set[id] then markTrace(sw, book, id, remote, false) return false end
    if any_queued and (Q.has(id) or Q.statusOf(id)) then
        markTrace(sw, book, id, remote, "clock")
        return "clock"
    end
    local want = cfg.mark_not_on_device and "mark" or false
    markTrace(sw, book, id, remote, want)
    return want
end

function Extras.hookNotOnDeviceMark()
    local ok, SW = pcall(require, "lib/bookshelf_spine_widget")
    if not ok or type(SW) ~= "table" or SW._orbitshelf_mark then return end
    if type(SW._renderShadowedCard) ~= "function" then
        O.remember(SW, "_renderShadowedCard") -- reports it missing
        return
    end
    SW._orbitshelf_mark = true
    O.remember(SW, "_renderShadowedCard")
    local orig = SW._renderShadowedCard
    SW._renderShadowedCard = function(self, ...)
        local group, card_w, card_h = orig(self, ...)
        local okw, want = pcall(wantsMark, self)
        if okw and want and type(group) == "table" and card_w and card_h and (want == "clock" or markFile()) then
            pcall(function()
                local Screen = require("device").screen
                local FrameContainer = require("ui/widget/container/framecontainer")
                local okp, CP = pcall(require, "lib/bookshelf_cover_progress")
                local base = math.max(Screen:scaleBySize(14), math.floor(card_w * 0.16))
                local size = (okp and type(CP.badgeSize) == "function") and CP.badgeSize(base) or base
                if size > card_w * 0.45 then return end -- a tiny cover: no room
                local inset = Screen:scaleBySize(1) + Screen:scaleBySize(3) -- card border + Bookshelf's badge margin
                -- Bookshelf's reading bookmark / tick and its progress bar also start
                -- bottom-left: the mark sits just above them when the book has one
                local lift = 0
                local oki, ind = pcall(self._statusIndicators, self)
                if oki and type(ind) == "table" then
                    if ind.glyph then
                        local g = math.max(Screen:scaleBySize(9), math.floor(card_w * 0.132))
                        g = (okp and type(CP.badgeSize) == "function") and CP.badgeSize(g) or g
                        lift = math.floor(g * 1.4) + Screen:scaleBySize(2)
                    elseif ind.bar then
                        lift = Screen:scaleBySize(8) + Screen:scaleBySize(4)
                    end
                end
                local y = card_h - inset - size - lift
                if y < inset then return end
                group[#group + 1] = FrameContainer:new{
                    bordersize = 0, padding = 0,
                    padding_top = y, padding_left = inset,
                    newMark(size, want == "clock"),
                }
            end)
        end
        return group, card_w, card_h
    end
end

-- the cover hook, the first time something is queued with the mark off
function Extras.ensureMarks()
    Extras.hookNotOnDeviceMark()
end

return Extras
