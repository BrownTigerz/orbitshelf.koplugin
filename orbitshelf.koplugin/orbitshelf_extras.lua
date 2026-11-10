-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Reading Status and Next In Series (settings, both off by default).
local O = require("orbitshelf_core")
local T, TAG, UIManager, _, cfg, logger = O.T, O.TAG, O.UIManager, O._, O.cfg, O.logger

local Extras = {}
O.Extras = Extras

local function runConnected(fn)
    local okN, NetworkMgr = pcall(require, "ui/network/manager")
    if okN and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(fn)
    else
        fn()
    end
end

-- ---- Reading Status ------------------------------------------------------------------
-- BookOrbit's own statuses, set on the server (for books read somewhere else).

local STATUSES = {
    { "want_to_read", _("Want To Read") },
    { "reading", _("Reading") },
    { "on_hold", _("On Hold") },
    { "read", _("Read") },
    { "abandoned", _("Abandoned") },
    { "unread", _("Unread") },
}

local function statusLabel(id, fallback)
    local okU, CU = pcall(require, "bookorbit_catalog_util")
    local labels = okU and type(CU) == "table" and CU.READ_STATUS_LABELS
    local l = type(labels) == "table" and labels[id]
    return type(l) == "string" and l ~= "" and l or fallback
end

local function setStatus(id, status, label)
    local client = O.boApiClient()
    if not client or type(O.runWorker) ~= "function" then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("BookOrbit is not signed in") })
        return
    end
    runConnected(function()
        O.runWorker(client, function()
            local body, err = client:catalogSetReadStatus(id, status)
            return { ok = body ~= nil and body ~= false, err = err and tostring(err) or nil }
        end, function(res)
            if type(res) == "table" and res.ok then
                pcall(function()
                    local SM = require("bookorbit_state_manager")
                    if type(SM.invalidate) == "function" then SM.invalidate() end
                end)
                O.Genres.note(T(_("Marked %1"), label))
            else
                logger.warn(TAG, "reading status failed:", type(res) == "table" and res.err or "no answer")
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("Couldn't save the reading status. Check Wi-Fi and try again."),
                })
            end
        end, 30)
    end)
end

local function pickStatus(id, title)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local rows = {}
    for i, s in ipairs(STATUSES) do
        local label = statusLabel(s[1], s[2])
        rows[#rows + 1] = {{ text = label, callback = function()
            UIManager:close(dlg)
            setStatus(id, s[1], label)
        end }}
    end
    rows[#rows + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = T(_("Reading Status: %1"), tostring(title or "")), buttons = rows }
    UIManager:show(dlg)
end

-- the row for a hold menu (any BookOrbit book), or nil
function O.readStatusRow(book, close)
    if not cfg.read_status or type(book) ~= "table" or book.is_folder then return nil end
    local id = tonumber(book.bookorbit_id) or tonumber(O.bookIdForPath(book.filepath))
    if not id then return nil end
    return { text = _("Reading Status…"), callback = function()
        if close then close() end
        pickStatus(id, book.display_title or book.title)
    end }
end

-- ---- Next In Series ------------------------------------------------------------------
-- Reaching the end of a BookOrbit book remembers the next one in its series (from the
-- saved lists, no network) when it isn't on the device. Nothing pops up in the book:
-- back on the home screen, one question offers to download it.

local pending -- { rec, finished }
local dialog  -- the question, while it's up
local hookShow -- below

local function lower(s) return type(s) == "string" and s ~= "" and s:lower() or nil end

local function findRecord(id)
    for k, entry in pairs(O.page_cache) do
        for i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            if type(r) == "table" and tonumber(r.bookorbit_id) == id then return r end
        end
    end
    return nil
end

local function nextInSeries(series, index, skip_id)
    local best
    for k, entry in pairs(O.page_cache) do
        for i, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
            local n = type(r) == "table" and tonumber(r.series_index)
            if n and n > index and lower(r.series) == series and tonumber(r.bookorbit_id) ~= skip_id
                    and (not best or n < tonumber(best.series_index)) then
                best = r
            end
        end
    end
    return best
end

function Extras.endOfBook(ui)
    if not cfg.next_in_series then return end
    local file = ui and ui.document and ui.document.file
    local id = tonumber(O.bookIdForPath(file))
    if not id then return end
    local rec = findRecord(id)
    local props = ui.doc_props or {}
    local series = lower(rec and rec.series) or lower(props.series)
    local index = tonumber(rec and rec.series_index) or tonumber(props.series_index)
    if not (series and index) then return end
    local nxt = nextInSeries(series, index, id)
    if not nxt or O.liveBookPath(nxt.bookorbit_id) then return end
    pending = { rec = nxt, finished = (rec and rec.title) or props.display_title or props.title or "" }
    hookShow()
end

local function shown(w)
    if type(UIManager.isWidgetShown) == "function" then
        local ok, yes = pcall(UIManager.isWidgetShown, UIManager, w)
        if ok then return yes end
    end
    for i, item in ipairs(UIManager._window_stack or {}) do
        if item.widget == w then return true end
    end
    return false
end

-- back home (SimpleUI's home screen, Bookshelf, the library: whichever shows first)
-- or off the sleep screen there: ask once. Already asked and something full screen
-- opened over it: brought back on top.
function Extras.offerNext()
    if dialog and shown(dialog) then
        UIManager:close(dialog)
        UIManager:show(dialog)
        return
    end
    dialog = nil
    if not pending or not cfg.next_in_series then return end
    if require("device").screen_saver_mode then return end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if type(ReaderUI) == "table" and ReaderUI.instance then return end
    local p = pending
    pending = nil
    if O.liveBookPath(p.rec.bookorbit_id) then return end
    local n = tonumber(p.rec.series_index)
    local head = p.finished ~= "" and T(_("You finished %1."), tostring(p.finished)) or _("You finished the book.")
    dialog = require("ui/widget/confirmbox"):new{
        text = head .. "\n\n" .. T(_("Next in %1: #%2 %3 (not on this device).\n\nDownload it?"),
            tostring(p.rec.series or ""), n and tostring(n) or "?", tostring(p.rec.title or "")),
        ok_text = _("Download"),
        cancel_text = _("Not Now"),
        ok_callback = function()
            dialog = nil
            O.downloadBookOrbitBook(p.rec)
        end,
        cancel_callback = function() dialog = nil end,
    }
    UIManager:show(dialog)
end

function Extras.hasPending()
    return pending ~= nil or dialog ~= nil
end

-- Something full screen opening (Bookshelf, SimpleUI's home, the library) while one
-- is waiting or up: offer it / bring it back on top, a tick later. Hooked the first
-- time a book ends with one to offer; the check is one table lookup otherwise.
local show_hooked = false
hookShow = function()
    if show_hooked then return end
    show_hooked = true
    local orig = UIManager.show
    UIManager.show = function(self, w, ...)
        local r = orig(self, w, ...)
        if (pending or dialog) and type(w) == "table" and w ~= dialog and w.covers_fullscreen then
            UIManager:nextTick(function() pcall(Extras.offerNext) end)
        end
        return r
    end
end

return Extras
