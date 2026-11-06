-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local Genres, SOURCE_ID, T, TAG, UIManager, _ = O.Genres, O.SOURCE_ID, O.T, O.TAG, O.UIManager, O._
local boApiClient, bookOrbitInstalled, bookOrbitSignedIn, cfg, fetchBoPage, getBookshelf = O.boApiClient, O.bookOrbitInstalled, O.bookOrbitSignedIn, O.cfg, O.fetchBoPage, O.getBookshelf
local isWifiOn, lfs, liveBookPath, logger, showNotOnDevice = O.isWifiOn, O.lfs, O.liveBookPath, O.logger, O.showNotOnDevice

-- ---- Grouping (Series / Authors / Genres) from the BookOrbit library -------------

local function modeParams(source)
    local mode = type(source) == "table" and source.mode or "library"
    if mode == "recently_added" then
        return { sort = "recently_added" }
    elseif mode == "recently_read" then
        return { sort = "recently_read" }
    elseif mode == "collection" and source.collection_id then
        return { collectionId = source.collection_id }
    end
    -- library / series / authors / genres all page the full library once
    return { sort = "title" }
end

local function splitNames(s)
    if type(s) ~= "string" or s == "" then return {} end
    local out = {}
    for part in s:gmatch("[^\n,;|/]+") do
        local t = part:match("^%s*(.-)%s*$")
        if t and t ~= "" then out[#out + 1] = t end
    end
    return out
end

local function groupKeysFor(rec, mode)
    if mode == "series" then
        local s = rec.series or rec.series_name
        if type(s) == "string" and s ~= "" then return { s } end
        return {}
    elseif mode == "authors" then
        if type(rec.authors) == "table" then
            local out = {}
            for _i, a in ipairs(rec.authors) do
                if type(a) == "string" and a ~= "" then out[#out + 1] = a end
            end
            if #out > 0 then return out end
        end
        if type(rec.author) == "string" and rec.author ~= "" then return { rec.author } end
        return {}
    elseif mode == "genres" then
        local built = Genres.of(rec)
        if built and #built > 0 then return built end
        if type(rec.genres) == "table" then
            local out = {}
            for _i, g in ipairs(rec.genres) do
                if type(g) == "string" and g ~= "" then out[#out + 1] = g end
            end
            if #out > 0 then return out end
        end
        return splitNames(rec.genres or rec.genre or "")
    end
    return {}
end

-- Fetch mode skips Bookshelf's own sort, so the groups are put in order here with
-- Bookshelf's sort engine (surname, articles ignored, missing values last). The
-- plain comparator is only the fallback when that module cannot be loaded.
local function sortWith(items, priority, fallback)
    local okE, Engine = pcall(require, "lib/bookshelf_sort_engine")
    if okE and type(Engine) == "table" and type(Engine.chainedComparator) == "function" then
        local okC, cmp = pcall(Engine.chainedComparator, priority)
        if okC and type(cmp) == "function" and pcall(table.sort, items, cmp) then return end
    end
    table.sort(items, fallback)
end

-- Stock Bookshelf orders: Series cards by last opened, Authors by surname,
-- Genres by book count; inside a group, series order (Series), series then
-- number (Authors / Genres).
local GROUP_CARD_ORDER = {
    series  = { { key = "last_opened", reverse = true }, { key = "series_name", reverse = false } },
    authors = { { key = "author_surname", reverse = false }, { key = "series_name", reverse = false } },
    genres  = { { key = "book_count", reverse = true }, { key = "series_name", reverse = false } },
}
local GROUP_BOOK_ORDER = {
    series  = { { key = "series_index", reverse = false }, { key = "title", reverse = false } },
    authors = { { key = "series_name", reverse = false }, { key = "series_index", reverse = false },
                { key = "title", reverse = false } },
    genres  = { { key = "series_name", reverse = false }, { key = "series_index", reverse = false },
                { key = "title", reverse = false } },
}

-- Build folder records for series/authors/genres from the (cached) library list.
local function groupFolders(mode)
    local books = fetchBoPage({ sort = "title" }, false) or {}
    local buckets, order = {}, {}
    for _i, rec in ipairs(books) do
        for _j, key in ipairs(groupKeysFor(rec, mode)) do
            local lk = key:lower()
            local b = buckets[lk]
            if not b then
                b = { title = key, books = {}, cover = nil }
                buckets[lk] = b
                order[#order + 1] = lk
            end
            b.books[#b.books + 1] = rec
            if not b.cover and rec.cover_image_path then b.cover = rec.cover_image_path end
        end
    end
    local folders = {}
    for _i, lk in ipairs(order) do
        local b = buckets[lk]
        local id = mode .. ":" .. lk
        local last
        for _j, rec in ipairs(b.books) do
            if rec.last_opened and (not last or rec.last_opened > last) then last = rec.last_opened end
        end
        folders[#folders + 1] = {
            is_folder = true,
            title = b.title,
            label = b.title,
            display_title = b.title,
            -- the fields Bookshelf's own group cards carry, so its sort keys read them
            name = b.title,
            series_name = b.title,
            last_opened = last,
            book_count = #b.books,
            cover_image_path = b.cover,
            filepath = "bookorbit://nav/" .. id,
            bookorbit_group = mode,
            bookorbit_group_key = b.title,
            source_kind = SOURCE_ID,
        }
    end
    sortWith(folders, GROUP_CARD_ORDER[mode] or GROUP_CARD_ORDER.series, function(a, b)
        return (a.title or ""):lower() < (b.title or ""):lower()
    end)
    return folders, #folders
end

local function booksInGroup(mode, key)
    local books = fetchBoPage({ sort = "title" }, false) or {}
    local want = (key or ""):lower()
    local out = {}
    for _i, rec in ipairs(books) do
        for _j, k in ipairs(groupKeysFor(rec, mode)) do
            if k:lower() == want then
                out[#out + 1] = rec
                break
            end
        end
    end
    sortWith(out, GROUP_BOOK_ORDER[mode] or GROUP_BOOK_ORDER.series, function(a, b)
        local na = tonumber(a.series_index) or tonumber(a.series_num) or 1e9
        local nb = tonumber(b.series_index) or tonumber(b.series_num) or 1e9
        if na ~= nb then return na < nb end
        return tostring(a.title or ""):lower() < tostring(b.title or ""):lower()
    end)
    return out
end

local function slice(items, offset, limit)
    offset = math.max(0, tonumber(offset) or 0)
    limit = tonumber(limit) or 50
    local total = #items
    local out = {}
    for i = offset + 1, math.min(offset + limit, total) do
        out[#out + 1] = items[i]
    end
    return out, total
end

-- Collections: from BookOrbit when Wi-Fi is on, else the list saved from the last
-- time, plus whatever the Side Panel has saved.
local COLLS_KEY = "orbitshelf_tweaks_collections"

local function fetchBoCollections()
    local client = boApiClient()
    if not client then return nil end
    local ok, body = pcall(function() return client:catalogSection("collections") end)
    if not ok or type(body) ~= "table" then
        logger.warn(TAG, "collections fetch failed -", ok and "no usable reply" or tostring(body))
        return nil
    end
    local out = {}
    for _i, e in ipairs(body.items or body.collections or body.entries or {}) do
        local id = type(e) == "table" and tonumber(e.id) or nil
        if id then out[#out + 1] = { id = id, title = e.title or e.name or tostring(id) } end
    end
    if #out > 0 and G_reader_settings then G_reader_settings:saveSetting(COLLS_KEY, out) end
    return out
end

local function listCollections()
    local out, seen = {}, {}
    local function add(list)
        for _i, c in ipairs(type(list) == "table" and list or {}) do
            local id = type(c) == "table" and tonumber(c.id) or nil
            if id and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, title = c.title or tostring(id) }
            end
        end
    end
    if isWifiOn() then add(fetchBoCollections()) end
    add(G_reader_settings and G_reader_settings:readSetting(COLLS_KEY))
    local okP, side = pcall(function() return package.loaded["simpleui_sidepanel_bo"] end)
    if okP and type(side) == "table" and type(side.collections) == "function" then
        local okC, colls = pcall(side.collections)
        if okC then add(colls) end
    end
    table.sort(out, function(a, b) return tostring(a.title):lower() < tostring(b.title):lower() end)
    return out
end

local function pickCollection(target, c)
    target.source = target.source or {}
    target.source.kind = SOURCE_ID
    target.source.mode = "collection"
    target.source.collection_id = c.id
    target.source.collection_title = c.title
    -- the shelf keeps its own title
end

local function setPickMode(draft, mode, label)
    draft.source = draft.source or {}
    draft.source.kind = SOURCE_ID
    draft.source.mode = mode
    -- the shelf keeps its own title (label is no longer written)
end

local function buildSpec()
    return {
        api = 1,
        label = function() return _("BookOrbit") end,
        available = function()
            return cfg.use_bookorbit and bookOrbitInstalled() and bookOrbitSignedIn()
        end,
        remote_prefix = "bookorbit://",
        -- fetch mode: server-style paging + folder drill for Series/Authors/Genres
        picker = true,

        pick = function(draft, done)
            local ButtonDialog = require("ui/widget/buttondialog")
            local dialog
            local function choose(mode, label)
                return {{
                    text = label,
                    callback = function()
                        UIManager:close(dialog)
                        setPickMode(draft, mode, label)
                        done()
                    end,
                }}
            end
            local buttons = {
                choose("library", _("BookOrbit · Library")),
                choose("recently_added", _("BookOrbit · Recently added")),
                choose("recently_read", _("BookOrbit · Recently read")),
                choose("series", _("BookOrbit · Series")),
                choose("authors", _("BookOrbit · Authors")),
                choose("genres", _("BookOrbit · Genres")),
                {{
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                        done(false)
                    end,
                }},
            }
            for i, c in ipairs(listCollections()) do
                if i > 20 then break end
                table.insert(buttons, #buttons, {{
                    text = T(_("Collection: %1"), c.title),
                    callback = function()
                        UIManager:close(dialog)
                        pickCollection(draft, c)
                        done()
                    end,
                }})
            end
            dialog = ButtonDialog:new{
                title = _("BookOrbit shelf"),
                buttons = buttons,
            }
            UIManager:show(dialog)
        end,

        -- fetch mode: folders for series/authors/genres, flat lists otherwise
        fetch = function(source, drill, offset, limit)
            pcall(O.checkHooks)
            local mode = type(source) == "table" and source.mode or "library"
            if mode == "collection" and not (type(source) == "table" and source.collection_id) then
                logger.warn(TAG, "collection shelf has no collection id; edit the shelf and pick the collection again")
                return {}, 0
            end
            if drill and (drill.group == "series" or drill.group == "authors" or drill.group == "genres") then
                local items = booksInGroup(drill.group, drill.key)
                return slice(items, offset, limit)
            end
            if mode == "series" or mode == "authors" or mode == "genres" then
                local folders = groupFolders(mode)
                if mode == "genres" then
                    -- after the list is in, so the count is right
                    Genres.listen()
                    Genres.offer()
                end
                return slice(folders, offset, limit)
            end
            local items = fetchBoPage(modeParams(source), false) or {}
            return slice(items, offset, limit)
        end,

        open_folder = function(folder)
            if type(folder) ~= "table" then return nil end
            return {
                label = folder.title or folder.label,
                group = folder.bookorbit_group,
                key = folder.bookorbit_group_key or folder.title,
            }
        end,

        owns = function(book)
            return book and (book.is_bookorbit or book.source_kind == SOURCE_ID
                or (type(book.filepath) == "string" and book.filepath:match("^bookorbit://"))) and true or false
        end,

        open = function(book, ctx)
            if not book or book.is_folder then return false end
            local path = book.filepath
            if type(path) == "string" and not path:match("^bookorbit://")
                    and lfs.attributes(path, "mode") == "file" then
                return path
            end
            local live = liveBookPath(book.bookorbit_id)
            if live then return live end
            showNotOnDevice(book)
            return true
        end,

        -- long-press on a book that is not on the device
        info = function(book, ctx)
            if not book or book.is_folder then return false end
            local live = liveBookPath(book.bookorbit_id)
            if live then
                if ctx and type(ctx.open) == "function" then ctx.open(live) end
                return true
            end
            showNotOnDevice(book)
            return true
        end,

        refresh = function(source, drill, done)
            if drill and drill.group then
                fetchBoPage({ sort = "title" }, true)
            else
                fetchBoPage(modeParams(source), true)
            end
            if type(done) == "function" then done() end
            pcall(O.Genres.afterRefresh)
        end,

        editor_rows = function(draft)
            local mode = type(draft.source) == "table" and draft.source.mode or "library"
            local names = {
                library = _("Library"),
                recently_added = _("Recently added"),
                recently_read = _("Recently read"),
                series = _("Series"),
                authors = _("Authors"),
                genres = _("Genres"),
                collection = _("Collection"),
            }
            return {
                {{
                    text = function(d)
                        local m = type(d.source) == "table" and d.source.mode or "library"
                        if m == "collection" and type(d.source) == "table" and d.source.collection_title then
                            return T(_("List: Collection · %1"), d.source.collection_title)
                        end
                        return T(_("List: %1"), names[m] or m)
                    end,
                    callback = function(d, done_row)
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local dialog
                        local function go(m, label)
                            return {{
                                text = label,
                                callback = function()
                                    UIManager:close(dialog)
                                    d.source = d.source or {}
                                    d.source.mode = m
                                    if m ~= "collection" then d.source.collection_id = nil d.source.collection_title = nil end
                                    done_row()
                                end,
                            }}
                        end
                        local buttons = {
                            go("library", _("Library")),
                            go("recently_added", _("Recently added")),
                            go("recently_read", _("Recently read")),
                            go("series", _("Series")),
                            go("authors", _("Authors")),
                            go("genres", _("Genres")),
                        }
                        for i, c in ipairs(listCollections()) do
                            if i > 20 then break end
                            buttons[#buttons + 1] = {{
                                text = T(_("Collection: %1"), c.title),
                                callback = function()
                                    UIManager:close(dialog)
                                    pickCollection(d, c)
                                    done_row()
                                end,
                            }}
                        end
                        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }}
                        dialog = ButtonDialog:new{
                            title = _("BookOrbit list"),
                            buttons = buttons,
                        }
                        UIManager:show(dialog)
                    end,
                }},
            }
        end,

        new_shelf = function(draft)
            draft.source = draft.source or {}
            draft.source.kind = SOURCE_ID
            draft.source.mode = draft.source.mode or "library"
            if not draft.label then draft.label = _("BookOrbit") end
        end,
    }
end

-- ---- Auto-rewrite stock Series / Authors / Genres / Recent / Latest chips ---------
-- When on, those chips' source becomes BookOrbit with the matching mode.
-- Previous sources are saved and restored when the toggle is turned off.

local STOCK_REWRITE = {
    series  = { mode = "series",         label = "BookOrbit · Series" },
    authors = { mode = "authors",        label = "BookOrbit · Authors" },
    genres  = { mode = "genres",         label = "BookOrbit · Genres" },
    recent  = { mode = "recently_read",  label = "BookOrbit · Recently read" },
    latest  = { mode = "recently_added", label = "BookOrbit · Recently added" },
}
local ORIG_TABS_KEY = "orbitshelf_tweaks_orig_tabs"

local function applyAutoRewrite()
    local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not ok or type(TabModel) ~= "table" then return end
    local okS, Store = pcall(require, "lib/bookshelf_settings_store")
    if not okS or type(Store) ~= "table" then return end

    local tabs = Store.read(TabModel.STORAGE_KEY or "tabs")
    if type(tabs) ~= "table" then
        if type(TabModel.load) == "function" then
            tabs = TabModel.load()
        elseif type(TabModel.get) == "function" then
            tabs = TabModel.get()
        end
    end
    if type(tabs) ~= "table" then return end

    if cfg.auto_rewrite_stock and cfg.use_bookorbit then
        -- Save originals once
        if not G_reader_settings:readSetting(ORIG_TABS_KEY) then
            local orig = {}
            for i, tab in ipairs(tabs) do
                if type(tab) == "table" and tab.id and STOCK_REWRITE[tab.id] then
                    orig[tab.id] = {
                        source = tab.source and { kind = tab.source.kind, mode = tab.source.mode, id = tab.source.id } or nil,
                        label = tab.label,
                    }
                end
            end
            G_reader_settings:saveSetting(ORIG_TABS_KEY, orig)
        end
        local changed = false
        for _i, tab in ipairs(tabs) do
            local map = tab and tab.id and STOCK_REWRITE[tab.id]
            if map then
                local sk = tab.source and tab.source.kind
                if sk ~= SOURCE_ID or (tab.source and tab.source.mode) ~= map.mode then
                    tab.source = { kind = SOURCE_ID, mode = map.mode }
                    changed = true
                end
            end
        end
        if changed then
            Store.save(TabModel.STORAGE_KEY or "tabs", tabs)
            logger.info(TAG, "auto-rewrite: stock chips -> BookOrbit")
        end
    else
        local orig = G_reader_settings:readSetting(ORIG_TABS_KEY)
        if type(orig) == "table" then
            local changed = false
            for _i, tab in ipairs(tabs) do
                local o = tab and tab.id and orig[tab.id]
                if o and tab.source and tab.source.kind == SOURCE_ID then
                    tab.source = o.source or { kind = tab.id }
                    changed = true
                end
            end
            if changed then
                Store.save(TabModel.STORAGE_KEY or "tabs", tabs)
                logger.info(TAG, "auto-rewrite: restored stock chip sources")
            end
            G_reader_settings:delSetting(ORIG_TABS_KEY)
        end
    end
end

local registered = false

local function unregisterSource()
    local bs = getBookshelf()
    if bs and type(bs.unregisterSource) == "function" then
        pcall(bs.unregisterSource, bs, SOURCE_ID)
    end
    registered = false
end

local function registerSource(ui)
    if not cfg.use_bookorbit or not bookOrbitInstalled() then
        unregisterSource()
        pcall(applyAutoRewrite)
        return false
    end
    local bs = getBookshelf(ui)
    if not (bs and bs.registerSource and (bs.SOURCE_API or 0) >= 1) then
        return false
    end
    local spec = buildSpec()
    local ok, why = bs:registerSource(SOURCE_ID, spec)
    if not ok then
        O.problem("register:" .. tostring(why), "Bookshelf refused the BookOrbit source:", why)
        return false
    end
    O.spec = spec
    registered = true
    logger.info(TAG, "BookOrbit source registered (fetch mode)")
    pcall(applyAutoRewrite)
    return true
end


-- shared with the other files
O.applyAutoRewrite = applyAutoRewrite
O.registerSource = registerSource
O.unregisterSource = unregisterSource
return O
