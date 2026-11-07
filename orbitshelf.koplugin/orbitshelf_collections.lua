-- Part of the OrbitShelf plugin (orbitshelf.koplugin); see main.lua.
-- Add To Collection without BookOrbit Tweaks.
--
-- BookOrbit's KOReader sign-in can't change collections; only the website sign-in
-- can. This is BookOrbit Tweaks' own Add To Collection (2.15.8), with the same
-- messages, sign-in box, notice and saved-password files, so the two share one
-- login: save it in either and the other uses it. With BookOrbit Tweaks installed,
-- OrbitShelf opens that patch's picker instead and this one stays unused.
local O = require("orbitshelf_core")
local _ = O._

local T = require("ffi/util").template
local LOGIN_FILE = "bookorbit_tweaks_login.lua"

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

-- Shown before the password is first asked for, and from the menu.
local SECURITY_TEXT = _([[
Add To Collection needs your BookOrbit password.

• Why: BookOrbit's KOReader sign-in can read your library and sync, but it can't change collections. Only the web sign-in can, the same one the BookOrbit website uses.
• Where it goes: only to your own BookOrbit server's sign-in, over the server address you set in BookOrbit. Nothing is sent anywhere else.
• While KOReader runs: the server's session key is kept in memory for 10 minutes, then it signs in again. Nothing about the session is written to disk.
• If you save it: it's encrypted (AES-256) in koreader/settings/bookorbit_tweaks_login.lua, with the key in a separate file, bookorbit_tweaks_keyring.lua. That stops someone casually browsing your files. It does not stop someone with full access to the e-reader, because the key is on the same device.
• Backups: neither file goes into Patch Backup & Restore's backups or device backups.
• Remove it anytime: OrbitShelf > Add To Collection > Forget Saved BookOrbit Password (or BookOrbit Tweaks' own).
If you'd rather not keep it, untick Save Password in the sign-in box: you'll be asked again after 10 minutes or a restart. Only a sign-in BookOrbit accepts is ever saved.]])
local KEYRING_FILE = "bookorbit_tweaks_keyring.lua"

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
        lib = (ok and res) or false
        return lib or nil
    end
    local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
    local function unhex(s)
        if type(s) ~= "string" or not s:match("^%x*$") or #s % 2 ~= 0 then return nil end
        return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
    end
    local function rand(l, n)
        local buf = ffi.new("unsigned char[?]", n)
        if l.RAND_bytes(buf, n) ~= 1 then return nil end
        return ffi.string(buf, n)
    end
    local function cipher(encrypt, key, iv, input)
        local l = libcrypto()
        if not l then return nil end
        local ctx = l.EVP_CIPHER_CTX_new()
        if ctx == nil then return nil end
        local init = encrypt and l.EVP_EncryptInit_ex or l.EVP_DecryptInit_ex
        local update = encrypt and l.EVP_EncryptUpdate or l.EVP_DecryptUpdate
        local final = encrypt and l.EVP_EncryptFinal_ex or l.EVP_DecryptFinal_ex
        local out, out_len
        local ok = init(ctx, l.EVP_aes_256_cbc(), nil, key, iv) == 1
        if ok then
            out = ffi.new("unsigned char[?]", #input + 16)
            local n1, n2 = ffi.new("int[1]"), ffi.new("int[1]")
            ok = update(ctx, out, n1, input, #input) == 1 and final(ctx, out + n1[0], n2) == 1
            if ok then out_len = n1[0] + n2[0] end
        end
        l.EVP_CIPHER_CTX_free(ctx)
        return ok and ffi.string(out, out_len) or nil
    end
    local function key()
        local l = libcrypto()
        if not l then return nil end
        local s = require("luasettings"):open(require("datastorage"):getSettingsDir() .. "/" .. KEYRING_FILE)
        local k = unhex(s:readSetting("aes_key"))
        if k and #k == 32 then return k end
        k = rand(l, 32)
        if not k then return nil end
        s:saveSetting("aes_key", hex(k))
        s:flush()
        return k
    end
    function Crypto.encrypt(plain)
        local ok, res = pcall(function()
            local k = key()
            local l = libcrypto()
            local iv = k and rand(l, 16)
            local c = iv and cipher(true, k, iv, plain)
            return c and hex(iv .. c) or nil
        end)
        return ok and res or nil
    end
    function Crypto.decrypt(blob)
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

-- server url -> { token, until }: the web session, in memory only
local web_sessions = {}

-- the website username last signed in with (kept with a saved password,
-- else for this session), to fill in next time
local typed_users = {}
local function last_web_user(server)
    local saved = loginStore():readSetting(server)
    if type(saved) == "table" and type(saved.username) == "string" then return saved.username end
    return typed_users[server]
end

local function forgetLogin(server)
    web_sessions[server] = nil
    local s = loginStore()
    local saved = s:readSetting(server)
    if type(saved) == "table" and type(saved.username) == "string" then typed_users[server] = saved.username end
    s:delSetting(server)
    s:flush()
end

-- Signs in the way the web app does and hands the access token to done().
-- Uses a saved password when there is one; otherwise asks, then offers to
-- save it.
local function webSignIn(catalog, done, ask)
    local client = catalog.client
    local server = client and client.server_url
    if not server then return end
    local cached = web_sessions[server]
    if not ask and cached and cached.token and os.time() < cached["until"] then return done(cached.token) end

    local UIManager = require("ui/uimanager")
    -- typed: from the sign-in box (else the saved password); save: its
    -- Save Password tick. Only a sign-in the server accepted gets saved.
    local function login(username, password, typed, save)
        local body, err = catalog:fetch(_("Signing in to BookOrbit…"), function()
            return client:requestBlocking("POST", "/auth/login",
                { username = username, password = password, clientKind = "native", deviceLabel = "KOReader" })
        end)
        if not (type(body) == "table" and type(body.accessToken) == "string") then
            if err == "cancelled" then return end
            if not typed then forgetLogin(server) end -- a saved password that no longer works
            failure(err == 401 and _("BookOrbit didn't accept that username or password.\n\nUse the login you sign in to the BookOrbit website with. Your KOReader sync username can be different.") or T(_("Couldn't sign in to BookOrbit:\n%1"), tostring(err)))
            if not typed then return webSignIn(catalog, done, true) end
            return
        end
        web_sessions[server] = { token = body.accessToken, ["until"] = os.time() + 10 * 60 }
        typed_users[server] = username
        if typed and save then
            local enc = Crypto.encrypt(password)
            if enc then
                local st = loginStore()
                st:saveSetting(server, { username = username, password_enc = enc })
                st:flush()
                note(_("Signed in. Password saved on this device (encrypted)."), _("Password saved"))
            else
                -- never kept in plain text
                failure(_("Signed in, but encryption isn't available on this device, so the password wasn't saved. You'll be asked for it again after a restart."))
            end
        end
        return done(body.accessToken)
    end

    if not ask then
        local saved = loginStore():readSetting(server)
        local password = type(saved) == "table" and Crypto.decrypt(saved.password_enc)
        if password then return login(saved.username, password, false, false) end
    end
    local function askPassword()
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local CheckButton = require("ui/widget/checkbutton")
    local dlg, save_box
    dlg = MultiInputDialog:new{
        title = _("Sign in to BookOrbit"),
        description = _("Your BookOrbit website login (not your KOReader sync name)."),
        fields = {
            -- not the sync username: that's a separate account and often a
            -- different name, which made the right password fail
            { text = last_web_user(server) or "", hint = _("Website username") },
            { text = "", hint = _("Password"), text_type = "password" },
        },
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Sign In"), is_enter_default = true, callback = function()
                local f = dlg:getFields()
                local save = save_box and save_box.checked or false
                UIManager:close(dlg)
                if f[1] ~= "" and f[2] ~= "" then login(f[1], f[2], true, save) end
            end },
        }},
    }
    -- ticked or not, nothing is saved until the server accepts the sign-in;
    -- the choice is remembered for next time
    save_box = CheckButton:new{
        text = _("Save password on this device (encrypted)"),
        checked = not (G_reader_settings and G_reader_settings:isFalse("bookorbit_tweaks_save_password")),
        parent = dlg,
        callback = function()
            if G_reader_settings then
                G_reader_settings:saveSetting("bookorbit_tweaks_save_password", save_box.checked and true or false)
            end
        end,
    }
    dlg:addWidget(save_box)
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    end
    -- The first time on this device (and after Forget): what happens to the
    -- password, before it's typed.
    if G_reader_settings and not G_reader_settings:isTrue("bookorbit_tweaks_password_notice_seen") then
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = SECURITY_TEXT,
            ok_text = _("Continue"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                G_reader_settings:saveSetting("bookorbit_tweaks_password_notice_seen", true)
                askPassword()
            end,
        })
        return
    end
    askPassword()
end

-- One authorised call; a session the server turned down signs in again once.
local function webCall(catalog, label, method, path, body, done, retried)
    webSignIn(catalog, function(token)
        local res, err = catalog:fetch(label, function()
            return catalog.client:requestBlocking(method, path, body, { ["Authorization"] = "Bearer " .. token })
        end)
        if err == 401 and not retried then
            web_sessions[catalog.client.server_url] = nil
            return webCall(catalog, label, method, path, body, done, true)
        end
        done(res, err)
    end)
end

local showCollections
showCollections = function(catalog, detail)
    local book_id = detail and tonumber(detail.id)
    if not book_id then return end
    local UIManager = require("ui/uimanager")
    catalog:runConnected(function()
        webCall(catalog, _("Loading your collections…"), "GET", "/collections?bookIds=" .. book_id, nil, function(list, err)
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
                            webCall(catalog, inside and _("Removing…") or _("Adding…"),
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
                        buttons = {{
                            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                            { text = _("Create"), is_enter_default = true, callback = function()
                                local name = (input:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                                UIManager:close(input)
                                if name == "" then return end
                                webCall(catalog, _("Creating…"), "POST", "/collections", { name = name, icon = "library" }, function(made, e)
                                    if type(made) ~= "table" or not made.id then
                                        if e ~= "cancelled" then failure(T(_("Couldn't create the collection:\n%1"), tostring(e))) end
                                        return
                                    end
                                    webCall(catalog, _("Adding…"), "POST", "/collections/" .. made.id .. "/books", { bookIds = { book_id } }, function(res, e2)
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

-- Saved password and its key: never in Patch Backup & Restore's backups.
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
        local okl, st = pcall(loginStore)
        if okl then
            for k in pairs(st.data) do st:delSetting(k) end
            st:flush()
        end
        for k in pairs(web_sessions) do web_sessions[k] = nil end
        G_reader_settings:delSetting("bookorbit_tweaks_password_notice_seen")
        note(_("Saved BookOrbit password removed from this device."), _("Password forgotten"))
    end,
    about = function()
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{ text = SECURITY_TEXT })
    end,
}
return O
