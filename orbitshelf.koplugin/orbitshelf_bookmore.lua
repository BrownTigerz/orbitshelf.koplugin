-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.14 (TK): the Book Page's More ▾ and the stats page's chips.
--   * More ▾ (a sheet): Sync (ShelfSync: this book, opening it first; its waiting
--     updates; BookOrbit: its library sync), Link (ShelfSync's sites: Link This Book from
--     ShelfSync Tweaks, else the book opens and ShelfSync's own Link; Bookshelf's Hardcover
--     book picker; BookOrbit), This Book (Highlights, Bookmarks, X-Ray), Downloads And Settings (Settings, Help)
--   * Highlights / Bookmarks: the book's own, from its sidecar; a tap opens the book there
--   * X-Ray: who you spent the most time with; Open X-Ray opens the book and X-Ray's menu
-- Nothing here changes another plugin's settings: it calls what each one offers.
local O = require("orbitshelf_core")
local T, _, UIManager = O.T, O._, O.UIManager

local BM = {}
O.BookMore = BM

local function W(name) return require("ui/widget/" .. name) end
local function note(s, secs) UIManager:show(W("infomessage"):new{ text = s, timeout = secs or 3 }) end

-- ---- Open the book, then … --------------------------------------------------------------

-- open path in the reader and run fn(ui) once it's ready (main.lua's onReaderReady)
function O.openThen(path, fn)
    if type(path) ~= "string" then return end
    O._after_open = { file = path, fn = fn, at = os.time() }
    require("apps/reader/readerui"):showReader(path)
end

-- main.lua's onReaderReady: the waiting step, for this book only, within two minutes
function O.runAfterOpen(ui)
    local a = O._after_open
    O._after_open = nil
    if not (a and ui and ui.document and ui.document.file == a.file and os.time() - a.at < 120) then return end
    UIManager:scheduleIn(0.6, function()
        local ok, err = pcall(a.fn, ui)
        if not ok then O.logger.warn(O.TAG, "after opening:", tostring(err)) end
    end)
end

-- 2.1.23 (TK): a swipe down on the Book Page or the stats page brings KOReader's top menu
-- (with the Shortcuts Toolbar) over it, as it does on Bookshelf, instead of closing the page
function O.showTopMenu()
    local ok = pcall(function()
        local FM = require("apps/filemanager/filemanager").instance
        if FM and FM.menu and type(FM.menu.onShowMenu) == "function" then
            FM.menu:onShowMenu()
        else
            UIManager:sendEvent(require("ui/event"):new("ShowMenu"))
        end
    end)
    return ok
end

-- ---- Highlights and bookmarks -----------------------------------------------------------

local HL_HUE = { yellow = "gold", red = "red", orange = "orange", green = "green", olive = "green", cyan = "teal",
    blue = "blue", purple = "purple", gray = "purple" }

-- the book's highlights and bookmarks (KOReader's annotations: a highlight has pos0)
function BM.notes(path)
    local out = { hl = {}, marks = {}, notes = 0 }
    if type(path) ~= "string" then return out end
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return end
        local list = DocSettings:open(path):readSetting("annotations")
        for _i, a in ipairs(type(list) == "table" and list or {}) do
            if type(a) == "table" then
                local e = { go = a.page, pageno = tonumber(a.pageno), text = type(a.text) == "string" and a.text or nil,
                    note = type(a.note) == "string" and a.note ~= "" and a.note or nil,
                    chapter = type(a.chapter) == "string" and a.chapter or nil, when = a.datetime,
                    colour = HL_HUE[tostring(a.color or "yellow")] }
                if a.pos0 then
                    out.hl[#out.hl + 1] = e
                    if e.note then out.notes = out.notes + 1 end
                else
                    out.marks[#out.marks + 1] = e
                end
            end
        end
    end)
    local function byPage(a, b) return (a.pageno or 0) < (b.pageno or 0) end
    table.sort(out.hl, byPage)
    table.sort(out.marks, byPage)
    return out
end

-- open the book at a highlight or bookmark
local function goTo(path, e)
    O.openThen(path, function(ui)
        local Event = require("ui/event")
        if type(e.go) == "string" then
            ui:handleEvent(Event:new("GotoXPointer", e.go, e.go))
        elseif tonumber(e.go) or e.pageno then
            ui:handleEvent(Event:new("GotoPage", tonumber(e.go) or e.pageno))
        end
    end)
end

local PER = 5

-- Highlights or Bookmarks, a few to a page
function BM.showNotes(kind, _rec, path)
    local all = BM.notes(path)
    local list = kind == "marks" and all.marks or all.hl
    if #list == 0 then
        note(kind == "marks" and _("No bookmarks in this book yet.") or _("No highlights in this book yet."))
        return
    end
    local sub
    if kind == "marks" then
        sub = #list == 1 and _("1 bookmark") or T(_("%1 bookmarks"), #list)
    else
        local most, n, count = nil, 0, {}
        for _i, e in ipairs(list) do
            if e.pageno then
                count[e.pageno] = (count[e.pageno] or 0) + 1
                if count[e.pageno] > n then most, n = e.pageno, count[e.pageno] end
            end
        end
        sub = (#list == 1 and _("1 highlight") or T(_("%1 highlights"), #list))
            .. (all.notes > 0 and (" · " .. (all.notes == 1 and _("1 note") or T(_("%1 notes"), all.notes))) or "")
            .. (most and n > 1 and (" · " .. T(_("most on p. %1"), most)) or "")
    end
    local pages = math.max(1, math.ceil(#list / PER))
    local widget
    local function spec(page)
        local rows = {}
        for i = (page - 1) * PER + 1, math.min(#list, page * PER) do
            local e = list[i]
            local words = e.text and ("“" .. e.text:gsub("%s+", " ") .. "”")
                or (e.chapter and T(_("In %1"), e.chapter)) or _("Bookmark")
            rows[#rows + 1] = { page = e.pageno and T(_("p. %1"), e.pageno) or "", text = words, note = e.note,
                max_chars = 170, colour = kind == "marks" and "blue" or e.colour,
                hint = kind == "marks" and e.text and e.chapter or _("tap to open the book here"),
                callback = function() goTo(path, e) end }
        end
        local items = { { kind = "quote", list = rows } }
        if pages > 1 then
            local nav = {}
            if page > 1 then nav[#nav + 1] = { text = _("‹ Back"), keep = true, colour = "gold",
                callback = function() widget:rebuild(spec(page - 1)) end } end
            if page < pages then nav[#nav + 1] = { text = _("More ›"), keep = true, fill = true, colour = "gold",
                callback = function() widget:rebuild(spec(page + 1)) end } end
            items[#items + 1] = { kind = "pills", list = nav }
        end
        return { title = kind == "marks" and _("Bookmarks") or _("Highlights"),
            subtitle = sub .. (pages > 1 and (" · " .. page .. " / " .. pages) or ""),
            sections = { { colour = kind == "marks" and "blue" or "gold", plain = true, items = items } } }
    end
    widget = O.Sheet.show(spec(1))
end

-- ---- X-Ray ------------------------------------------------------------------------------

local function xrayCached(path)
    local ok, has = pcall(function()
        local dir = require("docsettings"):getSidecarDir(path)
        return O.lfs.attributes(dir .. "/xray_cache.lua", "mode") == "file"
    end)
    return ok and has or false
end

local function openXRay(path)
    O.openThen(path, function(ui) ui:handleEvent(require("ui/event"):new("ShowXRayQuickMenu")) end)
end

-- who you spent the most time with (the stats page's X-Ray numbers), and Open X-Ray
function BM.showXRay(_rec, path, xr)
    local secs = O.Stats and O.Stats._kit and O.Stats._kit.durS
    local function rows(list, colour)
        local out = {}
        for i = 1, math.min(5, #(list or {})) do
            out[#out + 1] = { text = list[i].name, note = secs and secs(list[i].secs) or nil, colour = colour, enabled = true }
        end
        return out
    end
    local sections = {}
    if xr and #xr.people > 0 then
        sections[#sections + 1] = { title = _("Most time with"), colour = "purple", items = { { kind = "list", list = rows(xr.people, "purple") } } }
    end
    if xr and #xr.places > 0 then
        sections[#sections + 1] = { title = _("Most time in"), colour = "teal", items = { { kind = "list", list = rows(xr.places, "teal") } } }
    end
    local has = xrayCached(path)
    sections[#sections + 1] = { title = _("X-Ray"), colour = "blue", items = { { kind = "action", list = { {
        text = has and _("Open X-Ray") or _("Fetch X-Ray"),
        sub = has and _("Opens the book, then X-Ray's menu.") or _("Not fetched for this book yet. Opens the book, then X-Ray's menu to fetch it."),
        button = has and _("Open") or _("Fetch"), callback = function() openXRay(path) end } } } } }
    O.Sheet.show{ title = _("X-Ray"), subtitle = xr and T(_("%1 people met so far"), xr.met_people or 0) or nil, sections = sections }
end

-- ---- Sync and link ----------------------------------------------------------------------

local SS_SITES = { storygraph = "StoryGraph", hardcover = "Hardcover", goodreads = "Goodreads", fable = "Fable",
    pagebound = "Pagebound", librarything = "LibraryThing" }

local function fm()
    local ok, FM = pcall(require, "apps/filemanager/filemanager")
    return ok and type(FM) == "table" and FM or nil, ok and type(FM) == "table" and FM.instance or nil
end

-- ShelfSync's sites that are on, each with this book's link
local function shelfSync(path)
    local inst = select(2, fm())
    local app = type(inst) == "table" and inst.shelfsync
    if not (type(app) == "table" and type(app.engines) == "table") then return nil end
    local sites, waiting = {}, {}
    for key, e in pairs(app.engines) do
        local ok_a, active = pcall(function() return e:isActive() end)
        if ok_a and active and SS_SITES[key] then
            local s = { key = key, label = e.label or SS_SITES[key], engine = e }
            if path then
                pcall(function()
                    s.linked = e.settings:readBookSetting(path, "book_id") ~= nil
                    s.title = e.settings:readBookSetting(path, "title")
                    s.format = e.settings:readBookSetting(path, "edition_format")
                end)
            end
            pcall(function()
                for _i, f in ipairs(e.settings.pending_updates:filenames()) do waiting[f] = true end
            end)
            sites[#sites + 1] = s
        end
    end
    table.sort(sites, function(a, b) return a.label < b.label end)
    local n = 0
    for _f in pairs(waiting) do n = n + 1 end
    return { app = app, sites = sites, waiting = n, this_waiting = path and waiting[path] or false }
end

local function sendWaiting(ss)
    local left, sent = #ss.sites, 0
    for _i, s in ipairs(ss.sites) do
        local ok = pcall(function()
            s.engine:flushPendingUpdates(function(done)
                if done then sent = sent + 1 end
                left = left - 1
                if left == 0 then note(sent > 0 and _("ShelfSync: waiting updates sent.") or _("ShelfSync: nothing sent (no Wi-Fi, or nothing waiting).")) end
            end)
        end)
        if not ok then left = left - 1 end
    end
end

-- ShelfSync Tweaks' "ShelfSync: Link This Book" (its file-browser card), or nil
local function tweaksLink(path)
    local FM = fm()
    local rows = FM and FM.file_dialog_added_buttons
    if type(rows) ~= "table" then return nil end
    for _i, fn in ipairs(rows) do
        if type(fn) == "function" then
            local ok, got = pcall(fn, path, true, {})
            if ok and type(got) == "table" then
                for _j, row in ipairs(got) do
                    for _k, b in ipairs(type(row) == "table" and row or {}) do
                        if type(b) == "table" and b.text == "ShelfSync: Link This Book" and type(b.callback) == "function" then
                            return b.callback
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- ShelfSync's own Link, which needs the book open: pick the site, open the book, Link
local function linkInBook(ss, path)
    local list = {}
    for _i, s in ipairs(ss.sites) do
        list[#list + 1] = { text = s.label, note = s.linked and _("linked") or nil, colour = "blue", callback = function()
            O.openThen(path, function(ui)
                ui:handleEvent(require("ui/event"):new((SS_SITES[s.key] or s.label) .. "Link"))
            end)
        end }
    end
    O.Sheet.show{ title = _("Link this book to"), subtitle = _("The book opens, then ShelfSync's Link."),
        sections = { { colour = "blue", plain = true, items = { { kind = "list", list = list } } } } }
end

-- Bookshelf's Hardcover (its book picker), when Bookshelf has a Hardcover key
local function bookshelfHardcover(path)
    if type(path) ~= "string" then return nil end
    local ok, HC = pcall(require, "lib/bookshelf_hardcover")
    if not (ok and type(HC) == "table" and type(HC.isAvailable) == "function" and type(HC.showBookPicker) == "function") then return nil end
    local okA, avail = pcall(HC.isAvailable)
    if not (okA and avail) then return nil end
    local okL, label = pcall(HC.linkLabel, path)
    return { HC = HC, label = okL and label or nil }
end

local function bookOrbitPlugin()
    local inst = select(2, fm())
    local bo = type(inst) == "table" and inst.bookorbit
    if type(bo) ~= "table" or type(bo.onBookOrbitSyncNow) ~= "function" then return nil end
    local ok, on = pcall(function() return bo:isLoggedIn() end)
    return (ok and on) and bo or nil
end

-- ---- More ▾ -----------------------------------------------------------------------------

-- the Book Page's More: opts.legend (Help), opts.close (the Book Page, before opening the book)
function BM.more(rec, path, opts)
    opts = opts or {}
    local widget
    local function run(fn) return function() if widget then UIManager:close(widget) end fn() end end
    local function opening(fn) return run(function() if opts.close then pcall(opts.close) end fn() end) end
    local here = type(path) == "string" and O.lfs.attributes(path, "mode") == "file"
    local ss = here and shelfSync(path) or nil
    local bo_plugin = bookOrbitPlugin()
    local sections = {}

    -- Sync
    local sync = {}
    if ss and #ss.sites > 0 then
        local names = {}
        for _i, s in ipairs(ss.sites) do if s.linked then names[#names + 1] = s.label end end
        sync[#sync + 1] = { text = _("Sync This Book"), button = _("Sync"),
            sub = #names > 0 and T(_("Opens the book, then sends its progress to %1."), table.concat(names, ", "))
                or _("Not linked on ShelfSync yet: link it below first."),
            enabled = #names > 0, callback = #names > 0 and opening(function()
                O.openThen(path, function(ui) ui:handleEvent(require("ui/event"):new("ShelfSyncUpdateAllProgress")) end)
            end) or nil }
        sync[#sync + 1] = { text = _("Send Waiting Updates"), button = _("Send"),
            sub = ss.waiting > 0 and ((ss.waiting == 1 and _("1 book waiting") or T(_("%1 books waiting"), ss.waiting))
                .. (ss.this_waiting and _(" (this one too)") or "") .. " · ShelfSync") or _("Nothing waiting · ShelfSync"),
            enabled = ss.waiting > 0, callback = ss.waiting > 0 and run(function() sendWaiting(ss) end) or nil }
    end
    if bo_plugin then
        sync[#sync + 1] = { text = _("Sync With BookOrbit"), button = _("Sync"),
            sub = _("BookOrbit's library sync: your reading, progress and highlights, this book too."),
            callback = run(function() bo_plugin:onBookOrbitSyncNow() end) }
    end
    if #sync > 0 then sections[#sections + 1] = { title = _("Sync"), colour = "green", items = { { kind = "action", list = sync } } } end

    -- Link
    local link = {}
    if ss and #ss.sites > 0 then
        local bits = {}
        for _i, s in ipairs(ss.sites) do
            bits[#bits + 1] = s.label .. ": " .. (s.linked and (tostring(s.title or _("linked")) .. (s.format and s.format ~= "" and (" (" .. s.format .. ")") or ""))
                or _("not linked"))
        end
        local tw = tweaksLink(path)
        link[#link + 1] = { text = _("Link Book"), sub = table.concat(bits, "\n"), button = _("Link"),
            callback = tw and run(function() tw() end) or run(function() linkInBook(ss, path) end) }
    end
    local hc = here and bookshelfHardcover(path) or nil
    if hc then
        link[#link + 1] = { text = _("Hardcover · Bookshelf"), sub = hc.label or _("not linked"), button = hc.label and _("Change") or _("Link"),
            callback = run(function()
                local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
                local book = okR and type(Repo) == "table" and Repo.buildBookMeta and Repo.buildBookMeta(path) or { filepath = path, title = rec.title }
                pcall(hc.HC.showBookPicker, book, {})
            end) }
    end
    -- 2.1.17 (TK): no BookOrbit · Open row here (the page has its own BookOrbit ↗ button)
    if #link > 0 then sections[#sections + 1] = { title = _("Link"), colour = "blue", items = { { kind = "action", list = link } } } end

    -- This book
    if here then
        local n = BM.notes(path)
        local this = {
            { text = _("Highlights"), button = _("Show"), enabled = #n.hl > 0,
              sub = #n.hl == 0 and _("none yet") or ((#n.hl == 1 and _("1 highlight") or T(_("%1 highlights"), #n.hl))
                  .. (n.notes > 0 and (" · " .. (n.notes == 1 and _("1 note") or T(_("%1 notes"), n.notes))) or "")),
              callback = #n.hl > 0 and run(function() BM.showNotes("hl", rec, path) end) or nil },
            { text = _("Bookmarks"), button = _("Show"), enabled = #n.marks > 0,
              sub = #n.marks == 0 and _("none yet") or (#n.marks == 1 and _("1 bookmark") or T(_("%1 bookmarks"), #n.marks)),
              callback = #n.marks > 0 and run(function() BM.showNotes("marks", rec, path) end) or nil },
        }
        local xon = O.Stats and O.Stats.pluginOn and (O.Stats.pluginOn("xray") or O.Stats.pluginOn("koassistant"))
        if xon then
            -- 2.1.23 (TK): the X-Ray popup (what X-Ray fetched, up to your page, the book closed)
            local has = xrayCached(path)
            local xd, xex = nil, nil
            if O.Stats.xrayFor then xd, xex = O.Stats.xrayFor(rec, path) end
            local sum = O.XRay and xd and select(2, pcall(O.XRay.summary, xd, xex))
            if type(sum) ~= "table" then sum = nil end
            this[#this + 1] = { text = _("X-Ray"),
                sub = sum and T(_("%1 people, %2 places so far"), #sum.people, #sum.places)
                    or (has and _("fetched") or _("not fetched yet · opens the book, then X-Ray's menu")),
                button = (sum or has) and _("Show") or _("Fetch"),
                callback = (sum and O.XRay) and run(function() O.XRay.show(rec, path, xd, xex) end)
                    or opening(function() openXRay(path) end) }
        end
        sections[#sections + 1] = { title = _("This Book"), colour = "purple", items = { { kind = "action", list = this } } }
    end

    -- 2.1.15: the shelf's downloads (Manage Downloads), moved here from the top bar; 2.1.18
    -- (TK): with OrbitShelf's settings (the same menu as Tools › OrbitShelf, over this page)
    -- and Help as one row of buttons under it, so the sheet still fits the screen
    local last = {}
    if opts.downloads then
        local running = O.Bulk and O.Bulk.running and O.Bulk.running()
        last[#last + 1] = { kind = "action", list = {
            { text = _("Manage Downloads"), sub = running and _("Running now · this shelf, the queue, the space")
                or _("This shelf's books, the queue, the space"), button = _("Open"), callback = run(opts.downloads) } } }
    end
    local pills = {}
    if O.showSettingsMenu then
        pills[#pills + 1] = { text = _("Settings"), fill = true, callback = run(function() O.showSettingsMenu() end) }
    end
    if opts.legend then
        pills[#pills + 1] = { text = _("What's On This Page"), callback = run(function() opts.legend() end) }
    end
    if #pills > 0 then last[#last + 1] = { kind = "pills", list = pills } end
    if #last > 0 then
        local title = opts.downloads and _("Downloads And Settings") or _("Settings And Help")
        sections[#sections + 1] = { title = title, colour = "teal", items = last }
    end
    widget = O.Sheet.show{ title = tostring(rec.display_title or rec.title or _("This book")), sections = sections, cancel = false }
    -- 2.2.0 (TK: More didn't flash): its flash once the page under it has repainted too
    -- (Look › Screen Flashes › Popups; Quick Flash by default)
    local mode = O.flash and O.flash("popup") or "flashui"
    if mode ~= "ui" then
        UIManager:nextTick(function()
            if widget and widget.region then
                pcall(UIManager.setDirty, UIManager, widget, function() return mode, widget.region end)
            end
        end)
    end
    return widget
end

-- the stats page's chips: highlights, bookmarks, X-Ray, Glimpse
function BM.chip(id, rec, d, extra, close_all)
    local path = d and d.path
    if id == "highlights" then return BM.showNotes("hl", rec, path) end
    if id == "bookmarks" then return BM.showNotes("marks", rec, path) end
    if id == "xray" then
        if O.XRay and d then
            local ok = pcall(O.XRay.show, rec, path, d, extra)
            if ok then return end
        end
        return BM.showXRay(rec, path, extra and extra.xray)
    end
    if id == "glimpse" and type(path) == "string" then
        -- 2.1.26 (TK): the book's pictures from Glimpse, without opening it
        if O.Glimpse and O.Glimpse.show then
            local ok, shown = pcall(O.Glimpse.show, rec, path, d)
            if ok and shown then return end
            if not ok then O.logger.warn(O.TAG, "Glimpse popup:", tostring(shown)) end
        end
        if close_all then pcall(close_all) end
        return O.openThen(path, function() end)
    end
end

return BM
