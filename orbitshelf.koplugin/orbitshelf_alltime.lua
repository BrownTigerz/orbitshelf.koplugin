-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.28 (TK): All Time, the stats page for all your reading (Book | Stats | All Time):
--   * the hero: since when, days read, books opened; Your Year / Finished / Reading pills;
--     every book in order on one line, the critter at the one you're reading now
--   * TIME / DAYS / BOOKS / PAGES; the months ring; this week; moments; the books by time;
--     authors, genres (BookOrbit's library records) and habits
--   This Kobo: KOReader's statistics (worked out again when the database changes, saved).
--   BookOrbit: the years Your Year saved or fetches, added up (back until a year is empty).
-- The drawing helpers are the stats page's own (O.Stats._kit), the ring Your Year's.
local O = require("orbitshelf_core")
local T, _ = O.T, O._

local AllTime = {}
O.AllTime = AllTime

if not (O.Stats and O.Stats._kit) then require("orbitshelf_stats") end
local K = O.Stats._kit
local px, text, fill, disc, roundFill, canvas = K.px, K.text, K.fill, K.disc, K.roundFill, K.canvas
local dayKey, midnight, durS, dayShort = K.dayKey, K.midnight, K.durS, K.dayShort
local INK, SUB, PAPER = K.INK, K.SUB, K.PAPER

local function W(name) return require("ui/widget/" .. name) end
local function rings()
    local ok, R = pcall(require, "orbitshelf_rings")
    return ok and R or nil
end

-- the title without its subtitle ("No Exit: A Novel" -> "No Exit")
local function short(title) return (tostring(title or "?"):gsub("%s*:.*$", "")) end

local function key(title) return (tostring(title or ""):lower():gsub("%s*[:%(].*$", ""):gsub("^%s+",
    ""):gsub("%s+$", "")) end

-- ---- This Kobo ------------------------------------------------------------------------

local function fromKobo()
    local st = K.openStore()
    local saved = st and st:readSetting("alltime:kobo")
    local mtime = K.dbMtime()
    if type(saved) == "table" and saved.v == 2 and mtime and saved.db_mtime == mtime then return saved end
    local conn = K.openDb()
    if not conn then return type(saved) == "table" and saved or nil end
    local A = { v = 2, src = "kobo", db_mtime = mtime, days = {}, books = {}, finished = {}, hours = {},
        months = {}, total = 0, pages = 0 }
    local ok, err = pcall(function()
        local maxs = K.maxSec()
        -- the books, copies downloaded again as one (by title)
        local bk = K.query(conn, "SELECT id, title, authors, md5, pages FROM book;")
        local of, byk = {}, {}
        if bk then
            for i = 1, #bk[1] do
                local id = tonumber(bk[1][i])
                local title = type(bk[2][i]) == "string" and bk[2][i] or "?"
                local k = key(title)
                if not byk[k] then
                    A.books[#A.books + 1] = { title = title,
                        author = type(bk[3][i]) == "string" and bk[3][i]:match("^[^\n]*") or nil,
                        md5 = bk[4][i], pages = tonumber(bk[5][i]), secs = 0, read_pages = 0, days = 0 }
                    byk[k] = #A.books
                end
                if id then of[id] = byk[k] end
            end
        end
        -- each book's days, the days' time and pages
        local r = K.query(conn,
            "SELECT id_book, strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'), SUM(MIN(duration, ?)),"
            .. " COUNT(DISTINCT page), MIN(start_time), MAX(start_time) FROM page_stat_data GROUP BY 1, 2;", { maxs })
        local bdays = {}
        if r then
            for i = 1, #r[1] do
                local bi = of[tonumber(r[1][i]) or -1]
                local dk, secs, pg, t0, t1 = r[2][i], tonumber(r[3][i]) or 0, tonumber(r[4][i]) or 0,
                    tonumber(r[5][i]), tonumber(r[6][i])
                if bi and dk and t0 then
                    local dd = A.days[dk]
                    if not dd then
                        local y, mo, d = dk:match("^(%d+)%-(%d+)%-(%d+)")
                        dd = { secs = 0, pages = 0, t = os.time{ year = tonumber(y), month = tonumber(mo),
                            day = tonumber(d), hour = 12 }, top = bi, top_s = 0 }
                        A.days[dk] = dd
                    end
                    dd.secs, dd.pages = dd.secs + secs, dd.pages + pg
                    if secs > dd.top_s then dd.top, dd.top_s = bi, secs end
                    local b = A.books[bi]
                    b.secs = b.secs + secs
                    bdays[bi] = bdays[bi] or {}
                    if not bdays[bi][dk] then bdays[bi][dk] = true b.days = b.days + 1 end
                    b.from = math.min(b.from or t0, t0)
                    b.last = math.max(b.last or t1, t1)
                    A.total = A.total + secs
                    local mk = dk:sub(1, 7)
                    A.months[mk] = (A.months[mk] or 0) + secs
                end
            end
        end
        -- pages read in each book
        local q = K.query(conn, "SELECT id_book, COUNT(DISTINCT page) FROM page_stat_data GROUP BY id_book;")
        if q then
            for i = 1, #q[1] do
                local bi = of[tonumber(q[1][i]) or -1]
                if bi then A.books[bi].read_pages = A.books[bi].read_pages + (tonumber(q[2][i]) or 0) end
            end
        end
        -- the hours of the day
        local h = K.query(conn,
            "SELECT CAST(strftime('%H', start_time, 'unixepoch', 'localtime') AS INTEGER), SUM(MIN(duration, ?))"
            .. " FROM page_stat_data GROUP BY 1;", { maxs })
        if h then for i = 1, #h[1] do A.hours[tonumber(h[1][i]) or 0] = tonumber(h[2][i]) or 0 end end
        -- finished: the last pages reached, and not read on from earlier after (Your Year's rule)
        local R = rings()
        local ft = R and R.finishTimes and R.finishTimes(conn)
        local fin = {}
        if ft then
            local fid, t = next(ft)
            while fid do
                local bi = of[fid]
                if bi and (not fin[bi] or t < fin[bi]) then fin[bi] = t end
                fid, t = next(ft, fid)
            end
        else
            local f = K.query(conn, "SELECT id_book, MIN(start_time) FROM page_stat_data"
                .. " WHERE total_pages > 0 AND page >= total_pages * 0.97 GROUP BY id_book;")
            for i = 1, f and #f[1] or 0 do
                local bi = of[tonumber(f[1][i]) or -1]
                local t = tonumber(f[2][i])
                if bi and t and A.books[bi].secs >= 1800 and (not fin[bi] or t < fin[bi]) then fin[bi] = t end
            end
        end
        for bi, t in pairs(fin) do
            A.books[bi].to = t
            A.finished[#A.finished + 1] = { book = bi, t = t }
        end
        table.sort(A.finished, function(a, c) return a.t < c.t end)
        -- the longest sitting (no more than 10 minutes between pages)
        local s = K.query(conn,
            "SELECT id_book, start_time, MIN(duration, ?) FROM page_stat_data ORDER BY start_time;", { maxs })
        if s then
            local cur
            for i = 1, #s[1] do
                local bi, t, du = of[tonumber(s[1][i]) or -1], tonumber(s[2][i]) or 0, tonumber(s[3][i]) or 0
                if cur and cur.book == bi and t - cur.stop <= 600 then
                    cur.secs, cur.stop = cur.secs + du, t + du
                else
                    cur = { book = bi, start = t, stop = t + du, secs = du }
                end
                if not A.sit or cur.secs > A.sit.secs then A.sit = { book = cur.book, start = cur.start,
                    secs = cur.secs } end
            end
        end
        -- where you are now: the last page read
        local nw = K.query(conn,
            "SELECT id_book, page, total_pages FROM page_stat_data ORDER BY start_time DESC LIMIT 1;")
        if nw and nw[1] and nw[1][1] then
            local bi = of[tonumber(nw[1][1]) or -1]
            local tp = tonumber(nw[3][1]) or 0
            if bi and not A.books[bi].to and tp > 0 then A.now = { book = bi, pct = math.min(1,
                (tonumber(nw[2][1]) or 0) / tp) } end
        end
    end)
    pcall(conn.close, conn)
    if not ok then O.logger.warn(O.TAG, "All Time:", tostring(err)) return type(saved) == "table" and saved or nil end
    -- books never read here (only in KOReader's list) are left out
    local keep, remap = {}, {}
    for i = 1, #A.books do
        if A.books[i].secs > 0 then keep[#keep + 1] = A.books[i] remap[i] = #keep end
    end
    A.books = keep
    for k, dd in pairs(A.days) do dd.top = remap[dd.top] or dd.top if k == "" then A.days[k] = nil end end
    for i = 1, #A.finished do A.finished[i].book = remap[A.finished[i].book] end
    if A.sit then A.sit.book = remap[A.sit.book] end
    if A.now then A.now.book = remap[A.now.book] end
    for i = 1, #A.books do A.pages = A.pages + (A.books[i].read_pages or 0) end
    if st then pcall(function() st:saveSetting("alltime:kobo", A) st:flush() end) end
    return A
end

-- ---- BookOrbit: the years added up -------------------------------------------------------

local function fromYears(years)
    local A = { v = 1, src = "bookorbit", days = {}, books = {}, finished = {}, months = {}, total = 0, pages = 0 }
    for yi = #years, 1, -1 do
        local Y = years[yi]
        local base = #A.books
        for i = 1, #Y.books do
            local b = Y.books[i]
            A.books[#A.books + 1] = { title = b.title, author = b.author, bo_id = b.bo_id, pages = b.pages,
                secs = b.secs or 0,
                from = b.from, to = b.to, audio = b.audio }
        end
        for i = 1, #Y.finished do A.finished[#A.finished + 1] = { book = base + Y.finished[i].book,
            t = Y.finished[i].t } end
        for dy, secs in pairs(Y.secs) do
            local t = os.time{ year = Y.year, month = 1, day = dy, hour = 12 }
            local dk = dayKey(t)
            A.days[dk] = { secs = secs, pages = secs / 60, t = t, top = Y.top[dy] and (base + Y.top[dy]) or nil }
            A.total = A.total + secs
            local mk = dk:sub(1, 7)
            A.months[mk] = (A.months[mk] or 0) + secs
        end
        A.pages = A.pages + (tonumber(Y.pages) or 0)
        A.fetched = math.max(A.fetched or 0, tonumber(Y.fetched) or 0)
    end
    table.sort(A.finished, function(a, c) return a.t < c.t end)
    for i = 1, #A.books do
        local b = A.books[i]
        if not b.secs or b.secs == 0 then b.secs = 0 end
    end
    if A.pages == 0 then
        for i = 1, #A.books do A.pages = A.pages + (A.books[i].pages or 0) end
    end
    return A
end

-- the years back from this one until one comes back empty (at most 6); done(A, err)
local function fromBookOrbit(done)
    local R = rings()
    if not R then return done(nil, "no rings") end
    local y = tonumber(os.date("%Y"))
    local years = {}
    local function step(yy)
        local ok, err = pcall(R.loadYear, "bookorbit", yy, function(Y, e)
            if Y and ((Y.total or 0) > 0 or #(Y.books or {}) > 0) then
                years[#years + 1] = Y
                if #years < 6 then return step(yy - 1) end
            elseif #years == 0 then
                return done(nil, e)
            end
            done(fromYears(years))
        end)
        if not ok then done(#years > 0 and fromYears(years) or nil, err) end
    end
    step(y)
end

function AllTime.load(src, done)
    if src == "bookorbit" then return fromBookOrbit(done) end
    local ok, A = pcall(fromKobo)
    if not ok then O.logger.warn(O.TAG, "All Time:", tostring(A)) A = nil end
    -- 2.1.29 (TK): books marked finished count too, not only the ones read to the end
    local R = rings()
    if A and R and R.withMarked then pcall(R.withMarked, A) end
    done((A and A.total > 0) and A or nil)
end

-- ---- The numbers ------------------------------------------------------------------------

local function dayList(A)
    local list = {}
    local k0, dd = next(A.days)
    while k0 do
        if dd.secs > 0 then list[#list + 1] = dd end
        k0, dd = next(A.days, k0)
    end
    table.sort(list, function(a, c) return a.t < c.t end)
    return list
end

local function numbers(A)
    local N = { list = dayList(A) }
    local list = N.list
    N.days_read = #list
    N.first = list[1] and list[1].t or os.time()
    N.days_since = math.floor((midnight(os.time()) - midnight(N.first) + 3600) / 86400) + 1
    -- best day, streaks
    local run, best_run, run_from, best_from, best_to, prev = 0, 0, nil, nil, nil, nil
    for i = 1, #list do
        local dd = list[i]
        if not N.best or dd.secs > N.best.secs then N.best = dd end
        if prev and math.floor((midnight(dd.t) - midnight(prev.t) + 3600) / 86400) == 1 then run = run + 1
        else run, run_from = 1, dd.t end
        if run > best_run then best_run, best_from, best_to = run, run_from, dd.t end
        prev = dd
    end
    N.streak = best_run > 1 and { n = best_run, from = best_from, to = best_to } or nil
    -- finished, reading (read in the last 30 days, not finished)
    local fin = {}
    for i = 1, #A.finished do fin[A.finished[i].book] = A.finished[i].t end
    N.fin = fin
    N.reading = 0
    local recent = os.time() - 30 * 86400
    for i = 1, #A.books do
        local b = A.books[i]
        if not fin[i] and (b.secs or 0) >= 1800 and (b.last or b.to or b.from or 0) >= recent then
            N.reading = N.reading + 1
        end
    end
    -- fastest finish
    for i = 1, #A.finished do
        local f = A.finished[i]
        local b = A.books[f.book]
        -- 2.1.29: a book only marked finished after a few minutes here isn't a fast read
        if b and b.from and (A.src == "bookorbit" or (b.secs or 0) >= 1800) then
            local days = math.floor((midnight(f.t) - midnight(b.from) + 3600) / 86400) + 1
            if not N.fastest or days < N.fastest.days then N.fastest = { book = f.book, days = days } end
        end
    end
    -- months
    local mlist = {}
    for mk, secs in pairs(A.months) do mlist[#mlist + 1] = { k = mk, secs = secs } end
    table.sort(mlist, function(a, c) return a.k < c.k end)
    N.months = mlist
    for i = 1, #mlist do if not N.top_month or mlist[i].secs > N.top_month.secs then N.top_month = mlist[i] end end
    N.this_month = A.months[os.date("%Y-%m")] or 0
    -- this week and last (Mon-Sun), the time a day
    local today = midnight(os.time())
    local wd = (tonumber(os.date("%w", today)) + 6) % 7
    local mon = today - wd * 86400
    N.week, N.lweek, N.wk, N.lwk = {}, {}, 0, 0
    for i = 0, 6 do
        local a = A.days[dayKey(mon + i * 86400 + 3600)]
        local b = A.days[dayKey(mon - (7 - i) * 86400 + 3600)]
        N.week[i + 1], N.lweek[i + 1] = a and a.secs or 0, b and b.secs or 0
        N.wk, N.lwk = N.wk + N.week[i + 1], N.lwk + N.lweek[i + 1]
    end
    N.wd = wd + 1
    -- the books by time; authors
    local order = {}
    for i = 1, #A.books do order[i] = i end
    table.sort(order, function(a, c) return (A.books[a].secs or 0) > (A.books[c].secs or 0) end)
    N.by_time = order
    local au, aul = {}, {}
    for i = 1, #A.books do
        local b = A.books[i]
        if b.author and b.author ~= "" then
            if not au[b.author] then
                au[b.author] = { name = b.author, secs = 0, n = 0, books = {} }
                aul[#aul + 1] = au[b.author]
            end
            au[b.author].books[#au[b.author].books + 1] = i
            au[b.author].secs = au[b.author].secs + (b.secs or 0)
            au[b.author].n = au[b.author].n + 1
        end
    end
    table.sort(aul, function(a, c) return a.secs > c.secs end)
    N.authors = aul
    -- habits: parts of the day
    if A.hours and next(A.hours) then
        local parts = { { _("morning"), 5, 11 }, { _("afternoon"), 12, 17 }, { _("evening"), 18, 21 },
            { _("night"), 22, 28 } }
        local tot, pl = 0, {}
        for i = 1, #parts do
            local p = parts[i]
            local s = 0
            for hh = p[2], p[3] do s = s + (A.hours[hh % 24] or 0) end
            pl[i] = { name = p[1], secs = s }
            tot = tot + s
        end
        table.sort(pl, function(a, c) return a.secs > c.secs end)
        if tot > 0 then N.habits = { list = pl, total = tot } end
    end
    return N
end

-- genres from BookOrbit's saved library records (by title)
local function genres(A, N)
    local recs = {}
    local pc = O.page_cache or {}
    local ck, entry = next(pc)
    while ck do
        local items = type(entry) == "table" and type(entry.items) == "table" and entry.items or {}
        for i = 1, #items do
            local r = items[i]
            if type(r) == "table" and type(r.genres) == "table" and #r.genres > 0 and r.title then
                recs[key(r.title)] = r
            end
        end
        ck, entry = next(pc, ck)
    end
    local g, gl = {}, {}
    for i = 1, #A.books do
        local r = recs[key(A.books[i].title)]
        local name = r and r.genres[1]
        if type(name) == "string" and name ~= "" then
            if not g[name] then
                g[name] = { name = name, n = 0, fin = 0, secs = 0, books = {} }
                gl[#gl + 1] = g[name]
            end
            g[name].books[#g[name].books + 1] = i
            g[name].n = g[name].n + 1
            g[name].secs = g[name].secs + (A.books[i].secs or 0)
            if N.fin[i] then g[name].fin = g[name].fin + 1 end
        end
    end
    table.sort(gl, function(a, c) return a.secs > c.secs end)
    return #gl > 0 and gl or nil
end

-- a stand-in for a book's numbers, for the calendar card and a day's popup
function AllTime.pseudo(A, N)
    local days = {}
    local list = {}
    for k, dd in pairs(A.days) do
        local p = A.src == "bookorbit" and math.floor(dd.secs / 60 + 0.5) or dd.pages
        days[k] = { pages = p, secs = dd.secs, t = dd.t }
        list[#list + 1] = days[k]
    end
    table.sort(list, function(a, c) return a.t < c.t end)
    return { alltime = true, now = os.time(), days = days, day_list = list,
        unit = A.src == "bookorbit" and "min" or "pages",
        finished = false, first = N.first, days_read = N.days_read, days_since = N.days_since, sessions = {} }
end

-- ---- The page -----------------------------------------------------------------------------

-- the tiles in iw x room; nav: { year(), days(), books(filter), popup(i), sheet(spec) }
function AllTime.dashboard(A, iw, room, P, nav)
    local R = rings()
    local N = numbers(A)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g, tp, RAD = px(8), px(12), px(16)
    local taps = {}
    local hue = R and R.hue or function() return P.blue end
    local function tile(w, h, title, accent, on_tap, draw, bg)
        local l = title and text(title, 10, true, SUB) or nil
        local c = canvas(w, h, function(bb, x, y)
            roundFill(bb, x, y, w, h, RAD, bg or P.tile)
            local top = y + tp
            if l then
                roundFill(bb, x + tp, top + px(3), px(14), px(6), px(3), accent or P.blue)
                l:paintTo(bb, x + tp + px(20), top - px(1))
                top = top + l:getSize().h + px(4)
            end
            draw(bb, x + tp, top, w - 2 * tp, y + h - tp - top)
        end)
        if on_tap then taps[#taps + 1] = { c, on_tap } end
        return c
    end
    local function row(list, h)
        local hg = HG:new{ align = "top" }
        local wsum = 0
        for i = 1, #list do wsum = wsum + list[i][1] end
        local left, used = iw - (#list - 1) * g, 0
        for i = 1, #list do
            local w = i == #list and (left - used) or math.floor(left * list[i][1] / wsum)
            used = used + w
            if i > 1 then hg[#hg + 1] = HS:new{ width = g } end
            hg[#hg + 1] = list[i][2](w, h)
        end
        return hg
    end
    -- 2.1.30: taller number tiles
    local H = { hero = px(196), nums = px(112), mid = px(236), mom = px(224), small = px(110) }
    local function total() return H.hero + H.nums + H.mid + H.mom + H.small + 4 * g end
    if total() > room then
        local k = (room - 4 * g) / (total() - 4 * g)
        for kk, v in pairs(H) do H[kk] = math.floor(v * k) end
    end
    local col = VG:new{ align = "left" }
    local function gap() col[#col + 1] = VS:new{ width = g } end
    local ON = P.colour and (P.night and PAPER or INK) or PAPER

    -- the hero
    local h1 = text(_("All your reading"), 22, true, INK, iw - 2 * tp)
    local subl = { T(_("since %1"), K.day(N.first) .. (os.date("%Y",
        N.first) == os.date("%Y") and os.date(", %Y", N.first) or "")),
        T(_("%1 days read"), N.days_read), T(_("%1 books opened"), #A.books) }
    local h2 = text(table.concat(subl, "  ·  "), 12, false, SUB, iw - 2 * tp)
    local function hpill(label, k)
        local t = text(label, 12, true, INK)
        local w, h = t:getSize().w + px(36), t:getSize().h + px(10)
        local solid = P.colour and O.Sheet and O.Sheet.pillsColoured and O.Sheet.pillsColoured(P) and O.Sheet.solid(P) or nil -- 2.1.34 / 2.1.36
        return canvas(w, h, function(bb, x, y)
            bb:paintBorder(x, y, w, h, px(2), solid and solid.v or INK, math.floor(h / 2))
            disc(bb, x + px(14), y + math.floor(h / 2), px(6), k)
            t:paintTo(bb, x + px(26), y + px(5))
        end)
    end
    local pills = { { hpill(_("Your Year ›"), P.gold), function() nav.year() end } }
    if #A.finished > 0 then pills[#pills + 1] = { hpill(T(_("Finished %1"), #A.finished), P.green),
        function() nav.books("finished") end } end
    if N.reading > 0 then pills[#pills + 1] = { hpill(T(_("Reading %1"), N.reading), P.blue),
        function() nav.books("reading") end } end
    -- the line: the finished books in order, then the one you're on
    local seq = {}
    for i = 1, #A.finished do seq[#seq + 1] = { book = A.finished[i].book, done = true } end
    if A.now and A.now.book and not N.fin[A.now.book] then seq[#seq + 1] = { book = A.now.book, pct = A.now.pct } end
    while #seq > 5 do table.remove(seq, 1) end
    local seg_labels = {}
    for i = 1, #seq do
        local b = A.books[seq[i].book]
        seg_labels[i] = text(short(b and b.title), 11, true, INK)
    end
    local now_t, now_s
    if A.now and A.now.book and A.books[A.now.book] then
        now_t = text(T(_("now %1%"), math.floor(A.now.pct * 100 + 0.5)), 14, true, INK)
        now_s = text(short(A.books[A.now.book].title), 10, false, SUB, px(170))
    end
    -- 2.1.30 (TK): bigger, filling the hero's top right
    local crit = K.critter("happy", px(120), math.max(px(40), H.hero - px(80)))
    local seg_hits, line_at = {}, nil
    local hero = tile(iw, H.hero, nil, nil, nil, function(bb, x, y, w, h)
        h1:paintTo(bb, x, y - px(2))
        -- 2.1.29 (TK): the critter sits in the top right (all your reading, not one book)
        if crit then
            local cd = crit.dimen or { w = px(30), h = px(30) }
            crit:paintTo(bb, x + w - cd.w, y - px(2))
        end
        local yy = y + h1:getSize().h
        h2:paintTo(bb, x, yy)
        yy = yy + h2:getSize().h + px(8)
        local px0 = x
        local pills_bottom = yy
        for i = 1, #pills do
            local pc = pills[i][1]
            pc:paintTo(bb, px0, yy)
            px0 = px0 + pc:getSize().w + px(10)
            pills_bottom = math.max(pills_bottom, yy + pc:getSize().h)
        end
        if #seq == 0 then return end
        local line_y = y + h - px(14)
        line_at = line_y
        for k = #seg_hits, 1, -1 do seg_hits[k] = nil end
        local right = now_t and (math.max(now_t:getSize().w, now_s:getSize().w) + px(14)) or 0
        local lw = w - right
        -- 2.1.29: longer for more time, but never too thin to see (equal without times)
        local raw, tot = {}, 0
        for i = 1, #seq do raw[i] = A.books[seq[i].book].secs or 0 tot = tot + raw[i] end
        local floor_w = tot > 0 and tot / (#seq * 3) or 1
        tot = 0
        for i = 1, #seq do raw[i] = math.max(floor_w, raw[i]) tot = tot + raw[i] end
        local sx = x
        for i = 1, #seq do
            local e = seq[i]
            local sw = math.floor(lw * raw[i] / tot)
            if i == #seq then sw = x + lw - sx end
            local k = hue(P, e.book)
            roundFill(bb, sx, line_y - px(6), sw - px(3), px(12), px(6), k)
            seg_hits[#seg_hits + 1] = { x0 = sx, x1 = sx + sw, book = e.book }
            local lab = seg_labels[i]
            -- 2.1.31 (TK): a title only where it fits under the pills ("No Exit" ran into Your Year)
            local ly = line_y - px(10) - lab:getSize().h
            if lab:getSize().w < sw - px(8) and ly >= pills_bottom + px(2) then lab:paintTo(bb, sx + px(4), ly) end
            if e.done then
                disc(bb, sx + sw - px(4), line_y, px(10), P.paper)
                disc(bb, sx + sw - px(4), line_y, px(8), P.colour and P.green or P.ink)
                local ck = text("✓", 10, true, ON)
                ck:paintTo(bb, sx + sw - px(4) - math.floor(ck:getSize().w / 2),
                    line_y - math.floor(ck:getSize().h / 2))
            else
                -- where you are in the book you're reading: a marker on its piece
                local cx = sx + math.floor((sw - px(3)) * (e.pct or 1))
                disc(bb, cx, line_y, px(9), P.paper)
                disc(bb, cx, line_y, px(6), P.ink)
            end
            sx = sx + sw
        end
        if now_t then
            now_t:paintTo(bb, x + w - right + px(14), line_y - now_t:getSize().h - px(2))
            now_s:paintTo(bb, x + w - right + px(14), line_y)
        end
    end, P.tile_hero)
    col[#col + 1] = hero
    for i = 1, #pills do
        local fn = pills[i][2]
        taps[#taps + 1] = { pills[i][1], fn }
    end
    -- 2.1.30 (TK): tap a book on the line for its popup (after the pills, so they win)
    taps[#taps + 1] = { hero, function()
        local pos = K.tapPos()
        if not (pos and line_at) or pos.y < line_at - px(40) then return end
        for k = 1, #seg_hits do
            local hh = seg_hits[k]
            if pos.x >= hh.x0 and pos.x < hh.x1 then return nav.popup(hh.book) end
        end
    end }
    gap()

    -- TIME / DAYS / BOOKS / PAGES
    local function num(title, k, big, small, on_tap)
        return { 1, function(w, h)
            -- 2.1.30 (TK): the number and its line shrink to fit the tile (they ran out of it)
            local head = text(title, 10, true, SUB):getSize().h + px(4)
            local fit_h = h - tp - px(6) - head -- a little less padding at the bottom
            local b, s
            for try = 1, 6 do
                local bs = ({ 24, 22, 20, 18, 16, 14 })[try]
                b = text(big, bs, true, INK, w - 2 * tp)
                s = text(small, bs >= 20 and 10 or 9, false, SUB, w - 2 * tp)
                if b:getSize().h + s:getSize().h <= fit_h then break end
            end
            return tile(w, h, title, k, on_tap, function(bb, x, y)
                b:paintTo(bb, x, y)
                s:paintTo(bb, x, y + b:getSize().h)
            end)
        end }
    end
    local per_day = N.days_read > 0 and A.total / N.days_read or 0
    local pph = (A.src == "kobo" and A.total > 0) and math.floor(A.pages * 3600 / A.total + 0.5) or nil
    col[#col + 1] = row({
        num(_("TIME"), P.blue, durS(A.total), T(_("%1 a reading day"), durS(per_day)), function() nav.days("time") end),
        num(_("DAYS"), P.green, N.days_read .. "/" .. N.days_since, _("days read"), function() nav.days() end),
        num(_("BOOKS"), P.red, tostring(#A.finished), T(_("finished · %1 reading"), N.reading),
            function() nav.books() end),
        num(_("PAGES"), P.gold, A.pages > 0 and tostring(A.pages) or "–",
            pph and T(_("%1 pages an hour"), pph) or (A.pages > 0 and _("read") or _("not on BookOrbit")),
            function() nav.books() end),
    }, H.nums)
    gap()

    -- the months ring, this week
    local ml = N.months
    local mnames = {}
    for i = 1, #ml do mnames[i] = os.date("%b", os.time{ year = tonumber(ml[i].k:sub(1, 4)),
        month = tonumber(ml[i].k:sub(6, 7)), day = 15, hour = 12 }) end
    local top_t = N.top_month and text(T(_("%1 %2"), os.date("%b", os.time{ year = tonumber(N.top_month.k:sub(1, 4)),
        month = tonumber(N.top_month.k:sub(6, 7)), day = 15, hour = 12 }), durS(N.top_month.secs)), 22, true,
            INK) or nil
    local top_s = text(_("your biggest month"), 12, false, SUB)
    local this_s = text(T(_("this month %1"), durS(N.this_month)), 12, false, SUB)
    local mtitle = T(_("MONTHS · %1 HOURS"), string.format("%.1f", A.total / 3600))
    local chg = N.lwk > 0 and math.floor((N.wk - N.lwk) / N.lwk * 100 + 0.5) or nil
    col[#col + 1] = row({
        { 1.25, function(w, h)
            return tile(w, h, mtitle, P.green, function() nav.year() end, function(bb, x, y, cw, ch)
                local d = math.min(ch, math.floor(cw * 0.5))
                if R and R.drawRing and #ml > 0 then
                    local s = { n = math.max(#ml, 4), bars = {}, gap = 0.1, labels = {}, label_size = 10,
                        label_gap = 14 }
                    local mx = 1
                    for i = 1, #ml do mx = math.max(mx, ml[i].secs) end
                    local off = s.n - #ml
                    for i = 1, #ml do
                        s.bars[off + i] = { v = ml[i].secs / mx, k = hue(P, i) }
                        if #ml <= 12 then s.labels[off + i] = mnames[i] end
                    end
                    s.cx, s.cy = x + math.floor(d / 2), y + math.floor(ch / 2)
                    s.reach = math.floor(d / 2) - px(4)
                    s.rin = math.floor(s.reach * 0.5)
                    s.labels = nil
                    R.drawRing(bb, s, P)
                    local c1 = text(tostring(#ml), 18, true, INK)
                    local c2 = text(#ml == 1 and _("month") or _("months"), 10, false, SUB)
                    c1:paintTo(bb, s.cx - math.floor(c1:getSize().w / 2), s.cy - c1:getSize().h + px(4))
                    c2:paintTo(bb, s.cx - math.floor(c2:getSize().w / 2), s.cy + px(4))
                end
                local tx = x + d + px(16)
                local ty = y + math.floor(ch / 2) - px(40)
                if top_t then top_t:paintTo(bb, tx, ty) ty = ty + top_t:getSize().h end
                top_s:paintTo(bb, tx, ty)
                this_s:paintTo(bb, tx, ty + top_s:getSize().h + px(4))
            end)
        end },
        { 1, function(w, h)
            local big = text(durS(N.wk), 20, true, INK)
            local badge = chg and text((chg >= 0 and "▲ " or "▼ ") .. math.abs(chg) .. "%", 12, true, ON) or nil
            local wk = { _("M"), _("T"), _("W"), _("T"), _("F"), _("S"), _("S") }
            return tile(w, h, _("THIS WEEK"), P.blue, function() nav.days() end, function(bb, x, y, cw, ch)
                big:paintTo(bb, x, y)
                if badge then
                    local bw = badge:getSize().w + px(16)
                    local bx = x + cw - bw
                    roundFill(bb, bx, y + px(2), bw, badge:getSize().h + px(6), px(10), chg >= 0 and P.green or P.red)
                    badge:paintTo(bb, bx + px(8), y + px(5))
                end
                local gy = y + big:getSize().h + px(8)
                local lh = text("M", 10, false, SUB):getSize().h
                local gh = ch - (gy - y) - lh - px(4)
                local vmax = 1
                for i = 1, 7 do vmax = math.max(vmax, N.week[i], N.lweek[i]) end
                local slot = cw / 7
                local bw = math.floor(slot * 0.55)
                for i = 1, 7 do
                    local bx = x + math.floor((i - 1) * slot + (slot - bw) / 2)
                    local bh = math.floor(N.week[i] / vmax * gh)
                    if bh > 0 then roundFill(bb, bx, gy + gh - bh, bw, bh, px(4),
                        N.week[i] >= N.lweek[i] and P.green or P.blue)
                    elseif i <= N.wd then fill(bb, bx, gy + gh - px(2), bw, px(2), P.blue) end
                    local l = text(wk[i], 10, i == N.wd, i == N.wd and INK or SUB)
                    l:paintTo(bb, bx + math.floor((bw - l:getSize().w) / 2), gy + gh + px(4))
                end
            end)
        end },
    }, H.mid)
    gap()

    -- moments, the books
    local moments = {}
    if N.best then moments[#moments + 1] = { P.green, T(_("Best day: %1, %2"), dayShort(N.best.t),
        durS(N.best.secs)) } end
    if N.streak then moments[#moments + 1] = { P.red, T(_("%1 days in a row, %2–%3"), N.streak.n,
        dayShort(N.streak.from), dayShort(N.streak.to)) } end
    if N.fastest then moments[#moments + 1] = { P.blue, T(_("Fastest: %1, %2 days"),
        short(A.books[N.fastest.book].title), N.fastest.days) } end
    if A.sit and A.sit.secs >= 600 then moments[#moments + 1] = { P.gold, T(_("Most in one go: %1, %2"),
        durS(A.sit.secs), dayShort(A.sit.start)) } end
    if #A.finished > 0 then moments[#moments + 1] = { P.blue, T(_("%1 finished since %2"),
        #A.finished == 1 and _("1 book") or T(_("%1 books"), #A.finished),
        os.date("%b %Y", A.finished[1].t)) } end
    local by = N.by_time
    col[#col + 1] = row({
        { 1, function(w, h)
            local ls = {}
            for i = 1, #moments do ls[i] = text(moments[i][2], 12, true, INK, w - 2 * tp - px(24)) end
            return tile(w, h, _("MOMENTS"), P.red, function() nav.moments(moments) end, function(bb, x, y, cw, ch)
                local yy = y + px(4)
                for i = 1, #ls do
                    if yy + ls[i]:getSize().h > y + ch or ls[i]:getSize().w > cw then break end
                    disc(bb, x + px(8), yy + math.floor(ls[i]:getSize().h / 2), px(7), moments[i][1])
                    ls[i]:paintTo(bb, x + px(24), yy)
                    yy = yy + ls[i]:getSize().h + px(10)
                end
            end)
        end },
        { 1, function(w, h)
            -- 2.1.29: BookOrbit doesn't say how long each book took: the finished ones by date instead
            local timed = by[1] and (A.books[by[1]].secs or 0) >= 60
            if not timed then
                local fl = {}
                for i = #A.finished, math.max(1, #A.finished - 4), -1 do fl[#fl + 1] = A.finished[i] end
                local lead2 = text(#A.finished == 1 and _("1 book finished") or T(_("%1 books finished"), #A.finished),
                    13, true, INK, w - 2 * tp)
                local rows = {}
                for i = 1, #fl do
                    rows[i] = { text(short(A.books[fl[i].book].title), 11, false, SUB, math.floor((w - 2 * tp) * 0.7)),
                        text(dayShort(fl[i].t), 10, true, INK) }
                end
                local rh_hits = {}
                return tile(w, h, _("BOOKS"), P.blue, function()
                    local pos = K.tapPos()
                    for k = 1, #rh_hits do
                        local hh = rh_hits[k]
                        if pos and pos.y >= hh.y0 and pos.y < hh.y1 then return nav.popup(hh.book) end
                    end
                    nav.books()
                end, function(bb, x, y, cw, ch)
                    for k = #rh_hits, 1, -1 do rh_hits[k] = nil end
                    lead2:paintTo(bb, x, y)
                    local yy = y + lead2:getSize().h + px(8)
                    for i = 1, #rows do
                        local rh = rows[i][1]:getSize().h + px(6)
                        if yy + rh > y + ch then break end
                        disc(bb, x + px(5), yy + math.floor(rh / 2) - px(3), px(5), hue(P, fl[i].book))
                        rows[i][1]:paintTo(bb, x + px(16), yy)
                        rh_hits[#rh_hits + 1] = { y0 = yy, y1 = yy + rh, book = fl[i].book }
                        rows[i][2]:paintTo(bb, x + cw - rows[i][2]:getSize().w, yy)
                        yy = yy + rh
                    end
                end)
            end
            local lead = by[1] and text(T(_("Longest: %1, %2"), short(A.books[by[1]].title),
                durS(A.books[by[1]].secs)), 13, true, INK, w - 2 * tp) or nil
            local names, vals = {}, {}
            for i = 1, math.min(5, #by) do
                names[i] = text(short(A.books[by[i]].title), 11, false, SUB, math.floor((w - 2 * tp) * 0.36))
                vals[i] = text(durS(A.books[by[i]].secs), 10, true, INK)
            end
            -- 2.1.30 (TK): tap a book's row for its popup; anywhere else, every book
            local bh_hits = {}
            return tile(w, h, _("BOOKS"), P.blue, function()
                local pos = K.tapPos()
                for k = 1, #bh_hits do
                    local hh = bh_hits[k]
                    if pos and pos.y >= hh.y0 and pos.y < hh.y1 then return nav.popup(hh.book) end
                end
                nav.books()
            end, function(bb, x, y, cw, ch)
                for k = #bh_hits, 1, -1 do bh_hits[k] = nil end
                local yy = y
                if lead then lead:paintTo(bb, x, yy) yy = yy + lead:getSize().h + px(8) end
                local mx = by[1] and math.max(1, A.books[by[1]].secs) or 1
                local nw = math.floor(cw * 0.38)
                local rowh = names[1] and (names[1]:getSize().h + px(6)) or px(20)
                for i = 1, #names do
                    if yy + rowh > y + ch then break end
                    names[i]:paintTo(bb, x, yy)
                    bh_hits[#bh_hits + 1] = { y0 = yy, y1 = yy + rowh, book = by[i] }
                    local bw = math.max(px(6),
                        math.floor((cw - nw - vals[i]:getSize().w - px(8)) * A.books[by[i]].secs / mx))
                    roundFill(bb, x + nw, yy + px(3), bw, rowh - px(10), px(6), hue(P, by[i]))
                    vals[i]:paintTo(bb, x + nw + bw + px(6), yy)
                    yy = yy + rowh
                end
            end)
        end },
    }, H.mom)
    gap()

    -- authors, genres, habits: two short lines each (2.1.29, TK: they ran off the tiles)
    local small = {}
    local function two(title, k, l1, l2, on_tap)
        return { 1, function(w, h)
            local t1 = text(l1, 14, true, INK, w - 2 * tp)
            local t2 = text(l2, 11, false, SUB, w - 2 * tp)
            return tile(w, h, title, k, on_tap, function(bb, x, y)
                t1:paintTo(bb, x, y)
                t2:paintTo(bb, x, y + t1:getSize().h + px(2))
            end)
        end }
    end
    local function nbooks(nn) return nn == 1 and _("1 book") or T(_("%1 books"), nn) end
    local au = N.authors
    if au[1] then
        local l2 = (au[1].secs or 0) >= 60 and (durS(au[1].secs) .. " · " .. nbooks(au[1].n)) or nbooks(au[1].n)
        small[#small + 1] = two(_("AUTHORS"), P.gold, au[1].name, l2, function() nav.authors(au) end)
    end
    local gl = genres(A, N)
    if gl then
        small[#small + 1] = two(_("GENRES"), P.colour and hue(P, 4) or P.blue, gl[1].name,
            T(_("%1 of %2 finished"), gl[1].fin, gl[1].n), function() nav.genres(gl) end)
    end
    if N.habits then
        local hl = N.habits.list
        local nm = hl[1].name
        local cap = nm:sub(1, 1):upper() .. nm:sub(2) .. "s"
        local l2 = math.floor(hl[1].secs / N.habits.total * 100 + 0.5) .. "%"
            .. (hl[2] and (" · " .. T(_("%1 next"), hl[2].name .. "s")) or "")
        small[#small + 1] = two(_("HABITS"), P.green, cap, l2, function() nav.habits(N.habits) end)
    end
    if #small > 0 then col[#col + 1] = row(small, H.small) end
    return col, taps, N
end

-- the little sheets behind Moments, Authors, Genres and Habits
function AllTime.listSheet(title, rows, sub)
    if not O.Sheet then return end
    local list = {}
    for i = 1, #rows do
        local cb = rows[i][4]
        list[i] = { arrow = cb ~= nil, text = rows[i][1], note = rows[i][2], colour = rows[i][3] or "blue",
            keep = cb ~= nil, callback = cb }
    end
    O.Sheet.show({ title = title, subtitle = sub, cancel = false, sections = { { colour = "blue", plain = true,
        items = { { kind = "list", list = list } } } } })
end

return AllTime
