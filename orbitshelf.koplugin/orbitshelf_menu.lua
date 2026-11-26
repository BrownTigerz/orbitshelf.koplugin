-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local BoCovers, Genres, MENU_ID, Offline, SOURCE_ID, T = O.BoCovers, O.Genres, O.MENU_ID, O.Offline, O.SOURCE_ID, O.T
local UIManager, _, applyAutoRewrite, bookOrbitInstalled, bookOrbitSignedIn, cfg = O.UIManager, O._, O.applyAutoRewrite, O.bookOrbitInstalled, O.bookOrbitSignedIn, O.cfg
local clearPageCache, getBookshelf, hookCloseOnlyMenu, hookFooterCritter, isWifiOn, page_cache = O.clearPageCache, O.getBookshelf, O.hookCloseOnlyMenu, O.hookFooterCritter, O.isWifiOn, O.page_cache
local registerSource, resetPick, saveConfig, savePageCache, unregisterSource = O.registerSource, O.resetPick, O.saveConfig, O.savePageCache, O.unregisterSource

-- ---- Settings menu ----------------------------------------------------------------

-- Grouped like the other patches: the two main switches first, then Hero, Shelf,
-- Footer, and Clean Up Cache at the end.
local function rebuildShelf()
    local bs = getBookshelf()
    if bs and type(bs._rebuild) == "function" then pcall(bs._rebuild, bs) end
end

local function toggle(key, label, help, after, enabled_func)
    return {
        text = label,
        help_text = help,
        checked_func = function() return cfg[key] and true or false end,
        enabled_func = enabled_func,
        keep_menu_open = true,
        callback = function()
            cfg[key] = not cfg[key]
            saveConfig()
            if after then pcall(after) end
        end,
    }
end

local function critterSays(key, label)
    return {
        text = label,
        checked_func = function() return cfg[key] and true or false end,
        enabled_func = function() return cfg.footer_critter end,
        keep_menu_open = true,
        callback = function()
            local on = 0
            for _i, k in ipairs({ "critter_say_page", "critter_say_witty", "critter_say_recs", "critter_say_quotes" }) do
                if cfg[k] then on = on + 1 end
            end
            if cfg[key] and on <= 1 then return end -- keep at least one
            cfg[key] = not cfg[key]
            saveConfig()
            resetPick()
            rebuildShelf()
        end,
    }
end

local function cleanUpCacheItem()
    return {
        text = _("Clean Up Cache…"),
        help_text = _("Old covers and leftovers go. The newest cover of each book is kept (at most 600). Half-finished downloads and deleted Side Panel downloads are removed. The saved BookOrbit lists are pulled fresh. Nothing you set changes, and nothing on your BookOrbit server."),
        keep_menu_open = true,
        callback = function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Clean up the cache?\n\nOld covers and leftovers go. Newest cover of each book is kept (at most 600). Half-finished downloads and deleted Side Panel downloads are removed. Nothing you set changes, and nothing on your BookOrbit server."),
                ok_text = _("Clean Up"),
                ok_callback = function()
                    local res = BoCovers.cleanUp()
                    -- 2.1.8: Reading Stats' saved numbers (worked out again when needed)
                    pcall(function()
                        local okS, Stats = pcall(require, "orbitshelf_stats")
                        if okS and type(Stats) == "table" and Stats.clearStore then
                            Stats.clearStore()
                        else
                            os.remove(require("datastorage"):getDataDir() .. "/cache/bookorbit/orbitshelf_stats.lua")
                        end
                    end)
                    -- Offline Library with Wi-Fi off: keep the lists, they can't be pulled now
                    if not (cfg.offline_library and not isWifiOn()) then
                        clearPageCache()
                        savePageCache()
                    end
                    local bs = getBookshelf()
                    if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
                    collectgarbage()
                    local msg
                    if (res.files or 0) + (res.entries or 0) == 0 then
                        msg = _("Cache already clean")
                    else
                        local bits = {}
                        if res.files > 0 then
                            bits[#bits + 1] = string.format("%d old files (%.1f MB)", res.files, (res.bytes or 0) / 1048576)
                        end
                        if res.entries > 0 then
                            bits[#bits + 1] = string.format("%d stale downloads", res.entries)
                        end
                        msg = _("Cleaned: ") .. table.concat(bits, ", ")
                    end
                    UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 3 })
                end,
            })
        end,
    }
end

-- Offline Library menu: on / off, where it's at, Update Now, Delete
local function offlineStart()
    local books = Genres.library() or {}
    local todo = #Genres.missing(books, true)
    if todo == 0 and #books > 0 then
        Genres.build(true)
        Genres.note(_("Offline Library ready"))
        return
    end
    local n = todo > 0 and todo or #books
    local mins = math.max(1, math.floor(n * 0.3 / 60 + 0.5))
    local mb = math.max(1, math.floor(n * 25 / 1024 + 0.5))
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = n > 0
            and T(_("Save the library for offline?\n\nEvery BookOrbit book's cover and details (description, pages, genres) are saved on the device, not the books themselves: %1 books, about %2 MB, about %3 min with Wi-Fi on. It runs in the background. Wi-Fi off pauses it, and it carries on when Wi-Fi is back. New books are added when Wi-Fi comes on."), n, mb, mins)
            or _("Save the library for offline?\n\nEvery BookOrbit book's cover and details are saved on the device, not the books themselves. It runs in the background with Wi-Fi on."),
        ok_text = _("Start"),
        cancel_text = _("Later"),
        ok_callback = function() Genres.build(false) end,
    })
end

-- the saved lists and the hero lose the saved details at once (off or deleted)
local function offlineForgetShown()
    for _k, entry in pairs(page_cache) do
        if type(entry) == "table" and type(entry.items) == "table" then
            for _i, rec in ipairs(entry.items) do Offline.fill(rec) end
        end
    end
    pcall(function()
        local bs = getBookshelf()
        local w = bs and bs._widget
        if type(w) == "table" then
            w._hero_book_cache = nil
            if type(w._preview_book) == "table" then Offline.fill(w._preview_book) end
        end
    end)
end

local function offlineDelete(turn_off)
    if Genres.running then Genres.stop(false) end
    Offline.delete()
    if turn_off then cfg.offline_library = false end
    offlineForgetShown()
    if turn_off then cfg.offline_library = false; saveConfig() end
    -- covers back to the usual: newest per book, at most 600
    local was = cfg.offline_library
    cfg.offline_library = false
    pcall(BoCovers.cleanUp)
    cfg.offline_library = was
    Offline.sizeChanged()
    savePageCache()
    local bs = getBookshelf()
    if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
end

local function offlineMenu()
    return {
        text = _("Offline Library"),
        sub_item_table = {
            {
                text = _("Keep Library Offline"),
                help_text = _("Saves every BookOrbit book's cover and details (description, pages, published, genres) on the device, so the whole library shows on the shelf with Wi-Fi off. Books themselves are not downloaded: those still show Download. Off by default."),
                enabled_func = function() return bookOrbitInstalled() and cfg.use_bookorbit end,
                checked_func = function() return cfg.offline_library end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    if not cfg.offline_library then
                        cfg.offline_library = true
                        saveConfig()
                        Genres.listen()
                        offlineStart()
                    else
                        UIManager:show(require("ui/widget/multiconfirmbox"):new{
                            text = _("Turn off Offline Library?\n\nKeep the saved covers and details for later, or delete them?"),
                            choice1_text = _("Keep"),
                            choice1_callback = function()
                                if Genres.running then Genres.stop(false) end
                                cfg.offline_library = false
                                saveConfig()
                                offlineForgetShown()
                                savePageCache()
                                local bs = getBookshelf()
                                if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
                                if touchmenu then touchmenu:updateItems() end
                            end,
                            choice2_text = _("Delete"),
                            choice2_callback = function()
                                offlineDelete(true)
                                if touchmenu then touchmenu:updateItems() end
                            end,
                        })
                    end
                end,
            },
            {
                text_func = function()
                    if not cfg.offline_library then return _("Status: off") end
                    local mb = Offline.size() / 1048576
                    if Genres.running and Genres.full then
                        return T(_("Status: saving, %1 of %2"), Genres.done, Genres.total)
                    end
                    local books = Genres.library() or {}
                    local left = #Genres.missing(books, true)
                    if Genres.paused and left > 0 then
                        return T(_("Status: paused (Wi-Fi off), %1 left"), left)
                    end
                    return T(_("Status: %1 of %2 books · %3 MB"), math.max(0, #books - left), #books,
                        string.format("%.1f", mb))
                end,
                enabled_func = function() return false end,
            },
            {
                text = _("Update Now"),
                help_text = _("Pulls the library list fresh and saves any book that's new, changed, or still missing its cover or details. Needs Wi-Fi."),
                enabled_func = function() return cfg.offline_library and not Genres.running end,
                keep_menu_open = true,
                callback = function()
                    Genres.updateNow(false)
                end,
            },
            {
                text_func = function()
                    local names = { wifi = _("On Wi-Fi Connect"), refresh = _("On Refresh / Sync"),
                        both = _("Both"), manual = _("Off (Update Now only)") }
                    return T(_("Check For New Books: %1"), names[cfg.offline_update] or names.wifi)
                end,
                help_text = _("When Offline Library looks for new or changed books by itself. On Wi-Fi Connect: when KOReader starts and every time Wi-Fi connects (the default). On Refresh / Sync: when you tap the hero's Sync button or swipe down to refresh a BookOrbit shelf. Both. Off (Update Now only): never by itself; new books come in when you tap Update Now, the row below. A run that was cut short by Wi-Fi going off always finishes when it's back."),
                enabled_func = function() return cfg.offline_library end,
                sub_item_table = (function()
                    local out = {}
                    for _i, opt in ipairs({ { "wifi", _("On Wi-Fi Connect") }, { "refresh", _("On Refresh / Sync") },
                            { "both", _("Both") }, { "manual", _("Off (Update Now only)") } }) do
                        out[#out + 1] = {
                            text = opt[2],
                            radio = true,
                            checked_func = function() return (cfg.offline_update or "wifi") == opt[1] end,
                            keep_menu_open = true,
                            callback = function()
                                cfg.offline_update = opt[1]
                                saveConfig()
                            end,
                        }
                    end
                    return out
                end)(),
            },
            {
                text = _("Delete Offline Library…"),
                help_text = _("Deletes the saved details and trims covers back to the usual (newest per book, at most 600), and turns Offline Library off. Books on the device are not touched."),
                enabled_func = function() return Offline.count() > 0 or cfg.offline_library end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    UIManager:show(require("ui/widget/confirmbox"):new{
                        text = _("Delete the offline library?\n\nSaved covers and details go. Books on the device stay."),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            offlineDelete(true)
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
            },
        },
    }
end

-- 1.3.8: one radio row of a choice menu
local function radio(label, is_on, set)
    return {
        text = label,
        radio = true,
        keep_menu_open = true,
        checked_func = is_on,
        callback = function()
            set()
            saveConfig()
        end,
    }
end

-- 1.3.8: Flash as one choice, worked out from the eight 1.x switches (kept as they
-- are). A mix that isn't one of the four shows as Custom and keeps working exactly as
-- before until another choice is picked.
local FLASH_POPUPS = { "flash_description", "flash_hold_menu", "flash_download_menu", "flash_book_menu", "flash_shelf_editor" }
local function flashLevel()
    local n = 0
    for _i, k in ipairs(FLASH_POPUPS) do if cfg[k] then n = n + 1 end end
    local popups = n == #FLASH_POPUPS and "all" or (n == 0 and "none" or "some")
    if popups == "some" then return "custom" end
    local shelf, hero = cfg.flash_shelf and true or false, cfg.flash_hero and true or false
    if popups == "none" and not shelf and not hero then return "off" end
    if popups == "all" and not shelf and not hero then return "popups" end
    if popups == "all" and shelf and not hero then return "popups_shelf" end
    if popups == "all" and shelf and hero then return "all" end
    return "custom"
end
local FLASH_NAMES = { off = _("Off"), popups = _("Popups"), popups_shelf = _("Popups + Shelf Pages"),
    all = _("Everything"), custom = _("Custom (kept from 1.x)") }
local function nextSeriesMenu()
    local function mode()
        if not cfg.next_in_series then return "off" end
        return cfg.next_series_mode == "queue" and "queue" or "ask"
    end
    local names = { off = _("Off"), ask = _("Ask"), queue = _("Add To Queue") }
    return {
        text_func = function() return T(_("Next Book In Series: %1"), names[mode()]) end,
        help_text = _("Finishing a BookOrbit book when the next one in its series isn't on the device. Ask: back on the home screen, you're asked whether to download it (nothing pops up inside the book). Add To Queue: no question, it goes into the Queue and downloads with Wi-Fi on (now, or at the next connect). Off by default."),
        sub_item_table_func = function()
            return {
                radio(names.off, function() return mode() == "off" end, function() cfg.next_in_series = false end),
                radio(names.ask, function() return mode() == "ask" end, function()
                    cfg.next_in_series = true
                    cfg.next_series_mode = "ask"
                end),
                radio(names.queue, function() return mode() == "queue" end, function()
                    cfg.next_in_series = true
                    cfg.next_series_mode = "queue"
                end),
            }
        end,
    }
end

local function closeXMenu()
    local function side()
        if not cfg.close_only_menu then return "off" end
        return cfg.close_menu_side or "bottom"
    end
    local names = { off = _("Off"), left = _("Left"), right = _("Right"), bottom = _("Bookshelf's Side") }
    local function set(v)
        if v == "off" then
            cfg.close_only_menu = false
        else
            cfg.close_only_menu = true
            cfg.close_menu_side = v
        end
        saveConfig()
        hookCloseOnlyMenu()
        rebuildShelf()
    end
    return {
        text_func = function() return T(_("Close X: %1"), names[side()]) end,
        help_text = _("The footer's hamburger becomes a close X: one tap closes Bookshelf, no menu first. Left or Right: that bottom corner. Bookshelf's Side: where Bookshelf's own Start menu sits. Off: Bookshelf's hamburger as usual."),
        sub_item_table_func = function()
            local out = {}
            for _i, v in ipairs({ "off", "left", "right", "bottom" }) do
                out[#out + 1] = {
                    text = names[v],
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function() return side() == v end,
                    callback = function() set(v) end,
                }
            end
            return out
        end,
    }
end

local function homeMenu()
    local function tabName(id)
        local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
        local tab = ok and id and TabModel.getById(id)
        return tab and tostring(tab.label or tab.id) or nil
    end
    local function set(on, target)
        cfg.home_button = on
        if on then cfg.home_target = target end
        saveConfig()
        pcall(O.hookHomeButton)
        rebuildShelf()
    end
    return {
        text_func = function()
            if not cfg.home_button then return _("Home Button: Off") end
            return T(_("Home Button: %1"), cfg.home_target and (tabName(cfg.home_target) or _("This Shelf")) or _("This Shelf"))
        end,
        help_text = _("A house in the footer corner opposite the close X / hamburger. This Shelf: one tap back to page 1 of the shelf you're on (inside a folder it comes back out first). Or pick a shelf: always page 1 of that one. Off by default."),
        sub_item_table_func = function()
            local t = {
                {
                    text = _("Off"), radio = true, keep_menu_open = true,
                    checked_func = function() return not cfg.home_button end,
                    callback = function() set(false) end,
                },
                {
                    text = _("This Shelf"), radio = true, keep_menu_open = true,
                    checked_func = function() return cfg.home_button and not cfg.home_target end,
                    callback = function() set(true, false) end,
                    separator = true,
                },
            }
            local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
            local tabs = ok and type(TabModel.getActive) == "function" and TabModel.getActive() or {}
            for _i, tab in ipairs(tabs) do
                local id = tab.id
                t[#t + 1] = {
                    text = tostring(tab.label or id), radio = true, keep_menu_open = true,
                    checked_func = function() return cfg.home_button and cfg.home_target == id end,
                    callback = function() set(true, id) end,
                }
            end
            if #tabs == 0 then
                t[#t + 1] = { text = _("Open Bookshelf once to list its shelves"), enabled_func = function() return false end }
            end
            return t
        end,
    }
end

-- 1.3.8: Download / Remove buttons and the Sync icon as one switch. Each 1.x switch is
-- kept as it was; it shows on when either was on, and turning it on or off sets both.
local function group(label, items, help)
    return { text = label, help_text = help, sub_item_table = items }
end

-- 2.0.0: Help, at the bottom of Tools › OrbitShelf. One topic per window (TextViewer).
local HELP = {
    { _("Getting Started"), _([[OrbitShelf puts your BookOrbit library inside Bookshelf.

1. Sign in to BookOrbit (BookOrbit's own menu).
2. Tools › OrbitShelf › Shelves › Use BookOrbit In Bookshelf.
3. In Bookshelf's shelf editor, pick BookOrbit shelves: Recently Added, Authors, Series, Genres, Queue, Up Next and more.

Tap a book on the device to open it. Tap one that isn't to see it in the hero (Download / Status / BookOrbit). Hold a book for its Book Page or the quick menu (Books › Hold A Book Opens).]]) },
    { _("Shelves"), _([[BookOrbit shelves come from your library list, saved on the device, so they open quickly and work offline.

• Up Next: for every series you've started, the next book after the furthest one you've read or are reading. A series with a missing or doubled number is skipped.
• Queue: books waiting to download. A reading status waiting for Wi-Fi shows on the book; Don't Send in its Reading Status drops it.
• Return To: which shelf Bookshelf opens on after you close a book.
• Search BookOrbit: search your BookOrbit library from Bookshelf's search.]]) },
    { _("Book Page"), _([[Hold a book (or pick Book Page from a book's menu) for its page. A book on this device: hold it for Bookshelf's book menu, then Book Page.

• Top: Bulk Download, Bulk Remove, Help; where the book is and free space; X closes it.
• Beside the cover: Download / Open, Reading Status / Collection, BookOrbit / Remove. A tall book has them under the cover.
• The status line: Reading, progress, and when it was last read (this device's history or BookOrbit's). A book finished on this device shows when.
• Tap the title for all of it, tap the description to read it all.
• The bottom: the series, more by the author, or similar books. Similar books are one tap away (Similar ›, or swipe left past the series / More by); ‹ Series or a swipe right goes back. Covers show their status (Read, On Hold 30%…) and On device / Queued.
• BookOrbit opens over the page; closing it comes back here. Sleep closes the page.]]) },
    { _("Downloads And The Queue"), _([[With Wi-Fi off, Download becomes Queue and Reading Status changes are saved to send later. A clock mark shows queued books.

The queue runs once, 15 seconds after Wi-Fi connects (or Download Queue Now): statuses first, then the books one at a time. A book that doesn't fit (50 MB kept free) stays queued with a note. Sleep pauses it.

Bulk Download / Bulk Remove: tick books on the shelf. Bulk Remove › Select › Finished Books ticks only the finished ones.

Remove Finished Books: removes the finished BookOrbit books you haven't opened here for a while (Not Opened For). It always asks first. Books stay in BookOrbit.]]) },
    { _("Offline Library"), _([[Saves each book's details (description, pages, genres) so the Book Page and Genres work without Wi-Fi.

Check For New Books: when it looks for new books by itself: on Wi-Fi connect, on Sync / a swipe-down refresh, both, or Off (Update Now only).

Build / Rebuild Genres runs in the background and carries on after sleep.]]) },
    { _("Look, Footer And Flashing"), _([[• Hero Buttons and their size: the hero's Download / Status / BookOrbit and the round icons.
• Cover Marks: the Not On Device mark and the Queue clock; Mark Style picks how they look.
• Colour: on, the buttons, the popups' sections, the Book Page's boxes and Settings are in colour; off (the default), everything is plain. Charts and rings keep their colours.
• Colour Theme: the colours used (Vibrant, Pastel, Ocean, …, or your own).
• Popup Style: the popups' edge: Standard, Rainbow or Solid (one colour you pick).
• Screen Flashes: how each kind of screen refreshes to clear ghosting (Book Page, its changes, Hero, Popups, Shelf Pages, Stats Page, its changes): No Flash, Quick Flash or Full Flash.
• Settings from anywhere: More ▾ › Settings on the Book Page opens the same Settings window. Groups on the left, their settings on the right; hold one for what it does.
• A switch with a › has settings: tap its box to turn it on or off, tap its words for its settings.
• Footer: the critter and what it says, the Close X, and the Home button.]]) },
    { _("Something's Wrong"), _([[• Shelves empty: check BookOrbit's sign-in and Wi-Fi, then Sync. Saved lists still show offline.
• A book missing: Sync, or Offline › Update Now.
• Slow or odd: Advanced › Diagnostics writes what OrbitShelf does to crash.log for 30 minutes after each start (off by itself after 3 days). Send crash.log.
• Clean Up Cache frees cover space; covers come back when shown.]]) },
    -- "What's New": newest version first; older versions stay below
    { _("What's New"), _([[2.2
• Reading Stats (Books › Book Page: Reading Stats): Book | Stats | All Time at the top of the Book Page. Stats: one book's time, days, pace, calendar, chapters, moments, rewards (ReadMastery), X-Ray (or KOAssistant's) and Glimpse's pictures, spoiler-free. All Time: all your reading, with Your Year (its ring and its shelf: tap a spine for that book). From this Kobo or from BookOrbit; what's seen once works offline, and BookOrbit Account › Save All Stats For Offline saves it all at once.
• Settings is a window: groups on the left, settings on the right, open until ✕.
• Look: Colour (off: everything plain), Colour Theme, Popup Style (Standard, Rainbow or Solid) and Screen Flashes for each kind of screen.
• More ▾ on the Book Page: sync, link, highlights, bookmarks, X-Ray and Manage Downloads in one popup.
• Downloads › Book Type for read-along books (text only, with narration, both, or as BookOrbit).

2.0
• The Book Page: everything about a book on one page.
• The Queue: downloads and reading statuses wait for Wi-Fi.
• Up Next shelf, Similar books, status on covers, finished dates.
• Remove Finished Books, and a Finished filter in Bulk Remove.
• Settings regrouped (Shelves, Books, Downloads, Look, Offline, Footer, Advanced); Add To Collection, Reading Status and Bulk Download / Remove are always there.
• This Help.

Nothing you set was changed by the update.]]) },
}

-- 2.0.0: a topic opens in a window sized to its text (up to 80% of the screen; a
-- longer one scrolls), not full screen
local function showHelp(title, text)
    local Screen = require("device").screen
    local TextViewer = require("ui/widget/textviewer")
    local width = math.floor(Screen:getWidth() * 0.88)
    local max_h = math.floor(Screen:getHeight() * 0.8)
    local viewer = TextViewer:new{ title = title, text = text, width = width, height = max_h }
    local ok, want = pcall(function()
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local box = viewer.box_widget
        local pad = 2 * viewer.text_padding + 2 * viewer.text_margin
        local measure = TextBoxWidget:new{
            text = text, face = box.face, width = box.width, justified = box.justified,
        }
        local text_h = measure:getSize().h
        measure:free()
        return viewer.titlebar:getHeight() + viewer.button_table:getSize().h + pad + text_h
            + Screen:scaleBySize(4)
    end)
    if ok and type(want) == "number" and want < max_h then
        viewer:free()
        viewer = TextViewer:new{ title = title, text = text, width = width, height = want }
    end
    UIManager:show(viewer)
end

local function helpMenu()
    local sub = {}
    for _i, topic in ipairs(HELP) do
        sub[#sub + 1] = {
            text = topic[1],
            keep_menu_open = true,
            callback = function()
                showHelp(topic[1], topic[2])
            end,
        }
    end
    -- 2.2.0: Quick Setup again, first
    table.insert(sub, 1, { text = _("Quick Setup"), keep_menu_open = true, help_text = _("The main picks in one popup: Hold A Book Opens, Reading Stats, Colour, Popup Style, Cover Marks, Hero Buttons, Footer Critter."),
        callback = function() if O.quickSetup then O.quickSetup() end end })
    return { text = _("Help"), help_text = _("How OrbitShelf works, one topic at a time."), sub_item_table = sub }
end

-- ---- 2.1.18 (TK): the menu regrouped -------------------------------------------------
-- Groups A to Z (Help last). In each: the switches first, A to Z, then the rest A to Z.
-- A switch with settings of its own is one row: tap its box to turn it on or off, tap
-- its words for its settings (when it's off, the words turn it on). The API key is
-- its own group, BookOrbit Account. Look › Screen Flashes replaces Flash.

-- a switch that has its own settings. get(): on?; set(on, touchmenu); sub(): its rows
local function switchWith(label, help, get, set, sub, enabled_func)
    return {
        text = label,
        help_text = help and (help .. "\n\n" .. _("Tap the box to turn it on or off; tap the words for its settings.")) or nil,
        checked_func = get,
        enabled_func = enabled_func,
        keep_menu_open = true,
        checkmark_callback = function() set(not get()) end,
        -- reached only when it's off (no rows then): the words turn it on
        callback = function(touchmenu) set(not get(), touchmenu) end,
        sub_item_table_func = function()
            if not get() then return nil end
            return sub()
        end,
    }
end

-- a group: switches first, then a line, then the rest (each list already A to Z)
local function sorted(switches, rest)
    local out = {}
    for _i, it in ipairs(switches or {}) do out[#out + 1] = it end
    if #out > 0 and rest and #rest > 0 then out[#out].separator = true end
    for _i, it in ipairs(rest or {}) do out[#out + 1] = it end
    return out
end

-- Look › Screen Flashes: one choice per kind of screen
local FLASH_WORDS = { ui = _("No Flash"), flashui = _("Quick Flash"), full = _("Full Flash") }
local function flashChoice(kind, label, help)
    return {
        text_func = function() return T(_("%1: %2"), label, FLASH_WORDS[O.flash and O.flash(kind) or "ui"]) end,
        help_text = help,
        sub_item_table_func = function()
            local out = {}
            for _i, m in ipairs({ "ui", "flashui", "full" }) do
                out[#out + 1] = radio(FLASH_WORDS[m], function() return (O.flash and O.flash(kind) or "ui") == m end, function()
                    cfg["flash_" .. kind] = m
                    -- the popups from before the sheets (Book Description, the hold and download
                    -- menus, Bookshelf's book menu and shelf editor) follow Popups too
                    if kind == "popup" then
                        for _j, k in ipairs(FLASH_POPUPS) do cfg[k] = m ~= "ui" end
                        pcall(O.hookPopupFlash)
                    end
                end)
            end
            return out
        end,
    }
end

local function screenFlashesMenu()
    local hero_names = { [0] = _("No Flash"), [1] = _("Every Change"), [4] = _("Every 4th Change"), [6] = _("Every 6th Change") }
    local function heroNow() return cfg.flash_hero and math.max(1, tonumber(cfg.flash_hero_every) or 1) or 0 end
    return {
        text = _("Screen Flashes"),
        help_text = _("How each kind of screen refreshes, to clear e-ink ghosting: No Flash, Quick Flash (a quick blink, the popup only) or Full Flash (the whole screen). Changes: another book or Series ↔ Similar on the Book Page, a tile, card, month or the Device | BookOrbit switch on the stats page."),
        sub_item_table_func = function()
            return {
                flashChoice("bookpage", _("Book Page"), _("The Book Page opening and closing. Full Flash by default.")),
                flashChoice("bookpage_change", _("Book Page Changes"), _("Another book on the Book Page, Series ↔ Similar, a strip's swipe. Quick Flash by default.")),
                {
                    text_func = function() return T(_("Hero: %1"), hero_names[heroNow()] or hero_names[1]) end,
                    help_text = _("The hero showing another book: a quick flash every time, or every 4th or 6th time so most taps stay quick."),
                    sub_item_table_func = function()
                        local out = {}
                        for _i, n in ipairs({ 0, 1, 4, 6 }) do
                            out[#out + 1] = radio(hero_names[n], function() return heroNow() == n end, function()
                                cfg.flash_hero = n > 0
                                if n > 0 then cfg.flash_hero_every = n end
                            end)
                        end
                        return out
                    end,
                },
                flashChoice("popup", _("Popups"), _("OrbitShelf's popups opening and closing (More, Manage Downloads, a book's popup, Reading Status, …) and the older ones (Book Description, Bookshelf's book menu and shelf editor). Quick Flash by default.")),
                {
                    text_func = function() return T(_("Shelf Pages: %1"), cfg.flash_shelf and FLASH_WORDS.flashui or FLASH_WORDS.ui) end,
                    help_text = _("Every shelf page turn in Bookshelf."),
                    sub_item_table_func = function()
                        return {
                            radio(FLASH_WORDS.ui, function() return not cfg.flash_shelf end, function() cfg.flash_shelf = false end),
                            radio(FLASH_WORDS.flashui, function() return cfg.flash_shelf and true or false end, function() cfg.flash_shelf = true end),
                        }
                    end,
                },
                flashChoice("stats", _("Stats Page"), _("The stats page opening and closing. Full Flash by default.")),
                flashChoice("stats_change", _("Stats Page Changes"), _("A tile or card, a month, Your Year, the Device | BookOrbit switch. Full Flash by default.")),
            }
        end,
    }
end

local function radioList(opts, get, set)
    local out = {}
    for _i, o in ipairs(opts) do
        out[#out + 1] = radio(o[2], function() return get() == o[1] end, function() set(o[1]) end)
    end
    return out
end

-- 2.1.33 (TK): Save All Stats For Offline. Only by hand, from here: every book you've
-- read in BookOrbit and your years, fetched now and saved (otherwise each is saved the
-- first time you look at it)
local STATS_SAVED_KEY = "orbitshelf_stats_offline_at"
local function saveAllStatsItem()
    return {
        text_func = function()
            local t = G_reader_settings and tonumber(G_reader_settings:readSetting(STATS_SAVED_KEY))
            if not t then return _("Save All Stats For Offline") end
            return T(_("Save All Stats For Offline: %1"), os.date("%b ", t) .. tonumber(os.date("%d", t)))
        end,
        help_text = _("Fetches BookOrbit's stats for every book you've read there, and Your Year / All Time, and saves them on this device, so they all open with Wi-Fi off. Without this, each book's stats are saved the first time you look at them. Needs Wi-Fi; it takes a little while (one look-up per book). It only runs when you tap it."),
        enabled_func = function()
            return O.Collections ~= nil and O.Collections.hasSaved ~= nil and O.Collections.hasSaved()
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            local okS, Stats = pcall(require, "orbitshelf_stats")
            if not (okS and type(Stats) == "table" and Stats.saveAllOffline) then return end
            if not isWifiOn() then
                UIManager:show(require("ui/widget/infomessage"):new{ text = _("Turn Wi-Fi on first, then Save All Stats For Offline again."), timeout = 4 })
                return
            end
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Save all stats for offline?\n\nBookOrbit's stats for every book you've read there, and your years, are fetched now and saved on this device. It takes a little while."),
                ok_text = _("Save"),
                ok_callback = function()
                    Stats.saveAllOffline(function(books, years, err)
                        if books and err ~= "cancelled" and G_reader_settings then
                            G_reader_settings:saveSetting(STATS_SAVED_KEY, os.time())
                        end
                        local msg
                        if not books then msg = tostring(err or _("Couldn't save the stats."))
                        else msg = T(_("Saved for offline: %1 books, %2 years."), books, years or 0) end
                        UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 4 })
                        if touchmenu then touchmenu:updateItems() end
                    end)
                end,
            })
        end,
    }
end

-- 2.1.34 (TK): Look › Popup Style: Rainbow, Solid (a colour of your choice) or Standard
local SOLID_ORDER = { "blue", "gold", "green", "orange", "pink", "purple", "red", "teal" }
local SOLID_NAMES = { blue = _("Blue"), gold = _("Gold"), green = _("Green"), orange = _("Orange"), pink = _("Pink"),
    purple = _("Purple"), red = _("Red"), teal = _("Teal") }
local function popupStyle()
    local st = cfg.popup_style
    return (st == "rainbow" or st == "solid") and st or "standard"
end

local function menuItems()
    local bo_ok = function() return bookOrbitInstalled() end
    local items = {}
    if not bookOrbitInstalled() then
        items[#items + 1] = { text = _("BookOrbit plugin not found"), enabled_func = function() return false end, separator = true }
    elseif not bookOrbitSignedIn() then
        items[#items + 1] = { text = _("Sign in to BookOrbit first"), enabled_func = function() return false end, separator = true }
    end
    local function clearPages()
        local bs = getBookshelf()
        if bs and type(bs._pageCacheClear) == "function" then pcall(bs._pageCacheClear, bs) end
        rebuildShelf()
    end


    -- BookOrbit Account (the API key; was Books › BookOrbit Sign-In)
    items[#items + 1] = {
        text_func = function()
            if O.Collections and O.Collections.hasSaved and O.Collections.hasSaved() then
                return _("BookOrbit Account · API key active")
            end
            return _("BookOrbit Account")
        end,
        help_text = _("The BookOrbit API key OrbitShelf uses for Add To Collection, BookOrbit's stats and Your Year (Settings > You > API keys on the website, Read and write). Saved on this device encrypted, shared with BookOrbit Tweaks. Easiest: Create API Key File, paste over USB, then Set API Key… (the file is deleted)."),
        sub_item_table = {
            {
                text = _("About The API Key"),
                keep_menu_open = true,
                callback = function() O.Collections.about() end,
            },
            {
                text = _("Create API Key File"),
                help_text = _("Writes koreader/orbitshelf_api_key.txt (over USB). Paste your bok_ key on the marked line, then use Add To Collection or Set API Key… — the file is imported and deleted."),
                callback = function()
                    if O.Collections and O.Collections.writeTempKeyFile then O.Collections.writeTempKeyFile() end
                end,
            },
            {
                text = _("Forget Saved API Key"),
                help_text = _("Removes the API key from this device (encrypted). Shared with BookOrbit Tweaks. After this, Create API Key File or Set API Key… again."),
                enabled_func = function() return O.Collections ~= nil and O.Collections.hasSaved() end,
                callback = function() O.Collections.forget() end,
            },
            {
                text_func = function()
                    if O.Collections and O.Collections.hasSaved and O.Collections.hasSaved() then return _("API Key Active") end
                    return _("Set API Key…")
                end,
                help_text = _("When a key is saved: shows active. To change it, Forget first. When none: paste or type, or use Create API Key File over USB."),
                callback = function()
                    if O.Collections and O.Collections.setKey then
                        O.Collections.setKey(O.boApiClient and O.boApiClient())
                    end
                end,
            },
            saveAllStatsItem(),
        },
    }

    -- Books
    items[#items + 1] = group(_("Books"), sorted({
        toggle("bookpage_stats", _("Book Page: Reading Stats"),
            _("The Book Page's Book | Stats switch: one screen of tiles (the book and where you are, time, days, pace, time left, Day by Day, this week, your reads, moments, chapters, pages you came back to, X-Ray, habits); tap a tile for its own page, and Your Year. From KOReader's statistics on this device, saved when a book closes; a book not read here shows BookOrbit's (saved per book). Off by default."),
            nil),
    }, {
        {
            text_func = function()
                return T(_("Hold A Book Opens: %1"), cfg.hold_opens == "page" and _("Book Page") or _("Quick Menu"))
            end,
            help_text = _("Holding a BookOrbit book that isn't on the device. Quick Menu (the default): the small popup with Download, Open In BookOrbit, Book Page and More. Book Page: the full page with the cover, details, buttons, files, the description and the series / more by the author; it works offline from what's saved."),
            sub_item_table_func = function()
                return {
                    radio(_("Book Page"), function() return cfg.hold_opens == "page" end, function() cfg.hold_opens = "page" end),
                    radio(_("Quick Menu"), function() return (cfg.hold_opens or "menu") == "menu" end, function() cfg.hold_opens = "menu" end),
                }
            end,
        },
        nextSeriesMenu(),
    }))

    -- Downloads: Book Type, the Queue, Remove Finished Books
    local ra_names = { text = _("Text Only"), narration = _("With Narration"), both = _("Both"), bookorbit = _("Same As BookOrbit") }
    local downloads = {
        {
            text_func = function() return T(_("Book Type: %1"), ra_names[cfg.readalong_download] or ra_names.text) end,
            help_text = _([[Which kind of file a read-along book (an EPUB with the book's narration in it) downloads as, for every book. A book's own Files line on its Book Page can change it for that book only.

Text Only: the book without the narration, small.
With Narration: the book with its audio. Much bigger; KOReader itself doesn't play it.
Both: the text-only copy, plus one with narration beside it. Removing the book removes both.
Same As BookOrbit: whatever this device is set to under BookOrbit's own EPUB delivery.]]),
            sub_item_table_func = function()
                return radioList({ { "both", ra_names.both }, { "bookorbit", ra_names.bookorbit }, { "text", ra_names.text },
                    { "narration", ra_names.narration } }, function() return cfg.readalong_download or "text" end,
                    function(v) cfg.readalong_download = v end)
            end,
        },
    }
    if O.Queue then
        local q = O.Queue.menu()
        downloads[#downloads + 1] = {
            text_func = function() return q.text_func() end,
            help_text = q.help_text,
            sub_item_table_func = q.sub_item_table_func,
        }
    end
    downloads[#downloads + 1] = {
        text = _("Remove Finished Books"),
        help_text = _("Removes the BookOrbit books on this device that are finished (KOReader's own status, or Read / Skimmed in BookOrbit) and that you haven't opened here for a while. It lists them and asks first. They stay in BookOrbit."),
        sub_item_table_func = function()
            return {
                {
                    text_func = function()
                        local d = tonumber(cfg.finished_days) or 30
                        return d > 0 and T(_("Not Opened For: %1 Days"), d) or _("Not Opened For: Any Time")
                    end,
                    help_text = _("Remove Now… only offers books you haven't opened on this device for this long. Any Time offers every finished book."),
                    sub_item_table_func = function()
                        local out = {}
                        for _i, d in ipairs({ 0, 7, 30, 90 }) do
                            out[#out + 1] = radio(d > 0 and T(_("%1 Days"), d) or _("Any Time"),
                                function() return (tonumber(cfg.finished_days) or 30) == d end, function() cfg.finished_days = d end)
                        end
                        return out
                    end,
                },
                { text = _("Remove Now…"), callback = function() O.removeFinishedBooks() end },
            }
        end,
    }
    items[#items + 1] = { text = _("Downloads"), help_text = O.Queue and O.Queue.menu().help_text or nil,
        sub_item_table = downloads }

    -- Footer
    local function critterSub()
        return {
            critterSays("critter_say_page", _("Page")),
            critterSays("critter_say_recs", _("Picks")),
            critterSays("critter_say_quotes", _("Sayings")),
            critterSays("critter_say_witty", _("Witty")),
        }
    end
    items[#items + 1] = group(_("Footer"), sorted({
        switchWith(_("Footer Critter"),
            _("Your SimpleUI critter in place of the page numbers at the bottom. Tap it for another line; the left and right edges still turn the page. Its settings: what it says."),
            function() return cfg.footer_critter and true or false end,
            function(on, tm)
                cfg.footer_critter = on
                saveConfig()
                hookFooterCritter()
                rebuildShelf()
                if tm then tm:updateItems() end
            end, critterSub),
    }, { closeXMenu(), homeMenu() }))

    -- Look
    local hero_size_rows = function()
        return radioList({ { "large", _("Large") }, { "medium", _("Medium") }, { "small", _("Small") } },
            function() return cfg.hero_button_size or "small" end,
            function(v) cfg.hero_button_size = v rebuildShelf() end)
    end
    local mark_rows = function()
        return radioList({ { "auto", _("Auto Black / White") }, { "badge", _("Badge") } },
            function() return cfg.mark_style == "badge" and "badge" or "auto" end,
            function(v) cfg.mark_style = v clearPages() end)
    end
    items[#items + 1] = group(_("Look"), sorted({
        switchWith(_("Cover Marks"),
            _("A small mark on the bottom-left of a BookOrbit cover whose book isn't on the device, and a clock on a queued one. Covers view only. Its settings: Mark Style (Auto Black / White, or Badge). Off by default."),
            function() return cfg.mark_not_on_device and true or false end,
            function(on, tm)
                cfg.mark_not_on_device = on
                saveConfig()
                O.Extras.hookNotOnDeviceMark()
                clearPages()
                if tm then tm:updateItems() end
            end, mark_rows),
        switchWith(_("Hero Buttons"),
            _("On the hero of a BookOrbit book: Download (Queue with Wi-Fi off) and Open In BookOrbit for one not on the device; small Remove, Open In BookOrbit and Sync icons for one that is. Its settings: Button Size."),
            function() return (cfg.hero_pills or cfg.hero_sync) and true or false end,
            function(on, tm)
                cfg.hero_pills, cfg.hero_sync = on, on
                saveConfig()
                rebuildShelf()
                if tm then tm:updateItems() end
            end, hero_size_rows),
        -- 2.1.36 (TK): off is standard
        toggle("pill_colours", _("Colour"),
            _("Colour on a colour screen: the pill buttons (Sync, Show, Book | Stats | All Time, Your Year, …), the popups' sections, the Book Page's boxes and this window, each in its own colour (or Solid's with Popup Style Solid), whatever the edge. Off: everything standard, no colours: plain pills (black with white words, white with black at night), sections outlined. The edge is still Popup Style's, and charts and rings keep their colours. Off by default.")),
    }, {
        {
            text_func = function() return T(_("Colour Theme: %1"), O.Theme and O.Theme.name() or _("Vibrant")) end,
            help_text = _("The colours of OrbitShelf's popups, the stats page and its rings, and the Book Page on a colour screen: Vibrant (as before), Pastel, Ocean, Sunset, Forest, Kobo Mono, or Custom (tap any colour to change it). Grey screens stay grey."),
            keep_menu_open = true,
            callback = function() if O.Theme then O.Theme.show() end end,
        },
        {
            -- 2.1.23 (TK): the popups' edge. 2.1.34 (TK): Solid, one colour you pick
            text_func = function()
                local st = popupStyle()
                if st == "solid" then return T(_("Popup Style: Solid · %1"), SOLID_NAMES[cfg.popup_colour] or SOLID_NAMES.blue) end
                return T(_("Popup Style: %1"), st == "rainbow" and _("Rainbow") or _("Standard"))
            end,
            help_text = _("How OrbitShelf's popups (More, Manage Downloads, X-Ray, a book's popup, the stats page's popups, Settings, …) look on a colour screen. Rainbow: an edge in the 8 colours, a rainbow grab bar and the colour line under the title. Solid: the edge, the grab bar, the colour line and every pill button in one colour you pick (Solid Colour). Standard: a plain edge, no colour line. Grey screens stay plain."),
            sub_item_table_func = function()
                local out = radioList({ { "rainbow", _("Rainbow") }, { "solid", _("Solid") }, { "standard", _("Standard") } },
                    popupStyle, function(v) cfg.popup_style = v end)
                out[#out].separator = true
                out[#out + 1] = {
                    text_func = function() return T(_("Solid Colour: %1"), SOLID_NAMES[cfg.popup_colour] or SOLID_NAMES.blue) end,
                    help_text = _("Solid's colour, from the Colour Theme's 8."),
                    enabled_func = function() return popupStyle() == "solid" end,
                    sub_item_table_func = function()
                        local opts = {}
                        for _i, n in ipairs(SOLID_ORDER) do opts[#opts + 1] = { n, SOLID_NAMES[n] } end
                        return radioList(opts, function() return SOLID_NAMES[cfg.popup_colour] and cfg.popup_colour or "blue" end,
                            function(v) cfg.popup_colour = v end)
                    end,
                }
                return out
            end,
        },
        screenFlashesMenu(),
    }))

    -- Offline: Keep Library Offline (with its settings), then the genres
    local off = offlineMenu().sub_item_table
    local keep = off[1]
    local off_rows = function()
        -- the status first, then A to Z
        return { off[2], off[4], off[5], off[3] }
    end
    local genres_build = {
        text_func = function()
            local books = Genres.library() or {}
            local left = #Genres.missing(books)
            if Genres.running and Genres.full then
                return _("Genres: coming with Offline Library")
            elseif Genres.running then
                return T(_("Genres: building, %1 of %2"), Genres.done, Genres.total)
            elseif left == 0 and #books > 0 then
                return _("Genres: ready")
            end
            return T(_("Build Genres (%1 books)"), left)
        end,
        help_text = _("BookOrbit doesn't send genres with its book lists, so each book's genres and tags are looked up once from its BookOrbit page, in the background (about 2 minutes for 130 books, Wi-Fi on). Books on the device use the genres in their own file. Wi-Fi off pauses it; it carries on when Wi-Fi is back. Afterwards only new or changed books are looked up. Offline Library does this too."),
        enabled_func = function() return bookOrbitInstalled() and not Genres.running end,
        keep_menu_open = true,
        callback = function() Genres.asked = true; Genres.build(false) end,
    }
    local genres_rebuild = {
        text = _("Rebuild Genres"),
        help_text = _("Forgets the saved genres and looks every book up again. Use it after changing genres or tags in BookOrbit for many books at once."),
        enabled_func = function() return bookOrbitInstalled() and not Genres.running end,
        keep_menu_open = true,
        callback = function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Rebuild genres?\n\nEvery book's genres are looked up again, in the background."),
                ok_text = _("Rebuild"),
                ok_callback = function()
                    Genres.store = {}
                    Genres.save()
                    Genres.asked = true
                    Genres.build(false)
                end,
            })
        end,
    }
    items[#items + 1] = group(_("Offline"), sorted({
        switchWith(_("Keep Library Offline"), keep.help_text,
            function() return cfg.offline_library and true or false end,
            function(_on, tm) keep.callback(tm) if tm then tm:updateItems() end end,
            off_rows, keep.enabled_func),
    }, { genres_build, genres_rebuild }))

    -- Shelves
    local return_to = {
        text_func = function()
            local id = cfg.return_shelf
            if not id then return _("Return To: Bookshelf's Choice") end
            return T(_("Return To: %1"), O.shelfLabel(id) or id)
        end,
        help_text = _("Which shelf Bookshelf shows when it opens or when you close a book. Bookshelf's Choice keeps whatever shelf you were on (Bookshelf's own behaviour); pick a shelf to always come back to it."),
        enabled_func = function() return getBookshelf() ~= nil end,
        sub_item_table_func = function()
            local out = { {
                text = _("Bookshelf's Choice (last shelf)"),
                radio = true,
                checked_func = function() return not cfg.return_shelf end,
                callback = function() cfg.return_shelf = false saveConfig() end,
                separator = true,
            } }
            local list = {}
            for _i, t in ipairs(O.shelfList()) do list[#list + 1] = t end
            table.sort(list, function(x, y) return tostring(x.label) < tostring(y.label) end)
            for _i, t in ipairs(list) do
                out[#out + 1] = {
                    text = t.label,
                    radio = true,
                    checked_func = function() return cfg.return_shelf == t.id end,
                    callback = function()
                        cfg.return_shelf = t.id
                        saveConfig()
                        pcall(O.hookReturnShelf)
                    end,
                }
            end
            return out
        end,
    }
    items[#items + 1] = group(_("Shelves"), sorted({
        toggle("auto_rewrite_stock", _("Rewrite Stock Series / Authors / Genres"),
            _("Points Bookshelf's own Series, Authors, Genres, Recent and Latest chips at BookOrbit. Off puts the stock chips back."),
            function()
                pcall(applyAutoRewrite)
                local bs = getBookshelf()
                if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
            end, function() return cfg.use_bookorbit and bookOrbitInstalled() end),
        toggle("search_bookorbit", _("Search BookOrbit"),
            _("Bookshelf's search looks in your BookOrbit library instead of the books on the device. Results open like a folder; back returns to where you were. With Wi-Fi off it searches the saved library list (title, author, series, genres). Off by default."),
            nil),
        toggle("use_bookorbit", _("Use BookOrbit In Bookshelf"),
            _("Adds a BookOrbit shelf source to Bookshelf: Library, Recently added, Recently read, Series, Authors, Genres, Queue and Collections, books not on the device included."),
            function()
                if cfg.use_bookorbit then registerSource() else unregisterSource() end
            end, bo_ok),
    }, { return_to }))

    -- Advanced: second to last, above Help (TK, Nov 22; the patch-pass order)
    items[#items + 1] = group(_("Advanced"), sorted({
        toggle("diagnostics", _("Diagnostics"),
            _("For troubleshooting: writes what OrbitShelf does (shelf loads, covers, downloads, hero, timings, how long each page takes) to crash.log, tagged \"orbitshelf diag\", for 30 minutes after each start or after turning it on. Turns itself off after 3 days. Problems go to crash.log either way. Also logs each BookOrbit look-up for Reading Stats (what was asked, how much came back) and Your Year shelf taps. Off by default."),
            function() if cfg.diagnostics then O.startDiag(true) end end),
    }, { cleanUpCacheItem() }))

    -- Help, last
    local h = helpMenu()
    if #items > 0 then items[#items].separator = true end
    items[#items + 1] = h
    return items
end
O.menuItems = menuItems

-- 2.2.0 (TK, mockup m7): Quick Setup. The main picks in one popup, each showing what you
-- have now; a tap changes it at once (and saves it). Shown once (first start with BookOrbit
-- shelves, or once after updating to 2.2, in place of the What's New note); Help › Quick
-- Setup opens it again. Nothing changes unless you pick it.
function O.quickSetup()
    if not O.Sheet then return false end
    local widget
    local function onOff(key, after)
        return { { _("Off"), function() return not cfg[key] end, function() cfg[key] = false end },
                 { _("On"), function() return cfg[key] and true or false end, function() cfg[key] = true end }, after = after }
    end
    local function refreshShelf()
        local bs = getBookshelf()
        if bs and type(bs._pageCacheClear) == "function" then pcall(bs._pageCacheClear, bs) end
        rebuildShelf()
    end
    local rows = {
        { _("Hold A Book Opens"), _("What holding a book that isn't on this device opens"), {
            { _("Quick Menu"), function() return (cfg.hold_opens or "menu") ~= "page" end, function() cfg.hold_opens = "menu" end },
            { _("Book Page"), function() return cfg.hold_opens == "page" end, function() cfg.hold_opens = "page" end } } },
        { _("Reading Stats"), _("Book | Stats | All Time on the Book Page"), onOff("bookpage_stats") },
        { _("Colour"), _("Buttons, popup sections, the Book Page's boxes and Settings in colour"), onOff("pill_colours") },
        { _("Popup Style"), _("The popups' edge"), {
            { _("Standard"), function() return cfg.popup_style ~= "rainbow" and cfg.popup_style ~= "solid" end, function() cfg.popup_style = "standard" end },
            { _("Rainbow"), function() return cfg.popup_style == "rainbow" end, function() cfg.popup_style = "rainbow" end },
            { _("Solid"), function() return cfg.popup_style == "solid" end, function() cfg.popup_style = "solid" end } } },
        { _("Cover Marks"), _("A small mark on covers of books not on this device"), onOff("mark_not_on_device", function()
            if O.Extras and O.Extras.hookNotOnDeviceMark then pcall(O.Extras.hookNotOnDeviceMark) end
            refreshShelf()
        end) },
        { _("Hero Buttons"), _("Download / Open In BookOrbit on the hero, small icons for books on the device"), {
            { _("Off"), function() return not (cfg.hero_pills or cfg.hero_sync) end, function() cfg.hero_pills, cfg.hero_sync = false, false end },
            { _("On"), function() return (cfg.hero_pills or cfg.hero_sync) and true or false end, function() cfg.hero_pills, cfg.hero_sync = true, true end },
            after = rebuildShelf } },
        { _("Footer Critter"), _("Your SimpleUI critter at the bottom of the shelf"), onOff("footer_critter", function()
            pcall(hookFooterCritter)
            rebuildShelf()
        end) },
    }
    local spec
    spec = function()
        local sections = {}
        for i = 1, #rows do
            local r = rows[i]
            local pills = {}
            for j = 1, #r[3] do
                local o = r[3][j]
                pills[#pills + 1] = { text = o[1], fill = o[2](), keep = true, colour = "blue", callback = function()
                    if o[2]() then return end
                    o[3]()
                    saveConfig()
                    if r[3].after then pcall(r[3].after) end
                    if widget then widget:rebuild(spec()) end
                end }
            end
            sections[#sections + 1] = { title = r[1], colour = O.Sheet.CYCLE and O.Sheet.CYCLE[(i - 1) % #O.Sheet.CYCLE + 1] or "blue",
                items = { { kind = "pills", list = pills } } } -- r[2]: what it is (kept short to fit one screen)
        end
        sections[#sections + 1] = { plain = true, items = { { kind = "pills", list = {
            { text = _("Done"), fill = true, callback = function() end },
        } } } }
        return { title = T(_("OrbitShelf %1"), O.VERSION or ""),
            subtitle = _("Nothing changes unless you pick it. All in Settings too."),
            cancel = false, sections = sections }
    end
    widget = O.Sheet.show(spec())
    return true
end

-- 2.1.18 (TK): the same menu as a popup over the Book Page (More ▾ › Settings), the way
-- KOReader opens its own top menu
function O.showSettingsMenu()
    -- 2.1.33 (TK, mockup m1): the Settings window; KOReader's menu only if it can't open
    if O.Settings and O.Settings.show then
        local ok, shown = pcall(O.Settings.show, menuItems)
        if ok and shown then return end
        if not ok then O.logger.warn(O.TAG, "settings window:", tostring(shown)) end
    end
    local Screen = require("device").screen
    local CenterContainer = require("ui/widget/container/centercontainer")
    local TouchMenu = require("ui/widget/touchmenu")
    local container = CenterContainer:new{ ignore = "height", dimen = Screen:getSize() }
    local tab = menuItems()
    tab.icon = "appbar.settings"
    tab.text = _("OrbitShelf")
    local menu = TouchMenu:new{ width = Screen:getWidth(), last_index = 1, tab_item_table = { tab }, show_parent = container }
    menu.close_callback = function() UIManager:close(container) end
    container[1] = menu
    UIManager:show(container)
end

-- What's New, once, the first time a BookOrbit shelf shows after the update (not on a
-- new install: only when BookOrbit shelves were already on). 2.0.0: about 2.0, with the
-- regrouped settings' current values (1.3.8's note)
-- 2.1.0: a short note about Reading Stats for anyone who already saw 2.0's
local WHATS_NEW_ID = "2.2.0"
local STATS_NOTE = _("New in 2.2: Reading Stats (Book | Stats | All Time at the top of the Book Page: turn it on in Settings › Books › Book Page: Reading Stats if it's off), Your Year, a Settings window, and Look › Colour, Colour Theme, Popup Style and Screen Flashes. Help › What's New has the rest.")
function O.whatsNew()
    if not cfg.use_bookorbit then return end
    -- 2.2.0: Quick Setup once, in place of the What's New note
    if not cfg.setup_seen then
        cfg.setup_seen, cfg.whats_new_seen = true, WHATS_NEW_ID
        saveConfig()
        UIManager:scheduleIn(1, function() pcall(O.quickSetup) end)
        return
    end
    if cfg.whats_new_seen == WHATS_NEW_ID then return end
    local saw_2_0 = cfg.whats_new_seen == "2.0.0" or cfg.whats_new_seen == "2.1.0"
    cfg.whats_new_seen = WHATS_NEW_ID
    saveConfig()
    if saw_2_0 then
        UIManager:scheduleIn(1, function()
            UIManager:show(require("ui/widget/infomessage"):new{ text = _("OrbitShelf 2.2") .. "\n\n" .. STATS_NOTE })
        end)
        return
    end
    local hero = (cfg.hero_pills or cfg.hero_sync) and _("on") or _("off")
    local close = not cfg.close_only_menu and _("Off") or (cfg.close_menu_side == "left" and _("Left")
        or cfg.close_menu_side == "right" and _("Right") or _("Bookshelf's Side"))
    local nxt = not cfg.next_in_series and _("Off") or (cfg.next_series_mode == "queue" and _("Add To Queue") or _("Ask"))
    local text = _("OrbitShelf 2.0") .. "\n\n"
        .. _("New: the Book Page (hold a book), the Queue (downloads and statuses wait for Wi-Fi), the Up Next shelf, status on covers, Remove Finished Books, and Help at the bottom of Tools › OrbitShelf.") .. "\n\n"
        .. _("Tools › OrbitShelf now has Shelves, Books, Downloads, Look, Offline, Footer, Advanced and Help.") .. "\n\n"
        .. _("Always there now: Add To Collection, Reading Status and Bulk Download / Remove (under More… in a book's menu, and on the Book Page).") .. "\n\n"
        .. _("Single choices now, set from what you had:") .. "\n"
        .. T(_("• Flash: %1"), FLASH_NAMES[flashLevel()]) .. "\n"
        .. T(_("• Hero Buttons: %1"), hero) .. "\n"
        .. T(_("• Close X: %1"), close) .. "\n"
        .. T(_("• Home Button: %1"), cfg.home_button and _("on") or _("Off")) .. "\n"
        .. T(_("• Next Book In Series: %1"), nxt) .. "\n\n"
        .. STATS_NOTE .. "\n\n"
        .. _("Nothing you set was changed.")
    UIManager:scheduleIn(1, function()
        UIManager:show(require("ui/widget/infomessage"):new{ text = text })
    end)
end

-- 2.1.33 (TK): Tools › OrbitShelf opens the Settings window (KOReader's menu closes first)
local function menuItem()
    return {
        text = _("OrbitShelf"),
        callback = function() O.showSettingsMenu() end,
    }
end

-- Registered at load time, the way Screenshot Timer does it: the file manager menu
-- is built once and then kept, so hooking it later (or editing its items after it
-- was sorted) never shows anything.
local function addToolsMenu()
    -- Add-ons (2-tweaks-menu.lua): shared registry.
    local TM = package.loaded.tweaks_mods or {}
    package.loaded.tweaks_mods = TM
    TM.entries = TM.entries or {}
    TM.entries[MENU_ID] = {
        text = _("OrbitShelf"),
        order = 120,
        where = "filemanager",
        group = "Home & Library",
        build = menuItem,
    }

    -- Fallback: Tools, when the Add-ons patch isn't there (or the entry is turned off).
    local function addToOrder()
        local ok, order = pcall(require, "ui/elements/filemanager_menu_order")
        if not ok or type(order) ~= "table" or type(order.tools) ~= "table" then return end
        for _i, v in ipairs(order.tools) do if v == MENU_ID then return end end
        local pos = #order.tools + 1
        for i, v in ipairs(order.tools) do
            if type(v) == "string" and v:find("^%-%-%-") then pos = i break end
        end
        table.insert(order.tools, pos, MENU_ID)
    end
    -- Tools, when the Add-ons patch isn't there (or the entry is turned off there):
    -- the plugin's addToMainMenu (main.lua) calls this
    function O.addMainMenu(menu_items)
        local in_addons = TM.active and (type(TM.shows) ~= "function" or TM.shows(MENU_ID))
        if type(menu_items) == "table" and not in_addons then
            addToOrder()
            local m = menuItem()
            m.sorting_hint = "tools"
            menu_items[MENU_ID] = m
        end
    end
end

pcall(addToolsMenu)


-- shared with the other files
return O
