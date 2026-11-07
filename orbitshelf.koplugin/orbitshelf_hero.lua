-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
local O = require("orbitshelf_core")
local SOURCE_ID, T, TAG, UIManager, _ = O.SOURCE_ID, O.T, O.TAG, O.UIManager, O._
local bookIdForPath, cfg, clearPageCache, downloadBookOrbitBook, getBookshelf, isWifiOn = O.bookIdForPath, O.cfg, O.clearPageCache, O.downloadBookOrbitBook, O.getBookshelf, O.isWifiOn
local lfs, liveBookPath, logger, openInBookOrbit, removeFromDevice, savePageCache = O.lfs, O.liveBookPath, O.logger, O.openInBookOrbit, O.removeFromDevice, O.savePageCache

-- ---- Hero banner actions (hold menu + inline pills) -------------------------------

-- Hero button sizes (Hero > Button Size): pill font, pill padding (top/bottom,
-- left/right), icon glyph size, icon padding, gap between pills
local BUTTON_SIZES = {
    small  = { font = 12, pv = 1, ph = 7,  icon = 11, ipad = 5,  gap = 6 },
    medium = { font = 15, pv = 3, ph = 9,  icon = 13, ipad = 7,  gap = 8 },
    large  = { font = 18, pv = 5, ph = 11, icon = 15, ipad = 9,  gap = 10 },
}
local function buttonSize()
    return BUTTON_SIZES[cfg.hero_button_size] or BUTTON_SIZES.small
end

local function bookOnDevice(book)
    if not book then return false end
    local path = book.filepath
    if type(path) == "string" and not path:match("^bookorbit://")
            and lfs.attributes(path, "mode") == "file" then
        return true
    end
    return liveBookPath(book.bookorbit_id) and true or false
end

-- A BookOrbit book once it is on the device: Bookshelf rebuilds the hero's record
-- from the file (title, description...), which drops our fields. The file tells us
-- which BookOrbit book it is, and the record gets its id back.
local function asBookOrbit(book)
    if type(book) ~= "table" then return false end
    if book.is_bookorbit or book.bookorbit_id or book.source_kind == SOURCE_ID then return true end
    local fp = book.filepath
    if type(fp) ~= "string" or fp:match("^bookorbit://") then return false end
    local id = bookIdForPath(fp)
    if not id then return false end
    book.bookorbit_id = id
    book.is_bookorbit = true
    return true
end

local function heroActionsFor(book)
    if not asBookOrbit(book) then
        return nil
    end
    if book.is_folder then return nil end
    local actions = {}
    if bookOnDevice(book) then
        actions[#actions + 1] = {
            text = _("Remove From Device"),
            callback = function() removeFromDevice(book) end,
        }
    else
        actions[#actions + 1] = {
            text = _("Download"),
            needs_wifi = true,
            callback = function() downloadBookOrbitBook(book) end,
        }
    end
    actions[#actions + 1] = {
        text = _("Open In BookOrbit"),
        callback = function() openInBookOrbit(book) end,
    }
    return actions
end

-- Sync: the saved BookOrbit lists are thrown away and pulled fresh, then BookOrbit's
-- own "sync all books" runs (it relinks books on the device and syncs progress), then
-- the shelf is redrawn again.
local sync_running = false
local function syncBookOrbit()
    if sync_running then return end
    local okT, Toast = pcall(require, "bookorbit_toast")
    local function say(msg, is_error)
        if okT and Toast then
            if is_error and Toast.error then Toast.error(msg) elseif Toast.show then Toast.show(msg) end
        else
            UIManager:show(require("ui/widget/infomessage"):new{ text = msg, timeout = 3 })
        end
    end
    local function redraw()
        local bs = getBookshelf()
        if bs and bs.sourceChanged then pcall(bs.sourceChanged, bs, SOURCE_ID) end
    end
    local function run()
        sync_running = true
        local finished = false
        local function finish(msg, is_error)
            if finished then return end
            finished = true
            sync_running = false
            pcall(function()
                local SM = require("bookorbit_state_manager")
                if type(SM.invalidate) == "function" then SM.invalidate() end
            end)
            redraw()
            say(msg, is_error)
            pcall(O.Genres.afterRefresh)
        end
        -- fresh lists first
        clearPageCache()
        savePageCache()
        redraw()

        local bo
        pcall(function()
            local FM = package.loaded["apps/filemanager/filemanager"]
            bo = type(FM) == "table" and FM.instance and FM.instance.bookorbit or nil
        end)
        local signed_in = false
        if bo and type(bo.isLoggedIn) == "function" then
            local okL, v = pcall(bo.isLoggedIn, bo)
            signed_in = okL and v and true or false
        end
        if not (bo and type(bo.startSweep) == "function" and signed_in) then
            finish(_("BookOrbit lists refreshed"))
            return
        end
        say(_("Syncing BookOrbit…"))
        -- never leave the button stuck if the sync never reports back
        UIManager:scheduleIn(300, function() finish(_("BookOrbit sync did not finish"), true) end)
        local okS, errS = pcall(bo.startSweep, bo, {
            quiet = true,
            on_done = function(err)
                if err then
                    finish(T(_("Sync stopped: %1"), tostring(err)), true)
                else
                    finish(_("BookOrbit synced"))
                end
            end,
        })
        if not okS then
            logger.warn(TAG, "sync failed:", tostring(errS))
            finish(_("Sync could not start"), true)
        end
    end
    local okN, NetworkMgr = pcall(require, "ui/network/manager")
    if okN and NetworkMgr.runWhenConnected then
        NetworkMgr:runWhenConnected(run)
    else
        run()
    end
end

-- A small round icon button (KOReader's symbols font), white with a thin border like
-- the pills. Returns the button (with getSize) or nil.
local function makeIconButton(glyph_char, on_tap)
    local ok_ic, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
    local ok_fc, FrameContainer = pcall(require, "ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local ok_iw, TextWidget = pcall(require, "ui/widget/textwidget")
    local ok_ft, Font = pcall(require, "ui/font")
    local ok_geom, Geom = pcall(require, "ui/geometry")
    local ok_gr, GestureRange = pcall(require, "ui/gesturerange")
    local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
    local ok_sc, Screen = pcall(function() return require("device").screen end)
    if not (ok_ic and ok_fc and ok_iw and ok_ft and ok_geom and ok_gr and ok_bb and ok_sc) then return nil end
    local glyph = TextWidget:new{
        text = glyph_char,
        face = Font:getFace("symbols", buttonSize().icon),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local gsz = glyph:getSize()
    local side = math.max(gsz.w, gsz.h) + Screen:scaleBySize(buttonSize().ipad)
    local frame = FrameContainer:new{
        bordersize = 1,
        padding = 0,
        margin = 0,
        radius = math.floor(side / 2),
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = side, h = side }, glyph },
    }
    local sz = frame:getSize()
    local Button = InputContainer:extend{}
    function Button:onTap()
        on_tap()
        return true
    end
    local button = Button:new{ dimen = Geom:new{ w = sz.w, h = sz.h }, frame }
    button.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = button.dimen } } }
    return button
end

local ICON_SYNC, ICON_REMOVE, ICON_ORBIT = "\u{F021}", "\u{F1F8}", "\u{F08E}"

-- The hero's own font (Bookshelf's metadata / description region face, or its
-- infofont), at our size, so the buttons and the status line match the rest of the
-- hero instead of KOReader's UI font.
local hero_face_name -- set per hero build from its regions
-- Bookshelf's Text Size setting, so our small line scales with the hero's text
local function heroScaled(size)
    local ok, BS = pcall(require, "lib/bookshelf_settings_store")
    local scale = ok and type(BS) == "table" and type(BS.read) == "function"
        and tonumber((select(2, pcall(BS.read, "font_scale")))) or 100
    return math.max(8, math.floor(size * scale / 100 + 0.5))
end
local function heroFace(size)
    local Font = require("ui/font")
    if hero_face_name then
        local ok, face = pcall(Font.getFace, Font, hero_face_name, size)
        if ok and face then return face end
    end
    local okB, BFont = pcall(require, "lib/bookshelf_fonts")
    if okB and type(BFont) == "table" and type(BFont.getFace) == "function" then
        local ok, face = pcall(BFont.getFace, BFont, "infofont", size)
        if ok and face then return face end
    end
    return Font:getFace("infofont", size)
end

local function buildHeroPills(book, width)
    -- on the device: small icons instead (heroIconsFor), so the description has room
    if bookOnDevice(book) then return nil end
    local actions = heroActionsFor(book)
    if not actions or #actions == 0 then return nil end
    local ok_ic, InputContainer = pcall(require, "ui/widget/container/inputcontainer")
    local ok_hg, HorizontalGroup = pcall(require, "ui/widget/horizontalgroup")
    local ok_tw, TextWidget = pcall(require, "ui/widget/textwidget")
    local ok_fc, FrameContainer = pcall(require, "ui/widget/container/framecontainer")
    local ok_geom, Geom = pcall(require, "ui/geometry")
    local ok_gr, GestureRange = pcall(require, "ui/gesturerange")
    local ok_hs, HorizontalSpan = pcall(require, "ui/widget/horizontalspan")
    local ok_bb, Blitbuffer = pcall(require, "ffi/blitbuffer")
    if not (ok_ic and ok_hg and ok_tw and ok_fc and ok_geom and ok_gr) then
        return nil
    end
    -- small and thin, so the description keeps its room
    local size = buttonSize()
    local face = heroFace(size.font)
    local Screen = require("device").screen
    local gap = Screen:scaleBySize(size.gap)
    local row = HorizontalGroup:new{ align = "center" }
    local pad = Screen:scaleBySize(size.ph)
    -- Labels at their own width; only when they don't all fit does the widest one
    -- give up the difference (it used to be an equal share each, so "Open In
    -- BookOrbit" was cut even with room to spare next to a short "Download").
    -- Text is centred on its capitals, not on the font's line box (which keeps
    -- room for descenders below and sat the words a little high).
    local labels, widths, total = {}, {}, 0
    for i, a in ipairs(actions) do
        -- Wi-Fi off: Download looks dimmed (a tap still offers to turn Wi-Fi on)
        local dim = a.needs_wifi and ok_bb and not isWifiOn()
        labels[i] = TextWidget:new{
            text = a.text,
            face = face,
            padding = 0,
            fgcolor = dim and Blitbuffer.gray(0.45) or nil,
        }
        labels[i].dim = dim
        widths[i] = labels[i]:getSize().w
        total = total + widths[i]
    end
    local avail = (width or 200) - gap * (#actions - 1) - #actions * (2 * pad + 2)
    if total > avail then
        local widest = 1
        for i = 2, #widths do if widths[i] > widths[widest] then widest = i end end
        labels[widest]:setMaxWidth(math.max(Screen:scaleBySize(24), widths[widest] - (total - avail)))
    end
    for i, a in ipairs(actions) do
        if i > 1 and ok_hs then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
        end
        local label, dim = labels[i], labels[i].dim
        local lh = label:getSize().h
        local fsize = tonumber(face and face.size) or lh / 1.4
        label.forced_height = lh
        label.forced_baseline = math.floor((lh + 0.7 * fsize) / 2 + 0.5)
        local frame = FrameContainer:new{
            bordersize = 1,
            color = dim and Blitbuffer.gray(0.45) or nil,
            padding = 0,
            padding_left = pad,
            padding_right = pad,
            padding_top = Screen:scaleBySize(size.pv),
            padding_bottom = Screen:scaleBySize(size.pv),
            margin = 0,
            background = ok_bb and Blitbuffer.COLOR_WHITE or nil,
            radius = Screen:scaleBySize(7),
            label,
        }
        local sz = frame:getSize()
        local Pill = InputContainer:extend{}
        function Pill:onTap()
            a.callback()
            return true
        end
        local pill = Pill:new{
            dimen = Geom:new{ w = sz.w, h = sz.h },
            frame,
        }
        pill.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = pill.dimen,
                },
            },
        }
        row[#row + 1] = pill
    end
    return row
end

-- The small icons at the bottom right of the hero's right column: for a book on the
-- device Remove From Device and Open In BookOrbit, and Sync for any BookOrbit book.
local function heroIconsFor(book)
    local icons = {}
    if cfg.hero_pills and bookOnDevice(book) then
        icons[#icons + 1] = makeIconButton(ICON_REMOVE, function() removeFromDevice(book) end)
        icons[#icons + 1] = makeIconButton(ICON_ORBIT, function() openInBookOrbit(book) end)
    end
    if cfg.hero_sync then
        icons[#icons + 1] = makeIconButton(ICON_SYNC, syncBookOrbit)
    end
    if #icons == 0 then return nil end
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local gap = require("device").screen:scaleBySize(8)
    local row = HorizontalGroup:new{ align = "center" }
    for i, w in ipairs(icons) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = w
    end
    return row
end

local function Screen_gap()
    local ok, v = pcall(function() return require("device").screen:scaleBySize(12) end)
    return ok and v or 12
end

local function hookHero()
    local ok, HeroCard = pcall(require, "lib/bookshelf_hero_card")
    if not ok or type(HeroCard) ~= "table" then return end
    if HeroCard._orbitshelf_hooked then return end
    HeroCard._orbitshelf_hooked = true

    -- Hold menu
    O.remember(HeroCard, "onHold")
    local orig_hold = HeroCard.onHold
    if type(orig_hold) == "function" then
        HeroCard.onHold = function(self, ...)
            local book = self.book
            local extra = heroActionsFor(book)
            if extra and #extra > 0 then
                local ButtonDialog = require("ui/widget/buttondialog")
                local dlg
                local rows = {}
                for _i, a in ipairs(extra) do
                    rows[#rows + 1] = {{ text = a.text, callback = function()
                        UIManager:close(dlg)
                        a.callback()
                    end }}
                end
                -- a book not on the device: its description too
                if not bookOnDevice(book) then
                    rows[#rows + 1] = {{ text = _("Book Description"), callback = function()
                        UIManager:close(dlg)
                        O.showDescription(book)
                    end }}
                end
                if O.canAddToCollection(book) then
                    rows[#rows + 1] = {{ text = _("Add To Collection"), callback = function()
                        UIManager:close(dlg)
                        O.addToCollection(book)
                    end }}
                end
                rows[#rows + 1] = {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }}
                dlg = ButtonDialog:new{ title = book.title or _("Book"), buttons = rows }
                UIManager:show(dlg)
                if O.cfg.flash_hold_menu then O.flashPopup(dlg) end
                return true
            end
            if orig_hold then return orig_hold(self, ...) end
        end
    end

    -- One row at the bottom of the hero's right column: text pills on the left (a book
    -- not on the device), small icons on the right (Remove, BookOrbit, Sync). The column
    -- is built that much shorter so the row sits inside the card (not under the tab
    -- bar), and all go in one OverlapGroup.
    if type(HeroCard._buildRightColumn) == "function" then
        O.remember(HeroCard, "_buildRightColumn")
        local orig_col = HeroCard._buildRightColumn
        HeroCard._buildRightColumn = function(self, book, regions, state, dimen, ...)
            do
                local r = type(regions) == "table" and (regions.metadata or regions.description or regions.author)
                hero_face_name = type(r) == "table" and type(r.font_face) == "string" and r.font_face ~= ""
                    and r.font_face or nil
            end
            if not asBookOrbit(book) then return orig_col(self, book, regions, state, dimen, ...) end

            local okG, Geom = pcall(require, "ui/geometry")
            local okO, OverlapGroup = pcall(require, "ui/widget/overlapgroup")
            local have_dimen = okG and okO and type(dimen) == "table" and dimen.w and dimen.h

            local pills, icons
            if not book.is_folder then
                local okI, row = pcall(heroIconsFor, book)
                icons = okI and row or nil
                local icons_w = 0
                if icons then
                    local okS, isz = pcall(icons.getSize, icons)
                    icons_w = okS and isz and isz.w or 0
                end
                if cfg.hero_pills then
                    -- the text pills share the bottom row with the icons, to their left
                    local w = ((dimen and dimen.w) or self.width or 200) - (icons_w > 0 and icons_w + 12 or 0)
                    pills = buildHeroPills(book, math.max(60, w))
                end
            end

            -- no size to work with: the old way, pills stacked under the column
            if not have_dimen then
                local column = orig_col(self, book, regions, state, dimen, ...)
                if not pills and not icons then return column end
                local ok_vg, VerticalGroup = pcall(require, "ui/widget/verticalgroup")
                local ok_vs, VerticalSpan = pcall(require, "ui/widget/verticalspan")
                if not ok_vg then return column end
                local vg = VerticalGroup:new{ align = "left" }
                if column then vg[#vg + 1] = column end
                if ok_vs then vg[#vg + 1] = VerticalSpan:new{ width = 6 } end
                if pills then vg[#vg + 1] = pills end
                if icons then vg[#vg + 1] = icons end
                return vg
            end

            -- one row at the bottom: text pills on the left, icons on the right; the
            -- column is built that much shorter, so nothing overlaps
            local function sizeOf(w)
                if not w then return nil end
                local okS, sz = pcall(w.getSize, w)
                return okS and sz or nil
            end
            local psz, isz = sizeOf(pills), sizeOf(icons)
            -- the hero's own font for what we add (see heroFace)
            local row_h = math.max(psz and psz.h or 0, isz and isz.h or 0)
            -- Offline Library: a small line for a book not on the device, at the top
            -- right next to the rating stars (over the buttons when there's no room)
            local status, ssz
            if cfg.offline_library and not book.is_folder and not bookOnDevice(book) then
                pcall(function()
                    local TextWidget = require("ui/widget/textwidget")
                    local Blitbuffer = require("ffi/blitbuffer")
                    status = TextWidget:new{
                        text = book.bookorbit_saved and _("Not On Device · Saved Offline") or _("Not On Device"),
                        face = heroFace(heroScaled(12)),
                        fgcolor = Blitbuffer.gray(0.6),
                        max_width = dimen.w,
                    }
                end)
                ssz = sizeOf(status)
                if not ssz then status = nil end
            end
            local rest = { ... }
            local function build(extra_h)
                local used = (row_h > 0 and row_h + 4 or 0) + (extra_h or 0)
                local cd = dimen
                if used > 0 then
                    cd = Geom:new{ w = dimen.w, h = math.max(math.floor(dimen.h / 2), dimen.h - used) }
                end
                if not cfg.diagnostics then
                    return orig_col(self, book, regions, state, cd, unpack(rest))
                end
                -- Diagnostics: how much of the hero's time is Bookshelf's own build
                local okT, time = pcall(require, "ui/time")
                local function ms() return okT and time.now and time.to_ms(time.now()) or os.clock() * 1000 end
                local t0 = ms()
                local col = orig_col(self, book, regions, state, cd, unpack(rest))
                O.hero_bookshelf_ms = (O.hero_bookshelf_ms or 0) + (ms() - t0)
                return col
            end
            local column = build(0)
            -- where the stars row is: under the status strip, first in the column's top
            local function starSpot()
                local okS, spot = pcall(function()
                    local top = column[1][1][1] -- FrameContainer > OverlapGroup > TopContainer > right_top
                    local strip = type(self._status_strip_widgets) == "table" and self._status_strip_widgets or {}
                    local y = 0
                    for _i, w in ipairs(strip) do y = y + (w:getSize().h or 0) end
                    -- only when Bookshelf draws its rating row there (the hero's Rating
                    -- region on); otherwise that first row is the title
                    local rr = type(regions) == "table" and regions.rating
                    if not (rr and not book.is_remote) then return nil end
                    -- Bookshelf draws it for tappable stars (Rating on) or Hardcover stars
                    if not ((not rr.disabled and self.on_rating_change ~= nil) or book.hardcover_rating ~= nil) then
                        return nil
                    end
                    local stars = top[#strip + 1]
                    if not stars then return nil end
                    local st = stars:getSize()
                    if not (st and st.w + ssz.w + Screen_gap() <= dimen.w and st.h <= ssz.h * 2) then return nil end
                    -- a little in from the right edge, so it doesn't touch the frame
                    local inset = math.floor(Screen_gap() / 2)
                    return { x = math.max(0, dimen.w - ssz.w - inset),
                        y = y + math.max(0, math.floor((st.h - ssz.h) / 2)) }
                end)
                return okS and spot or nil
            end
            local extras = {}
            if status and ssz then
                local spot = starSpot()
                if spot then
                    status.overlap_offset = { spot.x, spot.y }
                else
                    -- no rating row (list view, or Rating off): right-aligned just over the
                    -- buttons, the column built that much shorter so nothing overlaps
                    column = build(ssz.h + 4)
                    local inset = math.floor(Screen_gap() / 2)
                    status.overlap_offset = { math.max(0, dimen.w - ssz.w - inset),
                        math.max(0, dimen.h - (row_h > 0 and row_h + 4 or 0) - ssz.h) }
                end
                extras[#extras + 1] = status
            end
            if pills and psz then
                pills.overlap_offset = { 0, math.max(0, dimen.h - row_h + math.floor((row_h - psz.h) / 2)) }
                extras[#extras + 1] = pills
            end
            if icons and isz then
                -- OverlapGroup ignores the offset when a child is aligned "right"
                icons.overlap_offset = { math.max(0, dimen.w - isz.w),
                    math.max(0, dimen.h - row_h + math.floor((row_h - isz.h) / 2)) }
                extras[#extras + 1] = icons
            end
            if #extras == 0 then return column end
            local group = OverlapGroup:new{ dimen = Geom:new{ w = dimen.w, h = dimen.h } }
            if column then group[#group + 1] = column end
            for _i, w in ipairs(extras) do group[#group + 1] = w end
            return group
        end
    end
end


-- ---- Flash (clears e-ink ghosting) ---------------------------------------------------
-- Bookshelf redraws the hero and the shelf rows in "ui" mode, which never flashes, so a
-- new cover can show the old one faintly behind it. Flash Hero: the hero's own rect gets
-- a flash when it shows another book (not on the clock tick). Flash Shelf: every page
-- turn is a full refresh (Bookshelf's own "Use E-ink refresh rate for shelf pages" only
-- flashes as often as KOReader's Full refresh rate). Both off by default: a flash takes
-- a moment and a little battery.
local function hookFlash()
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" or BW._orbitshelf_flash then return end
    BW._orbitshelf_flash = true
    O.remember(BW, "_swapHeroInPlace")
    local orig_swap = BW._swapHeroInPlace
    if type(orig_swap) == "function" then
        local swaps = 0
        BW._swapHeroInPlace = function(self, ...)
            local scope
            -- every Nth change (Hero > Flash): the others stay quick partial refreshes
            local every = math.max(1, tonumber(cfg.flash_hero_every) or 1)
            if cfg.flash_hero then swaps = swaps + 1 end
            if cfg.flash_hero and swaps % every == 0 then
                pcall(function()
                    local old = self._hero_parent and self._hero_parent[1]
                    local d = old and old.dimen
                    if d and d.w and d.w > 0 then
                        scope = require("ui/geometry"):new{ x = d.x, y = d.y, w = d.w, h = d.h }
                    end
                end)
            end
            local r = { orig_swap(self, ...) }
            if scope then
                UIManager:setDirty(self, function() return "flashui", scope, self.dithered end)
            end
            return unpack(r)
        end
    end
    O.remember(BW, "_pageTurnFlashDue")
    local orig_due = BW._pageTurnFlashDue
    if type(orig_due) == "function" then
        BW._pageTurnFlashDue = function(...)
            if cfg.flash_shelf then
                local Device = require("device")
                if Device.hasEinkScreen and Device:hasEinkScreen() then return true end
            end
            return orig_due(...)
        end
    end
end

-- ---- Flash: Bookshelf's own popups ------------------------------------------------------
-- Bookshelf's book menu (hold a book on the device) and its shelf editor (hold a shelf
-- tab) flash when they open and close, each with its own Flash setting. Hooked only once
-- one of them is turned on, so Bookshelf is untouched otherwise.
local function hookPopupFlash()
    if not (cfg.flash_book_menu or cfg.flash_shelf_editor) then return true end
    local okW, BW = pcall(require, "lib/bookshelf_widget")
    if okW and type(BW) == "table" and type(BW._showBookDetail) == "function" and not BW._orbitshelf_flash_detail then
        BW._orbitshelf_flash_detail = true
        O.remember(BW, "_showBookDetail")
        local orig = BW._showBookDetail
        BW._showBookDetail = function(...)
            return O.flashShownBy("flash_book_menu", orig, ...)
        end
    end
    local okE, Editor = pcall(require, "lib/bookshelf_chip_editor")
    if okE and type(Editor) == "table" and type(Editor.editTab) == "function" and not Editor._orbitshelf_flash_edit then
        Editor._orbitshelf_flash_edit = true
        O.remember(Editor, "editTab")
        local orig = Editor.editTab
        Editor.editTab = function(...)
            return O.flashShownBy("flash_shelf_editor", orig, ...)
        end
    end
    O.arm()
    return true
end

-- shared with the other files
O.hookPopupFlash = hookPopupFlash
O.hookFlash = hookFlash
O.hookHero = hookHero
return O
