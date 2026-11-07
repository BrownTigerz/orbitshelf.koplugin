# OrbitShelf

BookOrbit shelves inside [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin): your whole BookOrbit library on the shelf, books on the device or not.

**Version:** 1.2.21 · **Requires:** bookshelf.koplugin (source API 1; best with Bookshelf 6.x) and bookorbit.koplugin, signed in

## Install

1. Copy the `orbitshelf.koplugin` folder into KOReader's `plugins` folder.
2. Restart KOReader.
3. Open **Tools → OrbitShelf** (or **Tools → Add-ons → OrbitShelf** with the Add-ons menu patch) and turn on **Use BookOrbit In Bookshelf**.

**Everything is off on a new install**, so Bookshelf stays as it is until you turn things on.

**Updating:** copy the new folder over the old one and restart. Settings are kept.

**Coming from the old patch** (`2-orbitshelf-tweaks.lua`, and `2-zz-orbitshelf-tweaks-diagnostics.lua` if you had it): delete both from `patches/` first. While the old patch is there it runs and the plugin stays off (crash.log says so). Your settings, genres, saved lists, offline library and covers carry over; they live in KOReader's settings and data folders, not in the patch.

## Settings

Under **Tools → OrbitShelf**:

- **Use BookOrbit In Bookshelf**: adds a **BookOrbit** shelf source, so books not on the device show too. Modes: Library, Recently added, Recently read, **Series**, **Authors**, **Genres**, collections, **smart scopes** and **libraries** (one shelf per BookOrbit library: add a shelf, pick BookOrbit, then **Library: <name>**). A Library, Collection or Smart Scope shelf can also use **Group By** in the shelf editor (None, Series, Authors or Genres) to show just its own books as folders. Series, Authors and Genres are folders: tap a group to see its books. A new shelf is named after its list (Authors, Recently added, the collection's name …) and follows it when you change the list, unless you've typed your own name.
- **Rewrite Stock Series / Authors / Genres**: points Bookshelf's own Series, Authors, Genres, Recent and Latest chips at BookOrbit. Turn it off and the stock chips come back.

- **Return To**: which shelf Bookshelf shows when it opens or when you close a book. **Bookshelf's Choice** (default) keeps whatever shelf you were on; pick a shelf (Home, Authors, …) to always come back to it.
- **Add To Collection**: see [Add To Collection](#add-to-collection) below.

**Offline Library** (off by default)
- **Keep Library Offline**: saves every BookOrbit book's cover and details (description, pages, published, language, genres) on the device, so the whole library shows with Wi-Fi off. The books themselves aren't downloaded: those still show **Download** (dimmed with Wi-Fi off), and the hero says **Not On Device · Saved Offline** next to the rating stars (just above the buttons when there's no rating row, as in list view). About 25 KB a book. It runs in the background, pauses on Wi-Fi off or sleep, and carries on when Wi-Fi is back.
- **Status**: how many books are saved, and the size.
- **Update Now**: pulls the library list fresh and saves anything new or changed.
- **Check For New Books**: when it looks by itself:
  - **On Wi-Fi Connect** (default): at start and every time Wi-Fi connects.
  - **On Refresh / Sync**: when you tap Sync or swipe down to refresh a BookOrbit shelf.
  - **Both**.
  - **Update Now Only**.
- **Delete Offline Library…**: removes the saved details and trims covers back to normal. Turning Offline Library off asks Keep or Delete.

**Hero**
- **Download / Remove Buttons**: a book not on the device gets **Download / Open In BookOrbit** at the bottom of the banner; one on the device gets small round **Remove From Device** and **Open In BookOrbit** icons at the bottom right.
- **Sync Button**: a small round Sync icon for BookOrbit books. It pulls the lists fresh and runs BookOrbit's sync.
- **Button Size**: Small (default), Medium or Large, for the buttons and icons.

**Shelf**
- **Search BookOrbit** (off by default): Bookshelf's search looks in your BookOrbit library instead of the books on the device. Results open like a folder; back returns to where you were. With Wi-Fi off it searches the saved library list.
- **Build Genres / Rebuild Genres**: BookOrbit's lists carry no genres, so they're looked up once per book in the background (about a minute for 130 books with Wi-Fi on). The screen keeps working. Wi-Fi off pauses it; it finishes when Wi-Fi is back. After that, only new or changed books are looked up.

**Flash** (all off by default; turn on only what you need)
- **Hero When It Changes**: flashes the hero clean when it shows another book, so the last cover doesn't linger. **Hero: Every Change**, every 4th or every 6th, so most taps stay quick.
- **Shelf Page Turns**: every shelf page turn is a full refresh.
- **Book Description**, **Hold Menu (BookOrbit Books)**, **Download Window** (a book not on the device), **Bookshelf's Book Menu** (hold a book on the device) and **Shelf Editor** (hold a shelf tab): that popup's box flashes when it opens and when it closes (not the whole screen).

**Footer**
- **Footer Critter**: puts your SimpleUI critter in place of the page numbers. It says the shelf, the page and a remark (**Critter Says**: Page, Witty, Picks, Sayings). Tap it for another remark; the edges and swipes still turn pages.
- **Close Only**: the footer menu button becomes a one-tap close X. **Close Control** puts it left, right or on Bookshelf's side.

**Clean Up Cache…**: removes old covers and saved lists. With Offline Library on, every cover is kept.

**Diagnostics** (off by default): for troubleshooting. Writes what OrbitShelf does (shelf loads, covers, downloads, hero, timings) to crash.log, tagged `orbitshelf <version> diag:`, for 30 minutes after each start or after turning it on. Turns itself off after 3 days.

## Book Description

Tap or hold a book that isn't on the device: next to **Download** and **Open In BookOrbit** there's **Book Description**. It opens a small window sized to the description, which scrolls only when it's very long. Tap the X or anywhere outside to close. It uses the saved description (Offline Library) or looks it up once with Wi-Fi.

## Add To Collection

Turn on **Add To Collection → Add To Collection In Book Menu** (off by default). Hold a BookOrbit book's hero (with the hero buttons on), or tap a book that isn't on the device, and tap **Add To Collection**: your BookOrbit collections, ✓ on the ones the book is in. Tap one to add or remove it, or **New Collection…**.

BookOrbit's KOReader sign-in can't change collections, so it signs in like the website, with your BookOrbit **website** username and password. The first time, a notice explains what's saved and where (also under **About The Saved Password**). The sign-in box has a **Save password on this device** tick: only a sign-in BookOrbit accepted is saved, AES-encrypted with its key in a separate file, and never in Patch Backup & Restore's backups. **Forget Saved BookOrbit Password** clears it. It's the same sign-in, messages and saved password as the BookOrbit Tweaks patch, so if you have both they share one login, and with the patch installed its picker opens.

## When something's wrong

Problems go to **crash.log**, tagged `orbitshelf <version>:`, whether Diagnostics is on or not. Each one is written once per start:
- At start: the KOReader version, the device, the Bookshelf / BookOrbit / SimpleUI versions, and every patch and plugin present.
- Any part that fails, with where. Bookshelf's own version runs instead, so the screen doesn't break.
- By file name, any other patch or plugin that changed a Bookshelf function OrbitShelf relies on (hero, close X, footer, flash), or replaced the BookOrbit shelf source.

To report a problem, send `crash.log`, ideally with **Diagnostics** turned on just before it happens.

## Files

`main.lua` (start-up, menu, Wi-Fi and sleep) · `_meta.lua` · `orbitshelf_core.lua` (settings, crash.log) · `orbitshelf_bookorbit.lua` (BookOrbit lists, covers, offline details, download / remove, Book Description) · `orbitshelf_genres.lua` (background lookups) · `orbitshelf_source.lua` (the Bookshelf source and its shelves) · `orbitshelf_hero.lua` (hero buttons, flash) · `orbitshelf_footer.lua` (critter, close X) · `orbitshelf_collections.lua` (Add To Collection) · `orbitshelf_menu.lua` (settings) · `orbitshelf_diag.lua` (Diagnostics, loaded only while it's on)

The full changelog is at the top of `main.lua`.
