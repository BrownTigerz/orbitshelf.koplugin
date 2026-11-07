-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local T, TAG, UIManager, _, cfg, getBookshelf = O.T, O.TAG, O.UIManager, O._, O.cfg, O.getBookshelf
local lfs, logger = O.lfs, O.logger

-- ---- Close-only menu (true left / right / bottom via StartMenu) -------------------
-- Close control stays on the chosen side even when the footer critter owns the
-- centre strip: the hamburger / Close sits in the footer's side band, and the
-- start-menu panel hangs off left or right via side_override.

local function closeBookshelf()
    local bs = getBookshelf()
    if bs and type(bs.close) == "function" then
        pcall(bs.close, bs)
        return
    end
    pcall(function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = type(FM) == "table" and FM.instance
        if fm and fm.bookshelf and type(fm.bookshelf.onClose) == "function" then
            fm.bookshelf:onClose()
        end
    end)
    pcall(function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local r = type(ReaderUI) == "table" and ReaderUI.instance
        if r and r.bookshelf and type(r.bookshelf.onClose) == "function" then
            r.bookshelf:onClose()
        end
    end)
end

local function closeMenuSide()
    local side = cfg.close_menu_side or "bottom"
    if side == "left" or side == "right" then return side end
    return nil -- "bottom" (the saved value for Bookshelf's Side): no override
end

local function isCloseEntry(entry)
    return type(entry) == "table" and (
        entry.id == "orbitshelf_close"
        or entry.internal == "close"
        or (type(entry.label) == "string" and entry.label:find("Close Bookshelf", 1, true))
    )
end

-- Flat close: with Close Only on, the footer hamburger is painted as a close X
-- (same slot, same stroke weight as Bookshelf's own start-menu X) and a tap
-- closes the shelf directly. Anything else that would open the start menu
-- (gesture action, keyboard focus on the footer button) closes the shelf too.
local function closeShelfFrom(bw)
    local done = false
    if type(bw) == "table" and type(bw.onClose) == "function" then
        done = pcall(bw.onClose, bw)
    end
    if not done then closeBookshelf() end
    pcall(function() UIManager:setDirty("all", "full") end)
end

local function buildCloseXIcon(bw, focused, frame_width)
    local Device = require("device")
    local Screen = Device.screen
    local Geom = require("ui/geometry")
    local Widget = require("ui/widget/widget")
    local Color = require("lib/bookshelf_color")
    local art = Screen:scaleBySize(32)
    frame_width = frame_width or art
    local stroke = (bw.FOOTER_STROKE_W) or math.max(1, math.floor(art / 14))
    local span = math.floor(art * 0.62)
    local ink = bw:_chromeInk()
    local XWidget = Widget:extend{}
    function XWidget:getSize() return Geom:new{ w = art, h = art } end
    function XWidget:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = art, h = art }
        local ox = x + math.floor((art - span) / 2)
        local oy = y + math.floor((art - span) / 2)
        local last = span - stroke
        for t = 0, last do
            Color.paintRect(bb, ox + t, oy + t, stroke, stroke, ink)
            Color.paintRect(bb, ox + last - t, oy + t, stroke, stroke, ink)
        end
    end
    local btn = bw:_wrapAsFooterButton(XWidget:new{}, frame_width, focused, function()
        closeShelfFrom(bw)
        return true
    end)
    bw._burger_dimen = btn.dimen
    return btn
end

local function hookFlatClose(BW)
    if BW._orbitshelf_flat_close then return end
    BW._orbitshelf_flat_close = true

    if type(BW._buildStartMenuIcon) == "function" then
        O.remember(BW, "_buildStartMenuIcon")
        local orig_icon = BW._buildStartMenuIcon
        BW._buildStartMenuIcon = function(self, focused, frame_width, ...)
            if cfg.close_only_menu then
                local ok, btn = pcall(buildCloseXIcon, self, focused, frame_width)
                if ok and btn then return btn end
                logger.warn(TAG, "close X build failed, using stock hamburger:", btn)
            end
            return orig_icon(self, focused, frame_width, ...)
        end
    end

    if type(BW._openStartMenu) == "function" then
        O.remember(BW, "_openStartMenu")
        local orig_open = BW._openStartMenu
        BW._openStartMenu = function(self, force, ...)
            if cfg.close_only_menu and (force or self:_startMenuPosition() ~= "off") then
                closeShelfFrom(self)
                return
            end
            return orig_open(self, force, ...)
        end
    end
end

local function hookCloseOnlyMenu()
    local ok, StartMenu = pcall(require, "lib/bookshelf_start_menu")
    if not ok or type(StartMenu) ~= "table" then return end
    if not StartMenu._orbitshelf_close_hooked then
        StartMenu._orbitshelf_close_hooked = true

        -- Hamburger menu → only "Close Bookshelf"
        if type(StartMenu._loadItems) == "function" then
            O.remember(StartMenu, "_loadItems")
            local orig_load = StartMenu._loadItems
            StartMenu._loadItems = function(self, ...)
                if not cfg.close_only_menu then
                    return orig_load(self, ...)
                end
                return {
                    {
                        id = "orbitshelf_close",
                        type = "action",
                        label = _("Close Bookshelf"),
                        internal = "close", -- stock path also closes the shelf
                    },
                }
            end
        end

        -- Tap Close → dismiss menu, then close Bookshelf (always)
        if type(StartMenu._activate) == "function" then
            O.remember(StartMenu, "_activate")
            local orig_act = StartMenu._activate
            StartMenu._activate = function(self, entry, ...)
                if cfg.close_only_menu and isCloseEntry(entry) then
                    local bw = self.bw
                    if type(self._close) == "function" then
                        pcall(self._close, self)
                    else
                        pcall(UIManager.close, UIManager, self)
                    end
                    UIManager:nextTick(function()
                        if bw and type(bw.onClose) == "function" then
                            pcall(function() bw:onClose() end)
                            pcall(function() UIManager:setDirty("all", "full") end)
                        else
                            closeBookshelf()
                        end
                    end)
                    return
                end
                return orig_act(self, entry, ...)
            end
        end

        -- Panel hangs left / right when Close Control says so
        if type(StartMenu.open) == "function" then
            O.remember(StartMenu, "open")
            local orig_open = StartMenu.open
            StartMenu.open = function(bw, bottom_inset, burger_dimen, context, burger_art, anchor_top, side_override, ...)
                if cfg.close_only_menu then
                    local side = closeMenuSide()
                    if side then side_override = side end
                end
                return orig_open(bw, bottom_inset, burger_dimen, context, burger_art, anchor_top, side_override, ...)
            end
        end
    end

    -- Hamburger on the same side as Close Control (left/right)
    local okW, BW = pcall(require, "lib/bookshelf_widget")
    if okW and type(BW) == "table" then
        hookFlatClose(BW)
    end
    if okW and type(BW) == "table" and type(BW._startMenuPosition) == "function"
            and not BW._orbitshelf_close_side then
        BW._orbitshelf_close_side = true
        O.remember(BW, "_startMenuPosition")
        local orig_pos = BW._startMenuPosition
        BW._startMenuPosition = function(self, ...)
            if cfg.close_only_menu then
                local side = closeMenuSide()
                if side then return side end
            end
            return orig_pos(self, ...)
        end
    end
end

-- ---- Footer critter (replaces bottom page nav) ------------------------------------
-- Same sprite/bubble path as Quick Shelf / SimpleUI. Says page, book count,
-- and which shelf you're on. Swipe still pages the shelf; tap the critter for
-- another remark; left/right edges of the strip still step pages.

local function sui(name)
    local m = package.loaded[name]
    if m ~= nil then return m end
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

local BASE_MOOD = {
    reading = "neutral", proud = "cheer", hungry = "curious", cozy = "sleepy",
    dreamy = "sleepy", sipping = "happy", festive = "happy", spooky = "surprised",
}

local function critterId(Assets)
    local tw = G_reader_settings and G_reader_settings:readSetting("simpleui_mod")
    local mix = type(tw) == "table" and type(tw.critter_mix) == "table" and tw.critter_mix or nil
    if mix and #mix >= 2 then
        local turn = type(Assets.tw_turn) == "number" and Assets.tw_turn or (tonumber(os.date("%j")) or 0)
        return mix[(turn % #mix) + 1]
    end
    local CS = sui("modules/critter/settings")
    if type(CS) == "table" and type(CS.pick) == "function" then
        local ok, id = pcall(CS.pick)
        if ok and id ~= nil then return id end
    end
    local Store = sui("infra/sui_store")
    if type(Store) == "table" and type(Store.get) == "function" then
        local ok, id = pcall(Store.get, Store, "simpleui_hs_critter_pick")
        if ok then return id end
    end
end

local _footer_remark_i = 0
local _session_seed = os.time() % 9973
local _recent, RECENT_MAX = {}, 10
local _pick_cache = nil -- { key = ..., line = ... }: one pick per page / tap / shelf
local function resetPick() _pick_cache = nil end

-- UTF-8 safe clip with an ellipsis.
local function clip(s, n)
    s = tostring(s or "")
    local count, i, len = 0, 1, #s
    while i <= len do
        count = count + 1
        if count > n then
            return (s:sub(1, i - 1):gsub("%s+$", "")) .. "…"
        end
        local c = s:byte(i)
        i = i + (c >= 240 and 4 or c >= 224 and 3 or c >= 192 and 2 or 1)
    end
    return s
end

local function quoted(t) return "“" .. clip(t, 22) .. "”" end

local function strHash(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 100003 end
    return h
end

-- Where the shelf is right now, read from the fields Bookshelf really keeps:
-- page (set by _syncPageFromCursor), _total_pages, _total_items, _cursor,
-- _viewSize(), _chipLabel() and _page_items.
local function shelfFacts(bw)
    local f = { page = 1, pages = 1, books = 0, first = 1, last = 1, shelf = "", items = {} }
    pcall(function()
        f.pages = math.max(1, tonumber(bw._total_pages) or 1)
        f.books = math.max(tonumber(bw._spine_books_total) or 0, tonumber(bw._total_items) or 0)
        local view = 0
        if type(bw._viewSize) == "function" then view = tonumber(bw:_viewSize()) or 0 end
        local cursor = tonumber(bw._cursor) or 1
        f.first = cursor
        local last = view > 0 and (cursor + view - 1) or cursor
        if f.books > 0 and last > f.books then last = f.books end
        f.last = math.max(last, f.first)
        local page = tonumber(bw.page)
        if not page and view > 0 then page = math.ceil(f.last / view) end
        f.page = math.max(1, math.min(page or 1, f.pages))
        if type(bw._chipLabel) == "function" then
            f.shelf = tostring(bw:_chipLabel() or "")
        end
        if type(bw._page_items) == "table" then f.items = bw._page_items end
    end)
    if f.shelf == "" then f.shelf = _("this shelf") end
    f.total_pages = f.pages -- the nav-state code below still reads this name
    return f
end

local function pageInfo(f)
    return string.format(_("Page %d of %d · %s"), f.page, f.pages, clip(f.shelf, 16))
end

-- ---- Kind 1: where you are -------------------------------------------------------

local function pageLines(f)
    local L = {}
    local function add(mood, text, sub) L[#L + 1] = { mood = mood, text = text, sub = sub } end
    add("curious", string.format(_("Page %d of %d."), f.page, f.pages), f.books > 0
        and string.format(_("%d books on %s"), f.books, clip(f.shelf, 16)) or nil)
    add("reading", string.format(_("You're on page %d."), f.page))
    add("happy", T(_("Browsing %1."), clip(f.shelf, 20)), string.format(_("Page %d / %d"), f.page, f.pages))
    if f.books > 0 then
        add("neutral", string.format(_("Books %d–%d of %d."), f.first, f.last, f.books),
            string.format(_("Page %d · %s"), f.page, clip(f.shelf, 16)))
    end
    if f.page <= 1 then add("curious", _("Page 1. The very beginning."), pageInfo(f)) end
    if f.page >= f.pages and f.pages > 1 then add("party", string.format(_("Page %d. That's the last one!"), f.page), pageInfo(f)) end
    return L
end

-- ---- Kind 2: witty ---------------------------------------------------------------

local function wittyLines(f)
    local p, pages, n = f.page, f.pages, f.books
    local shelf = clip(f.shelf, 18)
    local L = {}
    local function add(mood, text) L[#L + 1] = { mood = mood, text = text } end
    add("playful", string.format(_("Page %d. The books are behaving."), p))
    add("playful", _("I judge books by their covers. Sorry."))
    add("neutral", _("Browsing is just reading's warm-up."))
    add("happy", _("Another page, another maybe."))
    add("curious", T(_("%1 sends its regards."), shelf))
    add("playful", _("Tap me again. I have opinions."))
    add("neutral", _("Somebody has to keep the spines in line."))
    add("curious", string.format(_("Page %d of %d. Still counting."), p, pages))
    add("happy", _("No dust here. I checked."))
    add("playful", _("You can't read them all tonight. Try anyway."))
    add("cheer", _("Every one of these started as someone's idea."))
    add("curious", _("That cover is doing a lot of work."))
    add("playful", _("Shelves don't judge. I do, a little."))
    add("reading", _("Pick one. The others will understand."))
    add("neutral", T(_("%1 again? Loyal."), shelf))
    if p == 1 then add("curious", _("Page one. Where every good pile starts.")) end
    if pages > 1 and p >= pages then add("party", _("Last page. The shelf ran out before the books did.")) end
    if pages >= 10 then add("surprised", string.format(_("%d pages of shelf. Brave."), pages)) end
    if n > 0 and n <= 3 then add("cozy", _("Tiny shelf. Very curated.")) end
    if n == 0 then add("sad", _("Empty shelf. So much potential.")) end
    if n >= 100 then add("playful", string.format(_("%d books. Bold of you to keep browsing."), n)) end
    local h = tonumber(os.date("%H")) or 12
    if h < 5 then add("sleepy", _("Browsing at this hour? Respect."))
    elseif h < 11 then add("happy", _("Morning browse. Tea first?"))
    elseif h >= 21 then add("dreamy", _("One more chapter, you said.")) end
    return L
end

-- ---- Kind 3: picks from what's on this shelf page --------------------------------

local function bookInfo(it)
    if type(it) ~= "table" or it.is_folder then return nil end
    local title = it.display_title or it.title
    if type(title) ~= "string" or title == "" then return nil end
    local author = it.author
    if (not author or author == "") and type(it.authors) == "table" then author = it.authors[1] end
    if type(author) ~= "string" or author == "" then author = nil end
    local pct = tonumber(it.percent_finished or it.book_pct)
    local st = it.status or it.read_status
    local state
    if st == "finished" or st == "complete" then state = "finished"
    elseif st == "on_hold" or st == "abandoned" then state = "hold"
    elseif st == "reading" or (pct and pct > 0 and pct < 1) then state = "reading"
    else state = "unread" end
    local series = type(it.series_name) == "string" and it.series_name ~= "" and it.series_name or nil
    return {
        title = title, author = author, pct = pct, state = state,
        series = series, series_num = it.series_num and tostring(it.series_num) or nil,
    }
end

local function recommendLines(f)
    local L = {}
    local function add(mood, text) L[#L + 1] = { mood = mood, text = text } end
    local books = {}
    for _i, it in ipairs(f.items or {}) do
        local b = bookInfo(it)
        if b then books[#books + 1] = b end
    end
    if #books == 0 then return L end

    local by_author, finished = {}, 0
    for _i, b in ipairs(books) do
        local t = quoted(b.title)
        if b.state == "reading" and b.pct then
            local pc = math.floor(b.pct * 100 + 0.5)
            if pc >= 80 then
                add("cheer", string.format(_("%s is %d%% done. One more push?"), t, pc))
            else
                add("reading", string.format(_("Back to %s? You're %d%% in."), t, pc))
            end
        elseif b.state == "hold" then
            add("sad", string.format(_("%s is on hold. It misses you."), t))
        elseif b.state == "unread" then
            if b.series and b.series_num and b.series_num ~= "1" and b.series_num ~= "0" then
                add("curious", string.format(_("%s #%s is still unread."), clip(b.series, 18), b.series_num))
            elseif b.series then
                add("hungry", string.format(_("Start the %s series?"), clip(b.series, 18)))
            elseif b.author then
                add("curious", string.format(_("%s by %s. Still unread."), t, clip(b.author, 20)))
            else
                add("curious", string.format(_("Still unread: %s."), t))
            end
            if b.author then
                by_author[b.author] = by_author[b.author] or {}
                table.insert(by_author[b.author], b.title)
            end
        else
            finished = finished + 1
        end
    end
    for author, titles in pairs(by_author) do
        if #titles >= 2 then
            add("playful", string.format(_("Two by %s: %s or %s?"), clip(author, 20), quoted(titles[1]), quoted(titles[2])))
        end
    end
    if #books >= 3 and finished == #books then
        add("proud", _("All read on this page. Impressive."))
    end
    return L
end

-- ---- Kind 4: shelf sayings (written for Bookshelf, no real person's words) --------

local SAYINGS = {
    "A shelf is a promise you keep making.",
    "Every book is a door with a spine.",
    "Unread books are just future evenings.",
    "Somewhere on this shelf is your next favourite.",
    "A good book leaves the light on for you.",
    "Read slowly. The ending isn't going anywhere.",
    "Books don't mind waiting. They're good at it.",
    "One more chapter is how every night begins.",
    "A full shelf is a quiet kind of wealth.",
    "Dog-ears are just love with a crease.",
    "The best bookmark is a good excuse.",
    "Every cover hides a weather system.",
    "A page is a small room with a big window.",
    "Borrowed books always know the way home.",
    "Rainy day, tall stack. That's the plan.",
    "Some books are meals. Some are snacks. Both count.",
    "It's fine to quit a book. Shelves forgive.",
    "A shelf remembers everything you meant to read.",
    "Spines in a row, stories in a crowd.",
    "Your to-read pile is optimism, stacked.",
    "The first line is a handshake.",
    "Every library starts with one more book.",
    "Quiet rooms are where books talk loudest.",
    "Stories keep. Take your time.",
    "Browse like you have all afternoon.",
    "Reading is time travel with better seats.",
    "A bookmark is a pause button made of paper.",
    "Don't rush the ending. It's earned.",
    "The right book finds you on the right page.",
    "Coffee cools. Good chapters stay warm.",
    "Browsing is choosing in slow motion.",
    "Every story started as someone's quiet hour.",
    "Small screen, big world.",
    "Future you will thank you for this pile.",
    "Comfort is a book you've already read twice.",
    "The shelf is full. The evening is free.",
}

-- Optional: add your own to koreader/settings/orbitshelf-quotes.txt, one per
-- line, as `quote` or `quote | author`. Re-read when the file changes.
local _user_quotes = { mtime = nil, list = {} }
local function userQuotes()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or type(DataStorage) ~= "table" or type(DataStorage.getSettingsDir) ~= "function" then
        return _user_quotes.list
    end
    local path = DataStorage:getSettingsDir() .. "/orbitshelf-quotes.txt"
    local attr = lfs.attributes(path)
    local mtime = attr and attr.modification or false
    if mtime == _user_quotes.mtime then return _user_quotes.list end
    _user_quotes.mtime = mtime
    _user_quotes.list = {}
    if not attr then return _user_quotes.list end
    pcall(function()
        for line in io.lines(path) do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" and line:sub(1, 1) ~= "#" then
                local text, author = line:match("^(.-)%s*|%s*(.+)$")
                table.insert(_user_quotes.list, { text = text or line, author = author })
            end
        end
    end)
    return _user_quotes.list
end

local function quoteLines(f)
    local L = {}
    for _i, s in ipairs(SAYINGS) do
        L[#L + 1] = { mood = (#L % 3 == 0) and "dreamy" or "reading", text = "“" .. s .. "”" }
    end
    for _i, q in ipairs(userQuotes()) do
        L[#L + 1] = {
            mood = "reading", text = "“" .. q.text .. "”",
            sub = q.author and ("— " .. clip(q.author, 18) .. " · " .. string.format(_("p. %d/%d"), f.page, f.pages)) or nil,
        }
    end
    return L
end

-- ---- Pick one line ----------------------------------------------------------------

local function recentHas(text)
    for _i, t in ipairs(_recent) do if t == text then return true end end
    return false
end

local function remember(text)
    table.insert(_recent, text)
    while #_recent > RECENT_MAX do table.remove(_recent, 1) end
end

local KIND_POOLS = {
    page = pageLines, witty = wittyLines, recs = recommendLines, quotes = quoteLines,
}

local function enabledKinds()
    local order = {}
    if cfg.critter_say_page then order[#order + 1] = "page" end
    if cfg.critter_say_witty then order[#order + 1] = "witty" end
    if cfg.critter_say_recs then order[#order + 1] = "recs" end
    if cfg.critter_say_quotes then order[#order + 1] = "quotes" end
    if #order == 0 then order[1] = "page" end
    return order
end

-- One line per (page, tap, shelf) so a repaint doesn't change what it says; every
-- tap or page turn moves to the next kind (page → witty → picks → sayings) and
-- steps over anything said in the last few lines.
local function pickFooterLine(bw)
    local f = shelfFacts(bw)
    local order = enabledKinds()
    local key = table.concat({
        f.page, f.pages, f.books, f.shelf, _footer_remark_i, table.concat(order, ","),
    }, "|")
    if _pick_cache and _pick_cache.key == key then return _pick_cache.line end

    local shelf_h = strHash(f.shelf)
    local start = (_footer_remark_i + f.page + shelf_h + _session_seed) % #order
    local chosen, chosen_kind
    for k = 0, #order - 1 do
        local kind = order[((start + k) % #order) + 1]
        local pool = KIND_POOLS[kind](f)
        if #pool > 0 then
            local base = (_session_seed + f.page * 31 + _footer_remark_i * 17 + shelf_h + #pool * 7) % #pool
            for j = 0, #pool - 1 do
                local cand = pool[((base + j) % #pool) + 1]
                if not recentHas(cand.text) then chosen = cand break end
            end
            chosen = chosen or pool[base + 1]
            chosen_kind = kind
            break
        end
    end
    chosen = chosen or { mood = "happy", text = string.format(_("Page %d of %d."), f.page, f.pages) }
    chosen_kind = chosen_kind or "page"
    local line = { mood = chosen.mood, text = chosen.text, sub = chosen.sub or pageInfo(f) }
    remember(line.text)
    _pick_cache = { key = key, line = line }
    package.loaded["orbitshelf_critter_last"] = {
        kind = chosen_kind, text = line.text, sub = line.sub, mood = line.mood,
        page = f.page, pages = f.pages, books = f.books, shelf = f.shelf,
        on_page = #(f.items or {}),
    }
    return line
end

-- The critter strip: the message and its detail written straight onto the footer bar
-- (the bar's own ink, centred in the visible bar), and the critter at the right end,
-- sized to the bar. h is the footer row's height; the visible bar is its top part, the
-- rest is tap area below it (Bookshelf's 12 dp).
-- width / height of a critter image, read once per file (nil when it can't be read)
local critter_aspects = {}
local function critterAspect(path)
    local a = critter_aspects[path]
    if a ~= nil then return a or nil end
    local ok, bb = pcall(function() return require("ui/renderimage"):renderImageFile(path, false) end)
    if ok and bb then
        local w, h = bb:getWidth(), bb:getHeight()
        pcall(bb.free, bb)
        a = (h > 0) and (w / h) or false
    else
        a = false
    end
    critter_aspects[path] = a
    return a or nil
end

local function buildFooterCritter(bw, max_w, h)
    local Screen = require("device").screen
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local line = pickFooterLine(bw)
    local mood = line.mood or "happy"
    local message, detail = line.text, line.sub

    local cap_h = h - Screen:scaleBySize(12)
    local pad = Screen:scaleBySize(3)
    local inner_h = math.max(Screen:scaleBySize(16), cap_h - 2 * pad)

    -- the critter, when SimpleUI's modules are there
    local sprite
    pcall(function()
        local Sprite = sui("modules/critter/sprite")
        local Assets = sui("modules/critter/assets")
        if not (type(Sprite) == "table" and type(Assets) == "table" and type(Assets.get) == "function") then return end
        local want = critterId(Assets)
        local entry = Assets.get(want)
        if type(entry) == "table" and want and entry.id ~= want and type(Assets.list) == "function" then
            for _i, e in ipairs(Assets.list()) do
                if e.id == want then entry = e break end
            end
        end
        local path = entry and (Assets.imagePath(entry, mood)
            or (BASE_MOOD[mood] and Assets.imagePath(entry, BASE_MOOD[mood]))
            or Assets.imagePath(entry, "happy"))
        if not path then return end
        -- SimpleUI scales a big critter image to exactly the box it is given, so the
        -- box keeps the image's own shape (a wide box stretched the critter)
        local box_w = math.floor(max_w * 0.22)
        local aspect = critterAspect(path)
        if aspect then box_w = math.min(box_w, math.max(1, math.floor(inner_h * aspect + 0.5))) end
        -- shadow: SimpleUI 3.0.3's ground shadow, like the home screen critter (older builds ignore it)
        local sp = Sprite:new{ path = path, max_w = box_w, max_h = inner_h, shadow = true }
        if sp.dimen and sp.dimen.w > 0 then sprite = sp end
    end)

    local gap = Screen:scaleBySize(6)
    local text_w = max_w - (sprite and (sprite.dimen.w + gap) or 0) - pad
    if text_w < Screen:scaleBySize(40) then
        sprite = nil
        text_w = max_w - pad
    end

    -- the bar's ink, so it reads on a dark or a light bar
    local ink = Blitbuffer.COLOR_BLACK
    pcall(function() if bw and type(bw._chromeInk) == "function" then ink = bw:_chromeInk() or ink end end)
    -- the detail a little softer than the message, but still easy to read: light
    -- grey on a dark bar, dark grey on a light one (it was the other way round,
    -- dark on dark, and faded out)
    local detail_ink = ink
    pcall(function()
        local a = ink.getColor8 and ink:getColor8().a or 0
        detail_ink = Blitbuffer.gray(a >= 128 and 0.15 or 0.75)
    end)

    -- the biggest type that fits the bar: message over detail
    local text_block
    for size = 15, 8, -1 do
        local msg = TextWidget:new{ text = message or "", face = Font:getFace("xx_smallinfofont", size),
                                    bold = true, fgcolor = ink, max_width = text_w }
        local det = detail and detail ~= "" and TextWidget:new{ text = detail,
                                    face = Font:getFace("xx_smallinfofont", math.max(7, size - 3)),
                                    fgcolor = detail_ink, max_width = text_w } or nil
        local total = msg:getSize().h + (det and det:getSize().h or 0)
        if total <= inner_h or size == 8 then
            local vg = VerticalGroup:new{ align = "left", msg }
            if det then vg[#vg + 1] = det end
            text_block = vg
            break
        end
        msg:free()
        if det then det:free() end
    end

    local row = HorizontalGroup:new{ align = "center" }
    row[#row + 1] = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = inner_h }, text_block }
    if sprite then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = sprite
    end
    -- centred in the visible bar; the tap area below it is left as space
    local strip = VerticalGroup:new{ align = "left" }
    strip[#strip + 1] = CenterContainer:new{ dimen = Geom:new{ w = max_w, h = cap_h }, row }
    if h > cap_h then strip[#strip + 1] = VerticalSpan:new{ width = h - cap_h } end
    return strip, line
end

local function hookFooterCritter()
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" then return end
    if BW._orbitshelf_footer_critter then return end
    BW._orbitshelf_footer_critter = true

    O.remember(BW, "_buildPaginationFooter")

    local orig = BW._buildPaginationFooter
    if type(orig) ~= "function" then return end

    BW._buildPaginationFooter = function(self, content_w, label_h, total_pages, ...)
        if not cfg.footer_critter then
            return orig(self, content_w, label_h, total_pages, ...)
        end

        local Screen = require("device").screen
        local CenterContainer = require("ui/widget/container/centercontainer")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local Geom = require("ui/geometry")
        local GestureRange = require("ui/gesturerange")
        local HorizontalGroup = require("ui/widget/horizontalgroup")

        local h = label_h or Screen:scaleBySize(36)
        local strip_w = math.floor((content_w or Screen:getWidth()) * 0.90)
        local edge_w = math.floor(strip_w * 0.12)
        local mid_w = strip_w - 2 * edge_w

        local critter = buildFooterCritter(self, mid_w, h)

        -- Invisible edge buttons: still page with left/right taps
        local function step(dir)
            return function()
                if type(self._footerStep) == "function" then
                    pcall(self._footerStep, self, dir)
                elseif type(self.onNextPage) == "function" and dir > 0 then
                    pcall(self.onNextPage, self)
                elseif type(self.onPrevPage) == "function" and dir < 0 then
                    pcall(self.onPrevPage, self)
                end
            end
        end

        local function edgeBtn(w, on_tap)
            local Btn = InputContainer:extend{}
            function Btn:onTap()
                if on_tap then on_tap() end
                return true
            end
            local b = Btn:new{ dimen = Geom:new{ w = w, h = h } }
            b.ges_events = {
                Tap = { GestureRange:new{ ges = "tap", range = b.dimen } },
            }
            return b
        end

        local Mid = InputContainer:extend{}
        function Mid:onTap()
            _footer_remark_i = _footer_remark_i + 1
            local bw = self.host
            pcall(function()
                if not (bw and bw._overlap_group and type(bw._buildFooterRow) == "function") then return end
                local d = bw._layout_dims or bw._dims
                local content_w = (d and d.content_w) or content_w
                local footer_h = (d and d.FOOTER_H) or h
                local pages = bw._total_pages or total_pages or 1
                local new_row = bw:_buildFooterRow(content_w, pages, footer_h)
                local BottomContainer = require("ui/widget/container/bottomcontainer")
                local Geom2 = require("ui/geometry")
                local idx = d and d.footer_overlap_idx
                if idx and bw._overlap_group then
                    local margin = (d and d.FOOTER_BOTTOM_MARGIN) or 0
                    bw._overlap_group[idx] = BottomContainer:new{
                        dimen = Geom2:new{ w = bw.width, h = (bw.height or Screen:getHeight()) - margin },
                        new_row,
                    }
                    UIManager:setDirty(bw, "ui")
                elseif type(bw._rebuild) == "function" then
                    bw:_rebuild()
                end
            end)
            return true
        end

        local mid = Mid:new{
            dimen = Geom:new{ w = mid_w, h = h },
            CenterContainer:new{
                dimen = Geom:new{ w = mid_w, h = h },
                critter,
            },
        }
        mid.host = self
        mid.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = mid.dimen } },
        }

        local row = HorizontalGroup:new{ align = "center" }
        row[#row + 1] = edgeBtn(edge_w, step(-1))
        row[#row + 1] = mid
        row[#row + 1] = edgeBtn(edge_w, step(1))

        -- Keep nav state so key/D-pad paths still know back/fwd
        local page = 1
        local pages = tonumber(total_pages) or 1
        pcall(function()
            local f = shelfFacts(self)
            page, pages = f.page, f.total_pages
        end)
        self._footer_nav_state = { back = page > 1, fwd = page < pages }

        return CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = h },
            row,
        }
    end
    logger.info(TAG, "footer critter hooked")
end


-- shared with the other files
O.hookCloseOnlyMenu = hookCloseOnlyMenu
O.hookFooterCritter = hookFooterCritter
O.resetPick = resetPick
return O
