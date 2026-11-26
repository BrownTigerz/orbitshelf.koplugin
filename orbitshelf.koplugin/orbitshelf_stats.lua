-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Reading Stats (2.1.0; Reading Sky 2.1.1-2.1.2; 2.1.8 redesign + book-close cache): one
-- book's reading on this Kobo, from KOReader's own statistics
-- (koreader/settings/statistics.sqlite3, opened read-only).
--
-- Two views, both reached from the Book Page (Books > Book Page: Reading Stats):
--   * the Description box's other side (Stats › or a swipe): TIME / DAYS / LEFT, each
--     with a small chart, as much as fits the box
--   * the stats page (tap it): the same block, the trail (where you are in the book,
--     how hard each stretch went in minutes a page, a numbered dot where each day
--     ended, the critter where you are now and the days ahead to the summit) and
--     When you read (one strip per reading day across the sun's day)
--
-- 2.1.8: the numbers that don't change with the clock are kept per book in
-- cache/bookorbit/orbitshelf_stats.lua, saved when a book closes (only while Reading
-- Stats is on). The Book Page uses them straight away and reads statistics.sqlite3
-- again only when it changed for that book. Clean Up Cache clears the file.
--
-- Times follow KOReader's own rule (each page's time capped at the Statistics
-- plugin's max, 120 s by default), so they match its Book statistics.
local O = require("orbitshelf_core")
local T, _, UIManager = O.T, O._, O.UIManager

local Stats = {}
O.Stats = Stats

local mem = {}    -- book id -> data (false: no stats), while the Book Page is open
local shown       -- the stats page while it's up
local on_closed   -- the Book Page's "redraw if something changed" callback

local FACTS_V = 3 -- the saved record's layout; another number = worked out again (2.1.11: 2; 2.1.20: 3, every copy of the book)
local STORE_MAX = 60

local function W(name) return require("ui/widget/" .. name) end

-- ---- Words for numbers -------------------------------------------------------------

local function dur(secs)
    secs = math.floor((tonumber(secs) or 0) + 0.5)
    if secs < 60 then return _("under 1 m") end
    local m = math.floor(secs / 60 + 0.5)
    if m < 60 then return T(_("%1 m"), m) end
    local h, r = math.floor(m / 60), m % 60
    if r == 0 or h >= 10 then return T(_("%1 h"), h + (r >= 30 and h >= 10 and 1 or 0)) end
    return T(_("%1 h %2 m"), h, r)
end

-- short: "3h 50m"
local function durS(secs)
    local m = math.floor((tonumber(secs) or 0) / 60 + 0.5)
    if m < 60 then return T(_("%1m"), m) end
    local h, r = math.floor(m / 60), m % 60
    if r == 0 or h >= 10 then return T(_("%1h"), h + ((h >= 10 and r >= 30) and 1 or 0)) end
    return T(_("%1h %2m"), h, r)
end

local function day(t)
    t = tonumber(t)
    if not t then return "" end
    return os.date("%b ", t) .. tonumber(os.date("%d", t)) .. (os.date("%Y", t) ~= os.date("%Y") and os.date(", %Y", t) or "")
end

local function hour12(h)
    h = h % 24
    if h == 0 then return _("12 AM") end
    if h == 12 then return _("noon") end
    return h < 12 and T(_("%1 AM"), h) or T(_("%1 PM"), h - 12)
end

local function dayKey(t) return os.date("%Y-%m-%d", t) end

local function midnight(t)
    local d = os.date("*t", t)
    return os.time{ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 }
end

-- whole days from a to b (both midnights; +1 h for daylight saving)
local function daysBetween(a, b) return math.floor((b - a + 3600) / 86400) end

local function mpp(v) return string.format("%.1f", v) end

-- 2.1.10: amounts in the book's unit: pages (This Kobo) or percent (BookOrbit)
local function pct1(v) return (v < 10 and v ~= math.floor(v)) and string.format("%.1f", v) or tostring(math.floor(v + 0.5)) end
local function amount(d, v)
    if d.unit == "pct" then return pct1(v) .. "%" end
    if d.unit == "min" then return durS(v * 60) end -- 2.1.28: All Time from BookOrbit (minutes a day)
    v = math.floor(v + 0.5)
    return v == 1 and _("1 page") or T(_("%1 pages"), v)
end
local function paceWords(d)
    if d.unit == "pct" then return T(_("%1% an hour"), pct1(d.pph)) end
    return T(_("%1 pages an hour"), math.floor(d.pph + 0.5))
end

Stats.dur, Stats.day = dur, day

-- ---- KOReader's statistics -----------------------------------------------------------

local function statSettings()
    local s = G_reader_settings and G_reader_settings:readSetting("statistics")
    s = type(s) == "table" and s or {}
    return math.max(1, tonumber(s.max_sec) or 120)
end

local function dbPath()
    return require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
end

local function openDb()
    local path = dbPath()
    if O.lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local okc, conn = pcall(SQ3.open, path, "ro")
    if not okc or not conn then return nil end
    pcall(conn.set_busy_timeout, conn, 1000)
    return conn
end

-- column-major rows, or nil
local function query(conn, sql, params)
    local stmt = conn:prepare(sql)
    if params and #params > 0 then stmt:bind(unpack(params)) end
    local res = stmt:resultset("i")
    stmt:close()
    return res
end

local function n(v) return tonumber(v) or 0 end

local function fileMd5(path)
    local md5
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return end
        md5 = DocSettings:open(path):readSetting("partial_md5_checksum")
    end)
    if type(md5) ~= "string" or md5 == "" then
        local ok, m = pcall(function() return require("util").partialMD5(path) end)
        md5 = ok and m or nil
    end
    return type(md5) == "string" and md5 ~= "" and md5 or nil
end

-- the statistics' rows for this book: by the file's fingerprint when it's on the
-- device, and (2.1.20) by title and the author's last name too, so a removed book keeps
-- its stats and a book downloaded again (a new file, so a new fingerprint and a new
-- row in KOReader's statistics: TK's Mountains Echoed had 4) counts all its copies
local function bookRows(conn, rec, md5)
    local res = { {}, {}, {} }
    local seen = {}
    local function add(id, h, nn)
        id = tonumber(id)
        if not id or seen[id] then return end
        seen[id] = true
        res[1][#res[1] + 1], res[2][#res[2] + 1], res[3][#res[3] + 1] = id, h, nn
    end
    local title, who = rec.title or rec.display_title, nil
    if md5 then
        local got = query(conn, "SELECT id, highlights, notes, title, authors FROM book WHERE md5 = ?;", { md5 })
        if got then
            for i = 1, #got[1] do add(got[1][i], got[2][i], got[3][i]) end
            -- at book close there's only the file: its title and author from the statistics
            if type(title) ~= "string" or title == "" then title, who = got[4] and got[4][1], got[5] and got[5][1] end
        end
    end
    if type(title) == "string" and title ~= "" then
        local got = query(conn, "SELECT id, highlights, notes, authors FROM book WHERE lower(title) = lower(?);", { title })
        if got then
            who = who or rec.author
            if (type(who) ~= "string" or who == "") and type(rec.authors) == "table" then who = rec.authors[1] end
            -- KOReader keeps several authors on separate lines: the first
            if type(who) == "string" then who = who:match("^[^\n]*") end
            local last = type(who) == "string" and who:match("(%S+)%s*$")
            last = last and last:lower()
            for i = 1, #got[1] do
                local a = type(got[4][i]) == "string" and got[4][i]:lower() or ""
                -- an older copy's highlights are its own file's: only the one on the device counts them
                if not last or a == "" or a:find(last, 1, true) then add(got[1][i], #res[1] == 0 and got[2][i] or 0, #res[1] == 0 and got[3][i] or 0) end
            end
        end
    end
    if #res[1] == 0 then return nil end
    return res
end

-- ---- Working it out ------------------------------------------------------------------

-- The facts: everything that doesn't change with the clock, so it can be saved at
-- book close. ev: list of { t, d, page, total } oldest first.
function Stats.gather(ev, max_sec)
    if #ev == 0 then return nil end
    max_sec = max_sec or 120
    -- the book's page count now (the newest event's), pages scaled to it
    local total = 0
    for i = #ev, 1, -1 do if ev[i][4] > 0 then total = ev[i][4] break end end
    if total <= 0 then return nil end
    local function norm(e)
        local tp = e[4] > 0 and e[4] or total
        return math.max(1, math.min(total, math.floor(e[3] * total / tp + 0.5)))
    end
    -- 2.1.11: your reads of this book. A new read starts when, after reaching 90%,
    -- you go well back in the book after a week or more away; everything else here
    -- is about the newest read.
    local reads, cur, last_t = {}, nil, nil
    for _i, e in ipairs(ev) do
        local p = norm(e)
        if not cur or (cur.hi >= 0.9 * total and p < cur.hi - 0.3 * total and e[1] - last_t > 7 * 86400) then
            cur = { start = e[1], last = e[1], hi = 0, secs = 0 }
            reads[#reads + 1] = cur
        end
        cur.last, cur.secs = e[1] + e[2], cur.secs + math.min(e[2], max_sec)
        last_t = e[1] + e[2]
        if p > cur.hi then cur.hi = p end
        if not cur.done_t and p >= 0.97 * total then cur.done_t = e[1] end
    end
    for _i, r in ipairs(reads) do r.hi = r.hi / total end
    if #reads > 1 then
        local from_t, kept = reads[#reads].start, {}
        for _i, e in ipairs(ev) do if e[1] >= from_t then kept[#kept + 1] = e end end
        ev = kept
    end
    -- time per page, capped like KOReader's
    local page_secs, raw = {}, {}
    for _i, e in ipairs(ev) do
        local p = norm(e)
        raw[p] = (raw[p] or 0) + e[2]
    end
    local secs, pages = 0, 0
    for p, s in pairs(raw) do
        local c = math.min(s, max_sec)
        page_secs[p] = c
        secs, pages = secs + c, pages + 1
    end
    if secs < 60 or pages == 0 then return nil end
    -- a page's capped time is shared out over its events (for days, hours and sittings)
    local function weight(e, p) return raw[p] > 0 and e[2] * page_secs[p] / raw[p] or 0 end

    local f = { v = FACTS_V, total = total, secs = secs, pages = pages, first = ev[1][1], last = ev[#ev][1],
        days = {}, sessions = {}, hours = {}, reads = reads, page_secs = {} }
    -- each page's time, whole seconds (the page-turner, chapters)
    for p, s in pairs(page_secs) do f.page_secs[p] = math.floor(s + 0.5) end
    -- 2.1.11: pages you came back to: how many sittings touched each page
    do
        local touched, sess_i, lt = {}, 0, nil
        for _i, e in ipairs(ev) do
            if not lt or e[1] - lt > 600 then sess_i = sess_i + 1 end
            lt = e[1] + e[2]
            local p = norm(e)
            touched[p] = touched[p] or {}
            touched[p][sess_i] = true
        end
        local list = {}
        for p, s in pairs(touched) do
            local c = 0
            for _k in pairs(s) do c = c + 1 end
            if c >= 2 then list[#list + 1] = { p = p, visits = c, secs = page_secs[p] or 0 } end
        end
        table.sort(list, function(a, b) return a.visits > b.visits or (a.visits == b.visits and a.secs > b.secs) end)
        f.returned = {}
        for i = 1, math.min(8, #list) do f.returned[i] = list[i] end
    end
    for h = 1, 24 do f.hours[h] = 0 end
    -- the furthest page reached by reading: a page counts once 5 of the 7 pages up to
    -- it were read (a run), so a jump that only looks at a page or two (a link to the
    -- end, an X-Ray entry) doesn't move it; starting mid-book works too
    local reached, frontier = {}, 0
    local function inRun(p)
        local c = 0
        for q = math.max(1, p - 6), p do if reached[q] then c = c + 1 end end
        return c >= math.min(5, p)
    end
    local by_key, day_pages = {}, {}
    local sess, sess_pages
    for _i, e in ipairs(ev) do
        local p = norm(e)
        local w = weight(e, p)
        local k = dayKey(e[1])
        local dd = by_key[k]
        if not dd then
            dd = { t = midnight(e[1]), secs = 0, pages = 0, reached = 0 }
            by_key[k] = dd
            day_pages[k] = {}
            f.days[#f.days + 1] = dd
        end
        dd.secs = dd.secs + w
        if not day_pages[k][p] then day_pages[k][p] = true dd.pages = dd.pages + 1 end
        local h = tonumber(os.date("%H", e[1])) or 0
        f.hours[h + 1] = f.hours[h + 1] + w
        reached[p] = true
        if p > frontier and inRun(p) then frontier = p end
        dd.reached = frontier / total
        -- a new sitting after 10 minutes without a page turn
        if not sess or e[1] - sess.stop > 600 then
            sess = { start = e[1], stop = e[1] + e[2], secs = 0, pages = 0, pos = frontier / total }
            sess_pages = {}
            f.sessions[#f.sessions + 1] = sess
        end
        sess.stop = math.max(sess.stop, e[1] + e[2])
        sess.secs = sess.secs + w
        if not sess_pages[p] then sess_pages[p] = true sess.pages = sess.pages + 1 end
        sess.pos = frontier / total
    end
    -- sittings under a minute are page flicks, not reading
    local kept = {}
    for _i, s in ipairs(f.sessions) do if s.secs >= 60 then kept[#kept + 1] = s end end
    f.sessions = kept
    f.reached = frontier / total

    -- the trail: minutes a page through the part read here, in stretches of about 2%
    -- of the book (6 pages at least), lightly smoothed. A stretch with under 3 pages
    -- read is a gap (drawn straight across).
    local list = {}
    for p in pairs(page_secs) do list[#list + 1] = p end
    table.sort(list)
    local lo = list[math.max(1, math.ceil(#list * 0.02))]
    local hi = math.max(frontier, lo)
    if hi <= lo then hi = list[#list] end
    local span = hi - lo + 1
    local nb = math.max(1, math.min(30, math.ceil(span / math.max(6, math.ceil(total * 0.02)))))
    local bs, bp = {}, {}
    for i = 1, nb do bs[i], bp[i] = 0, 0 end
    for _i, p in ipairs(list) do
        if p >= lo and p <= hi then
            local i = math.min(nb, math.floor((p - lo) * nb / span) + 1)
            bs[i], bp[i] = bs[i] + page_secs[p], bp[i] + 1
        end
    end
    local val = {}
    for i = 1, nb do val[i] = bp[i] >= 3 and bs[i] / bp[i] / 60 or false end
    local trail = {}
    for i = 1, nb do
        if val[i] then
            local s, wsum = val[i] * 2, 2
            if i > 1 and val[i - 1] then s, wsum = s + val[i - 1], wsum + 1 end
            if i < nb and val[i + 1] then s, wsum = s + val[i + 1], wsum + 1 end
            trail[i] = s / wsum
        else
            trail[i] = false
        end
    end
    f.trail = { lo = (lo - 1) / total, hi = hi / total, b = trail }
    return f
end

-- ---- BookOrbit's side (2.1.10) -------------------------------------------------------
-- BookOrbit's sessions for this book (every device and listening): start, end, length,
-- where it ended (0-100) and how far it moved. No pages, so the book counts in percent:
-- "total" is 100 and a "page" is 1%.

-- "2026-11-19T21:30:00.000Z" (or +hh:mm) to a time
local function isoTime(s)
    if type(s) ~= "string" then return nil end
    local y, mo, d, h, mi, se, rest = s:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)(.*)$")
    if not y then return nil end
    local t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
        min = tonumber(mi), sec = tonumber(se), isdst = false }
    -- the fields are UTC (or the given offset): move them by this device's own offset then
    local here = os.time(os.date("*t", t)) - os.time(os.date("!*t", t))
    local zone = 0
    local sign, zh, zm = rest:match("([%+%-])(%d%d):?(%d%d)$")
    if sign then zone = (sign == "-" and -1 or 1) * (tonumber(zh) * 3600 + tonumber(zm) * 60) end
    return t + here - zone
end

function Stats.boFacts(items)
    if type(items) ~= "table" then return nil end
    local list = {}
    for _i, it in ipairs(items) do
        if type(it) == "table" then
            local s0, s1 = isoTime(it.startedAt), isoTime(it.endedAt)
            local secs = tonumber(it.durationSeconds) or ((s0 and s1) and s1 - s0) or 0
            if s0 and secs >= 60 then
                local dev = type(it.device) == "table" and (it.device.name or it.device.model) or nil
                local SRC = { ios = _("iPhone"), android = _("Android"), web = _("web reader"), watchos = _("Apple Watch"),
                    koreader = _("KOReader"), kobo = _("Kobo"), manual = _("added by hand") }
                if type(dev) ~= "string" and type(it.source) == "string" then dev = SRC[it.source] or it.source end
                list[#list + 1] = { start = s0, stop = s1 or (s0 + secs), secs = secs, endp = tonumber(it.endProgress),
                    delta = tonumber(it.progressDelta), kind = it.sessionType or "read",
                    source = type(dev) == "string" and dev or nil }
            end
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.start < b.start end)
    local f = { v = FACTS_V, unit = "pct", total = 100, secs = 0, pages = 0, first = list[1].start,
        last = list[#list].stop, days = {}, sessions = {}, hours = {}, sources = {} }
    for h = 1, 24 do f.hours[h] = 0 end
    local by_key, reached, seen_src, lo = {}, 0, {}, nil
    for _i, s in ipairs(list) do
        local delta = math.max(0, s.delta or 0)
        if s.endp and s.endp > reached then reached = s.endp end
        if s.endp then lo = math.min(lo or 100, s.endp - delta) end
        f.secs, f.pages = f.secs + s.secs, f.pages + delta
        local k = dayKey(s.start)
        local dd = by_key[k]
        if not dd then
            dd = { t = midnight(s.start), secs = 0, pages = 0, reached = 0 }
            by_key[k] = dd
            f.days[#f.days + 1] = dd
        end
        dd.secs, dd.pages, dd.reached = dd.secs + s.secs, dd.pages + delta, reached / 100
        local hr = tonumber(os.date("%H", s.start)) or 0
        f.hours[hr + 1] = f.hours[hr + 1] + s.secs
        f.sessions[#f.sessions + 1] = { start = s.start, stop = s.stop, secs = s.secs, pages = delta,
            pos = reached / 100, kind = s.kind, source = s.source }
        if s.source and not seen_src[s.source] then seen_src[s.source] = true f.sources[#f.sources + 1] = s.source end
    end
    f.pages = math.max(1, f.pages)
    f.reached = reached / 100
    -- the trail: minutes per 1% in stretches of 2%, each sitting's time spread over
    -- the part it moved through
    lo = math.max(0, math.min(lo or 0, reached))
    local span = math.max(1, reached - lo)
    local nb = math.max(1, math.min(30, math.ceil(span / 2)))
    local bs, bc = {}, {}
    for i = 1, nb do bs[i], bc[i] = 0, 0 end
    for _i, s in ipairs(list) do
        local delta = math.max(0, s.delta or 0)
        if s.endp and delta >= 0.2 then
            local a, b = s.endp - delta, s.endp
            for i = 1, nb do
                local x0, x1 = lo + (i - 1) * span / nb, lo + i * span / nb
                local ov = math.min(b, x1) - math.max(a, x0)
                if ov > 0 then bs[i], bc[i] = bs[i] + s.secs * ov / delta, bc[i] + ov end
            end
        end
    end
    local val = {}
    for i = 1, nb do val[i] = bc[i] >= 0.5 and bs[i] / 60 / bc[i] or false end
    local trail = {}
    for i = 1, nb do
        if val[i] then
            local s, wsum = val[i] * 2, 2
            if i > 1 and val[i - 1] then s, wsum = s + val[i - 1], wsum + 1 end
            if i < nb and val[i + 1] then s, wsum = s + val[i + 1], wsum + 1 end
            trail[i] = s / wsum
        else
            trail[i] = false
        end
    end
    f.trail = { lo = lo / 100, hi = reached / 100, b = trail }
    return f
end

-- what the facts say today. opts: now, pct (KOReader's own place in the book, 0-1),
-- finished, finished_t
function Stats.derive(f, opts)
    opts = opts or {}
    local now = opts.now or os.time()
    local today = midnight(now)
    local d = { total = f.total, secs = f.secs, pages = f.pages, first = f.first, last = f.last,
        day_list = f.days, sessions = f.sessions, hours = f.hours, trail = f.trail, now = now,
        highlights = f.highlights or 0, notes = f.notes or 0, usual_pph = f.usual_pph,
        rank_faster = f.rank_faster, rank_n = f.rank_n, unit = f.unit, sources = f.sources, fetched = f.fetched,
        reads = f.reads, page_secs = f.page_secs, returned = f.returned, longer_than = f.longer_than, others_n = f.others_n }
    d.days = {}
    for _i, dd in ipairs(f.days) do d.days[dayKey(dd.t)] = dd end
    -- 2.1.9: today with this book, and when you last read it
    d.today = d.days[dayKey(today + 3600)]
    d.last_read_days = daysBetween(midnight(f.last), today)
    local longest
    for _i, s in ipairs(f.sessions) do if not longest or s.secs > longest.secs then longest = s end end
    d.longest = longest
    d.days_read = #f.days
    d.spp = f.secs / f.pages
    d.pph = 3600 / d.spp
    d.pct = tonumber(opts.pct) or f.reached or 0
    if d.pct > 1 then d.pct = 1 end
    d.finished = opts.finished or d.pct >= 0.995
    d.page_now = math.max(1, math.floor(d.pct * f.total + 0.5))
    local last_day = midnight(d.finished and (opts.finished_t or f.last) or now)
    d.days_since = math.max(1, #f.days, daysBetween(midnight(f.first), last_day) + 1)
    -- the last two weeks (or since you started, if sooner): your pace and how much a day
    local window = math.min(14, daysBetween(midnight(f.first), today) + 1)
    local from = today - (window - 1) * 86400
    local recent_secs, recent_pages, daily = 0, 0, {}
    for i = 0, window - 1 do daily[i + 1] = 0 end
    for _i, dd in ipairs(f.days) do
        if dd.t >= from - 3600 then
            recent_secs, recent_pages = recent_secs + dd.secs, recent_pages + dd.pages
            local i = daysBetween(from, dd.t) + 1
            if daily[i] then daily[i] = daily[i] + dd.secs end
        end
    end
    local spp = (recent_pages >= (f.unit == "pct" and 3 or 15) and recent_secs > 0) and recent_secs / recent_pages or d.spp
    d.spp_now = spp
    if not d.finished then
        d.pages_left = math.max(0, f.total - d.page_now)
        d.left_secs = d.pages_left * spp
        if recent_secs >= 300 then
            local per_day = recent_secs / window
            d.per_day = per_day
            d.days_left = math.max(1, math.ceil(d.left_secs / per_day))
            d.finish_t = today + d.days_left * 86400
            -- a range from your quicker and slower days (at least 4 days to go on)
            if window >= 4 then
                table.sort(daily, function(a, b) return a > b end)
                local half = math.floor(window / 2)
                local fast, slow = 0, 0
                for i = 1, half do fast = fast + daily[i] end
                for i = window - half + 1, window do slow = slow + daily[i] end
                fast, slow = fast / half, slow / half
                if fast > 0 then d.finish_lo = today + math.max(1, math.ceil(d.left_secs / fast)) * 86400 end
                -- 2.1.20 (TK saw Nov 29 – Sep 2 with 111 pages left): a few 1-page days made the
                -- slow end months away; it now stops at twice the estimate
                if slow > 0 then
                    d.finish_hi = today + math.min(2 * d.days_left, math.max(1, math.ceil(d.left_secs / slow))) * 86400
                end
                if d.finish_lo and d.finish_hi and d.finish_hi - d.finish_lo < 86400 then d.finish_lo, d.finish_hi = nil, nil end
            end
            -- the days ahead along the trail
            local step = per_day / spp / f.total
            d.ahead = {}
            for k = 1, d.days_left do
                d.ahead[k] = { pct = math.min(1, d.pct + k * step), t = today + k * 86400 }
            end
            d.ahead[#d.ahead].pct = 1
        end
    else
        d.finish_t = opts.finished_t or f.last
        d.took_days = daysBetween(midnight(f.first), midnight(d.finish_t)) + 1
    end
    -- when you read it (the biggest share: morning 5-11, afternoon 12-16, evening 17-20, night 21-4)
    local parts = {
        { "morning", { 5, 6, 7, 8, 9, 10, 11 } }, { "afternoon", { 12, 13, 14, 15, 16 } },
        { "evening", { 17, 18, 19, 20 } }, { "night", { 21, 22, 23, 0, 1, 2, 3, 4 } },
    }
    local best, best_s, peak = nil, -1, nil
    for _i, part in ipairs(parts) do
        local s, top = 0, nil
        for _j, h in ipairs(part[2]) do
            s = s + f.hours[h + 1]
            if not top or f.hours[h + 1] > f.hours[top + 1] then top = h end
        end
        if s > best_s then best, best_s, peak = part[1], s, top end
    end
    d.when, d.when_share, d.peak = best, best_s / f.secs, peak
    -- the longest break between two sittings (12 hours or more)
    for i = 1, #f.sessions - 1 do
        local gap = f.sessions[i + 1].start - f.sessions[i].stop
        if gap >= 12 * 3600 and (not d.brk or gap > d.brk.secs) then d.brk = { secs = gap, pos = f.sessions[i].pos } end
    end
    -- the hardest and easiest stretches of the trail
    local tr = f.trail
    if tr and #tr.b >= 3 then
        local hard, easy
        for i, v in ipairs(tr.b) do
            if v then
                if not hard or v > tr.b[hard] then hard = i end
                if not easy or v < tr.b[easy] then easy = i end
            end
        end
        if hard and easy and tr.b[hard] - tr.b[easy] >= 0.05 then d.hard, d.easy = hard, easy end
    end
    -- this week in one line (step 12): only with a few days to go on
    if d.days_read >= 2 and not d.finished then
        local wk_from = today - 6 * 86400
        local count, top = 0, nil
        for _i, dd in ipairs(f.days) do
            if dd.t >= wk_from - 3600 then
                count = count + 1
                if not top or dd.secs > top.secs then top = dd end
            end
        end
        local span = math.min(7, daysBetween(midnight(f.first), today) + 1)
        if count >= 2 then
            local a = count >= span and (span == 7 and _("Read every day this week.") or _("Read every day so far."))
                or T(_("Read %1 of the last %2 days."), count, span)
            d.summary = a .. " " .. T(_("%1 did the most (%2)."), os.date("%A", top.t), durS(top.secs))
        elseif count == 0 then
            d.summary = T(_("Last read %1."), day(f.last))
        end
    end
    return d
end

-- the facts for one book, from the database
local function gatherFromDb(conn, rec, md5)
    local books = bookRows(conn, rec, md5)
    if not books then return nil end
    local ids, marks, hl, notes = {}, {}, 0, 0
    for i = 1, #books[1] do
        ids[#ids + 1] = tonumber(books[1][i])
        marks[#marks + 1] = "?"
        hl, notes = hl + n(books[2][i]), notes + n(books[3][i])
    end
    local mk = table.concat(marks, ",")
    local res = query(conn, "SELECT start_time, duration, page, total_pages FROM page_stat_data WHERE id_book IN ("
        .. mk .. ") ORDER BY start_time;", ids)
    if not res then return nil end
    local ev = {}
    for i = 1, #res[1] do ev[i] = { n(res[1][i]), n(res[2][i]), n(res[3][i]), n(res[4][i]) } end
    local f = Stats.gather(ev, statSettings())
    if not f then return nil end
    f.highlights, f.notes, f.ids = hl, notes, ids
    f.last_row = ev[#ev][1]
    -- your usual pace (KOReader's own totals for your other books), and how this book
    -- compares with your last ten
    local u = query(conn, "SELECT total_read_time, total_read_pages FROM book WHERE total_read_pages >= 20 AND id NOT IN ("
        .. mk .. ") ORDER BY last_open DESC;", ids)
    if u then
        local ut, up, faster, count = 0, 0, 0, 0
        local pph = f.pages * 3600 / f.secs
        for i = 1, #u[1] do
            local bt, bp = n(u[1][i]), n(u[2][i])
            if bt > 0 then
                ut, up = ut + bt, up + bp
                if count < 10 then
                    count = count + 1
                    if pph > bp * 3600 / bt then faster = faster + 1 end
                end
            end
        end
        if ut > 0 and up > 0 then f.usual_pph = up * 3600 / ut end
        if count >= 3 then f.rank_faster, f.rank_n = faster, count end
    end
    -- 2.1.11: longer than how many of your last ten other books
    local lp = query(conn, "SELECT pages FROM book WHERE pages > 0 AND id NOT IN (" .. mk .. ") ORDER BY last_open DESC LIMIT 10;", ids)
    if lp and #lp[1] >= 3 then
        local c = 0
        for i = 1, #lp[1] do if f.total > n(lp[1][i]) then c = c + 1 end end
        f.longer_than, f.others_n = c, #lp[1]
    end
    return f
end

-- ---- The saved facts (book-close cache) -----------------------------------------------

local store -- LuaSettings, opened on first use (false: can't)

function Stats.storeFile()
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = ok and DataStorage:getDataDir() or "."
    return dir .. "/cache/bookorbit/orbitshelf_stats.lua"
end

local function openStore()
    if store == nil then
        local okL, LuaSettings = pcall(require, "luasettings")
        local okO, st = false, nil
        if okL then
            pcall(function()
                local dir = Stats.storeFile():match("^(.*)/[^/]*$")
                if dir and O.lfs.attributes(dir, "mode") ~= "directory" then
                    local parent = dir:match("^(.*)/[^/]*$")
                    if parent and O.lfs.attributes(parent, "mode") ~= "directory" then O.lfs.mkdir(parent) end
                    O.lfs.mkdir(dir)
                end
            end)
            okO, st = pcall(LuaSettings.open, LuaSettings, Stats.storeFile())
        end
        store = okO and st or false
    end
    return store or nil
end

local function dbMtime() return O.lfs.attributes(dbPath(), "modification") end

local function saveFacts(key, f, mtime)
    local st = openStore()
    if not st or not key then return end
    f.saved, f.db_mtime = os.time(), mtime
    st:saveSetting(key, f)
    -- kept small: the oldest go past STORE_MAX books
    local all, count = st.data or {}, 0
    for _k in pairs(all) do count = count + 1 end
    if count > STORE_MAX then
        local keys = {}
        for k, v in pairs(all) do keys[#keys + 1] = { k, type(v) == "table" and tonumber(v.saved) or 0 } end
        table.sort(keys, function(a, b) return a[2] < b[2] end)
        for i = 1, count - STORE_MAX do st:delSetting(keys[i][1]) end
    end
    st:flush()
end

-- the facts for a book: the saved ones while statistics.sqlite3 hasn't changed for it,
-- else from the database (and saved). force: always from the database.
local function factsFor(rec, md5, key, force)
    local st = openStore()
    local saved = (not force and st and key) and st:readSetting(key) or nil
    if type(saved) ~= "table" or saved.v ~= FACTS_V then saved = nil end
    local mtime = dbMtime()
    if saved and mtime and saved.db_mtime == mtime then return saved, "saved" end
    local conn = openDb()
    if not conn then return saved, "saved (no database)" end
    local f, how
    local ok, err = pcall(function()
        -- the database changed, maybe not for this book: one small look before the whole read
        if saved and type(saved.ids) == "table" and #saved.ids > 0 then
            local marks = {}
            for i = 1, #saved.ids do marks[i] = "?" end
            local r = query(conn, "SELECT max(start_time) FROM page_stat_data WHERE id_book IN ("
                .. table.concat(marks, ",") .. ");", saved.ids)
            if r and n(r[1][1]) == n(saved.last_row) then f, how = saved, "saved (checked)" return end
        end
        f, how = gatherFromDb(conn, rec, md5), "database"
    end)
    pcall(conn.close, conn)
    if not ok then O.logger.warn(O.TAG, "Reading Stats:", tostring(err)) return nil end
    if f then pcall(saveFacts, key, f, mtime) end
    return f, how
end

local function keyFor(rec, md5)
    if md5 then return "md5:" .. md5 end
    local id = tonumber(rec and rec.bookorbit_id)
    return id and ("bo:" .. id) or nil
end

-- everything for one book, or nil (no statistics for it on this Kobo)
function Stats.forBook(rec, path, pct, finished, finished_t)
    local id = tonumber(rec and rec.bookorbit_id) or (rec and rec.title) or "?"
    if mem[id] ~= nil then return mem[id] or nil end
    local md5 = path and fileMd5(path)
    local f, how = factsFor(rec or {}, md5, keyFor(rec, md5))
    local d = f and Stats.derive(f, { pct = pct, finished = finished, finished_t = finished_t }) or nil
    if d then
        local okE, ex = pcall(Stats.extras, d, path)
        d.extras = okE and ex or {}
        d.md5, d.path = md5, path
        d.title = rec and (rec.title or rec.display_title) or nil -- 2.1.23: X-Ray / ReadMastery notes are kept by title
    end
    if O.cfg and O.cfg.diagnostics then O.logger.info(O.TAG, "Reading Stats for", tostring(id), "from", tostring(how)) end
    mem[id] = d or false
    return d
end

-- a book closed (reader's CloseDocument, a tick later so KOReader's statistics are
-- written first): its facts worked out and saved for the Book Page
function Stats.saveOnClose(path, toc, toc_total)
    if not (O.cfg and O.cfg.bookpage_stats) or type(path) ~= "string" then return end
    local md5 = fileMd5(path)
    if not md5 then return end
    -- 2.1.11: the book's chapters (top level), with the page count they were taken at
    if type(toc) == "table" and #toc > 0 and tonumber(toc_total) then
        local st = openStore()
        if st then st:saveSetting("toc:" .. md5, { total = tonumber(toc_total), list = toc, saved = os.time() }) st:flush() end
    end
    local f, how = factsFor({}, md5, keyFor(nil, md5))
    if O.cfg.diagnostics then O.logger.info(O.TAG, "Reading Stats saved at close:", f and how or "no stats") end
    -- 2.1.26: Glimpse's list of the book's pictures, looked up now (once per book) so the
    -- stats page can show them later without opening the book
    if O.Glimpse and O.Glimpse.installed and O.Glimpse.installed() and not O.Glimpse.scan(path, true) then
        UIManager:scheduleIn(2, function() pcall(O.Glimpse.scan, path) end)
    end
end

-- 2.1.9: the book's highlights, notes and bookmarks from its sidecar (KOReader's
-- annotations: a highlight has pos0, a page bookmark doesn't), or nil
local function annotations(path)
    if type(path) ~= "string" then return nil end
    local got
    pcall(function()
        local DocSettings = require("docsettings")
        if DocSettings.hasSidecarFile and not DocSettings:hasSidecarFile(path) then return end
        local list = DocSettings:open(path):readSetting("annotations")
        if type(list) ~= "table" then return end
        local hl, notes, marks, hl_pages = 0, 0, 0, {}
        for _i, a in ipairs(list) do
            if type(a) == "table" then
                if a.pos0 then
                    hl = hl + 1
                    if tonumber(a.pageno) then hl_pages[#hl_pages + 1] = tonumber(a.pageno) end
                    if type(a.note) == "string" and a.note ~= "" then notes = notes + 1 end
                else
                    marks = marks + 1
                end
            end
        end
        got = { highlights = hl, notes = notes, bookmarks = marks, hl_pages = hl_pages }
    end)
    return got
end

-- a plugin's folder is there and it isn't turned off in KOReader's Plugin management
local function pluginOn(name)
    local off = G_reader_settings and G_reader_settings:readSetting("plugins_disabled")
    if type(off) == "table" and off[name] then return false end
    local dirs = { "plugins" }
    local ok, DataStorage = pcall(require, "datastorage")
    if ok then dirs[2] = DataStorage:getDataDir() .. "/plugins" end
    for _i, dir in ipairs(dirs) do
        if O.lfs.attributes(dir .. "/" .. name .. ".koplugin", "mode") == "directory" then return true end
    end
    return false
end

-- what sits beside the title: highlights / bookmarks (when there are any) and X-Ray /
-- Glimpse (when installed). 2.1.9: shown only, for placement; each opens its own
-- window later.
function Stats.extras(d, path)
    local ann = annotations(path)
    d.hl_pages = ann and ann.hl_pages or nil
    local hl = ann and ann.highlights or d.highlights or 0
    local notes = ann and ann.notes or d.notes or 0
    local out = {}
    if hl > 0 then
        out[#out + 1] = { id = "highlights", label = (hl == 1 and _("1 highlight") or T(_("%1 highlights"), hl))
            .. (notes > 0 and (" · " .. (notes == 1 and _("1 note") or T(_("%1 notes"), notes))) or "") }
    end
    if ann and ann.bookmarks > 0 then
        out[#out + 1] = { id = "bookmarks", label = ann.bookmarks == 1 and _("1 bookmark") or T(_("%1 bookmarks"), ann.bookmarks) }
    end
    -- 2.1.25 (TK): X-Ray and Glimpse only when they have something saved for this book
    -- (X-Ray's or KOAssistant's X-Ray, Glimpse's list of the book's pictures)
    if O.XRay and O.XRay.load and type(path) == "string" then
        local okX, data, src = pcall(O.XRay.load, path, d.pct)
        if okX and type(data) == "table" then
            -- 2.1.26 (TK): KOAssistant's X-Ray (X-Ray not installed) gets the same chip, named
            out[#out + 1] = { id = "xray", label = src == "koassistant" and _("X-Ray · KOAssistant") or _("X-Ray") }
        end
    end
    -- 2.1.37 (TK: the chip said "no maps, family trees or pictures"): only when Glimpse
    -- has pictures to show for this book after its own filter, so a tap opens them
    if pluginOn("glimpse") and Stats.glimpseSaved(path) and Stats.glimpseHas(path, d.pct) then
        out[#out + 1] = { id = "glimpse", label = _("Glimpse") }
    end
    return out
end

-- 2.1.37: pictures Glimpse would show (its filter, hidden / added, up to your chapter or locked)
function Stats.glimpseHas(path, pct)
    if not (O.Glimpse and O.Glimpse.pictures) then return true end
    local ok, pics = pcall(O.Glimpse.pictures, path, { pct = pct })
    return ok and type(pics) == "table" and type(pics.list) == "table" and #pics.list > 0
end

-- 2.1.25: whether Glimpse has gone through this book and found pictures (its saved scan
-- in the book's settings folder; it's only made once the book's been opened in Glimpse)
function Stats.glimpseSaved(path)
    if type(path) ~= "string" then return false end
    -- 2.1.26: Glimpse's own save or OrbitShelf's look through the book (made at book close)
    if O.Glimpse and O.Glimpse.saved then return O.Glimpse.saved(path, true) end
    local ok, dir = pcall(function() return require("docsettings"):getSidecarDir(path) end)
    if not (ok and dir) then return false end
    local f = io.open(dir .. "/glimpse.scan.lua", "r")
    if not f then return false end
    local txt = f:read("*a") or ""
    f:close()
    return txt:find("spine_index", 1, true) ~= nil
end

-- Clean Up Cache
function Stats.clearStore()
    store = nil
    mem = {}
    pcall(os.remove, Stats.storeFile())
end

function Stats.reset() mem = {} end

-- ---- Drawing --------------------------------------------------------------------------

local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local C = Blitbuffer.Color8
local INK, MID, SOFT, PALE, PAPER = Blitbuffer.COLOR_BLACK, C(0x77), C(0xAA), C(0xDD), Blitbuffer.COLOR_WHITE
-- 2.1.20 (TK: grey text is hard to read, night mode most of all): small text near black
local SUB = C(0x33)
local NIGHT = C(0xEE)

local function px(v) return Screen:scaleBySize(v) end
local function face(size) return Font:getFace("cfont", size) end
local function text(s, size, bold, color, max_w)
    return W("textwidget"):new{ text = s, face = face(size), bold = bold, fgcolor = color or INK, max_width = max_w }
end

-- Colours: on a colour screen with colour on, a few accents (the shapes only; words
-- stay black and grey). Night mode inverts the screen, so the colours are flipped
-- first and land as meant. Otherwise every accent is its grey.
local function rgb(r, g, b, night)
    if night then r, g, b = 255 - r, 255 - g, 255 - b end
    return { v = Blitbuffer.ColorRGB32(r, g, b, 0xFF), rgb = true }
end
local function grey(c) return { v = c } end

local function palette()
    local colour = Screen.isColorEnabled and Screen:isColorEnabled() and Blitbuffer.ColorRGB32 ~= nil
    local night = Screen.night_mode == true
    local P = { colour = colour, night = night, ink = grey(INK), mid = grey(MID), soft = grey(SOFT),
        pale = grey(PALE), paper = grey(PAPER), sky_night = grey(NIGHT) }
    if not colour then
        P.tile, P.tile_hero, P.cell = grey(NIGHT), grey(NIGHT), grey(PALE)
        P.red, P.green = grey(INK), grey(MID)
        P.gold, P.gold_soft, P.blue, P.top = grey(INK), grey(SOFT), grey(INK), grey(INK)
        P.ground, P.ground_ahead, P.track = grey(SOFT), grey(PALE), grey(PALE)
        P.sky_day, P.bar_day, P.bar_night = grey(PAPER), grey(INK), grey(MID)
        return P
    end
    -- as seen: night mode (dark page) / day mode (white page)
    P.gold = rgb(240, 170, 30, night)
    P.gold_soft = night and rgb(110, 85, 35, true) or rgb(245, 215, 150, false)
    P.blue = rgb(80, 150, 230, night)
    P.top = rgb(230, 70, 60, night)
    P.red = P.top
    P.green = rgb(60, 185, 110, night)
    -- 2.1.15: another Colour Theme than Vibrant: its blue, green, gold and red here too
    if O.Theme and not O.Theme.isDefault() then
        local c = O.Theme.colours()
        P.blue = rgb(c.blue[1], c.blue[2], c.blue[3], night)
        P.green = rgb(c.green[1], c.green[2], c.green[3], night)
        P.gold = rgb(c.gold[1], c.gold[2], c.gold[3], night)
        P.top = rgb(c.red[1], c.red[2], c.red[3], night)
        P.red = P.top
    end
    -- 2.1.11: the tiles
    P.tile = night and rgb(30, 33, 44, true) or rgb(238, 242, 248, false)
    P.tile_hero = night and rgb(40, 36, 30, true) or rgb(250, 243, 228, false)
    P.cell = night and rgb(44, 48, 60, true) or rgb(225, 230, 238, false)
    P.ground = night and rgb(55, 85, 125, true) or rgb(170, 200, 232, false)
    P.ground_ahead = night and rgb(26, 32, 44, true) or rgb(228, 233, 241, false)
    P.track = night and rgb(70, 70, 70, true) or rgb(215, 215, 215, false)
    P.sky_day = night and rgb(34, 36, 44, true) or rgb(236, 243, 251, false)
    P.sky_night = night and rgb(12, 14, 24, true) or rgb(196, 206, 228, false)
    P.bar_day = P.gold
    P.bar_night = night and rgb(250, 250, 250, true) or rgb(40, 60, 110, false)
    return P
end

-- fill a rectangle with a palette colour (RGB on a colour buffer, else paintRect)
local function fill(bb, x, y, w, h, k)
    if w <= 0 or h <= 0 then return end
    if k.rgb and bb.paintRectRGB32 then bb:paintRectRGB32(x, y, w, h, k.v) else bb:paintRect(x, y, w, h, k.v) end
end

local function disc(bb, cx, cy, r, k)
    for dy = -r, r do
        local dx = math.floor(math.sqrt(r * r - dy * dy) + 0.5)
        fill(bb, cx - dx, cy + dy, 2 * dx + 1, 1, k)
    end
end

-- a line of squares from one point to another (t: thickness)
local function line(bb, x0, y0, x1, y1, t, k)
    local len = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
    local steps = math.max(1, math.floor(len))
    for i = 0, steps do
        local f = i / steps
        fill(bb, math.floor(x0 + (x1 - x0) * f - t / 2), math.floor(y0 + (y1 - y0) * f - t / 2), t, t, k)
    end
end

local function dashed(bb, x0, y0, x1, y1, t, k, on, off)
    local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
    if len < 1 then return end
    local pos = 0
    while pos < len do
        local e = math.min(len, pos + on)
        line(bb, x0 + (x1 - x0) * pos / len, y0 + (y1 - y0) * pos / len,
            x0 + (x1 - x0) * e / len, y0 + (y1 - y0) * e / len, t, k)
        pos = pos + on + off
    end
end

-- a widget that draws itself: draw(bb, x, y, w, h)
local Canvas = W("widget"):extend{ width = 0, height = 0 }
function Canvas:getSize() return Geom:new{ w = self.width, h = self.height } end
function Canvas:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.draw(bb, x, y, self.width, self.height)
end
local function canvas(w, h, draw) return Canvas:new{ width = w, height = h, draw = draw } end
-- a fixed-size box with its content at the top left
local function boxed(child, w, h)
    return canvas(w, h, function(bb, x, y) child:paintTo(bb, x, y) end)
end

-- SimpleUI's critter (the one picked there), or nil without SimpleUI
local function critter(mood, max_w, max_h)
    if type(O.critterSprite) ~= "function" then return nil end
    local ok, sp = pcall(O.critterSprite, mood, max_w, max_h)
    return ok and sp or nil
end

-- ---- TIME / DAYS / LEFT -------------------------------------------------------------------

-- the little chart under each column
local function barsChart(d, w, h, P)
    local list = d.day_list
    local from = math.max(1, #list - 9)
    local top
    for i = from, #list do if not top or list[i].secs > list[top].secs then top = i end end
    local lab = top and text(os.date("%a ", list[top].t) .. durS(list[top].secs), 11, true, INK) or nil
    local lab_h = lab and lab:getSize().h + px(2) or 0
    return canvas(w, h, function(bb, x, y)
        local count = #list - from + 1
        local slot = w / 10
        local bw = math.max(px(3), math.floor(slot * 0.78))
        local gh = h - lab_h
        local max_s = top and list[top].secs or 1
        for i = from, #list do
            local bx = x + math.floor((i - from + 10 - count) * slot)
            local bh = math.max(px(2), math.floor(list[i].secs / max_s * gh))
            fill(bb, bx, y + h - bh, bw, bh, i == top and P.top or (P.colour and P.blue or P.soft))
            if i == top and lab then
                local lx = math.max(x, math.min(x + w - lab:getSize().w, bx + math.floor(bw / 2 - lab:getSize().w / 2)))
                lab:paintTo(bb, lx, y + h - bh - lab_h)
            end
        end
    end)
end

local function dotsChart(d, w, h, P)
    local lab = text(_("filled: a day you read"), 11, false, SUB, w)
    return canvas(w, h, function(bb, x, y)
        local count = math.min(14, d.days_since)
        local today = midnight(d.finished and d.finish_t or d.now)
        local slot = w / math.max(count, 7)
        local r = math.max(px(3), math.min(px(7), math.floor(slot * 0.32)))
        local cy = y + math.floor((h - lab:getSize().h) / 2)
        for i = 1, count do
            local t = today - (count - i) * 86400
            local cx = x + math.floor((i - 0.5) * slot)
            if d.days[dayKey(t + 3600)] then
                disc(bb, cx, cy, r, P.gold)
            else
                disc(bb, cx, cy, r, P.soft)
                disc(bb, cx, cy, math.max(1, r - px(2)), P.paper)
            end
        end
        lab:paintTo(bb, x, y + h - lab:getSize().h)
    end)
end

local function progressChart(d, w, h, P)
    local lab = text(d.finished and _("finished") or (math.floor(d.pct * 100) .. "%"), 11, false, SUB)
    return canvas(w, h, function(bb, x, y)
        local bh = px(10)
        local by = y + math.floor((h - lab:getSize().h) / 2 - bh / 2)
        local fw = math.floor(w * (d.finished and 1 or d.pct))
        if P.colour then fill(bb, x, by, w, bh, P.track) else bb:paintRoundedRect(x, by, w, bh, PALE, math.floor(bh / 2)) end
        if fw > 0 then
            if P.colour then fill(bb, x, by, fw, bh, P.gold)
            else bb:paintRoundedRect(x, by, math.max(fw, bh), bh, INK, math.floor(bh / 2)) end
        end
        lab:paintTo(bb, x, y + h - lab:getSize().h)
    end)
end

-- the three columns. big: the number's size; chart_h: 0 = no charts
local function columns(d, w, big, chart_h, P)
    local gap = px(16)
    local cw = math.floor((w - 2 * gap) / 3)
    local per_day = d.days_read > 0 and d.secs / d.days_read or 0
    local cols = {
        { _("TIME"), durS(d.secs), T(_("%1 a reading day"), durS(per_day)), barsChart },
        { _("DAYS"), T(_("%1 of %2"), d.days_read, d.days_since),
          T(d.days_read >= d.days_since and _("every day since %1") or _("since %1"), day(d.first)), dotsChart },
    }
    if d.finished then
        cols[3] = { _("DONE"), day(d.finish_t), d.took_days == 1 and _("in 1 day") or T(_("in %1 days"), d.took_days), progressChart }
    else
        cols[3] = { _("LEFT"), durS(d.left_secs),
            T(_("%1 to go"), amount(d, d.pages_left)), progressChart }
    end
    local row = W("horizontalgroup"):new{ align = "top" }
    for i, c in ipairs(cols) do
        if i > 1 then row[#row + 1] = W("horizontalspan"):new{ width = gap } end
        local head = text(c[1], 12, true, INK, cw)
        local g = W("verticalgroup"):new{ align = "left", head,
            canvas(cw, px(4), function(bb, x, y) fill(bb, x, y + px(1), cw, px(2), P.blue) end),
            text(c[2], big, true, INK, cw), text(c[3], 12, false, SUB, cw) }
        if chart_h > 0 then
            g[#g + 1] = W("verticalspan"):new{ width = px(6) }
            g[#g + 1] = c[4](d, cw, chart_h, P)
        end
        row[#row + 1] = g
    end
    return row
end

-- the grey line under the columns
local function paceLine(d)
    local bits = {}
    -- 2.1.9: today with this book, or when you last read it
    if d.today and not d.finished then
        bits[#bits + 1] = T(_("Today %1, %2"), durS(d.today.secs),
            amount(d, d.today.pages))
    elseif not d.finished and d.last_read_days >= 1 then
        bits[#bits + 1] = d.last_read_days == 1 and T(_("Last read yesterday (%1)"), day(d.last))
            or T(_("Last read %1 days ago (%2)"), d.last_read_days, day(d.last))
    end
    local p = paceWords(d)
    if d.rank_faster and d.rank_n then
        if d.rank_faster * 2 >= d.rank_n then p = p .. ", " .. T(_("faster than %1 of your last %2"), d.rank_faster, d.rank_n)
        else p = p .. ", " .. T(_("slower than %1 of your last %2"), d.rank_n - d.rank_faster, d.rank_n) end
    end
    bits[#bits + 1] = p
    local s = #d.sessions == 1 and _("1 sitting") or T(_("%1 sittings"), #d.sessions)
    if d.longest and #d.sessions > 1 then
        s = s .. ", " .. T(_("about %1 each, longest %2"), durS(d.secs / #d.sessions), durS(d.longest.secs))
    end
    bits[#bits + 1] = s
    local last = d.sessions[#d.sessions]
    if last and last.pages > 0 and not d.finished then
        bits[#bits + 1] = T(_("%1 last time"), amount(d, last.pages))
    end
    return table.concat(bits, "  ·  ")
end

-- "A night book · 78% after 9 PM" (when one part of the day has most of it)
local WHEN = {
    morning = { _("A morning book"), _("%1% 5 AM to noon") },
    afternoon = { _("An afternoon book"), _("%1% noon to 5 PM") },
    evening = { _("An evening book"), _("%1% 5 to 9 PM") },
    night = { _("A night book"), _("%1% after 9 PM") },
}
local function whenLine(d)
    local wl = d.when and WHEN[d.when]
    if not wl or d.when_share < 0.5 then return nil end
    return wl[1] .. "  ·  " .. T(wl[2], math.floor(d.when_share * 100 + 0.5))
end

-- ---- The Description box's other side ---------------------------------------------------

-- as much as fits `lines` lines of `line_h` (the Description box's own size)
function Stats.panel(d, w, lines, line_h)
    local P = palette()
    local room = lines * line_h
    local hint = text(_("Tap for all your stats ›"), 13, true, INK)
    local function hintRow()
        return canvas(w, hint:getSize().h, function(bb, x, y) hint:paintTo(bb, x + w - hint:getSize().w, y) end)
    end
    local wl = whenLine(d)
    local tries = {
        { 24, px(46), true, true }, { 22, px(40), false, true }, { 22, px(34), false, false },
        { 20, 0, false, false }, { 18, 0, false, false, true },
    }
    local g
    for _i, t in ipairs(tries) do
        g = W("verticalgroup"):new{ align = "left" }
        if t[3] and d.summary then
            g[#g + 1] = text(d.summary, 14, true, INK, w)
            g[#g + 1] = W("verticalspan"):new{ width = px(6) }
        end
        g[#g + 1] = columns(d, w, t[1], t[2], P)
        if t[4] then
            g[#g + 1] = W("verticalspan"):new{ width = px(6) }
            g[#g + 1] = text(wl or paceWords(d), 12, false, SUB, w)
        end
        if not t[5] then
            g[#g + 1] = W("verticalspan"):new{ width = px(4) }
            g[#g + 1] = hintRow()
        end
        if g:getSize().h <= room then break end
    end
    if g:getSize().h > room then
        -- a very small box: one line, and the tap
        g = W("verticalgroup"):new{ align = "left",
            text(T(_("%1 read  ·  %2 of %3 days  ·  %4 left"), durS(d.secs), d.days_read, d.days_since,
                d.finished and _("none") or durS(d.left_secs)), 14, true, INK, w) }
        if room >= 2 * line_h then g[#g + 1] = hintRow() end
    end
    return boxed(g, w, room)
end

-- ---- The stats page (2.1.11): one screen of tiles, each opening its own card -------------

-- a rounded rectangle filled with a palette colour (RGB too): rows inset at the corners
local function roundFill(bb, x, y, w, h, r, k)
    if w <= 0 or h <= 0 then return end
    r = math.min(r, math.floor(h / 2), math.floor(w / 2))
    for dy = 0, r - 1 do
        local inset = r - math.floor(math.sqrt(r * r - (r - dy - 0.5) ^ 2) + 0.5)
        fill(bb, x + inset, y + dy, w - 2 * inset, 1, k)
        fill(bb, x + inset, y + h - 1 - dy, w - 2 * inset, 1, k)
    end
    fill(bb, x, y + r, w, h - 2 * r, k)
end

-- a caption that wraps (2 lines at most)
local function caption(s, w, lines)
    local probe = W("textboxwidget"):new{ text = "A\nA", face = face(12), width = w }
    return W("textboxwidget"):new{ text = s, face = face(12), width = w, fgcolor = SUB,
        height = (lines or 2) * math.floor(probe:getSize().h / 2),
        height_adjust = true, height_overflow_show_ellipsis = true }
end

local function dayShort(t) return os.date("%b ", t) .. tonumber(os.date("%d", t)) end

-- 2.1.13: the drawing helpers, for the rings (orbitshelf_rings.lua)
Stats._kit = { px = px, text = text, fill = fill, disc = disc, roundFill = roundFill, canvas = canvas,
    dayKey = dayKey, midnight = midnight, daysBetween = daysBetween, durS = durS, dayShort = dayShort, amount = amount,
    rgb = rgb, grey = grey, C = C, INK = INK, MID = MID, SUB = SUB, SOFT = SOFT, PAPER = PAPER,
    openStore = openStore, openDb = openDb, query = query, fileMd5 = fileMd5, dbMtime = dbMtime, maxSec = statSettings,
    palette = palette, critter = critter, day = day, hour12 = hour12, line = line,
    tapPos = function() return Stats._tap_pos end } -- 2.1.28: All Time, and taps inside Your Year
local function rings()
    local ok, R = pcall(require, "orbitshelf_rings")
    if not ok then O.logger.warn(O.TAG, "Reading Stats rings:", tostring(R)) end
    return ok and R or nil
end

-- ---- What the page needs besides the numbers (looked up once per opening) -------------

-- the chapters (saved at book close), scaled to the book's page count now, with your
-- time and pages in each; nil when none were saved
local function chapters(d)
    if not d.md5 or type(d.page_secs) ~= "table" then return nil end
    local st = openStore()
    local rec = st and st:readSetting("toc:" .. d.md5)
    if type(rec) ~= "table" or type(rec.list) ~= "table" or #rec.list < 2 then return nil end
    local scale = d.total / math.max(1, tonumber(rec.total) or d.total)
    local chs = {}
    for _i, c in ipairs(rec.list) do
        local a = math.max(1, math.floor((tonumber(c.page) or 1) * scale + 0.5))
        chs[#chs + 1] = { title = tostring(c.title or ""), a = a }
    end
    table.sort(chs, function(x, y) return x.a < y.a end)
    for i, c in ipairs(chs) do
        c.b = i < #chs and math.max(c.a, chs[i + 1].a - 1) or d.total
        c.secs, c.pages = 0, 0
        for pg = c.a, c.b do
            local s = d.page_secs[pg]
            if s then c.secs, c.pages = c.secs + s, c.pages + 1 end
        end
        if d.page_now >= c.a and d.page_now <= c.b then d.chapter_now = i end
    end
    return chs
end

-- the words you looked up in this book (KOReader's Vocabulary Builder), or nil
local function words(title)
    if type(title) ~= "string" or title == "" then return nil end
    local path = require("datastorage"):getSettingsDir() .. "/vocabulary_builder.sqlite3"
    if O.lfs.attributes(path, "mode") ~= "file" then return nil end
    local ok, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok then return nil end
    local okc, conn = pcall(SQ3.open, path, "ro")
    if not okc or not conn then return nil end
    local got
    pcall(function()
        local res = query(conn, "SELECT v.word FROM vocabulary v JOIN title t ON v.title_id = t.id "
            .. "WHERE lower(t.name) = lower(?) ORDER BY v.create_time DESC;", { title })
        if res and #res[1] > 0 then got = { count = #res[1], latest = tostring(res[1][1]) } end
    end)
    pcall(conn.close, conn)
    return got
end

-- X-Ray's people and places for this book (its xray_cache.lua in the book's sidecar
-- folder, read as plain data), with your reading time on the pages each is mentioned
-- on, up to your page only. nil without X-Ray or its file.
local function xray(d)
    if type(d.path) ~= "string" or not pluginOn("xray") then return nil end
    local data
    pcall(function()
        local dir = require("docsettings"):getSidecarDir(d.path)
        local file = dir .. "/xray_cache.lua"
        if O.lfs.attributes(file, "mode") ~= "file" then return end
        local chunk = loadfile(file)
        if not chunk then return end
        setfenv(chunk, {})
        local ok, v = pcall(chunk)
        if ok and type(v) == "table" then data = v end
    end)
    if not data then return nil end
    local ps = d.page_secs or {}
    local function walk(list)
        local out, met = {}, 0
        for _i, e in ipairs(type(list) == "table" and list or {}) do
            if type(e) == "table" and type(e.name) == "string" then
                local seen, secs, any = {}, 0, false
                for _j, m in ipairs(type(e.mentions) == "table" and e.mentions or {}) do
                    local pg = type(m) == "table" and tonumber(m.page)
                    if pg and pg <= d.page_now then
                        any = true
                        if not seen[pg] then seen[pg] = true secs = secs + (ps[pg] or 0) end
                    end
                end
                if any then met = met + 1 end
                if secs > 0 then out[#out + 1] = { name = e.name, secs = secs } end
            end
        end
        table.sort(out, function(a, b) return a.secs > b.secs end)
        return out, met
    end
    local people, met_p = walk(data.characters)
    local hist, met_h = walk(data.historical_figures)
    for _i, h in ipairs(hist) do people[#people + 1] = h end
    table.sort(people, function(a, b) return a.secs > b.secs end)
    local places, met_l = walk(data.locations)
    local total_p = (type(data.characters) == "table" and #data.characters or 0)
    return { people = people, places = places, met_people = met_p + met_h, met_places = met_l, known = total_p }
end

-- ---- Moments and habits, worked out from the numbers ------------------------------------

local function moments(d, extra)
    local out = {}
    local ps = d.page_secs
    if type(ps) == "table" and d.total >= 40 then
        -- the page-turner: the quickest 20 pages in a row read here
        local best_a, best_s
        for a = 1, d.total - 19 do
            local s = 0
            for pg = a, a + 19 do
                local v = ps[pg]
                if not v then s = nil break end
                s = s + v
            end
            if s and (not best_s or s < best_s) then best_a, best_s = a, s end
        end
        if best_a then out[#out + 1] = { "turner", _("The page-turner"), T(_("Pages %1–%2 flew by in %3"), best_a, best_a + 19, durS(best_s)) } end
    end
    if d.longest then
        out[#out + 1] = { "sitting", _("Couldn't put it down"), T(_("%1 in one go, %2"), d.unit == "pct" and
            (pct1(d.longest.pages) .. "%") or T(_("%1 pages"), d.longest.pages), durS(d.longest.secs)) .. ", "
            .. os.date("%A", d.longest.start) }
    end
    local rec_day
    for _i, dd in ipairs(d.day_list) do if not rec_day or dd.pages > rec_day.pages then rec_day = dd end end
    if rec_day and #d.day_list > 1 then
        out[#out + 1] = { "record", _("Record day"), T(_("%1 on %2"), amount(d, rec_day.pages), os.date("%A, ", rec_day.t) .. day(rec_day.t)) }
    end
    for _i, dd in ipairs(d.day_list) do
        if dd.secs >= 1800 then out[#out + 1] = { "clicked", _("When it clicked"), T(_("%1: your first half hour with it"), day(dd.t)) } break end
    end
    if d.brk then
        out[#out + 1] = { "comeback", _("The comeback"), T(_("Back after %1 away, at %2"), durS(d.brk.secs), math.floor(d.brk.pos * 100 + 0.5) .. "%") }
    end
    if d.hard then
        local nb = #d.trail.b
        local a = d.trail.lo + (d.trail.hi - d.trail.lo) * (d.hard - 1) / nb
        out[#out + 1] = { "slog", _("The slog"), T(d.unit == "pct" and _("Around %1: %2 min per 1%, your slowest") or _("Around %1: %2 min a page, your slowest"),
            math.floor(a * 100 + 0.5) .. "%", mpp(d.trail.b[d.hard])) }
    end
    if extra and extra.words then
        out[#out + 1] = { "words", _("Words you looked up"), T(_("%1 in this book, latest: %2"), extra.words.count, extra.words.latest) }
    end
    if extra and extra.chapters and type(d.hl_pages) == "table" and #d.hl_pages > 0 then
        local per, top = {}, nil
        for _i, pg in ipairs(d.hl_pages) do
            for i, c in ipairs(extra.chapters) do
                if pg >= c.a and pg <= c.b then per[i] = (per[i] or 0) + 1 break end
            end
        end
        for i, c in pairs(per) do if not top or c > per[top] then top = i end end
        if top and per[top] >= 2 then
            out[#out + 1] = { "hotspot", _("Highlight hotspot"), T(_("%1: %2 of your %3 highlights"), extra.chapters[top].title, per[top], #d.hl_pages) }
        end
    end
    -- 2.1.23 (TK): the story (X-Ray) and rewards (ReadMastery), when there are any
    if O.XRay and d.unit ~= "pct" then
        local ok, more = pcall(O.XRay.moments, d, extra)
        if ok and type(more) == "table" then
            -- on the tile, one of each mixed in after the first two of yours
            local story, reward
            for _i, m in ipairs(more) do
                if m.group == "story" and not story then story = m end
                if m.group == "rewards" and not reward then reward = m end
            end
            local pos = math.min(#out + 1, 3)
            if reward then table.insert(out, pos, reward) end
            if story then table.insert(out, pos, story) end
            out.more = more
        elseif not ok then
            O.logger.warn(O.TAG, "Reading Stats x-ray / rewards:", tostring(more))
        end
    end
    return out
end

local function habits(d)
    local h = {}
    local dips, mids, dives = 0, 0, 0
    for _i, s in ipairs(d.sessions) do
        if s.secs < 600 then dips = dips + 1 elseif s.secs < 1800 then mids = mids + 1 else dives = dives + 1 end
    end
    h.dips, h.mids, h.dives = dips, mids, dives
    local parts = { { "morning", 5, 11 }, { "afternoon", 12, 16 }, { "evening", 17, 20 }, { "night", 21, 28 } }
    for _i, pt in ipairs(parts) do
        local s, pgs = 0, 0
        for _j, se in ipairs(d.sessions) do
            local hh = tonumber(os.date("%H", se.start))
            if hh < 5 then hh = hh + 24 end
            if hh >= pt[2] and hh <= pt[3] then s, pgs = s + se.secs, pgs + se.pages end
        end
        if s >= 600 then
            local v = pgs * 3600 / s
            if not h.best or v > h.best[2] then h.best = { pt[1], v } end
            if not h.worst or v < h.worst[2] then h.worst = { pt[1], v } end
        end
    end
    local we, wd = 0, 0
    for _i, dd in ipairs(d.day_list) do
        local w = tonumber(os.date("%w", dd.t))
        if w == 0 or w == 6 then we = we + dd.secs else wd = wd + dd.secs end
    end
    h.weekend, h.weekday = we, wd
    local late = 0
    for _i, s in ipairs(d.sessions) do
        local hh = tonumber(os.date("%H", s.start))
        if hh >= 23 or hh < 4 then late = late + 1 end
    end
    h.late = late
    return h
end

-- this week (Mon-Sun) and the same days last week, in the book's unit
local function weekNumbers(d)
    local today = midnight(d.now)
    local wd = (tonumber(os.date("%w", today)) + 6) % 7
    local mon = today - wd * 86400
    local this, last, ts, ls = {}, {}, 0, 0
    for i = 0, 6 do
        local a = d.days[dayKey(mon + i * 86400 + 3600)]
        local b = d.days[dayKey(mon - (7 - i) * 86400 + 3600)]
        this[i + 1], last[i + 1] = a and a.pages or 0, b and b.pages or 0
        ts, ls = ts + this[i + 1], ls + last[i + 1]
    end
    return this, last, ts, ls, mon, today
end

-- ---- Small charts shared by tiles and cards ------------------------------------------------

-- the month: a cell a day, the amount read in it, greener (darker) for more
local function drawMonth(bb, x, y, w, h, d, P, big, at, hits)
    local mt = os.date("*t", at or (d.finished and d.finish_t or d.now))
    local first = os.time{ year = mt.year, month = mt.month, day = 1, hour = 12 }
    local ndays = os.date("*t", os.time{ year = mt.year, month = mt.month + 1, day = 0, hour = 12 }).day
    local lead = (tonumber(os.date("%w", first)) + 6) % 7
    local rows = math.ceil((lead + ndays) / 7)
    local head = 0
    if big then
        local wk = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") }
        local mg0 = px(4)
        local cw0 = math.floor((w - 6 * mg0) / 7)
        for i = 1, 7 do
            local l = text(wk[i], 11, true, SUB)
            l:paintTo(bb, x + (i - 1) * (cw0 + mg0) + math.floor((cw0 - l:getSize().w) / 2), y)
            head = l:getSize().h + px(4)
        end
    end
    local mg = big and px(4) or px(3)
    local cw = math.floor((w - 6 * mg) / 7)
    local ch = math.floor((h - head - (rows - 1) * mg) / rows)
    local max_p = 0
    for k = 1, ndays do
        local dd = d.days[dayKey(os.time{ year = mt.year, month = mt.month, day = k, hour = 12 })]
        if dd and dd.pages > max_p then max_p = dd.pages end
    end
    local best_k = max_p > 0 and max_p or nil
    max_p = math.max(max_p, 0.001)
    local today_key = dayKey(d.now)
    local fin_key = (not d.finished and d.finish_t) and dayKey(d.finish_t + 3600) or nil
    for k = 1, ndays do
        local slot = lead + k - 1
        local cx = x + (slot % 7) * (cw + mg)
        local cy = y + head + math.floor(slot / 7) * (ch + mg)
        local key = dayKey(os.time{ year = mt.year, month = mt.month, day = k, hour = 12 })
        local dd = d.days[key]
        if hits then hits[#hits + 1] = { x = cx, y = cy, w = cw, h = ch, t = os.time{ year = mt.year,
            month = mt.month, day = k, hour = 12 } } end
        if dd and dd.pages > 0 then
            local a = 0.3 + 0.7 * dd.pages / max_p
            local col
            if P.colour then
                col = P.night and rgb(math.floor(60 * a), math.floor(185 * a), math.floor(110 * a), true)
                    or rgb(math.floor(255 - 195 * a), math.floor(255 - 70 * a), math.floor(255 - 145 * a), false)
            else
                col = grey(({ C(0xAA), C(0x77), C(0x44), C(0x00) })[math.max(1, math.min(4, math.ceil(dd.pages / max_p * 4)))])
            end
            roundFill(bb, cx, cy, cw, ch, px(5), col)
            local dark = not P.colour and dd.pages / max_p > 0.5
            if big then text(tostring(k), 9, true, dark and PAPER or INK):paintTo(bb, cx + px(4), cy + px(2)) end
            local nt = text(d.unit == "pct" and (pct1(dd.pages) .. "%")
                or (d.unit == "min" and (dd.pages >= 60 and T(_("%1h %2m"), math.floor(dd.pages / 60), math.floor(dd.pages % 60 + 0.5))
                    or (math.floor(dd.pages + 0.5) .. "m")))
                or tostring(dd.pages), big and 14 or 11, true, dark and PAPER or INK)
            nt:paintTo(bb, cx + math.floor((cw - nt:getSize().w) / 2), cy + ch - nt:getSize().h - (big and px(2) or math.floor((ch - nt:getSize().h) / 2)))
        else
            roundFill(bb, cx, cy, cw, ch, px(5), P.cell)
            local nt = text(tostring(k), 9, false, SUB)
            nt:paintTo(bb, cx + (big and px(4) or math.floor((cw - nt:getSize().w) / 2)), cy + (big and px(2) or math.floor((ch - nt:getSize().h) / 2)))
        end
        if key == today_key then bb:paintBorder(cx, cy, cw, ch, px(2), INK, px(5)) end
        -- 2.1.26 (TK): a star on the month's best day, like the ring
        if big and best_k and dd and dd.pages == best_k then
            local st = text("★", 14, true, (P.colour or dd.pages / max_p <= 0.5) and INK or PAPER)
            st:paintTo(bb, cx + cw - st:getSize().w - px(4), cy + px(1))
        end
        if key == fin_key then
            bb:paintRect(cx + cw - px(14), cy + px(4), px(2), ch - px(8), INK)
            for i = 0, px(7) do fill(bb, cx + cw - px(12), cy + px(4) + i, px(7) - i, 1, P.red) end
        end
    end
end

-- this week's bars (green: beat the same day last week) and last week's red ticks
local function drawWeek(bb, x, y, w, h, d, P, labels)
    local this, last = weekNumbers(d)
    local vmax = 0.001
    for i = 1, 7 do vmax = math.max(vmax, this[i], last[i]) end
    local lab_h = 0
    local wk = { _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat"), _("Sun") }
    if labels then lab_h = text("M", 10, false, SUB):getSize().h + px(2) end
    local gh = h - lab_h
    local slot = w / 7
    local bw = math.floor(slot * 0.55)
    for i = 1, 7 do
        local bx = x + math.floor((i - 1) * slot + (slot - bw) / 2)
        local bh = math.floor(this[i] / vmax * (gh - px(16)))
        if bh > 0 then
            roundFill(bb, bx, y + gh - bh, bw, bh, px(3), this[i] >= last[i] and P.green or P.blue)
            if labels then
                local n1 = text(d.unit == "pct" and pct1(this[i]) or tostring(this[i]), 10, true, INK)
                n1:paintTo(bb, bx + math.floor((bw - n1:getSize().w) / 2), y + gh - bh - n1:getSize().h)
            end
        end
        if last[i] > 0 then fill(bb, bx - px(2), y + gh - math.floor(last[i] / vmax * (gh - px(16))), bw + px(4), px(3), P.red) end
        if labels then
            local l = text(wk[i], 10, false, SUB)
            l:paintTo(bb, bx + math.floor((bw - l:getSize().w) / 2), y + gh + px(2))
        end
    end
    bb:paintRect(x, y + gh, w, 1, MID)
end

-- ---- The dashboard --------------------------------------------------------------------------

-- the tiles, filling iw x room; returns the widget and the list of { canvas, card }
local function dashboard(d, rec, iw, room, P, extra)
    local g = px(8)
    local tp = px(12)
    local R = px(16)
    local taps = {}
    local function tile(w, h, title, accent, card, draw, bg)
        local l = title and text(title, 10, true, SUB) or nil
        local c = canvas(w, h, function(bb, x, y)
            roundFill(bb, x, y, w, h, R, bg or P.tile)
            local top = y + tp
            if l then
                roundFill(bb, x + tp, top + px(3), px(14), px(6), px(3), accent or P.blue)
                l:paintTo(bb, x + tp + px(20), top - px(1))
                top = top + l:getSize().h + px(4)
            end
            draw(bb, x + tp, top, w - 2 * tp, y + h - tp - top)
        end)
        if card then taps[#taps + 1] = { c, card } end
        return c
    end
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local function row(list, h, count)
        -- tiles side by side: list of { weight, builder(w, h) } (count slots, some may be
        -- missing); missing ones leave their room to the rest
        local present = {}
        for i = 1, count or #list do if list[i] then present[#present + 1] = list[i] end end
        local wsum = 0
        for _i, it in ipairs(present) do wsum = wsum + it[1] end
        local hg = HG:new{ align = "top" }
        local left = iw - (#present - 1) * g
        local used = 0
        for i, it in ipairs(present) do
            local w = i == #present and (left - used) or math.floor(left * it[1] / wsum)
            used = used + w
            if i > 1 then hg[#hg + 1] = HS:new{ width = g } end
            hg[#hg + 1] = it[2](w, h)
        end
        return hg
    end

    -- the sizes, shrunk together when the screen is short
    local H = { hero = px(118), nums = px(74), month = px(196), mid = px(146), small = px(92) }
    -- 2.1.14: the chips under the title (highlights, bookmarks, X-Ray, Glimpse), each opening its window
    local chips = {}
    local CHIP_RGB = { highlights = { 255, 180, 0 }, bookmarks = { 45, 135, 255 }, xray = { 165, 95, 245 }, glimpse = { 0, 195, 205 } }
    for _i, e in ipairs(d.extras or {}) do
        local c = CHIP_RGB[e.id] or CHIP_RGB.bookmarks
        if O.Theme and not O.Theme.isDefault() then
            c = O.Theme.rgb(({ highlights = "gold", bookmarks = "blue", xray = "purple", glimpse = "teal" })[e.id] or "blue")
        end
        chips[#chips + 1] = { id = e.id, t = text(e.label, 11, true, INK),
            k = P.colour and rgb(c[1], c[2], c[3], P.night) or grey(INK) }
    end
    local chip_h = #chips > 0 and (chips[1].t:getSize().h + px(10)) or 0
    if #chips > 0 then H.hero = H.hero + chip_h + px(6) end
    local function total()
        return H.hero + H.nums + H.month + H.mid + H.small + 4 * g
    end
    if total() > room then
        local k = (room - 4 * g) / (total() - 4 * g)
        for key, v in pairs(H) do H[key] = math.floor(v * k) end
    end

    local col = VG:new{ align = "left" }
    local function gap() col[#col + 1] = VS:new{ width = g } end

    -- the hero: the book, and the journey with the critter
    local who = rec.author
    if (type(who) ~= "string" or who == "") and type(rec.authors) == "table" then who = rec.authors[1] end
    local rd = d.reads and d.reads[#d.reads]
    local st = rd and rd.start or d.first
    local bits = {}
    if type(who) == "string" and who ~= "" then bits[#bits + 1] = who end
    if d.finished then bits[#bits + 1] = T(_("finished %1, %2 days"), day(d.finish_t), d.took_days)
    else bits[#bits + 1] = T(_("started %1, day %2"), day(st), daysBetween(midnight(st), midnight(d.now)) + 1) end
    if d.reads and #d.reads > 1 then bits[#bits + 1] = T(_("read #%1"), #d.reads) end
    local ttl = text(tostring(rec.display_title or rec.title or ""), 20, true, INK, iw - 2 * tp)
    local sub = text(table.concat(bits, "   ·   "), 12, false, SUB, iw - 2 * tp)
    local crit = critter("happy", px(26), px(26))
    local pct_t = text(math.floor(d.pct * 100 + 0.5) .. "%", 13, true, INK)
    local fin_t = d.finished and text(_("finished"), 12, true, INK) or (d.finish_t and text(T(_("done around %1"), dayShort(d.finish_t)), 12, true, INK)) or nil
    local range_t = (d.finish_lo and d.finish_hi) and text(dayShort(d.finish_lo) .. " – " .. dayShort(d.finish_hi), 10, false, SUB) or nil
    col[#col + 1] = tile(iw, H.hero, nil, nil, "book", function(bb, x, y, w, h)
        ttl:paintTo(bb, x, y - px(2))
        sub:paintTo(bb, x, y + ttl:getSize().h - px(2))
        local cx, cy = x, y + ttl:getSize().h + sub:getSize().h + px(4)
        local rb = O.Sheet and O.Sheet.rainbow and O.Sheet.rainbow(P) or false
        -- 2.1.36: Pill Colours off: plain edges
        if rb and O.Sheet.pillsColoured and not O.Sheet.pillsColoured(P) then rb = false end
        for _i, c in ipairs(chips) do
            local cw = c.t:getSize().w + px(30)
            if cx + cw > x + w then c.dimen = nil break end
            -- 2.1.19: the colour itself (c.k is { v = colour }); handing KOReader the table crashed it
            -- 2.1.24 (TK): the colour edge only with Popup Style Rainbow, else black (white at night)
            local solid = rb and O.Sheet.solid and O.Sheet.solid(P) or nil -- 2.1.34: Solid's colour
            bb:paintBorder(cx, cy, cw, chip_h, px(2), rb and (solid or c.k).v or INK, math.floor(chip_h / 2))
            disc(bb, cx + px(11), cy + math.floor(chip_h / 2), px(4), c.k)
            c.t:paintTo(bb, cx + px(20), cy + math.floor((chip_h - c.t:getSize().h) / 2))
            c.dimen = Geom:new{ x = cx, y = cy, w = cw, h = chip_h }
            cx = cx + cw + px(8)
        end
        local by = y + h - px(12)
        local x0 = x
        local x1 = x + w - math.max(fin_t and fin_t:getSize().w or 0, range_t and range_t:getSize().w or 0) - px(24)
        roundFill(bb, x0, by, x1 - x0, px(8), px(4), P.track)
        local xn = x0 + math.floor((x1 - x0) * (d.finished and 1 or d.pct))
        roundFill(bb, x0, by, xn - x0, px(8), px(4), P.green)
        local lastdx = -1e9
        for i = 1, #d.day_list - 1 do
            local dx = x0 + math.floor((x1 - x0) * math.max(0, d.day_list[i].reached))
            if dx < xn - px(18) and dx - lastdx >= px(12) then
                disc(bb, dx, by + px(4), px(4), P.paper)
                disc(bb, dx, by + px(4), px(2), P.ink)
                lastdx = dx
            end
        end
        if d.ahead then
            -- the days ahead, at most about a dozen dots
            local step = math.max(1, math.ceil(#d.ahead / 12))
            for k = step, #d.ahead - 1, step do
                local dx = x0 + math.floor((x1 - x0) * d.ahead[k].pct)
                if dx > xn + px(30) then disc(bb, dx, by + px(4), px(3), P.mid) end
            end
        end
        bb:paintRect(x1, by - px(22), px(2), px(30), INK)
        for i = 0, px(8) do fill(bb, x1 + px(2), by - px(22) + i, px(8) - i, 1, P.red) end
        -- 2.1.20 (TK): the campfire's gone; the critter stands where you are
        if crit and not d.finished then crit:paintTo(bb, xn - math.floor(crit.dimen.w / 2), by - crit.dimen.h + px(4)) end
        if not d.finished then pct_t:paintTo(bb, xn - math.floor(pct_t:getSize().w / 2), by - px(22) - pct_t:getSize().h) end
        if fin_t then fin_t:paintTo(bb, x1 + px(16), by - px(22)) end
        if range_t then range_t:paintTo(bb, x1 + px(16), by - px(4)) end
    end, P.tile_hero)
    for i, c in ipairs(chips) do
        table.insert(taps, i, { c, function()
            if O.BookMore and O.BookMore.chip then O.BookMore.chip(c.id, rec, d, extra) end
        end })
    end
    gap()

    -- four numbers
    local nums = {
        { _("TIME"), durS(d.secs), T(_("%1 a day"), durS(d.secs / math.max(1, d.days_read))), P.blue, "book" },
        -- 2.1.25 (TK): DAYS opens the calendar (the month tile has the ring)
        { _("DAYS"), T(_("%1/%2"), d.days_read, d.days_since), _("days read"), P.green, "days" },
        { _("PACE"), d.unit == "pct" and (pct1(d.pph) .. "%") or tostring(math.floor(d.pph + 0.5)),
          d.unit == "pct" and _("an hour") or _("pages an hour"), P.red, "pace" },
        d.finished and { _("DONE"), dayShort(d.finish_t), T(_("in %1 days"), d.took_days), P.gold, "book" }
            or { _("LEFT"), durS(d.left_secs or 0), T(_("%1 to go"), amount(d, d.pages_left or 0)), P.gold, "book" },
    }
    local nlist = {}
    for _i, nm in ipairs(nums) do
        nlist[#nlist + 1] = { 1, function(w, h)
            local big = text(nm[2], 22, true, INK, w - 2 * tp)
            local sm = text(nm[3], 10, false, SUB, w - 2 * tp)
            return tile(w, h, nm[1], nm[4], nm[5], function(bb, x, y)
                big:paintTo(bb, x, y - px(2))
                sm:paintTo(bb, x, y + big:getSize().h - px(4))
            end)
        end }
    end
    col[#col + 1] = row(nlist, H.nums)
    gap()

    -- the month | this week (+ your reads)
    local month_amt = 0
    local mt = os.date("*t", d.finished and d.finish_t or d.now)
    for _i, dd in ipairs(d.day_list) do
        local t2 = os.date("*t", dd.t)
        if t2.month == mt.month and t2.year == mt.year then month_amt = month_amt + dd.pages end
    end
    local month_b = { 56, function(w, h)
        return tile(w, h, string.upper(os.date("%B", d.finished and d.finish_t or d.now)) .. "  ·  " .. string.upper(amount(d, month_amt)),
            P.green, "month", function(bb, x, y, ww, hh)
                -- 2.1.13: the small ring (the grid if the rings can't load)
                local RG = rings()
                local ok, err = false, "rings didn't load"
                if RG then ok, err = pcall(RG.monthTile, bb, x, y, ww, hh, d, P, extra) end
                if not ok then
                    -- 2.1.20: say why in crash.log (TK's Kobo showed the grid, not the ring)
                    O.logger.warn(O.TAG, "Reading Stats month tile:", tostring(err))
                    drawMonth(bb, x, y, ww, hh, d, P, false)
                end
            end)
    end }
    local multi = d.reads and #d.reads > 1
    local right_b = { 44, function(w, h)
        local ts, ls = select(3, weekNumbers(d))
        local chg = ls > 0 and math.floor((ts - ls) / ls * 100 + 0.5) or nil
        local wbig = text(amount(d, ts), 16, true, INK)
        local wchg = chg and text((chg >= 0 and "▲ " or "▼ ") .. math.abs(chg) .. "%", 11, true, P.colour and (P.night and PAPER or INK) or PAPER) or nil
        local wh = multi and (math.floor((h - g) / 2) + px(8)) or h
        local week = tile(w, wh, _("THIS WEEK"), P.blue, "week", function(bb, x, y, ww, hh)
            wbig:paintTo(bb, x, y - px(2))
            if wchg then
                roundFill(bb, x + ww - wchg:getSize().w - px(12), y, wchg:getSize().w + px(12), wchg:getSize().h + px(2), px(8),
                    chg >= 0 and P.green or P.red)
                wchg:paintTo(bb, x + ww - wchg:getSize().w - px(6), y + px(1))
            end
            local gy = y + wbig:getSize().h + px(2)
            drawWeek(bb, x, gy, ww, y + hh - gy, d, P, false)
        end)
        if not multi then return week end
        local reads = d.reads
        local rt = text(T(_("Read %1 times"), #reads), 14, true, INK)
        local r1 = reads[1]
        local rs = text(T(_("1st: %1, %2 days"), os.date("%b %Y", r1.start),
            daysBetween(midnight(r1.start), midnight(r1.done_t or r1.last)) + 1), 10, false, SUB, w - 2 * tp)
        local rtile = tile(w, h - wh - g, _("YOUR READS"), P.gold, "reads", function(bb, x, y, ww, hh)
            rt:paintTo(bb, x, y - px(2))
            rs:paintTo(bb, x, y + rt:getSize().h - px(2))
            local bx = x
            local bw = math.floor((ww - (#reads - 1) * px(6)) / #reads)
            for i, r in ipairs(reads) do
                local nowr = i == #reads and not d.finished
                local yy = y + hh - px(8)
                roundFill(bb, bx, yy, bw, px(8), px(4), P.track)
                roundFill(bb, bx, yy, math.max(px(8), math.floor(bw * (nowr and d.pct or r.hi))), px(8), px(4),
                    r.done_t and P.green or (nowr and P.gold or P.red))
                bx = bx + bw + px(6)
            end
        end)
        return VG:new{ align = "left", week, VS:new{ width = g }, rtile }
    end }
    col[#col + 1] = row({ month_b, right_b }, H.month)
    gap()

    -- moments | chapters
    local mom = moments(d, extra)
    local mdots = { turner = P.green, sitting = P.red, record = P.blue, clicked = P.gold, comeback = P.blue, slog = P.red, words = P.green, hotspot = P.gold,
        xmet = P.blue, xlook = P.red, xtime = P.green, xplace = P.blue, reward = P.gold, glimpse = P.teal or P.blue }
    local mom_b = #mom > 0 and { 1, function(w, h)
        return tile(w, h, _("MOMENTS"), P.red, "moments", function(bb, x, y, ww, hh)
            local nrows = math.max(1, math.min(#mom, math.floor(hh / px(18))))
            local lh = math.floor(hh / nrows)
            for i = 1, nrows do
                local m = mom[i]
                local ly = y + (i - 1) * lh
                disc(bb, x + px(5), ly + math.floor(lh / 2), px(4), mdots[m[1]] or P.blue)
                local t1 = text(m[3], 11, i == 1, INK, ww - px(16))
                t1:paintTo(bb, x + px(16), ly + math.floor((lh - t1:getSize().h) / 2))
            end
        end)
    end } or nil
    local chs = extra and extra.chapters
    local ch_b = chs and { 1, function(w, h)
        local top_c, maxs = nil, 0
        for i, c in ipairs(chs) do if c.secs > maxs then maxs, top_c = c.secs, i end end
        maxs = math.max(maxs, 1)
        local cur = d.chapter_now or 1
        local chl = text(top_c and T(_("Longest: %1, %2"), chs[top_c].title, durS(chs[top_c].secs)) or "", 12, true, INK, w - 2 * tp)
        local chn = text(d.finished and T(_("%1 chapters"), #chs) or T(_("In %1 of %2 · %3 left"), cur, #chs, amount(d, chs[cur].b - d.page_now)),
            10, false, SUB, w - 2 * tp)
        return tile(w, h, _("CHAPTERS"), P.blue, "chapters", function(bb, x, y, ww, hh)
            chl:paintTo(bb, x, y - px(2))
            chn:paintTo(bb, x, y + chl:getSize().h - px(2))
            local gy = y + chl:getSize().h + chn:getSize().h + px(4)
            local gh = y + hh - gy
            local slot = ww / #chs
            local bw = math.max(1, math.floor(slot * 0.7))
            for i, c in ipairs(chs) do
                local bx = x + math.floor((i - 1) * slot + (slot - bw) / 2)
                local bh = math.max(px(3), math.floor(c.secs / maxs * (gh - px(14))))
                roundFill(bb, bx, gy + gh - px(12) - bh, bw, bh, px(3), i == top_c and P.red or (c.secs > 0 and P.blue or P.track))
                if #chs <= 20 or i % 5 == 0 or i == cur then
                    local nt = text(tostring(i), 9, i == cur, i == cur and INK or SUB)
                    nt:paintTo(bb, bx + math.floor((bw - nt:getSize().w) / 2), gy + gh - px(11))
                end
                if i == cur and not d.finished then disc(bb, bx + math.floor(bw / 2), gy + gh - px(12) - bh - px(6), px(3), P.gold) end
            end
        end)
    end } or nil
    if mom_b or ch_b then
        col[#col + 1] = row({ mom_b, ch_b }, H.mid, 2)
        gap()
    end

    -- the small ones: came back to | X-Ray | habits
    local r1 = d.returned and d.returned[1]
    local back_b = r1 and { 1, function(w, h)
        return tile(w, h, _("CAME BACK TO"), P.gold, "back", function(bb, x, y, ww)
            local t1 = text(T(_("p. %1"), r1.p), 16, true, INK)
            t1:paintTo(bb, x, y - px(2))
            for k = 1, math.min(r1.visits, 8) do disc(bb, x + t1:getSize().w + px(12) + (k - 1) * px(13), y + px(11), px(5), P.red) end
            local more = {}
            for i = 2, math.min(4, #d.returned) do more[#more + 1] = T(_("p. %1"), d.returned[i].p) end
            text(table.concat(more, " · "), 10, false, SUB, ww):paintTo(bb, x, y + t1:getSize().h)
        end)
    end } or nil
    local xr = extra and extra.xray
    local xr_b = xr and { 1, function(w, h)
        local p1 = xr.people[1]
        return tile(w, h, _("X-RAY"), P.blue, "xray", function(bb, x, y, ww)
            if p1 then
                text(T(_("Most with %1"), p1.name), 13, true, INK, ww):paintTo(bb, x, y - px(2))
                local cols = { P.red, P.blue, P.green }
                for i = 1, math.min(3, #xr.people) do
                    local pp = xr.people[i]
                    local yy = y + px(22) + (i - 1) * px(11)
                    local bw = math.floor((ww - px(70)) * pp.secs / p1.secs)
                    roundFill(bb, x, yy, math.max(px(4), bw), px(7), px(3), cols[i])
                    text(pp.name, 9, false, SUB):paintTo(bb, x + bw + px(4), yy - px(5))
                end
            else
                -- 2.1.23: no time on anyone's pages yet: who you've met, from X-Ray's lists
                local sm = O.XRay and select(2, pcall(O.XRay.summary, d, extra))
                local np = type(sm) == "table" and #sm.people or (xr.met_people > 0 and xr.met_people or xr.known)
                text(T(_("%1 people met"), np), 13, true, INK, ww):paintTo(bb, x, y - px(2))
                local xline = type(sm) == "table" and #sm.places > 0 and T(_("%1 places · tap for X-Ray"), #sm.places) or _("tap for X-Ray")
                text(xline, 9, false, SUB, ww):paintTo(bb, x, y + px(22))
            end
        end)
    end } or nil
    local hb = habits(d)
    local hab_b = { 1, function(w, h)
        local first = d.when and T(_("A %1 reader"), d.when) or _("Habits")
        if d.when == "afternoon" or d.when == "evening" then first = T(_("An %1 reader"), d.when) end
        local l2 = T(_("%1 quick dips · %2 longer"), hb.dips, hb.mids + hb.dives)
        local l3 = hb.weekend > hb.weekday and _("mostly weekends") or _("mostly weekdays")
        if hb.late > 0 then l3 = l3 .. " · " .. (hb.late == 1 and _("1 late night") or T(_("%1 late nights"), hb.late)) end
        return tile(w, h, _("HABITS"), P.green, "habits", function(bb, x, y, ww)
            text(first, 13, true, INK, ww):paintTo(bb, x, y - px(2))
            text(l2, 10, false, SUB, ww):paintTo(bb, x, y + px(20))
            text(l3, 10, false, SUB, ww):paintTo(bb, x, y + px(34))
        end)
    end }
    col[#col + 1] = row({ back_b, xr_b, hab_b }, H.small, 3)
    return col, taps
end

-- ---- The big cards (a tile tapped) ---------------------------------------------------------

local CARD_TITLE = {
    book = _("This read"), month = _("Day by Day"), week = _("Weekly pace"), pace = _("Reading pace"),
    reads = _("Your reads"), moments = _("Moments"), chapters = _("Chapters"), back = _("Pages you came back to"),
    xray = _("X-Ray"), habits = _("Habits"), year = _("Your Year"), days = _("Days you read"),
}

-- 2.1.25 (TK): the DAYS tile's card: the calendar a month at a time (greener: more read),
-- with a pill for each month of this read. off: 0 = this month, -1 = the one before, ...
local function daysCard(d, cw, P, off, go)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g = VG:new{ align = "left" }
    local taps = {}
    local endt = d.finished and d.finish_t or d.now
    local et = os.date("*t", endt)
    local rd = d.reads and d.reads[#d.reads]
    local st = os.date("*t", (rd and rd.start) or d.first or endt)
    local back = math.max(0, (et.year - st.year) * 12 + et.month - st.month)
    off = math.max(-back, math.min(0, tonumber(off) or 0))
    local at = os.time{ year = et.year, month = et.month + off, day = 15, hour = 12 }
    local mt = os.date("*t", at)
    local amt, days_m, best = 0, 0, nil
    for k = 1, #d.day_list do local dd = d.day_list[k]
        local t2 = os.date("*t", dd.t)
        if t2.month == mt.month and t2.year == mt.year and dd.pages > 0 then
            amt, days_m = amt + dd.pages, days_m + 1
            if not best or dd.pages > best.pages then best = dd end
        end
    end
    g[#g + 1] = text(os.date("%B %Y", at), 22, true, INK, cw)
    g[#g + 1] = text(T(_("%1 days read  ·  %2"), days_m, amount(d, amt)) .. "  ·  "
        .. T(_("%1 of %2 days since you started"), d.days_read, d.days_since), 13, false, SUB, cw)
    g[#g + 1] = VS:new{ width = px(12) }
    -- 2.1.26 (TK): tap a day for that day's popup
    local hits = {}
    local cal = canvas(cw, px(380), function(bb, x, y, w, h)
        for k in pairs(hits) do hits[k] = nil end
        drawMonth(bb, x, y, w, h, d, P, true, at, hits)
    end)
    g[#g + 1] = cal
    taps[#taps + 1] = { cal, function()
        local pos = Stats._tap_pos
        if not pos then return end
        local _l1 = hits
        for _l1_n = 1, #_l1 do local c = _l1[_l1_n]
            if pos.x >= c.x and pos.x < c.x + c.w and pos.y >= c.y and pos.y < c.y + c.h then
                if c.t <= d.now + 43200 then Stats.showDay(d, c.t) end
                return
            end
        end
    end }
    g[#g + 1] = VS:new{ width = px(6) }
    local each = d.unit == "pct" and _("% read each day")
        or (d.unit == "min" and _("minutes read each day") or _("pages read each day"))
    local key = { each, _("greener: more"), _("outlined: today") }
    if d.finish_t and not d.finished and os.date("%Y%m", d.finish_t) == os.date("%Y%m", at) then
        key[#key + 1] = _("flag: likely finish")
    end
    if best then key[#key + 1] = T(_("★ best day %1 (%2)"), dayShort(best.t), amount(d, best.pages)) end
    g[#g + 1] = caption(table.concat(key, " · "), cw)
    if back > 0 then
        g[#g + 1] = VS:new{ width = px(12) }
        local row = HG:new{ align = "center" }
        local used = 0
        for o = math.max(-back, -5), 0 do
            local label = os.date("%b", os.time{ year = et.year, month = et.month + o, day = 15, hour = 12 })
            local on = o == off
            local fg = INK
            local pills = P.colour and O.Sheet and O.Sheet.pillsColoured and O.Sheet.pillsColoured(P) or false -- 2.1.36
            if on then fg = pills and (P.night and PAPER or INK) or PAPER end
            local t = text(label, 14, true, fg)
            local pw, ph = t:getSize().w + px(30), t:getSize().h + px(12)
            local pc = canvas(pw, ph, function(bb, x, y)
                if on then roundFill(bb, x, y, pw, ph, math.floor(ph / 2), pills and (O.Sheet.solid(P) or P.blue) or P.ink)
                else bb:paintBorder(x, y, pw, ph, px(2), INK, math.floor(ph / 2)) end
                t:paintTo(bb, x + px(15), y + px(6))
            end)
            if used > 0 then row[#row + 1] = HS:new{ width = px(10) } used = used + px(10) end
            row[#row + 1] = pc
            used = used + pw
            if not on then taps[#taps + 1] = { pc, function() go(o) end } end
        end
        g[#g + 1] = HG:new{ align = "center", HS:new{ width = math.max(0, math.floor((cw - used) / 2)) }, row }
    end
    return g, taps
end

-- 2.1.26: a small section heading inside a card: a colour mark and the words
local function secHead(label, k, cw)
    local t = text(label, 11, true, SUB, cw - px(30))
    return canvas(cw, t:getSize().h, function(bb, x, y)
        roundFill(bb, x, y + math.floor(t:getSize().h / 2) - px(3), px(18), px(6), px(3), k)
        t:paintTo(bb, x + px(26), y)
    end)
end

local function bigCard(id, d, rec, cw, P, extra, taps)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g = VG:new{ align = "left" }
    local function add(w) g[#g + 1] = w end
    local function sp(v) add(VS:new{ width = px(v) }) end
    local function trio(list)
        local gap3 = px(16)
        local c3 = math.floor((cw - (#list - 1) * gap3) / #list)
        local r = HG:new{ align = "top" }
        for i, c in ipairs(list) do
            if i > 1 then r[#r + 1] = HS:new{ width = gap3 } end
            r[#r + 1] = VG:new{ align = "left", text(c[1], 12, true, INK, c3),
                canvas(c3, px(5), function(bb, bx, byy) fill(bb, bx, byy + px(1), c3, px(3), c[4] or P.blue) end),
                text(c[2], 22, true, INK, c3), text(c[3], 12, false, SUB, c3) }
        end
        return r
    end
    if id == "book" then
        local who = rec.author
        if (type(who) ~= "string" or who == "") and type(rec.authors) == "table" then who = rec.authors[1] end
        add(text(tostring(rec.display_title or rec.title or ""), 22, true, INK, cw))
        if type(who) == "string" and who ~= "" then add(text(who, 15, false, SUB, cw)) end
        -- 2.1.25 (TK): no chips here: they sit on the stats page's book tile already
        if d.summary then sp(10) add(text(d.summary, 15, true, INK, cw)) end
        local rd = d.reads and d.reads[#d.reads]
        local st = rd and rd.start or d.first
        sp(6)
        add(text((d.finished and T(_("Started %1  ·  Finished %2 (%3 days)"), day(st), day(d.finish_t), d.took_days)
            or T(_("Started %1  ·  reading now, day %2"), day(st), daysBetween(midnight(st), midnight(d.now)) + 1))
            .. ((d.reads and #d.reads > 1) and ("  ·  " .. T(_("read #%1"), #d.reads)) or ""), 14, true, INK, cw))
        sp(12)
        add(columns(d, cw, 26, px(46), P))
        sp(12)
        local fin = d.finished and T(_("Finished %1"), day(d.finish_t))
            or (d.finish_t and (T(_("Done around %1"), day(d.finish_t)) .. ((d.finish_lo and d.finish_hi) and
            ("  ·  " .. dayShort(d.finish_lo) .. " – " .. dayShort(d.finish_hi)) or "")) or "")
        if fin ~= "" then add(text(fin, 15, true, INK, cw)) sp(6) end
        sp(4)
        add(caption(paceLine(d), cw))
        local wl = whenLine(d)
        if wl then sp(4) add(text(wl, 13, false, SUB, cw)) end
        sp(6)
        local facts = {}
        if d.unit == "pct" then
            if d.sources and #d.sources > 0 then facts[1] = T(_("From %1"), table.concat(d.sources, ", ")) end
            if d.fetched then facts[#facts + 1] = T(_("as of %1"), dayShort(d.fetched) .. os.date(" %I:%M %p", d.fetched):gsub(" 0", " ")) end
        else
            facts[1] = T(_("%1 pages on this device"), d.pages)
        end
        add(text(table.concat(facts, "  ·  "), 12, false, SUB, cw))
        -- 2.1.26 (TK, like BookOrbit's web Reading Log): records and where you read it
        sp(14)
        add(secHead(_("RECORDS"), P.gold, cw))
        sp(6)
        local best_day
        local _l2 = d.day_list or {}
        for _l2_n = 1, #_l2 do local dd = _l2[_l2_n]
            if (dd.secs or 0) > 0 and (not best_day or dd.secs > best_day.secs) then best_day = dd end
        end
        local run, best_run, prev = 0, 0, nil
        local _lr1 = d.day_list or {}
        for _lr1_n = 1, #_lr1 do local dd = _lr1[_lr1_n]
            if (dd.secs or 0) > 0 then
                local k = midnight(dd.t)
                run = (prev and daysBetween(prev, k) == 1) and run + 1 or 1
                best_run = math.max(best_run, run)
                prev = k
            end
        end
        local hrs = (d.secs or 0) / 3600
        local pace = hrs > 0.05 and (d.unit == "pct" and (T(_("%1%/h"), math.floor(d.pct * 1000 / hrs + 0.5) / 10))
            or T(_("%1 pages/h"), math.floor(d.pages / hrs + 0.5))) or "–"
        local recs = {
            { _("LONGEST SITTING"), d.longest and durS(d.longest.secs) or "–",
                d.longest and dayShort(d.longest.start) or "", P.blue },
            { _("BEST DAY"), best_day and durS(best_day.secs) or "–", best_day and dayShort(best_day.t) or "",
                P.green },
            { _("LONGEST STREAK"), best_run == 1 and _("1 day") or T(_("%1 days"), best_run), "", P.red },
            { _("PACE"), pace, "", P.gold },
        }
        local rg = px(8)
        local rw = math.floor((cw - 3 * rg) / 4)
        local rt = {}
        for i, r in ipairs(recs) do rt[i] = { text(r[1], 9, true, SUB, rw - px(16)), text(r[2], 17, true, INK,
            rw - px(16)), text(r[3], 10, false, SUB, rw - px(16)) } end
        local rh = rt[1][1]:getSize().h + rt[1][2]:getSize().h + rt[1][3]:getSize().h + px(18)
        add(canvas(cw, rh, function(bb, x, y)
            for i, r in ipairs(recs) do
                local bx = x + (i - 1) * (rw + rg)
                roundFill(bb, bx, y, rw, rh, px(10), P.tile)
                roundFill(bb, bx + px(8), y + px(8), px(14), px(5), px(2), r[4])
                local ty = y + px(16)
                for j = 1, 3 do rt[i][j]:paintTo(bb, bx + px(8), ty) ty = ty + rt[i][j]:getSize().h end
            end
        end))
        if d.unit == "pct" then
            local by, order, total = {}, {}, 0
            local _l3 = d.sessions or {}
            for _l3_n = 1, #_l3 do local se = _l3[_l3_n]
                local k = se.source or _("BookOrbit")
                if not by[k] then by[k] = 0 order[#order + 1] = k end
                by[k] = by[k] + (se.secs or 0)
                total = total + (se.secs or 0)
            end
            if total > 0 and #order > 0 then
                table.sort(order, function(a, b) return by[a] > by[b] end)
                sp(12)
                add(secHead(_("WHERE YOU READ IT"), P.blue, cw))
                sp(6)
                local cols = { P.blue, P.green, P.gold, P.red }
                add(canvas(cw, px(12), function(bb, x, y, w)
                    local bx = x
                    for i, k in ipairs(order) do
                        local sw2 = i == #order and (x + w - bx) or math.floor(w * by[k] / total)
                        if sw2 > 0 then fill(bb, bx, y, sw2, px(12), cols[(i - 1) % #cols + 1]) end
                        bx = bx + sw2
                    end
                end))
                sp(4)
                local bits = {}
                local _l4 = order
                for _l4_n = 1, #_l4 do
                    local k = _l4[_l4_n]
                    bits[#bits + 1] = k .. " " .. math.floor(by[k] * 100 / total + 0.5) .. "%"
                end
                add(text(table.concat(bits, "  ·  "), 12, true, INK, cw))
            end
        end
    elseif id == "month" then
        local mt = os.date("*t", d.finished and d.finish_t or d.now)
        local amt, days_m, best = 0, 0, nil
        for _i, dd in ipairs(d.day_list) do
            local t2 = os.date("*t", dd.t)
            if t2.month == mt.month and t2.year == mt.year then
                amt, days_m = amt + dd.pages, days_m + 1
                if not best or dd.pages > best.pages then best = dd end
            end
        end
        add(text(T(_("%1 over %2 days"), amount(d, amt), days_m), 26, true, INK, cw))
        add(text(T(_("%1 of %2 days read since you started"), d.days_read, d.days_since), 13, false, SUB, cw))
        sp(12)
        add(canvas(cw, px(300), function(bb, x, y, w, h) drawMonth(bb, x, y, w, h, d, P, true) end))
        sp(6)
        local key = { d.unit == "pct" and _("% read each day") or _("pages read each day"), _("greener: more"), _("outlined: today") }
        if d.finish_t and not d.finished then key[#key + 1] = _("flag: likely finish") end
        if best then key[#key + 1] = T(_("best day %1 (%2)"), dayShort(best.t), amount(d, best.pages)) end
        add(caption(table.concat(key, " · "), cw))
    elseif id == "week" then
        local ts, ls, mon = select(3, weekNumbers(d))
        local chg = ls > 0 and math.floor((ts - ls) / ls * 100 + 0.5) or nil
        add(text(T(_("%1 this week"), amount(d, ts)), 26, true, INK, cw))
        add(text(chg and (chg >= 0 and T(_("up %1% on last week (%2)"), chg, amount(d, ls)) or T(_("down %1% on last week (%2)"), -chg, amount(d, ls)))
            or _("nothing last week"), 13, false, SUB, cw))
        sp(14)
        add(canvas(cw, px(130), function(bb, x, y, w, h) drawWeek(bb, x, y, w, h, d, P, true) end))
        sp(4)
        add(caption(_("Bars: this week (green: beat the same day last week) · red tick: last week"), cw, 1))
        sp(14)
        add(text(_("The last five weeks"), 14, true, INK))
        sp(6)
        local weeks, vmax = {}, 0.001
        for k = 4, 0, -1 do
            local s = 0
            for i = 0, 6 do
                local a = d.days[dayKey(mon - k * 7 * 86400 + i * 86400 + 3600)]
                if a then s = s + a.pages end
            end
            weeks[#weeks + 1] = { s = s, t = mon - k * 7 * 86400 }
            vmax = math.max(vmax, s)
        end
        add(canvas(cw, px(80), function(bb, x, y, w, h)
            local gh = h - px(18)
            local slot = w / #weeks
            local bw = math.floor(slot * 0.55)
            for i, wv in ipairs(weeks) do
                local bx = x + math.floor((i - 1) * slot + (slot - bw) / 2)
                local bh = math.floor(wv.s / vmax * (gh - px(14)))
                if wv.s > 0 then roundFill(bb, bx, y + gh - bh, bw, bh, px(3), i == #weeks and P.gold or P.blue) end
                local nt = text(wv.s > 0 and (d.unit == "pct" and pct1(wv.s) or tostring(wv.s)) or "–", 10, true, INK)
                nt:paintTo(bb, bx + math.floor((bw - nt:getSize().w) / 2), y + gh - bh - nt:getSize().h)
                local l = text(dayShort(wv.t), 10, false, SUB)
                l:paintTo(bb, bx + math.floor((bw - l:getSize().w) / 2), y + gh + px(3))
            end
            bb:paintRect(x, y + gh, w, 1, MID)
        end))
    elseif id == "pace" then
        add(text(paceWords(d), 26, true, INK, cw))
        local vs = {}
        if d.usual_pph and d.unit ~= "pct" then
            vs[#vs + 1] = (d.pph >= d.usual_pph * 1.05 and _("faster than your usual") or (d.pph <= d.usual_pph * 0.95 and
                _("slower than your usual") or _("about your usual"))) .. " (" .. math.floor(d.usual_pph + 0.5) .. ")"
        end
        if d.rank_faster and d.rank_n then
            vs[#vs + 1] = d.rank_faster * 2 >= d.rank_n and T(_("faster than %1 of your last %2"), d.rank_faster, d.rank_n)
                or T(_("slower than %1 of your last %2"), d.rank_n - d.rank_faster, d.rank_n)
        end
        if #vs > 0 then add(text(table.concat(vs, "  ·  "), 13, false, SUB, cw)) end
        sp(14)
        add(text(_("Each reading day"), 14, true, INK))
        sp(6)
        local list = d.day_list
        local from = math.max(1, #list - 13)
        local vals, vmax = {}, 0.001
        for i = from, #list do
            local v = list[i].secs > 0 and list[i].pages * 3600 / list[i].secs or 0
            vals[#vals + 1] = { v = v, t = list[i].t }
            vmax = math.max(vmax, v)
        end
        if d.usual_pph and d.unit ~= "pct" then vmax = math.max(vmax, d.usual_pph) end
        vmax = vmax * 1.15
        add(canvas(cw, px(130), function(bb, x, y, w, h)
            local gh = h - px(18)
            local slot = w / math.max(#vals, 7)
            local bw = math.floor(slot * 0.6)
            local function Y(v) return y + gh - math.floor(v / vmax * (gh - px(16))) end
            local hi
            for i, v in ipairs(vals) do if not hi or v.v > vals[hi].v then hi = i end end
            for i, v in ipairs(vals) do
                local bx = x + math.floor((i - 1) * slot + (slot - bw) / 2)
                roundFill(bb, bx, Y(v.v), bw, y + gh - Y(v.v), px(3), i == hi and P.red or P.blue)
                local l = text(os.date("%a", v.t):sub(1, 2), 10, false, SUB)
                l:paintTo(bb, bx + math.floor((bw - l:getSize().w) / 2), y + gh + px(3))
            end
            bb:paintRect(x, y + gh, w, 1, MID)
            dashed(bb, x, Y(d.pph), x + w, Y(d.pph), px(2), P.gold, px(10), px(6))
            local at = text(T(_("this book %1"), d.unit == "pct" and pct1(d.pph) or math.floor(d.pph + 0.5)), 11, true, INK)
            at:paintTo(bb, x + w - at:getSize().w, Y(d.pph) - at:getSize().h - px(2))
            if d.usual_pph and d.unit ~= "pct" then
                dashed(bb, x, Y(d.usual_pph), x + w, Y(d.usual_pph), 1, P.mid, px(4), px(4))
                text(T(_("your usual %1"), math.floor(d.usual_pph + 0.5)), 11, false, SUB):paintTo(bb, x, Y(d.usual_pph) - px(20))
            end
        end))
        sp(14)
        local per_sit = d.pages / math.max(1, #d.sessions)
        add(trio({
            { d.unit == "pct" and _("1%") or _("A PAGE"), T(_("%1 min"), mpp(d.spp / 60)), _("on average"), P.blue },
            { _("A SITTING"), durS(d.secs / math.max(1, #d.sessions)), T(_("longest %1"), durS(d.longest and d.longest.secs or 0)), P.green },
            { _("A SITTING"), amount(d, per_sit), T(_("%1 sittings"), #d.sessions), P.red },
        }))
        if d.hard and d.easy then
            sp(12)
            local nb = #d.trail.b
            local function pr(i)
                local a = d.trail.lo + (d.trail.hi - d.trail.lo) * (i - 1) / nb
                local b = d.trail.lo + (d.trail.hi - d.trail.lo) * i / nb
                return math.floor(a * 100 + 0.5) .. "–" .. math.floor(b * 100 + 0.5) .. "%"
            end
            add(caption(T(d.unit == "pct" and _("Slowest going %1 of the book (%2 min per 1%), quickest %3 (%4).")
                or _("Slowest going %1 of the book (%2 min a page), quickest %3 (%4)."), pr(d.hard), mpp(d.trail.b[d.hard]),
                pr(d.easy), mpp(d.trail.b[d.easy])), cw))
        end
    elseif id == "reads" then
        local reads = d.reads or {}
        add(text(#reads == 1 and _("Your first read") or T(_("Read %1 times"), #reads), 26, true, INK, cw))
        if #reads > 1 then
            local prev = reads[#reads - 1]
            add(text(T(_("First started %1 · %2 days between the last two"), day(reads[1].start),
                daysBetween(midnight(prev.done_t or prev.last), midnight(reads[#reads].start))), 13, false, SUB, cw))
        end
        sp(12)
        local ords = { _("1st read"), _("2nd read"), _("3rd read") }
        for i, r in ipairs(reads) do
            local nowr = i == #reads and not d.finished
            local fin = r.done_t
            local days = daysBetween(midnight(r.start), midnight(fin or (nowr and d.now or r.last))) + 1
            add(text(ords[i] or T(_("Read %1"), i), 15, true, INK))
            add(text(nowr and T(_("%1 – now · day %2 · %3 so far"), day(r.start), days, math.floor(d.pct * 100 + 0.5) .. "%")
                or (T(_("%1 – %2 · %3 days · %4"), day(r.start), day(fin or r.last), days, durS(r.secs))
                .. (fin and "" or ("  ·  " .. T(_("stopped at %1"), math.floor(r.hi * 100 + 0.5) .. "%")))), 13, false, INK, cw))
            add(canvas(cw, px(16), function(bb, x, y, w)
                roundFill(bb, x, y + px(4), w, px(8), px(4), P.track)
                roundFill(bb, x, y + px(4), math.max(px(8), math.floor(w * (nowr and d.pct or r.hi))), px(8), px(4),
                    fin and P.green or (nowr and P.gold or P.red))
            end))
            sp(8)
        end
        add(caption(_("Green: finished · gold: this read · red: stopped. The other tiles are about this read."), cw, 1))
    elseif id == "moments" then
        local all = moments(d, extra)
        local mdots = { turner = P.green, sitting = P.red, record = P.blue, clicked = P.gold, comeback = P.blue, slog = P.red, words = P.green, hotspot = P.gold,
            xmet = P.blue, xlook = P.red, xtime = P.green, xplace = P.blue, reward = P.gold, glimpse = P.teal or P.blue }
        -- 2.1.23: your reading, then the story (X-Ray), then rewards (ReadMastery)
        local mom = {}
        for _i, m in ipairs(all) do if not m.group then mom[#mom + 1] = m end end
        local groups = { { nil, mom } }
        local story, rewards = {}, {}
        for _i, m in ipairs(all.more or {}) do
            if m.group == "story" then story[#story + 1] = m else rewards[#rewards + 1] = m end
        end
        if #story > 0 or #rewards > 0 then groups[1][1] = _("YOUR READING") end
        if #story > 0 then groups[#groups + 1] = { _("IN THE STORY · X-RAY"), story } end
        if #rewards > 0 then groups[#groups + 1] = { _("REWARDS · READMASTERY"), rewards } end
        local rewards_n = all.more and all.more.rewards_n or 0
        mom = {}
        for gi, gr in ipairs(groups) do
            if gr[1] then mom[#mom + 1] = { head = gr[1], first = gi == 1 } end
            for _i, m in ipairs(gr[2]) do mom[#mom + 1] = m end
        end
        for _i, m in ipairs(mom) do
          if m.head then
            if not m.first then sp(8) end
            add(text(m.head, 11, true, SUB))
            sp(4)
          else
            local t1 = text(m[2], 12, true, SUB)
            local t2 = text(m[3], 15, true, INK, cw - px(16))
            local hh = t1:getSize().h + t2:getSize().h + px(10)
            add(canvas(cw, hh, function(bb, x, y)
                roundFill(bb, x, y + px(4), px(6), hh - px(12), px(3), mdots[m[1]] or P.blue)
                t1:paintTo(bb, x + px(16), y + px(2))
                t2:paintTo(bb, x + px(16), y + t1:getSize().h + px(2))
            end))
          end
        end
        -- 2.1.26 (TK): every ReadMastery reward from this book, and ReadMastery itself
        if rewards_n > 0 and O.XRay and O.XRay.showRewards then
            sp(10)
            local lab = text(T(_("All %1 rewards  ›"), rewards_n), 14, true,
                P.colour and (P.night and PAPER or INK) or PAPER)
            local bw, bh = lab:getSize().w + px(30), lab:getSize().h + px(14)
            local b = canvas(bw, bh, function(bb, x, y)
                roundFill(bb, x, y, bw, bh, math.floor(bh / 2), P.colour and P.gold or P.ink)
                lab:paintTo(bb, x + px(15), y + px(7))
            end)
            add(b)
            if taps then taps[#taps + 1] = { b, function() O.XRay.showRewards(d) end } end
        end
    elseif id == "chapters" then
        local chs = extra and extra.chapters or {}
        local top_c, maxs = nil, 0
        for i, c in ipairs(chs) do if c.secs > maxs then maxs, top_c = c.secs, i end end
        maxs = math.max(maxs, 1)
        local cur = d.chapter_now or 1
        if top_c then
            add(text(T(_("Longest: %1"), chs[top_c].title), 24, true, INK, cw))
            add(text(T(_("%1 over %2 pages · %3 min a page"), durS(chs[top_c].secs), chs[top_c].b - chs[top_c].a + 1,
                mpp(chs[top_c].secs / math.max(1, chs[top_c].pages) / 60)), 13, false, SUB, cw))
        end
        if chs[cur] and not d.finished then
            sp(8)
            local left_p = chs[cur].b - d.page_now
            add(text(T(_("Now in %1 (%2 of %3) · %4 pages, about %5 left"), chs[cur].title, cur, #chs, left_p,
                durS(left_p * (d.spp_now or d.spp))), 14, true, INK, cw))
        end
        sp(12)
        -- 2.1.23: who leads each chapter (X-Ray's mentions), beside its time
        local leads = {}
        local sm_ch = O.XRay and select(2, pcall(O.XRay.summary, d, extra))
        if type(sm_ch) == "table" then leads = O.XRay.leads(sm_ch) end
        local rowh = px(22)
        local show_n = math.min(#chs, 30)
        local first_i = math.max(1, math.min(cur - 10, #chs - show_n + 1))
        local lab_w = math.floor(cw * 0.36)
        add(canvas(cw, show_n * rowh, function(bb, x, y, w)
            for k = 0, show_n - 1 do
                local i = first_i + k
                local c = chs[i]
                local ry = y + k * rowh
                text(c.title, 11, i == cur, c.secs > 0 and INK or SUB, lab_w - px(8)):paintTo(bb, x, ry + px(2))
                local bw = math.floor((w - lab_w - px(80)) * c.secs / maxs)
                if c.secs > 0 then
                    roundFill(bb, x + lab_w, ry + px(4), math.max(px(3), bw), rowh - px(9), px(3), i == top_c and P.red or P.blue)
                    local lead = leads[i]
                    text(durS(c.secs) .. (lead and ("  ·  " .. lead.name) or ""), 10, i == top_c, INK, w - lab_w - bw - px(10))
                        :paintTo(bb, x + lab_w + bw + px(6), ry + px(3))
                else
                    text(c.a > d.page_now and _("ahead") or _("not read here"), 10, false, SUB):paintTo(bb, x + lab_w, ry + px(3))
                end
                if i == cur and not d.finished then disc(bb, x + w - px(8), ry + math.floor(rowh / 2), px(5), P.gold) end
            end
        end))
        sp(6)
        add(caption(next(leads) and _("Your time in each chapter, and who comes up most in it (X-Ray) · gold dot: where you are.")
            or _("Your time in each chapter · gold dot: where you are. Chapters are saved when you close the book."), cw))
    elseif id == "back" then
        local list = d.returned or {}
        -- 2.1.23: who's on each page (X-Ray)
        local sm_back = O.XRay and select(2, pcall(O.XRay.summary, d, extra))
        if type(sm_back) ~= "table" then sm_back = nil end
        local r1 = list[1]
        if r1 then
            add(text(T(_("Page %1, %2 times"), r1.p, r1.visits), 26, true, INK, cw))
            add(text(T(_("%1 there in all · %2 of the book"), durS(r1.secs), math.floor(r1.p / d.total * 100 + 0.5) .. "%"), 13, false, SUB, cw))
        end
        sp(14)
        local rowh = px(30)
        local maxv = r1 and math.min(r1.visits, 10) or 1
        add(canvas(cw, #list * rowh, function(bb, x, y, w)
            for i, r in ipairs(list) do
                local ry = y + (i - 1) * rowh
                text(T(_("p. %1"), r.p), 14, true, INK):paintTo(bb, x, ry + px(3))
                local x0 = x + px(90)
                for k = 1, math.min(r.visits, 10) do disc(bb, x0 + (k - 1) * px(20) + px(7), ry + math.floor(rowh / 2), px(7), i == 1 and P.red or P.gold) end
                local who = sm_back and O.XRay.onPage(sm_back, r.p) or {}
                local note = T(_("%1 times · %2"), r.visits, durS(r.secs)) .. (#who > 0 and ("  ·  " .. table.concat(who, ", ", 1, math.min(2, #who))) or "")
                text(note, 12, false, SUB, w - px(150) - (x0 - x) - maxv * px(20) - px(16)):paintTo(bb, x0 + maxv * px(20) + px(12), ry + px(5))
                local bw = px(140)
                local tx = x + w - bw
                bb:paintRect(tx, ry + math.floor(rowh / 2), bw, 1, MID)
                disc(bb, tx + math.floor(bw * r.p / d.total), ry + math.floor(rowh / 2), px(4), P.ink)
            end
        end))
        sp(6)
        add(caption(_("A dot for each sitting that came back to the page · right: where it is in the book"), cw))
    elseif id == "xray" then
        local xr = extra and extra.xray or { people = {}, places = {}, met_people = 0, met_places = 0, known = 0 }
        local p1 = xr.people[1]
        add(text(p1 and T(_("Most with %1: %2"), p1.name, durS(p1.secs)) or _("Who you spent time with"), 24, true, INK, cw))
        add(text(T(_("You've met %1 people and %2 places so far (up to your page)"), xr.met_people, xr.met_places), 13, false, SUB, cw))
        sp(12)
        local ppl = {}
        for i = 1, math.min(8, #xr.people) do ppl[i] = xr.people[i] end
        local cols = { P.red, P.blue, P.green, P.gold }
        local rowh = px(24)
        add(canvas(cw, #ppl * rowh, function(bb, x, y, w)
            for i, pp in ipairs(ppl) do
                local ry = y + (i - 1) * rowh
                text(pp.name, 13, i == 1, INK, px(150)):paintTo(bb, x, ry + px(2))
                local bw = math.floor((w - px(240)) * pp.secs / p1.secs)
                roundFill(bb, x + px(160), ry + px(5), math.max(px(3), bw), rowh - px(10), px(3), cols[(i - 1) % 4 + 1])
                text(durS(pp.secs), 11, true, INK):paintTo(bb, x + px(166) + bw, ry + px(3))
            end
        end))
        if #xr.places > 0 then
            sp(10)
            local pl = {}
            for i = 1, math.min(4, #xr.places) do pl[i] = xr.places[i].name .. " " .. durS(xr.places[i].secs) end
            add(text(T(_("Where the book took you: %1"), table.concat(pl, " · ")), 13, true, INK, cw))
        end
        sp(6)
        add(caption(p1 and _("Your reading time on the pages each one is mentioned on, from X-Ray's lists, up to your page.")
            or _("X-Ray hasn't found mentions yet: open a character's mentions in X-Ray and they show up here."), cw))
    elseif id == "habits" then
        local hb = habits(d)
        local tot = math.max(1, #d.sessions)
        add(text(_("Quick dips or deep dives"), 15, true, INK))
        sp(6)
        add(canvas(cw, px(46), function(bb, x, y, w)
            local segs = { { hb.dips, P.blue, _("under 10m") }, { hb.mids, P.green, _("10–30m") }, { hb.dives, P.red, _("30m+") } }
            local xx = x
            for _i, sg in ipairs(segs) do
                local sw2 = math.floor(w * sg[1] / tot)
                if sw2 > 0 then
                    fill(bb, xx, y, sw2, px(18), sg[2])
                    xx = xx + sw2
                end
            end
            -- 2.1.25 (TK: cut off): the counts as a key under the bar, one after another,
            -- not under each piece (a thin last piece ran its words off the edge)
            local lx = x
            for k = 1, #segs do local sg = segs[k]
                if sg[1] > 0 then
                    local t = text(T(_("%1 %2"), sg[1], sg[3]), 11, true, INK)
                    disc(bb, lx + px(5), y + px(22) + math.floor(t:getSize().h / 2), px(5), sg[2])
                    t:paintTo(bb, lx + px(14), y + px(22))
                    lx = lx + px(14) + t:getSize().w + px(18)
                end
            end
        end))
        sp(10)
        if hb.best and hb.worst and hb.best[1] ~= hb.worst[1] and d.unit ~= "pct" then
            add(text(T(_("Quickest in the %1: %2 pages an hour (%3 in the %4)"), hb.best[1], math.floor(hb.best[2] + 0.5),
                math.floor(hb.worst[2] + 0.5), hb.worst[1]), 14, true, INK, cw))
            sp(6)
        end
        add(text(T(_("Weekdays %1 · weekends %2"), durS(hb.weekday), durS(hb.weekend)) .. "  ·  "
            .. (hb.weekend > hb.weekday and _("a weekend book") or _("a weekday book")), 14, true, INK, cw))
        sp(6)
        add(text(hb.late == 0 and _("Never past 11 PM") or (hb.late == 1 and _("Read past 11 PM once") or T(_("Read past 11 PM %1 times"), hb.late)), 14, true, INK, cw))
        if d.when then
            sp(6)
            add(text(T(_("Mostly in the %1, around %2"), d.when, hour12(d.peak)), 14, true, INK, cw))
        end
        if d.longer_than and d.others_n then
            sp(10)
            add(text(T(_("Longer than %1 of your last %2 books"), d.longer_than, d.others_n), 13, false, SUB, cw))
        end
    end
    return g
end

local ctx -- the page's book (2.1.10): { rec, kobo = this Kobo's data, on_back, close_all }

Stats.pluginOn = pluginOn
-- 2.1.23: a book's numbers and chapters for the X-Ray popup opened from More or a chip
function Stats.xrayFor(rec, path, pct)
    -- where you are: what the book's own settings say (so nothing past it shows)
    if not pct and type(path) == "string" then
        pcall(function()
            local DS = require("docsettings")
            if DS.hasSidecarFile and not DS:hasSidecarFile(path) then return end
            pct = tonumber(DS:open(path):readSetting("percent_finished"))
        end)
    end
    if not pct and rec and tonumber(rec.bookorbit_pct) then pct = tonumber(rec.bookorbit_pct) end
    local d = Stats.forBook(rec, path, pct)
    if not d then return nil end
    local ex = { chapters = (select(2, pcall(chapters, d))) }
    if type(ex.chapters) ~= "table" then ex.chapters = nil end
    return d, ex
end

local card_shown -- 2.1.20: a tile's card, a popup over the page
local function closeCard(refresh)
    if not card_shown then return end
    local c = card_shown
    card_shown = nil
    UIManager:close(c, refresh ~= false and (O.flash and O.flash("stats_change") or "full") or nil, refresh ~= false and c.frame_dimen or nil)
end
local function closePage(refresh)
    closeCard(false)
    if not shown then return end
    local p = shown
    shown, ctx = nil, nil
    UIManager:close(p, refresh ~= false and (O.flash and O.flash("stats") or "full") or nil)
    local cb = on_closed
    on_closed = nil
    if cb and refresh ~= false then cb() end
end

function Stats.isShown() return shown ~= nil end
function Stats.close(refresh) closePage(refresh) end
-- 2.1.14: a book opening (a highlight, X-Ray) closes the page
function Stats.closeForBook() if shown then closePage(false) end end

-- ---- This Kobo | BookOrbit (2.1.10) -----------------------------------------------------

local render -- below

local function canBookOrbit(rec)
    return tonumber(rec and rec.bookorbit_id) ~= nil and type(O.boApiClient) == "function"
        and type(O.Collections) == "table" and type(O.Collections.get) == "function"
end

local function orbitKey(rec) return "orbit:" .. tonumber(rec.bookorbit_id) end

local function orbitSaved(rec)
    local st = openStore()
    local f = st and st:readSetting(orbitKey(rec))
    return (type(f) == "table" and f.v == FACTS_V and f.unit == "pct") and f or nil
end

local function orbitData(f)
    local d = Stats.derive(f, { pct = f.reached, finished = ctx and ctx.kobo and ctx.kobo.finished or nil })
    d.extras = {} -- highlights, bookmarks, X-Ray and Glimpse are this Kobo's
    return d
end

-- every session for the book (100 a page, at most 10 pages), then the facts, saved
local function fetchOrbit(rec, done, label)
    local id = tonumber(rec.bookorbit_id)
    local client = O.boApiClient()
    if not client then return done(nil, "BookOrbit isn't signed in") end
    local items, page = {}, 1
    local function one()
        local started = O.Collections.get(client, label or _("Loading BookOrbit's sessions…"),
            "/books/" .. id .. "/sessions?page=" .. page .. "&pageSize=100&sortBy=startedAt&sortDir=asc", function(body, err)
                if type(body) ~= "table" or type(body.items) ~= "table" then return done(nil, err) end
                for _i, it in ipairs(body.items) do items[#items + 1] = it end
                local total = tonumber(body.total) or #items
                if #items < total and #body.items > 0 and page < 10 then page = page + 1 return one() end
                local f = Stats.boFacts(items)
                if f then
                    f.fetched = os.time()
                    pcall(saveFacts, orbitKey(rec), f, nil)
                end
                if O.cfg and O.cfg.diagnostics then
                    O.logger.info(O.TAG, "BookOrbit stats: book", id, #items, "sessions",
                        f and ("-> saved for offline (" .. tostring(type(f.days) == "table" and #f.days or "?") .. " days)") or "-> nothing to show")
                end
                done(f, f == nil and _("no reading sessions for this book") or nil)
            end)
        if not started then done(nil, "BookOrbit isn't installed") end
    end
    one()
end

-- 2.1.33 (TK): Settings › BookOrbit Account › Save All Stats For Offline. Only by hand:
-- every book you've read in BookOrbit (its sessions) and your years, fetched now with
-- Wi-Fi on and saved, so the stats open offline without being looked at first.
-- done(books_saved, years_saved, err)
function Stats.saveAllOffline(done)
    done = done or function() end
    if not (type(O.isWifiOn) == "function" and O.isWifiOn()) then return done(nil, nil, _("Turn Wi-Fi on first.")) end
    if type(O.boApiClient) ~= "function" or not O.boApiClient() then return done(nil, nil, _("BookOrbit isn't signed in.")) end
    local okG, books = pcall(function() return O.Genres and O.Genres.library() end)
    local recs = {}
    for _i, r in ipairs(okG and type(books) == "table" and books or {}) do
        if type(r) == "table" and canBookOrbit(r) and (r.last_read_time or (tonumber(r.bookorbit_pct) or 0) > 0
                or ({ read = true, skimmed = true, reading = true, rereading = true, on_hold = true,
                    abandoned = true })[tostring(r.bookorbit_status or ""):lower()]) then
            recs[#recs + 1] = r
        end
    end
    local saved, years, i = 0, 0, 0
    local R = rings()
    local function nextYear(y, left)
        if not (R and R.fetchYear) or left == 0 then return done(saved, years) end
        local ok = pcall(R.fetchYear, y, function(Y, err)
            if err == "cancelled" then return done(saved, years, err) end
            if Y and ((Y.total or 0) > 0 or #(Y.books or {}) > 0) then
                years = years + 1
                return nextYear(y - 1, left - 1)
            end
            done(saved, years)
        end, T(_("Saving your years for offline… %1"), y))
        if not ok then done(saved, years) end
    end
    local function nextBook()
        i = i + 1
        if i > #recs then return nextYear(tonumber(os.date("%Y")), 6) end
        fetchOrbit(recs[i], function(f, err)
            if f then saved = saved + 1 end
            if err == "cancelled" then return done(saved, years, err) end
            nextBook()
        end, T(_("Saving stats for offline… %1 of %2"), i, #recs))
    end
    nextBook()
end

-- the switch: This Kobo, or BookOrbit (fetched now; the last fetch if that fails)
local function pick(src)
    if not ctx then return end
    ctx.wake = nil -- 2.1.30: picked by hand
    if src == "kobo" then
        -- 2.1.17: a book that was never read on this Kobo has only BookOrbit's side
        if not ctx.kobo then
            UIManager:show(W("infomessage"):new{ text = _("No reading on this device for this book yet: only BookOrbit's."), timeout = 3 })
            return
        end
        O.cfg.stats_source = "kobo"
        pcall(O.saveConfig)
        return render(ctx.kobo, "kobo")
    end
    fetchOrbit(ctx.rec, function(f, err)
        if not ctx then return end
        f = f or orbitSaved(ctx.rec)
        if not f then
            UIManager:show(W("infomessage"):new{ text = T(_("Couldn't load BookOrbit's reading sessions for this book:\n%1"),
                tostring(err or "?")), timeout = 4 })
            return
        end
        O.cfg.stats_source = "bookorbit"
        pcall(O.saveConfig)
        render(orbitData(f), "bookorbit")
    end)
end

-- 2.1.13: Your Year (all books) on this side: This Kobo from its statistics, BookOrbit
-- from the server (saved; fetched again after 30 minutes with Wi-Fi on)
function Stats.openYear(d, src, y)
    local R = rings()
    if not (ctx and R) then return end
    local function show(Y, err)
        if not ctx then return end
        if not Y then
            UIManager:show(W("infomessage"):new{ text = src == "bookorbit"
                and T(_("Couldn't load your year from BookOrbit:\n%1"), tostring(err or "?"))
                or T(_("No reading in %1 on this device."), y), timeout = 4 })
            return
        end
        ctx.year = Y
        render(d, src, "year")
    end
    local ok, err = pcall(R.loadYear, src == "bookorbit" and "bookorbit" or "kobo", y, show)
    if not ok then O.logger.warn(O.TAG, "Your Year:", tostring(err)) end
end

-- 2.1.28 (TK): All Time (all your reading) on this side; the side picked last time
local function allBookOrbit()
    if type(O.boApiClient) ~= "function" or type(O.Collections) ~= "table"
        or type(O.Collections.get) ~= "function" then return false end
    local R = rings()
    if R and R.yearSaved("bookorbit", tonumber(os.date("%Y"))) then return true end
    return type(O.isWifiOn) == "function" and O.isWifiOn() and O.boApiClient() ~= nil
end

function Stats.showAll(src)
    if not ctx then return end
    local okA, AT = pcall(require, "orbitshelf_alltime")
    if not okA then O.logger.warn(O.TAG, "All Time:", tostring(AT)) return end
    if not src then
        local bo = O.cfg and O.cfg.stats_source == "bookorbit" and not ctx.wake and allBookOrbit()
        src = bo and "bookorbit" or "kobo"
    end
    ctx.all = ctx.all or {}
    local function go(A, err)
        if not ctx then return end
        if not A and src == "kobo" and not ctx.all_tried_bo and allBookOrbit() then
            ctx.all_tried_bo = true
            return Stats.showAll("bookorbit")
        end
        if not A then
            UIManager:show(W("infomessage"):new{ text = src == "bookorbit"
                and T(_("Couldn't load your reading from BookOrbit:\n%1"), tostring(err or "?"))
                or _("No reading on this device yet."), timeout = 4 })
            if not shown then ctx = nil end
            return
        end
        ctx.all[src] = A
        ctx.view = "all"
        render(nil, src)
    end
    if ctx.all[src] then return go(ctx.all[src]) end
    AT.load(src, go)
end

-- 2.1.28 (TK): Stats again from All Time (the book's numbers, the side picked last time)
local function backToStats()
    if not ctx then return end
    if not ctx.has_stats then
        UIManager:show(W("infomessage"):new{
            text = _("No reading stats for this book yet (on this device or saved from BookOrbit)."), timeout = 3 })
        return
    end
    O.stats_after_wake = ctx.wake -- 2.1.30: still Device first until a side is picked
    Stats.show(ctx.rec, ctx.kobo, ctx.on_back, ctx.close_all, { more = ctx.more, has_stats = ctx.has_stats })
end

-- the stats page over the Book Page (on_back: the Book Page's redraw if it changed
-- underneath; close_all: the Book Page's own close), on the side picked last time (BookOrbit: the
-- saved fetch, fetched again when it's over 30 minutes old and Wi-Fi is on)
-- 2.1.17: can the stats page open for this book without this Kobo's numbers (BookOrbit's,
-- saved for the book or fetched now)?
function Stats.hasBookOrbit(rec)
    if not canBookOrbit(rec) then return false end
    if orbitSaved(rec) then return true end
    return type(O.isWifiOn) == "function" and O.isWifiOn() and O.boApiClient() ~= nil
end

function Stats.show(rec, d, on_back, close_all, opts)
    opts = opts or {}
    ctx = { rec = rec, kobo = d, on_back = on_back, close_all = close_all, more = opts.more,
        view = opts.view or "stats",
        has_stats = opts.has_stats ~= false and (d ~= nil or canBookOrbit(rec)), wake = O.stats_after_wake }
    O.stats_after_wake = nil
    -- 2.1.28 (TK): All Time from the Book Page's Book | Stats | All Time
    if ctx.view == "all" then return Stats.showAll() end
    -- 2.1.17 (TK): not read on this Kobo (not downloaded): BookOrbit's side, saved per book
    -- for offline (orbit:<id>, fetched again after 30 minutes with Wi-Fi on)
    if not d then
        if not canBookOrbit(rec) then return end
        local f = orbitSaved(rec)
        local wifi = type(O.isWifiOn) == "function" and O.isWifiOn()
        if f and not (wifi and os.time() - (tonumber(f.fetched) or 0) > 1800) then return render(orbitData(f), "bookorbit") end
        if not wifi and not f then
            ctx = nil
            UIManager:show(W("infomessage"):new{ text = _("No stats saved for this book yet. Turn Wi-Fi on to get BookOrbit's."), timeout = 4 })
            return
        end
        return fetchOrbit(rec, function(f2, err)
            if not ctx then return end
            f2 = f2 or f
            if f2 then return render(orbitData(f2), "bookorbit") end
            ctx = nil
            UIManager:show(W("infomessage"):new{ text = T(_("Couldn't load BookOrbit's reading sessions for this book:\n%1"),
                tostring(err or "?")), timeout = 4 })
        end)
    end
    if O.cfg and O.cfg.stats_source == "bookorbit" and canBookOrbit(rec) and not ctx.wake then
        local f = orbitSaved(rec)
        local wifi = type(O.isWifiOn) == "function" and O.isWifiOn()
        if f and not (wifi and os.time() - (tonumber(f.fetched) or 0) > 1800) then return render(orbitData(f), "bookorbit") end
        if wifi then
            return fetchOrbit(rec, function(f2)
                f2 = f2 or f
                if f2 then render(orbitData(f2), "bookorbit") else render(d, "kobo") end
            end)
        end
        if f then return render(orbitData(f), "bookorbit") end
    end
    render(d, "kobo")
end

-- what this Kobo knows besides the numbers: chapters, words looked up, X-Ray (once per opening)
local function extraFor(d, src, rec)
    if src ~= "kobo" or not d or d.alltime then return nil end
    if not ctx.extra then
        ctx.extra = {}
        local okC, chs = pcall(chapters, d)
        ctx.extra.chapters = okC and chs or nil
        local okW, ws = pcall(words, rec.title or rec.display_title)
        ctx.extra.words = okW and ws or nil
        local okX, xr = pcall(xray, d)
        ctx.extra.xray = okX and xr or nil
    end
    return ctx.extra
end

-- 2.1.28 (TK): All Time's tiles, and where each one goes
local function allDashboard(A, src, iw, room, P)
    local AT = require("orbitshelf_alltime")
    local R = rings()
    local pd
    local nav = {}
    local function sub(filter, N)
        if not filter then return { books = A.books, finished = A.finished, total = A.total, src = A.src } end
        local Y = { books = {}, finished = {}, total = 0, src = A.src }
        for i = 1, #A.books do
            local fin = N.fin[i] ~= nil
            local b = A.books[i]
            local reading = not fin and (b.secs or 0) >= 1800
                and (b.last or b.to or b.from or 0) >= os.time() - 30 * 86400
            if (filter == "finished" and fin) or (filter == "reading" and reading) then
                Y.books[#Y.books + 1] = b
                Y.total = Y.total + (b.secs or 0)
                if fin then Y.finished[#Y.finished + 1] = { book = #Y.books, t = N.fin[i] } end
            end
        end
        return Y
    end
    local N
    function nav.year() Stats.openYear(pd, src, tonumber(os.date("%Y"))) end
    -- 2.1.35 (TK): Time opens the calendar in time (each day's minutes), Days in pages
    local pd_time
    function nav.days(kind)
        if kind ~= "time" or pd.unit == "min" then return render(pd, src, "days") end
        if not pd_time then
            pd_time = {}
            for k, v in pairs(pd) do pd_time[k] = v end
            local days, list = {}, {}
            for k, dd in pairs(pd.days) do
                days[k] = { pages = math.floor((dd.secs or 0) / 60 + 0.5), secs = dd.secs, t = dd.t }
                list[#list + 1] = days[k]
            end
            table.sort(list, function(a, c) return a.t < c.t end)
            pd_time.days, pd_time.day_list, pd_time.unit = days, list, "min"
        end
        render(pd_time, src, "days")
    end
    -- 2.1.30 (TK): a book tapped on the hero's line or in Books: its popup
    function nav.popup(i)
        if R then R.bookPopup({ books = A.books, finished = A.finished, total = A.total, src = A.src }, i, nil) end
    end
    function nav.books(filter)
        if not R then return end
        local Y = sub(filter, N)
        local title = filter == "finished" and _("Books finished")
            or (filter == "reading" and _("Reading now") or _("All your books"))
        R.bookList(Y, function(i) R.bookPopup(Y, i, nil) end, title)
    end
    function nav.moments(list)
        local rows = {}
        for i = 1, #list do rows[i] = { list[i][2], nil, "gold" } end
        AT.listSheet(_("Moments"), rows)
    end
    -- 2.1.29 (TK): an author's or a genre's books, each opening its popup
    local function booksOf(list, title)
        if not R then return end
        local Y = { books = {}, finished = {}, total = 0, src = A.src }
        for k = 1, #list do
            local i = list[k]
            local b = A.books[i]
            if b then
                Y.books[#Y.books + 1] = b
                Y.total = Y.total + (b.secs or 0)
                if N.fin[i] then Y.finished[#Y.finished + 1] = { book = #Y.books, t = N.fin[i] } end
            end
        end
        R.bookList(Y, function(bi) R.bookPopup(Y, bi, nil) end, title)
    end
    local function nb(n2) return n2 == 1 and _("1 book") or T(_("%1 books"), n2) end
    function nav.authors(au)
        local rows = {}
        for i = 1, math.min(16, #au) do
            local a = au[i]
            rows[i] = { a.name, ((a.secs or 0) >= 60 and (durS(a.secs) .. " · ") or "") .. nb(a.n), "gold",
                function() booksOf(a.books, a.name) end }
        end
        AT.listSheet(_("Authors"), rows, _("tap an author for their books"))
    end
    function nav.genres(gl)
        local rows = {}
        for i = 1, math.min(16, #gl) do
            local g2 = gl[i]
            rows[i] = { g2.name, T(_("%1 · %2 finished"), nb(g2.n), g2.fin), "purple",
                function() booksOf(g2.books, g2.name) end }
        end
        AT.listSheet(_("Genres"), rows, _("from BookOrbit · tap a genre for its books"))
    end
    function nav.habits(h)
        local rows = {}
        for i = 1, #h.list do rows[i] = { h.list[i].name,
            math.floor(h.list[i].secs / h.total * 100 + 0.5) .. "% · " .. durS(h.list[i].secs), "green" } end
        AT.listSheet(_("Habits"), rows)
    end
    local col, taps
    col, taps, N = AT.dashboard(A, iw, room, P, nav)
    pd = AT.pseudo(A, N)
    return col, taps
end

local showCard -- below
render = function(d, src, card)
    -- 2.1.20 (TK): a tile's card is a popup sized to fit, over the page (✕ closes just it)
    if card then return showCard(d, src, card) end
    closeCard(false)
    local rec, close_all = ctx.rec, ctx.close_all
    local Device = require("device")
    local GestureRange = require("ui/gesturerange")
    local P = palette()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local pad = px(14)
    local iw = sw - 2 * pad
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local widget = W("container/inputcontainer"):new{ dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }, covers_fullscreen = true,
        orbitshelf_perf = "stats page" } -- 2.1.15: diagnostics times its first draw
    local all = ctx.view == "all"
    local A = all and ctx.all and ctx.all[src] or nil
    local extra = (not all) and extraFor(d, src, rec) or nil
    local function goBack() closePage() end
    -- 2.1.28 (TK): the top bar is the Book Page's: ‹ OrbitShelf · Book | Stats | All Time · More ▾ · ✕
    -- (More ▾ only on Stats: All Time isn't about one book)
    local top_taps = {}
    local top
    do
        local function closeAll() closePage(false) if close_all then close_all() end end
        local bh = px(40)
        local bt = text("‹ " .. _("OrbitShelf"), 15, true, INK)
        local back = canvas(bt:getSize().w + px(12), bh, function(bb, x0, y0)
            bt:paintTo(bb, x0 + px(2), y0 + math.floor((bh - bt:getSize().h) / 2))
        end)
        local xt = text("\u{2715}", 20, true, INK)
        local xb = canvas(xt:getSize().w + px(16), bh, function(bb, x0, y0)
            xt:paintTo(bb, x0 + px(8), y0 + math.floor((bh - xt:getSize().h) / 2))
        end)
        local seg_w3, seg_h3 = px(270), px(34)
        local third = math.floor(seg_w3 / 3)
        local on_k = all and 3 or 2
        -- 2.1.36 (TK): Look › Pill Colours: off, the picked one is black with white words
        local PILLS = P.colour and O.Sheet and O.Sheet.pillsColoured and O.Sheet.pillsColoured(P) or false
        local ON = PILLS and (P.night and PAPER or INK) or PAPER
        local labs = { text(_("Book"), 14, true, INK), text(_("Stats"), 14, true,
            on_k == 2 and ON or (ctx.has_stats and INK or SOFT)),
            text(_("All Time"), 14, true, on_k == 3 and ON or INK) }
        local seg3 = canvas(seg_w3, seg_h3, function(bb, x0, y0)
            roundFill(bb, x0, y0, seg_w3, seg_h3, math.floor(seg_h3 / 2), P.colour and P.cell or grey(NIGHT))
            roundFill(bb, x0 + (on_k - 1) * third + px(3), y0 + px(3),
                third - px(6) + (on_k == 3 and (seg_w3 - 3 * third) or 0),
                seg_h3 - px(6), math.floor(seg_h3 / 2) - px(3),
                PILLS and (O.Sheet.solid(P) or P.blue) or P.ink)
            for k = 1, 3 do
                local t = labs[k]
                t:paintTo(bb, x0 + math.floor(third * (k - 0.5) - t:getSize().w / 2),
                    y0 + math.floor((seg_h3 - t:getSize().h) / 2))
            end
        end)
        local more
        if not all and ctx.more then
            local mt = text(_("More ▾"), 13, true, INK)
            local mw, mh = mt:getSize().w + px(30), px(34)
            more = canvas(mw, mh, function(bb, x0, y0)
                bb:paintBorder(x0, y0, mw, mh, px(2), P.colour and P.gold.v or INK, math.floor(mh / 2))
                mt:paintTo(bb, x0 + px(15), y0 + math.floor((mh - mt:getSize().h) / 2))
            end)
        end
        local right_w = (more and (more:getSize().w + px(8)) or 0) + xb:getSize().w
        local mid_l = math.max(0, math.floor((iw - seg_w3) / 2) - back:getSize().w)
        top = HG:new{ align = "center", back, HS:new{ width = mid_l }, seg3,
            HS:new{ width = math.max(0, iw - back:getSize().w - mid_l - seg_w3 - right_w) } }
        if more then top[#top + 1] = more top[#top + 1] = HS:new{ width = px(8) } end
        top[#top + 1] = xb
        top_taps[#top_taps + 1] = { back, closeAll }
        top_taps[#top_taps + 1] = { xb, closeAll }
        if more then top_taps[#top_taps + 1] = { more, function() ctx.more() end } end
        top_taps[#top_taps + 1] = { seg3, function()
            local pos = Stats._tap_pos
            local sx = seg3.dimen and seg3.dimen.x
            local k = (pos and sx) and math.floor((pos.x - sx) / third) + 1 or on_k
            if k <= 1 then goBack()
            elseif k == 2 and all then backToStats()
            elseif k >= 3 and not all then Stats.showAll() end
        end }
    end
    -- This Kobo | BookOrbit, under the top bar (the tiles only)
    local switch, seg_w
    -- 2.1.31 (TK): a book with no reading on this device has only BookOrbit's side: no switch
    if (all and allBookOrbit()) or (not all and canBookOrbit(rec) and ctx.kobo ~= nil) then
        local l1 = text(_("Device"), 13, true, src == "kobo" and PAPER or INK)
        local l2 = text(_("BookOrbit"), 13, true, src == "bookorbit" and PAPER or INK)
        seg_w = math.max(l1:getSize().w, l2:getSize().w) + px(28)
        local seg_h = l1:getSize().h + px(10)
        local r = math.floor(seg_h / 2)
        switch = canvas(2 * seg_w, seg_h, function(bb, sx, sy)
            bb:paintRoundedRect(sx, sy, 2 * seg_w, seg_h, PAPER, r)
            bb:paintRoundedRect(sx + (src == "kobo" and 0 or seg_w), sy, seg_w, seg_h, INK, r)
            bb:paintBorder(sx, sy, 2 * seg_w, seg_h, px(1), INK, r)
            l1:paintTo(bb, sx + math.floor((seg_w - l1:getSize().w) / 2), sy + px(5))
            l2:paintTo(bb, sx + seg_w + math.floor((seg_w - l2:getSize().w) / 2), sy + px(5))
        end)
    end

    local col = VG:new{ align = "left", top, VS:new{ width = px(4) },
        W("linewidget"):new{ dimen = Geom:new{ w = iw, h = px(1) }, background = INK }, VS:new{ width = px(8) } }
    if switch then
        col[#col + 1] = HG:new{ align = "center", HS:new{ width = math.floor((iw - switch:getSize().w) / 2) }, switch }
        col[#col + 1] = VS:new{ width = px(8) }
    end
    local taps
    do
        -- the foot: where BookOrbit's numbers came from, or the tap hint
        local foot
        if all then
            local bits = {}
            if src == "bookorbit" and A.fetched and A.fetched > 0 then
                bits[1] = T(_("from BookOrbit · as of %1"), dayShort(A.fetched) .. os.date(" %I:%M %p",
                    A.fetched):gsub(" 0", " "))
            end
            bits[#bits + 1] = _("Tap a tile for more")
            foot = text(table.concat(bits, "  ·  "), 11, false, SUB, iw)
        elseif d.unit == "pct" then
            local bits = {}
            if d.sources and #d.sources > 0 then bits[1] = T(_("From %1"), table.concat(d.sources, ", ")) end
            if d.fetched then bits[#bits + 1] = T(_("as of %1"), dayShort(d.fetched) .. os.date(" %I:%M %p", d.fetched):gsub(" 0", " ")) end
            bits[#bits + 1] = _("tap a tile for more")
            foot = text(table.concat(bits, "  ·  "), 11, false, SUB, iw)
        else
            foot = text(_("Tap a tile for more"), 11, false, SUB, iw)
        end
        local room = sh - 2 * pad - col:getSize().h - foot:getSize().h - px(8)
        local dash
        if all then
            dash, taps = allDashboard(A, src, iw, room, P)
        else
            dash, taps = dashboard(d, rec, iw, room, P, extra)
        end
        for k = 1, #top_taps do table.insert(taps, k, top_taps[k]) end
        col[#col + 1] = dash
        col[#col + 1] = VS:new{ width = px(8) }
        col[#col + 1] = HG:new{ align = "center", HS:new{ width = math.floor((iw - foot:getSize().w) / 2) }, foot }
    end
    -- 2.1.17: col was measured above (the room left) before the tiles / card went in;
    -- KOReader's VerticalGroup keeps that layout, so painting the new rows crashed
    -- (verticalgroup.lua:51, TK's Kobo): measured again now
    if col.resetLayout then col:resetLayout() else col._size, col._offsets = nil, nil end
    widget[1] = W("container/framecontainer"):new{ dimen = Geom:new{ w = sw, h = sh }, width = sw, height = sh,
        background = PAPER, bordersize = 0, padding = pad, margin = 0, col }
    widget.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    function widget:onClose()
        goBack()
        return true
    end
    -- swipe right: back to the Book Page; down: KOReader's top menu (2.1.23)
    widget.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = widget.dimen } },
        TapTile = { GestureRange:new{ ges = "tap", range = widget.dimen } } }
    if switch then
        widget.ges_events.TapSwitch = { GestureRange:new{ ges = "tap", range = function() return switch.dimen or Geom:new{ w = 0, h = 0 } end } }
        function widget:onTapSwitch(_arg, ges)
            local gx = ges and ges.pos and ges.pos.x or 0
            local want = (switch.dimen and gx >= switch.dimen.x + seg_w) and "bookorbit" or "kobo"
            if all then
                if want ~= src then
                    ctx.wake = nil
                    O.cfg.stats_source = want
                    pcall(O.saveConfig)
                    Stats.showAll(want)
                end
                return true
            end
            if want == "bookorbit" or want ~= src then pick(want) end
            return true
        end
    end
    -- a tile tapped: its card
    function widget:onTapTile(_arg, ges)
        local pos = ges and ges.pos
        if not pos then return false end
        Stats._tap_pos = pos
        for _i, tp in ipairs(taps) do
            local dm = tp[1].dimen
            if dm and pos.x >= dm.x and pos.x < dm.x + dm.w and pos.y >= dm.y and pos.y < dm.y + dm.h then
                -- a tile: its card; on a card (2.1.13), its own buttons
                if type(tp[2]) == "function" then tp[2]() else render(d, src, tp[2]) end
                return true
            end
        end
        return false
    end
    function widget:onSwipe(_arg, ges)
        local dir = ges and ges.direction
        if dir == "east" then
            goBack()
            return true
        end
        -- 2.1.23 (TK): down brings KOReader's top menu (it used to close both pages)
        if dir == "south" then
            if not (O.showTopMenu and O.showTopMenu()) then closePage(false) if close_all then close_all() end end
            return true
        end
        return false
    end
    -- 2.1.17: opening flashes as Look › Screen Flashes › Stats Page says; a tile, a card,
    -- the switch or a month as Stats Page Changes says (both full by default, as before)
    local changing = shown ~= nil
    if shown then UIManager:close(shown) end
    shown, on_closed = widget, ctx.on_back
    -- a colour screen shows colour properly only with a dithered refresh
    UIManager:show(widget, O.flash and O.flash(changing and "stats_change" or "stats") or "full", nil, nil, nil, P.colour or nil)
end

-- ---- A tile's card (2.1.20, TK): a popup sized to fit, over the stats page ----------------
-- ✕, back, a swipe down or a tap outside closes just the card; Your Year's back goes to
-- the month. Tiles' own buttons (months, Your Year) work as before.
showCard = function(d, src, card)
    if not (ctx and shown) then return end
    -- 2.1.23 (TK): X-Ray's card is the X-Ray popup (everything X-Ray fetched, up to your page)
    if card == "xray" and O.XRay and src == "kobo" then
        local ok, err = pcall(O.XRay.show, ctx.rec, d.path, d, extraFor(d, src, ctx.rec))
        if ok then return end
        O.logger.warn(O.TAG, "X-Ray popup:", tostring(err))
    end
    local rec = ctx.rec
    local Device = require("device")
    local GestureRange = require("ui/gesturerange")
    local P = palette()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local margin, pad, border = px(12), px(14), px(2)
    local fw = sw - 2 * margin
    local iw = fw - 2 * pad - 2 * border
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local widget = W("container/inputcontainer"):new{ dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh },
        orbitshelf_perf = "stats card" }
    local function btn(s, cb, size)
        return W("button"):new{ text = s, bordersize = 0, padding = px(6), text_font_size = size or 18,
            callback = cb, show_parent = widget }
    end
    local extra = extraFor(d, src, rec)
    local function goBack()
        if card == "year" and not d.alltime then render(d, src, "month") else ctx.month_off = nil closeCard() end
    end
    local x = btn("\u{2715}", function() ctx.month_off = nil closeCard() end, 20)
    local back = (card == "year" and not d.alltime) and btn(_("‹ Month"), goBack) or nil
    local back_w = back and back:getSize().w or x:getSize().w
    local ttl = text(CARD_TITLE[card] or "", 18, true, INK, iw - back_w - x:getSize().w - px(16))
    local mid_gap = math.max(0, math.floor((iw - ttl:getSize().w) / 2) - back_w)
    local top = HG:new{ align = "center", back or HS:new{ width = back_w }, HS:new{ width = mid_gap }, ttl,
        HS:new{ width = math.max(0, iw - back_w - x:getSize().w - mid_gap - ttl:getSize().w) }, x }
    local body, taps = nil, {}
    local R = (card == "month" or card == "year") and rings() or nil
    if R and card == "month" then
        local ok, b, t = pcall(R.monthCard, d, rec, iw, P, extra, {
            off = ctx.month_off,
            go = function(off) ctx.month_off = off render(d, src, "month") end,
            year = function() Stats.openYear(d, src, tonumber(os.date("%Y", d.now))) end,
        })
        if ok then body, taps = b, t or {} else O.logger.warn(O.TAG, "Reading Stats month:", tostring(b)) end
    elseif R and card == "year" and ctx.year then
        local ok, b, t = pcall(R.yearCard, ctx.year, d, rec, iw, P, {
            go = function(y) Stats.openYear(d, src, y) end,
            -- 2.1.28 (TK): ‹ 2025 · 2026 · All Time
            all = function()
                if ctx.view == "all" then closeCard() else closeCard(false) Stats.showAll(src) end
            end,
        })
        if ok then body, taps = b, t or {} else O.logger.warn(O.TAG, "Reading Stats year:", tostring(b)) end
    end
    if card == "days" then
        local off = ctx.cal_keep and ctx.cal_off or 0
        ctx.cal_keep, ctx.cal_off = nil, off
        local function go(o) ctx.cal_off, ctx.cal_keep = o, true render(d, src, "days") end
        local ok, b, t = pcall(daysCard, d, iw, P, off, go)
        if ok then body, taps = b, t or {} else O.logger.warn(O.TAG, "Reading Stats calendar:", tostring(b)) end
    end
    if not body then
        local ctaps = {}
        body = bigCard(card == "year" and "month" or card, d, rec, iw, P, extra, ctaps)
        local _l5 = ctaps
        for _l5_n = 1, #_l5 do local t = _l5[_l5_n] taps[#taps + 1] = t end
    end
    local head_h = top:getSize().h + px(13)
    local max_body = sh - 2 * margin - 2 * pad - 2 * border - head_h
    local col = VG:new{ align = "left", top, VS:new{ width = px(4) },
        W("linewidget"):new{ dimen = Geom:new{ w = iw, h = px(1) }, background = INK }, VS:new{ width = px(8) },
        boxed(body, iw, math.min(body:getSize().h, max_body)) }
    local frame = W("container/framecontainer"):new{ background = PAPER, bordersize = border, color = INK,
        radius = px(18), padding = pad, margin = 0, col }
    -- 2.1.23 (TK): Look › Popup Style: Rainbow draws the edge in the 8 colours
    local SP = O.Sheet and O.Sheet.palette and O.Sheet.palette()
    if SP and O.Sheet.rainbow(SP) then
        local inner = frame
        local isz = inner:getSize()
        frame = canvas(isz.w, isz.h, function(bb, fx0, fy0)
            inner:paintTo(bb, fx0, fy0)
            O.Sheet.edge(bb, fx0, fy0, isz.w, isz.h, px(2), px(18), SP) -- 2.1.30: thinner
        end)
        -- 2.1.24: taps still reach ✕ and ‹ Month inside (the drawn edge took them before)
        function frame.handleEvent(_s, ev) return inner:handleEvent(ev) end
    end
    local fs = frame:getSize()
    local fx, fy = math.floor((sw - fs.w) / 2), math.floor((sh - fs.h) / 2)
    widget.frame_dimen = Geom:new{ x = fx, y = fy, w = fs.w, h = fs.h }
    widget[1] = W("container/centercontainer"):new{ dimen = Geom:new{ w = sw, h = sh }, frame }
    widget.key_events = { Close = { { Device.input and Device.input.group and Device.input.group.Back or "Back" } } }
    function widget:onClose()
        goBack()
        return true
    end
    widget.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = widget.dimen } },
        TapCard = { GestureRange:new{ ges = "tap", range = widget.dimen } } }
    function widget:onTapCard(_arg, ges)
        local pos = ges and ges.pos
        if not pos then return false end
        Stats._tap_pos = pos
        local fd = widget.frame_dimen
        if pos.x < fd.x or pos.x >= fd.x + fd.w or pos.y < fd.y or pos.y >= fd.y + fd.h then
            ctx.month_off = nil
            closeCard()
            return true
        end
        for _i, tp in ipairs(taps) do
            local dm = tp[1].dimen
            if dm and pos.x >= dm.x and pos.x < dm.x + dm.w and pos.y >= dm.y and pos.y < dm.y + dm.h then
                if type(tp[2]) == "function" then tp[2]() else render(d, src, tp[2]) end
                return true
            end
        end
        return false
    end
    function widget:onSwipe(_arg, ges)
        local dir = ges and ges.direction
        if dir == "east" then goBack() return true end
        if dir == "south" then ctx.month_off = nil closeCard() return true end
        return false
    end
    -- another card (a month, Your Year): the old one's spot is redrawn with the page
    local old = card_shown
    card_shown = widget
    if old then UIManager:close(old, nil) end
    local region = widget.frame_dimen
    if old and old.frame_dimen then
        local o = old.frame_dimen
        local x0, y0 = math.min(o.x, region.x), math.min(o.y, region.y)
        region = Geom:new{ x = x0, y = y0, w = math.max(o.x + o.w, region.x + region.w) - x0,
            h = math.max(o.y + o.h, region.y + region.h) - y0 }
    end
    UIManager:show(widget, O.flash and O.flash("stats_change") or "full", region, nil, nil, P.colour or nil)
end

-- 2.1.26 (TK): a tapped day: this book's sittings that day (from KOReader's statistics),
-- the other books you read, highlights and ReadMastery rewards that day; ‹ › to the day
-- before / after; KOReader's own day view and Reading Insights
local function clock(t) return (os.date("%I:%M %p", t):gsub("^0", "")) end

local function booksOn(t0, t1)
    local out = {}
    local conn = openDb()
    if not conn then return out end
    pcall(function()
        local r = query(conn, "SELECT b.title, SUM(p.duration), COUNT(DISTINCT p.page) FROM page_stat_data p "
            .. "JOIN book b ON b.id = p.id_book WHERE p.start_time >= ? AND p.start_time < ? "
            .. "GROUP BY b.title ORDER BY 2 DESC", { t0, t1 }) -- copies of a book downloaded again: one
        if r and r[1] then
            for i = 1, #r[1] do
                local title = tostring(r[1][i] or "")
                if n(r[2][i]) >= 60 then out[#out + 1] = { title = title, secs = n(r[2][i]), pages = n(r[3][i]) } end
            end
        end
    end)
    pcall(conn.close, conn)
    return out
end

local function koreaderDayView(t0)
    local ok = pcall(function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local RUI = package.loaded["apps/reader/readerui"]
        local ui = (RUI and RUI.instance) or (FM and FM.instance)
        local rs = ui and ui.statistics
        local CV = rs and require("calendarview")
        if not (rs and CV and CV.showCalendarDayView) then error("no statistics") end
        local CDV
        for i = 1, 60 do
            local name, v = debug.getupvalue(CV.showCalendarDayView, i)
            if not name then break end
            if name == "CalendarDayView" then CDV = v break end
        end
        if not CDV then error("no day view") end
        local st = rs.settings or {}
        local dt = os.date("*t", t0)
        UIManager:show(CDV:new{
            day_ts = os.time{ year = dt.year, month = dt.month, day = dt.day,
                hour = st.calendar_day_start_hour or 0, min = st.calendar_day_start_minute or 0 },
            reader_statistics = rs, color = rs.color,
            min_month = os.date("%Y-%m", (rs.getFirstTimestamp and rs:getFirstTimestamp()) or t0),
        })
    end)
    if not ok then
        UIManager:show(require("ui/widget/infomessage"):new{
            text = _("KOReader's day view isn't available here."), timeout = 3 })
    end
end

function Stats.showDay(d, t)
    local widget
    local function spec(day_t)
        local t0 = midnight(day_t)
        local t1 = t0 + 86400
        local sits, secs, pages = {}, 0, 0
        local _lr2 = d.sessions or {}
        for _lr2_n = 1, #_lr2 do local se = _lr2[_lr2_n]
            if se.start >= t0 and se.start < t1 then
                sits[#sits + 1] = se
                secs, pages = secs + (se.secs or 0), pages + (se.pages or 0)
            end
        end
        -- the streak that day: days in a row with reading, up to it
        local streak = 0
        if d.days[dayKey(t0 + 43200)] and d.days[dayKey(t0 + 43200)].pages > 0 then
            local k = t0
            while d.days[dayKey(k + 43200)] and d.days[dayKey(k + 43200)].pages > 0 do
                streak = streak + 1
                k = k - 86400
            end
        end
        -- 2.1.27 (TK): what you read that day, every book, with its pages and time
        local books = booksOn(t0, t1)
        local mine
        for bi = 1, #books do if books[bi].title == d.title then mine = books[bi] end end
        if not mine and secs > 0 then
            mine = { title = d.title or _("This book"), secs = secs, pages = pages, pct = d.unit == "pct" }
            table.insert(books, 1, mine)
        end
        local all_secs, all_pages = 0, 0
        for bi = 1, #books do
            local b = books[bi]
            all_secs = all_secs + b.secs
            if not b.pct then all_pages = all_pages + b.pages end
        end
        local items = { { kind = "counts", list = {
            { n = durS(all_secs), text = _("Read"), colour = "blue" },
            { n = #books, text = #books == 1 and _("Book") or _("Books"), colour = "teal" },
            { n = all_pages, text = _("Pages"), colour = "green" },
            { n = streak, text = streak == 1 and _("Day in a row") or _("Days in a row"), colour = "purple" } } } }
        local sections = { { colour = "blue", plain = true, items = items } }
        if #books > 0 then
            local rows = {}
            for bi = 1, #books do
                local b = books[bi]
                local amt = b.pct and (math.floor(b.pages * 10 + 0.5) / 10 .. "%")
                    or (b.pages == 1 and _("1 page") or T(_("%1 pages"), b.pages))
                rows[#rows + 1] = { arrow = false, bold = b == mine, colour = b == mine and "blue" or "teal",
                    text = b.title, note = amt .. "  ·  " .. durS(b.secs) }
            end
            sections[#sections + 1] = { title = _("What you read"), colour = "teal", plain = true,
                items = { { kind = "list", list = rows } } }
        end
        if #sits > 0 then
            local timeline = { kind = "custom", build = function(w, P)
                local h = px(58)
                local labs = { { 6, _("6 AM") }, { 12, _("12 PM") }, { 18, _("6 PM") }, { 24, _("12 AM") } }
                local lt = {}
                for i, l in ipairs(labs) do lt[i] = text(l[2], 10, false, SUB) end
                return canvas(w, h, function(bb, x, y)
                    local bh = px(22)
                    O.Sheet.roundFill(bb, x, y, w, bh, px(11), P.colour and P.track or { v = PAPER })
                    if not P.colour then bb:paintBorder(x, y, w, bh, px(1), INK, px(11)) end
                    local _l6 = sits
                    for _l6_n = 1, #_l6 do local se = _l6[_l6_n]
                        local a = math.max(6, (se.start - t0) / 3600)
                        local b2 = math.min(24, math.max(a + 0.2, (se.start + se.secs - t0) / 3600))
                        local sx = x + math.floor(w * (a - 6) / 18)
                        local ex = x + math.floor(w * (b2 - 6) / 18)
                        O.Sheet.roundFill(bb, sx, y, math.max(px(8), ex - sx), bh, px(11),
                            P.colour and P.hue("blue") or { v = INK })
                    end
                    for i, l in ipairs(labs) do
                        local lx = x + math.floor(w * (l[1] - 6) / 18)
                        lt[i]:paintTo(bb, math.min(lx, x + w - lt[i]:getSize().w), y + bh + px(6))
                    end
                end)
            end }
            local rows = {}
            local _lr3 = sits
            for _lr3_n = 1, #_lr3 do local se = _lr3[_lr3_n]
                local note
                if d.unit ~= "pct" and d.total and se.pos then
                    local p1 = math.floor(se.pos * d.total + 0.5)
                    local p0 = math.max(1, p1 - math.floor(se.pages + 0.5) + 1)
                    note = p0 < p1 and T(_("p. %1–%2"), p0, p1) or T(_("p. %1"), p1)
                elseif se.pos then
                    note = T(_("to %1%"), math.floor(se.pos * 100 + 0.5))
                end
                rows[#rows + 1] = { text = clock(se.start) .. "  ·  " .. durS(se.secs), note = note,
                    colour = "blue", arrow = false }
            end
            sections[#sections + 1] = { title = T(_("Sittings · %1"), d.title or _("this book")),
                colour = "blue", plain = true,
                items = { timeline, { kind = "list", list = rows } } }
        end
        local also = {}
        local hl = 0
        pcall(function()
            if type(d.path) ~= "string" then return end
            local list = require("docsettings"):open(d.path):readSetting("annotations")
            local want = os.date("%Y-%m-%d", t0 + 43200)
            local _l8 = type(list) == "table" and list or {}
            for _l8_n = 1, #_l8 do local a = _l8[_l8_n]
                local dt = type(a) == "table" and a.pos0 and a.datetime
                    and tostring(a.datetime):match("^(%d+%-%d+%-%d+)")
                if dt == want then hl = hl + 1 end
            end
        end)
        if hl > 0 then also[#also + 1] = { arrow = false,
            text = hl == 1 and _("1 highlight") or T(_("%1 highlights"), hl), colour = "gold" } end
        if O.XRay and O.XRay.rewards then
            local okR, rw = pcall(O.XRay.rewards, d)
            local _l9 = okR and rw or {}
            for _l9_n = 1, #_l9 do local r = _l9[_l9_n]
                if r.t and r.t >= t0 and r.t < t1 then also[#also + 1] = { arrow = false,
                    text = r.name .. (r.tier and (" · " .. r.tier) or ""), note = _("ReadMastery"),
                        colour = "purple" } end
            end
        end
        if #also > 0 then sections[#sections + 1] = { title = _("Also that day"), colour = "gold", plain = true,
            items = { { kind = "list", list = also } } } end
        if #books == 0 and #also == 0 then
            sections[#sections + 1] = { colour = "gold", plain = true, items = { { kind = "text", size = 13,
                text = _("No reading that day.") } } }
        end
        local pills = {
            { text = "‹ " .. os.date("%b ", t0 - 43200) .. tonumber(os.date("%d", t0 - 43200)), keep = true,
                callback = function() widget:rebuild(spec(t0 - 43200)) end },
        }
        if t1 <= d.now then
            pills[#pills + 1] = { text = os.date("%b ", t1 + 43200) .. tonumber(os.date("%d",
                t1 + 43200)) .. " ›", keep = true, callback = function() widget:rebuild(spec(t1 + 43200)) end }
        end
        pills[#pills + 1] = { text = _("Day View"), colour = "blue", callback = function() koreaderDayView(t0) end }
        sections[#sections + 1] = { colour = "teal", plain = true, items = { { kind = "pills", list = pills } } }
        return { title = os.date("%A, %B ", t0 + 43200) .. tonumber(os.date("%d", t0 + 43200)),
            subtitle = _("from KOReader's statistics"),
                cancel = false, sections = sections }
    end
    widget = O.Sheet.show(spec(t))
    return widget
end


return Stats
