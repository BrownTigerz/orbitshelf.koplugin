-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Add To Collection without BookOrbit Tweaks.
--
-- BookOrbit's KOReader sign-in cannot change collections. From BookOrbit 3.8.0
-- an API key (Settings > You > API keys) can, with Read+Write access. This
-- module uses that key instead of the old website-password login.
--
-- With BookOrbit Tweaks installed, OrbitShelf still opens that patch's picker
-- when present; this file stays unused in that case.
local O = require("orbitshelf_core")
local _ = O._

local T = require("ffi/util").template
local LOGIN_FILE = "orbitshelf_api_key.lua"          -- encrypted key store (settings/)
local PLAIN_KEY_FILE = "orbitshelf_api_key.txt"      -- temp plain file for easy import
local KEYRING_FILE = "orbitshelf_api_keyring.lua"

-- Temp key file lives in the koreader folder (works on Kobo, Kindle, Android,
-- etc.). settings/ is still accepted as a fallback.
local function plainKeyPaths()
    local DS = require("datastorage")
    return {
        DS:getDataDir() .. "/" .. PLAIN_KEY_FILE,
        DS:getSettingsDir() .. "/" .. PLAIN_KEY_FILE,
    }
end

-- Write a clear template so the file explains itself.
-- force: rewrite even if present (menu "Create API Key File").
-- Returns the path, or nil on failure.
local function ensurePlainKeyTemplate(force)
    local path = plainKeyPaths()[1]
    if not path then return nil end
    if not force and lfs.attributes(path, "mode") == "file" then return path end
    local parent = path:match("^(.*)/[^/]+$")
    if parent then pcall(function() require("util").makePath(parent) end) end
    local f = io.open(path, "w")
    if not f then return nil end
    f:write([[
OrbitShelf / BookOrbit Tweaks — Temporary API Key File

This is a TEMPORARY file. It is only a way to get your BookOrbit API Key
onto the device without typing it on the device keyboard.

What happens:
1. Paste your API Key on the line marked ENTER API KEY HERE below.
2. Save this file and unplug the device.
3. On the device use Add To Collection (BookOrbit or OrbitShelf), or
   Tools > OrbitShelf > BookOrbit Sign-In > Set API Key…
4. The key is read from this file, saved ENCRYPTED on this device, and
   this file is deleted. After that, the only copy is the encrypted one.
5. OrbitShelf and BookOrbit Tweaks share the same encrypted key — enter once.
6. If you never sign in, nothing reads this file and the key stays here
   in plain text. Delete this file yourself if you change your mind.

Make the key on your PC in BookOrbit: Settings > You > API Keys > Create,
with Read And Write. It starts with bok_ and is shown only once.

ENTER API KEY HERE:

]])
    f:close()
    return path
end

-- Shared notification contract (same as Network Tweaks' other patches):
-- results follow Network Tweaks' style (Banner / Minimal / Normal), then
-- ReadMastery's, else a short KOReader note; never over the sleep screen.
-- Questions and failures always stay popups.
local function note(banner_text, minimal_text, timeout)
    timeout = timeout or 2
    local okd, Device = pcall(require, "device")
    if okd and Device.screen_saver_mode then return end
    local okn, NetworkMgr = pcall(require, "ui/network/manager")
    if okn and type(NetworkMgr) == "table" and type(NetworkMgr.__network_tweaks_note) == "function" then
        local ok, handled = pcall(NetworkMgr.__network_tweaks_note, banner_text, minimal_text, timeout)
        if ok and handled then return end
    end
    local rm = _G.__readmastery_note
    if type(rm) == "function" then
        local ok, handled = pcall(rm, banner_text or minimal_text, timeout)
        if ok and handled then return end
    end
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/infomessage"):new{ text = banner_text, timeout = timeout })
end
local function failure(text)
    local UIManager = require("ui/uimanager")
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

-- Menu: write the temp API key template (needs note/failure above).
local function writeTempKeyFile()
    local path = ensurePlainKeyTemplate(true)
    if not path then
        failure(_("Couldn't create koreader/orbitshelf_api_key.txt"))
        return
    end
    note(T(_("API key file ready:\n%1\n\nPaste your bok_ key on the ENTER API KEY HERE line, save, unplug, then use Add To Collection or Set API Key…"), path),
         _("Key file created"), 5)
end


-- Shown the first time and from the menu.
local SECURITY_TEXT = _([[
Add To Collection needs a BookOrbit API key.

• Why: BookOrbit's KOReader sign-in can read your library and sync, but it cannot change collections. An API key with Read and write access can.

• Create one: on the BookOrbit website go to Settings > You > API keys. Create a key, choose "Read and write", give it the permissions you want (or leave the defaults), and copy the key (it starts with bok_ and is shown only once).

• How to get it onto the device (typing a long key on an e-reader is hard):
  1. Easiest – over USB open koreader/orbitshelf_api_key.txt (OrbitShelf puts a ready template there). Paste the key on the marked line, save, unplug, then use Add To Collection or OrbitShelf → BookOrbit Sign-In. The key is imported, encrypted, and that temp file is deleted.
  2. Or open OrbitShelf > BookOrbit Sign-In > Set API Key… and paste / type the key (a USB keyboard or clipboard paste helps a lot).

• Storage: the key is encrypted (AES-256) in koreader/settings/orbitshelf_api_key.lua with the key material in orbitshelf_api_keyring.lua. That stops casual browsing of your files. It does not stop someone with full access to the device.

• Backups: those two files are excluded from Patch Backup & Restore and normal device backups.

• Shared with BookOrbit Tweaks: the same encrypted key is used by both if Tweaks is installed.

• Remove it anytime: OrbitShelf > BookOrbit Sign-In > Forget Saved API Key (or BookOrbit Tweaks > Forget Saved API Key).
]])

local Crypto = {}
do
    local ok_ffi, ffi = pcall(require, "ffi")
    local lib, cdef_done
    local function libcrypto()
        if lib ~= nil then return lib or nil end
        if not ok_ffi then lib = false return nil end
        local ok, res = pcall(function()
            if not cdef_done then
                cdef_done = true
                pcall(ffi.cdef, [[
                    typedef struct engine_st ENGINE;
                    typedef struct evp_cipher_st EVP_CIPHER;
                    typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
                    EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
                    void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *);
                    int EVP_EncryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
                    int EVP_EncryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
                    int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
                    int EVP_DecryptInit_ex(EVP_CIPHER_CTX *, const EVP_CIPHER *, ENGINE *, const unsigned char *, const unsigned char *);
                    int EVP_DecryptUpdate(EVP_CIPHER_CTX *, unsigned char *, int *, const unsigned char *, int);
                    int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *, unsigned char *, int *);
                    const EVP_CIPHER *EVP_aes_256_cbc(void);
                    int RAND_bytes(unsigned char *, int);
                ]])
            end
            if ffi.loadlib then return ffi.loadlib("crypto", "57") end
            local okl, l = pcall(ffi.load, "libs/libcrypto.so.57")
            if okl and l then return l end
            return ffi.load("crypto")
        end)
        lib = ok and res or false
        return lib or nil
    end
    local function hex(s)
        return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    end
    local function unhex(h)
        if type(h) ~= "string" or #h % 2 ~= 0 then return nil end
        return (h:gsub("..", function(cc) return string.char(tonumber(cc, 16) or 0) end))
    end
    local function key()
        local path = require("datastorage"):getSettingsDir() .. "/" .. KEYRING_FILE
        local s = require("luasettings"):open(path)
        local k = s:readSetting("k")
        if type(k) == "string" and #k == 64 then return unhex(k) end
        local L = libcrypto()
        if not L then return nil end
        local buf = ffi.new("unsigned char[32]")
        if L.RAND_bytes(buf, 32) ~= 1 then return nil end
        local raw = ffi.string(buf, 32)
        s:saveSetting("k", hex(raw))
        s:flush()
        return raw
    end
    local function cipher(encrypt, k, iv, data)
        local L = libcrypto()
        if not L then return nil end
        local ctx = L.EVP_CIPHER_CTX_new()
        if ctx == nil then return nil end
        local ok, res = pcall(function()
            local c = L.EVP_aes_256_cbc()
            if encrypt then
                if L.EVP_EncryptInit_ex(ctx, c, nil, k, iv) ~= 1 then error("init") end
            else
                if L.EVP_DecryptInit_ex(ctx, c, nil, k, iv) ~= 1 then error("init") end
            end
            local out = ffi.new("unsigned char[?]", #data + 32)
            local outl = ffi.new("int[1]")
            local finall = ffi.new("int[1]")
            if encrypt then
                if L.EVP_EncryptUpdate(ctx, out, outl, data, #data) ~= 1 then error("upd") end
                if L.EVP_EncryptFinal_ex(ctx, out + outl[0], finall) ~= 1 then error("fin") end
            else
                if L.EVP_DecryptUpdate(ctx, out, outl, data, #data) ~= 1 then error("upd") end
                if L.EVP_DecryptFinal_ex(ctx, out + outl[0], finall) ~= 1 then error("fin") end
            end
            return ffi.string(out, outl[0] + finall[0])
        end)
        L.EVP_CIPHER_CTX_free(ctx)
        return ok and res or nil
    end
    function Crypto.encrypt(plain)
        if type(plain) ~= "string" or plain == "" then return nil end
        local ok, res = pcall(function()
            local L = libcrypto()
            if not L then return nil end
            local ivbuf = ffi.new("unsigned char[16]")
            if L.RAND_bytes(ivbuf, 16) ~= 1 then return nil end
            local iv = ffi.string(ivbuf, 16)
            local k = key()
            if not k then return nil end
            local ct = cipher(true, k, iv, plain)
            if not ct then return nil end
            return hex(iv .. ct)
        end)
        return ok and res or nil
    end
    function Crypto.decrypt(blob)
        if type(blob) ~= "string" then return nil end
        local ok, res = pcall(function()
            local raw, k = unhex(blob), key()
            if not (raw and k and #raw > 16) then return nil end
            return cipher(false, k, raw:sub(1, 16), raw:sub(17))
        end)
        return ok and res or nil
    end
end

local function loginStore()
    return require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/" .. LOGIN_FILE)
end

-- One storage key per server: strip trailing slash so Set API Key and
-- Add To Collection share the same entry.
local function normalizeServer(server)
    if type(server) ~= "string" or server == "" then return nil end
    server = server:match("^%s*(.-)%s*$") or server
    server = server:gsub("/+$", "")
    return server ~= "" and server or nil
end

-- server_url -> raw API key (in memory only after load)
local key_cache = {}

local function forgetKey(server)
    if server then
        server = normalizeServer(server) or server
        key_cache[server] = nil
        key_cache[server .. "/"] = nil
        local s = loginStore()
        s:delSetting(server)
        s:delSetting(server .. "/")
        -- also drop any key whose normalized form matches
        for k in pairs(s.data or {}) do
            if normalizeServer(k) == server then s:delSetting(k) end
        end
        s:flush()
    else
        key_cache = {}
        local s = loginStore()
        for k in pairs(s.data or {}) do s:delSetting(k) end
        s:flush()
    end
end

local function saveKey(server, key)
    server = normalizeServer(server)
    if not server or type(key) ~= "string" or key == "" then return false end
    key = key:match("^%s*(.-)%s*$") or key
    if not key:match("^bok_") then
        -- still accept it; the server will reject if wrong
    end
    local enc = Crypto.encrypt(key)
    if not enc then
        -- fall back to storing the key in the settings file unencrypted when crypto is missing
        local s = loginStore()
        s:saveSetting(server, { key = key, plain = true })
        s:flush()
        key_cache[server] = key
        return true
    end
    local s = loginStore()
    s:saveSetting(server, { key_enc = enc })
    s:flush()
    key_cache[server] = key
    return true
end

local function loadKey(server)
    server = normalizeServer(server)
    if not server then return nil end
    if key_cache[server] then return key_cache[server] end
    local saved = loginStore():readSetting(server)
    -- fallback: same URL with/without trailing slash written by an older build
    if type(saved) ~= "table" then
        local alt = loginStore():readSetting(server .. "/")
        if type(alt) == "table" then saved = alt end
    end
    if type(saved) ~= "table" then
        for k, v in pairs(loginStore().data or {}) do
            if normalizeServer(k) == server and type(v) == "table" then saved = v break end
        end
    end
    if type(saved) ~= "table" then return nil end
    local key
    if type(saved.key_enc) == "string" then
        key = Crypto.decrypt(saved.key_enc)
    elseif type(saved.key) == "string" and saved.plain then
        key = saved.key
    end
    if type(key) == "string" and key ~= "" then
        key_cache[server] = key
        return key
    end
    return nil
end

-- Import a plain-text key file if present (easy transfer from a computer).
-- Looks in koreader/ first, then settings/. File is deleted after a successful import.
local function tryImportPlainKey(server)
    for _i, path in ipairs(plainKeyPaths()) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a") or ""
            f:close()
            -- skip pure template (only comments / placeholder)
            local key = content:match("(bok_[%w%-_]+)")
            if key and #key >= 20 and key ~= "bok_" then
                if saveKey(server, key) then
                    pcall(os.remove, path)
                    -- also clear the other candidate path so a leftover isn't re-imported
                    for _j, other in ipairs(plainKeyPaths()) do
                        if other ~= path then pcall(os.remove, other) end
                    end
                    note(_("API key imported from the temp file and encrypted. The temp file was removed."), _("Key imported"))
                    return key
                end
            end
        end
    end
    return nil
end

local function getApiKey(server, force_ask)
    server = normalizeServer(server)
    if not server then return nil end
    if not force_ask then
        local k = loadKey(server)
        if k then return k end
        k = tryImportPlainKey(server)
        if k then return k end
        -- single saved key on device: reuse it (common when Set API Key and
        -- the catalog client disagree slightly on the URL string)
        local s = loginStore()
        local found, n = nil, 0
        for srv in pairs(s.data or {}) do
            local kk = loadKey(srv)
            if kk then n = n + 1 found = kk end
        end
        if n == 1 and found then
            key_cache[server] = found
            return found
        end
    end
    return nil
end

-- Ask the user for an API key (or re-ask after a 401).
local function askForKey(server, done)
    ensurePlainKeyTemplate()
    local UIManager = require("ui/uimanager")
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dlg
    dlg = MultiInputDialog:new{
        title = _("BookOrbit API Key"),
        description = _("Paste or type a key that starts with bok_.\n\nEasier over USB: put the key in koreader/orbitshelf_api_key.txt (a temp file OrbitShelf creates there). After you continue, it is imported, encrypted, and that file is deleted."),
        fields = {
            { text = "", hint = _("bok_…"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local f = dlg:getFields()
                UIManager:close(dlg)
                local key = f[1] and f[1]:match("^%s*(.-)%s*$")
                if key and key ~= "" then
                    if saveKey(server, key) then
                        -- drop any leftover temp import files
                        for _i, path in ipairs(plainKeyPaths()) do pcall(os.remove, path) end
                        note(_("API key saved on this device (encrypted)."), _("Key saved"))
                        if done then done(key) end
                    else
                        failure(_("Couldn't save the API key."))
                    end
                end
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

-- Obtain a usable key; ask once if missing.
local function ensureKey(catalog, done, force_ask)
    local client = catalog and catalog.client
    local server = client and client.server_url
    if not server then return end
    local key = getApiKey(server, force_ask)
    if key then return done(key) end

    ensurePlainKeyTemplate()
    local UIManager = require("ui/uimanager")
    if G_reader_settings and not G_reader_settings:isTrue("orbitshelf_api_key_notice_seen") then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = SECURITY_TEXT,
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                G_reader_settings:saveSetting("orbitshelf_api_key_notice_seen", true)
                -- try the temp file again in case they filled it while reading this
                local k2 = tryImportPlainKey(server)
                if k2 then return done(k2) end
                askForKey(server, done)
            end,
        })
        return
    end
    askForKey(server, done)
end

-- One authorised call. A 401 clears the key and asks again once.
local function apiCall(catalog, label, method, path, body, done, retried)
    ensureKey(catalog, function(key)
        local res, err = catalog:fetch(label, function()
            return catalog.client:requestBlocking(method, path, body, {
                ["Authorization"] = "Bearer " .. key,
            })
        end)
        if err == 401 and not retried then
            local server = catalog.client and catalog.client.server_url
            if server then forgetKey(server) end
            return apiCall(catalog, label, method, path, body, done, true)
        end
        done(res, err)
    end, retried)
end

local showCollections
showCollections = function(catalog, detail)
    local book_id = detail and tonumber(detail.id)
    if not book_id then return end
    local UIManager = require("ui/uimanager")
    catalog:runConnected(function()
        apiCall(catalog, _("Loading your collections…"), "GET", "/collections?bookIds=" .. book_id, nil, function(list, err)
            if type(list) ~= "table" then
                if err ~= "cancelled" then failure(T(_("Couldn't load your BookOrbit collections:\n%1"), tostring(err))) end
                return
            end
            local ButtonDialog = require("ui/widget/buttondialog")
            local dlg
            local buttons = {}
            for _i, c in ipairs(list) do
                if type(c) == "table" and c.id and c.isOwner ~= false then
                    local inside = (tonumber(c.memberCount) or 0) > 0
                    buttons[#buttons + 1] = {{
                        text = (inside and "\u{2713} " or "") .. tostring(c.name or c.id),
                        callback = function()
                            UIManager:close(dlg)
                            apiCall(catalog, inside and _("Removing…") or _("Adding…"),
                                inside and "DELETE" or "POST", "/collections/" .. c.id .. "/books",
                                { bookIds = { book_id } }, function(res, e)
                                    if res == nil and e ~= nil then
                                        if e ~= "cancelled" then failure(T(_("Couldn't change the collection:\n%1"), tostring(e))) end
                                        return
                                    end
                                    if catalog.markStackDirty then pcall(catalog.markStackDirty, catalog) end
                                    local msg = T(inside and _("Removed from %1") or _("Added to %1"), tostring(c.name))
                                    note(msg, inside and _("Removed") or _("Added"))
                                end)
                        end,
                    }}
                end
            end
            buttons[#buttons + 1] = {{
                text = _("New Collection…"),
                callback = function()
                    UIManager:close(dlg)
                    local InputDialog = require("ui/widget/inputdialog")
                    local input
                    input = InputDialog:new{
                        title = _("New collection"),
                        input = "",
                        input_hint = _("Name"),
                        buttons = {{
                            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                            { text = _("Create"), is_enter_default = true, callback = function()
                                local name = input:getInputText()
                                UIManager:close(input)
                                if not name or name == "" then return end
                                apiCall(catalog, _("Creating…"), "POST", "/collections", { name = name, icon = "library" }, function(made, e)
                                    if type(made) ~= "table" or not made.id then
                                        if e ~= "cancelled" then failure(T(_("Couldn't create the collection:\n%1"), tostring(e))) end
                                        return
                                    end
                                    apiCall(catalog, _("Adding…"), "POST", "/collections/" .. made.id .. "/books", { bookIds = { book_id } }, function(res, e2)
                                        if res == nil and e2 ~= nil then
                                            if e2 ~= "cancelled" then failure(T(_("Made %1, but couldn't add the book:\n%2"), name, tostring(e2))) end
                                            return
                                        end
                                        note(T(_("Added to %1"), name), _("Added"))
                                    end)
                                end)
                            end },
                        }},
                    }
                    UIManager:show(input)
                    input:onShowKeyboard()
                end,
            }}
            dlg = ButtonDialog:new{
                title = T(_("Collections · %1"), tostring(detail.title or "")),
                title_align = "center",
                buttons = buttons,
            }
            UIManager:show(dlg)
        end)
    end)
end

-- Exclude the encrypted key files from Patch Backup & Restore.
do
    local BK = package.loaded.backup_patches or { targets = {} }
    package.loaded.backup_patches = BK
    if type(BK.addSecrets) == "function" then
        pcall(BK.addSecrets, { files = { LOGIN_FILE, KEYRING_FILE } })
    else
        BK.secrets = BK.secrets or { files = {}, folders = {}, keys = {} }
        BK.secrets.files = BK.secrets.files or {}
        BK.secrets.files[LOGIN_FILE] = true
        BK.secrets.files[KEYRING_FILE] = true
    end
end

-- Outside BookOrbit's own pages (OrbitShelf's Bookshelf menus) BookOrbit's loading
-- pill isn't cleared by the shelf underneath: it stayed at the bottom as a blank
-- bar (tinted by Pill Colour) until the shelf redrew. There the wait shows as a
-- plain KOReader message instead, which closes cleanly; the request is the same.
local function shelfCatalog(client, Catalog)
    local shim = setmetatable({ client = client }, { __index = Catalog })
    shim.fetch = function(self, text, fn, opts)
        if type(opts) == "table" and opts.invisible then return Catalog.fetch(self, text, fn, opts) end
        local UIManager = require("ui/uimanager")
        local msg = require("ui/widget/infomessage"):new{ text = text or _("Loading…"), dismissable = false }
        UIManager:show(msg)
        UIManager:forceRePaint()
        -- closed whatever happens, so it can't be left behind either
        local res = { pcall(Catalog.fetch, self, text, fn, { invisible = true }) }
        UIManager:close(msg)
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, 4)
    end
    return shim
end

-- The picker for a book: a BookOrbit API client wrapped over BookOrbit's own
-- catalog (fetch / runConnected), like BookOrbit Tweaks does.
O.Collections = {
    show = function(client, book_id, title)
        local okC, Catalog = pcall(require, "bookorbit_catalog")
        if not (okC and type(Catalog) == "table" and type(client) == "table" and tonumber(book_id)) then
            return false
        end
        showCollections(shelfCatalog(client, Catalog), { id = tonumber(book_id), title = title })
        return true
    end,
    hasSaved = function()
        local okl, st = pcall(loginStore)
        return okl and type(st.data) == "table" and next(st.data) ~= nil
    end,
    forget = function()
        forgetKey()
        G_reader_settings:delSetting("orbitshelf_api_key_notice_seen")
        note(_("Saved BookOrbit API key removed from this device."), _("API key forgotten"))
    end,
    about = function()
        local Screen = require("device").screen
        local TextViewer = require("ui/widget/textviewer")
        local width = math.floor(Screen:getWidth() * 0.88)
        local max_h = math.floor(Screen:getHeight() * 0.8)
        require("ui/uimanager"):show(TextViewer:new{
            title = _("About The API Key"),
            text = SECURITY_TEXT,
            width = width,
            height = max_h,
        })
    end,
    writeTempKeyFile = writeTempKeyFile,
    -- Explicit entry point so the menu can open the key dialog without a book
    setKey = function(client)
        local server = client and client.server_url
            or (G_reader_settings and G_reader_settings:readSetting("bookorbit") or {}).server_url
        if not server then
            failure(_("BookOrbit is not signed in, so there is no server address to attach the key to."))
            return
        end
        -- already have a key for this (or any) server: don't open a blank entry dialog
        if loadKey(server) or (next(loginStore().data or {}) ~= nil) then
            note(_("API key is active on this device (encrypted).\n\nTo use a different key: Forget Saved API Key, then Set API Key… or Create API Key File."),
                 _("API key active"), 4)
            return
        end
        -- try import first (in case the temp file was filled over USB)
        local imported = tryImportPlainKey(server)
        if imported then return end
        askForKey(server)
    end,
}
return O
