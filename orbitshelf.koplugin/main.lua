--[[
orbitshelf.koplugin  ·  OrbitShelf
BookOrbit shelves inside Bookshelf (AndyHazz/bookshelf.koplugin).

Version: 2.2.0

Requires:
  * bookshelf.koplugin (SOURCE_API >= 1; best with Bookshelf 6.x)
  * bookorbit.koplugin signed in (server_url + username + userkey)

What it does
  * Toggle **Use BookOrbit In Bookshelf**. Registers a **BookOrbit** fetch-mode
    shelf source (books not on device included).
  * Source modes: Library, Recently added, Recently read, **Series**,
    **Authors**, **Genres**, and **Collections** (fetched from BookOrbit when
    Wi-Fi is on, the saved list otherwise). Series/Authors/Genres are folder
    drills (tap a group → its books), ordered the way Bookshelf orders its own
    Series / Authors / Genres stacks.
  * Toggle **Rewrite Stock Series/Author/Genre**: points the built-in Series,
    Authors, Genres, Recent and Latest chips at BookOrbit (restored when off).
  * Covers: shared cache/bookorbit/ folder with Side Panel; Clean Up Cache
    matches Reading Log Tweaks.
  * Hero: hold menu and, at the bottom of the banner, **Download / Open In
    BookOrbit** pills for a BookOrbit book not on the device; small round icons
    (Remove From Device, Open In BookOrbit, Sync) at the bottom right for one
    that is, so its description keeps the room.
  * Toggle **Close Only (No Hamburger)**: the footer hamburger is replaced by a
    plain close X. One tap closes Bookshelf, no menu in between. Placement is
    still left, right or Bookshelf's side (Close Control). Gesture / keyboard
    "open start menu" closes the shelf too while this is on.
  * Toggle **Footer Critter**: replaces the bottom page nav with your SimpleUI
    Tiny Critter (same critters as Quick Shelf / Reading Log). The bubble always
    carries where you are (page, pages, shelf) and says one of four things,
    moving to the next kind on every tap or page turn:
      Page    - "Page 3 of 9", "Books 25-36 of 104".
      Witty   - short remarks that know the page, shelf size and time of day.
      Picks   - recommendations from the books on this page: one to get back to,
                one nearly finished, the next in a series, two by one author.
      Sayings - original one-liners about books and shelves; add your own in
                koreader/settings/orbitshelf-quotes.txt (one per line, or
                `quote | author`).
    Each kind has its own switch (at least one stays on). Left/right edges
    still page; swipe still pages.

  * **Genres**: BookOrbit's lists carry no genres, so they are built once from each
    book's BookOrbit page (genres + tags), in the background, after a Start / Later
    question the first time the Genres shelf opens. Books on the device use their
    file's own genres. Wi-Fi off pauses it; it carries on when Wi-Fi is back.
    Shelf > Build Genres / Rebuild Genres.
  * **Flash** (both off by default): Hero > Flash When It Changes flashes the hero
    clean when it shows another book; Shelf > Flash On Every Page Turn makes every
    shelf page turn a full refresh. Both clear e-ink ghosting.
  * **Offline Library** (off by default): every BookOrbit book's cover and details
    (description, pages, published, language, genres) saved on the device, so the
    whole library shows with Wi-Fi off. Books themselves are not downloaded: those
    still show Download (dimmed with Wi-Fi off) and the hero says Not On Device ·
    Saved Offline at the top right, next to the rating stars. Built in the background with Wi-Fi on, new books added when
    Wi-Fi comes on. Details in koreader/orbitshelf-library.txt, covers in the shared
    cover folder. Offline Library > Keep Library Offline / Update Now / Delete.

Reading Stats (2.2): Book | Stats | All Time on the Book Page: one book's stats (from
this Kobo's statistics or BookOrbit's sessions), All Time and Your Year, Moments with
X-Ray / KOAssistant, Glimpse and ReadMastery, spoiler-free; saved for offline.

Settings: Tools → OrbitShelf (or Add-ons with 2-tweaks-menu.lua) opens the Settings
window (2.2): BookOrbit Account, Books, Downloads, Footer, Look, Offline, Shelves,
Advanced and Help (with Quick Setup, shown once after install or update).

Problems go to crash.log, tagged "orbitshelf 2.2.0:". With Diagnostics on, at start
it also writes the KOReader version, the device, the Bookshelf / BookOrbit / SimpleUI
versions and every patch and plugin present. When another patch or plugin changed a Bookshelf function
OrbitShelf hooks (hero, close X, footer, flash), or replaced the BookOrbit shelf
source, the line names that file. A part that fails writes its error and where it
happened, once per start, and Bookshelf's own version runs instead.

Install: copy the orbitshelf.koplugin folder into koreader/plugins/ and restart.
Everything is off on a new install (Reading Stats aside): Bookshelf stays as it is until
you turn things on in Tools > OrbitShelf (start with Use BookOrbit In Bookshelf).
Coming from the patch: delete koreader/patches/2-orbitshelf-tweaks.lua first. While
the old patch is there it runs and the plugin stays off (crash.log says so). Settings,
genres, saved lists, the offline library and covers carry over as they are.

Files: main.lua (start-up, menu, Wi-Fi and sleep), orbitshelf_core.lua (settings,
crash.log), orbitshelf_bookorbit.lua (BookOrbit lists, covers, offline details,
download / remove), orbitshelf_genres.lua (background lookups), orbitshelf_source.lua
(the Bookshelf source and its shelves), orbitshelf_hero.lua (hero buttons, flash),
orbitshelf_footer.lua (critter, close X, Home button), orbitshelf_menu.lua (settings menu),
orbitshelf_collections.lua (Add To Collection), orbitshelf_bulk.lua (Bulk Download / Remove),
orbitshelf_extras.lua (Reading Status, Next In Series, Not On Device mark),
orbitshelf_queue.lua (the Queue: downloads and statuses waiting for Wi-Fi),
orbitshelf_bookpage.lua (the Book Page), orbitshelf_stats.lua (Reading Stats),
orbitshelf_diag.lua (Diagnostics, loaded only while it's on).

Changelog: see CHANGELOG.md in the repo.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local O = require("orbitshelf_core")
-- this plugin's folder (diagnostics is loaded from it later, only while it's on)
O.dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")

local OrbitShelf = WidgetContainer:extend{
    name = "orbitshelf",
    is_doc_only = false,
}

-- the old patch is running: stay off (crash.log already says why)
if O.idle then return OrbitShelf end

require("orbitshelf_theme") -- 2.1.15: Colour Theme
require("orbitshelf_sheet") -- 2.1.12: the popups
require("orbitshelf_bookmore") -- 2.1.14: More ▾, highlights, bookmarks
require("orbitshelf_xray") -- 2.1.23: X-Ray and ReadMastery in the stats
require("orbitshelf_glimpse") -- 2.1.26: Glimpse's pictures in the stats
require("orbitshelf_bookorbit")
require("orbitshelf_collections")
require("orbitshelf_genres")
require("orbitshelf_source")
require("orbitshelf_bulk")
require("orbitshelf_extras")
require("orbitshelf_queue")
require("orbitshelf_bookpage")
require("orbitshelf_hero")
require("orbitshelf_footer")
require("orbitshelf_menu")
require("orbitshelf_settings") -- 2.1.33: Settings as one window

local UIManager, logger, TAG, cfg = O.UIManager, O.logger, O.TAG, O.cfg

-- one start-up step; a failure is written to crash.log with where it happened
local function step(label, fn, ...)
    local args = { n = select("#", ...), ... }
    local ok, err = xpcall(function() return fn(unpack(args, 1, args.n)) end, debug.traceback)
    if not ok then O.problem("boot:" .. label, label .. " failed at start:", err) end
end

local function boot()
    if cfg.diagnostics then O.environment() end -- what it runs with, for the log
    if cfg.use_bookorbit and O.bookOrbitInstalled() then
        if not O.registerSource() then
            -- Bookshelf may not be ready yet
            UIManager:nextTick(function() step("BookOrbit source", O.registerSource) end)
            UIManager:scheduleIn(1, function() step("BookOrbit source", O.registerSource) end)
            UIManager:scheduleIn(3, function()
                step("BookOrbit source", O.registerSource)
                if cfg.use_bookorbit and not O.spec then
                    O.problem("nosource", "BookOrbit source not registered: Bookshelf missing, too old (needs source API 1), or turned off")
                end
            end)
        end
    elseif cfg.use_bookorbit then
        O.problem("nobo", "BookOrbit plugin not found: BookOrbit shelves are off")
    end
    step("hero", O.hookHero)
    step("flash", O.hookFlash)
    step("popup flash", O.hookPopupFlash)
    step("BookOrbit search", O.hookSearch)
    -- Return To shelf (off by default): Bookshelf's instance may come a moment later
    if cfg.return_shelf then
        local ok, done = pcall(O.hookReturnShelf)
        if not (ok and done) then
            UIManager:scheduleIn(1, function() step("Return To shelf", O.hookReturnShelf) end)
            UIManager:scheduleIn(3, function() step("Return To shelf", O.hookReturnShelf) end)
        end
    end
    -- Offline Library: new books since last time, quietly, once shortly after start
    if cfg.offline_library and O.Genres.autoOn("wifi") then
        UIManager:scheduleIn(20, function()
            if O.isWifiOn() then step("Offline Library", O.Genres.build, true) end
        end)
    end
    step("Remove From Device button", O.registerFileDialogButton)
    step("close-only menu", O.hookCloseOnlyMenu)
    step("footer critter", O.hookFooterCritter)
    if cfg.home_button then step("Home button", O.hookHomeButton) end
    if cfg.mark_not_on_device or not O.Queue.isEmpty() then step("Not On Device mark", O.Extras.hookNotOnDeviceMark) end
    step("rewrite stock chips", O.applyAutoRewrite)
    O.arm()
    if cfg.diagnostics then step("diagnostics", O.startDiag) end
end

local booted = false

function OrbitShelf:init()
    if not booted then
        booted = true
        UIManager:nextTick(function() step("start-up", boot) end)
        logger.info(TAG, "loaded (plugin)")
    end
    -- the file manager's menu (Tools, unless the Add-ons patch shows it)
    if self.ui and self.ui.menu and not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
    -- back home after finishing a book: Next In Series asks once the home screen is up
    if self.ui and not self.ui.document and O.Extras.hasPending() then
        UIManager:scheduleIn(1, function() step("next in series", O.Extras.offerNext) end)
    end
end

function OrbitShelf:addToMainMenu(menu_items)
    step("menu", O.addMainMenu, menu_items)
end

-- Wi-Fi back: a paused Genres / Offline Library run carries on, new books are added
function OrbitShelf:onNetworkConnected()
    step("Wi-Fi back", O.Genres.onWifi)
    -- the Queue: once, a little after the connect (1.3.1)
    step("queue", O.Queue.onWifi)
end

-- going to sleep: the background lookups stop (they carry on when Wi-Fi is back)
-- 2.0.0: Simple UI's Start With Home Screen puts its home back on top after sleep,
-- over a Bookshelf left open. Bookshelf closes any "homescreen" above it at the next
-- Wi-Fi change (its _evictHomescreenOverlay), so the shelf popped up by itself once
-- Wi-Fi connected. A second after waking (and after the sleep screen goes), if Simple
-- UI's home sits over the shelf and no book is open, the shelf under it is closed.
local wake_check
local function closeShelfUnderHome()
    wake_check = nil
    local RUI = package.loaded["apps/reader/readerui"]
    if RUI and RUI.instance then return end
    if require("device").screen_saver_lock then return end -- OutOfScreenSaver checks again
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return end
    local shelf
    for _i, entry in ipairs(stack) do
        local w = entry and entry.widget
        if type(w) == "table" then
            if w.name == "bookshelf" then
                shelf = w
            elseif shelf and w.covers_fullscreen and w.name == "homescreen" then
                logger.info(TAG, "woke to Simple UI's home over Bookshelf: closing Bookshelf under it")
                local ok = type(shelf.onClose) == "function" and pcall(shelf.onClose, shelf)
                if not ok then UIManager:close(shelf) end
                return
            end
        end
    end
end
local function checkShelfAfterWake()
    if wake_check then UIManager:unschedule(wake_check) end
    wake_check = function() step("shelf under home after wake", closeShelfUnderHome) end
    UIManager:scheduleIn(1, wake_check)
end

function OrbitShelf:onSuspend()
    if wake_check then UIManager:unschedule(wake_check); wake_check = nil end
    if O.Genres.running then step("sleep", O.Genres.stop, true) end
    if O.Bulk.running() then step("bulk download pause", O.Bulk.pause) end
    if O.Queue.running() then step("queue pause", O.Queue.pause) end
    if O.BookPage and O.BookPage.isShown() then step("book page close", O.BookPage.close) end
    if O.Settings and O.Settings.current then step("settings close", O.Settings.closeOnSleep) end
    step("save lists", O.flushPageCache)
end

-- a book opening (1.3.14): the Book Page closes. Opened from BookOrbit's own "open
-- now?" after a download it stayed under the book, and after Close Bookshelf it was
-- left under the stock library. ShowingReader reaches the file browser's copy of the
-- plugin, ReaderReady the book's; the page is shared, so either closes it.
local function closeBookPage()
    -- 2.1.14: the stats page too (a highlight or X-Ray opens the book from it)
    if O.Stats and O.Stats.closeForBook then step("stats page close (book opened)", O.Stats.closeForBook) end
    if O.BookPage and O.BookPage.isShown() then step("book page close (book opened)", O.BookPage.close) end
end
function OrbitShelf:onShowingReader() closeBookPage() end
function OrbitShelf:onReaderReady()
    closeBookPage()
    -- 2.1.14: what More ▾ or a highlight asked for once this book is open
    if O.runAfterOpen then step("after open", O.runAfterOpen, self.ui) end
    -- 2.1.23: with Reading Stats on, count X-Ray lookups and ReadMastery's rewards for this book
    if O.cfg and O.cfg.bookpage_stats and O.XRay then
        step("x-ray lookups", O.XRay.hookLookups, self.ui)
        step("readmastery rewards", O.XRay.hookReadMastery)
    end
end

-- awake again: a Bulk Download paused by sleep asks whether to continue, once the
-- sleep screen is gone (with "tap to exit" the screen stays until OutOfScreenSaver)
function OrbitShelf:onResume()
    -- 2.1.30 (TK): after sleep the stats open on Device first (BookOrbit's side would
    -- fetch as soon as Wi-Fi is back); picking BookOrbit again works as before
    O.stats_after_wake = true
    checkShelfAfterWake()
    if O.Bulk.running() then step("bulk download resume", O.Bulk.offerResume) end
end

function OrbitShelf:onOutOfScreenSaver()
    checkShelfAfterWake()
    if O.Bulk.running() then step("bulk download resume", O.Bulk.offerResume) end
    if O.Extras.hasPending() then step("next in series", O.Extras.offerNext) end
end

-- the last page of a book: Next In Series remembers what comes next (asks back home)
function OrbitShelf:onEndOfBook()
    if cfg.next_in_series then step("next in series", O.Extras.endOfBook, self.ui) end
end

-- 2.1.8: a book closing, with Reading Stats on: its stats are worked out and saved for
-- the Book Page a tick later (after KOReader's statistics have written its pages), so the
-- Book Page doesn't read the statistics again
function OrbitShelf:onCloseDocument()
    if not cfg.bookpage_stats then return end
    local file = self.ui and self.ui.document and self.ui.document.file
    if type(file) ~= "string" then return end
    -- 2.1.11: the book's chapters (top level, at most 300), taken now while the book is open
    local toc, toc_total
    pcall(function()
        local rt = self.ui.toc
        if not rt then return end
        if type(rt.fillToc) == "function" then rt:fillToc() end
        local list = type(rt.toc) == "table" and rt.toc or {}
        local min_depth
        for _i, e in ipairs(list) do
            local dpt = tonumber(e.depth) or 1
            if not min_depth or dpt < min_depth then min_depth = dpt end
        end
        toc = {}
        for _i, e in ipairs(list) do
            if (tonumber(e.depth) or 1) == min_depth and tonumber(e.page) and #toc < 300 then
                toc[#toc + 1] = { title = tostring(e.title or ""):gsub("^%s+", ""):gsub("%s+$", ""), page = tonumber(e.page) }
            end
        end
        toc_total = self.ui.document:getPageCount()
    end)
    UIManager:nextTick(function()
        step("reading stats at close", function()
            local ok, Stats = pcall(require, "orbitshelf_stats")
            if ok and type(Stats) == "table" then Stats.saveOnClose(file, toc, toc_total) end
        end)
    end)
end

-- KOReader saving its settings (closing a book, exit, sleep): the saved lists, if changed
function OrbitShelf:onFlushSettings()
    step("save lists", O.flushPageCache)
end

return OrbitShelf
