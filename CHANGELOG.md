# OrbitShelf Changelog

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


## 2.0.1 (2026-11-15)

- First release of the OrbitShelf plugin line from the former OrbitShelf Tweaks patch.
