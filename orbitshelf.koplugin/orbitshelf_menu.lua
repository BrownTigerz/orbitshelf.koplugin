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
local function setFlash(level)
    local popups = level ~= "off"
    for _i, k in ipairs(FLASH_POPUPS) do cfg[k] = popups end
    cfg.flash_shelf = level == "popups_shelf" or level == "all"
    cfg.flash_hero = level == "all"
    pcall(O.hookPopupFlash)
end

local function flashMenu()
    return {
        text_func = function() return T(_("Flash: %1"), FLASH_NAMES[flashLevel()]) end,
        help_text = _("Full refreshes to clear e-ink ghosting. Off: none. Popups: OrbitShelf's windows (Book Description, the hold and download menus) and Bookshelf's book menu and shelf editor flash when they open and close. Popups + Shelf Pages: also every shelf page turn. Everything: also the hero when it shows another book (see Hero Flash). Custom: the separate switches from 1.x, kept as you had them until you pick one of these."),
        sub_item_table_func = function()
            local out = {}
            for _i, lv in ipairs({ "off", "popups", "popups_shelf", "all" }) do
                out[#out + 1] = radio(FLASH_NAMES[lv], function() return flashLevel() == lv end, function() setFlash(lv) end)
            end
            out[#out + 1] = {
                text = FLASH_NAMES.custom,
                radio = true,
                checked_func = function() return flashLevel() == "custom" end,
                enabled_func = function() return false end,
                separator = true,
            }
            out[#out + 1] = {
                text_func = function()
                    local n = tonumber(cfg.flash_hero_every) or 1
                    return n <= 1 and _("Hero Flash: Every Change") or T(_("Hero Flash: Every %1th Change"), n)
                end,
                help_text = _("How often the hero flashes when it shows another book (with Flash: Everything). Every Change cleans every time but each tap waits for the flash; every 4th or 6th keeps most taps quick."),
                enabled_func = function() return cfg.flash_hero end,
                sub_item_table_func = function()
                    local t = {}
                    for _j, n in ipairs({ 1, 4, 6 }) do
                        t[#t + 1] = radio(n == 1 and _("Every Change") or T(_("Every %1th Change"), n),
                            function() return (tonumber(cfg.flash_hero_every) or 1) == n end,
                            function() cfg.flash_hero_every = n end)
                    end
                    return t
                end,
            }
            return out
        end,
    }
end

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
local function heroButtonsToggle()
    return {
        text = _("Hero Buttons"),
        help_text = _("On the hero of a BookOrbit book: Download (Queue with Wi-Fi off) and Open In BookOrbit for one not on the device; small Remove From Device, Open In BookOrbit and Sync icons for one that is."),
        checked_func = function() return (cfg.hero_pills or cfg.hero_sync) and true or false end,
        keep_menu_open = true,
        callback = function()
            local on = not (cfg.hero_pills or cfg.hero_sync)
            cfg.hero_pills, cfg.hero_sync = on, on
            saveConfig()
            rebuildShelf()
        end,
    }
end

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
    { _("Book Page"), _([[Hold a book (or pick Book Page from a book's menu) for its page. A book on this Kobo: hold it for Bookshelf's book menu, then Book Page.

• Top: Bulk Download, Bulk Remove, Help; where the book is and free space; X closes it.
• Beside the cover: Download / Open, Reading Status / Collection, BookOrbit / Remove. A tall book has them under the cover.
• The status line: Reading, progress, and when it was last read (this Kobo's history or BookOrbit's). A book finished on this Kobo shows when.
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
• Flash: how often the screen does a full refresh (Off, Popups, Popups + Shelf Pages, Everything).
• Footer: the critter and what it says, the Close X, and the Home button.]]) },
    { _("Something's Wrong"), _([[• Shelves empty: check BookOrbit's sign-in and Wi-Fi, then Sync. Saved lists still show offline.
• A book missing: Sync, or Offline › Update Now.
• Slow or odd: Advanced › Diagnostics writes what OrbitShelf does to crash.log for 30 minutes after each start (off by itself after 3 days). Send crash.log.
• Clean Up Cache frees cover space; covers come back when shown.]]) },
    -- "What's New": newest version first; older versions stay below
    { _("What's New"), _([[2.0
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
    return { text = _("Help"), help_text = _("How OrbitShelf works, one topic at a time."), sub_item_table = sub }
end

local function menuItems()
    local bo_ok = function() return bookOrbitInstalled() end
    local items = {}
    if not bookOrbitInstalled() then
        items[#items + 1] = { text = _("BookOrbit plugin not found"), enabled_func = function() return false end, separator = true }
    elseif not bookOrbitSignedIn() then
        items[#items + 1] = { text = _("Sign in to BookOrbit first"), enabled_func = function() return false end, separator = true }
    end

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
            local out = {{
                text = _("Bookshelf's Choice (last shelf)"),
                radio = true,
                checked_func = function() return not cfg.return_shelf end,
                callback = function() cfg.return_shelf = false saveConfig() end,
            }}
            for _i, t in ipairs(O.shelfList()) do
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
    items[#items + 1] = group(_("Shelves"), {
        toggle("use_bookorbit", _("Use BookOrbit In Bookshelf"),
            _("Adds a BookOrbit shelf source to Bookshelf: Library, Recently added, Recently read, Series, Authors, Genres, Queue and Collections, books not on the device included."),
            function()
                if cfg.use_bookorbit then registerSource() else unregisterSource() end
            end, bo_ok),
        toggle("auto_rewrite_stock", _("Rewrite Stock Series / Authors / Genres"),
            _("Points Bookshelf's own Series, Authors, Genres, Recent and Latest chips at BookOrbit. Off puts the stock chips back."),
            function()
                pcall(applyAutoRewrite)
                local bs = getBookshelf()
                if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
            end, function() return cfg.use_bookorbit and bookOrbitInstalled() end),
        return_to,
        toggle("search_bookorbit", _("Search BookOrbit"),
            _("Bookshelf's search looks in your BookOrbit library instead of the books on the device. Results open like a folder; back returns to where you were. With Wi-Fi off it searches the saved library list (title, author, series, genres). Off by default."),
            nil),
    })

    -- Books
    items[#items + 1] = group(_("Books"), {
        {
            text_func = function()
                return T(_("Hold A Book Opens: %1"), cfg.hold_opens == "page" and _("Book Page") or _("Quick Menu"))
            end,
            help_text = _("Holding a BookOrbit book that isn't on the device. Quick Menu (the default): the small menu with Download, Open In BookOrbit, Book Page and More… (Add To Collection, Reading Status, Bulk Download). Book Page: one full page with the cover, details, status, all the buttons, the description, the series in order and more by the author (or similar books); it works offline from what's saved."),
            sub_item_table_func = function()
                return {
                    radio(_("Quick Menu"), function() return (cfg.hold_opens or "menu") == "menu" end, function() cfg.hold_opens = "menu" end),
                    radio(_("Book Page"), function() return cfg.hold_opens == "page" end, function() cfg.hold_opens = "page" end),
                }
            end,
        },
        nextSeriesMenu(),
        {
            text = _("BookOrbit Sign-In"),
            help_text = _("Add To Collection signs in like the web app, with your BookOrbit password (saved on this device, encrypted). With BookOrbit Tweaks installed it uses that patch's sign-in; the saved password is shared either way."),
            sub_item_table = {
                {
                    text = _("Forget Saved BookOrbit Password"),
                    help_text = _("The password Add To Collection saved on this device (encrypted). You'll be asked again next time."),
                    enabled_func = function() return O.Collections ~= nil and O.Collections.hasSaved() end,
                    callback = function() O.Collections.forget() end,
                },
                {
                    text = _("About The Saved Password"),
                    keep_menu_open = true,
                    callback = function() O.Collections.about() end,
                },
            },
        },
    })

    -- Downloads (the Queue)
    if O.Queue then
        local q = O.Queue.menu()
        items[#items + 1] = {
            text = _("Downloads"),
            help_text = q.help_text,
            sub_item_table_func = function()
                local sub = q.sub_item_table_func()
                table.insert(sub, 1, { text_func = q.text_func, enabled_func = function() return false end })
                -- 1.3.24: Remove Finished Books
                local at = 2
                table.insert(sub, at, {
                    text = _("Remove Finished Books…"),
                    help_text = _("Removes the BookOrbit books on this device that are finished (KOReader's own status, or Read / Skimmed in BookOrbit) and that you haven't opened here for the time below. It lists them and asks first. They stay in BookOrbit."),
                    callback = function() O.removeFinishedBooks() end,
                })
                table.insert(sub, at + 1, {
                    text_func = function()
                        local d = tonumber(cfg.finished_days) or 30
                        return d > 0 and T(_("Not Opened For: %1 Days"), d) or _("Not Opened For: Any Time")
                    end,
                    help_text = _("Remove Finished Books only offers books you haven't opened on this device for this long. Any Time offers every finished book."),
                    separator = true,
                    sub_item_table_func = function()
                        local out = {}
                        for _i, d in ipairs({ 0, 7, 30, 90 }) do
                            out[#out + 1] = {
                                text = d > 0 and T(_("%1 Days"), d) or _("Any Time"),
                                radio = true,
                                checked_func = function() return (tonumber(cfg.finished_days) or 30) == d end,
                                callback = function()
                                    cfg.finished_days = d
                                    O.saveConfig()
                                end,
                            }
                        end
                        return out
                    end,
                })
                return sub
            end,
        }
    end

    -- Look
    local hero_size = {
        text_func = function()
            local names = { small = _("Small"), medium = _("Medium"), large = _("Large") }
            return T(_("Hero Button Size: %1"), names[cfg.hero_button_size] or names.small)
        end,
        help_text = _("Size of the hero's Download / Open In BookOrbit buttons and the round Remove / Open / Sync icons. Small leaves the most room for the description."),
        enabled_func = function() return cfg.hero_pills or cfg.hero_sync end,
        sub_item_table_func = function()
            local out = {}
            for _i, opt in ipairs({ { "small", _("Small") }, { "medium", _("Medium") }, { "large", _("Large") } }) do
                out[#out + 1] = {
                    text = opt[2], radio = true, keep_menu_open = true,
                    checked_func = function() return (cfg.hero_button_size or "small") == opt[1] end,
                    callback = function()
                        cfg.hero_button_size = opt[1]
                        saveConfig()
                        rebuildShelf()
                    end,
                }
            end
            return out
        end,
        separator = true,
    }
    local function clearPages()
        local bs = getBookshelf()
        if bs and type(bs._pageCacheClear) == "function" then pcall(bs._pageCacheClear, bs) end
        rebuildShelf()
    end
    items[#items + 1] = group(_("Look"), {
        heroButtonsToggle(),
        hero_size,
        toggle("mark_not_on_device", _("Cover Marks"),
            _("A small mark on the bottom-left of a BookOrbit cover whose book isn't on the device (BookOrbit's download mark), so you can see at a glance what's still to download. A book in the Queue shows a clock there either way. Reading status and progress use Bookshelf's own badges. Covers view only. Off by default."),
            function()
                O.Extras.hookNotOnDeviceMark()
                clearPages()
            end),
        {
            text_func = function()
                return T(_("Mark Style: %1"), cfg.mark_style == "badge" and _("Badge") or _("Auto Black / White"))
            end,
            help_text = _("How the cover mark looks. Auto Black / White: black on a light cover, white on a dark one, with a thin outline so it reads on a busy corner. Badge: on a small round disc in Bookshelf's badge colours, like the page count. Auto by default."),
            enabled_func = function() return cfg.mark_not_on_device end,
            sub_item_table_func = function()
                return {
                    radio(_("Auto Black / White"), function() return (cfg.mark_style or "auto") == "auto" end,
                        function() cfg.mark_style = "auto" clearPages() end),
                    radio(_("Badge"), function() return cfg.mark_style == "badge" end,
                        function() cfg.mark_style = "badge" clearPages() end),
                }
            end,
            separator = true,
        },
        flashMenu(),
    })

    -- Offline (Offline Library + genres)
    local off = offlineMenu().sub_item_table
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
    off[#off].separator = true
    off[#off + 1] = genres_build
    off[#off + 1] = genres_rebuild
    items[#items + 1] = group(_("Offline"), off)

    -- Footer
    items[#items + 1] = group(_("Footer"), {
        toggle("footer_critter", _("Footer Critter"),
            _("Your SimpleUI critter in place of the page numbers at the bottom. Tap it for another line; the left and right edges still turn the page."),
            function() hookFooterCritter() rebuildShelf() end),
        {
            text = _("Critter Says"),
            enabled_func = function() return cfg.footer_critter end,
            sub_item_table = {
                critterSays("critter_say_page", _("Page")),
                critterSays("critter_say_witty", _("Witty")),
                critterSays("critter_say_recs", _("Picks")),
                critterSays("critter_say_quotes", _("Sayings")),
            },
            separator = true,
        },
        closeXMenu(),
        homeMenu(),
    })

    -- Advanced
    items[#items + 1] = group(_("Advanced"), {
        cleanUpCacheItem(),
        toggle("diagnostics", _("Diagnostics"),
            _("For troubleshooting: writes what OrbitShelf does (shelf loads, covers, downloads, hero, timings) to crash.log, tagged \"orbitshelf diag\", for 30 minutes after each start or after turning it on. Turns itself off after 3 days. Problems go to crash.log either way. Off by default."),
            function() if cfg.diagnostics then O.startDiag(true) end end),
    })
    -- 2.0.0: Help, last
    items[#items + 1] = helpMenu()
    return items
end

-- What's New, once, the first time a BookOrbit shelf shows after the update (not on a
-- new install: only when BookOrbit shelves were already on). 2.0.0: about 2.0, with the
-- regrouped settings' current values (1.3.8's note)
local WHATS_NEW_ID = "2.0.0"
function O.whatsNew()
    if cfg.whats_new_seen == WHATS_NEW_ID or not cfg.use_bookorbit then return end
    cfg.whats_new_seen = WHATS_NEW_ID
    saveConfig()
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
        .. _("Nothing you set was changed.")
    UIManager:scheduleIn(1, function()
        UIManager:show(require("ui/widget/infomessage"):new{ text = text })
    end)
end

local function menuItem()
    return {
        text = _("OrbitShelf"),
        sub_item_table_func = menuItems,
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
