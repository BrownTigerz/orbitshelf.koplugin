--[[
orbitshelf.koplugin  ·  OrbitShelf
BookOrbit shelves inside Bookshelf (AndyHazz/bookshelf.koplugin).

Version: 1.2.26

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

Problems go to crash.log, tagged "orbitshelf 1.2.26:". At start it writes the
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
orbitshelf_footer.lua (critter, close X, Home button), orbitshelf_menu.lua (settings menu),
orbitshelf_collections.lua (Add To Collection), orbitshelf_bulk.lua (Bulk Download / Remove),
orbitshelf_extras.lua (Reading Status, Next In Series, Not On Device mark),
orbitshelf_diag.lua (Diagnostics, loaded only while it's on).

Changelog:
  1.2.26 2026-11-11  Shelf > Mark Style for the Not On Device mark: Auto (the default)
                     draws it black on a light cover corner and white on a dark one, with
                     a thin outline in the other colour so it reads on a busy corner too;
                     Badge puts it on a small round disc in Bookshelf's badge colours, like
                     its page-count pill. Night mode keeps the contrast either way.
  1.2.25 2026-11-11  Two new options, both off by default:
                     Shelf > Mark Books Not On Device: BookOrbit's download mark (the Side
                     Panel's) on the bottom-left of a BookOrbit cover whose book isn't on
                     the device; books on the device stay as they are. The page count
                     keeps the bottom-right. Covers view only; it follows Bookshelf's Cover
                     badge size. A book with Bookshelf's reading mark or progress bar
                     (they start bottom-left too) gets it just above them. A download or a
                     removal shows on the next redraw. A book is known by its bookorbit://
                     address, which Bookshelf keeps when it rebuilds the record; turning the
                     option on or off redraws every cover (Bookshelf's kept pages are
                     dropped). With Diagnostics on, the first covers it decides on are
                     logged.
                     Footer > Home Button: a house in the footer corner opposite the close
                     X / hamburger, back to page 1. Home Goes To: This Shelf (page 1 of
                     whichever shelf you're on) or a shelf you pick (always its page 1).
                     Inside a folder or group it comes back out to the shelf; already there,
                     nothing redraws. Not shown while selecting books, or when Bookshelf's
                     full-screen grid button has that corner.
  1.2.24 2026-11-10  New Extras menu, every option off by default:
                     Bulk Download: hold a book that isn't on the device (or the hero),
                     Bulk Download… lists that shelf's books not on the device, the held
                     one ticked; Select… ticks All, Same Series, Same Author or None. A
                     size and free-space check comes first (too big: says so and stops),
                     then they download one at a time ("Downloading 3 of 12"), the shelf
                     redraws once at the end and a popup lists any that failed. The row
                     reads Stop Bulk Download while it runs. Wi-Fi off stops it (popup);
                     sleep pauses it and waking asks whether to continue.
                     Bulk Remove: the same list for the shelf's books on the device (from
                     the hero or Bookshelf's book menu), one question, then removed; they
                     stay in BookOrbit.
                     Reading Status: Want To Read / Reading / On Hold / Read / Abandoned /
                     Unread, set in BookOrbit from the hold menus and the book menu.
                     Next In Series: finishing a BookOrbit book remembers the next one in
                     its series when it isn't on the device; back on the home screen one
                     question offers to download it (nothing pops up in the book).
                   Shelf editor: Show All Books, On Device or Not On Device. A book
                   moves between those shelves when it's downloaded or removed (a
                   bulk download moves them all at the end).
                   Downloads of 1.5 MB+ show their % in the corner note.
                   Fix: OrbitShelf's BookOrbit calls now carry the device id, model
                   and plugin version (BookOrbit's own settings when it's loaded), so
                   the link after a download (match-check) works; the server answered
                   400 without them and the book wasn't linked for syncing.
                   Bulk Download's size check asks BookOrbit's bulk manifest (100
                   books a call) instead of one call a book, and the Download row
                   reads "Checking sizes…" meanwhile, so a second tap can't ask twice.
                   Next In Series also asks when the book closes to Bookshelf (or
                   anything full screen), and stays on top if Bookshelf or the home
                   screen opens over it.
  1.2.23 2026-11-07  Spines: Series, Authors and Genres (and Group By shelves) stand as runs
                     of their books' spines under each group's name, like Bookshelf's own
                     Series shelf, instead of one face-out tile per group. Covers view is
                     unchanged: groups are still folders there.
  1.2.22 2026-11-07  Spines for BookOrbit shelves, with a Bookshelf that offers them for
                     fetch-mode sources (6.4, or its feat-588 test branch). Covers colour
                     the spines, page counts set their thickness; folders stand face-out.
  1.2.21 2026-11-07  Footer critter stands on SimpleUI 3.0.3's ground shadow, like the home
                     screen's.
  1.2.20 2026-11-06  Genres / Offline Library look books up two batches at a time (was three):
                     about the same speed, less battery.
  1.2.19 2026-11-06  A new BookOrbit shelf is named after its list (Authors, Recently added,
                     the collection's name …) instead of "BookOrbit", and the name follows
                     when you change the list, as long as you haven't typed your own. Flash
                     for popups now flashes only the popup's box, not the whole screen.
  1.2.18 2026-11-06  The BookOrbit source goes straight into Bookshelf's source list at
                     start-up, without waiting for Bookshelf's window (older Bookshelf: as
                     before). Background results keep every digit of a number, and a NaN or
                     infinity no longer loses the whole result. The offline file is tidied
                     after any run, not only after Offline Library. Diagnostics says how
                     the source was registered.
  1.2.17 2026-11-06  Covers download in OrbitShelf's background worker (BookOrbit's
                     runInSubprocess ran them on the screen's thread: a few seconds' freeze
                     per batch of new covers). Saved lists moved from KOReader's settings to
                     koreader/orbitshelf-lists.lua, written only when changed, when KOReader
                     saves its settings; moved over once. A background refresh that finds
                     the same list only updates its age. Worker checks every 0.5 s for the
                     first 2 s, then every second. A shelf refresh, download or cover fetch
                     cut off by sleep no longer stays blocked until a restart.
  1.2.16 2026-11-06  New Flash menu with every flash option, each off by default: Hero When
                     It Changes (and how often), Shelf Page Turns (both moved from Hero and
                     Shelf, settings kept), and new ones that flash a popup when it opens
                     and closes: Book Description, Hold Menu (BookOrbit books), Download
                     Window, Bookshelf's Book Menu, Shelf Editor. Bookshelf's two are
                     hooked only once turned on.
  1.2.15 2026-11-06  Add To Collection: "Signing in…" and "Loading your collections…" show
                     as a plain KOReader message. BookOrbit's loading pill (tinted by
                     BookOrbit Tweaks' Pill Colour) stayed on the shelf as a blank bar
                     until the shelf redrew; 1.2.14's extra refresh didn't clear it and
                     is gone. Same as BookOrbit Tweaks 2.15.10.
  1.2.14 2026-11-06  Add To Collection: after typing the password, the collection list does
                     one clean refresh, so no blank pill is left at the bottom of the
                     screen. Same fix as BookOrbit Tweaks 2.15.9.
  1.2.13 2026-11-06  Menu: Return To (the shelf Bookshelf shows when it opens or a book
                     closes: Bookshelf's Choice, the default, or one you pick), then
                     Add To Collection, Offline Library, Hero, Shelf, Footer.
                     Hero buttons: text centred on its capitals, and a long label is only
                     shortened when the row doesn't fit (it used to get an equal share).
  1.2.12 2026-11-06  Add To Collection (setting, off by default): in the hero's hold menu
                     and the Not On Device window. Signs in like the BookOrbit website,
                     with the same messages, notice and saved password (encrypted) as
                     BookOrbit Tweaks, and the same files, so the two share one login.
                     With BookOrbit Tweaks 2.15.8 or newer installed, its picker opens.
  1.2.11 2026-11-06  Hero: the pills and the status line use the hero's own font (they were
                     in the UI serif). The status line sits next to the stars only when
                     the hero has a rating row; otherwise (list view) it sits right-
                     aligned just above the buttons, inset from the frame edge.
                     Cleanup: dead code, unused locals and duplicate helpers removed
                     (Diagnostics uses the plugin's own checks); no change in behaviour.
  1.2.10 2026-11-06  Hero > Flash: Every Change / Every 4th / Every 6th (with Flash When It
                     Changes on; Every Change, as before, by default), so most taps skip the
                     slow full flash. A saved list over 30 minutes old shows at once and is
                     refreshed in the background worker, redrawing the shelf only if it
                     changed (it used to wait about 1 s on the network). Diagnostics count
                     the saved lists under the right settings key (it always said 0).
  1.2.9  2026-11-06  Corner notes fit on one line: shorter wording, and anything over about
                     45 characters is cut with an ellipsis (the Group By note ran off the
                     screen). Diagnostics time a tap on a book: the whole hero swap, and
                     the hero column split into Bookshelf's own build and OrbitShelf's part
                     (first 15, then slow ones), to find where taps feel sluggish.
  1.2.8  2026-11-06  Group By (shelf editor, off by default): a Library, Collection or Smart
                     Scope shelf can show its own books as Series, Authors or Genres
                     folders (only that list's books, ordered like the main Series /
                     Authors / Genres shelves). None keeps the flat A to Z list. Changing
                     List to a whole-library mode clears it.
  1.2.7  2026-11-06  Libraries: each BookOrbit library can be its own shelf (Library: <name>,
                     in the shelf picker and the editor's List row), so a library per genre
                     becomes a shelf per genre; saved for when Wi-Fi is off. Picking a
                     library, collection or smart scope clears the others.
  1.2.6  2026-11-06  Smart Scopes: BookOrbit's smart scopes can be a shelf, picked like a
                     collection (Smart Scope: <name>, in the shelf picker and the editor's
                     List row); saved for when Wi-Fi is off. Downloads: the detail call,
                     the download and the hash check run in OrbitShelf's background worker
                     with a corner note, instead of BookOrbit's loading pill over the
                     footer and a download on the screen's thread (the pill and the shelf
                     glitched while it ran). Linking the file to BookOrbit runs in the
                     worker too. A second tap on the same book doesn't start another.
                     Shelf > Search BookOrbit (off by default): Bookshelf's search looks in
                     BookOrbit instead of the device; results open like a folder ("BookOrbit:
                     <query>"), back returns. Wi-Fi off: the saved library list is searched.
  1.2.5  2026-11-05  Reports: the start-up line now shows BookOrbit's version (read from its
                     main.lua; it has none in _meta.lua), and the Diagnostics snapshot lists
                     every OrbitShelf setting plus the saved library size, how many books
                     Offline Library has saved, and whether a lookup run is going. No
                     change to how OrbitShelf works.
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
require("orbitshelf_collections")
require("orbitshelf_genres")
require("orbitshelf_source")
require("orbitshelf_bulk")
require("orbitshelf_extras")
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
    step("popup flash", O.hookPopupFlash)
    step("BookOrbit search", O.hookSearch)
    -- Return To shelf (off by default): Bookshelf's instance may come a moment later
    if cfg.return_shelf then
        local ok, done = pcall(O.hookReturnShelf)
        if not (ok and done) then
            UIManager:scheduleIn(1, function() step("Return To shelf", O.hookReturnShelf) end)
            UIManager:scheduleIn(3, function() step("Return To shelf", O.hookReturnShelf) end)
        end
    end
    -- Offline Library: new books since last time, quietly, once shortly after start
    if cfg.offline_library and O.Genres.autoOn("wifi") then
        UIManager:scheduleIn(20, function()
            if O.isWifiOn() then step("Offline Library", O.Genres.build, true) end
        end)
    end
    step("Remove From Device button", O.registerFileDialogButton)
    step("close-only menu", O.hookCloseOnlyMenu)
    step("footer critter", O.hookFooterCritter)
    if cfg.home_button then step("Home button", O.hookHomeButton) end
    if cfg.mark_not_on_device then step("Not On Device mark", O.Extras.hookNotOnDeviceMark) end
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
    -- back home after finishing a book: Next In Series asks once the home screen is up
    if self.ui and not self.ui.document and O.Extras.hasPending() then
        UIManager:scheduleIn(1, function() step("next in series", O.Extras.offerNext) end)
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
    if O.Bulk.running() then step("bulk download pause", O.Bulk.pause) end
    step("save lists", O.flushPageCache)
end

-- awake again: a Bulk Download paused by sleep asks whether to continue, once the
-- sleep screen is gone (with "tap to exit" the screen stays until OutOfScreenSaver)
function OrbitShelf:onResume()
    if O.Bulk.running() then step("bulk download resume", O.Bulk.offerResume) end
end

function OrbitShelf:onOutOfScreenSaver()
    if O.Bulk.running() then step("bulk download resume", O.Bulk.offerResume) end
    if O.Extras.hasPending() then step("next in series", O.Extras.offerNext) end
end

-- the last page of a book: Next In Series remembers what comes next (asks back home)
function OrbitShelf:onEndOfBook()
    if cfg.next_in_series then step("next in series", O.Extras.endOfBook, self.ui) end
end

-- KOReader saving its settings (closing a book, exit, sleep): the saved lists, if changed
function OrbitShelf:onFlushSettings()
    step("save lists", O.flushPageCache)
end

return OrbitShelf
