-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- The Queue (1.3.1): with Wi-Fi off, Download and Reading Status… don't ask to turn
-- Wi-Fi on, they go into a queue that runs the next time Wi-Fi connects.
--
-- Battery and speed: no timers, no polling, nothing at sleep. It only starts from
-- KOReader's Wi-Fi-connected event (once, a little after the connect, so it isn't
-- in the rush of everything else syncing on wake) or Download Queue Now. It never
-- turns Wi-Fi on. Status changes go first (one small call each), then the books one
-- at a time through the same background download Bulk Download uses, each checked
-- for space first. Sleep or Wi-Fi off stops it between books; the next connect
-- carries on. The queue is saved only when it changes. Covers tell a queued book by
-- a lookup in a table already in memory.
local O = require("orbitshelf_core")
local T, UIManager, _, cfg = O.T, O.UIManager, O._, O.cfg

local Queue = {}
O.Queue = Queue

local KEY = "orbitshelf_queue"
local START_DELAY = 15 -- seconds after Wi-Fi connects (wake syncs go first)

-- { downloads = { { id, title, t, note }... }, status = { [id] = { status, label, title, t, prev } } }
local q
local by_id -- id -> download entry (covers and menus ask this)

local function load()
    if q then return q end
    local saved = G_reader_settings and G_reader_settings:readSetting(KEY)
    q = { downloads = {}, status = {} }
    if type(saved) == "table" then
        for _i, e in ipairs(type(saved.downloads) == "table" and saved.downloads or {}) do
            local id = type(e) == "table" and tonumber(e.id)
            if id then q.downloads[#q.downloads + 1] = { id = id, title = e.title, t = e.t, note = e.note } end
        end
        for k, e in pairs(type(saved.status) == "table" and saved.status or {}) do
            local id = tonumber(k)
            if id and type(e) == "table" and type(e.status) == "string" then
                q.status[id] = { status = e.status, label = e.label, title = e.title, t = e.t,
                    prev = type(e.prev) == "string" and e.prev or nil }
            end
        end
    end
    by_id = {}
    for _i, e in ipairs(q.downloads) do by_id[e.id] = e end
    return q
end

local function save()
    if not (q and G_reader_settings) then return end
    local out = { downloads = {}, status = {} }
    for i, e in ipairs(q.downloads) do
        out.downloads[i] = { id = e.id, title = e.title, t = e.t, note = e.note }
    end
    for id, e in pairs(q.status) do
        out.status[tostring(id)] = { status = e.status, label = e.label, title = e.title, t = e.t, prev = e.prev }
    end
    if #out.downloads == 0 and next(out.status) == nil then
        G_reader_settings:delSetting(KEY)
    else
        G_reader_settings:saveSetting(KEY, out)
    end
    -- written now: queueing is a tap, and a reset shouldn't lose it
    if G_reader_settings.flush then pcall(G_reader_settings.flush, G_reader_settings) end
end

local function redraw()
    local bs = O.getBookshelf and O.getBookshelf()
    if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, O.SOURCE_ID) end
end

local function dlog(fmt, ...)
    local d = O.diag
    if cfg.diagnostics and type(d) == "table" and type(d.log) == "function" then
        pcall(d.log, "queue: " .. fmt, ...)
    end
end

local function idOf(book)
    if type(book) ~= "table" then return nil end
    return tonumber(book.bookorbit_id) or tonumber(book.id)
        or (O.bookIdForPath and tonumber(O.bookIdForPath(book.filepath)))
end

local function titleOf(book)
    local s = type(book) == "table" and (book.display_title or book.title) or nil
    return type(s) == "string" and s ~= "" and s or _("book")
end

local function short(s, max)
    s = tostring(s or "")
    if #s > max then s = s:sub(1, max - 2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") .. "…" end
    return s
end

-- a saved record for a queued id (the lists already in memory), or a bare one
local function recordFor(id, title)
    for _k, entry in pairs(O.page_cache or {}) do
        for _i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            if type(r) == "table" and tonumber(r.bookorbit_id) == id then return r end
        end
    end
    return { bookorbit_id = id, id = id, title = title, is_bookorbit = true, filepath = "bookorbit://" .. id }
end

local function freeText()
    local free = O.freeBytes and O.freeBytes()
    return free and T(_("%1 free"), O.mb(free)) or nil
end

-- ---- Asking ------------------------------------------------------------------------

function Queue.has(book_or_id)
    load()
    local id = type(book_or_id) == "table" and idOf(book_or_id) or tonumber(book_or_id)
    return id and by_id[id] ~= nil or false
end

-- a book's queued status (applyReadState shows it until it's sent), or nil
function Queue.statusOf(id)
    load()
    local e = q.status[tonumber(id) or -1]
    return e and e.status or nil
end

function Queue.count()
    load()
    local n = #q.downloads
    for _k in pairs(q.status) do n = n + 1 end
    return n, #q.downloads
end

function Queue.isEmpty()
    return Queue.count() == 0
end

-- the queued download entries in order, and the ids with a queued status
function Queue.entries()
    load()
    local ids = {}
    for _k in pairs(q.status) do ids[#ids + 1] = _k end
    table.sort(ids)
    return q.downloads, ids, q.status
end

-- ---- Changing ----------------------------------------------------------------------

local function summaryLine()
    local n = Queue.count()
    local free = freeText()
    local s = n == 1 and _("1 waiting") or T(_("%1 waiting"), n)
    return free and (s .. " · " .. free) or s
end

function Queue.addDownload(book)
    local id = idOf(book)
    if not id then return false end
    load()
    if by_id[id] then
        O.Genres.note(T(_("Already queued: %1"), short(titleOf(book), 28)))
        return true
    end
    if O.liveBookPath and O.liveBookPath(id) then
        O.Genres.note(_("Already on the device"))
        return false
    end
    local e = { id = id, title = titleOf(book), t = os.time() }
    q.downloads[#q.downloads + 1] = e
    by_id[id] = e
    save()
    pcall(O.Extras.ensureMarks)
    dlog("added download id=%s %q", tostring(id), e.title)
    O.Genres.note(T(_("Queued %1 · downloads on Wi-Fi · %2"), short(e.title, 24), summaryLine()))
    redraw()
    return true
end

-- the BookOrbit status the saved lists have for a book now, or nil
local function savedStatusOf(id)
    for _k, entry in pairs(O.page_cache or {}) do
        for _i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            if type(r) == "table" and tonumber(r.bookorbit_id) == id and type(r.bookorbit_status) == "string" then
                return r.bookorbit_status
            end
        end
    end
end

function Queue.addStatus(id, status, label, title)
    id = tonumber(id)
    if not id or type(status) ~= "string" then return false end
    load()
    -- only the last one for a book is sent; 2.0.1: what it was before, for Don't Send
    local old = q.status[id]
    local prev = old and old.prev or savedStatusOf(id)
    q.status[id] = { status = status, label = label, title = title, prev = prev, t = os.time() }
    save()
    pcall(O.Extras.ensureMarks)
    if O.noteReadStatus then pcall(O.noteReadStatus, id, status) end
    dlog("added status id=%s %s", tostring(id), status)
    O.Genres.note(T(_("%1 · sent on Wi-Fi"), tostring(label or status)))
    redraw()
    return true
end

function Queue.removeDownload(id, quiet)
    id = tonumber(id)
    load()
    for i, e in ipairs(q.downloads) do
        if e.id == id then
            table.remove(q.downloads, i)
            by_id[id] = nil
            save()
            if not quiet then
                O.Genres.note(T(_("Removed from the queue: %1"), short(e.title, 28)))
                redraw()
            end
            return true
        end
    end
    return false
end

-- revert (2.0.1, Don't Send): the covers go back to the status the book had before
function Queue.removeStatus(id, revert)
    id = tonumber(id)
    load()
    local e = q.status[id]
    if not e then return false end
    q.status[id] = nil
    save()
    if revert then
        dlog("status id=%s not sent (Don't Send)", tostring(id))
        if O.noteReadStatus then pcall(O.noteReadStatus, id, e.prev or false) end
        pcall(O.Extras.ensureMarks)
        if O.BookPage then pcall(O.BookPage.changed, id) end
        O.Genres.note(T(_("Not sending %1: %2"), tostring(e.label or e.status), short(e.title or ("#" .. id), 24)))
        redraw()
    end
    return true
end

-- a book's queued status entry (label, title), or nil
function Queue.statusEntry(id)
    load()
    return q.status[tonumber(id) or -1]
end

function Queue.moveToTop(id)
    id = tonumber(id)
    load()
    for i, e in ipairs(q.downloads) do
        if e.id == id then
            if i > 1 then
                table.remove(q.downloads, i)
                table.insert(q.downloads, 1, e)
                save()
                redraw()
            end
            O.Genres.note(T(_("Next in the queue: %1"), short(e.title, 28)))
            return true
        end
    end
    return false
end

function Queue.clear()
    load()
    q.downloads, q.status, by_id = {}, {}, {}
    save()
    redraw()
end

-- Download, or with Wi-Fi off, the queue (the hero, the Not On Device menu, Next In Series)
function Queue.downloadOrQueue(book)
    if O.isWifiOn() then
        O.downloadBookOrbitBook(book)
    else
        Queue.addDownload(book)
    end
end

-- Drop what no longer needs doing: a book on the device now (downloaded another way),
-- or one the library no longer has (only when the saved library list is there to say so).
function Queue.prune()
    load()
    local lib = O.page_cache and O.page_cache["sort=title"]
    local known
    if type(lib) == "table" and type(lib.items) == "table" and #lib.items > 0
            and (tonumber(lib.total) or 0) <= #lib.items then
        known = {}
        for _i, r in ipairs(lib.items) do
            local id = type(r) == "table" and tonumber(r.bookorbit_id)
            if id then known[id] = true end
        end
    end
    local changed = false
    for i = #q.downloads, 1, -1 do
        local e = q.downloads[i]
        if (O.liveBookPath and O.liveBookPath(e.id)) or (known and not known[e.id]) then
            table.remove(q.downloads, i)
            by_id[e.id] = nil
            changed = true
            dlog("pruned download id=%s", tostring(e.id))
        end
    end
    if known then
        for id in pairs(q.status) do
            if not known[id] then q.status[id] = nil changed = true end
        end
    end
    if changed then save() end
    return changed
end

-- ---- Running -----------------------------------------------------------------------

local run -- { gen, ok, failed, sent }
local gen = 0
Queue.starting = false

function Queue.running() return run ~= nil end

local function finishRun(stopped)
    local r = run
    if not r then return end
    run = nil
    local parts = {}
    if r.ok > 0 then parts[#parts + 1] = r.ok == 1 and _("1 book downloaded") or T(_("%1 books downloaded"), r.ok) end
    if r.sent > 0 then parts[#parts + 1] = r.sent == 1 and _("1 status sent") or T(_("%1 statuses sent"), r.sent) end
    local left = Queue.count()
    if left > 0 then parts[#parts + 1] = left == 1 and _("1 still waiting") or T(_("%1 still waiting"), left) end
    dlog("run %s: ok=%d sent=%d left=%d", stopped and "stopped" or "done", r.ok, r.sent, left)
    if #parts > 0 then O.Genres.note(_("Queue: ") .. table.concat(parts, " · ")) end
    redraw()
end

local nextDownload
nextDownload = function()
    local r = run
    if not r or r.gen ~= gen then return end
    if not O.isWifiOn() then return finishRun(true) end
    load()
    -- the next one not tried in this run
    local e
    for _i, d in ipairs(q.downloads) do
        if not r.tried[d.id] then e = d break end
    end
    if not e then return finishRun(false) end
    r.tried[e.id] = true
    if O.liveBookPath and O.liveBookPath(e.id) then
        Queue.removeDownload(e.id, true)
        UIManager:nextTick(nextDownload)
        return
    end
    local n_left = 0
    for _i, d in ipairs(q.downloads) do if not r.tried[d.id] then n_left = n_left + 1 end end
    local label = T(_("Queue: downloading %1 (%2 more)"), short(e.title, 20), n_left)
    local my_gen = r.gen
    O.downloadBookOrbitBook(recordFor(e.id, e.title), function()
        if not run or run.gen ~= my_gen then return end
        Queue.removeDownload(e.id, true)
        r.ok = r.ok + 1
        UIManager:nextTick(nextDownload)
    end, {
        quiet = true,
        no_redraw = true,
        check_space = true,
        progress_label = label,
        on_fail = function(msg)
            if not run or run.gen ~= my_gen then return end
            -- stays queued with why; the rest carry on
            e.note = msg and tostring(msg):gsub("\n", " ") or nil
            save()
            r.failed = r.failed + 1
            dlog("download id=%s stays queued: %s", tostring(e.id), tostring(e.note))
            UIManager:nextTick(nextDownload)
        end,
    })
end

-- the statuses first: one small call each
local function sendStatuses(done)
    local r = run
    load()
    local id = next(q.status)
    if not id then return done() end
    local client = O.boApiClient()
    if not client or type(O.runWorker) ~= "function" then return done() end
    local pending = {}
    for k, v in pairs(q.status) do pending[#pending + 1] = { id = k, status = v.status } end
    local my_gen = r.gen
    O.runWorker(client, function()
        local res = {}
        for i, p in ipairs(pending) do
            local body = client:catalogSetReadStatus(p.id, p.status)
            res[i] = { id = p.id, status = p.status, ok = body ~= nil and body ~= false }
        end
        return res
    end, function(res)
        if not run or run.gen ~= my_gen then return end
        local changed, sent = false, {}
        for _i, x in ipairs(type(res) == "table" and res or {}) do
            local cur = q.status[x.id]
            -- sent, and not changed again meanwhile
            if x.ok and cur and cur.status == x.status then
                q.status[x.id] = nil
                r.sent = r.sent + 1
                changed = true
                sent[#sent + 1] = x
            elseif not x.ok then
                dlog("status id=%s not sent, stays queued", tostring(x.id))
            end
        end
        if changed then
            save()
            pcall(function()
                local SM = require("bookorbit_state_manager")
                if type(SM.invalidate) == "function" then SM.invalidate() end
            end)
            -- 1.3.11: the saved lists get the sent status. A refresh on connect can
            -- land before the send with the old one, and with the queued one gone
            -- the cover went back to it (TK: On Hold set offline didn't stick).
            for _i, x in ipairs(sent) do
                if O.noteReadStatus then pcall(O.noteReadStatus, x.id, x.status) end
            end
        end
        done()
    end, 60)
end

function Queue.run(manual)
    if run then
        if manual then O.Genres.note(_("The queue is already running")) end
        return
    end
    Queue.prune()
    if Queue.isEmpty() then
        if manual then O.Genres.note(_("The queue is empty")) end
        return
    end
    if not O.isWifiOn() then
        if manual then O.Genres.note(_("Turn on Wi-Fi to run the queue")) end
        return
    end
    if O.Bulk and O.Bulk.running() then
        if manual then O.Genres.note(_("Bulk Download is running; the queue runs after it")) end
        return
    end
    if require("device").screen_saver_mode then return end
    gen = gen + 1
    run = { gen = gen, ok = 0, failed = 0, sent = 0, tried = {} }
    dlog("run start (%s): %d items", manual and "by hand" or "Wi-Fi", (Queue.count()))
    sendStatuses(nextDownload)
end

-- KOReader's Wi-Fi connected: once, a little later
function Queue.onWifi()
    load()
    if run or Queue.starting or Queue.isEmpty() then return end
    Queue.starting = true
    UIManager:scheduleIn(START_DELAY, function()
        Queue.starting = false
        Queue.run(false)
    end)
end

-- going to sleep: the background download is stopped with everything else; the book
-- it was on stays queued and the next connect carries on
function Queue.pause()
    if not run then return end
    gen = gen + 1
    local r = run
    run = nil
    for id in pairs(r.tried) do pcall(O.forgetDownloading, id) end
    dlog("paused for sleep: ok=%d sent=%d", r.ok, r.sent)
end

-- ---- Menu --------------------------------------------------------------------------

function Queue.menu()
    return {
        text_func = function()
            local n = Queue.count()
            return n == 0 and _("Queue: Empty") or T(_("Queue: %1"), summaryLine())
        end,
        sub_item_table_func = function()
            local items = {
                {
                    text = _("Download Queue Now"),
                    help_text = _("Runs the queue now (Wi-Fi on): saved reading statuses first, then the books one at a time. It also runs by itself a little after Wi-Fi connects."),
                    enabled_func = function() return not Queue.isEmpty() end,
                    callback = function() Queue.run(true) end,
                },
            }
            local downloads, status_ids, status = Queue.entries()
            for i, e in ipairs(downloads) do
                items[#items + 1] = {
                    text = T(_("%1. %2"), i, short(e.title, 40)) .. (e.note and (" · " .. short(e.note, 30)) or ""),
                    keep_menu_open = true,
                    callback = function(tmi)
                        local dlg
                        dlg = O.dialog{ colour = "teal",
                            title = tostring(e.title) .. (e.note and ("\n" .. e.note) or ""),
                            buttons = {
                                {{ text = _("Move To Top"), enabled = i > 1, callback = function()
                                    UIManager:close(dlg)
                                    Queue.moveToTop(e.id)
                                    if tmi and tmi.updateItems then tmi:updateItems() end
                                end }},
                                {{ text = _("Remove From Queue"), callback = function()
                                    UIManager:close(dlg)
                                    Queue.removeDownload(e.id)
                                    if tmi and tmi.updateItems then tmi:updateItems() end
                                end }},
                                {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }},
                            },
                        }
                        UIManager:show(dlg)
                    end,
                }
            end
            for _i, id in ipairs(status_ids) do
                local s = status[id]
                items[#items + 1] = {
                    text = T(_("Status: %1 · %2"), tostring(s.label or s.status), short(s.title or ("#" .. id), 32)),
                    keep_menu_open = true,
                    callback = function(tmi)
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = T(_("Don't send \"%1\" for %2?"), tostring(s.label or s.status), tostring(s.title or ("#" .. id))),
                            ok_text = _("Remove"),
                            ok_callback = function()
                                Queue.removeStatus(id, true)
                                if tmi and tmi.updateItems then tmi:updateItems() end
                            end,
                        })
                    end,
                }
            end
            items[#items].separator = true
            items[#items + 1] = {
                text = _("Clear Queue…"),
                enabled_func = function() return not Queue.isEmpty() end,
                callback = function(tmi)
                    UIManager:show(require("ui/widget/confirmbox"):new{
                        text = _("Remove everything from the queue? Nothing is downloaded or sent."),
                        ok_text = _("Clear"),
                        ok_callback = function()
                            Queue.clear()
                            if tmi and tmi.updateItems then tmi:updateItems() end
                        end,
                    })
                end,
            }
            return items
        end,
        help_text = _("With Wi-Fi off, Download and Reading Status… go into this queue instead of asking to turn Wi-Fi on. It runs by itself a little after Wi-Fi connects: statuses first, then the books one at a time, each checked for space. Sleep or Wi-Fi off stops it; the next connect carries on. A queued book shows a clock on its cover. Add a BookOrbit · Queue shelf in Bookshelf to see the books waiting to download. A waiting status can be dropped here, or with Don't Send in the book's Reading Status."),
    }
end

return Queue
