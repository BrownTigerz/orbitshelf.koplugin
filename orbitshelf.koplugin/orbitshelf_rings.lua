-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Reading Stats rings (2.1.13, from TK's pick of BookOrbit's iPhone Activity ring):
--   * the month for this book: one wedge a day round a circle, longer for a longer read,
--     coloured by the chapter you were in (This Kobo) or read / listened (BookOrbit),
--     with your sittings as dots inside, skipped days, the best day and the likely finish
--   * the small one on the stats page's month tile
--   * Your Year (all books): a bar a day coloured by the book, a dot where each book was
--     finished, and the year's shelf in Bookshelf's own spines (plain ones without it).
--     This Kobo: KOReader's statistics. BookOrbit: four calls an API key may make
--     (reading-heatmap, reading-history, its summary and peak-hours for audio).
-- The drawing helpers are the stats page's own (O.Stats._kit).
local O = require("orbitshelf_core")
local T, _ = O.T, O._

local Rings = {}

-- 2.1.24: load the stats page first. Diagnostics asked for this file at boot before the
-- stats page had loaded, the first load failed, and Lua then refused it for the rest of
-- the session ("loop or previous error loading module"): the ring always fell back.
if not (O.Stats and O.Stats._kit) then require("orbitshelf_stats") end
local K = O.Stats._kit
local px, text, fill, disc, roundFill, canvas = K.px, K.text, K.fill, K.disc, K.roundFill, K.canvas
local dayKey, midnight, durS, dayShort, rgb, grey = K.dayKey, K.midnight, K.durS, K.dayShort, K.rgb, K.grey
local INK, MID, SUB, PAPER = K.INK, K.MID, K.SUB, K.PAPER

local function W(name) return require("ui/widget/" .. name) end

local TAU = 2 * math.pi
local LISTEN = { listen = true, tts = true }
local AUDIO = { M4B = true, MP3 = true, M4A = true, OPUS = true, OGG = true, FLAC = true }

-- the vibrant colours (the sheets' own), flipped first in night mode; greys without colour
local HUE_RGB = { { 45, 135, 255 }, { 30, 200, 110 }, { 255, 180, 0 }, { 165, 95, 245 }, { 0, 195, 205 },
    { 255, 125, 30 }, { 255, 70, 70 }, { 245, 85, 165 } }
local GREYS = { 0x22, 0x66, 0x44, 0x88, 0x33, 0x77, 0x55, 0x99 }
-- 2.1.15: the Colour Theme's, in this order (Vibrant = HUE_RGB)
local RING_ORDER = { "blue", "green", "gold", "purple", "teal", "orange", "red", "pink" }
local function themed(i)
    if O.Theme and not O.Theme.isDefault() then return O.Theme.rgb(RING_ORDER[i]) end
    return HUE_RGB[i]
end
local function hue(P, i)
    i = ((i - 1) % #HUE_RGB) + 1
    if not P.colour then return grey(K.C(GREYS[i])) end
    local c = themed(i)
    return rgb(c[1], c[2], c[3], P.night)
end
local function pink(P)
    if not P.colour then return grey(K.C(0x99)) end
    local c = themed(8)
    return rgb(c[1], c[2], c[3], P.night)
end

-- ---- Drawing ----------------------------------------------------------------------------

-- a ring piece: radii r0..r1, from angle a1 to a2 (radians, 0 = up, clockwise)
-- 2.1.15: which side of the two edges a pixel is on (two multiplications) instead of its
-- angle (atan2), and each row only across the ring: about 5 times faster
local function sector(bb, cx, cy, r0, r1, a1, a2, k)
    if r1 <= r0 or a2 <= a1 then return end
    local span = a2 - a1
    local full = span >= TAU - 1e-6
    local big = span > math.pi
    local ux1, uy1 = math.sin(a1), -math.cos(a1)
    local ux2, uy2 = math.sin(a2), -math.cos(a2)
    local x0, x1, y0, y1 = math.huge, -math.huge, math.huge, -math.huge
    local steps = full and 32 or 24
    for i = 0, steps do
        local a = a1 + math.min(span, TAU) * i / steps
        for _j, r in ipairs({ r0, r1 }) do
            local x, y = cx + r * math.sin(a), cy - r * math.cos(a)
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
    end
    local r0s, r1s = r0 * r0, r1 * r1
    local fx0, fx1 = math.floor(x0) - 1, math.ceil(x1) + 1
    for yy = math.floor(y0) - 1, math.ceil(y1) + 1 do
        local dy = yy + 0.5 - cy
        local dy2 = dy * dy
        if dy2 <= r1s then
            local xo = math.sqrt(r1s - dy2)
            local xs = math.max(fx0, math.floor(cx - xo) - 1)
            local xe = math.min(fx1, math.ceil(cx + xo) + 1)
            local run
            for xx = xs, xe do
                local dx = xx + 0.5 - cx
                local d2 = dx * dx + dy2
                local inside = d2 >= r0s and d2 <= r1s
                if inside and not full then
                    local c1 = ux1 * dy - uy1 * dx
                    local c2 = dx * uy2 - dy * ux2
                    if big then inside = c1 >= 0 or c2 >= 0 else inside = c1 >= 0 and c2 >= 0 end
                end
                if inside then
                    run = run or xx
                elseif run then
                    fill(bb, run, yy, xx - run, 1, k)
                    run = nil
                end
            end
            if run then fill(bb, run, yy, xe + 1 - run, 1, k) end
        end
    end
end

local function at(cx, cy, r, a) return cx + r * math.sin(a), cy - r * math.cos(a) end

-- a small flag (the likely finish)
local function flag(bb, x, y, P)
    bb:paintRect(math.floor(x), math.floor(y - px(9)), px(2), px(18), INK)
    for i = 0, px(7) do fill(bb, math.floor(x) + px(2), math.floor(y - px(9)) + i, px(9) - i, 1, P.gold) end
end

-- the ring. s: n slots, cx, cy, rin (the circle), reach (how far the longest bar goes),
-- bars[i] = { v = 0-1, k, v2, k2 (stacked, striped) }, sits[i] = n dots (colour dot_k[i]),
-- skipped[i], ahead_from, today, best, finish, labels[i] = text, label_bold, gap (0-0.5),
-- marks[i] = { colour } (dots inside, the year's finished books)
local function drawRing(bb, s, P)
    local slot = TAU / s.n
    local gap = s.gap or 0.12
    local base = s.rin + (s.lift or px(4))
    local len = s.reach - base
    -- the circle
    sector(bb, s.cx, s.cy, s.rin - px(1), s.rin + px(1), 0, TAU, P.soft)
    for i = 1, s.n do
        local a0 = (i - 1) * slot
        local am = a0 + slot / 2
        local b = s.bars[i]
        if b and (b.v or 0) > 0 then
            local r1 = base + math.max(px(3), len * b.v)
            sector(bb, s.cx, s.cy, base, r1, a0 + gap * slot, a0 + (1 - gap) * slot, b.k)
            -- 2.1.14: cut into one piece a sitting
            local cuts = s.cuts and s.cuts[i] or 0
            if cuts > 1 and r1 - base > cuts * px(6) then
                local seg = (r1 - base) / cuts
                for c = 1, cuts - 1 do
                    local rc = base + c * seg
                    sector(bb, s.cx, s.cy, rc - px(1.5), rc + px(1.5), a0 + (gap - 0.04) * slot, a0 + (1 - gap + 0.04) * slot, P.paper)
                end
            end
            if (b.v2 or 0) > 0 then
                local r2 = r1 + math.max(px(3), len * b.v2)
                sector(bb, s.cx, s.cy, r1, r2, a0 + gap * slot, a0 + (1 - gap) * slot, b.k2)
                -- striped: listened
                local r = r1 + px(3)
                while r < r2 - px(1) do
                    sector(bb, s.cx, s.cy, r, math.min(r2, r + px(2)), a0 + gap * slot, a0 + (1 - gap) * slot, P.paper)
                    r = r + px(5)
                end
                r1 = r2
            end
            if s.best == i and s.star then
                local x, y = at(s.cx, s.cy, r1 + px(12), am)
                s.star:paintTo(bb, math.floor(x - s.star:getSize().w / 2), math.floor(y - s.star:getSize().h / 2))
            end
        elseif s.skipped and s.skipped[i] then
            local x, y = at(s.cx, s.cy, base + px(6), am)
            disc(bb, math.floor(x), math.floor(y), px(4), P.mid)
            disc(bb, math.floor(x), math.floor(y), px(2), P.paper)
        elseif s.ahead_from and i >= s.ahead_from and (s.ahead_step == nil or i % s.ahead_step == 0) then
            local x, y = at(s.cx, s.cy, base + px(6), am)
            disc(bb, math.floor(x), math.floor(y), px(2), P.soft)
        end
        if s.sits and (s.sits[i] or 0) > 0 then
            for j = 1, math.min(3, s.sits[i]) do
                local x, y = at(s.cx, s.cy, s.rin - px(7) - (j - 1) * px(8), am)
                disc(bb, math.floor(x), math.floor(y), px(3), s.dot_k and s.dot_k[i] or P.blue)
            end
        end
        if s.marks and s.marks[i] then
            local x, y = at(s.cx, s.cy, s.rin - px(12), am)
            disc(bb, math.floor(x), math.floor(y), px(7), P.paper)
            disc(bb, math.floor(x), math.floor(y), px(5), s.marks[i])
        end
        if s.finish == i then
            local x, y = at(s.cx, s.cy, s.reach * 0.55 + base * 0.45, am)
            flag(bb, x, y, P)
        end
        if s.labels and s.labels[i] then
            local l = text(s.labels[i], s.label_size or 11, s.label_bold == i, s.label_bold == i and INK or SUB)
            local x, y = at(s.cx, s.cy, s.reach + px(s.label_gap or 18), s.label_at_start and a0 or am)
            l:paintTo(bb, math.floor(x - l:getSize().w / 2), math.floor(y - l:getSize().h / 2))
        end
    end
    -- 2.1.14: a clock face inside the circle: a tick a slot (longer every 5 days, gold
    -- where a month starts), the numbers like a clock's hours, today's in a gold disc
    if s.face then
        local f = s.face
        for i = 1, s.n do
            local kind = f.ticks[i]
            if kind then
                local a0 = (i - 1) * slot
                local L = kind == "month" and px(13) or (kind == "five" and px(8) or px(4))
                local k = kind == "month" and P.gold or (kind == "five" and P.mid or P.soft)
                local th = kind == "month" and 0.012 or 0.006
                sector(bb, s.cx, s.cy, s.rin - px(2) - L, s.rin - px(2), a0 - th, a0 + th, k)
            end
            local num = f.nums[i]
            if num then
                local am = (i - 0.5) * slot
                local x, y = at(s.cx, s.cy, s.rin - px(f.num_r or 26), am)
                if s.today == i then
                    disc(bb, math.floor(x), math.floor(y), px(12), P.gold)
                    local t = text(num, 11, true, P.colour and (P.night and PAPER or INK) or PAPER)
                    if not P.colour then disc(bb, math.floor(x), math.floor(y), px(12), P.ink) end
                    t:paintTo(bb, math.floor(x - t:getSize().w / 2), math.floor(y - t:getSize().h / 2))
                else
                    local gold = f.gold and f.gold[i]
                    local t = text(num, gold and 10 or 11, gold, gold and INK or SUB)
                    if gold and P.colour then
                        local w2, h2 = t:getSize().w + px(8), t:getSize().h
                        roundFill(bb, math.floor(x - w2 / 2), math.floor(y - h2 / 2), w2, h2, px(5), P.gold_soft or P.tile)
                    end
                    t:paintTo(bb, math.floor(x - t:getSize().w / 2), math.floor(y - t:getSize().h / 2))
                end
            end
        end
    elseif s.today then
        local x, y = at(s.cx, s.cy, s.rin, (s.today - 0.5) * slot)
        disc(bb, math.floor(x), math.floor(y), px(9), P.paper)
        disc(bb, math.floor(x), math.floor(y), px(7), P.ink)
        disc(bb, math.floor(x), math.floor(y), px(5), P.gold)
    end
end

-- lines of text centred at cx from y (list of widgets)
local function centred(bb, cx, y, list)
    for _i, l in ipairs(list) do
        if l then
            l:paintTo(bb, math.floor(cx - l:getSize().w / 2), y)
            y = y + l:getSize().h
        end
    end
end
local function stackH(list)
    local h = 0
    for _i, l in ipairs(list) do if l then h = h + l:getSize().h end end
    return h
end

-- ---- The month (this book) ------------------------------------------------------------

local function monthOf(d, off)
    local base = os.date("*t", d.finished and d.finish_t or d.now)
    local t = os.time{ year = base.year, month = base.month + (off or 0), day = 1, hour = 12 }
    local mt = os.date("*t", t)
    local ndays = os.date("*t", os.time{ year = mt.year, month = mt.month + 1, day = 0, hour = 12 }).day
    return { year = mt.year, month = mt.month, ndays = ndays, t = t }
end
local function dayT(m, k)
    if m.day then return m.day(k) end
    return os.time{ year = m.year, month = m.month, day = k, hour = 12 }
end

-- 2.1.14: the whole read (this read's first day to the finish, or the likely finish),
-- a day a slot; a week a slot past 9 weeks
local function readSpan(d)
    local rd = d.reads and d.reads[#d.reads]
    local t0 = midnight(rd and rd.start or d.first) + 12 * 3600
    local t1 = d.finished and d.finish_t or math.max(d.now, d.finish_t or d.now)
    local days = K.daysBetween(midnight(t0), midnight(t1)) + 1
    local step = days > 63 and 7 or 1
    return { read = true, step = step, ndays = math.ceil(days / step), t = t0, t_end = t1, days = days,
        day = function(k) return t0 + (k - 1) * step * 86400 end }
end

-- each day of the month: time, listened, pages, sittings, where the day ended
local function monthDays(d, m)
    local out = { max = 0, total = 0, listen = 0, amount = 0, read_days = 0 }
    local idx = {}
    local step = m.step or 1
    for k = 1, m.ndays do
        out[k] = { secs = 0, listen = 0, pages = 0, sits = 0, key = dayKey(dayT(m, k)) }
        for j = 0, step - 1 do idx[dayKey(dayT(m, k) + j * 86400)] = k end
    end
    for _i, s in ipairs(d.sessions or {}) do
        local k = idx[dayKey(s.start)]
        if k then
            out[k].sits = out[k].sits + 1
            if LISTEN[s.kind] then out[k].listen = out[k].listen + s.secs end
        end
    end
    for k = 1, m.ndays do
        local o = out[k]
        for j = 0, step - 1 do
            local dd = d.days[dayKey(dayT(m, k) + j * 86400)]
            if dd and dd.secs > 0 then
                o.secs, o.pages = o.secs + dd.secs, o.pages + dd.pages
                o.reached = math.max(o.reached or 0, dd.reached or 0)
                out.read_days = out.read_days + 1
            end
        end
        if o.secs > 0 then
            o.listen = math.min(o.listen, o.secs)
            out.total, out.listen, out.amount = out.total + o.secs, out.listen + o.listen, out.amount + o.pages
            if o.secs > out.max then out.max, out.best = o.secs, k end
        else
            o.listen = 0
        end
    end
    return out
end

-- today, this week (against last), the streak now and the longest
local function nowNumbers(d)
    local today = midnight(d.now)
    local r = { today = d.days[dayKey(today + 3600)] }
    local wd = (tonumber(os.date("%w", today)) + 6) % 7
    local mon = today - wd * 86400
    r.week, r.last_week = 0, 0
    for i = 0, 6 do
        local a = d.days[dayKey(mon + i * 86400 + 3600)]
        local b = d.days[dayKey(mon - (7 - i) * 86400 + 3600)]
        r.week = r.week + (a and a.secs or 0)
        r.last_week = r.last_week + (b and b.secs or 0)
    end
    local t = r.today and today or today - 86400
    r.streak = 0
    while d.days[dayKey(t + 3600)] do r.streak, t = r.streak + 1, t - 86400 end
    r.longest = 0
    local run, prev = 0, nil
    for _i, dd in ipairs(d.day_list or {}) do
        if prev and K.daysBetween(prev, dd.t) == 1 then run = run + 1 else run = 1 end
        prev = dd.t
        if run > r.longest then r.longest = run end
    end
    r.sits_today = 0
    for _i, s in ipairs(d.sessions or {}) do if s.start >= today then r.sits_today = r.sits_today + 1 end end
    return r
end

-- which chapter a page is in (chapters from the stats page's own list)
local function chapterAt(chs, page)
    if not chs then return nil end
    for i, c in ipairs(chs) do if page >= c.a and page <= c.b then return i end end
    return nil
end

-- the ring's spec for the month; small: the tile's (no labels, no dots inside)
local function monthSpec(d, m, md, P, extra, small)
    local chs = extra and extra.chapters
    local s = { n = m.ndays, bars = {}, cuts = {}, skipped = {} }
    local rd = d.reads and d.reads[#d.reads]
    local first_t = midnight(rd and rd.start or d.first)
    local step = m.step or 1
    local function slotOf(t)
        local key = dayKey(t)
        for k = 1, m.ndays do
            for j = 0, step - 1 do if dayKey(dayT(m, k) + j * 86400) == key then return k end end
        end
    end
    for k = 1, m.ndays do
        local o = md[k]
        local t = dayT(m, k)
        if o.secs > 0 then
            local col
            local ci = o.reached and chapterAt(chs, math.max(1, math.floor(o.reached * d.total + 0.5)))
            if ci then col = hue(P, ci) else col = hue(P, math.floor((k - 1) * step / 7) + 1) end
            local read = o.secs - o.listen
            s.bars[k] = { v = read / md.max, k = col, v2 = o.listen / md.max, k2 = pink(P) }
            if not small and step == 1 then s.cuts[k] = o.sits end
        elseif t >= first_t and t <= d.now and not small then
            s.skipped[k] = true
        end
    end
    s.today = slotOf(d.now)
    if s.today then s.ahead_from = s.today + 1 end
    if not d.finished and d.finish_t then s.finish = slotOf(d.finish_t) end
    s.best = md.best
    if not small then
        -- the clock face: ticks, every 5th day's number, the months' names where they start
        local f = { ticks = {}, nums = {}, gold = {} }
        for k = 1, m.ndays do
            local t = dayT(m, k)
            local dom = tonumber(os.date("%d", t))
            if step > 1 then
                f.ticks[k] = "day"
                for j = 0, step - 1 do
                    if tonumber(os.date("%d", t + j * 86400)) == 1 or (k == 1 and j == 0) then
                        f.ticks[k] = "month"
                        f.nums[k], f.gold[k] = string.upper(os.date("%b", t + j * 86400)), true
                    end
                end
            else
                f.ticks[k] = (dom == 1 or (k == 1 and m.read)) and "month" or (dom % 5 == 0 and "five" or "day")
                if f.ticks[k] == "month" then
                    f.nums[k], f.gold[k] = string.upper(os.date("%b", t)), true
                end
            end
        end
        -- the numbers: not next to a month's name or today
        local function near(k)
            for j = k - 1, k + 1 do if j ~= k and (f.gold[j] or s.today == j) then return true end end
            return false
        end
        if step == 1 then
            for k = 1, m.ndays do
                local dom = tonumber(os.date("%d", dayT(m, k)))
                local every = m.ndays > 35 and 10 or 5
                if not f.gold[k] and dom % every == 0 and dom ~= 30 and not near(k) then f.nums[k] = tostring(dom) end
            end
            if s.today then f.nums[s.today] = tostring(tonumber(os.date("%d", d.now))) f.gold[s.today] = nil end
        end
        s.face = f
    end
    return s
end

-- the stats page's month tile: the small ring and the month's numbers beside it
function Rings.monthTile(bb, x, y, w, h, d, P, extra)
    local m = monthOf(d, 0)
    local md = monthDays(d, m)
    local dia = math.min(h, math.floor(w * 0.56))
    local cx, cy = x + math.floor(dia / 2), y + math.floor(h / 2)
    local reach = math.floor(dia / 2) - px(2)
    local rin = math.floor(reach * 0.58)
    local s = monthSpec(d, m, md, P, extra, true)
    s.cx, s.cy, s.rin, s.reach, s.lift = cx, cy, rin, reach, px(2)
    s.best = nil
    drawRing(bb, s, P)
    local pt = text(d.finished and _("done") or (math.floor(d.pct * 100 + 0.5) .. "%"), 14, true, INK)
    pt:paintTo(bb, cx - math.floor(pt:getSize().w / 2), cy - math.floor(pt:getSize().h / 2))
    local tx = x + dia + px(10)
    local tw = x + w - tx
    local lines = {
        text(durS(md.total), 18, true, INK, tw),
        text(T(_("%1 days read"), md.read_days), 10, false, SUB, tw),
        md.best and text(T(_("best %1"), dayShort(dayT(m, md.best))), 10, false, SUB, tw) or nil,
        md.listen > 0 and text(T(_("%1 listened"), durS(md.listen)), 10, true, INK, tw) or nil,
    }
    local yy = cy - math.floor(stackH(lines) / 2)
    for _i, l in ipairs(lines) do
        if l then l:paintTo(bb, tx, yy) yy = yy + l:getSize().h end
    end
end

-- a pill (tappable); returns the canvas
local function pill(label, k, P, filled)
    -- 2.1.22 (TK): words on a colour are black (night mode too: drawn white, shown black)
    -- 2.1.36 (TK): Look › Pill Colours: off, filled pills are black with white words
    local pills = P.colour and O.Sheet and O.Sheet.pillsColoured and O.Sheet.pillsColoured(P) or false
    local t = text(label, 13, true, filled and (pills and (P.night and PAPER or INK) or PAPER) or INK)
    local w, h = t:getSize().w + px(28), t:getSize().h + px(12)
    -- 2.1.34 (TK): Popup Style Solid: every pill in its one colour
    local solid = pills and O.Sheet.solid(P) or nil
    return canvas(w, h, function(bb, x, y)
        if filled and pills then
            roundFill(bb, x, y, w, h, math.floor(h / 2), solid or k)
        elseif filled then
            roundFill(bb, x, y, w, h, math.floor(h / 2), P.ink)
        else
            bb:paintBorder(x, y, w, h, px(2), solid and solid.v or INK, math.floor(h / 2))
        end
        t:paintTo(bb, x + px(14), y + px(6))
    end)
end

-- the numbers under a ring: { label, big, unit, sub, sub_k }
local function numbersRow(cw, P, cols)
    local h = px(86)
    local list = {}
    for i, c in ipairs(cols) do
        list[i] = { text(c[1], 11, true, SUB), text(c[2], 24, true, INK), c[3] and text(c[3], 14, false, SUB) or nil,
            text(c[4] or "", 11, c[5] ~= nil, c[5] and INK or SUB) }
    end
    return canvas(cw, h, function(bb, x, y)
        roundFill(bb, x, y, cw, h, px(16), P.tile)
        local colw = cw / #cols
        for i, c in ipairs(cols) do
            local l = list[i]
            local lx = math.floor(x + (i - 1) * colw + px(14))
            if i > 1 then bb:paintRect(math.floor(x + (i - 1) * colw), y + px(14), px(1), h - px(28), K.SOFT) end
            l[1]:paintTo(bb, lx, y + px(10))
            l[2]:paintTo(bb, lx, y + px(10) + l[1]:getSize().h)
            if l[3] then l[3]:paintTo(bb, lx + l[2]:getSize().w + px(3), y + px(10) + l[1]:getSize().h + px(6)) end
            if c[5] and P.colour then
                local sw = l[4]:getSize().w + px(10)
                roundFill(bb, lx - px(5), y + h - px(10) - l[4]:getSize().h, sw, l[4]:getSize().h, px(6), c[5])
            end
            l[4]:paintTo(bb, lx, y + h - px(10) - l[4]:getSize().h)
        end
    end)
end

local function sectionHead(label, right, cw, P)
    local l = text(label, 15, true, INK)
    local r = right and text(right, 11, true, SUB) or nil
    return canvas(cw, l:getSize().h + px(4), function(bb, x, y)
        roundFill(bb, x, y + px(7), px(14), px(6), px(3), P.gold)
        l:paintTo(bb, x + px(20), y)
        local lx = x + px(28) + l:getSize().w
        local rx = r and (x + cw - r:getSize().w) or (x + cw)
        if rx - lx > px(20) then bb:paintRect(lx, y + math.floor(l:getSize().h / 2), rx - lx - px(10), px(1), K.SOFT) end
        if r then r:paintTo(bb, rx, y + math.floor((l:getSize().h - r:getSize().h) / 2)) end
    end)
end

-- 2.1.28: block widths by length that add up to room at most: none under min_w
-- (smaller when even that doesn't fit), the longer ones shrunk to make the room
function Rings.fitWidths(list, room, span, min_w)
    local n = #list
    local ws = {}
    if n == 0 then return ws end
    min_w = math.min(min_w, math.floor(room / n))
    local function len(e) return e.c.b - e.c.a + 1 end
    for j = 1, n do ws[j] = math.max(min_w, math.floor(room * len(list[j]) / span)) end
    local passes = 0
    while passes < 4 do
        passes = passes + 1
        local sum, free = 0, 0
        for j = 1, n do
            sum = sum + ws[j]
            if ws[j] > min_w then free = free + (ws[j] - min_w) end
        end
        local over = sum - room
        if over <= 0 or free <= 0 then break end
        for j = 1, n do
            if ws[j] > min_w then ws[j] = math.max(min_w, ws[j] - math.ceil(over * (ws[j] - min_w) / free)) end
        end
    end
    return ws
end

-- This Kobo: the chapters read this month, as blocks (wider: longer; taller: more time)
local function chapterStrip(d, m, md, extra, cw, P)
    local chs = extra and extra.chapters
    if not chs then return nil end
    local lo, hi
    for k = 1, m.ndays do
        local o = md[k]
        if o.secs > 0 and o.reached then
            local p1 = o.reached * d.total
            local p0 = p1 - o.pages
            lo = math.min(lo or p0, p0)
            hi = math.max(hi or p1, p1)
        end
    end
    if not lo then return nil end
    local list = {}
    for i, c in ipairs(chs) do
        if c.b >= lo and c.a <= hi then list[#list + 1] = { i = i, c = c } end
    end
    if #list == 0 then return nil end
    local more = #chs - list[#list].i
    -- 2.1.26 (TK): at most 8 blocks so they never get too thin as chapters pile up; the
    -- earlier ones fold into "N earlier" on the left
    local earlier = 0
    if #list > 8 then
        earlier = #list - 8
        local keep = {}
        for k = earlier + 1, #list do keep[#keep + 1] = list[k] end
        list = keep
    end
    local span, smax = 0, 1
    for _i, e in ipairs(list) do
        span = span + (e.c.b - e.c.a + 1)
        smax = math.max(smax, e.c.secs)
    end
    -- 2.1.26 (TK): shorter blocks, bigger words, black on the colour (white in night mode)
    local h = px(112)
    local ON = P.colour and (P.night and PAPER or INK) or PAPER
    local labels = {}
    for j, e in ipairs(list) do
        labels[j] = { text(tostring(e.i), 18, true, ON), text(T(_("%1p"), e.c.b - e.c.a + 1), 12, true, ON) }
    end
    local here = text(_("you're here"), 11, true, INK)
    local left_t = more > 0 and text(T(_("%1 more"), more), 12, false, SUB) or nil
    local ghost = left_t and math.max(px(56), left_t:getSize().w + px(12)) or 0
    local early_t = earlier > 0 and text(T(_("%1 earlier"), earlier), 12, false, SUB) or nil
    local eghost = early_t and math.max(px(56), early_t:getSize().w + px(12)) or 0
    local g = px(4)
    return canvas(cw, h, function(bb, x, y)
        local room = cw - ghost - eghost - (#list) * g - (early_t and g or 0)
        -- 2.1.28 (TK): the widths fit the room, so "N more" never runs off the right
        local ws = Rings.fitWidths(list, room, span, px(40))
        local bx = x
        if early_t then
            bb:paintBorder(bx, y + math.floor(h * 0.4), eghost, h - math.floor(h * 0.4), px(1), MID, px(6))
            early_t:paintTo(bb, bx + math.floor((eghost - early_t:getSize().w) / 2),
                y + math.floor(h * 0.7) - math.floor(early_t:getSize().h / 2))
            bx = bx + eghost + g
        end
        for j, e in ipairs(list) do
            local bw = ws[j]
            local bh = math.floor(h * 0.55 + h * 0.3 * e.c.secs / smax)
            local col = hue(P, e.i)
            roundFill(bb, bx, y + h - bh, bw, bh, px(6), col)
            if not P.colour then bb:paintBorder(bx, y + h - bh, bw, bh, px(1), INK, px(6)) end
            local n1, n2 = labels[j][1], labels[j][2]
            if bw >= n1:getSize().w + px(4) then n1:paintTo(bb, bx + math.floor((bw - n1:getSize().w) / 2), y + h - bh + px(6)) end
            if bw >= n2:getSize().w + px(4) then n2:paintTo(bb, bx + math.floor((bw - n2:getSize().w) / 2), y + h - n2:getSize().h - px(4)) end
            if e.i == d.chapter_now and not d.finished then
                here:paintTo(bb, bx + math.floor((bw - here:getSize().w) / 2), y + h - bh - here:getSize().h - px(2))
            end
            bx = bx + bw + g
        end
        if left_t then
            bb:paintBorder(bx, y + math.floor(h * 0.4), ghost, h - math.floor(h * 0.4), px(1), MID, px(6))
            left_t:paintTo(bb, bx + math.floor((ghost - left_t:getSize().w) / 2), y + math.floor(h * 0.7) - math.floor(left_t:getSize().h / 2))
        end
    end)
end

-- BookOrbit: where you read this month (by device or app), and read vs listened
local function sourceStrip(d, m, cw, P)
    local by, order, total = {}, {}, 0
    local from, to = dayT(m, 1) - 12 * 3600, dayT(m, m.ndays) + 12 * 3600
    for _i, s in ipairs(d.sessions or {}) do
        if s.start >= from and s.start < to then
            local key = LISTEN[s.kind] and _("Listening") or (s.source or _("Reading"))
            if not by[key] then by[key] = 0 order[#order + 1] = key end
            by[key] = by[key] + s.secs
            total = total + s.secs
        end
    end
    if total <= 0 then return nil end
    table.sort(order, function(a, b) return by[a] > by[b] end)
    local rows = math.min(4, #order)
    local rh = px(28)
    local labels = {}
    for i = 1, rows do labels[i] = { text(order[i], 12, true, INK), text(durS(by[order[i]]), 12, true, INK) } end
    local lw = 0
    for i = 1, rows do lw = math.max(lw, labels[i][1]:getSize().w) end
    lw = math.min(lw + px(10), math.floor(cw * 0.4))
    return canvas(cw, rows * rh, function(bb, x, y)
        for i = 1, rows do
            local key = order[i]
            local yy = y + (i - 1) * rh
            labels[i][1]:paintTo(bb, x, yy + px(4))
            local bw = math.max(px(6), math.floor((cw - lw - px(70)) * by[key] / by[order[1]]))
            local col = key == _("Listening") and pink(P) or hue(P, i)
            roundFill(bb, x + lw, yy + px(6), bw, rh - px(12), px(6), col)
            if key == _("Listening") then
                for sx = x + lw + px(4), x + lw + bw - px(3), px(7) do fill(bb, sx, yy + px(6), px(2), rh - px(12), P.paper) end
            end
            labels[i][2]:paintTo(bb, x + lw + bw + px(8), yy + px(4))
        end
    end)
end

-- the month card. nav: { off, go(off), year() } ; returns the widget and its taps
function Rings.monthCard(d, _rec, cw, P, extra, nav)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g = VG:new{ align = "left" }
    local taps = {}
    local function add(w) g[#g + 1] = w end
    local function sp(v) add(VS:new{ width = px(v) }) end
    -- 2.1.14: nav.off nil = the whole read; a number = that month (0 = this one)
    local off = nav.off
    local m = off and monthOf(d, off) or readSpan(d)
    local md = monthDays(d, m)
    local bo = d.unit == "pct"

    -- the title: the read's dates, or the month
    local head, head_sub
    if m.read then
        local y0, y1 = os.date("%Y", m.t), os.date("%Y", m.t_end)
        head = dayShort(m.t) .. (y0 ~= y1 and (", " .. y0) or "") .. " – " .. dayShort(m.t_end) .. ", " .. y1
        local bits = { T(_("%1 days"), m.days), T(_("%1 read"), md.read_days) }
        if not d.finished then bits[#bits + 1] = T(_("today day %1"), K.daysBetween(midnight(m.t), midnight(d.now)) + 1) end
        if m.step > 1 then bits[#bits + 1] = _("a week a wedge") end
        head_sub = table.concat(bits, " · ")
    else
        head = os.date("%B %Y", m.t)
        head_sub = T(_("%1 days read"), md.read_days) .. " · " .. durS(md.total)
    end
    local ht = text(head, 18, true, INK, cw)
    local hs = text(head_sub, 11, false, SUB, cw)
    add(canvas(cw, ht:getSize().h + hs:getSize().h, function(bb, x, y)
        ht:paintTo(bb, x + math.floor((cw - ht:getSize().w) / 2), y)
        hs:paintTo(bb, x + math.floor((cw - hs:getSize().w) / 2), y + ht:getSize().h)
    end))
    sp(6)

    -- the ring
    local ring_h = math.min(math.floor(cw * 0.86), px(330))
    local s = monthSpec(d, m, md, P, extra, false)
    s.star = md.best and md.max > 0 and text("★", 16, true, INK) or nil
    local is_now = m.read or off == 0
    local c1
    if m.read then
        local total_days = m.days
        c1 = text(d.finished and T(_("%1 DAYS"), total_days)
            or T(_("DAY %1 OF ~%2"), K.daysBetween(midnight(m.t), midnight(d.now)) + 1, total_days), 10, false, SUB)
    else
        c1 = text(is_now and (string.upper(os.date("%b", m.t)) .. " · " .. T(_("DAY %1"), tonumber(os.date("%d", d.now))))
            or string.upper(os.date("%B", m.t)), 10, false, SUB)
    end
    local big = (is_now or d.finished) and (d.finished and _("done") or (math.floor(d.pct * 100 + 0.5) .. "%")) or durS(md.total)
    local c2 = text(big, 30, true, INK)
    local c3 = text(m.read and T(_("%1 so far"), durS(md.total)) or (is_now and T(_("%1 this month"), durS(md.total)))
        or T(_("%1 days read"), md.read_days), 11, false, SUB)
    local c4
    if bo and md.listen > 0 then
        c4 = text(T(_("%1 read · %2 listened"), durS(md.total - md.listen), durS(md.listen)), 9, true, INK)
    elseif is_now and not d.finished and d.finish_t then
        c4 = text(T(_("done ~ %1"), dayShort(d.finish_t)), 10, true, INK)
    elseif d.finished then
        c4 = text(T(_("finished %1"), dayShort(d.finish_t)), 10, true, INK)
    end
    local ring_cv = canvas(cw, ring_h, function(bb, x, y, w, h)
        local cx, cy = x + math.floor(w / 2), y + math.floor(h / 2)
        s.cx, s.cy, s.reach = cx, cy, math.floor(h / 2) - px(18)
        s.rin = math.floor(s.reach * 0.64)
        s.face.num_r = 22
        drawRing(bb, s, P)
        centred(bb, cx, cy - math.floor(stackH({ c1, c2, c3, c4 }) / 2), { c1, c2, c3, c4 })
    end)
    add(ring_cv)
    -- 2.1.26 (TK): tap a day's wedge for that day's popup (not on a week-a-wedge ring)
    if not (m.step and m.step > 1) and O.Stats and O.Stats.showDay then
        taps[#taps + 1] = { ring_cv, function()
            local pos = O.Stats._tap_pos
            if not (pos and s.cx) then return end
            local dx, dy = pos.x - s.cx, pos.y - s.cy
            local r = math.sqrt(dx * dx + dy * dy)
            if r < s.rin * 0.8 or r > s.reach + px(24) then return end
            local ang = math.atan2(dx, -dy) % TAU
            local i = math.floor(ang / (TAU / s.n)) + 1
            local t = dayT(m, i)
            if t and t <= d.now + 43200 then O.Stats.showDay(d, t) end
        end }
    end
    -- what it all means
    local key = { m.step and m.step > 1 and _("bar: time that week") or _("bar: time that day"), _("cuts: sittings"), _("○ skipped") }
    if bo then key[#key + 1] = _("striped: listened") end
    key[#key + 1] = _("★ best day")
    if s.finish then key[#key + 1] = _("flag: likely finish") end
    local kt = text(table.concat(key, "  ·  "), 10, false, SUB, cw)
    add(HG:new{ align = "center", HS:new{ width = math.floor((cw - kt:getSize().w) / 2) }, kt })
    sp(8)
    -- This Read | the read's months (the last 4)
    local span = readSpan(d)
    local here_m = monthOf(d, 0)
    local months = {}
    local t = os.time{ year = tonumber(os.date("%Y", span.t)), month = tonumber(os.date("%m", span.t)), day = 1, hour = 12 }
    while t <= span.t_end + 86400 do
        local mt = os.date("*t", t)
        local mo_off = (mt.year * 12 + mt.month) - (here_m.year * 12 + here_m.month)
        -- 2.1.26 (TK): no pill for a month that hasn't come yet (the likely finish can be in it)
        if mo_off <= 0 then months[#months + 1] = { label = os.date("%b", t), off = mo_off } end
        t = os.time{ year = mt.year, month = mt.month + 1, day = 1, hour = 12 }
    end
    while #months > 4 do table.remove(months, 1) end
    local row = HG:new{ align = "center" }
    local pills = { { label = _("This Read"), off = false } }
    for _i, mo in ipairs(months) do pills[#pills + 1] = mo end
    local roww = 0
    for i, pl in ipairs(pills) do
        local on = (pl.off == false and off == nil) or (pl.off ~= false and off == pl.off)
        local pw = pill(pl.label, P.blue, P, on)
        if i > 1 then row[#row + 1] = HS:new{ width = px(10) } roww = roww + px(10) end
        row[#row + 1] = pw
        roww = roww + pw:getSize().w
        if not on then taps[#taps + 1] = { pw, function() nav.go(pl.off ~= false and pl.off or nil) end } end
    end
    add(HG:new{ align = "center", HS:new{ width = math.max(0, math.floor((cw - roww) / 2)) }, row })
    sp(10)

    -- today, this week, the streak
    local nn = nowNumbers(d)
    local chg = nn.last_week > 0 and math.floor((nn.week - nn.last_week) / nn.last_week * 100 + 0.5) or nil
    local td = nn.today
    local th, tu = durS(td and td.secs or 0):match("^(%d+)(.*)$")
    local wh, wu = durS(nn.week):match("^(%d+)(.*)$")
    local today_sub = nn.sits_today == 1 and _("1 sitting") or T(_("%1 sittings"), nn.sits_today)
    if td and td.pages > 0 then today_sub = today_sub .. " · " .. K.amount(d, td.pages) end
    add(numbersRow(cw, P, {
        { _("TODAY"), th or "0", tu or "m", today_sub },
        { _("THIS WEEK"), wh or "0", wu or "m", chg and ((chg >= 0 and "▲ " or "▼ ") .. math.abs(chg) .. "% " .. _("on last")) or _("nothing last week"),
          chg and (chg >= 0 and P.green or P.red) or nil },
        { _("STREAK"), tostring(nn.streak), nn.streak == 1 and _(" day") or _(" days"), T(_("Longest %1"), nn.longest) },
    }))
    sp(12)

    -- the chapters this month (This Kobo) or where you read (BookOrbit)
    local strip, strip_head, right
    if bo then
        strip, strip_head = sourceStrip(d, m, cw, P), _("Where you read")
        right = md.listen > 0 and T(_("%1 LISTENED"), string.upper(durS(md.listen))) or nil
    else
        strip, strip_head = chapterStrip(d, m, md, extra, cw, P), m.read and _("Chapters this read") or _("Chapters this month")
        right = md.amount > 0 and string.upper(K.amount(d, md.amount)) or nil
    end
    if strip then
        add(sectionHead(strip_head, right, cw, P))
        sp(8)
        add(strip)
        sp(12)
    end
    -- Your Year
    local yp = pill(_("Your Year ›"), P.gold, P, true)
    add(HG:new{ align = "center", HS:new{ width = math.floor((cw - yp:getSize().w) / 2) }, yp })
    taps[#taps + 1] = { yp, function() nav.year() end }
    return g, taps
end

-- ---- Your Year (all books) ------------------------------------------------------------

local function yearKey(src, y) return "year:" .. src .. ":" .. y end
local function doyOf(t) return tonumber(os.date("%j", t)) end
local function daysIn(y) return os.date("*t", os.time{ year = y, month = 12, day = 31, hour = 12 }).yday end

-- a "2026-03-04" day to a time (noon)
local function dateT(s)
    local y, mo, dd = tostring(s or ""):match("^(%d+)%-(%d+)%-(%d+)")
    if not y then return nil end
    return os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(dd), hour = 12 }
end

function Rings.yearSaved(src, y)
    local st = K.openStore()
    local Y = st and st:readSetting(yearKey(src, y))
    return type(Y) == "table" and Y.v == 1 and Y or nil
end

local function saveYear(Y)
    local st = K.openStore()
    if not st then return end
    Y.saved = os.time()
    st:saveSetting(yearKey(Y.src, Y.year), Y)
    st:flush()
end

-- history files to their fingerprints (only until every wanted one is found; kept)
local function pathsFor(want)
    local st = K.openStore()
    local known = st and st:readSetting("md5path")
    known = type(known) == "table" and known or {}
    local out, missing = {}, 0
    for md5 in pairs(want) do
        local p = known[md5]
        if p and O.lfs.attributes(p, "mode") == "file" then out[md5] = p else missing = missing + 1 end
    end
    if missing == 0 then return out end
    local ok, RH = pcall(require, "readhistory")
    local hist = ok and type(RH) == "table" and RH.hist or {}
    local looked = 0
    for _i, e in ipairs(hist) do
        local f = type(e) == "table" and e.file
        if f and O.lfs.attributes(f, "mode") == "file" then
            looked = looked + 1
            local md5 = K.fileMd5(f)
            if md5 then known[md5] = f end
            if md5 and want[md5] and not out[md5] then
                out[md5] = f
                missing = missing - 1
                if missing == 0 then break end
            end
            if looked >= 200 then break end
        end
    end
    if st then st:saveSetting("md5path", known) st:flush() end
    return out
end

-- 2.1.29: a title to match books by ("No Exit: A Novel" and "No Exit" are the same book)
function Rings.titleKey(title)
    return (tostring(title or ""):lower():gsub("%s*[:%(].*$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- 2.1.29 (TK marked 4 finished, the stats said 2): books marked finished in KOReader (the
-- book's status: Finished), from the books on this device and the history; title key ->
-- the day it was marked (noon), or true. Looked up again after a minute.
function Rings.markedDone()
    if Rings._marked and os.time() - (Rings._marked_t or 0) < 60 then return Rings._marked end
    local out = {}
    pcall(function()
        local DS = require("docsettings")
        local files, seen = {}, {}
        local dev = type(O.onDeviceByBookId) == "function" and O.onDeviceByBookId(false) or {}
        local id, p = next(dev)
        while id do
            if type(p) == "string" and not seen[p] then seen[p] = true files[#files + 1] = p end
            id, p = next(dev, id)
        end
        local okH, RH = pcall(require, "readhistory")
        local hist = okH and type(RH) == "table" and type(RH.hist) == "table" and RH.hist or {}
        for i = 1, math.min(#hist, 300) do
            local f = type(hist[i]) == "table" and hist[i].file
            if type(f) == "string" and not seen[f] then seen[f] = true files[#files + 1] = f end
        end
        for i = 1, #files do
            local f = files[i]
            pcall(function()
                if DS.hasSidecarFile and not DS:hasSidecarFile(f) then return end
                local ds = DS:open(f)
                local sm = ds:readSetting("summary")
                if type(sm) == "table" and sm.status == "complete" then
                    local props = ds:readSetting("doc_props")
                    local title = type(props) == "table" and props.title or f:match("([^/]+)%.[%w]+$")
                    local k = Rings.titleKey(title)
                    if k ~= "" then out[k] = dateT(sm.modified) or true end
                end
            end)
        end
    end)
    Rings._marked, Rings._marked_t = out, os.time()
    return out
end

-- 2.1.29: the finished list again: reached the end (worked out from the statistics) plus
-- marked finished (only in t0..t1 when given). Y.books[i].to follows.
function Rings.withMarked(Y, t0, t1)
    if type(Y) ~= "table" or type(Y.books) ~= "table" then return Y end
    Y.fin_pages = Y.fin_pages or Y.finished or {}
    local base = Y.fin_pages
    local fin, seen = {}, {}
    for i = 1, #Y.books do Y.books[i].to = nil end
    for i = 1, #base do
        local f = base[i]
        if Y.books[f.book] and not seen[f.book] then
            seen[f.book] = true
            fin[#fin + 1] = { book = f.book, t = f.t }
            Y.books[f.book].to = f.t
        end
    end
    local marked = Rings.markedDone()
    for i = 1, #Y.books do
        local b = Y.books[i]
        local m = not seen[i] and marked[Rings.titleKey(b.title)]
        if m then
            local t = (m ~= true) and m or (b.last or b.from or os.time())
            if not t0 or (t >= t0 and t < t1) then
                seen[i] = true
                fin[#fin + 1] = { book = i, t = t, marked = true }
                b.to = t
            end
        end
    end
    table.sort(fin, function(a, c) return a.t < c.t end)
    Y.finished = fin
    return Y
end

-- 2.1.28: when each book was finished: the first time its last pages were reached, unless
-- you then read half an hour more earlier in it (a peek at the end isn't a finish: TK's
-- Mountains Echoed showed as finished in October from one). Copies downloaded again count
-- as one (by title), with half an hour read in all. { [id_book] = t }, or nil
function Rings.finishTimes(conn)
    local ok, r = pcall(K.query, conn, "SELECT p.id_book, b.title, p.start_time, MIN(p.duration, ?),"
        .. " p.page, p.total_pages FROM page_stat_data p JOIN book b ON b.id = p.id_book"
        .. " ORDER BY p.start_time;", { K.maxSec() })
    if not (ok and type(r) == "table" and r[1] and #r[1] > 0 and r[6]) then return nil end
    local st = {}
    for i = 1, #r[1] do
        local id, title = tonumber(r[1][i]), tostring(r[2][i] or "")
        local t, du = tonumber(r[3][i]) or 0, tonumber(r[4][i]) or 0
        local pg, tp = tonumber(r[5][i]) or 0, tonumber(r[6][i]) or 0
        local e = st[title]
        if not e then e = { ids = {}, secs = 0 } st[title] = e end
        if id then e.ids[id] = true end
        e.secs = e.secs + du
        if tp > 0 then
            if pg >= tp * 0.97 then
                if not e.cand then e.cand, e.after = t, 0 end
            elseif e.cand and pg < tp * 0.9 then
                e.after = e.after + du
                if e.after > 1800 then e.cand = nil end
            end
        end
    end
    local out = {}
    local k, e = next(st)
    while k do
        if e.cand and e.secs >= 1800 then
            local id = next(e.ids)
            while id do out[id] = e.cand id = next(e.ids, id) end
        end
        k, e = next(st, k)
    end
    return out
end

-- This Kobo's year, from statistics.sqlite3 (worked out again when the database changed)
local function yearFromKobo(y)
    local saved = Rings.yearSaved("kobo", y)
    local mtime = K.dbMtime()
    -- 2.1.28: saved years from before the book list (days, pages read) are worked out again
    if saved and mtime and saved.db_mtime == mtime and saved.v2 == 2 then return saved end
    local conn = K.openDb()
    if not conn then return saved end
    local t0, t1 = os.time{ year = y, month = 1, day = 1, hour = 0 }, os.time{ year = y + 1, month = 1, day = 1, hour = 0 }
    local Y = { v = 1, v2 = 2, src = "kobo", year = y, secs = {}, top = {}, books = {}, finished = {},
        db_mtime = mtime }
    local ok, err = pcall(function()
        local r = K.query(conn, "SELECT id_book, strftime('%j', start_time, 'unixepoch', 'localtime'), SUM(MIN(duration, ?))"
            .. " FROM page_stat_data WHERE start_time >= ? AND start_time < ? GROUP BY 1, 2;", { K.maxSec(), t0, t1 })
        if not r then return end
        local per, ids, order = {}, {}, {}
        for i = 1, #r[1] do
            local id, dy, s = tonumber(r[1][i]), tonumber(r[2][i]), tonumber(r[3][i]) or 0
            if id and dy then
                if not ids[id] then ids[id] = { secs = 0, first = dy, last = dy, days = 0 } order[#order + 1] = id end
                ids[id].secs = ids[id].secs + s
                ids[id].first = math.min(ids[id].first, dy)
                ids[id].last = math.max(ids[id].last, dy)
                ids[id].days = ids[id].days + 1
                Y.secs[dy] = (Y.secs[dy] or 0) + s
                per[dy] = per[dy] or {}
                per[dy][id] = (per[dy][id] or 0) + s
            end
        end
        if #order == 0 then return end
        table.sort(order, function(a, b) return ids[a].first < ids[b].first end)
        local marks = {}
        for i, id in ipairs(order) do
            marks[i] = "?"
            ids[id].idx = i
        end
        local b = K.query(conn, "SELECT id, title, authors, md5, pages FROM book WHERE id IN (" .. table.concat(marks, ",") .. ");", order)
        local info = {}
        if b then
            for i = 1, #b[1] do info[tonumber(b[1][i])] = { title = b[2][i], authors = b[3][i], md5 = b[4][i], pages = tonumber(b[5][i]) } end
        end
        -- 2.1.28: the pages read in each book this year
        local rp = {}
        local q = K.query(conn,
            "SELECT id_book, COUNT(DISTINCT page) FROM page_stat_data"
            .. " WHERE start_time >= ? AND start_time < ? GROUP BY id_book;", { t0, t1 })
        if q then for i = 1, #q[1] do rp[tonumber(q[1][i]) or 0] = tonumber(q[2][i]) end end
        local function noon(dy) return os.time{ year = y, month = 1, day = dy, hour = 12 } end
        local _lo = order
        for _lo_n = 1, #_lo do
            local id = _lo[_lo_n]
            local inf = info[id] or {}
            local e = ids[id]
            Y.books[e.idx] = { title = type(inf.title) == "string" and inf.title or "?",
                author = type(inf.authors) == "string" and inf.authors:match("^[^\n]*") or nil,
                md5 = inf.md5, pages = inf.pages, secs = math.floor(e.secs), read_pages = rp[id], days = e.days,
                from = noon(e.first), last = noon(e.last) }
        end
        for dy, list in pairs(per) do
            local best, bs = nil, -1
            for id, s in pairs(list) do if s > bs then best, bs = id, s end end
            Y.top[dy] = ids[best].idx
        end
        -- 2.1.28: a finish is the last pages reached and not read on from earlier after
        local ft = Rings.finishTimes(conn)
        local f = (not ft) and K.query(conn, "SELECT id_book, MIN(start_time) FROM page_stat_data WHERE total_pages > 0"
            .. " AND page >= total_pages * 0.97 AND start_time >= ? AND start_time < ?"
            .. " GROUP BY id_book;", { t0, t1 }) or nil
        if ft then
            local seen = {}
            local fid, fts = next(ft)
            while fid do
                local e = ids[fid]
                if e and fts >= t0 and fts < t1 and not seen[Y.books[e.idx].title] then
                    seen[Y.books[e.idx].title] = true
                    Y.finished[#Y.finished + 1] = { book = e.idx, t = fts }
                    Y.books[e.idx].to = fts
                end
                fid, fts = next(ft, fid)
            end
        end
        if f then
            for i = 1, #f[1] do
                local id = tonumber(f[1][i])
                if id and ids[id] and ids[id].secs >= 1800 then
                    Y.finished[#Y.finished + 1] = { book = ids[id].idx, t = tonumber(f[2][i]) }
                    Y.books[ids[id].idx].to = tonumber(f[2][i])
                end
            end
        end
        -- 2.1.28: copies of a book downloaded again are one book (TK's Mountains Echoed showed 4 times)
        local merged, map, byt = {}, {}, {}
        for i = 1, #Y.books do
            local bk = Y.books[i]
            if bk then
                local j = byt[bk.title]
                if not j then
                    merged[#merged + 1] = bk
                    j = #merged
                    byt[bk.title] = j
                else
                    local m = merged[j]
                    if (bk.last or 0) > (m.last or 0) then m.md5 = bk.md5 end
                    m.secs = m.secs + (bk.secs or 0)
                    m.read_pages = (m.read_pages or 0) + (bk.read_pages or 0)
                    if m.pages then m.read_pages = math.min(m.read_pages, m.pages) end
                    m.days = (m.days or 0) + (bk.days or 0)
                    m.from = math.min(m.from or bk.from, bk.from or m.from)
                    m.last = math.max(m.last or bk.last, bk.last or m.last)
                    m.to = m.to or bk.to
                end
                map[i] = j
            end
        end
        Y.books = merged
        local dk, ti = next(Y.top)
        while dk do Y.top[dk] = map[ti] dk, ti = next(Y.top, dk) end
        local fin, fseen = {}, {}
        for i = 1, #Y.finished do
            local f2 = Y.finished[i]
            local j = map[f2.book]
            if j and not fseen[j] then fseen[j] = true fin[#fin + 1] = { book = j, t = f2.t } merged[j].to = f2.t end
        end
        Y.finished = fin
        table.sort(Y.finished, function(a, c) return a.t < c.t end)
        local pg = K.query(conn, "SELECT COUNT(*) FROM (SELECT DISTINCT id_book, page FROM page_stat_data WHERE start_time >= ? AND start_time < ?);", { t0, t1 })
        Y.pages = pg and tonumber(pg[1][1]) or nil
    end)
    pcall(conn.close, conn)
    if not ok then O.logger.warn(O.TAG, "Your Year:", tostring(err)) return saved end
    Y.total = 0
    for _dy, s in pairs(Y.secs) do Y.total = Y.total + s end
    pcall(saveYear, Y)
    return Y
end

-- BookOrbit's year: the days (heatmap), the finished reads, the summary and audio (peak-hours)
local function yearFromBookOrbit(y, done, label)
    if type(O.boApiClient) ~= "function" or type(O.Collections) ~= "table" or type(O.Collections.get) ~= "function" then
        return done(nil, "BookOrbit isn't installed")
    end
    local client = O.boApiClient()
    if not client then return done(nil, "BookOrbit isn't signed in") end
    local now = os.time()
    local this_year = tonumber(os.date("%Y", now))
    local days = math.min(3650, (this_year - y) * 366 + doyOf(now) + 1)
    local Y = { v = 1, src = "bookorbit", year = y, secs = {}, top = {}, books = {}, finished = {}, src_secs = {} }
    label = label or _("Loading your year from BookOrbit…")
    local function get(path, cb)
        local started = O.Collections.get(client, label, path, cb)
        if not started then done(nil, "BookOrbit isn't installed") end
    end
    get("/user-statistics/reading-heatmap?days=" .. days, function(heat, err)
        if type(heat) ~= "table" then return done(nil, err) end
        Y.total = 0
        for _i, it in ipairs(heat) do
            local t = type(it) == "table" and dateT(it.day)
            if t and tonumber(os.date("%Y", t)) == y then
                local s = tonumber(it.readingSeconds) or 0
                if s > 0 then
                    local dy = doyOf(t)
                    Y.secs[dy] = s
                    Y.total = Y.total + s
                    if type(it.bySource) == "table" then
                        for k, v in pairs(it.bySource) do Y.src_secs[k] = (Y.src_secs[k] or 0) + (tonumber(v) or 0) end
                    end
                end
            end
        end
        get("/reading-history?year=" .. y .. "&limit=200&sort=oldest", function(hist)
            local items = type(hist) == "table" and type(hist.items) == "table" and hist.items or {}
            for _i, it in ipairs(items) do
                if type(it) == "table" and (it.outcome == nil or it.outcome == "completed") then
                    local t1 = dateT(it.endedOn)
                    if t1 and tonumber(os.date("%Y", t1)) == y then
                        local authors = type(it.authors) == "table" and it.authors or {}
                        Y.books[#Y.books + 1] = { title = type(it.title) == "string" and it.title or "?", author = authors[1],
                            bo_id = tonumber(it.bookId), pages = tonumber(it.pageCount), secs = tonumber(it.seconds),
                            audio = type(it.format) == "string" and AUDIO[it.format:upper()] or nil,
                            from = dateT(it.startedOn), to = t1 }
                        Y.finished[#Y.finished + 1] = { book = #Y.books, t = t1 }
                    end
                end
            end
            -- each day's colour: the finished read it falls in (the latest started)
            for dy in pairs(Y.secs) do
                local t = os.time{ year = y, month = 1, day = dy, hour = 12 }
                local best
                for i, b in ipairs(Y.books) do
                    if b.from and t >= b.from - 43200 and t <= b.to + 43200 and (not best or b.from > Y.books[best].from) then best = i end
                end
                Y.top[dy] = best
            end
            get("/reading-history/summary?year=" .. y, function(sum)
                if type(sum) == "table" then
                    Y.pages = tonumber(sum.pages)
                    Y.days_read = tonumber(sum.daysRead)
                    if type(sum.goal) == "table" then Y.goal = { target = tonumber(sum.goal.target), reached = tonumber(sum.goal.reached) } end
                end
                get("/user-statistics/peak-hours?days=" .. days, function(peak)
                    if type(peak) == "table" then
                        local audio = 0
                        for _i, h in ipairs(peak) do
                            if type(h) == "table" and type(h.byFormat) == "table" then
                                for fmt, v in pairs(h.byFormat) do if AUDIO[tostring(fmt):upper()] then audio = audio + (tonumber(v) or 0) end end
                            end
                        end
                        -- peak-hours counts back from today, not from January 1: only exact for this year
                        if y == this_year then Y.audio = audio end
                    end
                    Y.fetched = os.time()
                    pcall(saveYear, Y)
                    done(Y)
                end)
            end)
        end)
    end)
end

-- the year for this side: This Kobo at once; BookOrbit the saved one while fresh
-- (30 minutes, or no Wi-Fi), else fetched
function Rings.loadYear(src, y, done)
    if src ~= "bookorbit" then
        local Y = yearFromKobo(y)
        if Y then
            Rings.withMarked(Y, os.time{ year = y, month = 1, day = 1, hour = 0 },
                os.time{ year = y + 1, month = 1, day = 1, hour = 0 })
        end
        return done((Y and (Y.total or 0) > 0) and Y or nil)
    end
    local saved = Rings.yearSaved("bookorbit", y)
    local wifi = type(O.isWifiOn) == "function" and O.isWifiOn()
    local old = y < tonumber(os.date("%Y")) and 7 * 86400 or 1800
    if saved and not (wifi and os.time() - (tonumber(saved.fetched) or 0) > old) then return done(saved) end
    yearFromBookOrbit(y, function(Y, err)
        if Y then return done(Y) end
        done(saved, err)
    end)
end

-- the books as Bookshelf's own items, for its spines: BookOrbit's saved copy, or the file
local function shelfItems(Y)
    local items, idxs = {}, {}
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    -- 2.1.29 (TK): every book read this year, not only the finished ones, in the order you started them
    local want = {}
    for i = 1, #Y.books do
        local b = Y.books[i]
        if b and b.md5 then want[b.md5] = true end
    end
    local paths = next(want) and pathsFor(want) or {}
    local order = {}
    for i = 1, #Y.books do order[i] = { book = i } end
    table.sort(order, function(a, c) return (Y.books[a.book].from or 0) < (Y.books[c.book].from or 0) end)
    for oi = 1, #order do
        local f = order[oi]
        local b = Y.books[f.book]
        local item
        local id = b and (b.bo_id or (b.md5 and paths[b.md5] and O.bookIdForPath and tonumber(O.bookIdForPath(paths[b.md5]))))
        if id then
            for _k, entry in pairs(O.page_cache or {}) do
                for _j, r in ipairs(type(entry) == "table" and type(entry.items) == "table" and entry.items or {}) do
                    if type(r) == "table" and tonumber(r.bookorbit_id) == id then item = r break end
                end
                if item then break end
            end
            if not item and type(O.recordFromBo) == "function" then
                local okB, r = pcall(O.recordFromBo, { id = id, title = b.title, authors = b.author and { { name = b.author } } or nil, pageCount = b.pages })
                item = okB and r or nil
            end
        end
        if not item and b and b.md5 and paths[b.md5] and okR and type(Repo) == "table" and Repo.buildBookMeta then
            local okM, r = pcall(Repo.buildBookMeta, paths[b.md5])
            item = okM and r or nil
        end
        if item then items[#items + 1] = item idxs[#items] = f.book end
    end
    return items, idxs
end

-- Bookshelf's shelf (its spines, plank and colours), or nil without Bookshelf
-- 2.1.32 (TK: a tap on a spine still did nothing): Bookshelf's spine slots take the tap
-- themselves and, with no callbacks for our books, drop it before the card sees it. Each
-- slot in the row gets its own tap handler: on_tap(book record Bookshelf drew).
local function hookSlots(w, on_tap, depth)
    depth = depth or 0
    if type(w) ~= "table" or depth > 12 then return 0 end
    local n = 0
    if w.book ~= nil and type(w.ges_events) == "table" and w.ges_events.Tap then
        local book = w.book
        w.onTap = function() on_tap(book) return true end
        n = 1
    end
    for i = 1, #w do n = n + hookSlots(w[i], on_tap, depth + 1) end
    return n
end
Rings.hookSlots = hookSlots
-- 2.1.33: Settings' Save All Stats For Offline fetches each year now (saved as it comes)
Rings.fetchYear = yearFromBookOrbit

local function bookshelfRow(items, w, h, on_tap)
    if #items == 0 then return nil end
    local ok, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
    if not ok or type(SpineShelf) ~= "table" or type(SpineShelf.plan) ~= "function" or type(SpineShelf.rowWidget) ~= "function" then return nil end
    local okW, wdg = pcall(function()
        local okS, Space = pcall(require, "lib/bookshelf_space")
        local gap = okS and Space.px(SpineShelf.BOOK_GAP_DP or 0) or 0
        local opts = { content_w = w - 2 * SpineShelf.endMargin(h), row_h = h, face_out = "none", gap = gap,
            group_gap = okS and Space.px(SpineShelf.GROUP_GAP_DP or 12) or gap, n_rows = 1 }
        -- 2.1.30 (TK): no ornaments (the plant) on this shelf: Bookshelf's pinned
        -- frequency is set to off while it's planned, then put back
        local okO, Orn = pcall(require, "lib/bookshelf_ornaments")
        local had = okO and type(Orn) == "table" and Orn._chip_frequency or nil
        if okO and type(Orn) == "table" and Orn.setChipFrequency then Orn.setChipFrequency(0) end
        local function restore()
            if okO and type(Orn) == "table" and Orn.setChipFrequency then Orn.setChipFrequency(had) end
        end
        local okP, got = pcall(SpineShelf.withPlank, nil, function()
            local plan = SpineShelf.plan(items, opts)
            local row = plan and plan.rows and plan.rows[1]
            if not row then return nil end
            return SpineShelf.rowWidget{ plan = plan, row = row, width = w, height = h, gap = opts.gap, callbacks = {},
                row_index = 1, keep_ground = true, no_pin = true }
        end)
        restore()
        if not okP then error(got, 0) end
        if got and on_tap then
            local n = hookSlots(got, on_tap)
            if O.cfg and O.cfg.diagnostics then O.logger.info(O.TAG, "Your Year shelf: spines hooked", n) end
        end
        return got
    end)
    if not okW then O.logger.warn(O.TAG, "Your Year shelf:", tostring(wdg)) end
    return okW and wdg or nil
end

-- the book's colour on the ring: its spine's (Bookshelf, from the cover, made brighter), or one of ours
local function bookColour(P, Y, i, items_by_title)
    if P.colour and items_by_title then
        local b = Y.books[i]
        local item = b and items_by_title[b.title]
        local ok, SpineShelf = pcall(require, "lib/bookshelf_spine_shelf")
        if item and ok and type(SpineShelf) == "table" and type(SpineShelf.bookLook) == "function" then
            local okL, look = pcall(SpineShelf.bookLook, item)
            if okL and type(look) == "table" and look.sampled and look.r then
                -- brighter: pushed away from its grey
                local m = (look.r + look.g + look.b) / 3
                local function boost(v) return math.max(0, math.min(255, math.floor(m + (v - m) * 1.6 + 20))) end
                return rgb(boost(look.r), boost(look.g), boost(look.b), P.night)
            end
        end
    end
    return hue(P, i)
end

-- plain spines: coloured, a little taller for longer books (no Bookshelf)
local function plainShelf(Y, w, h, P, hits)
    local list = {}
    for i = 1, #Y.books do list[#list + 1] = { i, Y.books[i] } end -- 2.1.29: every book read
    return canvas(w, h, function(bb, x, y)
        if hits then for k = #hits, 1, -1 do hits[k] = nil end end
        local base = y + h - px(6)
        local bx = x
        for _i, e in ipairs(list) do
            local b = e[2]
            local bw = math.max(px(14), math.min(px(26), math.floor((b.pages or 300) / 18)))
            if bx + bw > x + w then break end
            local bh = math.floor(h * 0.62 + h * 0.3 * (((b.title or ""):len() * 37) % 10) / 10)
            roundFill(bb, bx, base - bh, bw, bh, px(2), hue(P, e[1]))
            if hits then hits[#hits + 1] = { x = bx, w = bw + px(2), book = e[1] } end
            fill(bb, bx, base - bh + px(6), bw, px(3), P.paper)
            if b.audio then disc(bb, bx + math.floor(bw / 2), base - px(10), px(4), P.paper) end
            bx = bx + bw + px(2)
        end
        fill(bb, x, base, w, px(6), P.soft)
    end)
end

-- 2.1.28: the spine under a tap in Bookshelf's row (its slots know where they were drawn)
function Rings.slotAt(w, pos, depth)
    depth = depth or 0
    if type(w) ~= "table" or depth > 10 then return nil end
    if w.book and w.dimen and w.dimen.x and pos.x >= w.dimen.x and pos.x < w.dimen.x + w.dimen.w then return w end
    for i = 1, #w do
        local hit = Rings.slotAt(w[i], pos, depth + 1)
        if hit then return hit end
    end
    return nil
end

-- a book from the year (or All Time) as a record the Book Page can open, or nil
function Rings.recordFor(b, item)
    if item and (item.bookorbit_id or item.filepath) then return item end
    if not b then return nil end
    local id = b.bo_id
    if not id and b.md5 then
        local p = pathsFor({ [b.md5] = true })[b.md5]
        id = p and O.bookIdForPath and tonumber(O.bookIdForPath(p)) or nil
    end
    return id and { bookorbit_id = id, title = b.title } or nil
end

local function dateS(t) return t and (os.date("%b ", t) .. tonumber(os.date("%d", t)) .. os.date(", %Y", t)) or nil end

-- 2.1.28 (TK): a book's popup: its time, pages and days, when you started and finished,
-- and Stats / Book Page
-- 2.1.30 (TK): when you read a book, from KOReader's statistics (every copy of it, by
-- title): { days = { { t, secs, pages } }, sits, longest = { t, secs }, best, run, part }
function Rings.bookDays(title)
    local key = Rings.titleKey(title)
    if key == "" then return nil end
    local conn = K.openDb()
    if not conn then return nil end
    local out = { days = {}, sits = 0 }
    local ok = pcall(function()
        local like = key:gsub("[%%_]", "") .. "%"
        local r = K.query(conn, "SELECT strftime('%Y-%m-%d', p.start_time, 'unixepoch', 'localtime'),"
            .. " SUM(MIN(p.duration, ?)),"
            .. " COUNT(DISTINCT p.page) FROM page_stat_data p JOIN book b ON b.id = p.id_book"
            .. " WHERE lower(b.title) LIKE ? GROUP BY 1 ORDER BY 1;", { K.maxSec(), like })
        for i = 1, (r and r[1]) and #r[1] or 0 do
            local y, mo, d = tostring(r[1][i]):match("^(%d+)%-(%d+)%-(%d+)")
            if y and (tonumber(r[2][i]) or 0) >= 60 then -- a book opened for a moment isn't a reading day
                local e = { t = os.time{ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 },
                    secs = tonumber(r[2][i]) or 0, pages = tonumber(r[3][i]) or 0 }
                out.days[#out.days + 1] = e
                if not out.best or e.secs > out.best.secs then out.best = e end
            end
        end
        -- sittings (no more than 10 minutes between pages) and the part of the day
        local q = K.query(conn, "SELECT p.start_time, MIN(p.duration, ?) FROM page_stat_data p"
            .. " JOIN book b ON b.id = p.id_book"
            .. " WHERE lower(b.title) LIKE ? ORDER BY p.start_time;", { K.maxSec(), like })
        local cur
        local parts = { 0, 0, 0, 0 }
        for i = 1, (q and q[1]) and #q[1] or 0 do
            local t, du = tonumber(q[1][i]) or 0, tonumber(q[2][i]) or 0
            if cur and t - cur.stop <= 600 then cur.secs, cur.stop = cur.secs + du, t + du
            else
                cur = { start = t, stop = t + du, secs = du }
                out.sits = out.sits + 1
            end
            if not out.longest or cur.secs > out.longest.secs then out.longest = { t = cur.start, secs = cur.secs } end
            local hh = tonumber(os.date("%H", t))
            local k = 4
            if hh >= 5 and hh < 12 then k = 1
            elseif hh >= 12 and hh < 18 then k = 2
            elseif hh >= 18 and hh < 22 then k = 3 end
            parts[k] = parts[k] + du
        end
        local names = { _("mornings"), _("afternoons"), _("evenings"), _("nights") }
        local tot, bk = 0, 1
        for k = 1, 4 do tot = tot + parts[k] if parts[k] > parts[bk] then bk = k end end
        if tot > 0 then out.part = { name = names[bk], pct = math.floor(parts[bk] / tot * 100 + 0.5) } end
    end)
    pcall(conn.close, conn)
    if not ok or #out.days == 0 then return nil end
    -- the most days in a row
    local run, best = 0, 0
    for i = 1, #out.days do
        local gap_d = i > 1 and math.floor((out.days[i].t - out.days[i - 1].t + 3600) / 86400) or 0
        if gap_d == 1 then run = run + 1 else run = 1 end
        best = math.max(best, run)
    end
    out.run = best
    return out
end

-- 2.1.28 (TK): a book's popup: its time, pages and days, when you started and finished,
-- and Stats / Book Page. 2.1.30 (TK): interactive: when you read it, day by day (a bar
-- a day from the first to the last), its best day, longest sitting, days in a row and
-- the part of the day you read it most
function Rings.bookPopup(Y, bi, item)
    local b = Y.books[bi]
    if not (b and O.Sheet) then return end
    local fin
    for k = 1, #Y.finished do if Y.finished[k].book == bi then fin = Y.finished[k].t end end
    -- 2.1.31 (TK): the same popup wherever it opens: this device's history for the book
    -- even on BookOrbit's side (BookOrbit doesn't say per book how long you read)
    local D = Rings.bookDays(b.title)
    local secs = b.secs or 0
    if D and secs < 60 then
        secs = 0
        for i = 1, #D.days do secs = secs + D.days[i].secs end
    end
    local counts = {}
    if secs >= 60 then counts[1] = { n = durS(secs), text = _("Read"), colour = "blue" } end
    local pg = b.read_pages or b.pages
    if pg then counts[#counts + 1] = { n = pg, text = b.read_pages and _("Pages read") or _("Pages"),
        colour = "green" } end
    local nd = D and #D.days or b.days
    if nd then counts[#counts + 1] = { n = nd, text = nd == 1 and _("Day") or _("Days"), colour = "purple" } end
    if D and D.sits > 0 then counts[#counts + 1] = { n = D.sits, text = D.sits == 1 and _("Sitting") or _("Sittings"),
        colour = "gold" } end
    local items = {}
    if #counts > 0 then items[1] = { kind = "counts", list = counts } end
    local when = {}
    if b.from then when[#when + 1] = T(_("Started %1"), dateS(b.from)) end
    if fin or b.to then when[#when + 1] = T(_("Finished %1"), dateS(fin or b.to))
    elseif b.last then when[#when + 1] = T(_("Last read %1"), dateS(b.last)) end
    if #when > 0 then items[#items + 1] = { kind = "text", text = table.concat(when, "  ·  "), size = 13 } end
    local sections = { { colour = "blue", plain = true, items = items } }
    if D then
        -- a bar a day, first day to last (empty days left as gaps)
        local strip = { kind = "custom", build = function(w, P)
            local h = px(92)
            local t0, t1 = D.days[1].t, D.days[#D.days].t
            local span = math.max(1, math.floor((t1 - t0 + 3600) / 86400) + 1)
            local mx = 1
            for i = 1, #D.days do mx = math.max(mx, D.days[i].secs) end
            local l0 = text(dayShort(t0), 10, false, SUB)
            local l1 = text(dayShort(t1), 10, false, SUB)
            local lh = l0:getSize().h
            return canvas(w, h, function(bb, x, y)
                local gh = h - lh - px(6)
                local slot = w / span
                local bw = math.min(px(28), math.max(px(2), math.floor(slot * 0.7))) -- one day isn't a wall
                fill(bb, x, y + gh, w, px(1), P.colour and P.track or { v = INK })
                for i = 1, #D.days do
                    local e = D.days[i]
                    local k = math.floor((e.t - t0 + 3600) / 86400)
                    local bh = math.max(px(3), math.floor(gh * e.secs / mx))
                    local bx = x + math.floor(k * slot + (slot - bw) / 2)
                    fill(bb, bx, y + gh - bh, bw, bh, (e == D.best) and (P.colour and P.hue("gold") or { v = INK })
                        or (P.colour and P.hue("blue") or { v = INK }))
                end
                l0:paintTo(bb, x, y + gh + px(4))
                if span > 1 then l1:paintTo(bb, x + w - l1:getSize().w, y + gh + px(4)) end
            end)
        end }
        local facts = {}
        if D.best then facts[#facts + 1] = { arrow = false, colour = "gold",
            text = T(_("Best day: %1"), dateS(D.best.t)),
            note = durS(D.best.secs) .. " · " .. T(_("%1 pages"), D.best.pages) } end
        if D.longest and D.longest.secs >= 60 then facts[#facts + 1] = { arrow = false, colour = "blue",
            text = T(_("Longest sitting: %1"), dateS(D.longest.t)), note = durS(D.longest.secs) } end
        if D.run and D.run > 1 then facts[#facts + 1] = { arrow = false, colour = "red",
            text = T(_("%1 days in a row"), D.run) } end
        if D.part then facts[#facts + 1] = { arrow = false, colour = "green",
            text = T(_("Mostly %1"), D.part.name), note = D.part.pct .. "%" } end
        local wi = { strip }
        if #facts > 0 then wi[2] = { kind = "list", list = facts } end
        local wt = Y.src == "bookorbit" and _("When you read it · on this device") or _("When you read it")
        sections[#sections + 1] = { title = wt, colour = "teal", plain = true, items = wi }
    end
    local rec = Rings.recordFor(b, item)
    local pills = {}
    if rec and O.BookPage then
        pills[#pills + 1] = { text = _("Stats"), colour = "blue", fill = true, callback = function()
            if O.BookPage.show(rec) and O.BookPage.openStats then O.BookPage.openStats() end
        end }
        pills[#pills + 1] = { text = _("Book Page"), colour = "teal", callback = function() O.BookPage.show(rec) end }
    end
    if #pills > 0 then
        sections[#sections + 1] = { colour = "blue", plain = true, items = { { kind = "pills", list = pills } } }
    end
    local sub = {}
    if b.author then sub[1] = b.author end
    sub[#sub + 1] = (fin or b.to) and _("finished ✓") or _("not finished")
    O.Sheet.show({ title = b.title or "?", subtitle = table.concat(sub, " · "), cancel = false, sections = sections })
end

-- 2.1.28 (TK): every book read in the year (or All Time), most time first, 8 a page;
-- a row opens its popup
function Rings.bookList(Y, open, title)
    if not O.Sheet then return end
    local fin = {}
    for k = 1, #Y.finished do fin[Y.finished[k].book] = true end
    local order = {}
    for i = 1, #Y.books do order[i] = i end
    table.sort(order, function(a, c) return (Y.books[a].secs or 0) > (Y.books[c].secs or 0) end)
    local per = 8
    local pages = math.max(1, math.ceil(#order / per))
    local widget
    local function spec(pgn)
        local rows = {}
        for k = (pgn - 1) * per + 1, math.min(#order, pgn * per) do
            local i = order[k]
            local b = Y.books[i]
            local bits = {}
            if (b.secs or 0) >= 60 then bits[1] = durS(b.secs) end
            local pg = b.read_pages or b.pages
            if pg then bits[#bits + 1] = T(_("%1 pages"), pg) end
            rows[#rows + 1] = { text = (fin[i] and "✓ " or "") .. (b.title or "?"), note = table.concat(bits, " · "),
                colour = fin[i] and "green" or "blue", keep = true, callback = function() open(i) end }
        end
        local its = { { kind = "list", list = rows } }
        if pages > 1 then
            its[#its + 1] = { kind = "pills", list = {
                { text = "‹", enabled = pgn > 1, keep = true, callback = function() widget:rebuild(spec(pgn - 1)) end },
                { text = T(_("%1 / %2"), pgn, pages), enabled = false },
                { text = "›", enabled = pgn < pages, keep = true,
                    callback = function() widget:rebuild(spec(pgn + 1)) end },
            } }
        end
        return { title = title or T(_("Your %1 books"), Y.year), cancel = false,
            subtitle = T(_("%1 books · %2 finished · %3"), #order, #Y.finished, durS(Y.total or 0)),
            sections = { { colour = "blue", plain = true, items = its } } }
    end
    widget = O.Sheet.show(spec(1))
end

-- shared with All Time (2.1.28)
Rings.hue, Rings.pill, Rings.drawRing, Rings.numbersRow, Rings.sectionHead = hue, pill, drawRing, numbersRow,
    sectionHead

-- Your Year. nav: { year = this card's year, go(y), now_title } ; returns the widget and taps
function Rings.yearCard(Y, d, rec, cw, P, nav)
    local VG, VS, HG, HS = W("verticalgroup"), W("verticalspan"), W("horizontalgroup"), W("horizontalspan")
    local g = VG:new{ align = "left" }
    local taps = {}
    local function add(w) g[#g + 1] = w end
    local function sp(v) add(VS:new{ width = px(v) }) end
    local y = Y.year
    local this_year = tonumber(os.date("%Y", d.now))
    local prev = pill("‹ " .. (y - 1), P.blue, P)
    local nxt = y < this_year and pill((y + 1) .. " ›", P.blue, P) or nil
    -- 2.1.28 (TK): ‹ 2025 · 2026 · All Time
    local allp = nav.all and pill(_("All Time"), P.gold, P, true) or nil
    local yname = text(tostring(y) .. (Y.src == "bookorbit" and "  ·  BookOrbit" or "  ·  " .. _("Device")), 16, true, INK)
    local navh = math.max(yname:getSize().h, prev:getSize().h)
    add(canvas(cw, navh, function(bb, x, yy)
        prev:paintTo(bb, x, yy)
        yname:paintTo(bb, x + math.floor((cw - yname:getSize().w) / 2), yy + math.floor((navh - yname:getSize().h) / 2))
        local rx = x + cw
        if allp then rx = rx - allp:getSize().w allp:paintTo(bb, rx, yy) rx = rx - px(8) end
        if nxt then nxt:paintTo(bb, rx - nxt:getSize().w, yy) end
    end))
    taps[#taps + 1] = { prev, function() nav.go(y - 1) end }
    if nxt then taps[#taps + 1] = { nxt, function() nav.go(y + 1) end } end
    if allp then taps[#taps + 1] = { allp, function() nav.all() end } end
    sp(6)

    local items, idxs = shelfItems(Y)
    local by_title = {}
    for _i, it in ipairs(items) do if it.title then by_title[it.title] = it end end
    local cols = {}
    for i = 1, #Y.books do cols[i] = bookColour(P, Y, i, by_title) end

    -- the ring: a bar a day
    local n = daysIn(y)
    local today = (y == this_year) and doyOf(d.now) or nil
    local maxs = 1
    for _dy, s in pairs(Y.secs) do maxs = math.max(maxs, s) end
    local s = { n = n, bars = {}, marks = {}, gap = 0.08, label_at_start = false, label_size = 12 }
    for dy = 1, n do
        local v = Y.secs[dy]
        if v and v > 0 then s.bars[dy] = { v = math.min(1, v / maxs), k = Y.top[dy] and cols[Y.top[dy]] or P.mid } end
    end
    for _i, f in ipairs(Y.finished) do
        local fy = tonumber(os.date("%Y", f.t))
        if fy == y then s.marks[doyOf(f.t)] = cols[f.book] end
    end
    s.today = today
    if today then s.ahead_from, s.ahead_step = today + 1, 3 end
    s.labels = {}
    local letters = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }
    local now_m = (y == this_year) and tonumber(os.date("%m", d.now)) or nil
    for mo = 1, 12 do
        local dy = doyOf(os.time{ year = y, month = mo, day = 15, hour = 12 })
        s.labels[dy] = letters[mo]
        if mo == now_m then s.label_bold = dy end
    end
    local c1 = text(today and T(_("%1 · DAY %2"), y, today) or tostring(y), 11, false, SUB)
    local c2 = text(tostring(#Y.finished), 48, true, INK)
    local c3 = text(Y.goal and Y.goal.target and T(_("of %1 books"), Y.goal.target) or (#Y.finished == 1 and _("book finished") or _("books finished")), 13, false, SUB)
    local c4
    if Y.goal and Y.goal.target and #Y.finished >= Y.goal.target then
        c4 = text(_("Goal reached"), 12, true, INK)
    elseif today and not d.finished and not d.alltime then
        c4 = text(T(_("now · %1"), tostring(rec.display_title or rec.title or "")), 10, true, INK, px(128))
    end
    local ring_h = math.min(math.floor(cw * 0.86), px(330))
    local ring = canvas(cw, ring_h, function(bb, x, yy, w, h)
        local cx, cy = x + math.floor(w / 2), yy + math.floor(h / 2)
        s.cx, s.cy = cx, cy
        s.reach = math.floor(h / 2) - px(30)
        s.rin = math.floor(s.reach * 0.64)
        s.label_gap = 16
        drawRing(bb, s, P)
        centred(bb, cx, cy - math.floor(stackH({ c1, c2, c3, c4 }) / 2), { c1, c2, c3, c4 })
    end)
    add(ring)
    -- 2.1.29 (TK): the spines' titles are small: a tap on the ring lists every book
    taps[#taps + 1] = { ring, function()
        Rings.bookList(Y, function(bi)
            local item
            for k = 1, #items do if idxs[k] == bi then item = items[k] break end end
            Rings.bookPopup(Y, bi, item)
        end)
    end }
    local key = { _("bar: your time that day, in the book's colour"), _("dot: a book finished") }
    if Y.src == "bookorbit" then key[#key + 1] = _("grey: books not finished yet") end
    local kt = text(table.concat(key, "  ·  "), 10, false, SUB, cw)
    add(HG:new{ align = "center", HS:new{ width = math.floor((cw - kt:getSize().w) / 2) }, kt })
    sp(10)

    -- today, this week, the streak (all books); BookOrbit: listening too
    local tdy = today
    local function secsOn(dy) return (dy and dy >= 1 and Y.secs[dy]) or 0 end
    local wk, lwk = 0, 0
    if tdy then
        local wd = (tonumber(os.date("%w", d.now)) + 6) % 7
        for i = 0, wd do wk = wk + secsOn(tdy - i) end
        for i = wd + 1, wd + 7 do lwk = lwk + secsOn(tdy - i) end
    end
    local streak, longest, run = 0, 0, 0
    for dy = 1, (tdy or n) do
        if secsOn(dy) > 0 then run = run + 1 else run = 0 end
        longest = math.max(longest, run)
    end
    if tdy then
        local t0 = secsOn(tdy) > 0 and tdy or tdy - 1
        while t0 >= 1 and secsOn(t0) > 0 do streak, t0 = streak + 1, t0 - 1 end
    end
    local chg = lwk > 0 and math.floor((wk - lwk) / lwk * 100 + 0.5) or nil
    local function split(v) local a, b = durS(v):match("^(%d+)(.*)$") return a or "0", b or "m" end
    local cols4 = {}
    if tdy then
        local a, b = split(secsOn(tdy))
        cols4[#cols4 + 1] = { _("TODAY"), a, b, T(_("%1 days read"), Y.days_read or (function() local c = 0 for _k in pairs(Y.secs) do c = c + 1 end return c end)()) }
        local a2, b2 = split(wk)
        cols4[#cols4 + 1] = { _("THIS WEEK"), a2, b2, chg and ((chg >= 0 and "▲ " or "▼ ") .. math.abs(chg) .. "% " .. _("on last")) or "",
            chg and (chg >= 0 and P.green or P.red) or nil }
        cols4[#cols4 + 1] = { _("STREAK"), tostring(streak), streak == 1 and _(" day") or _(" days"), T(_("Longest %1"), longest) }
    else
        local a, b = split(Y.total or 0)
        cols4[#cols4 + 1] = { _("TIME"), a, b, "" }
        cols4[#cols4 + 1] = { _("LONGEST"), tostring(longest), _(" days"), _("in a row") }
    end
    if Y.audio and Y.audio > 0 then
        local a, b = split(Y.audio)
        cols4[#cols4 + 1] = { _("LISTENED"), a, b, T(_("of %1"), durS(Y.total or 0)) }
    end
    add(numbersRow(cw, P, cols4))
    sp(12)

    -- the year's shelf
    local right = Y.pages and Y.pages > 0 and T(_("%1 PAGES"), Y.pages) or (Y.total and string.upper(durS(Y.total))) or nil
    add(sectionHead(T(_("Your %1 shelf"), y), right, cw, P))
    sp(6)
    local shelf_h = px(130)
    -- 2.1.28 / 2.1.32 (TK): tap a spine for that book's popup
    local function bookOf(book)
        if type(book) ~= "table" then return nil end
        for k = 1, #items do if items[k] == book then return idxs[k], items[k] end end
        -- Bookshelf may hand back its own copy of the record: matched by title then
        local want = Rings.titleKey(book.title or book.display_title)
        for k = 1, #Y.books do
            if Rings.titleKey(Y.books[k].title) == want then
                for kk = 1, #items do if idxs[kk] == k then return k, items[kk] end end
                return k, nil
            end
        end
        return nil
    end
    local function spineTapped(book)
        local bi, item = bookOf(book)
        if O.cfg and O.cfg.diagnostics then
            local t = type(book) == "table" and book.title
            O.logger.info(O.TAG, "Your Year spine tap:", tostring(t), "->", tostring(bi))
        end
        if bi then Rings.bookPopup(Y, bi, item) end
    end
    local row = bookshelfRow(items, cw, shelf_h, spineTapped)
    local hits = {}
    local shelf = row or plainShelf(Y, cw, shelf_h, P, hits)
    -- 2.1.35 (TK: spine taps still did nothing on the Kobo): Bookshelf's row is an
    -- OverlapGroup, which never records where it was drawn, so the page's tap test never
    -- matched it. Held in our own box that does; the spine is then found by its own place.
    if row then
        local inner = row
        local rs = inner:getSize()
        shelf = canvas(rs.w, rs.h, function(bb, x0, y0) inner:paintTo(bb, x0, y0) end)
    end
    add(shelf)
    local function diag(...)
        if O.cfg and O.cfg.diagnostics then O.logger.info(O.TAG, "Your Year shelf tap:", ...) end
    end
    taps[#taps + 1] = { shelf, function()
        local pos = K.tapPos()
        diag("at", pos and pos.x, pos and pos.y, "| shelf at", shelf.dimen and shelf.dimen.x, shelf.dimen and shelf.dimen.y,
            "| bookshelf row:", row ~= nil)
        if not pos then return end
        if row then
            local slot = Rings.slotAt(row, pos)
            -- a tap just past a thin spine (or in the shelf's end margin): the nearest one
            if not slot then
                local best, bd
                local function walk(w, depth)
                    if type(w) ~= "table" or depth > 10 then return end
                    if w.book and w.dimen and w.dimen.x then
                        local dx = pos.x < w.dimen.x and (w.dimen.x - pos.x) or (pos.x - (w.dimen.x + w.dimen.w))
                        if not bd or dx < bd then best, bd = w, dx end
                    end
                    for i = 1, #w do walk(w[i], depth + 1) end
                end
                walk(row, 0)
                if best and bd <= px(24) then slot = best end
            end
            diag("spine:", slot and tostring(slot.book and (slot.book.title or slot.book.display_title)) or "none here")
            if slot then spineTapped(slot.book) end
            return
        end
        for k = 1, #hits do
            local hh = hits[k]
            if pos.x >= hh.x and pos.x < hh.x + hh.w then
                local item
                for kk = 1, #items do if idxs[kk] == hh.book then item = items[kk] break end end
                return Rings.bookPopup(Y, hh.book, item)
            end
        end
    end }
    local off = #Y.books - #items
    if row and off > 0 then
        sp(4)
        add(text(off == 1 and _("1 more not on this device") or T(_("%1 more not on this device"), off), 10, false, SUB, cw))
    end
    -- 2.1.28 (TK): every book read this year, not just the finished ones
    if #Y.books > 0 then
        sp(10)
        local lp = pill(T(_("Every book this year · %1  ›"), #Y.books), P.blue, P)
        add(HG:new{ align = "center", HS:new{ width = math.floor((cw - lp:getSize().w) / 2) }, lp })
        taps[#taps + 1] = { lp, function() Rings.bookList(Y, function(bi)
            local item
            for k = 1, #items do if idxs[k] == bi then item = items[k] break end end
            Rings.bookPopup(Y, bi, item)
        end) end }
    end
    if Y.src == "bookorbit" and Y.fetched then
        sp(4)
        add(text(T(_("from BookOrbit · as of %1"), dayShort(Y.fetched) .. os.date(" %I:%M %p", Y.fetched):gsub(" 0", " ")), 10, false, SUB, cw))
    end
    return g, taps
end

return Rings
