-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- 2.1.23 (TK): X-Ray and ReadMastery in the stats.
--
-- X-Ray: what X-Ray (xray.koplugin) saved for a book (its xray_cache.lua in the book's
-- sidecar folder, read as plain data, the book closed, offline), or KOAssistant's X-Ray
-- (koassistant_cache.lua there) when X-Ray isn't installed. Everything stops at your page:
-- a name shows once it's come up by then, mentions only up to it, the timeline only for
-- the chapters you've reached. On top of that, your reading: your time on the pages each
-- one comes up on (KOReader's statistics), and how often you looked each one up in X-Ray
-- (counted by OrbitShelf from 2.1.23 on: X-Ray doesn't keep a count).
--
--   XRay.show(rec, path, d, extra)   the X-Ray popup (counts, you and the cast, people,
--                                    places, the timeline); a name opens its card
--   XRay.summary(d, extra)           the numbers the stats tile and Moments use
--   XRay.moments(d, extra)           Moments lines ("In the story")
--
-- ReadMastery (readmastery.koplugin), when installed: the achievements it unlocked while
-- you were reading this book (from its readmastery_data.json), and, from 2.1.23 on, the
-- XP, level-ups and tier-ups each book earned (ReadMastery keeps no history of those, so
-- OrbitShelf notes them while a book is open).
--
--   XRay.rewards(d)                  { { name, tier, t, note } } for this book
local O = require("orbitshelf_core")
local T, _ = O.T, O._

local XRay = {}
O.XRay = XRay

local function lower(s) return type(s) == "string" and s:lower() or "" end

-- ---- What OrbitShelf notes itself (lookups, ReadMastery's XP): settings/orbitshelf_reading_log.lua
-- Per book, by its title (lower case), so a book downloaded again keeps them.

local log_store
local function logStore()
    if log_store == nil then
        local ok, st = pcall(function()
            return require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/orbitshelf_reading_log.lua")
        end)
        log_store = ok and st or false
    end
    return log_store or nil
end

local function bookLog(title)
    local st = logStore()
    if not st or lower(title) == "" then return nil, nil end
    local all = st:readSetting("books") or {}
    local b = all[lower(title)]
    if type(b) ~= "table" then b = { lookups = {}, rm = {} } end
    b.lookups = type(b.lookups) == "table" and b.lookups or {}
    b.rm = type(b.rm) == "table" and b.rm or {}
    return b, function()
        all[lower(title)] = b
        st:saveSetting("books", all)
        st:flush()
    end
end

-- ---- X-Ray's data -------------------------------------------------------------------------

local function readLuaFile(file)
    if O.lfs.attributes(file, "mode") ~= "file" then return nil end
    local chunk = loadfile(file)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, v = pcall(chunk)
    return ok and type(v) == "table" and v or nil
end

local function sidecar(path)
    local ok, dir = pcall(function() return require("docsettings"):getSidecarDir(path) end)
    return ok and dir or nil
end

local function jsonDecode(s)
    if type(s) ~= "string" then return nil end
    -- KOAssistant's X-Ray is JSON, sometimes in a ```json block
    s = s:match("```json%s*(.-)%s*```") or s:match("```%s*(.-)%s*```") or s
    s = s:match("^%s*(%b{})") or s
    for _i, name in ipairs({ "rapidjson", "json" }) do
        local okR, J = pcall(require, name)
        if okR and type(J) == "table" and type(J.decode) == "function" then
            local okD, v = pcall(J.decode, s)
            if okD and type(v) == "table" then return v end
        end
    end
    return nil
end

local loaded = {} -- path -> { mtime, data }

-- X-Ray's (or KOAssistant's) saved X-Ray for the book: data, "xray" | "koassistant"; nil when neither
function XRay.load(path, pct)
    if type(path) ~= "string" then return nil end
    local dir = sidecar(path)
    if not dir then return nil end
    local pluginOn = O.Stats and O.Stats.pluginOn or function() return true end
    if pluginOn("xray") then
        local file = dir .. "/xray_cache.lua"
        local m = O.lfs.attributes(file, "modification")
        if m then
            local c = loaded[file]
            if not (c and c.m == m) then c = { m = m, data = readLuaFile(file) } loaded[file] = c end
            if c.data then return c.data, "xray" end
        end
    end
    if pluginOn("koassistant") then
        local file = dir .. "/koassistant_cache.lua"
        local m = O.lfs.attributes(file, "modification")
        if m then
            local c = loaded[file]
            if not (c and c.m == m) then
                local cache = readLuaFile(file)
                local e = cache and cache._xray_cache
                local data = e and jsonDecode(e.result)
                -- KOAssistant writes its X-Ray up to where you were: one ahead of you now isn't shown
                if data and tonumber(e.progress_decimal) and pct and tonumber(e.progress_decimal) > pct + 0.02 then data = nil end
                c = { m = m, data = data }
                loaded[file] = c
            end
            if c.data then return c.data, "koassistant" end
        end
    end
    return nil
end

-- the chapter (index in extra.chapters) a page or a chapter title is in
local function chapterOf(chs, page, title)
    if not chs then return nil end
    if type(title) == "string" and title ~= "" then
        for i, c in ipairs(chs) do if c.title == title then return i end end
    end
    if page then
        for i, c in ipairs(chs) do if page >= c.a and page <= (c.b or math.huge) then return i end end
    end
    return nil
end

local KINDS = {
    { key = "characters", kind = "person", label = _("Characters"), colour = "purple" },
    { key = "historical_figures", kind = "historical", label = _("Historical"), colour = "gold" },
    { key = "locations", kind = "place", label = _("Places"), colour = "teal" },
    { key = "terms", kind = "term", label = _("Terms"), colour = "blue" },
}

-- everything up to your page: { people, places, historical, terms, timeline, src, fetched_to }
function XRay.summary(d, extra)
    if type(d) ~= "table" then return nil end
    local data, src = XRay.load(d.path, d.pct)
    if not data then return nil end
    local now = tonumber(d.page_now) or math.huge
    local ps = d.page_secs or {}
    local chs = extra and extra.chapters
    local looks = {}
    local blog = bookLog(d.title)
    if blog then looks = blog.lookups end
    local out = { src = src, people = {}, places = {}, historical = {}, terms = {}, timeline = {}, all = {} }
    for _k, kd in ipairs(KINDS) do
        local list = data[kd.key]
        if kd.key == "locations" and type(list) ~= "table" then list = data.places end
        if kd.key == "terms" and type(list) ~= "table" then list = data.themes end
        for idx, e in ipairs(type(list) == "table" and list or {}) do
            local name = type(e) == "table" and (e.name or e.title) or nil
            if type(name) == "string" and name ~= "" then
                local ms, pages, secs, first = {}, {}, 0, nil
                for _j, m in ipairs(type(e.mentions) == "table" and e.mentions or {}) do
                    local pg = type(m) == "table" and tonumber(m.page)
                    if pg and pg <= now then
                        ms[#ms + 1] = m
                        if not pages[pg] then pages[pg] = true secs = secs + (ps[pg] or 0) end
                        first = first and math.min(first, pg) or pg
                    end
                end
                local vf = type(e.visible_from) == "table" and tonumber(e.visible_from.page_hint) or nil
                -- not met yet: its first mention or X-Ray's own "visible from" is past your page
                local hidden = (vf and vf > now) or (#(type(e.mentions) == "table" and e.mentions or {}) > 0 and #ms == 0)
                if not hidden then
                    local ent = {
                        name = name, kind = kd.kind, colour = kd.colour, order = idx,
                        role = type(e.role) == "string" and e.role or (type(e.category) == "string" and e.category or nil),
                        job = type(e.occupation) == "string" and e.occupation or nil,
                        desc = e.description or e.biography or e.definition or e.summary,
                        aliases = type(e.aliases) == "table" and e.aliases or nil,
                        mentions = ms, pages = pages, secs = secs, first = first or vf,
                        looked = tonumber(looks[lower(name)]) or 0,
                    }
                    if type(ent.desc) ~= "string" then ent.desc = nil end
                    -- per chapter, for "Where they come up"
                    if chs then
                        ent.per = {}
                        for _j, m in ipairs(ms) do
                            local ci = chapterOf(chs, tonumber(m.page), m.chapter)
                            if ci then ent.per[ci] = (ent.per[ci] or 0) + 1 end
                        end
                    end
                    local bucket = kd.kind == "person" and out.people or kd.kind == "place" and out.places
                        or kd.kind == "historical" and out.historical or out.terms
                    bucket[#bucket + 1] = ent
                    out.all[#out.all + 1] = ent
                end
            end
        end
    end
    -- the timeline, for the chapters you've reached (all of it once the book's done)
    local cur = d.chapter_now or (chs and chapterOf(chs, now)) or nil
    for _i, ev in ipairs(type(data.timeline) == "table" and data.timeline or {}) do
        if type(ev) == "table" then
            local txt = ev.event or ev.description or ev.summary
            local ci = chs and chapterOf(chs, nil, ev.chapter) or nil
            -- an event whose chapter can't be matched shows only when X-Ray's fetch didn't go past you
            local safe = ci and (not cur or ci <= cur) or (not ci and (tonumber(data.last_fetch_page) or 0) <= now)
            if type(txt) == "string" and txt ~= "" and (d.finished or safe) then
                out.timeline[#out.timeline + 1] = { chapter = type(ev.chapter) == "string" and ev.chapter or nil, text = txt, ci = ci }
            end
        end
    end
    -- people and places in the order you met them
    local function byFirst(a, b)
        if (a.first or math.huge) ~= (b.first or math.huge) then return (a.first or math.huge) < (b.first or math.huge) end
        return a.order < b.order
    end
    table.sort(out.people, byFirst)
    table.sort(out.places, byFirst)
    local function top(list, field)
        local best
        for _i, e in ipairs(list) do
            local v = field == "mentions" and #e.mentions or e[field]
            if v and v > 0 and (not best or v > (field == "mentions" and #best.mentions or best[field])) then best = e end
        end
        return best
    end
    local cast = {}
    for _i, e in ipairs(out.people) do cast[#cast + 1] = e end
    for _i, e in ipairs(out.historical) do cast[#cast + 1] = e end
    out.most_time, out.most_mentioned, out.most_looked = top(cast, "secs"), top(cast, "mentions"), top(cast, "looked")
    out.by_time = {}
    for _i, e in ipairs(cast) do if e.secs > 0 then out.by_time[#out.by_time + 1] = e end end
    table.sort(out.by_time, function(a, b) return a.secs > b.secs end)
    return out
end

-- who comes up on a page (for Pages You Came Back To)
function XRay.onPage(sum, page)
    local out = {}
    for _i, e in ipairs(sum and sum.people or {}) do
        if e.pages[page] or e.pages[page - 1] or e.pages[page + 1] then out[#out + 1] = e.name end
    end
    return out
end

-- who leads each chapter: { [ci] = entity }
function XRay.leads(sum)
    local out, n = {}, {}
    for _i, e in ipairs(sum and sum.people or {}) do
        for ci, c in pairs(e.per or {}) do
            if c > (n[ci] or 0) then n[ci], out[ci] = c, e end
        end
    end
    return out, n
end

-- ---- Counting lookups (while a book is open) ----------------------------------------------

-- main.lua's onReaderReady: each X-Ray card opened from the text counts for that name
function XRay.hookLookups(ui)
    local xp = ui and ui.xray
    local lm = type(xp) == "table" and xp.lookup_manager or nil
    if type(lm) ~= "table" or type(lm.showResult) ~= "function" or lm._orbitshelf_counted then return end
    lm._orbitshelf_counted = true
    local orig = lm.showResult
    lm.showResult = function(self, item, ...)
        pcall(function()
            local title = ui.document and ui.doc_props and ui.doc_props.display_title
            if not title then
                local props = ui.doc_settings and ui.doc_settings:readSetting("doc_props")
                title = props and props.title
            end
            local name = type(item) == "table" and item.name
            if type(name) == "string" and title then
                local b, save = bookLog(title)
                if b then
                    b.lookups[lower(name)] = (tonumber(b.lookups[lower(name)]) or 0) + 1
                    save()
                end
            end
        end)
        return orig(self, item, ...)
    end
end

-- ---- ReadMastery ---------------------------------------------------------------------------

local function rmOn()
    local pluginOn = O.Stats and O.Stats.pluginOn
    return pluginOn and (pluginOn("readmastery") or pluginOn("ReadMastery")) or false
end

local function rmData()
    local ok, data = pcall(function()
        local file = require("datastorage"):getDataDir() .. "/readmastery/readmastery_data.json"
        local f = io.open(file, "r")
        if not f then return nil end
        local s = f:read("*all")
        f:close()
        return jsonDecode(s)
    end)
    return ok and data or nil
end

local function achName(id)
    local A = package.loaded["achievements"]
    local def = type(A) == "table" and type(A.DEFINITIONS) == "table" and A.DEFINITIONS[id]
    if type(def) == "table" and type(def.name) == "string" then return def.name end
    return (tostring(id):gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end
local TIER = { bronze = _("Bronze"), silver = _("Silver"), gold = _("Gold"), platinum = _("Platinum") }

-- while a book is open: XP, levels, achievements and tiers, noted for it with the time
function XRay.hookReadMastery()
    if XRay._rm_hooked or not rmOn() then return end
    local ok, Core = pcall(require, "readmasterycore")
    if not (ok and type(Core) == "table" and type(Core.addXP) == "function") then return end
    XRay._rm_hooked = true
    local function title()
        local u = require("apps/reader/readerui").instance
        if not (u and u.document) then return nil end
        local props = u.doc_props or (u.doc_settings and u.doc_settings:readSetting("doc_props")) or {}
        return props.display_title or props.title
    end
    local function note(ev)
        pcall(function()
            local t = title()
            if not t then return end
            local b, save = bookLog(t)
            if not b then return end
            ev.t = os.time()
            -- 2.1.35 (TK): where in the book it happened (page, of how many, and the chapter)
            pcall(function()
                local u = require("apps/reader/readerui").instance
                local pg = u and u.view and u.view.state and u.view.state.page
                if not pg and u and u.document and u.document.getCurrentPage then pg = u.document:getCurrentPage() end
                if tonumber(pg) then
                    ev.page = tonumber(pg)
                    ev.of = u.document and u.document.getPageCount and u.document:getPageCount() or nil
                    local ch = u.toc and u.toc.getTocTitleByPage and u.toc:getTocTitleByPage(pg)
                    if type(ch) == "string" and ch ~= "" then ev.chapter = ch end
                end
            end)
            b.rm.events = type(b.rm.events) == "table" and b.rm.events or {}
            table.insert(b.rm.events, ev)
            while #b.rm.events > 60 do table.remove(b.rm.events, 1) end
            save()
        end)
    end
    local orig_xp = Core.addXP
    Core.addXP = function(self, amount, source, ...)
        local lv0 = type(self.getLevel) == "function" and self:getLevel() or nil
        local r = { orig_xp(self, amount, source, ...) }
        pcall(function()
            local t = title()
            if t and tonumber(amount) then
                local b, save = bookLog(t)
                if b then b.rm.xp = (tonumber(b.rm.xp) or 0) + tonumber(amount) save() end
            end
            local lv1 = type(self.getLevel) == "function" and self:getLevel() or nil
            if lv0 and lv1 and lv1 > lv0 then note({ kind = "level", n = lv1 }) end
        end)
        return unpack(r)
    end
    if type(Core.unlockAchievement) == "function" then
        local orig = Core.unlockAchievement
        Core.unlockAchievement = function(self, id, ...)
            local new = orig(self, id, ...)
            if new then note({ kind = "ach", id = id }) end
            return new
        end
    end
    -- 2.1.35: earned again (ReadMastery only counts it): noted with when and where
    if type(Core.incrementAchievementCount) == "function" then
        local orig = Core.incrementAchievementCount
        Core.incrementAchievementCount = function(self, id, ...)
            local n = orig(self, id, ...)
            if tonumber(n) and n > 1 then note({ kind = "again", id = id, n = n }) end
            return n
        end
    end
    if type(Core.setAchievementTier) == "function" then
        local orig = Core.setAchievementTier
        Core.setAchievementTier = function(self, id, tier, ...)
            local was = type(self.getAchievementTier) == "function" and self:getAchievementTier(id) or nil
            local r = orig(self, id, tier, ...)
            if r and tier ~= was and tier ~= "bronze" then note({ kind = "tier", id = id, tier = tier }) end
            return r
        end
    end
end

-- this book's rewards: achievements first unlocked during its sittings, and what was noted
-- while it was open; newest last. { name, tier, t, note, kind }
function XRay.rewards(d)
    if type(d) ~= "table" or not rmOn() then return nil end
    local out, seen = {}, {}
    local data = rmData()
    local ach = data and type(data.achievements) == "table" and data.achievements or {}
    local function during(t)
        for _i, s in ipairs(d.sessions or {}) do
            if t >= s.start - 60 and t <= (s.stop or s.start) + 300 then return true end
        end
        return false
    end
    for id, a in pairs(ach) do
        local t = type(a) == "table" and tonumber(a.unlocked_at)
        if t and during(t) then
            out[#out + 1] = { kind = "ach", name = achName(id), tier = TIER[a.tier or "bronze"], t = t, note = _("while reading this") }
            seen["ach:" .. id] = true
        end
    end
    local b = bookLog(d.title)
    if b then
        for _i, ev in ipairs(type(b.rm.events) == "table" and b.rm.events or {}) do
            if ev.kind == "level" then
                out[#out + 1] = { kind = "level", name = T(_("Level %1"), ev.n), t = ev.t, note = _("reached reading this") }
            elseif ev.kind == "ach" and not seen["ach:" .. tostring(ev.id)] then
                out[#out + 1] = { kind = "ach", name = achName(ev.id), tier = TIER.bronze, t = ev.t, note = _("while reading this") }
            elseif ev.kind == "tier" then
                out[#out + 1] = { kind = "tier", name = achName(ev.id), tier = TIER[ev.tier] or ev.tier, t = ev.t, note = _("tier up while reading this") }
            elseif ev.kind == "again" then
                out[#out + 1] = { kind = "ach", name = T(_("%1 ×%2"), achName(ev.id), ev.n), t = ev.t, note = _("earned again reading this") }
            end
            -- 2.1.35: the page (and chapter) it happened on, when noted
            local last = out[#out]
            if last and last.t == ev.t and tonumber(ev.page) then
                last.page, last.of, last.chapter = ev.page, ev.of, ev.chapter
                last.note = last.note .. " · " .. T(_("p. %1"), ev.page) .. (ev.chapter and (" · " .. ev.chapter) or "")
            end
        end
        out.xp = tonumber(b.rm.xp)
    end
    table.sort(out, function(a, c) return (a.t or 0) < (c.t or 0) end)
    return out
end

-- ---- Moments ----------------------------------------------------------------------------------

local function when(t) return os.date("%b %d", t):gsub(" 0", " ") .. os.date(", %I:%M %p", t):gsub(" 0", " ") end

-- { id, label, line } like the stats page's own moments; group: "story" | "rewards"
function XRay.moments(d, extra)
    local out = {}
    local sum = XRay.summary(d, extra)
    if sum then
        local p1, p2 = sum.people[1], sum.people[2]
        if p1 and p1.first then
            local who = (p2 and p2.first == p1.first) and T(_("%1 and %2"), p1.name, p2.name) or p1.name
            out[#out + 1] = { "xmet", _("First met"), T(_("%1 on p. %2"), who, p1.first), group = "story" }
        end
        if sum.most_looked then
            out[#out + 1] = { "xlook", _("Looked up most"), T(_("%1, %2 times"), sum.most_looked.name, sum.most_looked.looked), group = "story" }
        end
        if sum.most_time and sum.most_time.secs >= 60 then
            local durS = O.Stats and O.Stats._kit and O.Stats._kit.durS or function(s) return math.floor(s / 60) .. "m" end
            out[#out + 1] = { "xtime", _("Most time with"), T(_("%1, %2 on their pages"), sum.most_time.name, durS(sum.most_time.secs)), group = "story" }
        end
        if #sum.places >= 2 then
            local names = {}
            for i = 1, math.min(4, #sum.places) do names[i] = sum.places[i].name end
            out[#out + 1] = { "xplace", _("Where it took you"), table.concat(names, " · "), group = "story" }
        end
    end
    -- 2.1.37 (TK): the story side from other plugins too (with or without X-Ray): Glimpse's
    -- pictures so far, spoiler-free (only up to your chapter, as Glimpse itself shows them)
    local okG, pics = pcall(function()
        local pluginOn = O.Stats and O.Stats.pluginOn or function() return true end
        if not (O.Glimpse and O.Glimpse.pictures and type(d.path) == "string" and pluginOn("glimpse")) then return nil end
        return O.Glimpse.pictures(d.path, { pct = d.pct })
    end)
    if okG and type(pics) == "table" and type(pics.list) == "table" and #pics.list > 0 then
        local maps, trees, latest = 0, 0, nil
        for i = 1, #pics.list do
            local e = pics.list[i]
            if not e.locked then
                if e.kind == "map" then maps = maps + 1 elseif e.kind == "tree" then trees = trees + 1 end
                latest = e
            end
        end
        local extra_w = {}
        if maps > 0 then extra_w[#extra_w + 1] = maps == 1 and _("1 map") or T(_("%1 maps"), maps) end
        if trees > 0 then extra_w[#extra_w + 1] = trees == 1 and _("1 family tree") or T(_("%1 family trees"), trees) end
        local line = (pics.shown == 1 and _("1 picture") or T(_("%1 pictures"), pics.shown))
            .. (#extra_w > 0 and (" (" .. table.concat(extra_w, ", ") .. ")") or "")
            .. (pics.ahead > 0 and (" · " .. T(_("%1 still ahead"), pics.ahead)) or "")
        out[#out + 1] = { "glimpse", _("Pictures so far · Glimpse"), line, group = "story" }
        local cap = latest and type(latest.caption) == "string" and latest.caption:gsub("%s+", " ") or ""
        if cap ~= "" and #cap <= 80 then
            out[#out + 1] = { "glimpse", _("The latest picture · Glimpse"), cap, group = "story" }
        end
    end
    local rw = XRay.rewards(d)
    -- 2.1.26 (TK): the newest five here; All Rewards shows every one
    for i = #(rw or {}), math.max(1, #(rw or {}) - 4), -1 do
        local r = rw[i]
        out[#out + 1] = { "reward", r.name .. (r.tier and (" · " .. r.tier) or ""), when(r.t) .. " · " .. r.note, group = "rewards" }
    end
    if rw and rw.xp and rw.xp > 0 then
        out[#out + 1] = { "reward", _("XP from this book"), T(_("%1 XP so far"), math.floor(rw.xp)), group = "rewards" }
    end
    local all = XRay.allRewards(d)
    out.rewards_n = all and #all or 0
    return out
end

-- 2.1.26 (TK): ReadMastery's own Achievements page (its plugin instance, else its event)
function XRay.openReadMastery()
    local ok = pcall(function()
        local FM = package.loaded["apps/filemanager/filemanager"]
        local RUI = package.loaded["apps/reader/readerui"]
        local ui = (RUI and RUI.instance) or (FM and FM.instance)
        if not ui then return end
        local rm = ui.readmastery
        if rm and type(rm.onReadMasteryShowAchievements) == "function" then
            rm:onReadMasteryShowAchievements()
        else
            ui:handleEvent(require("ui/event"):new("ReadMasteryShowAchievements"))
        end
    end)
    if not ok then O.logger.warn(O.TAG, "couldn't open ReadMastery's achievements") end
end

-- 2.1.28 (TK): every reward ReadMastery has unlocked, not just the ones earned inside this
-- book's sittings (Book Slayer lands when a book is finished, often after the sitting ends),
-- plus this book's level-ups and tier-ups; newest first. { name, tier, t, kind, here }
function XRay.allRewards(d)
    if not rmOn() then return nil end
    local out, here = {}, {}
    local rw = type(d) == "table" and XRay.rewards(d) or nil
    local _rw = rw or {}
    for _rw_n = 1, #_rw do
        local r = _rw[_rw_n]
        if r.kind == "ach" then here[r.name] = true
        else out[#out + 1] = { kind = r.kind, name = r.name, tier = r.tier, t = r.t, here = true } end
    end
    local data = rmData()
    local ach = data and type(data.achievements) == "table" and data.achievements or {}
    for id, a in pairs(ach) do
        if type(a) == "table" then
            local name = achName(id)
            out[#out + 1] = { kind = "ach", name = name, tier = TIER[a.tier or "bronze"] or a.tier,
                t = tonumber(a.unlocked_at), here = here[name] or false }
        end
    end
    table.sort(out, function(a, c) return (a.t or 0) > (c.t or 0) end)
    out.xp = rw and rw.xp
    return out
end

-- 2.1.28 (TK): all of them, a page at a time; no ReadMastery button
function XRay.showRewards(d)
    local list = XRay.allRewards(d) or {}
    local n_here = 0
    for i = 1, #list do if list[i].here then n_here = n_here + 1 end end
    local per = 8
    local pages = math.max(1, math.ceil(#list / per))
    local widget
    local function spec(pg)
        local rows = {}
        for i = (pg - 1) * per + 1, math.min(#list, pg * per) do
            local r = list[i]
            local note = (r.t and r.t > 1000000000) and when(r.t) or ""
            if r.here then note = note ~= "" and (note .. " · " .. _("this book")) or _("this book") end
            rows[#rows + 1] = { arrow = false, text = r.name .. (r.tier and (" · " .. r.tier) or ""),
                colour = r.kind == "level" and "blue"
                or (r.kind == "tier" and "purple" or "gold"), note = note, enabled = true }
        end
        local items = {}
        if #rows > 0 then items[1] = { kind = "list", list = rows }
        else items[1] = { kind = "text", text = _("Nothing unlocked in ReadMastery yet."), size = 13 } end
        if pages > 1 then
            items[#items + 1] = { kind = "pills", list = {
                { text = "‹", enabled = pg > 1, keep = true, callback = function() widget:rebuild(spec(pg - 1)) end },
                { text = T(_("%1 / %2"), pg, pages), enabled = false },
                { text = "›", enabled = pg < pages, keep = true,
                    callback = function() widget:rebuild(spec(pg + 1)) end },
            } }
        end
        local sub = { T(_("%1 unlocked"), #list) }
        if n_here > 0 then sub[#sub + 1] = T(_("%1 from this book"), n_here) end
        if list.xp and list.xp > 0 then sub[#sub + 1] = T(_("%1 XP"), math.floor(list.xp)) end
        return { title = _("Rewards"), subtitle = table.concat(sub, " · "), cancel = false,
            sections = { { colour = "gold", plain = true, items = items } } }
    end
    widget = O.Sheet.show(spec(1))
    return widget
end

-- ---- The X-Ray popup ----------------------------------------------------------------------

local function openXRay(path)
    if type(O.openThen) ~= "function" then return end
    O.openThen(path, function(ui) ui:handleEvent(require("ui/event"):new("ShowXRayQuickMenu")) end)
end

local durS = function(s)
    local f = O.Stats and O.Stats._kit and O.Stats._kit.durS
    return f and f(s) or (math.floor(s / 60) .. "m")
end

local function roleLine(e)
    local bits = {}
    if e.role and e.role ~= "" then bits[#bits + 1] = e.role end
    if e.job and e.job ~= "" and e.job ~= e.role then bits[#bits + 1] = e.job end
    return table.concat(bits, " · ")
end

local KIND_LABEL = { person = _("Character"), historical = _("Historical figure"), place = _("Place"), term = _("Term") }

-- a name's card: what it is, you and it, where it comes up, often with, its mentions
function XRay.showName(e, sum, d, extra, page)
    page = page or 1
    local widget
    local function spec(pg)
        local sections = {}
        local desc = {}
        if e.desc then desc[#desc + 1] = { kind = "text", text = e.desc, size = 13 } end
        if e.aliases and #e.aliases > 0 then
            desc[#desc + 1] = { kind = "text", text = T(_("Also: %1"), table.concat(e.aliases, ", ")), size = 11, dim = true }
        end
        if #desc > 0 then sections[#sections + 1] = { colour = e.colour, plain = true, items = desc } end
        local you = {}
        if e.kind == "person" or e.kind == "historical" or e.kind == "place" then
            you[#you + 1] = { label = _("Your time with"), value = e.secs > 0 and durS(e.secs) or "–" }
        end
        you[#you + 1] = { label = _("Looked up"), value = e.looked > 0 and T(_("%1 times"), e.looked) or _("not yet") }
        if e.first then you[#you + 1] = { label = _("Met"), value = T(_("p. %1"), e.first) } end
        sections[#sections + 1] = { colour = e.colour, items = { { kind = "trio", list = you } } }
        -- where it comes up, by chapter
        local chs = extra and extra.chapters
        if chs and e.per and #e.mentions > 0 then
            local vals, top, last, first = {}, nil, nil, nil
            for i = 1, #chs do
                vals[i] = e.per[i] or 0
                if vals[i] > 0 then
                    first = first or i
                    last = i
                    if not top or vals[i] > vals[top] then top = i end
                end
            end
            local cur = d.chapter_now or #chs
            local items = { { kind = "columns", values = vals, now = not d.finished and cur or nil, colour = e.colour,
                caption = (not d.finished and cur < #chs) and T(_("You're in chapter %1; the rest isn't shown yet."), cur) or nil } }
            if first then
                items[#items + 1] = { kind = "trio", list = {
                    { label = _("First seen"), value = chs[first].title },
                    { label = _("Most mentions"), value = T(_("%1 (%2)"), chs[top].title, vals[top]) },
                    { label = _("Latest"), value = chs[last].title } } }
            end
            sections[#sections + 1] = { title = e.kind == "place" and _("Where it comes up") or _("Where they come up"), colour = e.colour, items = items }
        end
        -- often with: who shares the most pages with it
        local near = {}
        for _i, o in ipairs(sum.all) do
            if o ~= e and (o.kind == "person" or o.kind == "historical" or o.kind == "place") then
                local n = 0
                for pgn in pairs(e.pages) do if o.pages[pgn] then n = n + 1 end end
                if n > 0 then near[#near + 1] = { o, n } end
            end
        end
        table.sort(near, function(a, b) return a[2] > b[2] end)
        if #near > 0 then
            local pills = {}
            for i = 1, math.min(5, #near) do
                local o = near[i][1]
                pills[#pills + 1] = { text = o.name, colour = o.colour, callback = function() XRay.showName(o, sum, d, extra) end }
            end
            sections[#sections + 1] = { title = _("Often with"), colour = e.colour, items = { { kind = "pills", list = pills } } }
        end
        -- the mentions, three to a page, with the words around each
        local per = 3
        local pages = math.max(1, math.ceil(#e.mentions / per))
        if #e.mentions > 0 then
            local list = {}
            for i = (pg - 1) * per + 1, math.min(#e.mentions, pg * per) do
                local m = e.mentions[i]
                list[#list + 1] = { page = T(_("p. %1"), m.page) .. (type(m.chapter) == "string" and (" · " .. m.chapter) or ""),
                    text = type(m.snippet) == "string" and m.snippet or "", colour = e.colour, max_chars = 140 }
            end
            local items = { { kind = "quote", list = list } }
            if pages > 1 then
                items[#items + 1] = { kind = "pills", list = {
                    { text = "‹", enabled = pg > 1, keep = true, callback = function() widget:rebuild(spec(pg - 1)) end },
                    { text = T(_("%1 / %2"), pg, pages), enabled = false },
                    { text = "›", enabled = pg < pages, keep = true, callback = function() widget:rebuild(spec(pg + 1)) end } } }
            end
            sections[#sections + 1] = { title = T(_("Mentions · %1 so far"), #e.mentions), colour = e.colour, items = items }
        end
        local sub = { KIND_LABEL[e.kind] or "" }
        if roleLine(e) ~= "" then sub[#sub + 1] = roleLine(e) end
        if #e.mentions > 0 then sub[#sub + 1] = T(_("%1 mentions so far"), #e.mentions) end
        return { title = e.name, subtitle = table.concat(sub, " · "), sections = sections, cancel = false }
    end
    widget = O.Sheet.show(spec(page))
    return widget
end

-- a list of everyone in one group (Characters, Places, ...)
local function showList(title, list, colour, sum, d, extra)
    local rows = {}
    for i = 1, math.min(40, #list) do
        local e = list[i]
        rows[#rows + 1] = { text = e.name, colour = colour, note = e.first and T(_("p. %1"), e.first) or nil,
            callback = function() XRay.showName(e, sum, d, extra) end }
    end
    O.Sheet.show{ title = title, subtitle = T(_("%1 so far"), #list), cancel = false,
        sections = { { colour = colour, plain = true, items = { { kind = "list", list = rows } } } } }
end

local function showTimeline(sum)
    local rows = {}
    for _i, ev in ipairs(sum.timeline) do
        rows[#rows + 1] = { kind = "text", text = (ev.chapter and (ev.chapter .. ": ") or "") .. ev.text, size = 12 }
    end
    O.Sheet.show{ title = _("Timeline so far"), cancel = false, sections = { { colour = "green", plain = true, items = rows } } }
end

-- the plugins that give a book an X-Ray, when neither has one for it
local function showNone(rec, path)
    local pluginOn = O.Stats and O.Stats.pluginOn or function() return false end
    local sections = {}
    if pluginOn("xray") then
        sections[#sections + 1] = { title = _("X-Ray"), colour = "purple", items = { { kind = "action", list = { {
            text = _("Fetch X-Ray"), sub = _("X-Ray hasn't been fetched for this book yet. Opens the book, then X-Ray's menu."),
            button = _("Fetch"), callback = function() openXRay(path) end } } } } }
    else
        sections[#sections + 1] = { title = _("X-Ray plugin"), colour = "purple", items = { { kind = "text",
            text = _("xray.koplugin: the book's characters, places, historical figures, terms and timeline, up to your page. Once fetched, OrbitShelf shows it here with your time with each one, offline."), size = 12 } } }
        sections[#sections + 1] = { title = _("Or KOAssistant"), colour = "blue", items = { { kind = "text",
            text = pluginOn("koassistant") and _("KOAssistant is installed: its X-Ray (Quick Actions › X-Ray, with the book open) shows here too once it's made.")
                or _("koassistant.koplugin: an AI assistant with its own X-Ray of the book up to where you are. OrbitShelf reads it when X-Ray isn't installed."), size = 12 } } }
    end
    O.Sheet.show{ title = _("X-Ray"), subtitle = tostring(rec and (rec.display_title or rec.title) or ""), sections = sections, cancel = false }
end

function XRay.show(rec, path, d, extra)
    local sum = d and XRay.summary(d, extra)
    if not sum or (#sum.all == 0 and #sum.timeline == 0) then return showNone(rec, path) end
    local sections = {}
    sections[#sections + 1] = { colour = "purple", plain = true, items = { { kind = "counts", list = {
        { n = #sum.people, text = _("Characters"), colour = "purple", keep = true, callback = function() showList(_("Characters"), sum.people, "purple", sum, d, extra) end },
        { n = #sum.places, text = _("Places"), colour = "teal", keep = true, callback = function() showList(_("Places"), sum.places, "teal", sum, d, extra) end },
        { n = #sum.historical, text = _("Historical"), colour = "gold", keep = true, callback = function() showList(_("Historical figures"), sum.historical, "gold", sum, d, extra) end },
        { n = #sum.terms, text = _("Terms"), colour = "blue", keep = true, callback = function() showList(_("Terms"), sum.terms, "blue", sum, d, extra) end },
        { n = #sum.timeline, text = _("Timeline"), colour = "green", keep = true, callback = function() showTimeline(sum) end },
    } } } }
    -- you and the cast
    local trio = {}
    if sum.most_looked then trio[#trio + 1] = { label = _("Most looked up"), value = sum.most_looked.name, note = T(_("%1 times"), sum.most_looked.looked) } end
    if sum.most_time then trio[#trio + 1] = { label = _("Most time with"), value = sum.most_time.name, note = durS(sum.most_time.secs) } end
    if sum.most_mentioned then trio[#trio + 1] = { label = _("Most mentioned"), value = sum.most_mentioned.name, note = T(_("%1 times"), #sum.most_mentioned.mentions) } end
    if #trio > 0 then
        local items = { { kind = "trio", list = trio } }
        local top = sum.by_time[1]
        for i = 1, math.min(2, #sum.by_time) do
            local e = sum.by_time[i]
            items[#items + 1] = { kind = "bar", frac = e.secs / top.secs, colour = e.colour }
            items[#items + 1] = { kind = "text", text = e.name .. "  " .. durS(e.secs), size = 10, dim = true }
        end
        if not sum.most_looked then
            items[#items + 1] = { kind = "text", text = _("Most looked up counts the X-Ray cards you open while reading, from now on."), size = 10, dim = true }
        end
        sections[#sections + 1] = { title = _("You and the cast"), colour = "purple", items = items }
    end
    -- people you've met
    if #sum.people > 0 then
        local rows = {}
        for i = 1, math.min(4, #sum.people) do
            local e = sum.people[i]
            local line = roleLine(e)
            rows[#rows + 1] = { text = e.name .. (line ~= "" and ("  ·  " .. line) or ""), colour = e.colour,
                note = e.first and T(_("met p. %1"), e.first) or nil, keep = true,
                callback = function() XRay.showName(e, sum, d, extra) end }
        end
        local items = { { kind = "list", list = rows } }
        if #sum.people > 4 then
            items[#items + 1] = { kind = "pills", list = { { text = T(_("+ %1 more · Show all ›"), #sum.people - 4), keep = true,
                callback = function() showList(_("Characters"), sum.people, "purple", sum, d, extra) end } } }
        end
        sections[#sections + 1] = { title = _("People you've met · tap for more"), colour = "purple", items = items }
    end
    -- where the book took you
    if #sum.places > 0 then
        local pills = {}
        for i = 1, math.min(8, #sum.places) do
            local e = sum.places[i]
            pills[#pills + 1] = { text = e.name, colour = "teal", keep = true, callback = function() XRay.showName(e, sum, d, extra) end }
        end
        sections[#sections + 1] = { title = _("Where the book took you"), colour = "teal", items = { { kind = "pills", list = pills } } }
    end
    -- the timeline: its tile at the top (it doesn't fit here as well)
    local pills = {}
    if sum.src == "xray" then pills[#pills + 1] = { text = _("Open In X-Ray"), fill = true, colour = "purple", callback = function() openXRay(path) end } end
    if #sum.terms + #sum.historical > 0 then
        local both = {}
        for _i, e in ipairs(sum.historical) do both[#both + 1] = e end
        for _i, e in ipairs(sum.terms) do both[#both + 1] = e end
        pills[#pills + 1] = { text = _("Terms & Historical ›"), keep = true, callback = function() showList(_("Terms & Historical"), both, "gold", sum, d, extra) end }
    end
    if #pills > 0 then sections[#sections + 1] = { colour = "blue", plain = true, items = { { kind = "pills", list = pills } } } end
    local sub = T(_("%1 · up to p. %2 · from %3"), tostring(rec and (rec.display_title or rec.title) or d.title or ""),
        d.page_now or "?", sum.src == "xray" and "X-Ray" or "KOAssistant")
    return O.Sheet.show{ title = _("X-Ray"), subtitle = sub, sections = sections, cancel = false }
end

return XRay
