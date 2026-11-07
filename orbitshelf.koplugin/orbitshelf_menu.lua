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
                        both = _("Both"), manual = _("Update Now Only") }
                    return T(_("Check For New Books: %1"), names[cfg.offline_update] or names.wifi)
                end,
                help_text = _("When Offline Library looks for new or changed books by itself. On Wi-Fi Connect: when KOReader starts and every time Wi-Fi connects (the default). On Refresh / Sync: when you tap the hero's Sync button or swipe down to refresh a BookOrbit shelf. Both. Update Now Only: never by itself. A run that was cut short by Wi-Fi going off always finishes when it's back."),
                enabled_func = function() return cfg.offline_library end,
                sub_item_table = (function()
                    local out = {}
                    for _i, opt in ipairs({ { "wifi", _("On Wi-Fi Connect") }, { "refresh", _("On Refresh / Sync") },
                            { "both", _("Both") }, { "manual", _("Update Now Only") } }) do
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

local function menuItems()
    local bo_ok = function() return bookOrbitInstalled() end
    local items = {}
    if not bookOrbitInstalled() then
        items[#items + 1] = { text = _("BookOrbit plugin not found"), enabled_func = function() return false end, separator = true }
    elseif not bookOrbitSignedIn() then
        items[#items + 1] = { text = _("Sign in to BookOrbit first"), enabled_func = function() return false end, separator = true }
    end
    items[#items + 1] = toggle("use_bookorbit", _("Use BookOrbit In Bookshelf"),
        _("Adds a BookOrbit shelf source to Bookshelf: Library, Recently added, Recently read, Series, Authors, Genres and Collections, books not on the device included."),
        function()
            if cfg.use_bookorbit then registerSource() else unregisterSource() end
        end, bo_ok)
    items[#items + 1] = toggle("auto_rewrite_stock", _("Rewrite Stock Series / Authors / Genres"),
        _("Points Bookshelf's own Series, Authors, Genres, Recent and Latest chips at BookOrbit. Off puts the stock chips back."),
        function()
            pcall(applyAutoRewrite)
            local bs = getBookshelf()
            if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
        end, function() return cfg.use_bookorbit and bookOrbitInstalled() end)
    items[#items].separator = true
    items[#items + 1] = {
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
        separator = true,
    }
    items[#items + 1] = {
        text = _("Add To Collection"),
        sub_item_table = {
            toggle("add_to_collection", _("Add To Collection In Book Menu"),
                _("Hold the hero, or tap a book that isn't on the device: Add To Collection lists your BookOrbit collections (✓ = the book is in it). Tap one to add or remove the book, or make a new collection. It signs in like the web app, with your BookOrbit password. With BookOrbit Tweaks installed it uses that patch's sign-in; the saved password is shared either way."),
                nil),
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
    }
    items[#items + 1] = offlineMenu()
    items[#items + 1] = {
        text = _("Hero"),
        sub_item_table = {
            toggle("hero_pills", _("Download / Remove Buttons"),
                _("A BookOrbit book not on the device: Download and Open In BookOrbit at the bottom of the hero. One on the device: small Remove From Device and Open In BookOrbit icons at the bottom right."),
                rebuildShelf),
            toggle("hero_sync", _("Sync Button"),
                _("A small Sync icon at the bottom right of the hero for BookOrbit books: pulls the BookOrbit lists fresh and runs BookOrbit's sync all books."),
                rebuildShelf),
            {
                text_func = function()
                    local names = { small = _("Small"), medium = _("Medium"), large = _("Large") }
                    return T(_("Button Size: %1"), names[cfg.hero_button_size] or names.small)
                end,
                help_text = _("Size of the hero's Download / Open In BookOrbit buttons and the round Remove / Open / Sync icons. Small leaves the most room for the description."),
                enabled_func = function() return cfg.hero_pills or cfg.hero_sync end,
                sub_item_table = (function()
                    local out = {}
                    for _i, opt in ipairs({ { "small", _("Small") }, { "medium", _("Medium") }, { "large", _("Large") } }) do
                        out[#out + 1] = {
                            text = opt[2],
                            radio = true,
                            checked_func = function() return (cfg.hero_button_size or "small") == opt[1] end,
                            keep_menu_open = true,
                            callback = function()
                                cfg.hero_button_size = opt[1]
                                saveConfig()
                                rebuildShelf()
                            end,
                        }
                    end
                    return out
                end)(),
            },
        },
    }
    items[#items + 1] = {
        text = _("Shelf"),
        sub_item_table = {
            {
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
                help_text = _("BookOrbit doesn't send genres with its book lists, so each book's genres and tags are looked up once from its BookOrbit page, in the background (about 2 minutes for 130 books, Wi-Fi on). Books on the device use the genres in their own file. Wi-Fi off pauses it; it carries on when Wi-Fi is back. Afterwards only new or changed books are looked up."),
                enabled_func = function() return bookOrbitInstalled() and not Genres.running end,
                keep_menu_open = true,
                callback = function() Genres.asked = true; Genres.build(false) end,
            },
            {
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
                separator = true,
            },
            toggle("search_bookorbit", _("Search BookOrbit"),
                _("Bookshelf's search looks in your BookOrbit library instead of the books on the device. Results open like a folder; back returns to where you were. With Wi-Fi off it searches the saved library list (title, author, series, genres). Off by default."),
                nil),
        },
    }
    items[#items + 1] = {
        text = _("Flash"),
        help_text = _("Full refreshes to clear e-ink ghosting, each one on its own. All off by default; turn on only the ones you need."),
        sub_item_table = {
            toggle("flash_hero", _("Hero When It Changes"),
                _("Flashes the hero clean when it shows another book, so the last cover doesn't show faintly behind the new one. Takes a moment longer. Off by default."),
                nil),
            {
                text_func = function()
                    local n = tonumber(cfg.flash_hero_every) or 1
                    return n <= 1 and _("Hero: Every Change") or T(_("Hero: Every %1th Change"), n)
                end,
                help_text = _("How often the hero flashes when Hero When It Changes is on. Every Change cleans every time but each tap waits for the flash; every 4th or 6th keeps most taps quick and still clears the ghosting regularly."),
                enabled_func = function() return cfg.flash_hero end,
                sub_item_table = (function()
                    local out = {}
                    for _i, n in ipairs({ 1, 4, 6 }) do
                        out[#out + 1] = {
                            text = n == 1 and _("Every Change") or T(_("Every %1th Change"), n),
                            radio = true,
                            checked_func = function() return (tonumber(cfg.flash_hero_every) or 1) == n end,
                            keep_menu_open = true,
                            callback = function()
                                cfg.flash_hero_every = n
                                saveConfig()
                            end,
                        }
                    end
                    return out
                end)(),
            },
            (function()
                local t = toggle("flash_shelf", _("Shelf Page Turns"),
                    _("Every page turn of the shelf is a full refresh, to clear ghosting. Page turns skip their animation and take a little longer. Bookshelf's own \"Use E-ink refresh rate for shelf pages\" flashes only as often as KOReader's Full refresh rate. Off by default."),
                    nil)
                t.separator = true
                return t
            end)(),
            toggle("flash_description", _("Book Description"),
                _("The Book Description popup flashes when it opens and when it closes, to clear ghosting. Off by default."), nil),
            toggle("flash_hold_menu", _("Hold Menu (BookOrbit Books)"),
                _("OrbitShelf's menu when you hold the hero of a BookOrbit book flashes when it opens and when it closes. Off by default."), nil),
            toggle("flash_download_menu", _("Download Window"),
                _("The window for a book that isn't on the device (Download, Open In BookOrbit, Book Description …) flashes when it opens and when it closes. Off by default."), nil),
            toggle("flash_book_menu", _("Bookshelf's Book Menu"),
                _("Bookshelf's own menu when you hold a book that's on the device flashes when it opens and when it closes. Off by default."),
                function() O.hookPopupFlash() end),
            toggle("flash_shelf_editor", _("Shelf Editor"),
                _("Bookshelf's shelf editor (hold a shelf tab) flashes when it opens and when it closes. Off by default."),
                function() O.hookPopupFlash() end),
        },
    }
    items[#items + 1] = {
        text = _("Footer"),
        sub_item_table = {
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
            toggle("close_only_menu", _("Close Only (No Hamburger)"),
                _("The hamburger becomes a close X: one tap closes Bookshelf, no menu first."),
                function() hookCloseOnlyMenu() rebuildShelf() end),
            {
                text_func = function()
                    return T(_("Close Control: %1"),
                        cfg.close_menu_side == "left" and _("Left")
                        or cfg.close_menu_side == "right" and _("Right")
                        or _("Bookshelf's Side"))
                end,
                enabled_func = function() return cfg.close_only_menu end,
                help_text = _("Which bottom corner the close X sits in. Bookshelf's Side follows Bookshelf's own Start menu position (left unless you changed it there)."),
                sub_item_table = (function()
                    local t = {}
                    for _i, side in ipairs({ { "left", _("Left") }, { "right", _("Right") }, { "bottom", _("Bookshelf's Side") } }) do
                        t[#t + 1] = {
                            text = side[2],
                            radio = true,
                            keep_menu_open = true,
                            checked_func = function() return (cfg.close_menu_side or "bottom") == side[1] end,
                            callback = function()
                                cfg.close_menu_side = side[1]
                                saveConfig()
                                hookCloseOnlyMenu()
                                rebuildShelf()
                            end,
                        }
                    end
                    return t
                end)(),
            },
        },
        separator = true,
    }
    items[#items + 1] = cleanUpCacheItem()
    items[#items + 1] = toggle("diagnostics", _("Diagnostics"),
        _("For troubleshooting: writes what OrbitShelf does (shelf loads, covers, downloads, hero, timings) to crash.log, tagged \"orbitshelf diag\", for 30 minutes after each start or after turning it on. Turns itself off after 3 days. Problems go to crash.log either way. Off by default."),
        function() if cfg.diagnostics then O.startDiag(true) end end)
    return items
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
