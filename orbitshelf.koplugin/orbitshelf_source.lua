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
    elseif mode == "smart_scope" and source.smart_scope_id then
        return { smartScopeId = source.smart_scope_id, sort = "title" }
    elseif mode == "bo_library" and source.library_id then
        return { libraryId = source.library_id, sort = "title" }
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

-- Shelves of one list (a BookOrbit library, collection or smart scope) can show that
-- list's books as Series / Authors / Genres folders (shelf editor > Group By).
local SCOPED = { bo_library = true, collection = true, smart_scope = true }
local GROUP_BY = { series = true, authors = true, genres = true }

local function scopeTag(base)
    if not base then return "" end
    return "@" .. tostring(base.libraryId or base.collectionId or base.smartScopeId or "")
end

-- Build folder records for series/authors/genres from the (cached) library list, or
-- from one list's books when base (that list's BookOrbit query) is given.
local function groupFolders(mode, base)
    local books = fetchBoPage(base or { sort = "title" }, false) or {}
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
        local id = mode .. ":" .. lk .. scopeTag(base)
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

local function booksInGroup(mode, key, base)
    local books = fetchBoPage(base or { sort = "title" }, false) or {}
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

-- BookOrbit search (Shelf > Search BookOrbit): BookOrbit's own search with Wi-Fi on,
-- otherwise the saved library list (title, authors, series, genres)
local function searchBookOrbit(query)
    query = tostring(query or "")
    if isWifiOn() then
        local items = fetchBoPage({ q = query, sort = "title" }, false)
        if type(items) == "table" and #items > 0 then return items end
    end
    local needle = query:lower()
    local out = {}
    for _i, rec in ipairs(Genres.library() or {}) do
        local hay = { rec.title or "", rec.series or "" }
        for _j, a in ipairs(type(rec.authors) == "table" and rec.authors or {}) do hay[#hay + 1] = a end
        for _j, g in ipairs(Genres.of and Genres.of(rec) or {}) do hay[#hay + 1] = g end
        if table.concat(hay, "\n"):lower():find(needle, 1, true) then out[#out + 1] = rec end
    end
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

-- Smart scopes (BookOrbit's saved filters): the same way as collections, from
-- BookOrbit when Wi-Fi is on, else the list saved from the last time
local SCOPES_KEY = "orbitshelf_smart_scopes"

-- one of BookOrbit's catalog sections (smart-scopes, libraries) as { id, title }:
-- from BookOrbit with Wi-Fi on, else the list saved from the last time
local function listSection(section, save_key)
    local out, seen = {}, {}
    local function add(list)
        for _i, c in ipairs(type(list) == "table" and list or {}) do
            local id = type(c) == "table" and tonumber(c.id) or nil
            if id and not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, title = c.title or c.name or tostring(id) }
            end
        end
    end
    if isWifiOn() then
        local client = boApiClient()
        local ok, body = pcall(function() return client and client:catalogSection(section) end)
        if ok and type(body) == "table" then
            local got = {}
            for _i, e in ipairs(body.items or body.entries or {}) do
                local id = type(e) == "table" and tonumber(e.id) or nil
                if id then got[#got + 1] = { id = id, title = e.title or e.name or tostring(id) } end
            end
            if #got > 0 and G_reader_settings then G_reader_settings:saveSetting(save_key, got) end
            add(got)
        elseif not ok then
            logger.warn(TAG, section .. " fetch failed -", tostring(body))
        end
    end
    add(G_reader_settings and G_reader_settings:readSetting(save_key))
    table.sort(out, function(a, b) return tostring(a.title):lower() < tostring(b.title):lower() end)
    return out
end

local function listSmartScopes() return listSection("smart-scopes", SCOPES_KEY) end
local function listLibraries() return listSection("libraries", "orbitshelf_libraries") end

-- ---- Shelf names ------------------------------------------------------------------------
-- A BookOrbit shelf is named after its list (Authors, Recently added, the collection's
-- name …) while its name is still an automatic one, and follows the list when it's
-- changed. A name you typed is never touched. (Before 1.2.19 a new shelf was just
-- "BookOrbit", whatever it showed.)
local MODE_NAMES = {
    library = _("Library"),
    recently_added = _("Recently added"),
    recently_read = _("Recently read"),
    series = _("Series"),
    authors = _("Authors"),
    genres = _("Genres"),
    collection = _("Collection"),
    smart_scope = _("Smart Scope"),
    bo_library = _("Library"),
}

local function autoName(src)
    src = type(src) == "table" and src or {}
    local m = src.mode or "library"
    if m == "collection" and src.collection_title then return src.collection_title end
    if m == "smart_scope" and src.smart_scope_title then return src.smart_scope_title end
    if m == "bo_library" and src.library_title then return src.library_title end
    return MODE_NAMES[m] or _("BookOrbit")
end

-- a shelf name may start with an icon glyph and a space (Bookshelf keeps icons there)
local function splitIcon(label)
    local icon, rest = tostring(label or ""):match("^([\226-\244][\128-\191]+) (.*)$")
    if icon then return icon, rest end
    return nil, tostring(label or "")
end

local function isAutoName(label, src)
    local text = select(2, splitIcon(label))
    if text == "" or text == "New shelf" or text == "New chip" or text == _("BookOrbit") then return true end
    local okI, I18n = pcall(require, "lib/bookshelf_i18n")
    if okI and type(I18n) == "table" and type(I18n.gettext) == "function" and text == I18n.gettext("New shelf") then
        return true
    end
    for _m, n in pairs(MODE_NAMES) do
        if text == n or text == "BookOrbit · " .. n then return true end
    end
    return src ~= nil and text == autoName(src)
end

-- run change(target) on target.source; rename the shelf if its name was automatic
local function renameWith(target, change)
    local auto = isAutoName(target.label, target.source)
    change(target)
    if auto then
        local icon = splitIcon(target.label)
        target.label = (icon and icon .. " " or "") .. autoName(target.source)
    end
end

-- picking one of these clears the others' ids, so a shelf has one list
local function clearPicks(src)
    src.collection_id, src.collection_title = nil, nil
    src.smart_scope_id, src.smart_scope_title = nil, nil
    src.library_id, src.library_title = nil, nil
end

local function pickLibraryRaw(target, c)
    target.source = target.source or {}
    clearPicks(target.source)
    target.source.kind = SOURCE_ID
    target.source.mode = "bo_library"
    target.source.library_id = c.id
    target.source.library_title = c.title
end
local function pickLibrary(target, c)
    renameWith(target, function(t) pickLibraryRaw(t, c) end)
end

local function pickSmartScopeRaw(target, c)
    target.source = target.source or {}
    target.source.kind = SOURCE_ID
    target.source.mode = "smart_scope"
    target.source.library_id, target.source.library_title = nil, nil
    target.source.collection_id, target.source.collection_title = nil, nil
    target.source.smart_scope_id = c.id
    target.source.smart_scope_title = c.title
end
local function pickSmartScope(target, c)
    renameWith(target, function(t) pickSmartScopeRaw(t, c) end)
end

local function pickCollectionRaw(target, c)
    target.source = target.source or {}
    target.source.kind = SOURCE_ID
    target.source.mode = "collection"
    target.source.collection_id = c.id
    target.source.collection_title = c.title
    target.source.smart_scope_id, target.source.smart_scope_title = nil, nil
    target.source.library_id, target.source.library_title = nil, nil
    -- the shelf keeps its own title
end
local function pickCollection(target, c)
    renameWith(target, function(t) pickCollectionRaw(t, c) end)
end

local function setPickMode(draft, mode, label)
    renameWith(draft, function(d)
        d.source = d.source or {}
        d.source.kind = SOURCE_ID
        d.source.mode = mode
        clearPicks(d.source)
    end)
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
            for i, c in ipairs(listSmartScopes()) do
                if i > 20 then break end
                table.insert(buttons, #buttons, {{
                    text = T(_("Smart Scope: %1"), c.title),
                    callback = function()
                        UIManager:close(dialog)
                        pickSmartScope(draft, c)
                        done()
                    end,
                }})
            end
            for i, c in ipairs(listLibraries()) do
                if i > 40 then break end
                table.insert(buttons, #buttons, {{
                    text = T(_("Library: %1"), c.title),
                    callback = function()
                        UIManager:close(dialog)
                        pickLibrary(draft, c)
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
            if mode == "bo_library" and not (type(source) == "table" and source.library_id) then
                O.problem("nolib", "library shelf has no library id; edit the shelf and pick it again")
                return {}, 0
            end
            if mode == "smart_scope" and not (type(source) == "table" and source.smart_scope_id) then
                O.problem("noscope", "smart scope shelf has no smart scope id; edit the shelf and pick it again")
                return {}, 0
            end
            if drill and drill.group == "search" then
                return slice(searchBookOrbit(drill.key), offset, limit)
            end
            local group_by = SCOPED[mode] and type(source) == "table" and GROUP_BY[source.group_by or ""]
                and source.group_by or nil
            if drill and (drill.group == "series" or drill.group == "authors" or drill.group == "genres") then
                local items = booksInGroup(drill.group, drill.key, group_by and modeParams(source) or nil)
                return slice(items, offset, limit)
            end
            if group_by then
                local folders = groupFolders(group_by, modeParams(source))
                if group_by == "genres" then
                    Genres.listen()
                    Genres.offer()
                end
                return slice(folders, offset, limit)
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
            local names = MODE_NAMES
            return {
                {{
                    text = function(d)
                        local m = type(d.source) == "table" and d.source.mode or "library"
                        if m == "collection" and type(d.source) == "table" and d.source.collection_title then
                            return T(_("List: Collection · %1"), d.source.collection_title)
                        end
                        if m == "smart_scope" and type(d.source) == "table" and d.source.smart_scope_title then
                            return T(_("List: Smart Scope · %1"), d.source.smart_scope_title)
                        end
                        if m == "bo_library" and type(d.source) == "table" and d.source.library_title then
                            return T(_("List: Library · %1"), d.source.library_title)
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
                                    renameWith(d, function(t)
                                        t.source = t.source or {}
                                        t.source.mode = m
                                        if m ~= "collection" then t.source.collection_id = nil t.source.collection_title = nil end
                                        if m ~= "smart_scope" then t.source.smart_scope_id = nil t.source.smart_scope_title = nil end
                                        if m ~= "bo_library" then t.source.library_id = nil t.source.library_title = nil end
                                        if not SCOPED[m] then t.source.group_by = nil end
                                    end)
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
                        for i, c in ipairs(listSmartScopes()) do
                            if i > 20 then break end
                            buttons[#buttons + 1] = {{
                                text = T(_("Smart Scope: %1"), c.title),
                                callback = function()
                                    UIManager:close(dialog)
                                    pickSmartScope(d, c)
                                    done_row()
                                end,
                            }}
                        end
                        for i, c in ipairs(listLibraries()) do
                            if i > 40 then break end
                            buttons[#buttons + 1] = {{
                                text = T(_("Library: %1"), c.title),
                                callback = function()
                                    UIManager:close(dialog)
                                    pickLibrary(d, c)
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
                -- Group By: only for a library, collection or smart scope shelf (off = flat list)
                {{
                    text = function(d)
                        local src = type(d.source) == "table" and d.source or {}
                        if not SCOPED[src.mode or ""] then return _("Group By: for Library / Collection lists") end
                        local gb = { series = _("Series"), authors = _("Authors"), genres = _("Genres") }
                        return T(_("Group By: %1"), gb[src.group_by or ""] or _("None"))
                    end,
                    callback = function(d, done_row)
                        local src = type(d.source) == "table" and d.source or {}
                        if not SCOPED[src.mode or ""] then
                            O.Genres.note(_("Pick a Library or Collection under List"))
                            return
                        end
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local dialog
                        local function opt(value, label)
                            return {{
                                text = label,
                                callback = function()
                                    UIManager:close(dialog)
                                    d.source.group_by = value
                                    done_row()
                                end,
                            }}
                        end
                        dialog = ButtonDialog:new{
                            title = _("Group this list's books by"),
                            buttons = {
                                opt(nil, _("None (one list, A to Z)")),
                                opt("series", _("Series")),
                                opt("authors", _("Authors")),
                                opt("genres", _("Genres")),
                                {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
                            },
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
            -- named after its list while the name is still the automatic one
            if isAutoName(draft.label) then
                local icon = splitIcon(draft.label)
                draft.label = (icon and icon .. " " or "") .. autoName(draft.source)
            end
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

-- Bookshelf's source list (lib/bookshelf_sources) is a module, there for the whole
-- session; bs:registerSource only hands over to it. Bookshelf loads before OrbitShelf,
-- so at start-up the source goes straight in, without waiting for Bookshelf's window
-- (before 1.2.18: retried on the next tick, then after 1 and 3 seconds). Without that
-- module (an older Bookshelf) the running Bookshelf is asked, as before.
local function sourceRegistry()
    local ok, Sources = pcall(require, "lib/bookshelf_sources")
    if ok and type(Sources) == "table" and type(Sources.register) == "function"
            and (tonumber(Sources.API) or 0) >= 1 then
        return Sources
    end
end

local function unregisterSource()
    local Sources = sourceRegistry()
    if Sources and type(Sources.unregister) == "function" then
        pcall(Sources.unregister, SOURCE_ID)
        return
    end
    local bs = getBookshelf()
    if bs and type(bs.unregisterSource) == "function" then
        pcall(bs.unregisterSource, bs, SOURCE_ID)
    end
end

local function registerSource(ui)
    if not cfg.use_bookorbit or not bookOrbitInstalled() then
        unregisterSource()
        pcall(applyAutoRewrite)
        return false
    end
    local Sources = sourceRegistry()
    local bs = not Sources and getBookshelf(ui)
    if not (Sources or (bs and bs.registerSource and (bs.SOURCE_API or 0) >= 1)) then
        return false
    end
    local spec = buildSpec()
    local ok, why
    if Sources then
        ok, why = Sources.register(SOURCE_ID, spec)
    else
        ok, why = bs:registerSource(SOURCE_ID, spec)
    end
    if not ok then
        O.problem("register:" .. tostring(why), "Bookshelf refused the BookOrbit source:", why)
        return false
    end
    O.spec = spec
    O.source_via = Sources and "Bookshelf's source list" or "Bookshelf"
    logger.info(TAG, "BookOrbit source registered (fetch mode)")
    pcall(applyAutoRewrite)
    return true
end


-- shared with the other files
-- Bookshelf's search goes to BookOrbit instead of the device library (setting
-- search_bookorbit): the results open like a folder of the BookOrbit source, so the
-- breadcrumb shows the query and back returns to where you were.
local function hookSearch()
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" or BW._orbitshelf_search then return end
    BW._orbitshelf_search = true
    O.remember(BW, "_searchAndDrill")
    local orig = BW._searchAndDrill
    if type(orig) ~= "function" then return end
    BW._searchAndDrill = function(self, query, ...)
        if not (cfg.search_bookorbit and cfg.use_bookorbit and bookOrbitInstalled() and bookOrbitSignedIn())
                or type(self._drillInto) ~= "function" then
            return orig(self, query, ...)
        end
        self:_drillInto{
            kind = "source_nav",
            label = T(_("BookOrbit: %1"), tostring(query)),
            payload = { source_kind = SOURCE_ID, drill = { group = "search", key = query, label = query } },
        }
    end
end
O.hookSearch = hookSearch

-- ---- Return To shelf ----------------------------------------------------------------
-- Bookshelf opens on (and comes back from a book to) the shelf you were last on. With
-- Return To set, it always shows that shelf instead. Bookshelf:show is the one door:
-- opening it, closing a book, and its reader parking all come through it. A new shelf
-- widget reads Bookshelf's saved active_chip; one already there gets the shelf set and
-- a single full rebuild from its own refresh (no second rebuild).

local function shelfList()
    local ok, TabModel = pcall(require, "lib/bookshelf_tab_model")
    local out = {}
    if not (ok and type(TabModel) == "table" and type(TabModel.getActive) == "function") then return out end
    local okA, tabs = pcall(TabModel.getActive)
    for _i, t in ipairs(okA and type(tabs) == "table" and tabs or {}) do
        if type(t) == "table" and t.id ~= nil then
            local label = tostring(t.label or t.id):gsub("^%s+", "")
            out[#out + 1] = { id = t.id, label = label }
        end
    end
    return out
end

local function shelfLabel(id)
    for _i, t in ipairs(shelfList()) do
        if t.id == id then return t.label end
    end
end

local function liveShelfWidget()
    for _i, e in ipairs(UIManager._window_stack or {}) do
        local w = e.widget
        if type(w) == "table" and type(w._selectChip) == "function" and type(w.softRefresh) == "function" then
            return w
        end
    end
end

local function applyReturnShelf()
    local id = cfg.return_shelf
    if not id or not shelfLabel(id) then return end -- off, or that shelf was removed
    local okS, BS = pcall(require, "lib/bookshelf_settings_store")
    if okS and type(BS) == "table" and type(BS.save) == "function" then pcall(BS.save, "active_chip", id) end
    local w = liveShelfWidget()
    if not w or w.chip == id then return end
    if type(w._markOpdsNav) == "function" then pcall(w._markOpdsNav, w) end
    w._drilldown_path = {}
    w.chip = id
    w._cursor = 1
    if type(w._syncPageFromCursor) == "function" then pcall(w._syncPageFromCursor, w) end
    -- softRefresh (from show) does one full rebuild for this
    w._metadata_dirty_force_full_refresh = true
    w._tree_fresh = nil
end

local function hookReturnShelf()
    local bs = getBookshelf()
    local cls = type(bs) == "table" and getmetatable(bs)
    if type(cls) ~= "table" or type(cls.show) ~= "function" then return false end
    if cls._orbitshelf_return then return true end
    cls._orbitshelf_return = true
    O.remember(cls, "show")
    local orig = cls.show
    cls.show = function(self, ...)
        if cfg.return_shelf then pcall(applyReturnShelf) end
        return orig(self, ...)
    end
    O.arm()
    return true
end

O.shelfList = shelfList
O.shelfLabel = shelfLabel
O.hookReturnShelf = hookReturnShelf

O.applyAutoRewrite = applyAutoRewrite
O.registerSource = registerSource
O.unregisterSource = unregisterSource
return O
