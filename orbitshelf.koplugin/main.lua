--[[
orbitshelf.koplugin  ·  OrbitShelf
BookOrbit shelves inside Bookshelf (AndyHazz/bookshelf.koplugin).

Version: 1.2.4

Requires:
  * bookshelf.koplugin (SOURCE_API >= 1; best with Bookshelf 6.x)
  * bookorbit.koplugin signed in (server_url + username + userkey)

What it does
  * Toggle **Use BookOrbit In Bookshelf**. Registers a **BookOrbit** fetch-mode
    shelf source (books not on device included).
  * Source modes: Library, Recently added, Recently read, **Series**,
    **Authors**, **Genres**, and **Collections** (fetched from BookOrbit when
    Wi-Fi is on, the saved list otherwise). Series/Authors/Genres are folder
    drills (tap a group → its books), ordered the way Bookshelf orders its own
    Series / Authors / Genres stacks.
  * Toggle **Rewrite Stock Series/Author/Genre**: points the built-in Series,
    Authors, Genres, Recent and Latest chips at BookOrbit (restored when off).
  * Covers: shared cache/bookorbit/ folder with Side Panel; Clean Up Cache
    matches Reading Log Tweaks.
  * Hero: hold menu and, at the bottom of the banner, **Download / Open In
    BookOrbit** pills for a BookOrbit book not on the device; small round icons
    (Remove From Device, Open In BookOrbit, Sync) at the bottom right for one
    that is, so its description keeps the room.
  * Toggle **Close Only (No Hamburger)**: the footer hamburger is replaced by a
    plain close X. One tap closes Bookshelf, no menu in between. Placement is
    still left, right or Bookshelf's side (Close Control). Gesture / keyboard
    "open start menu" closes the shelf too while this is on.
  * Toggle **Footer Critter**: replaces the bottom page nav with your SimpleUI
    Tiny Critter (same critters as Quick Shelf / Reading Log). The bubble always
    carries where you are (page, pages, shelf) and says one of four things,
    moving to the next kind on every tap or page turn:
      Page    - "Page 3 of 9", "Books 25-36 of 104".
      Witty   - short remarks that know the page, shelf size and time of day.
      Picks   - recommendations from the books on this page: one to get back to,
                one nearly finished, the next in a series, two by one author.
      Sayings - original one-liners about books and shelves; add your own in
                koreader/settings/orbitshelf-quotes.txt (one per line, or
                `quote | author`).
    Each kind has its own switch (at least one stays on). Left/right edges
    still page; swipe still pages.

  * **Genres**: BookOrbit's lists carry no genres, so they are built once from each
    book's BookOrbit page (genres + tags), in the background, after a Start / Later
    question the first time the Genres shelf opens. Books on the device use their
    file's own genres. Wi-Fi off pauses it; it carries on when Wi-Fi is back.
    Shelf > Build Genres / Rebuild Genres.
  * **Flash** (both off by default): Hero > Flash When It Changes flashes the hero
    clean when it shows another book; Shelf > Flash On Every Page Turn makes every
    shelf page turn a full refresh. Both clear e-ink ghosting.
  * **Offline Library** (off by default): every BookOrbit book's cover and details
    (description, pages, published, language, genres) saved on the device, so the
    whole library shows with Wi-Fi off. Books themselves are not downloaded: those
    still show Download (dimmed with Wi-Fi off) and the hero says Not On Device ·
    Saved Offline at the top right, next to the rating stars. Built in the background with Wi-Fi on, new books added when
    Wi-Fi comes on. Details in koreader/orbitshelf-library.txt, covers in the shared
    cover folder. Offline Library > Keep Library Offline / Update Now / Delete.

Settings: Tools → OrbitShelf (or Add-ons with 2-tweaks-menu.lua):
  Use BookOrbit In Bookshelf, Rewrite Stock Series / Authors / Genres, then
  Hero, Shelf, Offline Library and Footer sub-menus, and Clean Up Cache at the end.

Problems go to crash.log, tagged "orbitshelf 1.2.4:". At start it writes the
KOReader version, the device, the Bookshelf / BookOrbit / SimpleUI versions and every
patch and plugin present. When another patch or plugin changed a Bookshelf function
OrbitShelf hooks (hero, close X, footer, flash), or replaced the BookOrbit shelf
source, the line names that file. A part that fails writes its error and where it
happened, once per start, and Bookshelf's own version runs instead.

Install: copy the orbitshelf.koplugin folder into koreader/plugins/ and restart.
Everything is off on a new install: Bookshelf stays as it is until you turn things
on in Tools > OrbitShelf (start with Use BookOrbit In Bookshelf).
Coming from the patch: delete koreader/patches/2-orbitshelf-tweaks.lua first. While
the old patch is there it runs and the plugin stays off (crash.log says so). Settings,
genres, saved lists, the offline library and covers carry over as they are.

Files: main.lua (start-up, menu, Wi-Fi and sleep), orbitshelf_core.lua (settings,
crash.log), orbitshelf_bookorbit.lua (BookOrbit lists, covers, offline details,
download / remove), orbitshelf_genres.lua (background lookups), orbitshelf_source.lua
(the Bookshelf source and its shelves), orbitshelf_hero.lua (hero buttons, flash),
orbitshelf_footer.lua (critter, close X), orbitshelf_menu.lua (settings menu),
orbitshelf_diag.lua (Diagnostics, loaded only while it's on).

Changelog:
  1.2.4  2026-11-05  Offline Library > Check For New Books: On Wi-Fi Connect (default, as
                     before: at start and each Wi-Fi connect), On Refresh / Sync (the hero's
                     Sync button or a swipe-down refresh on a BookOrbit shelf, with the
                     library list pulled fresh), Both, or Update Now Only. A run cut short
                     by Wi-Fi going off always finishes when it's back. README.md in the
                     plugin folder.
  1.2.3  2026-11-05  Fix: scrolling a long Book Description crashed KOReader (the scrolling
                     text had no window to refresh through). Fix: Genres / Offline Library
                     lookups froze the screen. The background worker was only used when
                     BookOrbit's own background_requests flag was on, which BookOrbit
                     leaves off, so every lookup ran on the screen's thread (since the
                     patch's 1.6.0; 1.5.10 did one book per tick). Now the worker is
                     always used when KOReader can fork (Kobo, Kindle, PocketBook); where
                     it can't, one book at a time with a turn for the screen in between.
                     Book Description's lookup uses the worker too. _meta.lua no longer
                     has the deprecated name line (KOReader warned about it).
  1.2.2  2026-11-05  Faster background lookups (Genres, Offline Library): 3 batches at once,
                     each in its own worker, and the next starts as soon as one lands (no
                     gap); about 3x faster on a full run. The shelf and the progress note
                     update at most every 15 seconds while it runs, and once at the end,
                     instead of after every batch. Diagnostics turned on after start now
                     time the BookOrbit shelf loads too; the cover hit / miss counters
                     that never counted are gone from its lines.
  1.2.1  2026-11-05  Hero > Button Size: Small (default, as before) / Medium / Large for the
                     Download / Open In BookOrbit buttons and the round icons.
  1.2.0  2026-11-05  Book Description: holding (or tapping) a book that isn't on the device
                     now also offers Book Description. It opens a compact window sized to
                     the description (scrolls only past about 70% of the screen), closed
                     by its X or a tap outside it. Uses the saved description (Offline
                     Library) or looks it up once in the background; HTML in it is turned
                     into plain text.
  1.1.1  2026-11-05  Diagnostics write to crash.log (tagged "orbitshelf 1.1.1 diag:")
                     instead of diagnostics.log, which stays for the patches and the
                     Debugging Menu.
  1.1.0  2026-11-05  Diagnostics moved into the plugin: Tools > OrbitShelf > Diagnostics
                     (off by default). Same [orbitshelf] lines in koreader/diagnostics.log,
                     30 minutes after each start or after turning it on; turns itself off
                     after 3 days. Only loaded while it's on. The diagnostics patch
                     (2-zz-orbitshelf-tweaks-diagnostics.lua) is retired; if the old one is
                     still installed it keeps logging and the plugin's stays off.
  1.0.1  2026-11-05  Everything off by default on a new install (BookOrbit source, Rewrite
                     Stock chips, hero buttons, Sync, footer critter), so Bookshelf stays
                     as it is until you turn things on. Saved settings are untouched; if
                     you used the patch without ever changing a setting, you keep what
                     the patch had on (and it's saved now).
  1.0.0  2026-11-05  OrbitShelf Tweaks 1.6.1 as a plugin. Same features and settings.
                     Split into files, all well under 128 KB. Problems go to crash.log
                     (see above), including which other patch or plugin changed what
                     OrbitShelf relies on. Wi-Fi back and sleep come to the plugin
                     directly. The old patch's history is in its own changelog (1.0.0
                     to 1.6.1, 2026-10-31 to 2026-11-05).
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local O = require("orbitshelf_core")
-- this plugin's folder (diagnostics is loaded from it later, only while it's on)
O.dir = (debug.getinfo(1, "S").source or ""):match("^@(.+)/[^/]+$")

local OrbitShelf = WidgetContainer:extend{
    name = "orbitshelf",
    is_doc_only = false,
}

-- the old patch is running: stay off (crash.log already says why)
if O.idle then return OrbitShelf end

require("orbitshelf_bookorbit")
require("orbitshelf_genres")
require("orbitshelf_source")
require("orbitshelf_hero")
require("orbitshelf_footer")
require("orbitshelf_menu")

local UIManager, logger, TAG, cfg = O.UIManager, O.logger, O.TAG, O.cfg

-- one start-up step; a failure is written to crash.log with where it happened
local function step(label, fn, ...)
    local args = { n = select("#", ...), ... }
    local ok, err = xpcall(function() return fn(unpack(args, 1, args.n)) end, debug.traceback)
    if not ok then O.problem("boot:" .. label, label .. " failed at start:", err) end
end

local function boot()
    O.environment()
    if cfg.use_bookorbit and O.bookOrbitInstalled() then
        if not O.registerSource() then
            -- Bookshelf may not be ready yet
            UIManager:nextTick(function() step("BookOrbit source", O.registerSource) end)
            UIManager:scheduleIn(1, function() step("BookOrbit source", O.registerSource) end)
            UIManager:scheduleIn(3, function()
                step("BookOrbit source", O.registerSource)
                if cfg.use_bookorbit and not O.spec then
                    O.problem("nosource", "BookOrbit source not registered: Bookshelf missing, too old (needs source API 1), or turned off")
                end
            end)
        end
    elseif cfg.use_bookorbit then
        O.problem("nobo", "BookOrbit plugin not found: BookOrbit shelves are off")
    end
    step("hero", O.hookHero)
    step("flash", O.hookFlash)
    -- Offline Library: new books since last time, quietly, once shortly after start
    if cfg.offline_library and O.Genres.autoOn("wifi") then
        UIManager:scheduleIn(20, function()
            if O.isWifiOn() then step("Offline Library", O.Genres.build, true) end
        end)
    end
    step("Remove From Device button", O.registerFileDialogButton)
    step("close-only menu", O.hookCloseOnlyMenu)
    step("footer critter", O.hookFooterCritter)
    step("rewrite stock chips", O.applyAutoRewrite)
    O.arm()
    if cfg.diagnostics then step("diagnostics", O.startDiag) end
end

local booted = false

function OrbitShelf:init()
    if not booted then
        booted = true
        UIManager:nextTick(function() step("start-up", boot) end)
        logger.info(TAG, "loaded (plugin)")
    end
    -- the file manager's menu (Tools, unless the Add-ons patch shows it)
    if self.ui and self.ui.menu and not self.ui.document then
        self.ui.menu:registerToMainMenu(self)
    end
end

function OrbitShelf:addToMainMenu(menu_items)
    step("menu", O.addMainMenu, menu_items)
end

-- Wi-Fi back: a paused Genres / Offline Library run carries on, new books are added
function OrbitShelf:onNetworkConnected()
    step("Wi-Fi back", O.Genres.onWifi)
end

-- going to sleep: the background lookups stop (they carry on when Wi-Fi is back)
function OrbitShelf:onSuspend()
    if O.Genres.running then step("sleep", O.Genres.stop, true) end
end

return OrbitShelf
