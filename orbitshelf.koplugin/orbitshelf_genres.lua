-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local BoCovers, Offline, SOURCE_ID, T, UIManager, _ = O.BoCovers, O.Offline, O.SOURCE_ID, O.T, O.UIManager, O._
local boApiClient, cfg, coverPathFor, fetchBoPage, getBookshelf, isWifiOn = O.boApiClient, O.cfg, O.coverPathFor, O.fetchBoPage, O.getBookshelf, O.isWifiOn
local lfs, liveBookPath, page_cache, recordFromBo, savePageCache = O.lfs, O.liveBookPath, O.page_cache, O.recordFromBo, O.savePageCache

-- ---- Genres: built once from each book's details --------------------------------
-- BookOrbit's book lists carry no genres (only a book's own detail page has its
-- genres and tags), so the Genres shelf needs them looked up once per book. It asks
-- first, then runs in the background in a separate process (the shelf stays usable),
-- 10 books at a time, saving after each batch. Wi-Fi off, sleep or a restart pauses
-- it; it carries on when Wi-Fi is back. A book on the device uses the genres in its
-- own file, no network. Afterwards only new or changed books are looked up.
local GENRES_KEY = "orbitshelf_genres"
local Genres = { store = nil, running = false, paused = false, asked = false, total = 0, done = 0, jobs = {}, gen = 0 }

-- the whole library as saved (no network: the menu and the checks must not wait)
function Genres.library()
    local e = page_cache["sort=title"]
    if type(e) == "table" and type(e.items) == "table" and #e.items > 0 then return e.items end
    return nil
end

function Genres.load()
    if Genres.store then return Genres.store end
    local saved = G_reader_settings and G_reader_settings:readSetting(GENRES_KEY)
    Genres.store = type(saved) == "table" and saved or {}
    return Genres.store
end

function Genres.save()
    if G_reader_settings and Genres.store then
        G_reader_settings:saveSetting(GENRES_KEY, Genres.store)
    end
end

-- genres then tags, no repeats (any case), not an author's own name
function Genres.fromDetail(detail)
    local seen, out, authors = {}, {}, {}
    for _i, a in ipairs(type(detail.authors) == "table" and detail.authors or {}) do
        local name = type(a) == "table" and a.name or a
        if type(name) == "string" then authors[name:lower()] = true end
    end
    for _i, list in ipairs({ detail.genres or {}, detail.tags or {} }) do
        for _j, v in ipairs(type(list) == "table" and list or {}) do
            local text = type(v) == "table" and v.name or v
            text = type(text) == "string" and text:match("^%s*(.-)%s*$") or nil
            local key = text and text:lower()
            if key and key ~= "" and not seen[key] and not authors[key] then
                seen[key] = true
                out[#out + 1] = text
            end
        end
    end
    return out
end

-- the file's own keywords, for a book on the device (no network)
function Genres.fromFile(path)
    local out = {}
    pcall(function()
        local ds = require("docsettings"):open(path)
        local props = ds and ds:readSetting("doc_props")
        local kw = type(props) == "table" and props.keywords or nil
        if type(kw) == "string" then
            for part in kw:gmatch("[^\n,;]+") do
                local t = part:match("^%s*(.-)%s*$")
                if t and t ~= "" then out[#out + 1] = t end
            end
        end
    end)
    return out
end

-- a book's genres, as saved (nil when not built yet)
function Genres.of(rec)
    local id = rec and rec.bookorbit_id
    if not id then return nil end
    local e = Genres.load()[tostring(id)]
    return type(e) == "table" and e.g or nil
end

-- books still to look up: not saved yet, or changed in BookOrbit since. With Offline
-- Library on, also any book whose details or cover aren't saved yet.
function Genres.missing(books, full)
    local store, out = Genres.load(), {}
    local saved = full and Offline.load() or nil
    for _i, rec in ipairs(books or {}) do
        local id = rec.bookorbit_id
        if id then
            local key, cv = tostring(id), rec.bookorbit_cv and tostring(rec.bookorbit_cv)
            local e = store[key]
            local need = type(e) ~= "table" or (cv and e.cv ~= cv)
            if not need and saved then
                local o = saved[key]
                need = not o or (cv and o.cv ~= cv) or (not o.nc and not coverPathFor(id, cv))
            end
            if need then out[#out + 1] = rec end
        end
    end
    return out
end

-- a note in the corner (Network Tweaks style), never over the sleep screen
function Genres.note(text)
    -- one line on a small screen: long ones are cut with an ellipsis
    text = tostring(text or "")
    if #text > 46 then
        local okU, util = pcall(require, "util")
        local cut = okU and util.splitToChars and util.splitToChars(text) or nil
        if cut and #cut > 44 then
            text = table.concat(cut, "", 1, 44) .. "…"
        elseif not cut then
            text = text:sub(1, 44) .. "…"
        end
    end
    pcall(function()
        if require("device").screen_saver_mode then return end
        local NM = package.loaded["ui/network/manager"]
        if type(NM) == "table" and type(NM.__network_tweaks_note) == "function" then
            local ok, handled = pcall(NM.__network_tweaks_note, text, text, 3)
            if ok and handled then return end
        end
        require("ui/widget/notification"):notify(text)
    end)
end

-- ---- background worker -----------------------------------------------------------
-- A forked process does the network calls and sends back a Lua table; it is checked
-- every half second, so the screen and taps keep working. Sleep stops it.
-- Numbers keep all their digits (%.17g; tostring kept 14). NaN and infinity have no
-- Lua literal, so they're left out: before 1.2.18 one of them made the whole result
-- unreadable and the batch was lost.
local function number(v)
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return string.format("%.17g", v)
end

local function serialize(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" then return number(v) or "nil" end
    if t == "boolean" then return tostring(v) end
    if t ~= "table" then return "nil" end
    local out = {}
    for k, x in pairs(v) do
        local kt
        if type(k) == "string" then kt = string.format("[%q]", k)
        elseif type(k) == "number" and number(k) then kt = "[" .. number(k) .. "]" end
        if kt then out[#out + 1] = kt .. "=" .. serialize(x) end
    end
    return "{" .. table.concat(out, ",") .. "}"
end

local function deserialize(data)
    if type(data) ~= "string" or data == "" then return nil end
    local fn = loadstring("return " .. data)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, v = pcall(fn)
    return ok and v or nil
end

-- run child_fn() in a worker; done(result) gets its table back (nil on failure, sleep
-- or after max_s seconds). Without fork support it runs inline on the next tick.
-- Our own worker only needs KOReader's fork helpers. (1.5.10-1.2.2 also required
-- BookOrbit's background_requests flag, which BookOrbit leaves off unless asked, so
-- every lookup ran on the screen's own thread: that was the frozen screen.)
local function canFork()
    local ok_util, util = pcall(require, "ffi/util")
    return ok_util and type(util.runInSubProcess) == "function" and type(util.isSubProcessDone) == "function"
        and type(util.getNonBlockingReadSize) == "function" and type(util.readAllFromFD) == "function"
        and type(util.writeToFD) == "function"
end

local function runWorker(client, child_fn, done, max_s)
    local util = require("ffi/util")
    if not canFork() then
        O.problem("nofork", "background worker not available on this device: lookups run one book at a time on the screen's thread")
        UIManager:scheduleIn(0.1, function()
            local okR, res = pcall(child_fn)
            done(okR and res or nil)
        end)
        return
    end
    local pid, fd = util.runInSubProcess(function(_pid, wfd)
        -- in the worker: run the calls inline, no second worker
        client.subprocess_depth = (client.subprocess_depth or 0) + 1
        local okR, res = pcall(child_fn)
        util.writeToFD(wfd, okR and serialize(res) or "", true)
    end, true)
    if not pid then done(nil) return end
    local job = { fd = fd }
    Genres.jobs[pid] = job
    local data, waited = "", 0
    local function poll()
        if Genres.jobs[pid] ~= job then return end -- stopped meanwhile
        local ok_dev, Device = pcall(require, "device")
        if ok_dev and Device.screen_saver_mode then
            Genres.stop(true)
            return
        end
        if fd and util.getNonBlockingReadSize(fd) ~= 0 then
            data = data .. (util.readAllFromFD(fd) or "")
            fd, job.fd = nil, nil
        end
        if util.isSubProcessDone(pid) then
            if fd then data = data .. (util.readAllFromFD(fd) or ""); fd = nil end
            Genres.jobs[pid] = nil
            done(deserialize(data))
            return
        end
        -- every 0.5 s for the first 2 s (most jobs are done by then), then every second
        local step_s = waited < 2 and 0.5 or 1
        waited = waited + step_s
        if waited > (max_s or 120) then
            Genres.stop(true)
            return
        end
        UIManager:scheduleIn(step_s, poll)
    end
    UIManager:scheduleIn(0.5, poll)
end

-- finished = the run ended by itself: nothing to kill (a Book Description lookup may
-- still be going and is left alone)
function Genres.stop(paused, finished)
    local util = require("ffi/util")
    for pid, job in pairs(finished and {} or Genres.jobs) do
        pcall(util.terminateSubProcess, pid)
        -- the worker is gone, so this only closes our end of the pipe
        if job.fd then pcall(util.readAllFromFD, job.fd) end
    end
    if not finished then Genres.jobs = {} end
    -- batches still on their way back (or run inline) are ignored from here
    Genres.gen = (Genres.gen or 0) + 1
    -- after any run (1.2.18; only after Offline Library before): rewrites the offline
    -- file only when it holds 50+ lines more than books
    if Genres.running then pcall(Offline.tidy) end
    Genres.running = false
    Genres.paused = paused and true or false
end

-- the whole library list, pulled fresh in the worker (Offline Library only)
local function libraryListStale()
    local e = page_cache["sort=title"]
    return not (type(e) == "table" and type(e.items) == "table" and #e.items > 0)
        or os.time() - (e.t or 0) > (cfg.cache_ttl or 1800)
end

local function fetchLibraryInWorker(client, done)
    runWorker(client, function()
        local items, page, total = {}, 1, nil
        for _guard = 1, 200 do
            local body = client:catalogBooks({ sort = "title", page = page, size = 100 })
            if type(body) ~= "table" then return nil end
            local list = body.items or body.books or body.entries or {}
            if type(list) ~= "table" or #list == 0 then break end
            for _i, b in ipairs(list) do
                if type(b) == "table" and b.id then items[#items + 1] = recordFromBo(b) end
            end
            total = tonumber(body.total) or tonumber(body.totalCount) or total
            if (total and page * 100 >= total) or #list < 100 then break end
            page = page + 1
        end
        return { items = items, total = total or #items }
    end, function(res)
        if type(res) == "table" and type(res.items) == "table" and #res.items > 0 then
            page_cache["sort=title"] = { t = os.time(), items = res.items, total = res.total }
            savePageCache()
        end
        done()
    end, 300)
end

-- details for one batch (in the worker): genres always; with Offline Library also the
-- description, page count, published, language, publisher and the cover
function Genres.fetchBatch(client, batch, full)
    local got, dir = {}, nil
    if full then
        dir = require("datastorage"):getDataDir() .. "/cache/bookorbit"
        pcall(function() require("util").makePath(dir) end)
    end
    for _k, b in ipairs(batch) do
        local okD, d = pcall(function() return client:catalogBook(b.id) end)
        if okD and type(d) == "table" then
            local e = { id = b.id, cv = b.cv, g = Genres.fromDetail(d) }
            if full then
                e.d = type(d.description) == "string" and d.description or nil
                e.p = tonumber(d.pageCount)
                e.pub = d.publishedDate or (d.publishedYear and tostring(d.publishedYear)) or nil
                e.lang = type(d.language) == "string" and d.language or nil
                e.publisher = type(d.publisher) == "string" and d.publisher or nil
                local path = string.format("%s/%s_%s.jpg", dir, tostring(b.id), tostring(b.cv ~= "" and b.cv or "0"))
                if lfs.attributes(path, "mode") ~= "file" then
                    pcall(function()
                        client:downloadCatalogThumbnail(b.id, path, {
                            temp_path = path .. ".part", max_bytes = 4 * 1024 * 1024, background = false,
                        })
                    end)
                    -- no cover on the server: remembered, so it isn't asked for again
                    if lfs.attributes(path, "mode") ~= "file" then e.nc = true end
                end
            end
            got[#got + 1] = e
        end
    end
    return got
end

function Genres.build(silent, list_done)
    if Genres.running then return end
    local full = cfg.offline_library and true or false
    local client = boApiClient()
    if full and not list_done and client and isWifiOn() and libraryListStale() then
        -- the library list first (new books, removed ones), in the background too
        Genres.running, Genres.full = true, true
        fetchLibraryInWorker(client, function()
            Genres.running = false
            Genres.build(silent, true)
        end)
        return
    end
    local books = Genres.library() or (not full and fetchBoPage({ sort = "title" }, false)) or {}
    local todo = Genres.missing(books, full)
    if #todo == 0 then Genres.paused = false return end
    -- genres only: books on the device first, from their files
    local store, net = Genres.load(), {}
    for _i, rec in ipairs(todo) do
        local path = (not full) and liveBookPath(rec.bookorbit_id)
        local g = path and Genres.fromFile(path) or {}
        if #g > 0 then
            store[tostring(rec.bookorbit_id)] = { cv = tostring(rec.bookorbit_cv or ""), g = g }
        else
            net[#net + 1] = rec
        end
    end
    Genres.save()
    if #net == 0 then
        local bs = getBookshelf()
        if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
        return
    end
    local what = full and _("Saving library") or _("Building genres")
    if not isWifiOn() then
        Genres.paused = true
        if not silent then
            Genres.note(full and _("Offline Library paused: Wi-Fi off")
                or _("Genres paused: Wi-Fi off"))
        end
        return
    end
    if not client then return end
    Genres.running, Genres.paused, Genres.full = true, false, full
    Genres.total, Genres.done = #net, 0
    if not silent then Genres.note(T(_("%1: 0 of %2"), what, #net)) end
    Genres.step(client, net, 1, silent)
end

-- One batch, then the next. Wi-Fi off or sleep stops it; Wi-Fi back carries on from
-- the next book. Silent runs (new books, a run picked up again) show no progress notes.
local GENRES_BATCH = 10
-- batches looked up at the same time (each its own worker), and how often the shelf
-- and the progress note update while it runs
-- 2 since 1.2.20 (3 before): on a device log the server answered one lookup at a time,
-- so a third worker added almost nothing but CPU and radio time
local WORKERS = 2
local REDRAW_S = 15
function Genres.step(client, net, i, silent)
    local full = Genres.full
    local what = full and _("Saving library") or _("Building genres")
    local gen = Genres.gen or 0
    local nxt, inflight = i, 0
    local last_shown = os.time()
    local function redraw()
        local bs = getBookshelf()
        if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
    end
    local launch
    local function finished()
        redraw()
        Genres.stop(false, true)
        Offline.sizeChanged()
        if not silent then Genres.note(full and _("Offline Library ready") or _("Genres ready")) end
    end
    local function landed(batch, got)
        if gen ~= (Genres.gen or 0) then return end -- stopped meanwhile
        inflight = inflight - 1
        if type(got) ~= "table" then
            -- the batch failed (network, server, sleep): stop for now, pick up later
            Genres.stop(true)
            return
        end
        local store = Genres.load()
        for _k, e in ipairs(got) do
            store[tostring(e.id)] = { cv = e.cv, g = type(e.g) == "table" and e.g or {} }
        end
        Genres.save()
        if full then
            Offline.put(got)
            BoCovers.forget()
        end
        Genres.done = math.min(Genres.total, Genres.done + #batch)
        if nxt > #net and inflight == 0 then return finished() end
        -- the shelf and the corner note at most every REDRAW_S seconds, not per batch
        if os.time() - last_shown >= REDRAW_S then
            last_shown = os.time()
            redraw()
            if not silent then Genres.note(T(_("%1: %2 of %3"), what, Genres.done, Genres.total)) end
        end
        launch()
    end
    -- keep up to WORKERS batches going; the next starts as soon as one lands
    launch = function()
        while inflight < (canFork() and WORKERS or 1) and nxt <= #net do
            if gen ~= (Genres.gen or 0) then return end
            if not isWifiOn() then
                Genres.stop(true)
                if not silent then Genres.note(T(_("%1 paused: Wi-Fi off (%2/%3)"), what, Genres.done, Genres.total)) end
                return
            end
            local batch = {}
            -- without a worker, one book at a time so taps get through between books
            local size = canFork() and GENRES_BATCH or 1
            for k = nxt, math.min(nxt + size - 1, #net) do
                batch[#batch + 1] = { id = net[k].bookorbit_id, cv = tostring(net[k].bookorbit_cv or "") }
            end
            nxt = nxt + #batch
            inflight = inflight + 1
            runWorker(client, function() return Genres.fetchBatch(client, batch, full) end,
                function(got) landed(batch, got) end)
        end
        if nxt > #net and inflight == 0 then finished() end
    end
    launch()
end

-- Opening the Genres shelf: when books still need looking up, ask once per start.
-- Once you have said Start (genres saved before), the rest - a build that was cut
-- short, or new books since - just carries on, quietly. With Offline Library on it
-- is already being built, so it just carries on.
function Genres.offer()
    if Genres.running or Genres.asked then return end
    if cfg.offline_library then
        Genres.asked = true
        if Genres.autoOn("wifi") then UIManager:nextTick(function() Genres.build(true) end) end
        return
    end
    local books = Genres.library() or {}
    local todo = Genres.missing(books)
    if #todo == 0 then return end
    local store = Genres.load()
    if next(store) ~= nil then
        Genres.asked = true
        UIManager:nextTick(function() Genres.build(true) end)
        return
    end
    Genres.asked = true
    UIManager:nextTick(function()
        local mins = math.max(1, math.floor(#todo * 0.3 / 60 + 0.5))
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = T(_("Genres need building first.\n\nBookOrbit doesn't send genres with its book lists, so each book's genres are looked up once: %1 books, about %2 min with Wi-Fi on. It runs in the background; the shelf fills in as it goes. Wi-Fi off pauses it, and it carries on when Wi-Fi is back."), #todo, mins),
            ok_text = _("Start"),
            cancel_text = _("Later"),
            ok_callback = function() Genres.build(false) end,
        })
    end)
end

-- Wi-Fi back on: a paused build carries on, and with Offline Library on new books are
-- picked up. The plugin gets KOReader's NetworkConnected itself (main.lua).
function Genres.onWifi()
    if Genres.running then return end
    if Genres.paused then
        -- a run that was cut short always carries on
        UIManager:scheduleIn(5, function() Genres.build(false) end)
    elseif cfg.offline_library and Genres.autoOn("wifi") then
        UIManager:scheduleIn(5, function() Genres.build(true) end)
    end
end

-- Offline Library > Check For New Books: when it looks on its own.
-- "wifi" (default): KOReader start and every Wi-Fi connect. "refresh": the hero's Sync
-- button and a swipe-down refresh on a BookOrbit shelf. "both". "manual": Update Now only.
function Genres.autoOn(trigger)
    local mode = cfg.offline_update or "wifi"
    if mode == "both" then return true end
    return mode == trigger
end

-- the library list pulled fresh (not the 30-minute saved one), then new / changed books
function Genres.updateNow(silent)
    local e = page_cache["sort=title"]
    if type(e) == "table" then
        page_cache["sort=title"] = { t = 0, items = e.items, total = e.total }
    end
    Genres.build(silent)
end

-- after a Sync or a swipe-down refresh (only when Check For New Books says so)
function Genres.afterRefresh()
    if not (cfg.offline_library and Genres.autoOn("refresh")) or Genres.running then return end
    UIManager:scheduleIn(1, function() Genres.updateNow(true) end)
end

function Genres.listen()
    if O.plugin then return end
    pcall(function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local fm = type(FM) == "table" and FM.instance
        if not (type(fm) == "table" and type(fm.registerModule) == "function") or fm.orbitshelf_genres then return end
        local Widget = require("ui/widget/widget")
        local listener = Widget:new{}
        function listener:onNetworkConnected()
            if Genres.running then return end
            if Genres.paused then
                UIManager:scheduleIn(5, function() Genres.build(false) end)
            elseif cfg.offline_library then
                UIManager:scheduleIn(5, function() Genres.build(true) end)
            end
        end
        fm:registerModule("orbitshelf_genres", listener)
    end)
end


-- shared with the other files
O.Genres = Genres
O.runWorker = runWorker
return O
