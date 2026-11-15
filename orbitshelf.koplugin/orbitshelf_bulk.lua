-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Bulk Download / Bulk Remove (settings, off by default): hold a book, tap Bulk
-- Download… or Bulk Remove…, tick books from that shelf. Downloads go one at a time
-- after a size and space check; removals all at once after one question.
local O = require("orbitshelf_core")
local T, UIManager, _ = O.T, O.UIManager, O._

local Bulk = {}
O.Bulk = Bulk

-- ---- Which shelf the held book is on ----------------------------------------------
-- The source's fetch hands every list it serves to remember() (a reference, nothing
-- copied). The shelf on screen is the most recent list holding every book on the
-- page; failing that, the most recent one holding the held book.

local levels = {} -- most recent first: { key, source, drill, items }
local MAX_LEVELS = 8

local function levelKey(source, drill)
    local s = type(source) == "table" and source or {}
    local parts = { tostring(s.mode or "library"),
        tostring(s.collection_id or s.library_id or s.smart_scope_id or ""), tostring(s.group_by or ""),
        tostring(s.show or "") }
    if type(drill) == "table" then
        parts[#parts + 1] = tostring(drill.group or "")
        parts[#parts + 1] = tostring(drill.key or "")
    end
    return table.concat(parts, "|")
end

function Bulk.remember(source, drill, items)
    local key = levelKey(source, drill)
    for i = #levels, 1, -1 do
        if levels[i].key == key then table.remove(levels, i) end
    end
    table.insert(levels, 1, { key = key, source = source, drill = drill, items = items })
    while #levels > MAX_LEVELS do table.remove(levels) end
end

local function idOf(rec)
    if type(rec) ~= "table" or rec.is_folder then return nil end
    return tonumber(rec.bookorbit_id)
end

-- a level's books in shelf order; folders (Spines: a run per series / author /
-- genre) give their books
local function booksOf(level)
    local out, seen = {}, {}
    local function add(rec)
        local id = idOf(rec)
        if id and not seen[id] then
            seen[id] = true
            out[#out + 1] = rec
        end
    end
    for i = 1, #level.items do
        local rec = level.items[i]
        if type(rec) == "table" and rec.is_folder then
            for j, b in ipairs(type(rec.books) == "table" and rec.books or {}) do add(b) end
        else
            add(rec)
        end
    end
    return out, seen
end

local function shelfWidget(widget)
    if type(widget) == "table" then return widget end
    local bs = O.getBookshelf()
    return type(bs) == "table" and bs._widget or nil
end

local function pageIds(widget)
    local ids = {}
    local w = shelfWidget(widget)
    local items = type(w) == "table" and (w._page_items or w._spine_page_books)
    for i, rec in ipairs(type(items) == "table" and items or {}) do
        if type(rec) == "table" and rec.is_folder and type(rec.books) == "table" then
            for j, b in ipairs(rec.books) do
                local id = idOf(b)
                if id then ids[#ids + 1] = id end
            end
        else
            local id = idOf(rec)
            if id then ids[#ids + 1] = id end
        end
    end
    return ids
end

local function levelFor(book, widget)
    local id = idOf(book)
    if not id then return nil end
    local ids = pageIds(widget)
    local first_level, first_books
    for i, level in ipairs(levels) do
        local books, seen = booksOf(level)
        if seen[id] then
            if not first_level then first_level, first_books = level, books end
            local all = #ids > 0
            for j = 1, #ids do
                if not seen[ids[j]] then
                    all = false
                    break
                end
            end
            if all then return level, books end
        end
    end
    return first_level, first_books
end

local function levelLabel(level)
    if not level then return _("This Book") end
    local d = level.drill
    if type(d) == "table" and d.group == "search" then return T(_("Search: %1"), tostring(d.key or "")) end
    if type(d) == "table" and d.key then return tostring(d.label or d.key) end
    local s = type(level.source) == "table" and level.source or {}
    if type(s.label) == "string" and s.label ~= "" then return s.label end
    return O.autoShelfName and O.autoShelfName(s) or _("BookOrbit")
end

local function onDevice(rec)
    local p = rec.filepath
    if type(p) == "string" and not p:match("^bookorbit://") and O.lfs.attributes(p, "mode") == "file" then
        return true
    end
    return O.liveBookPath(rec.bookorbit_id) and true or false
end

local function shortTitle(rec, max)
    local t = tostring(rec.display_title or rec.title or _("book"))
    max = max or 28
    if #t > max then t = t:sub(1, max - 2):gsub("[\128-\191]+$", ""):gsub("[\192-\255]$", "") .. "…" end
    return t
end

local function firstAuthor(rec)
    local a = rec.author
    if type(a) ~= "string" or a == "" then a = type(rec.authors) == "table" and rec.authors[1] or nil end
    return type(a) == "string" and a ~= "" and a:lower() or nil
end

local function seriesOf(rec)
    return type(rec.series) == "string" and rec.series ~= "" and rec.series:lower() or nil
end

-- ---- The queue ----------------------------------------------------------------------

local job -- { list, i, ok, skipped, failed, label, gen, paused, stop_after }

local function redraw()
    local bs = O.getBookshelf()
    if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, O.SOURCE_ID) end
end

local function popup(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function summary(j, head)
    local lines = { head }
    if j.skipped > 0 then lines[#lines + 1] = T(_("%1 were already on the device."), j.skipped) end
    if #j.failed > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Not downloaded:")
        for i = 1, math.min(8, #j.failed) do
            local f = j.failed[i]
            lines[#lines + 1] = "• " .. f.title .. (f.msg and f.msg ~= "" and (" (" .. f.msg:gsub("\n", " ") .. ")") or "")
        end
        if #j.failed > 8 then lines[#lines + 1] = T(_("… and %1 more"), #j.failed - 8) end
    end
    return table.concat(lines, "\n")
end

local function finish()
    local j = job
    if not j then return end
    job = nil
    redraw()
    local done_text = j.ok == 1 and _("Downloaded 1 book") or T(_("Downloaded %1 books"), j.ok)
    if #j.failed == 0 and not j.stop_after then
        O.Genres.note(done_text)
    elseif #j.failed == 0 then
        O.Genres.note(T(_("Bulk download stopped: %1"), done_text:lower()))
    else
        popup(summary(j, T(_("Downloaded %1 of %2."), j.ok, #j.list)))
    end
end

-- stopped by something other than the reader (Wi-Fi off): a popup says how far it got
local function halt(reason)
    local j = job
    if not j then return end
    job = nil
    redraw()
    popup(summary(j, T(_("Bulk download stopped: %1.\n%2 of %3 downloaded."), reason, j.ok, #j.list)))
end

local nextBook
nextBook = function()
    local j = job
    if not j or j.paused then return end
    if j.stop_after then return finish() end
    j.i = j.i + 1
    if j.i > #j.list then return finish() end
    local rec = j.list[j.i]
    if onDevice(rec) then
        j.skipped = j.skipped + 1
        UIManager:nextTick(nextBook)
        return
    end
    if not O.isWifiOn() then
        j.i = j.i - 1
        return halt(_("Wi-Fi is off"))
    end
    local note = T(_("Downloading %1 of %2: %3"), j.i, #j.list, shortTitle(rec, 18))
    O.Genres.note(note)
    local gen = j.gen
    local function current() return job == j and j.gen == gen end
    O.downloadBookOrbitBook(rec, function()
        if not current() then return end
        j.ok = j.ok + 1
        UIManager:nextTick(nextBook)
    end, {
        quiet = true,
        no_redraw = true,
        progress_label = note,
        on_fail = function(msg)
            if not current() then return end
            j.failed[#j.failed + 1] = { title = shortTitle(rec, 40), msg = msg and tostring(msg) or nil }
            UIManager:nextTick(nextBook)
        end,
    })
end

local function start(list, label)
    job = { list = list, i = 0, ok = 0, skipped = 0, failed = {}, label = label, gen = 1 }
    local okN, NetworkMgr = pcall(require, "ui/network/manager")
    if okN and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(nextBook)
    else
        nextBook()
    end
end

function Bulk.running()
    return job ~= nil
end

-- the reader stops it: the book downloading now finishes, then it ends
function Bulk.stop()
    local j = job
    if not j then return end
    if j.paused then
        finish()
        return
    end
    j.stop_after = true
    O.Genres.note(_("Stopping after this book"))
end

-- going to sleep: the download worker is stopped with everything else, so the book it
-- was on is tried again if the reader continues
function Bulk.pause()
    local j = job
    if not j or j.paused then return end
    j.paused = true
    j.gen = j.gen + 1
    local rec = j.list[j.i]
    if rec then
        pcall(O.forgetDownloading, rec.bookorbit_id)
        j.i = j.i - 1
    end
end

-- awake again and off the sleep screen: ask (a question, so a popup)
function Bulk.offerResume()
    local j = job
    if not j or not j.paused or j.asking then return end
    if require("device").screen_saver_mode then return end
    j.asking = true
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("Bulk download paused while the device slept.\n%1 of %2 downloaded.\n\nContinue?"), j.ok, #j.list),
        ok_text = _("Continue"),
        cancel_text = _("Stop"),
        ok_callback = function()
            if job ~= j then return end
            j.asking, j.paused = nil, false
            local okN, NetworkMgr = pcall(require, "ui/network/manager")
            if okN and NetworkMgr.runWhenConnected then
                NetworkMgr:runWhenConnected(nextBook)
            else
                nextBook()
            end
        end,
        cancel_callback = function()
            if job ~= j then return end
            j.asking = nil
            finish()
        end,
    })
end


-- ---- Size and space ----------------------------------------------------------------

local function mb(bytes)
    if not bytes then return "?" end
    if bytes >= 1024 ^ 3 then return string.format("%.1f GB", bytes / 1024 ^ 3) end
    return string.format("%d MB", math.max(1, math.floor(bytes / 1024 ^ 2 + 0.5)))
end

local function freeBytes()
    local okR, Root = pcall(require, "bookorbit_download_root")
    local root = okR and type(Root) == "table" and Root.get and Root.get()
        or (G_reader_settings and G_reader_settings:readSetting("home_dir"))
    if type(root) ~= "string" or root == "" then return nil end
    local okU, util = pcall(require, "util")
    local du = okU and util.diskUsage and util.diskUsage(root)
    return type(du) == "table" and du.available or nil
end

O.mb = mb
O.freeBytes = freeBytes

-- the selected books' sizes, looked up in the worker: BookOrbit's bulk manifest
-- answers up to 100 books a call (129 books = 2 calls). A server without it: one
-- detail call a book, only for up to 25 books (more just goes without a size).
-- done(total_bytes or nil, unknown_count)
local MANIFEST_IDS, MANIFEST_PAGE, DETAIL_MAX = 500, 100, 25
local function sizeOf(list, done)
    local client = O.boApiClient()
    if not client or type(O.runWorker) ~= "function" or not O.isWifiOn() then return done(nil, #list) end
    local ids = {}
    for i = 1, #list do ids[i] = idOf(list[i]) end
    O.Genres.note(_("Checking sizes…"))
    O.runWorker(client, function()
        local okU, CU = pcall(require, "bookorbit_catalog_util")
        local function usable(f)
            return type(f) == "table" and f.id and (not okU or type(CU.isSupportedFormat) ~= "function"
                or CU.isSupportedFormat(f.format))
        end
        local function fileSize(files)
            local size
            for j, f in ipairs(type(files) == "table" and files or {}) do
                if usable(f) and (f.role == "primary" or not size) then size = tonumber(f.sizeBytes) end
                if usable(f) and f.role == "primary" then break end
            end
            return size
        end
        local sizes = {}
        local manifest_ok = type(client.catalogManifest) == "function"
        if manifest_ok then
            for start = 1, #ids, MANIFEST_IDS do
                local chunk = {}
                for k = start, math.min(#ids, start + MANIFEST_IDS - 1) do chunk[#chunk + 1] = tostring(ids[k]) end
                local cursor
                repeat
                    local body = client:catalogManifest({ ids = table.concat(chunk, ","), size = MANIFEST_PAGE, cursor = cursor })
                    if type(body) ~= "table" or type(body.items) ~= "table" then
                        manifest_ok = false
                        break
                    end
                    for k, b in ipairs(body.items) do
                        local id = tonumber(type(b) == "table" and b.id)
                        if id then sizes[id] = fileSize(b.files) or false end
                    end
                    cursor = body.hasNext and body.nextCursor or nil
                until not cursor
                if not manifest_ok then break end
            end
        end
        if not manifest_ok then
            if #ids > DETAIL_MAX then return { total = nil, unknown = #ids } end
            for i = 1, #ids do
                sizes[ids[i]] = fileSize(type(client.catalogBook) == "function" and (client:catalogBook(ids[i]) or {}).files) or false
            end
        end
        local total, unknown = 0, 0
        for i = 1, #ids do
            local size = sizes[ids[i]]
            if size then total = total + size else unknown = unknown + 1 end
        end
        return { total = total, unknown = unknown }
    end, function(res)
        if type(res) ~= "table" then return done(nil, #list) end
        done(res.total, res.unknown)
    end, 60)
end

-- ---- Removing ----------------------------------------------------------------------

local function removeAll(list)
    local ok, failed = 0, {}
    for i = 1, #list do
        local rec = list[i]
        local done_ok, gone = pcall(O.deleteBookFiles, rec)
        if done_ok and gone then
            ok = ok + 1
        else
            failed[#failed + 1] = shortTitle(rec, 40)
        end
    end
    redraw()
    if #failed == 0 then
        O.Genres.note(ok == 1 and _("Removed 1 book") or T(_("Removed %1 books"), ok))
    else
        local lines = { T(_("Removed %1 of %2."), ok, #list), "", _("Not removed:") }
        for i = 1, math.min(8, #failed) do lines[#lines + 1] = "• " .. failed[i] end
        popup(table.concat(lines, "\n"))
    end
end

-- ---- The checklist ------------------------------------------------------------------
-- mode "download": the shelf's books not on the device; "remove": the ones on it.

local function showChecklist(book, widget, mode)
    local removing = mode == "remove"
    local level, books = levelFor(book, widget)
    books = books or { book }
    local cands = {}
    for i = 1, #books do
        if onDevice(books[i]) == removing then cands[#cands + 1] = books[i] end
    end
    -- the held book itself, when its shelf isn't one of ours (Bookshelf's own shelves)
    if #cands == 0 and onDevice(book) == removing then cands[1] = book end
    if #cands == 0 then
        O.Genres.note(removing and _("No book here is on the device") or _("Every book here is on the device"))
        return
    end
    local held = idOf(book)
    local sel = {}
    if held then sel[held] = true end
    local label = levelLabel(level)

    local function count()
        local n = 0
        for i = 1, #cands do
            if sel[idOf(cands[i])] then n = n + 1 end
        end
        return n
    end

    local function line(rec)
        local t = tostring(rec.display_title or rec.title or "")
        if type(rec.series) == "string" and rec.series ~= "" then
            local n = tonumber(rec.series_index)
            t = t .. " · " .. rec.series .. (n and (" #" .. tostring(n)) or "")
        end
        return t
    end

    local menu
    local checking = false -- sizes being looked up: Download waits, no second question
    local function items()
        local n = count()
        local go_text
        if checking then
            go_text = _("Checking sizes…")
        elseif n == 0 then
            go_text = _("(tick some books)")
        elseif removing then
            go_text = n == 1 and _("Remove 1 Book") or T(_("Remove %1 Books"), n)
        else
            go_text = n == 1 and _("Download 1 Book") or T(_("Download %1 Books"), n)
        end
        local out = {
            { text = go_text, bold = true, dim = n == 0 or checking, action = "go" },
            { text = _("Select…"), action = "select" },
        }
        for i = 1, #cands do
            local rec = cands[i]
            out[#out + 1] = { text = line(rec), mandatory = sel[idOf(rec)] and "✓" or "", book = rec }
        end
        return out
    end
    local function refresh()
        if menu then menu:switchItemTable(nil, items(), -1) end
    end

    local function selectBy(fn)
        sel = {}
        for i = 1, #cands do
            if fn(cands[i]) then sel[idOf(cands[i])] = true end
        end
        refresh()
    end

    -- 1.3.15: finished = KOReader's own status on this Kobo (finished), else
    -- BookOrbit's (Read / Skimmed); read once per window
    local finished_of = {}
    local function isFinished(rec)
        local id = idOf(rec)
        if id == nil then return false end
        if finished_of[id] == nil then
            local yes = false
            local path = O.liveBookPath and O.liveBookPath(id)
            local st
            if path then
                pcall(function()
                    local DocSettings = require("docsettings")
                    if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return end
                    local summary = DocSettings:open(path):readSetting("summary")
                    st = type(summary) == "table" and summary.status or nil
                end)
            end
            if st == "complete" then yes = true
            elseif st == nil or st == "" or st == "new" then
                local bo = rec.bookorbit_status
                yes = bo == "read" or bo == "skimmed"
            end
            finished_of[id] = yes
        end
        return finished_of[id]
    end

    local function selectMenu()
        local ButtonDialog = require("ui/widget/buttondialog")
        local s, a = seriesOf(book), firstAuthor(book)
        local dlg
        local function pick(fn)
            return function()
                UIManager:close(dlg)
                selectBy(fn)
            end
        end
        local buttons = {
            {{ text = _("All"), callback = pick(function() return true end) }},
        }
        -- 1.3.15 (TK): Bulk Remove can tick just the finished books
        if removing then
            local n = 0
            for i = 1, #cands do if isFinished(cands[i]) then n = n + 1 end end
            buttons[#buttons + 1] = {{ text = T(_("Finished Books (%1)"), n), enabled = n > 0, callback = pick(isFinished) }}
        end
        buttons[#buttons + 1] = {{ text = _("Same Series"), enabled = s ~= nil,
            callback = pick(function(r) return seriesOf(r) == s end) }}
        buttons[#buttons + 1] = {{ text = _("Same Author"), enabled = a ~= nil,
            callback = pick(function(r) return firstAuthor(r) == a end) }}
        buttons[#buttons + 1] = {{ text = _("None"), callback = pick(function() return false end) }}
        buttons[#buttons + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
        dlg = ButtonDialog:new{ title = _("Select"), buttons = buttons }
        UIManager:show(dlg)
    end

    local function go()
        local list = {}
        for i = 1, #cands do
            if sel[idOf(cands[i])] then list[#list + 1] = cands[i] end
        end
        if #list == 0 or checking then return end
        local ConfirmBox = require("ui/widget/confirmbox")
        if removing then
            UIManager:show(ConfirmBox:new{
                text = (#list == 1 and _("Remove 1 book from this device?") or T(_("Remove %1 books from this device?"), #list))
                    .. "\n\n" .. _("They stay in BookOrbit."),
                ok_text = _("Remove"),
                ok_callback = function()
                    UIManager:close(menu)
                    removeAll(list)
                end,
            })
            return
        end
        -- download: sizes first, then one question with the space left
        checking = true
        refresh()
        sizeOf(list, function(total, unknown)
            checking = false
            refresh()
            local free = freeBytes()
            if total and free and total + 50 * 1024 ^ 2 > free then
                popup(T(_("Not enough space: these need about %1 and %2 is free."), mb(total), mb(free)))
                return
            end
            local what = #list == 1 and _("Download 1 book?") or T(_("Download %1 books?"), #list)
            local size_line
            if total and total > 0 then
                size_line = T(_("About %1"), mb(total)) .. (unknown > 0 and T(_(" (%1 without a size)"), unknown) or "")
                    .. (free and (" · " .. T(_("%1 free"), mb(free))) or "")
            elseif free then
                size_line = T(_("%1 free on the device"), mb(free))
            end
            UIManager:show(ConfirmBox:new{
                text = what .. (size_line and ("\n" .. size_line) or "") .. "\n\n"
                    .. _("They download one at a time. To stop, hold a book that isn't on the device and tap Stop Bulk Download."),
                ok_text = _("Download"),
                ok_callback = function()
                    UIManager:close(menu)
                    start(list, label)
                end,
            })
        end)
    end

    local Menu = require("ui/widget/menu")
    local Screen = require("device").screen
    local subtitle
    if removing then
        subtitle = #cands == 1 and _("1 book on this device") or T(_("%1 books on this device"), #cands)
    else
        subtitle = #cands == 1 and _("1 book not on this device") or T(_("%1 books not on this device"), #cands)
    end
    menu = Menu:new{
        title = T(removing and _("Bulk Remove: %1") or _("Bulk Download: %1"), label),
        subtitle = subtitle,
        item_table = items(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(self_m, item)
            if item.action == "go" then
                go()
            elseif item.action == "select" then
                selectMenu()
            elseif item.book then
                local id = idOf(item.book)
                if id then sel[id] = not sel[id] or nil end
                refresh()
            end
            return true
        end,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

local function open(book, widget, mode)
    local ok, err = pcall(showChecklist, book, widget, mode)
    if not ok then
        O.problem("bulk", "Bulk " .. mode .. " failed:", err)
        popup(_("Couldn't open the list."))
    end
end

-- ---- The rows in the hold menus -----------------------------------------------------
-- ButtonDialog buttons (or nil).

-- Bulk Download… for a book that isn't on the device, dimmed with Wi-Fi off; Stop Bulk
-- Download while one is running.
-- always (1.3.14, the Book Page): offered whether or not this book is on the device
-- (the window lists the shelf's books that aren't)
function Bulk.row(book, widget, close, always)
    if job then
        return { text = T(_("Stop Bulk Download (%1 of %2)"), math.max(job.i, 1), #job.list), callback = function()
            if close then close() end
            Bulk.stop()
        end }
    end
    if not idOf(book) or (onDevice(book) and not always) then return nil end
    return { text = _("Bulk Download…"), enabled = O.isWifiOn() and true or false, callback = function()
        if close then close() end
        open(book, widget, "download")
    end }
end

-- Bulk Remove… for a BookOrbit book that is on the device
-- always (1.3.14, the Book Page): offered for a book not on the device too, so the
-- shelf's other books can be removed from its page (TK)
function Bulk.removeRow(book, widget, close, always)
    if not idOf(book) or (not onDevice(book) and not always) then return nil end
    return { text = _("Bulk Remove…"), callback = function()
        if close then close() end
        open(book, widget, "remove")
    end }
end

return Bulk
