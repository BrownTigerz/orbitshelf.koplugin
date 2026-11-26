# OrbitShelf Changelog

## 2.2.0 (2026-11-26)

The big one since 2.0.2, tested on the Kobo as 2.1.7 to 2.1.37 (their notes are below). Nothing you set is changed by the update; new options are off, except Reading Stats on a new install.

- **Reading Stats** (Books › Book Page: Reading Stats; on for new installs). **Book | Stats | All Time** at the top of the Book Page.
  - **Stats:** one book at a glance in tiles: time, days, pace, what's left and when you'll likely finish, this week, Day by Day (a ring of the whole read, a wedge a day), the calendar (tap a day), chapters, pages you came back to, your reads, habits and **Moments**. Highlights, bookmarks, X-Ray and Glimpse chips open their own windows.
  - **This Kobo | BookOrbit:** your KOReader statistics, or BookOrbit's reading sessions with the API key (every device and listening). A book never read on this Kobo opens on BookOrbit.
  - **All Time:** all your reading: total time (tap: the calendar in time), days (tap: in pages), books finished, the months ring, this week, authors, genres, habits, moments; marked-finished books count.
  - **Your Year:** a ring of the year coloured by book, the books finished, and the year's shelf (Bookshelf's spines; tap one for that book).
  - **Moments and rewards:** ReadMastery's achievements, levels and tiers for the book (with the page and chapter from now on), X-Ray (or KOAssistant's X-Ray) and Glimpse's pictures, all spoiler-free (only up to where you are).
  - **Offline:** everything you've opened is saved; **BookOrbit Account › Save All Stats For Offline** saves all your BookOrbit stats at once (Wi-Fi on, only when you tap it).
- **The Book Page, redesigned:** ‹ OrbitShelf · Book | Stats | All Time · More ▾ · ✕; one main button beside the cover, the book's files as chips (tap to pick what Download gets for this book), the description, the series strip and More by / Similar books. **More ▾**: Sync (ShelfSync, BookOrbit), Link, Highlights / Bookmarks / X-Ray, Manage Downloads, Settings.
- **Settings is a window:** groups on the left, their settings on the right, each in its own box; open until ✕ or Back; hold one for what it does. Advanced sits above Help. **Help › Quick Setup** (also shown once after this update): Hold A Book Opens, Reading Stats, Colour, Popup Style, Cover Marks, Hero Buttons, Footer Critter in one popup.
- **Look:** **Colour** (off: everything plain; on: buttons, sections, boxes and Settings in colour), **Colour Theme** (Vibrant, Pastel, Ocean, Sunset, Forest, Kobo Mono, Custom), **Popup Style** (Standard, Rainbow, or Solid in a colour you pick) and **Screen Flashes** for each kind of screen. Popups are sheets in sections with a line between each item.
- **Fixes:** Look's choices (Colour Theme, Popup Style, Screen Flashes) are kept after a restart; the API key saved by BookOrbit Tweaks opens in OrbitShelf (shared keyring); Bookshelf no longer flashes or ghosts the cover when closing with a book open or opening one. Create API Key File: a missing file-system reference fixed.
- **Diagnostics** (Advanced › Diagnostics) also logs the BookOrbit stats look-ups and Your Year shelf taps, and times the Book Page and stats pages.

## 2.1.37 (2026-11-26)

- **Look › Colour** (TK, mockup m6; was Pill Colours, the same setting kept): on, colour everywhere it's for show, whatever the edge: the pill buttons, the popups' sections, the Book Page's boxes and the Settings window (the picked group and the option boxes). Off (the default): everything standard: plain pills, sections outlined instead of filled, no colour dashes, Settings plain. Popup Style still decides the edge, and charts and rings keep their colours either way.
- **A line between each item** in the popups' sections (More's Sync This Book | Send Waiting Updates | Sync With BookOrbit, Link Book | Hardcover, This Book's Highlights | Bookmarks | X-Ray, …) so each one is easy to tell apart.
- **Stats: the Glimpse chip only shows when Glimpse has pictures to show** for the book (after its own filter); it said "no maps, family trees or pictures" before.
- **Moments: Glimpse too** (with or without X-Ray): pictures so far (maps, family trees), how many are still ahead, and the latest one's caption, only up to your chapter like Glimpse.
- Diagnostics: the BookOrbit stats line now says how many days were saved (it said "?").

## 2.1.36 (2026-11-26)

- **Settings, the new layout** (TK, mockup m5): the groups down the left, the picked group's options on the right, each option in its own box. The window is only as tall as it needs to be (the same height for every group, so it doesn't jump). Tap a group to see its options; a › option opens its own page on the right (‹ Back). Swipe left / right for more options or the next / last group; hold an option or a group for what it does. The picked group and the boxes follow Popup Style: plain with Standard, each group's colour with Rainbow, the one colour with Solid.
- **Look › Pill Colours** (TK; off by default, "off is standard"): on, the pill buttons are in colour (each its own, or Solid's colour with Popup Style Solid); off, they're plain, black with white words (white with black at night). This covers the popups' pills and buttons, the Book Page's, Book | Stats | All Time, the stats page's chips and month pills, Your Year / All Time pills and the Glimpse viewer. Pills were always in colour before, so with this off they now look plain until you turn it on.

## 2.1.35 (2026-11-26)

- **Your Year: tapping a spine opens its book** (TK: still nothing on the Kobo in 2.1.32-2.1.34). Bookshelf's shelf row never records where it was drawn, so the stats page couldn't tell a tap had landed on it. The row is now held in a box that does, and the spine is found by its place. With Diagnostics on, each tap on the shelf is logged (where, and which spine).
- **All Time: Time opens the calendar in time**: each day shows the time read (45m, 1h 20m) and the month's total time. Days still opens it in pages.
- **Book Page: Reading Stats is on by default** for new installs (TK). A Kobo that already has OrbitShelf keeps what it has saved: turn it on in Settings › Books.
- **Fixed: tapping Stats or All Time with Reading Stats off crashed KOReader**. It now says Reading Stats is off and where to turn it on.
- **ReadMastery rewards say where they happened**: each achievement, level-up and tier-up noted while a book is open now keeps the page (of how many) and the chapter, and an achievement earned again is noted too (ReadMastery itself only counts them). Shown in the book's Rewards and Moments (from now on; earlier ones have the time only).
- **Diagnostics logs the BookOrbit look-ups for Reading Stats**: each one (the path, with ids and dates only), how many items came back or why it failed, and how long it took; and per book, how many sessions and whether they were saved for offline.
- **Settings**: Advanced moved to second last, above Help. The group chips follow Popup Style like the edge: Standard plain, Rainbow each group's colour, Solid the one colour.

## 2.1.34 (2026-11-22)

- **Popup Style: Solid** (TK): Look › Popup Style now has Rainbow, Solid and Standard. Solid draws the popups' edge, grab bar and colour line in one colour you pick (Solid Colour: any of the theme's 8), and every pill button too: filled ones in that colour, outlined ones edged in it (popups, the Book Page, Stats, Your Year, All Time, the Settings chips). Standard stays the default.
- **Look settings are kept after a restart**: Colour Theme, Popup Style and Screen Flashes' kinds (Book Page, Book Page Changes, Popups, Stats Page, Stats Page Changes) went back to their defaults every time KOReader started. They're saved now; their defaults are the same as before, so nothing changes until you pick something.

## 2.1.33 (2026-11-22)

- **Settings is one window** (TK, mockup m1): Tools › OrbitShelf and More ▾ › Settings open the same window. A chip for each group at the top (tap to jump to it), each group a card in its own colour, switches drawn as switches, the current value at the right of a row, and › for a page of its own (‹ Back or a swipe right comes back). It stays open until ✕ or Back, or sleep; a tap outside does nothing. Swipe left / right for more pages, hold a row for what it does. The edge follows Look › Popup Style. The rows are the same as before; nothing you set changes.
- **Save All Stats For Offline** (TK), in Settings › BookOrbit Account: fetches BookOrbit's stats for every book you've read there, and your years, and saves them, so Stats, Your Year and All Time open with Wi-Fi off without looking at each one first. Only when you tap it (Wi-Fi on); the row shows the date it last ran.

## 2.1.32 (2026-11-22)

- **Tapping a spine on Your Year's shelf opens its book** (TK: it still did nothing). Bookshelf's spine slots took the tap themselves and dropped it (they had nothing to call for these books), so the card never saw it. Each spine on that shelf now has its own tap handler that opens the book's popup; with Diagnostics on, crash.log says how many spines were hooked and which book each tap matched.

## 2.1.31 (2026-11-22)

- **A spine shows everything about its book** (TK): the book's popup is the same wherever it opens. On BookOrbit's side it now also shows When You Read It from this device (and the time read), and a spine is matched to its book by title when Bookshelf hands back its own copy of the record.
- **All Your Reading**: a book's title on the line is only drawn where it fits under the pills ("No Exit" ran into Your Year) (TK).
- **A book never read on this device** opens Stats on BookOrbit's side with no Device | BookOrbit switch, so the page stays clean (TK's plan).

## 2.1.30 (2026-11-22)

- **Tap a book for when you read it** (TK): a book's popup (from Your Year's shelf or list, All Time's Books tile, the books on All Time's line, an author's or genre's books) now has When You Read It: a bar a day from your first day to your last (the best day in gold), then your best day, longest sitting, most days in a row and the part of the day you read it most, with its sittings counted. From KOReader's statistics, every copy of the book; a book opened for under a minute that day doesn't count as a reading day.
- **All Time**: TIME, DAYS, BOOKS and PAGES fit their tiles (a little taller, and the number shrinks when it has to); the critter is bigger, filling the top right.
- **Your Year's shelf has no ornaments** (Bookshelf's plant): only your books (TK).
- **Rainbow popups are sleeker** (TK): a thinner edge, colour line and grab bar.
- **After sleep the stats open on Device** (TK): the first time after waking, Stats and All Time open on Device even if BookOrbit was picked last, so nothing waits on BookOrbit while Wi-Fi comes back. Picking BookOrbit works as before.

## 2.1.29 (2026-11-22)

- **Books you marked finished count** (TK marked 4, the stats said 2): All Time and Your Year count a book as finished when KOReader's status for it is Finished (the day you marked it), as well as when you read to the end. A book marked finished after a few minutes here doesn't count as your fastest read.
- **All Time's hero**: the critter sits in the top right (it's all your reading, not one book); the book you're reading has a marker where you are on the line instead. Short books on the line are no longer too thin to see.
- **Authors, Genres and Habits** are two short lines each so they fit (e.g. "Afternoons · 48% · evenings next"). Tap Authors or Genres for the list, then an author or a genre for its books, then a book for its popup (TK).
- **BookOrbit side**: BookOrbit doesn't say how long each book took, so Books lists the finished ones by date instead of "0m" bars, and Pages shows "–" when BookOrbit has no page count.
- **Your Year's shelf shows every book read that year** (it only had the finished ones), in the order you started them. Tap the ring for the list of every book (the spines' titles are small) (TK).

## 2.1.28 (2026-11-22)

- **All Time** (TK picked the mockup): the stats page for all your reading, not one book. The hero has since when, days read and books opened, Your Year / Finished / Reading pills, and the books you finished on one line with SimpleUI's critter on the one you're reading now. Under it: TIME, DAYS, BOOKS and PAGES; your months as a ring with your biggest month; this week's days against last week; Moments (best day, longest streak, fastest finish, most in one go); the books by time; authors, genres (from BookOrbit's library) and habits (the part of the day you read most). Tap a tile for more: TIME, DAYS and This Week open the calendar (tap a day for what you read), the books open every book you've read, each with its popup. Device | BookOrbit as on Stats: This Kobo from KOReader's statistics, BookOrbit from your years there added up.
- **Book | Stats | All Time** (TK): the Book Page's switch has All Time now, and the stats page has the same bar (‹ OrbitShelf · Book | Stats | All Time · More ▾ · ✕) in place of ‹ Book · Reading Stats · ✕. More ▾ is hidden on All Time.
- **Your Year**: All Time sits in its row (‹ 2025 · 2026 · All Time); Every book this year › lists every book read that year (time and pages, ✓ finished); tap a spine on the year's shelf (or a book in the list) for its popup: time, pages read, days, started / finished, with Stats and Book Page (TK).
- **Rewards** (TK): All N rewards › shows every reward ReadMastery has unlocked (Book Slayer was missing: it's earned when a book is finished, after the sitting), the ones from this book marked; no Open ReadMastery button.
- **Chapters strip**: the blocks fit the width, so "N more" no longer runs off the right edge (TK).

## 2.1.27 (2026-11-22)

- **A tapped day shows what you read** (TK): every book you read that day, each with its pages and time (copies of a book downloaded again count as one), and the day's total time, books and pages; this book's sittings under it. No Reading Insights button.

## 2.1.26 (2026-11-22)

- **Glimpse in the stats** (TK picked the design): the Glimpse chip opens a popup of the book's pictures (maps, family trees, the rest) and a full screen view: the picture big, then where each one is in the book along a line, with SimpleUI's critter where you are (a marker without SimpleUI). The book stays closed: OrbitShelf reads Glimpse's saved list, or runs Glimpse's own scanner over the EPUB (once a book, at close) and keeps it. Spoiler-free: Glimpse's Mode is followed (up to your chapter / whole book), with its filter and the pictures you hid or added; a picture past your chapter is never opened, just a "?". Open In Glimpse opens the book and Glimpse.
- **Tap a day** (TK): on the calendar (DAYS) or a day's wedge on the ring: that day's time, pages, sittings and streak, the sittings on a 6 AM – 12 AM line with their pages, other books, highlights and ReadMastery rewards that day; ‹ › to the next day; Day View opens KOReader's own day view, Reading Insights opens Reading Insights.
- **Moments: every ReadMastery reward** (TK): the newest five in Moments, then All N Rewards › for every one from the book, a page at a time, with Open ReadMastery (its Achievements).
- **Records and where you read it** (TK, like BookOrbit's web Reading Log): This read (TIME / LEFT) shows longest sitting, best day, longest streak and pace; on BookOrbit also how much was read where (each device or app).
- **Calendar**: a star on the month's best day (TK).
- **Day by Day**: no pill for a month that hasn't come yet (Dec showed because of the likely finish) (TK).
- **Chapters strip**: shorter blocks with bigger words (black on the colour), at most 8 blocks so they don't get too thin as chapters pile up (the earlier ones fold into "N earlier") (TK).
- **X-Ray chip from KOAssistant** (X-Ray not installed) is named "X-Ray · KOAssistant" (TK).

## 2.1.25 (2026-11-22)

- **DAYS opens a calendar** (TK): the month a day at a time (greener: more read, today outlined, the likely finish flagged in its month), with a pill for each month of this read. The month tile keeps the ring.
- **X-Ray and Glimpse chips only when there's something to show** (TK): X-Ray when X-Ray (or KOAssistant) has saved an X-Ray for the book; Glimpse when Glimpse has gone through the book and found pictures. The This read popup (TIME / LEFT) no longer repeats the chips: they're on the book tile.
- **Habits popup**: the dips / longer / deep-dive counts sit as a key under the bar instead of under each piece (a thin last piece ran its words off the edge).

## 2.1.24 (2026-11-22)

- **Day by Day's ring and the month tile's small ring draw on the Kobo now** (TK's crash.log): with Diagnostics on, the diagnostics loaded the ring's file at start before the stats page had loaded, that first load failed, and Lua then refused the file for the rest of the session ("loop or previous error loading module"), so the ring always fell back to the grid. The ring's file now loads the stats page first, and Diagnostics only times it once the stats page has loaded it.
- **✕ and ‹ Month work with Popup Style Rainbow** (TK): the rainbow edge was drawn over the stats page's popups as a picture and took the taps meant for the buttons inside it.
- **The description popup follows Popup Style** (TK): Rainbow gives it the 8-colour edge and the colour line under the title; Standard stays as it was.
- **Outlined pills and chips follow Popup Style** (TK): their colour edge only with Rainbow; Standard edges them in black (white in night mode). Filled pills keep their colour.

## 2.1.23 (2026-11-22)

- **X-Ray popup** (TK; new orbitshelf_xray.lua): the stats page's X-Ray tile, the X-Ray chip and More ▾'s X-Ray row open everything X-Ray fetched for the book, read from its saved data with the book closed, offline, and only up to your page: Characters / Places / Historical / Terms / Timeline tiles (tap for the list), You And The Cast (most looked up, most time with, most mentioned), People You've Met, Where The Book Took You, Open In X-Ray, Terms & Historical.
- **A name's card** (after Aleph's): its description and other names, your time with it, how often you looked it up, where you met it; where it comes up chapter by chapter (chapters you haven't reached aren't shown); first seen, most mentions, latest; often with; its mentions with the words around them, three to a page.
- **KOAssistant**: when X-Ray isn't installed, KOAssistant's own X-Ray of the book is read instead (only up to where it was made). With neither, the popup says what each would add.
- **Most looked up**: X-Ray doesn't keep a count, so OrbitShelf counts the X-Ray cards you open while reading, from now on (settings/orbitshelf_reading_log.lua, by title).
- **ReadMastery rewards** (TK): Moments shows the achievements ReadMastery unlocked while you were reading the book (from its own data), and from now on the level-ups, tier-ups and XP each book earned (ReadMastery keeps no history of those, so OrbitShelf notes them while a book is open).
- **Moments in sections**: Your Reading, In The Story · X-Ray (first met, looked up most, most time with, where it took you), Rewards · ReadMastery. The tile mixes one of each in.
- **Chapters** shows who comes up most in each chapter; **Pages You Came Back To** shows who's on each page.
- **Look › Popup Style** (TK): Rainbow (an edge in the 8 colours, a rainbow grab bar and the colour line under the title) or Standard (a plain edge, no colour line; the default). Covers OrbitShelf's popups and the stats page's.
- **A swipe down** on the Book Page or the stats page brings KOReader's top menu (with the Shortcuts Toolbar) instead of closing the page (TK).
- **"This Kobo" is "Device"** on the stats page and its messages (the stats can come from any device).
- X-Ray / KOAssistant / ReadMastery are only read when installed; nothing of theirs is changed.

## 2.1.22 (2026-11-22)

- **Words on a colour are black** (TK): buttons, pills, chips and the Book | Stats switch, night mode included (night mode flips the page, so they're drawn white there and show black).
- **A popup's button that can't do anything isn't drawn** (TK: Highlights / Bookmarks "Show" was hard to see with none): the line under the row says why ("none yet", "Nothing waiting").

## 2.1.21 (2026-11-22)

- **This Kobo's stats count every copy of the book** (checked against TK's statistics.sqlite3): a book downloaded again is a new file, so KOReader's statistics start a new row for it, and only the current copy was counted. TK's And the Mountains Echoed had 4 copies: the page showed 2h 54m over 11 days from Nov 11; with all of them it's 12h over 36 days from Oct 15 (BookOrbit has 11h). Same title and author's last name; at book close the title and author come from the statistics themselves. Highlights and notes still come from the copy on the device. Saved stats are worked out again once (record 3).
- Checked against the real database: the current copy's numbers on TK's Kobo (2h 54m, 11/12 days, 33 pages an hour, 107 pages in November, 52 pages this week, done around Dec 5) match KOReader's statistics exactly.

## 2.1.20 (2026-11-22)

- **A tile's page is a popup now** (TK): sized to what's on it, centred over the stats page. ✕, a swipe down or a tap outside closes just the popup and leaves the stats page there. Your Year's ‹ Month goes back to Day by Day.
- **Darker small text** (TK: grey was hard to read, night mode most of all): the smaller lines on the stats page, Day by Day, Your Year, the popups and the Book Page are near black now.
- **The campfire's gone** from the stats page's journey line (TK); the critter stands where you are.
- **Finish range fixed:** a few 1-page days made the slow end months away (TK saw "Nov 29 – Sep 2" with 111 pages left); it now stops at twice the estimate.
- **Diagnostics:** when the month tile can't draw its ring, crash.log says why (TK's Kobo showed the grid).

## 2.1.19 (2026-11-22)

- **Fixed: the stats page crashed KOReader on a colour screen** (blitbuffer.lua getColorRGB32, TK's crash.log 5:40 AM): the Highlights / Bookmarks / X-Ray chips beside the title handed KOReader a colour wrapped in a table for their outline. Since 2.1.9's chips; grey screens didn't hit it.
- **Fixed: Stats asked for the API key that Add To Collection already had.** BookOrbit Tweaks and OrbitShelf share one saved key, but each kept its own unlock key in the keyring ("aes_key" and "k"), so OrbitShelf couldn't open a key BookOrbit Tweaks saved. OrbitShelf now uses BookOrbit Tweaks' one, still opens a key it saved itself before, and saves that again the shared way.

## 2.1.18 (2026-11-22)

- **The settings menu, regrouped** (TK's mockup): the groups A to Z (Advanced, BookOrbit Account, Books, Downloads, Footer, Look, Offline, Shelves), Help last. In each group the switches come first, A to Z, then the rest A to Z. Values still show after the colon ("Book Type: Text Only").
- **Switches with settings are one row:** Footer Critter, Cover Marks, Hero Buttons and Keep Library Offline. Tap the box to turn it on or off; tap the words for its settings (when it's off, the words turn it on). Critter Says, Mark Style, Hero Button Size and the Offline Library rows moved inside them.
- **BookOrbit Account:** the API key rows have their own group (they were inside Books › BookOrbit Sign-In). It says "API key active" when one is saved.
- **Look › Screen Flashes** replaces Flash: Book Page, Book Page Changes, Hero, Popups, Shelf Pages, Stats Page and Stats Page Changes, each No Flash / Quick Flash / Full Flash (Hero: No Flash, Every Change, Every 4th, Every 6th). Popups covers the older popups too (Book Description, the hold and download menus, Bookshelf's book menu and shelf editor) once it's picked; until then those keep your old Flash setting.
- **Downloads:** Book Type, Queue › and Remove Finished Books › (Not Opened For and Remove Now… inside).
- **Settings in the Book Page's More ▾:** a Settings button (next to What's On This Page, under Manage Downloads) opens the same menu as a popup over the page; closing it leaves you on the Book Page.

## 2.1.17 (2026-11-22)

- **Fixed: the stats page crashed KOReader** (verticalgroup.lua:51, since 2.1.10): it measured its page before the tiles went in, and KOReader keeps the first layout. Measured again once everything is in.
- **Stats for a book that isn't on this Kobo** (TK): Book | Stats opens BookOrbit's side for it (its reading sessions, fetched with Wi-Fi on and saved per book, so they show offline; fetched again after 30 minutes). This Kobo's side says there's no reading here yet.
- **Book Page: "‹ OrbitShelf"** instead of the bare arrow, a bigger target to go back to the shelf.
- **Quick flashes** (TK: popups and page changes left ghosting): a popup opening and closing does a quick flash over itself, and the Book Page changing (another book, Series ↔ Similar, a strip's swipe) does a quick flash. The Book Page and stats page opening and closing keep their full flash.
- **More ▾:** no BookOrbit · Open row (the page has BookOrbit ↗).

## 2.1.16 (2026-11-22)

- **Book Page: the strips are back.** 2.1.15's taller top pushed More by (and Similar books with it) off the page for a book without a series, and left a series book 1 line of description. The cover is a little smaller, the buttons and the Files line tighter (its hint is in the Files heading now), the strips' covers shorter, and the description keeps at least 2 lines with More by / Similar books as one row when room is short.

## 2.1.15 (2026-11-22)

- **The Book Page, redesigned** (TK's mockups), in colour on a colour screen:
  - **Top bar:** ‹ · a **Book | Stats** switch · **More ▾** · ✕. The shelf's Manage Downloads moved into More ▾ (Downloads section).
  - **Beside the cover:** the title, the author, series · year · pages, chips (rating, two genres, the language), the status with a progress bar, last read / finished / queued, and **one main button**: ▶ Continue Reading / Start Reading (on this Kobo), ↓ Download · size, Queue Download (no Wi-Fi) or Remove From Queue.
  - **Under it:** Queue (or Remove when it's here) · Status ▾ · Collection + · BookOrbit ↗.
  - **Files:** one line with the book's files on BookOrbit as chips: EPUB, ♪ Read-along · size, M4B · can't play. Filled = what Download gets (by Downloads › Book Type), ✓ = on this Kobo. **Tap a file to change it for this book only**: the pick is kept for that book (also for the Queue and re-downloads), the line under the status says "this book only: …", and Download takes it ("Download 2 files · 49 MB"). Book Type and the free space show on the right. The files come from BookOrbit's list (saved with the book from the shelf's next refresh).
  - The description, the series strip and More by / Similar books as before, with coloured headings.
- **Colour Theme** (Look › Colour Theme): Vibrant (the default, as before), Pastel, Ocean, Sunset, Forest, Kobo Mono, or Custom (tap any of the 8 colours for a new one; Reset To Vibrant). It colours the popups, the stats page and its rings, and the Book Page. Grey screens stay grey.
- **Speed in Diagnostics:** with Diagnostics on, the log times the Book Page (building, finding the series / More by / Similar books, first draw), the stats page (book data, building, first draw), Day by Day, Your Year (loading, building), the More popup, reading highlights and every popup, and the summary lists them slowest first with what each slow one means and whether a cache would help ("cache verdict").
- The rings draw about twice as fast (which side of the edges a pixel is on, instead of its angle).

## 2.1.14 (2026-11-22)

- **Book Page top bar: Stats · Downloads · More ▾.** More is a sheet in sections:
  - **Sync** (green): **Sync This Book** opens the book, then ShelfSync's own "update progress" to the sites it's linked on; **Send Waiting Updates** sends ShelfSync's queued updates without opening anything; **Sync With BookOrbit** runs BookOrbit's library sync (this book too).
  - **Link** (blue): **Link Book** shows this book's link on each ShelfSync site and links it: through ShelfSync Tweaks' "Link This Book" when it's installed (no opening), else the book opens and ShelfSync's own Link starts; **Hardcover · Bookshelf** opens Bookshelf's Hardcover book picker; **BookOrbit** opens the book in BookOrbit.
  - **This Book** (purple): Highlights, Bookmarks, and X-Ray (opens the book, then X-Ray's menu, where it can be fetched).
  - **Help** (teal).
  - Rows only show for what's installed and switched on.
- **Chips on the stats page's book tile:** highlights (+ notes), bookmarks, X-Ray, Glimpse, each opening its window. **Highlights** and **Bookmarks** list the book's own (from its sidecar), page by page, coloured like the highlight, with notes; a tap opens the book there. **X-Ray** shows who and where you spent the most time with, and Open / Fetch X-Ray. Glimpse opens the book.
- **Day by Day** (was The month): the ring covers **the whole read** (its first day to the finish, or the likely finish), so a book read across October and November is one ring; **This Read | Oct | Nov** switches to a single month.
  - A **clock face** inside the ring: a tick a day (longer every 5th day, gold where a month starts with its name), the day numbers like a clock's hours (every 10th past 5 weeks), today's in a gold disc. Only the wedges are outside.
  - **Sittings are cuts** in each day's wedge (3 pieces = 3 sittings) instead of dots.
  - Past 9 weeks, a wedge is a week.
- Opening a book from the stats page (a highlight, X-Ray) closes the stats page too.

## 2.1.13 (2026-11-21)

- **The month as a ring** (from BookOrbit's iPhone Activity ring, TK's pick). Tap the month tile on the stats page: one wedge a day round a circle, longer for a longer read that day.
  - **This Kobo:** each wedge in the colour of the chapter you were in; dots inside for your sittings; ○ a day you skipped; ★ your best day; a flag on the likely finish; faint dots for the days ahead; today glows. In the middle: how far through, your time this month, done around. Under it: Today / This Week (▲▼ on last week) / Streak (and your longest), then **Chapters this month** as blocks (wider: longer chapter; taller: more time), "you're here" on yours.
  - **BookOrbit:** the same ring with each wedge split: solid for read, striped pink for listened; "4h 6m read · 50m listened" in the middle; **Where you read** (each device or app, and listening) instead of chapters.
  - ‹ › go to the other months you read the book in.
  - The month tile on the stats page is now a small ring with the month's time, days read and best day.
- **Your Year** (all books; the button under the month ring). A bar a day round the year, coloured by the book you read most that day, a dot where each book was finished, today glowing, month letters round it. Books finished in the middle (BookOrbit: "of N books" and Goal reached with a reading goal), Today / This Week / Streak (and Listened on BookOrbit), and **Your 2026 shelf**: the year's finished books in Bookshelf's own spines on its plank (plain coloured spines without Bookshelf). The ring takes each book's colour from its spine, brightened. ‹ › other years.
  - **This Kobo:** from KOReader's statistics (finished = reached 97% this year after at least 30 minutes with it); the books on the shelf are found through your history. Worked out again only when the statistics change.
  - **BookOrbit:** four calls the API key may make: reading-heatmap (each day's time), reading-history (the finished reads and their dates), its summary (pages, days, goal) and peak-hours (audio time). Days outside a finished read are grey. Saved, fetched again after 30 minutes with Wi-Fi on. BookOrbit's own year and calendar calls are iPhone-app-only, so they aren't used.

## 2.1.12 (2026-11-21)

- **Book Page top bar: Manage Downloads · Stats · Help.** Bulk download/remove moved into **Manage Downloads**, and **Stats** sits beside it (only when the book has stats), so you switch between the Book Page and the stats page from the top. The Description box is back to just the description (the Stats side and swipe are gone).
- **Manage Downloads** is a new sheet in sections, each with its own colour:
  - **Now** (green, while a job runs): what's happening, with Stop.
  - **This book** (gold): on this Kobo or not, Remove / Download / Queue.
  - **This shelf** (blue): how many are downloaded, a bar, and Download N… / Remove N… (opens the tick list as before).
  - **Queue** (teal): what's waiting, Download Now.
  - **Storage** (purple): space used.
- **Every OrbitShelf popup is now a sheet:** rounded, sectioned, with vibrant colours (blue, green, gold, red, purple, teal, pink, orange), a colour line under the title, pill buttons and coloured list rows. Tap outside or swipe down to close; long lists page with ‹ Back / More ›.
  - The book popup (tap a book that isn't on the Kobo) and the hero hold menu: **Get it** (Open / Remove, or Download / Queue / Move To Top / Remove From Queue), **This book** (Book Page, Description, Open In BookOrbit), **More** (Add To Collection, Reading Status, Manage Downloads).
  - Reading Status (each status in its colour, plus Don't Send), the More… row, Add To Collection, the queue item, Select, and the shelf pickers.

## 2.1.11 (2026-11-21)

- **Reading Stats, redesigned: one screen of tiles.** The trail and When you read are gone. The full stats page is now rounded tiles, each with a colour tag (blue, green, red, gold); tap a tile for its own page, ‹ Stats (or swipe right) to go back.
  - **The book:** title, author, started (or finished) and which read; the journey bar: read part green, a dot where each day ended, the campfire and SimpleUI critter where you are, dots for the days ahead, a flag with "done around …" and the date range.
  - **TIME / DAYS / PACE / LEFT** (DONE on a finished book).
  - **The month:** a cell a day with what you read that day, greener for more, today outlined, a flag on the likely finish day.
  - **This week:** the total with ▲/▼ against last week, a bar a day (green: beat the same day last week) and last week's red ticks.
  - **Your reads** (when you've read the book more than once): a re-read starts when, after reaching 90%, you go well back after a week or more away. Everything else on the page is about the newest read.
  - **Moments:** the page-turner (quickest 20 pages in a row), couldn't put it down, record day, when it clicked, the comeback, the slog, words you looked up (KOReader's Vocabulary Builder) and the highlight hotspot (the chapter with most highlights).
  - **Chapters:** the book's chapters (top level) are saved when you close it; the longest chapter, where you are and what's left in it, your time in each.
  - **Came back to:** the pages you returned to in the most separate sittings.
  - **X-Ray** (only with X-Ray installed): who you spent the most time with — your reading time on the pages each character is mentioned on, from X-Ray's own saved file, up to your page; people and places met so far.
  - **Habits:** quick dips vs longer sittings, weekdays vs weekends, late nights, the time of day you read fastest, and "longer than N of your last 10 books".
  - **Pages:** This read (all the old numbers, chips, pace line), The month, Weekly pace (and the last five weeks), Reading pace (a bar a day, your usual), Your reads, Moments, Chapters, Pages you came back to, X-Ray, Habits.
  - **BookOrbit side:** the same screen with only what BookOrbit has (percent amounts; no chapters, came back to, X-Ray or reads).
- The saved stats record changed shape (it now keeps each page's time, your reads and the pages you came back to), so each book is worked out again once.

## 2.1.10 (2026-11-21)

- **Reading Stats: This Kobo | BookOrbit** (step 13; for checking the placement). A switch under the stats page's top bar.
  - **BookOrbit** loads the book's reading sessions from your BookOrbit server with the saved API key (Wi-Fi is asked for if it's off): every device and listening, not just this Kobo. The last fetch is saved, so it shows offline with its date ("as of …"), and opening the page again fetches fresh when it's over 30 minutes old and Wi-Fi is on.
  - It shows only what BookOrbit has. With no pages in BookOrbit's sessions, the book counts in percent: "29% to go", "2.6% an hour", "Today 22m, 0.9%", the trail in minutes per 1% ("0–55% before BookOrbit" when its sessions start partway). Left out: "faster than X of your last 10", the highlights / bookmarks / X-Ray / Glimpse chips, and pages on this Kobo. The footer says where the sessions came from (device names, iPhone, …); listening sittings are striped in When you read.
  - The page opens on the side you picked last (new setting, This Kobo to start with). If BookOrbit can't be reached and nothing was saved, it says so and stays on This Kobo.
- The trail: the critter at camp sits just past the fire under the trail ahead (it covered the bubble and the "uphill" words), the dates ahead start clear of it, "easy" sits in the ground under the low point when there's room, and both names get a backing so dots don't cover them.

## 2.1.9 (2026-11-21)

- **Reading Stats, more per book** (from comparing with SimpleUI Plus's Book Stats):
  - The grey line under TIME / DAYS / LEFT starts with **today with this book** ("Today 17m, 9 pages"), or **when you last read it** ("Last read 3 days ago (Nov 19)") when it wasn't today, and the sittings say **how long they run on average** ("18 sittings, about 12m each, longest 14m").
- **Beside the title (placement for now):** chips for the book's **highlights** (with notes) and **bookmarks** (from the book's sidecar when it's on the device; only when there are any), **X-Ray** (xray.koplugin) and **Glimpse** (glimpse.koplugin) only when installed and not turned off. They sit on the author's line at the right, or their own line when there isn't room. Tapping them does nothing yet; each opens its own compact window in a later build.
- The footer line no longer repeats highlights, notes and sittings (they're in the chips and the grey line).

## 2.1.8 (2026-11-21)

- **Reading Stats redesign** (Books › Book Page: Reading Stats, still off by default):
  - **Book Page, Stats side:** TIME / DAYS / LEFT in three columns, each with a small chart (your last reading days as bars, a dot for each day since you started, a progress bar), as much as fits the box, plus "An afternoon book · 81% noon to 5 PM".
  - **Stats page:** a line about this week ("Read every day this week. Thursday did the most (38m)."), the same three columns, then pace, sittings and pages last time in one grey line ("faster than 7 of your last 10").
  - **The trail** replaces the reading path and pace through the book: where you are in the part read on this Kobo (what came before is a labelled hatched box), height = minutes a page (higher = slower), "uphill" and "easy" named, a numbered dot where each day ended, a campfire where you are now with your SimpleUI critter, the days ahead dashed to the summit flag with dates, a date range from your quicker and slower days, and the longest break with a sleeping critter.
  - **When you read** replaces the calendar and the Reading Sky: one strip per reading day across the sun's day (6 AM to 6 AM), sittings as bars, the day's total at the right.
  - **Colour on colour screens** (Kaleido with colour on): gold, blue and a red top day as accents on shapes only (words stay black and grey), pre-flipped in night mode; the page opens with a dithered refresh. Greyscale screens and colour off keep greys.
  - Critters are SimpleUI's (the one you picked); without SimpleUI they're left out. The campfire is `campfire.svg` in the plugin folder.
- **Book-close cache:** with Reading Stats on, a closing book's numbers are worked out a tick after it closes and saved in `cache/bookorbit/orbitshelf_stats.lua`. The Book Page uses them straight away and reads KOReader's statistics again only when they changed for that book (one small check when another book was read). At most 60 books (the oldest go first). Clean Up Cache clears it.
- Help and What's New text updated for the new layout.

## 2.1.7 (2026-11-19)

- **Reading Stats on the Book Page** (Books › Book Page: Reading Stats, off by default). The Description box gets a second side: tap Stats › or swipe it. It shows your time, days and pace with this book, the time left and a small reading path. Tap it for the full stats page: progress, the reading path with where your pace takes you, a calendar, the Reading Sky (each sitting as a dot on its day and time, with sunrise, sun, sunset and moon across the top) and your pace through the book. From KOReader's own statistics on this device; books not read here have no Stats side.
- **Bookshelf refresh fixes:**
  - Close X with a book held open no longer asks a full refresh first (the shelf flashed before closing).
  - Opening a book from Bookshelf: Bookshelf's early full refresh is dropped and one is asked once the book is on screen, so the cover doesn't ghost onto the first page. Bookshelf's cover opening effect stays.
- What's New: a short note about Reading Stats for anyone who already saw 2.0's.
- Changelog: the old in-file history from main.lua moved here, under 2.0.1 and below.
- Built on 2.0.2 (API key sign-in and Book Type are 2.0.2's own, unchanged). Tested as 2.1.0–2.1.5 test builds on the 2.0.1 base; 2.1.6 was a separate API-key merge test.

## 2.0.2 (2026-11-17)

- **Add To Collection uses a BookOrbit API key** (needs BookOrbit 3.8.0+ on the server) instead of the website password.
  - Create a key under Settings > You > API keys with **Read and write**.
  - Easiest: OrbitShelf → BookOrbit Sign-In → **Create API Key File** (writes `koreader/orbitshelf_api_key.txt`), paste the key on the marked line over USB, then Add To Collection or Set API Key… — imported, encrypted (AES-256), temp file deleted.
  - Or: Set API Key… on device.
  - Menu shows **BookOrbit Sign-In · API key active** / **API Key Active** when a key is saved.
  - Forget Saved API Key clears it (shared with BookOrbit Tweaks).
  - Shared with BookOrbit Tweaks 2.17.0+: same encrypted key and temp file.
  - About The API Key opens a scrollable window.
- **Downloads › Book Type** — how a read-along EPUB (with narration) downloads:
  - **Text Only** (default) — without narration, as before
  - **With Narration** — the book with its audio (for apps that play EPUB narration). If the book has no narration file: **No narration file for this book.** (nothing is downloaded)
  - **Both** — text-only copy plus "… - With Narration" beside it; remove takes both. The done note lists what arrived and what didn’t (text / narration none / narration failed)
  - **Same As BookOrbit** — follow the server's EPUB delivery setting for this device


## 2.0.1 (2026-11-14)
- A reading status set with Wi-Fi off can be dropped before it's sent: Reading Status… (hero Status, the Book Page, a book's menu) starts with Don't Send <status> while one is waiting, and the covers go back to the status the book had. The hero's button says Status · Queued meanwhile. The BookOrbit · Queue shelf shows books waiting to download only (TK: a book stayed on it after Remove Queue because its status was still waiting). Clean-up: an unused return value removed.

## 2.0.0 (2026-11-14)
- OrbitShelf 2.0 ("your library, ready offline"), built and tested as 1.3.0-1.3.24 and 2.0.1-2.0.4 on a Kobo Clara Colour: * Book Page (hold a book, or Book Page in its menu): cover with its status, title (tap for all of it), author, series, status, progress and last read (this Kobo's history or BookOrbit's), finished date for a book finished here, pages / year / language / genres; the buttons beside the cover (full-width under it on a tall book); Bulk Download, Bulk Remove and Help in the top bar with where the book is and the free space; the description (tap to read it all); the series, more by the author, or similar books (BookOrbit's, else by genre) with status and On device / Queued on each cover. The page opens on the series (or More by); Similar › or a swipe left past it shows Similar books, ‹ or a swipe right goes back. Book Page is also in Bookshelf's book menu (and the file browser's) for a BookOrbit book on the device. Opens over Bookshelf, closes on sleep and when a book opens; BookOrbit opened from it comes back to it. * The Queue: with Wi-Fi off, downloads and reading statuses wait; the queue runs once 15 s after Wi-Fi connects (statuses first, books one at a time, 50 MB kept free) or Download Queue Now. A sent status sticks after a refresh. Clock mark on queued covers; BookOrbit · Queue shelf. No timers, no polling; sleep pauses it. * Up Next shelf: the next book in every series you've started. * Covers show BookOrbit's reading status and progress (Bookshelf's own badges) for books not on the device. * Remove Finished Books (Downloads, Not Opened For) and a Finished Books select in Bulk Remove. Bulk Remove on every Book Page. * Hero: Status button for a quick Reading Status; Remove Queue on a queued book. * Settings regrouped: Shelves, Books, Downloads, Look, Offline, Footer, Advanced, Help. Always on: Add To Collection, Reading Status, Bulk Download / Remove (under More… in a book's menu). Single choices for Flash, Hero Buttons, Close X, Home Button, Next Book In Series (Off / Ask / Add To Queue), read from the 1.x settings: nothing you set is changed, and 1.2.x still loads them. * Help at the bottom of Tools › OrbitShelf (Getting Started … What's New, newest version first), each topic in a window sized to it; What's New pops up once after the update. * Bigger footer critter. * Waking to Simple UI's home (its Start With Home Screen) with Bookshelf left open closes Bookshelf under the home, so it no longer pops up by itself when Wi-Fi connects. * Fix: paging a series strip past the book shown jumped back to the books around it, so a long series' later books never showed. * Clean-up: the start-up environment lines (versions, patches, plugins) only with Diagnostics on; unused code removed.

## 1.2.26 (2026-11-11)
- Shelf > Mark Style for the Not On Device mark: Auto (the default) draws it black on a light cover corner and white on a dark one, with a thin outline in the other colour so it reads on a busy corner too; Badge puts it on a small round disc in Bookshelf's badge colours, like its page-count pill. Night mode keeps the contrast either way.

## 1.2.25 (2026-11-11)
- Two new options, both off by default: Shelf > Mark Books Not On Device: BookOrbit's download mark (the Side Panel's) on the bottom-left of a BookOrbit cover whose book isn't on the device; books on the device stay as they are. The page count keeps the bottom-right. Covers view only; it follows Bookshelf's Cover badge size. A book with Bookshelf's reading mark or progress bar (they start bottom-left too) gets it just above them. A download or a removal shows on the next redraw. A book is known by its bookorbit:// address, which Bookshelf keeps when it rebuilds the record; turning the option on or off redraws every cover (Bookshelf's kept pages are dropped). With Diagnostics on, the first covers it decides on are logged. Footer > Home Button: a house in the footer corner opposite the close X / hamburger, back to page 1. Home Goes To: This Shelf (page 1 of whichever shelf you're on) or a shelf you pick (always its page 1). Inside a folder or group it comes back out to the shelf; already there, nothing redraws. Not shown while selecting books, or when Bookshelf's full-screen grid button has that corner.

## 1.2.24 (2026-11-10)
- New Extras menu, every option off by default: Bulk Download: hold a book that isn't on the device (or the hero), Bulk Download… lists that shelf's books not on the device, the held one ticked; Select… ticks All, Same Series, Same Author or None. A size and free-space check comes first (too big: says so and stops), then they download one at a time ("Downloading 3 of 12"), the shelf redraws once at the end and a popup lists any that failed. The row reads Stop Bulk Download while it runs. Wi-Fi off stops it (popup); sleep pauses it and waking asks whether to continue. Bulk Remove: the same list for the shelf's books on the device (from the hero or Bookshelf's book menu), one question, then removed; they stay in BookOrbit. Reading Status: Want To Read / Reading / On Hold / Read / Abandoned / Unread, set in BookOrbit from the hold menus and the book menu. Next In Series: finishing a BookOrbit book remembers the next one in its series when it isn't on the device; back on the home screen one question offers to download it (nothing pops up in the book). Shelf editor: Show All Books, On Device or Not On Device. A book moves between those shelves when it's downloaded or removed (a bulk download moves them all at the end). Downloads of 1.5 MB+ show their % in the corner note. Fix: OrbitShelf's BookOrbit calls now carry the device id, model and plugin version (BookOrbit's own settings when it's loaded), so the link after a download (match-check) works; the server answered 400 without them and the book wasn't linked for syncing. Bulk Download's size check asks BookOrbit's bulk manifest (100 books a call) instead of one call a book, and the Download row reads "Checking sizes…" meanwhile, so a second tap can't ask twice. Next In Series also asks when the book closes to Bookshelf (or anything full screen), and stays on top if Bookshelf or the home screen opens over it.

## 1.2.23 (2026-11-07)
- Spines: Series, Authors and Genres (and Group By shelves) stand as runs of their books' spines under each group's name, like Bookshelf's own Series shelf, instead of one face-out tile per group. Covers view is unchanged: groups are still folders there.

## 1.2.22 (2026-11-07)
- Spines for BookOrbit shelves, with a Bookshelf that offers them for fetch-mode sources (6.4, or its feat-588 test branch). Covers colour the spines, page counts set their thickness; folders stand face-out.

## 1.2.21 (2026-11-07)
- Footer critter stands on SimpleUI 3.0.3's ground shadow, like the home screen's.

## 1.2.20 (2026-11-06)
- Genres / Offline Library look books up two batches at a time (was three): about the same speed, less battery.

## 1.2.19 (2026-11-06)
- A new BookOrbit shelf is named after its list (Authors, Recently added, the collection's name …) instead of "BookOrbit", and the name follows when you change the list, as long as you haven't typed your own. Flash for popups now flashes only the popup's box, not the whole screen.

## 1.2.18 (2026-11-06)
- The BookOrbit source goes straight into Bookshelf's source list at start-up, without waiting for Bookshelf's window (older Bookshelf: as before). Background results keep every digit of a number, and a NaN or infinity no longer loses the whole result. The offline file is tidied after any run, not only after Offline Library. Diagnostics says how the source was registered.

## 1.2.17 (2026-11-06)
- Covers download in OrbitShelf's background worker (BookOrbit's runInSubprocess ran them on the screen's thread: a few seconds' freeze per batch of new covers). Saved lists moved from KOReader's settings to koreader/orbitshelf-lists.lua, written only when changed, when KOReader saves its settings; moved over once. A background refresh that finds the same list only updates its age. Worker checks every 0.5 s for the first 2 s, then every second. A shelf refresh, download or cover fetch cut off by sleep no longer stays blocked until a restart.

## 1.2.16 (2026-11-06)
- New Flash menu with every flash option, each off by default: Hero When It Changes (and how often), Shelf Page Turns (both moved from Hero and Shelf, settings kept), and new ones that flash a popup when it opens and closes: Book Description, Hold Menu (BookOrbit books), Download Window, Bookshelf's Book Menu, Shelf Editor. Bookshelf's two are hooked only once turned on.

## 1.2.15 (2026-11-06)
- Add To Collection: "Signing in…" and "Loading your collections…" show as a plain KOReader message. BookOrbit's loading pill (tinted by BookOrbit Tweaks' Pill Colour) stayed on the shelf as a blank bar until the shelf redrew; 1.2.14's extra refresh didn't clear it and is gone. Same as BookOrbit Tweaks 2.15.10.

## 1.2.14 (2026-11-06)
- Add To Collection: after typing the password, the collection list does one clean refresh, so no blank pill is left at the bottom of the screen. Same fix as BookOrbit Tweaks 2.15.9.

## 1.2.13 (2026-11-06)
- Menu: Return To (the shelf Bookshelf shows when it opens or a book closes: Bookshelf's Choice, the default, or one you pick), then Add To Collection, Offline Library, Hero, Shelf, Footer. Hero buttons: text centred on its capitals, and a long label is only shortened when the row doesn't fit (it used to get an equal share).

## 1.2.12 (2026-11-06)
- Add To Collection (setting, off by default): in the hero's hold menu and the Not On Device window. Signs in like the BookOrbit website, with the same messages, notice and saved password (encrypted) as BookOrbit Tweaks, and the same files, so the two share one login. With BookOrbit Tweaks 2.15.8 or newer installed, its picker opens.

## 1.2.11 (2026-11-06)
- Hero: the pills and the status line use the hero's own font (they were in the UI serif). The status line sits next to the stars only when the hero has a rating row; otherwise (list view) it sits right- aligned just above the buttons, inset from the frame edge. Cleanup: dead code, unused locals and duplicate helpers removed (Diagnostics uses the plugin's own checks); no change in behaviour.

## 1.2.10 (2026-11-06)
- Hero > Flash: Every Change / Every 4th / Every 6th (with Flash When It Changes on; Every Change, as before, by default), so most taps skip the slow full flash. A saved list over 30 minutes old shows at once and is refreshed in the background worker, redrawing the shelf only if it changed (it used to wait about 1 s on the network). Diagnostics count the saved lists under the right settings key (it always said 0).

## 1.2.9 (2026-11-06)
- Corner notes fit on one line: shorter wording, and anything over about 45 characters is cut with an ellipsis (the Group By note ran off the screen). Diagnostics time a tap on a book: the whole hero swap, and the hero column split into Bookshelf's own build and OrbitShelf's part (first 15, then slow ones), to find where taps feel sluggish.

## 1.2.8 (2026-11-06)
- Group By (shelf editor, off by default): a Library, Collection or Smart Scope shelf can show its own books as Series, Authors or Genres folders (only that list's books, ordered like the main Series / Authors / Genres shelves). None keeps the flat A to Z list. Changing List to a whole-library mode clears it.

## 1.2.7 (2026-11-06)
- Libraries: each BookOrbit library can be its own shelf (Library: <name>, in the shelf picker and the editor's List row), so a library per genre becomes a shelf per genre; saved for when Wi-Fi is off. Picking a library, collection or smart scope clears the others.

## 1.2.6 (2026-11-06)
- Smart Scopes: BookOrbit's smart scopes can be a shelf, picked like a collection (Smart Scope: <name>, in the shelf picker and the editor's List row); saved for when Wi-Fi is off. Downloads: the detail call, the download and the hash check run in OrbitShelf's background worker with a corner note, instead of BookOrbit's loading pill over the footer and a download on the screen's thread (the pill and the shelf glitched while it ran). Linking the file to BookOrbit runs in the worker too. A second tap on the same book doesn't start another. Shelf > Search BookOrbit (off by default): Bookshelf's search looks in BookOrbit instead of the device; results open like a folder ("BookOrbit: <query>"), back returns. Wi-Fi off: the saved library list is searched.

## 1.2.5 (2026-11-05)
- Reports: the start-up line now shows BookOrbit's version (read from its main.lua; it has none in _meta.lua), and the Diagnostics snapshot lists every OrbitShelf setting plus the saved library size, how many books Offline Library has saved, and whether a lookup run is going. No change to how OrbitShelf works.

## 1.2.4 (2026-11-05)
- Offline Library > Check For New Books: On Wi-Fi Connect (default, as before: at start and each Wi-Fi connect), On Refresh / Sync (the hero's Sync button or a swipe-down refresh on a BookOrbit shelf, with the library list pulled fresh), Both, or Update Now Only. A run cut short by Wi-Fi going off always finishes when it's back. README.md in the plugin folder.

## 1.2.3 (2026-11-05)
- Fix: scrolling a long Book Description crashed KOReader (the scrolling text had no window to refresh through). Fix: Genres / Offline Library lookups froze the screen. The background worker was only used when BookOrbit's own background_requests flag was on, which BookOrbit leaves off, so every lookup ran on the screen's thread (since the patch's 1.6.0; 1.5.10 did one book per tick). Now the worker is always used when KOReader can fork (Kobo, Kindle, PocketBook); where it can't, one book at a time with a turn for the screen in between. Book Description's lookup uses the worker too. _meta.lua no longer has the deprecated name line (KOReader warned about it).

## 1.2.2 (2026-11-05)
- Faster background lookups (Genres, Offline Library): 3 batches at once, each in its own worker, and the next starts as soon as one lands (no gap); about 3x faster on a full run. The shelf and the progress note update at most every 15 seconds while it runs, and once at the end, instead of after every batch. Diagnostics turned on after start now time the BookOrbit shelf loads too; the cover hit / miss counters that never counted are gone from its lines.

## 1.2.1 (2026-11-05)
- Hero > Button Size: Small (default, as before) / Medium / Large for the Download / Open In BookOrbit buttons and the round icons.

## 1.2.0 (2026-11-05)
- Book Description: holding (or tapping) a book that isn't on the device now also offers Book Description. It opens a compact window sized to the description (scrolls only past about 70% of the screen), closed by its X or a tap outside it. Uses the saved description (Offline Library) or looks it up once in the background; HTML in it is turned into plain text.

## 1.1.1 (2026-11-05)
- Diagnostics write to crash.log (tagged "orbitshelf 1.1.1 diag:") instead of diagnostics.log, which stays for the patches and the Debugging Menu.

## 1.1.0 (2026-11-05)
- Diagnostics moved into the plugin: Tools > OrbitShelf > Diagnostics (off by default). Same [orbitshelf] lines in koreader/diagnostics.log, 30 minutes after each start or after turning it on; turns itself off after 3 days. Only loaded while it's on. The diagnostics patch (2-zz-orbitshelf-tweaks-diagnostics.lua) is retired; if the old one is still installed it keeps logging and the plugin's stays off.

## 1.0.1 (2026-11-05)
- Everything off by default on a new install (BookOrbit source, Rewrite Stock chips, hero buttons, Sync, footer critter), so Bookshelf stays as it is until you turn things on. Saved settings are untouched; if you used the patch without ever changing a setting, you keep what the patch had on (and it's saved now).

## 1.0.0 (2026-11-05)
- OrbitShelf Tweaks 1.6.1 as a plugin. Same features and settings. Split into files, all well under 128 KB. Problems go to crash.log (see above), including which other patch or plugin changed what OrbitShelf relies on. Wi-Fi back and sleep come to the plugin directly. The old patch's history is in its own changelog (1.0.0 to 1.6.1, 2026-10-31 to 2026-11-05).
