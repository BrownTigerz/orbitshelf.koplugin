-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local SOURCE_ID, T, TAG, UIManager, _, cfg = O.SOURCE_ID, O.T, O.TAG, O.UIManager, O._, O.cfg
local lfs, logger = O.lfs, O.logger

-- ---- Presence checks --------------------------------------------------------------

local function bookOrbitInstalled()
    if lfs.attributes("plugins/bookorbit.koplugin/main.lua", "mode") == "file" then return true end
    if lfs.attributes("plugins/BookOrbit.koplugin/main.lua", "mode") == "file" then return true end
    local ok = pcall(require, "bookorbit_api")
    return ok
end

local function bookOrbitSignedIn()
    local s = G_reader_settings and G_reader_settings:readSetting("bookorbit")
    return type(s) == "table" and s.server_url and s.username and s.userkey and true or false
end

local function getBookshelf(ui)
    ui = ui or (package.loaded["apps/filemanager/filemanager"]
        and package.loaded["apps/filemanager/filemanager"].instance)
    if type(ui) == "table" and type(ui.bookshelf) == "table" then return ui.bookshelf end
    -- Reader context
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if type(ReaderUI) == "table" and type(ReaderUI.instance) == "table"
            and type(ReaderUI.instance.bookshelf) == "table" then
        return ReaderUI.instance.bookshelf
    end
    return nil
end

-- ---- BookOrbit API helpers (aligned with 2-simpleui-sidepanel) --------------------

local function boApiClient()
    local s = G_reader_settings and G_reader_settings:readSetting("bookorbit")
    if type(s) ~= "table" or not s.server_url or not s.username or not s.userkey then
        return nil, "not signed in"
    end
    local ok, BookOrbitApi = pcall(require, "bookorbit_api")
    if not ok or type(BookOrbitApi) ~= "table" or type(BookOrbitApi.new) ~= "function" then
        return nil, "BookOrbit not installed"
    end
    return BookOrbitApi.new({
        server_url = s.server_url,
        username = s.username,
        userkey = s.userkey,
        device_id = s.device_id,
    })
end

local function isWifiOn()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if ok and type(NetworkMgr) == "table" then
        if type(NetworkMgr.isWifiOn) == "function" then
            local a, b = pcall(NetworkMgr.isWifiOn, NetworkMgr)
            if a then return b end
        end
        if type(NetworkMgr.isConnected) == "function" then
            local a, b = pcall(NetworkMgr.isConnected, NetworkMgr)
            if a then return b end
        end
    end
    return false
end

local function onDeviceByBookId(refresh)
    local ok, SM = pcall(require, "bookorbit_state_manager")
    if not (ok and type(SM) == "table") then return {} end
    if refresh and type(SM.invalidate) == "function" then pcall(SM.invalidate) end
    if type(SM.onDeviceMaps) == "function" then
        local okm, maps = pcall(SM.onDeviceMaps)
        if okm and type(maps) == "table" and type(maps.byBookId) == "table" then
            return maps.byBookId
        end
    end
    return {}
end

local function liveBookPath(book_id)
    if book_id == nil then return nil end
    local on_device = onDeviceByBookId(false)
    local fp = on_device[book_id] or on_device[tostring(book_id)] or on_device[tonumber(book_id)]
    if type(fp) == "string" and fp ~= "" and lfs.attributes(fp, "mode") == "file" then
        return fp
    end
    -- Side Panel local downloads waiting to be linked
    local mine = G_reader_settings and G_reader_settings:readSetting("simpleui_sidepanel_bo_local")
    local own = type(mine) == "table" and mine[tostring(book_id)] or nil
    if type(own) == "string" and lfs.attributes(own, "mode") == "file" then return own end
    return nil
end

-- Bookshelf wants `authors` as a list of names and `author` as the first one.
local function authorList(book)
    local out = {}
    if type(book.authors) == "table" then
        for _j, a in ipairs(book.authors) do
            if type(a) == "string" and a ~= "" then out[#out + 1] = a
            elseif type(a) == "table" and type(a.name) == "string" and a.name ~= "" then out[#out + 1] = a.name end
        end
    elseif type(book.authors) == "string" and book.authors ~= "" then
        out[1] = book.authors
    end
    if #out == 0 and type(book.author) == "string" and book.author ~= "" then out[1] = book.author end
    return out
end

-- "2026-10-31T14:03:22.000Z" -> unix time (UTC), nil when it does not parse
local function isoToUnix(str)
    if type(str) ~= "string" then return nil end
    local y, mo, d, h, mi, se = str:match("^(%d+)-(%d+)-(%d+)[T ](%d+):(%d+):(%d+)")
    if not y then return nil end
    y, mo, d, h, mi, se = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(se)
    local yy = mo <= 2 and y - 1 or y
    local era = math.floor(yy / 400)
    local yoe = yy - era * 400
    local doy = math.floor((153 * (mo + (mo > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + se
end

local function coverVersion(book)
    local t = tostring(book.updatedAt or book.coverUpdatedAt or ""):gsub("%D", "")
    if #t > 32 then t = t:sub(1, 16) .. t:sub(-16) end
    return t ~= "" and t or "0"
end

-- Covers live in the same folder BookOrbit and Side Panel use:
--   <datadir>/cache/bookorbit/<id>_<cv>.jpg
-- Prefer an already-cached cover; missing ones are fetched in the background
-- (Wi-Fi only, up to 8 at a time) via downloadCatalogThumbnail, so BookOrbit
-- sees them too. Clean Up Cache matches Reading Log Tweaks: newest of each
-- book kept, at most 600, half-finished .part files dropped.
local BoCovers = {}
do
    local index, index_at
    local wanted, tried, busy = {}, {}, false

    local function dir()
        return require("datastorage"):getDataDir() .. "/cache/bookorbit"
    end

    local function buildIndex()
        index = {}
        local d = dir()
        if lfs.attributes(d, "mode") ~= "directory" then return end
        for f in lfs.dir(d) do
            -- same pattern Side Panel / Reading Log use
            local id, tok = f:match("^(%d+)_(%d+)%.jpg$")
            if id and (not index[id] or tok > index[id].tok) then
                index[id] = { tok = tok, path = d .. "/" .. f }
            end
        end
    end

    function BoCovers.forget()
        index, tried, wanted = nil, {}, {}
    end

    function BoCovers.path(book_id, cv)
        if book_id == nil then return nil end
        if not index or os.time() - (index_at or 0) > 600 then
            buildIndex()
            index_at = os.time()
        end
        local id = tostring(book_id)
        local hit = index[id]
        if hit and lfs.attributes(hit.path, "mode") ~= "file" then
            index[id] = nil
            tried[tonumber(book_id)] = nil
            hit = nil
        end
        if hit then return hit.path end
        -- exact version path (even if index is stale)
        if cv then
            local exact = string.format("%s/%s_%s.jpg", dir(), id, tostring(cv))
            if lfs.attributes(exact, "mode") == "file" then return exact end
        end
        return nil
    end

    function BoCovers.want(book_id, cv)
        local id = tonumber(book_id)
        if id and not tried[id] and not BoCovers.path(id, cv) then
            wanted[id] = tostring(cv or "0")
        end
    end

    function BoCovers.fetch(on_done)
        if busy or next(wanted) == nil or not isWifiOn() then return end
        local client = boApiClient()
        if not client then wanted = {} return end
        local jobs, d = {}, dir()
        for id, cv in pairs(wanted) do
            if #jobs < 8 then
                tried[id] = true
                jobs[#jobs + 1] = { id = id, path = string.format("%s/%d_%s.jpg", d, id, cv) }
            end
        end
        for _i, j in ipairs(jobs) do wanted[j.id] = nil end
        if #jobs == 0 then return end
        busy = true
        require("util").makePath(d)
        require("ui/trapper"):wrap(function()
            local got = 0
            local ok_run, completed, result = pcall(client.runInSubprocess, client, function()
                local n = 0
                for _i, j in ipairs(jobs) do
                    local ok = client:downloadCatalogThumbnail(j.id, j.path, {
                        temp_path = j.path .. ".part",
                        max_bytes = 4 * 1024 * 1024,
                        background = false,
                    })
                    if ok then n = n + 1 end
                end
                return n
            end)
            busy = false
            if ok_run and completed and type(result) == "table" then
                got = tonumber(result.body) or 0
            elseif ok_run and type(result) == "number" then
                got = result
            end
            if next(wanted) ~= nil then
                UIManager:nextTick(function() BoCovers.fetch(on_done) end)
            end
            if got > 0 then
                index = nil
                local bs = getBookshelf()
                if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
                if on_done then pcall(on_done, got) end
            end
        end)
    end

    -- Reading Log style: newest cover per book, max 600, drop old + .part leftovers
    function BoCovers.cleanUp()
        local res = { files = 0, bytes = 0, entries = 0 }
        local function gone(path)
            local size = lfs.attributes(path, "size") or 0
            if os.remove(path) then
                res.files = res.files + 1
                res.bytes = res.bytes + size
            end
        end
        local d = dir()
        local newest, all = {}, {}
        if lfs.attributes(d, "mode") == "directory" then
            for name in lfs.dir(d) do
                -- half-finished downloads, ten minutes old or more
                if name:match("%.part$") then
                    local path = d .. "/" .. name
                    local at = lfs.attributes(path, "modification") or 0
                    if os.time() - at >= 600 then gone(path) end
                else
                    local id = name:match("^a?(%d+)_[%w]+%.jpg$")
                    if id then
                        local path = d .. "/" .. name
                        local at = lfs.attributes(path, "modification") or 0
                        local who = (name:sub(1, 1) == "a" and "a" or "") .. id
                        local e = { path = path, at = at }
                        all[#all + 1] = e
                        local cur = newest[who]
                        if not cur or at > cur.at then
                            if cur then cur.old = true end
                            newest[who] = e
                        else
                            e.old = true
                        end
                    end
                end
            end
            for _, e in ipairs(all) do
                if e.old then gone(e.path) end
            end
            local keep = {}
            for _, e in pairs(newest) do
                if not e.old then keep[#keep + 1] = e end
            end
            table.sort(keep, function(a, b) return a.at > b.at end)
            -- Offline Library keeps a cover for every book, so no cap then
            if not cfg.offline_library then
                for i = 601, #keep do gone(keep[i].path) end
            end
        end
        -- Side Panel local downloads whose file is gone
        local mine = G_reader_settings and G_reader_settings:readSetting("simpleui_sidepanel_bo_local")
        if type(mine) == "table" then
            local changed = false
            for k, path in pairs(mine) do
                if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
                    mine[k] = nil
                    changed = true
                    res.entries = res.entries + 1
                end
            end
            if changed then G_reader_settings:saveSetting("simpleui_sidepanel_bo_local", mine) end
        end
        BoCovers.forget()
        -- Side Panel / Reading Log forget hooks when present
        pcall(function()
            local SP = package.loaded.simpleui_sidepanel
            if type(SP) == "table" and type(SP.boCoverForget) == "function" then SP.boCoverForget() end
        end)
        pcall(function()
            local side = package.loaded["simpleui_sidepanel_bo"]
            -- nothing required
        end)
        return res
    end
end

local function coverPathFor(book_id, cv)
    return BoCovers.path(book_id, cv)
end

-- ---- Offline Library: saved details for every BookOrbit book ----------------------
-- One line per book in <datadir>/orbitshelf-library.txt (book id, cover version, page
-- count, published, language, publisher, genres, description). New lines are added at
-- the end (cheap: nothing is rewritten while it builds); the last line for a book wins,
-- and the file is tidied at the end of a build. Covers go in the shared BookOrbit
-- cover folder. Book files are never downloaded by this.
local Offline = { store = nil, lines = 0 }

local function offlineFile()
    return require("datastorage"):getDataDir() .. "/orbitshelf-library.txt"
end

local function esc(v)
    return (tostring(v or ""):gsub("\\", "\\\\"):gsub("\t", "\\t"):gsub("\r?\n", "\\n"):gsub("\31", " "))
end

local UNESC = { t = "\t", n = "\n", ["\\"] = "\\" }
local function unesc(v)
    return (v:gsub("\\(.)", function(c) return UNESC[c] or c end))
end

function Offline.line(e)
    local g = {}
    for _i, t in ipairs(type(e.g) == "table" and e.g or {}) do g[#g + 1] = esc(t) end
    return table.concat({ esc(e.id), esc(e.cv), esc(e.p), esc(e.pub), esc(e.lang), esc(e.publisher),
        table.concat(g, "\31"), esc(e.d), e.nc and "1" or "" }, "\t")
end

function Offline.parse(line)
    local f = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = part end
    if #f < 8 or f[1] == "" then return nil end
    local g = {}
    for t in f[7]:gmatch("[^\31]+") do g[#g + 1] = unesc(t) end
    local function opt(v) v = unesc(v) return v ~= "" and v or nil end
    return { id = unesc(f[1]), cv = unesc(f[2]), p = tonumber(f[3]), pub = opt(f[4]), lang = opt(f[5]),
        publisher = opt(f[6]), g = g, d = opt(f[8]), nc = f[9] == "1" or nil }
end

function Offline.load()
    if Offline.store then return Offline.store end
    local store, n = {}, 0
    local f = io.open(offlineFile(), "r")
    if f then
        for line in f:lines() do
            local e = Offline.parse(line)
            if e then store[e.id] = e; n = n + 1 end
        end
        f:close()
    end
    Offline.store, Offline.lines = store, n
    return store
end

-- save a batch: add its lines at the end of the file
function Offline.put(list)
    local store = Offline.load()
    local out = {}
    for _i, e in ipairs(list or {}) do
        e.id = tostring(e.id)
        store[e.id] = e
        out[#out + 1] = Offline.line(e)
    end
    if #out == 0 then return end
    local f = io.open(offlineFile(), "a")
    if f then
        f:write(table.concat(out, "\n"), "\n")
        f:close()
        Offline.lines = Offline.lines + #out
    end
end

-- rewrite the file with one line per book once old lines pile up
function Offline.tidy()
    local store = Offline.load()
    local count = 0
    for _k in pairs(store) do count = count + 1 end
    if Offline.lines <= count + 50 then return end
    local tmp = offlineFile() .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    for _k, e in pairs(store) do f:write(Offline.line(e), "\n") end
    f:close()
    if os.rename(tmp, offlineFile()) then Offline.lines = count else os.remove(tmp) end
end

function Offline.count()
    local n = 0
    for _k in pairs(Offline.load()) do n = n + 1 end
    return n
end

function Offline.delete()
    os.remove(offlineFile())
    Offline.store, Offline.lines = {}, 0
end

function Offline.entry(id)
    if not cfg.offline_library or id == nil then return nil end
    return Offline.load()[tostring(id)]
end

-- A list record gets the saved details (BookOrbit's lists don't carry them). The
-- fields it adds are noted on the record (bookorbit_filled), so they come off again
-- once Offline Library is off or deleted: the saved lists keep these records.
local FILL_FIELDS = { "description", "pages", "page_count", "published", "lang", "publisher", "genres" }
-- 1.6.0 filled records without noting it; BookOrbit's lists carry none of these
-- fields, so such a record had them all from the saved details
local function filledOf(rec)
    if type(rec.bookorbit_filled) == "table" then return rec.bookorbit_filled end
    if rec.bookorbit_saved then
        local all = {}
        for _i, k in ipairs(FILL_FIELDS) do all[k] = true end
        return all
    end
    return nil
end

function Offline.unfill(rec)
    local f = type(rec) == "table" and filledOf(rec)
    if type(f) == "table" then
        for _i, k in ipairs(FILL_FIELDS) do
            if f[k] then rec[k] = nil end
        end
    end
    if type(rec) == "table" then rec.bookorbit_filled, rec.bookorbit_saved = nil, nil end
    return rec
end

function Offline.fill(rec)
    if type(rec) ~= "table" then return rec end
    local e = Offline.entry(rec.bookorbit_id)
    if not e then return Offline.unfill(rec) end
    local f = filledOf(rec) or {}
    local function set(k, v)
        if v == nil then return end
        if rec[k] == nil or rec[k] == "" or f[k] then rec[k] = v; f[k] = true end
    end
    set("description", e.d)
    if e.p and e.p > 0 then set("pages", e.p); set("page_count", e.p) end
    set("published", e.pub)
    set("lang", e.lang)
    set("publisher", e.publisher)
    if #e.g > 0 and (rec.genres == nil or #rec.genres == 0 or f.genres) then rec.genres = e.g; f.genres = true end
    rec.bookorbit_filled = next(f) and f or nil
    rec.bookorbit_saved = true
    return rec
end

-- size on the device: the details file plus the covers (counted at most once a minute)
local offline_size, offline_size_at
function Offline.size()
    if offline_size and os.time() - (offline_size_at or 0) < 60 then return offline_size end
    local bytes = lfs.attributes(offlineFile(), "size") or 0
    local d = require("datastorage"):getDataDir() .. "/cache/bookorbit"
    if lfs.attributes(d, "mode") == "directory" then
        for name in lfs.dir(d) do
            if name:match("^%d+_%d+%.jpg$") then bytes = bytes + (lfs.attributes(d .. "/" .. name, "size") or 0) end
        end
    end
    offline_size, offline_size_at = bytes, os.time()
    return bytes
end
function Offline.sizeChanged() offline_size = nil end

-- In-memory + settings-backed page cache: key -> { t=, items=, total= }
local page_cache = {}
local CACHE_KEY = "orbitshelf_tweaks_pages_2"
local OLD_CACHE_KEY = "orbitshelf_tweaks_pages" -- 1.5.1 and older: authors saved as one string

local function loadPageCache()
    if G_reader_settings and G_reader_settings:readSetting(OLD_CACHE_KEY) ~= nil then
        G_reader_settings:delSetting(OLD_CACHE_KEY)
    end
    local saved = G_reader_settings and G_reader_settings:readSetting(CACHE_KEY)
    if type(saved) == "table" then
        for k, v in pairs(saved) do page_cache[k] = v end
        -- an empty list saved from a failed fetch must not hide the shelf
        for k, v in pairs(page_cache) do
            if type(v) ~= "table" or type(v.items) ~= "table" or #v.items == 0 then
                page_cache[k] = nil
            end
        end
    end
end
loadPageCache()

local function savePageCache()
    if not G_reader_settings then return end
    -- Keep the cache small: drop entries older than offline_ttl
    local now = os.time()
    local slim = {}
    for k, v in pairs(page_cache) do
        -- Offline Library: lists are kept until they're pulled fresh, however old
        if type(v) == "table" and type(v.t) == "number"
                and (cfg.offline_library or (now - v.t) < (cfg.offline_ttl or 21600)) then
            slim[k] = v
        end
    end
    for k in pairs(page_cache) do if slim[k] == nil then page_cache[k] = nil end end
    G_reader_settings:saveSetting(CACHE_KEY, page_cache)
end

-- forget every saved list (the table itself stays: other files hold it)
local function clearPageCache()
    for k in pairs(page_cache) do page_cache[k] = nil end
end

local function recordFromBo(book)
    local id = book.id
    local fp = liveBookPath(id)
    local cv = coverVersion(book)
    local cover = coverPathFor(id, cv)
    if not cover then
        -- queue background fetch into the shared BookOrbit cache folder
        BoCovers.want(id, cv)
    end
    local series = book.seriesName or book.series or ""
    local series_index = tonumber(book.seriesIndex) or tonumber(book.series_index)
    local genres
    if type(book.genres) == "table" then
        genres = {}
        for _i, g in ipairs(book.genres) do
            if type(g) == "string" then genres[#genres + 1] = g
            elseif type(g) == "table" and g.name then genres[#genres + 1] = g.name end
        end
    elseif type(book.genre) == "string" and book.genre ~= "" then
        genres = { book.genre }
    elseif type(book.tags) == "table" then
        genres = {}
        for _i, t in ipairs(book.tags) do
            if type(t) == "string" then genres[#genres + 1] = t
            elseif type(t) == "table" and t.name then genres[#genres + 1] = t.name end
        end
    end
    local remote = "bookorbit://" .. tostring(id)
    local authors = authorList(book)
    return Offline.fill({
        filepath = fp or remote,
        title = book.title or book.name or _("Untitled"),
        authors = authors,
        author = authors[1] or "",
        series = series,
        series_name = series,
        series_index = series_index,
        series_num = series_index and tostring(series_index) or nil,
        genres = genres,
        description = book.description or book.summary,
        cover_image_path = cover,
        pages = tonumber(book.pageCount) or tonumber(book.pages),
        last_opened = isoToUnix(book.lastReadAt),
        last_read_time = isoToUnix(book.lastReadAt),
        added_time = isoToUnix(book.addedAt),
        downloaded = fp and true or nil,
        bookorbit_id = id,
        bookorbit_cv = cv,
        is_bookorbit = true,
        -- Bookshelf stamps source_kind itself; we also mark for owns()
        source_kind = SOURCE_ID,
    })
end

local function refreshCoverPaths(items)
    if type(items) ~= "table" then return items end
    for _i, rec in ipairs(items) do
        if type(rec) == "table" and rec.bookorbit_id then
            -- on the device or not, as of now (a download or a removal since the list was saved)
            local live = liveBookPath(rec.bookorbit_id)
            if live then
                rec.filepath, rec.downloaded = live, true
            else
                rec.filepath, rec.downloaded = "bookorbit://" .. tostring(rec.bookorbit_id), nil
            end
            local path = coverPathFor(rec.bookorbit_id, rec.bookorbit_cv)
            if path then
                rec.cover_image_path = path
            else
                BoCovers.want(rec.bookorbit_id, rec.bookorbit_cv)
            end
            Offline.fill(rec)
        end
    end
    return items
end

local function fetchBoPage(api_params, force)
    local client, err = boApiClient()
    if not client then return {}, nil, err end

    local key_parts = {}
    for k, v in pairs(api_params or {}) do
        key_parts[#key_parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    table.sort(key_parts)
    local key = table.concat(key_parts, "&")
    local now = os.time()
    local entry = page_cache[key]
    local wifi = isWifiOn()

    if not force and type(entry) == "table" and type(entry.items) == "table" then
        local age = now - (entry.t or 0)
        if (not wifi and age < (cfg.offline_ttl or 21600))
                or (wifi and age < (cfg.cache_ttl or 1800)) then
            local items = refreshCoverPaths(entry.items)
            BoCovers.fetch()
            return items, entry.total
        end
    end

    if not wifi and type(entry) == "table" and type(entry.items) == "table" then
        return refreshCoverPaths(entry.items), entry.total
    end

    local books, seen, page, page_size = {}, {}, 1, 100
    local total
    local failed = false
    for _guard = 1, 20 do
        local q = {}
        for k, v in pairs(api_params or {}) do q[k] = v end
        q.page, q.size = page, page_size
        local ok_body, body = pcall(function() return client:catalogBooks(q) end)
        if not ok_body or type(body) ~= "table" then
            failed = true
            logger.warn(TAG, "catalog fetch failed on page", page, "-", ok_body and "no usable reply" or tostring(body),
                "(wifi " .. (wifi and "on" or "off") .. ")")
            break
        end
        local items = body.items or body.books or body.entries or {}
        if type(items) ~= "table" or #items == 0 then break end
        for _i, book in ipairs(items) do
            if type(book) == "table" and book.id and not seen[book.id] then
                seen[book.id] = true
                books[#books + 1] = recordFromBo(book)
            end
        end
        total = tonumber(body.total) or tonumber(body.totalCount) or total
        if total and page * page_size >= total then break end
        if #items < page_size then break end
        page = page + 1
    end

    if failed then
        -- never cache a failed fetch: keep the last good list, or show what came in
        if #books == 0 and type(entry) == "table" and type(entry.items) == "table" and #entry.items > 0 then
            return refreshCoverPaths(entry.items), entry.total, "catalog fetch failed"
        end
        return books, total or #books, "catalog fetch failed"
    end
    if #books == 0 then
        logger.info(TAG, "catalog returned no books for", key ~= "" and key or "(all)")
    end
    page_cache[key] = { t = now, items = books, total = total or #books }
    savePageCache()
    -- pull missing covers into the shared cache (Side Panel / BookOrbit folder)
    BoCovers.fetch()
    return books, total or #books
end

-- ---- Download / remove (Side Panel style) -----------------------------------------

local function rememberLocalDownload(book_id, path)
    if not G_reader_settings or not book_id or not path then return end
    local mine = G_reader_settings:readSetting("simpleui_sidepanel_bo_local")
    if type(mine) ~= "table" then mine = {} end
    mine[tostring(book_id)] = path
    G_reader_settings:saveSetting("simpleui_sidepanel_bo_local", mine)
end

local function forgetLocalDownload(book_id)
    if not G_reader_settings or not book_id then return end
    local mine = G_reader_settings:readSetting("simpleui_sidepanel_bo_local")
    if type(mine) ~= "table" then return end
    mine[tostring(book_id)] = nil
    G_reader_settings:saveSetting("simpleui_sidepanel_bo_local", mine)
end

-- The hero shows a book picked on the shelf as Bookshelf's preview record. After a
-- download (or a removal) that record still points at the old place, so the hero kept
-- its old look until another book was picked and this one again. It is pointed at the
-- book's new place here, before the shelf redraws.
local function retargetHeroPreview(id, local_path)
    pcall(function()
        local bs = getBookshelf()
        local w = bs and bs._widget
        local pb = w and w._preview_book
        -- a record rebuilt from the file gets its id back when the hero draws it
        -- (asBookOrbit), so the id is enough
        if type(pb) ~= "table" or tonumber(pb.bookorbit_id) ~= tonumber(id) then return end
        if local_path then
            -- read from the file now, the way Bookshelf does for a book on the device
            local fresh = type(w._hydrateBook) == "function" and w:_hydrateBook({ filepath = local_path }) or nil
            if type(fresh) == "table" then
                fresh.bookorbit_id = tonumber(id) or id
                fresh.is_bookorbit = true
                w._preview_book = fresh
            else
                pb.filepath = local_path
                pb.downloaded = true
            end
        else
            -- back to the BookOrbit record (Download / Open In BookOrbit)
            local rec
            for _k, entry in pairs(page_cache) do
                for _i, r in ipairs(type(entry) == "table" and entry.items or {}) do
                    if type(r) == "table" and tonumber(r.bookorbit_id) == tonumber(id) then rec = r break end
                end
                if rec then break end
            end
            local remote = "bookorbit://" .. tostring(id)
            local copy = {}
            for k, v in pairs(rec or pb) do copy[k] = v end
            copy.filepath, copy.downloaded = remote, nil
            copy.bookorbit_id, copy.is_bookorbit, copy.source_kind = tonumber(id) or id, true, SOURCE_ID
            w._preview_book = copy
        end
        w._hero_book_cache = nil
    end)
end

local function downloadBookOrbitBook(book, on_done)
    local id = tonumber(book and (book.bookorbit_id or book.id))
    if not id then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("No BookOrbit id") })
        return
    end
    local client = boApiClient()
    if not client then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("BookOrbit is not signed in") })
        return
    end
    local function fail(msg)
        UIManager:show(require("ui/widget/infomessage"):new{ text = msg })
    end

    -- the file a download takes: the main supported one
    local function pickFile(detail)
        local okU, CU = pcall(require, "bookorbit_catalog_util")
        local function usable(f) return type(f) == "table" and f.id and (not okU or CU.isSupportedFormat(f.format)) end
        for _i, f in ipairs(type(detail) == "table" and detail.files or {}) do
            if usable(f) and f.role == "primary" then return f end
        end
        for _i, f in ipairs(type(detail) == "table" and detail.files or {}) do
            if usable(f) then return f end
        end
        return nil
    end

    -- Same way the Side Panel and BookOrbit's own book page download: BookOrbit's
    -- download folder and layout, checked against the server's hash, then linked.
    local function run()
        local Trapper = require("ui/trapper")
        Trapper:wrap(function()
            local okT, Toast = pcall(require, "bookorbit_toast")
            local pill = okT and Toast.loading and Toast.loading(T(_("Downloading %1…"), tostring(book.title or _("book")))) or nil
            local function done() if pill and pill.close then pcall(pill.close, pill) end end

            local ok_run, completed, result = pcall(client.runInSubprocess, client, function() return client:catalogBook(id) end)
            local detail = ok_run and completed and type(result) == "table" and result.body or nil
            if type(detail) ~= "table" then
                local ok_d, d = pcall(function() return client:catalogBook(id) end)
                detail = ok_d and type(d) == "table" and d or nil
            end
            if type(detail) ~= "table" then
                done()
                return fail(_("Could not load book details"))
            end
            local file = pickFile(detail)
            if not file then done() return fail(_("No file this reader can open")) end

            local okR, Root = pcall(require, "bookorbit_download_root")
            local root = okR and type(Root) == "table" and Root.get and Root.get()
                or (G_reader_settings and G_reader_settings:readSetting("home_dir"))
            if type(root) ~= "string" or root == "" then
                done()
                return fail(_("Set a download folder in BookOrbit first."))
            end
            local util = require("util")
            -- the server's folder layout under the download folder
            local rel
            local dp = tostring(file.devicePath or ""):gsub("\\", "/"):gsub("^/+", "")
            if dp ~= "" then
                local segs, bad = {}, false
                for seg in dp:gmatch("[^/]+") do
                    if seg == ".." then bad = true break end
                    if seg ~= "." then segs[#segs + 1] = util.getSafeFilename(seg, root) end
                end
                if not bad and #segs > 0 then rel = table.concat(segs, "/") end
            end
            if not rel then
                local okC, CU = pcall(require, "bookorbit_catalog_util")
                local base = okC and CU.safeFilenameBase(detail) or tostring(detail.title or ("book-" .. id))
                rel = util.getSafeFilename(base .. "." .. tostring(file.format or "epub"):lower(), root)
            end
            local dest = (root ~= "/" and root or "") .. "/" .. rel
            local parent = dest:match("^(.*)/[^/]+$")
            if parent then util.makePath(parent) end

            if lfs.attributes(dest, "mode") ~= "file" then
                local okX, Transfer = pcall(require, "bookorbit_download_transfer")
                if not okX then done() return fail(_("This BookOrbit version can't download from here.")) end
                pcall(Transfer.sweepStale, root)
                local ok_t, ok, err = pcall(Transfer.run, {
                    root = root, destination = dest, generation = os.time(),
                    expected_bytes = file.sizeBytes, expected_hash = file.fileHash, hash = "partial_md5",
                    perform = function(o)
                        o.variant = file.selection and (file.requestedVariant or file.downloadVariant) or nil
                        o.selection = file.selection
                        return client:downloadCatalogFile(file.id, dest, o)
                    end,
                })
                if not (ok_t and ok) then
                    done()
                    logger.warn(TAG, "download failed:", ok_t and err or ok)
                    if err ~= "cancelled" then
                        fail(T(_("Couldn't download it:\n%1"), tostring(ok_t and err or ok)))
                    end
                    return
                end
            end

            -- on the device straight away, before BookOrbit links it
            rememberLocalDownload(id, dest)

            done()
            if on_done then pcall(on_done, dest) end
            -- the shelf shows it as on the device now, whoever started the download;
            -- before the link below, which is a network call
            retargetHeroPreview(id, dest)
            local bs = getBookshelf()
            if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end

            -- linked to its BookOrbit book, so it syncs: a moment later, after the shelf
            -- has redrawn
            UIManager:scheduleIn(0.5, function()
                pcall(function()
                    local digest = util.partialMD5(dest)
                    if not digest then return end
                    local body = client:matchCheck({ digest }, { [digest] = { source = "file", book_file_id = file.id } })
                    local SM = require("bookorbit_state_manager")
                    if type(body) ~= "table" then return end
                    if SM.applyLibraryVersion then SM.applyLibraryVersion(body.libraryVersion) end
                    for _i, m in ipairs(body.matches or {}) do
                        if m.hash == digest then
                            SM.linkFile(digest, m.bookFileId, m.bookId, dest)
                            return
                        end
                    end
                end)
            end)

            -- it is not opened by itself: the reader chooses
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = T(_("Downloaded %1.\n\nOpen it now?"), tostring(detail.title or book.title or "")),
                ok_text = _("Open"),
                cancel_text = _("Later"),
                ok_callback = function()
                    require("apps/reader/readerui"):showReader(dest)
                end,
            })
        end)
    end

    local okN, NetworkMgr = pcall(require, "ui/network/manager")
    if okN and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(run)
    else
        run()
    end
end

local function removeFromDevice(book)
    local path = book and book.filepath
    if type(path) ~= "string" or path:match("^bookorbit://") then
        path = liveBookPath(book and book.bookorbit_id)
    end
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("Not on this device") })
        return
    end
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("Remove %1 from this device?\n\nIt stays in BookOrbit."), tostring(book.title or path)),
        ok_text = _("Remove"),
        ok_callback = function()
            pcall(os.remove, path)
            -- sidecar
            local sdr = path:match("^(.*)%.[^.]+$")
            if sdr then
                local dir = sdr .. ".sdr"
                if lfs.attributes(dir, "mode") == "directory" then
                    pcall(function()
                        for f in lfs.dir(dir) do
                            if f ~= "." and f ~= ".." then pcall(os.remove, dir .. "/" .. f) end
                        end
                        lfs.rmdir(dir)
                    end)
                end
            end
            -- history / collections best-effort
            pcall(function()
                local ReadHistory = require("readhistory")
                if ReadHistory and ReadHistory.removeItemByPath then
                    ReadHistory:removeItemByPath(path)
                end
            end)
            pcall(function()
                local RC = require("readcollection")
                if type(RC) == "table" and type(RC.coll) == "table" then
                    for name, _ in pairs(RC.coll) do
                        if RC.removeItem then pcall(RC.removeItem, RC, path, name) end
                    end
                end
            end)
            forgetLocalDownload(book.bookorbit_id)
            if book.bookorbit_id then retargetHeroPreview(book.bookorbit_id, nil) end
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("Removed from device"),
                timeout = 2,
            })
            local bs = getBookshelf()
            if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
        end,
    })
end

-- BookOrbit book id for a file on the device, or nil when it is not one of theirs
local function bookIdForPath(file)
    if type(file) ~= "string" or file == "" then return nil end
    for id, fp in pairs(onDeviceByBookId(false)) do
        if fp == file then return tonumber(id) or id end
    end
    local mine = G_reader_settings and G_reader_settings:readSetting("simpleui_sidepanel_bo_local")
    if type(mine) == "table" then
        for id, fp in pairs(mine) do
            if fp == file then return tonumber(id) or id end
        end
    end
    return nil
end

-- Remove From Device in the long-press menu of a BookOrbit book that is on the device.
-- Bookshelf shows buttons registered here in its own book menu; the file browser's
-- long-press menu shows them too.
local FILE_DIALOG_ID = "orbitshelf_remove_from_device"
local function registerFileDialogButton()
    local okFM, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not (okFM and type(FileManager) == "table" and type(FileManager.addFileDialogButtons) == "function") then
        return false
    end
    FileManager.addFileDialogButtons(FileManager, FILE_DIALOG_ID, function(file, is_file, book_props)
        if not is_file then return nil end
        local id = bookIdForPath(file)
        if not id then return nil end
        return {{
            text = _("Remove From Device"),
            callback = function()
                -- close the book menu this was tapped in (the top window that has a
                -- rebuildTab), like Bookshelf's own Delete does
                pcall(function()
                    local stack = UIManager._window_stack or {}
                    for i = #stack, 1, -1 do
                        local w = stack[i].widget
                        if type(w) == "table" and type(w.rebuildTab) == "function" then
                            UIManager:close(w)
                            break
                        end
                    end
                end)
                local title = type(book_props) == "table" and book_props.title or nil
                removeFromDevice({
                    bookorbit_id = id,
                    filepath = file,
                    title = title or (file:match("([^/]+)%.[^./]+$") or file:match("([^/]+)$") or file),
                })
            end,
        }}
    end)
    return true
end

local function openInBookOrbit(book)
    local id = book and book.bookorbit_id
    if not id then return false end
    local plugin
    pcall(function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = type(FM) == "table" and FM.instance
        if type(fm) == "table" then
            plugin = fm.bookorbit or fm._bookorbit_plugin
        end
    end)
    if not plugin then
        -- discover via package
        local ok, main = pcall(require, "bookorbit")
        if ok and type(main) == "table" then plugin = main end
    end
    -- Try common open paths (same as Side Panel)
    local function tryOpenDetail(p)
        if type(p) ~= "table" then return false end
        if not p.catalog_browser then
            if type(p.openBookOrbit) == "function" then pcall(p.openBookOrbit, p) end
            if not p.catalog_browser and type(p.browseCatalog) == "function" then
                pcall(p.browseCatalog, p, false)
            end
            if not p.catalog_browser and type(p.openCatalogBrowser) == "function" then
                pcall(p.openCatalogBrowser, p)
            end
        end
        local catalog = p.catalog_browser
        if type(catalog) == "table" and type(catalog.loadBookDetail) == "function" then
            return pcall(catalog.loadBookDetail, catalog, id)
        end
        return false
    end
    if tryOpenDetail(plugin) then return true end
    -- Dispatcher / global
    local okD, Dispatcher = pcall(require, "dispatcher")
    if okD and Dispatcher and Dispatcher.execute then
        pcall(Dispatcher.execute, { "BookOrbit" })
    end
    return false
end

-- ---- Book Description popup ---------------------------------------------------------
-- A compact window sized to the description (bigger or smaller as needed, scrolls only
-- when it's longer than about 70% of the screen). Closes on the X or a tap outside it.
local desc_memo = {} -- book id -> description, for this session (not saved)

local function plainText(s)
    s = tostring(s or "")
    s = s:gsub("\r", ""):gsub("<[Bb][Rr]%s*/?>", "\n"):gsub("</[Pp]>", "\n\n"):gsub("<[^>]+>", "")
    s = s:gsub("&nbsp;", " "):gsub("&quot;", '"'):gsub("&#0*39;", "'"):gsub("&apos;", "'")
        :gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&#(%d+);", function(n)
            n = tonumber(n)
            return n and n < 128 and string.char(n) or ""
        end):gsub("&amp;", "&")
    s = s:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n"):gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

local function popupDescription(book, text)
    local Device = require("device")
    local Screen = Device.screen
    local Blitbuffer = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local ScrollTextWidget = require("ui/widget/scrolltextwidget")
    local Button = require("ui/widget/button")
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = Screen:scaleBySize(12)
    local face = Font:getFace("cfont", 18)
    -- width: as wide as the text needs, up to 86% of the screen
    local max_w = math.floor(sw * 0.86)
    local probe = TextWidget:new{ text = text:gsub("\n", " "), face = face }
    local natural = probe:getSize().w
    probe:free()
    local inner_w = math.max(math.floor(sw * 0.5), math.min(max_w - 2 * pad, natural))
    local close
    local xbtn = Button:new{
        text = "\u{2715}",
        bordersize = 0,
        padding = Screen:scaleBySize(4),
        callback = function() if close then close() end end,
    }
    local title = TextWidget:new{
        text = tostring(book.display_title or book.title or _("Book")),
        face = Font:getFace("cfont", 18),
        bold = true,
        max_width = inner_w - xbtn:getSize().w - Screen:scaleBySize(8),
    }
    local head = HorizontalGroup:new{ align = "center", title,
        require("ui/widget/horizontalspan"):new{ width = inner_w - title:getSize().w - xbtn:getSize().w }, xbtn }
    local body = TextBoxWidget:new{ text = text, face = face, width = inner_w }
    local text_h = body:getSize().h
    local max_h = math.floor(sh * 0.7) - head:getSize().h - 3 * pad
    if text_h > max_h then
        body:free()
        body = ScrollTextWidget:new{ text = text, face = face, width = inner_w, height = max_h }
    end
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Screen:scaleBySize(2),
        radius = Screen:scaleBySize(10),
        padding = pad,
        VerticalGroup:new{ align = "left", head, VerticalSpan:new{ width = Screen:scaleBySize(6) }, body },
    }
    local popup = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        CenterContainer:new{ dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }, frame },
    }
    -- ScrollTextWidget refreshes through its dialog when it scrolls (1.2.0-1.2.2 left
    -- this empty, so scrolling a long description crashed KOReader)
    body.dialog = popup
    if Device:isTouchDevice() then
        popup.ges_events = {
            TapClose = { GestureRange:new{ ges = "tap", range = popup.dimen } },
        }
    end
    popup.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    close = function()
        UIManager:close(popup)
        UIManager:setDirty(nil, function() return "ui", frame.dimen end)
    end
    function popup:onTapClose(_arg, ges)
        -- a tap inside the box does nothing (the X closes); outside closes
        if ges and ges.pos and frame.dimen and frame.dimen:contains(ges.pos) then return true end
        close()
        return true
    end
    function popup:onClose() close() return true end
    UIManager:show(popup)
    UIManager:setDirty(popup, function() return "ui", frame.dimen end)
end

-- Saved description first (Offline Library, or looked up earlier this session);
-- otherwise one lookup in the background (the screen keeps working).
local function showDescription(book)
    local id = book and (book.bookorbit_id or (book.filepath and bookIdForPath(book.filepath)))
    local have = book and type(book.description) == "string" and book.description ~= "" and book.description
        or (id and desc_memo[tostring(id)])
    if have then
        popupDescription(book, plainText(have))
        return
    end
    if not id then
        O.Genres.note(_("No description for this book."))
        return
    end
    if not isWifiOn() then
        O.Genres.note(_("No description saved. Turn on Wi-Fi, or Offline Library, to see it."))
        return
    end
    local client = boApiClient()
    if not client or type(O.runWorker) ~= "function" then return end
    O.runWorker(client, function()
        local d = client:catalogBook(id)
        return type(d) == "table" and { d = d.description } or nil
    end, function(res)
        local text = type(res) == "table" and type(res.d) == "string" and res.d or nil
        if not text or text == "" then
            O.Genres.note(_("This book has no description in BookOrbit."))
            return
        end
        desc_memo[tostring(id)] = text
        popupDescription(book, plainText(text))
    end, 30)
end

-- A tap or a long-press on a book that is not on the device: say so and offer
-- Download. Nothing downloads or opens until a button is pressed.
local function showNotOnDevice(book)
    local ButtonDialog = require("ui/widget/buttondialog")
    local lines = { tostring(book.display_title or book.title or "") }
    local who = book.author
    if type(who) ~= "string" or who == "" then who = type(book.authors) == "table" and book.authors[1] or "" end
    if type(who) == "string" and who ~= "" then lines[#lines + 1] = who end
    if type(book.series) == "string" and book.series ~= "" then
        local n = tonumber(book.series_index)
        lines[#lines + 1] = n and T(_("%1 #%2"), book.series, tostring(n)) or book.series
    end
    lines[#lines + 1] = _("Not On Device")
    local dialog
    dialog = ButtonDialog:new{
        title = table.concat(lines, "\n"),
        buttons = {
            {{ text = _("Download"), callback = function()
                UIManager:close(dialog)
                downloadBookOrbitBook(book)
            end }},
            {{ text = _("Open In BookOrbit"), callback = function()
                UIManager:close(dialog)
                openInBookOrbit(book)
            end }},
            {{ text = _("Book Description"), callback = function()
                UIManager:close(dialog)
                showDescription(book)
            end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
        },
    }
    UIManager:show(dialog)
end


-- shared with the other files
O.BoCovers = BoCovers
O.Offline = Offline
O.boApiClient = boApiClient
O.bookIdForPath = bookIdForPath
O.bookOrbitInstalled = bookOrbitInstalled
O.bookOrbitSignedIn = bookOrbitSignedIn
O.clearPageCache = clearPageCache
O.coverPathFor = coverPathFor
O.downloadBookOrbitBook = downloadBookOrbitBook
O.showDescription = showDescription
O.fetchBoPage = fetchBoPage
O.getBookshelf = getBookshelf
O.isWifiOn = isWifiOn
O.liveBookPath = liveBookPath
O.openInBookOrbit = openInBookOrbit
O.page_cache = page_cache
O.recordFromBo = recordFromBo
O.registerFileDialogButton = registerFileDialogButton
O.removeFromDevice = removeFromDevice
O.savePageCache = savePageCache
O.showNotOnDevice = showNotOnDevice
return O
