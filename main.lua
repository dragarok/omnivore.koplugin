--[[--
Omnivore for KOReader.

Two-way sync between KOReader and an Omnivore library (self-hosted or hosted):
downloads articles, sends highlights, notes and reading progress back, archives what you
finish, and lets you browse, save and manage your library from the device.

Based on omnivore.koplugin by Jamie (fairlygood), MIT licence.

@module koplugin.omnivore
]]

local BD = require("ui/bidi")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local Event = require("ui/event")
local FileManager = require("apps/filemanager/filemanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local Menu = require("ui/widget/menu")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local N_ = _.ngettext
local T = ffiUtil.template

local Locator = require("highlightlocator")
local OmnivoreAPI = require("omnivoreapi")
local str, num, tbl = OmnivoreAPI.str, OmnivoreAPI.num, OmnivoreAPI.tbl

local DEFAULTS = {
    server_url = "",
    api_key = "",
    directory = nil,            -- nil: <home folder>/Omnivore
    filter = "inbox",           -- "inbox" | "label" | "query"
    filter_label = "",
    filter_query = "",
    articles_per_sync = 20,
    download_images = true,
    archive_finished = true,    -- archive in Omnivore when marked as finished in KOReader
    archive_read = false,       -- ... or when read to the end
    after_archive = "delete",   -- local copy after archiving: "delete" | "move" | "keep"
    send_progress = true,
    send_highlights = true,
    send_on_close = true,       -- send progress and highlights as soon as an article is closed
}

local VIEWS = {
    { text = _("Inbox"), query = "in:inbox sort:saved-desc" },
    { text = _("Continue reading"), query = "in:inbox is:reading sort:read-desc" },
    { text = _("Unread"), query = "in:inbox is:unread sort:saved-desc" },
    { text = _("With highlights"), query = "in:all has:highlights sort:saved-desc" },
    { text = _("Archive"), query = "in:archive sort:saved-desc" },
}

local CSS = [[
.omnivore-header { margin: 0 0 1.5em 0; padding: 0 0 0.6em 0; border-bottom: 1px solid #999; }
.omnivore-header h1 { margin: 0 0 0.3em 0; font-size: 1.5em; line-height: 1.2; text-align: left; hyphens: none; }
.omnivore-meta { margin: 0.15em 0; font-size: 0.85em; color: #555; text-indent: 0; text-align: left; }
img { max-width: 100%; height: auto; }
figure { margin: 1em 0; }
figcaption { font-size: 0.85em; color: #555; }
pre { white-space: pre-wrap; font-size: 0.85em; }
]]

local KO_TO_OMNIVORE_COLOR = {
    yellow = "yellow", red = "red", orange = "red", green = "green", olive = "green",
    cyan = "blue", blue = "blue", purple = "blue",
}

-- Settings and sync state are shared by the file browser and reader instances of the plugin.
local settings_store, state_store

local function settingsStore()
    if not settings_store then
        settings_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/omnivore.lua")
    end
    return settings_store
end

local function stateStore()
    if not state_store then
        state_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/omnivore_state.lua")
    end
    return state_store
end

--- Downloaded articles, keyed by Omnivore id:
-- { path, title, slug, url, progress_sent, archived, hl = { [key] = { id, note } } }
local function articles()
    local data = stateStore().data
    data.articles = data.articles or {}
    return data.articles
end

--- Actions waiting for the network: { type = "save" | "archive" | "delete", url | id, title }
local function queue()
    local data = stateStore().data
    data.queue = data.queue or {}
    return data.queue
end

local function saveState()
    stateStore():flush()
end

local function fileExists(path)
    return type(path) == "string" and lfs.attributes(path, "mode") == "file"
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isoUTC(t)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", t)
end

local function ago(t)
    if not t then return _("never") end
    local d = os.time() - t
    if d < 90 then return _("just now") end
    if d < 3600 then return T(_("%1 min ago"), math.floor(d / 60)) end
    if d < 86400 then return T(_("%1 h ago"), math.floor(d / 3600)) end
    return T(N_("1 day ago", "%1 days ago", math.floor(d / 86400)), math.floor(d / 86400))
end

local function errorText(kind, detail)
    if kind == "network" then
        return _("Couldn't reach the Omnivore server.\n\nCheck that you're online (and connected to your VPN, if the server needs one) and that the server address is right.")
    elseif kind == "auth" then
        if detail == "not configured" then
            return _("Omnivore isn't set up yet. Add your server address and API key in Omnivore → Settings.")
        end
        return _("The server didn't accept the API key.\n\nCheck it in Omnivore → Settings → Server and API key. Keys can expire; you can create a new one in Omnivore's web app under Settings → API Keys.")
    elseif kind == "http" then
        return T(_("The Omnivore server returned an error (HTTP %1)."), tostring(detail))
    elseif kind == "json" then
        return _("The server's answer doesn't look like Omnivore. Check the server address (for self-hosted Omnivore it's the API address, often on port 4000).")
    end
    return T(_("Omnivore error: %1"), tostring(detail or kind))
end

local function shortTitle(s)
    s = tostring(s or "")
    if #s > 80 then s = util.fixUtf8(s:sub(1, 77), "") .. "…" end
    return s
end

local function readingTime(words)
    words = num(words)
    if not words or words <= 0 then return nil end
    return T(_("%1 min read"), math.max(1, math.floor(words / 230 + 0.5)))
end

local function siteOf(url)
    return url and url:match("^%a+://([^/%?#]+)")
end

-- Menu items are put next to Wallabag in the Tools tab instead of under "NEW:".
local menu_order_done = false
local function insertIntoMenuOrder()
    if menu_order_done then return end
    menu_order_done = true
    for _i, mod in ipairs({ "ui/elements/filemanager_menu_order", "ui/elements/reader_menu_order" }) do
        local ok, order = pcall(require, mod)
        if ok and type(order) == "table" and type(order.tools) == "table" then
            local present, pos = false, nil
            for i, v in ipairs(order.tools) do
                if v == "omnivore" then present = true end
                if v == "wallabag" then pos = i end
            end
            if not present then
                table.insert(order.tools, pos and pos + 1 or #order.tools + 1, "omnivore")
            end
        end
    end
end

local Omnivore = WidgetContainer:extend{
    name = "omnivore",
    is_doc_only = false,
}

function Omnivore:init()
    insertIntoMenuOrder()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    if self.ui.link and self.ui.link.addToExternalLinkDialog then
        self.ui.link:addToExternalLinkDialog("26_omnivore", function(this, link_url)
            return {
                text = _("Save to Omnivore"),
                callback = function()
                    UIManager:close(this.external_link_dialog)
                    self:saveLink(link_url)
                end,
                show_in_dialog_func = function()
                    return type(link_url) == "string" and link_url:match("^https?://") ~= nil
                end,
            }
        end)
    end
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("13_omnivore_save_link", function(this)
            return {
                text = _("Save link to Omnivore"),
                show_in_highlight_dialog_func = function()
                    local t = this.selected_text and this.selected_text.text
                    return type(t) == "string" and t:match("^%s*https?://%S+%s*$") ~= nil
                end,
                callback = function()
                    local url = this.selected_text.text:match("https?://%S+")
                    this:onClose()
                    self:saveLink(url)
                end,
            }
        end)
    end
end

function Omnivore:onDispatcherRegisterActions()
    -- "omnivore_download" keeps gestures set up with the original plugin working.
    Dispatcher:registerAction("omnivore_download", {
        category = "none", event = "SynchronizeOmnivore", title = _("Omnivore: sync"), general = true,
    })
    Dispatcher:registerAction("omnivore_browse", {
        category = "none", event = "BrowseOmnivore", title = _("Omnivore: browse library"), general = true,
    })
    Dispatcher:registerAction("omnivore_folder", {
        category = "none", event = "GoToOmnivoreFolder", title = _("Omnivore: open download folder"), general = true,
    })
    Dispatcher:registerAction("omnivore_archive", {
        category = "none", event = "ArchiveOmnivoreArticle", title = _("Omnivore: archive this article"), reader = true,
    })
end

---------------------------------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------------------------------

function Omnivore:cfg()
    local s = settingsStore()
    s.data.omnivore = s.data.omnivore or {}
    return s.data.omnivore
end

function Omnivore:get(key)
    local v = self:cfg()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

function Omnivore:set(key, value)
    self:cfg()[key] = value
    settingsStore():flush()
end

function Omnivore:isConfigured()
    return self:get("server_url") ~= "" and self:get("api_key") ~= ""
end

function Omnivore:getDirectory()
    local dir = self:get("directory")
    if not dir or dir == "" then
        local home = G_reader_settings:readSetting("home_dir") or Device.home_dir or DataStorage:getDataDir()
        dir = ffiUtil.joinPath(home, "Omnivore")
    end
    dir = dir:gsub("/+$", "")
    return dir
end

function Omnivore:api(quick)
    return OmnivoreAPI:new{
        server_url = self:get("server_url"),
        api_key = self:get("api_key"),
        block_timeout = quick and 5 or nil,
        total_timeout = quick and 15 or nil,
    }
end

function Omnivore:syncQuery()
    local filter = self:get("filter")
    if filter == "label" and self:get("filter_label") ~= "" then
        return string.format('in:inbox label:"%s" sort:saved-desc', self:get("filter_label"):gsub('"', ""))
    elseif filter == "query" and trim(self:get("filter_query")) ~= "" then
        return trim(self:get("filter_query"))
    end
    return "in:inbox sort:saved-desc"
end

function Omnivore:filterDescription()
    local filter = self:get("filter")
    if filter == "label" and self:get("filter_label") ~= "" then
        return T(_("label “%1”"), self:get("filter_label"))
    elseif filter == "query" and trim(self:get("filter_query")) ~= "" then
        return _("custom search")
    end
    return _("inbox")
end

---------------------------------------------------------------------------------------------------
-- Local articles
---------------------------------------------------------------------------------------------------

--- Omnivore id of a local file: from the sync state, or from the <meta> tag in the file.
function Omnivore:getArticleId(path)
    if type(path) ~= "string" then return nil end
    for id, a in pairs(articles()) do
        if a.path == path then return id end
    end
    if not path:lower():match("%.html?$") then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local head = f:read(4096) or ""
    f:close()
    local id = head:match('<meta name="omnivore%-id" content="([%w%-]+)"')
    if id then
        -- The file was moved or renamed: remember where it is now.
        local a = articles()[id] or {}
        a.path = path
        a.title = a.title or head:match("<title>(.-)</title>")
        articles()[id] = a
        saveState()
    end
    return id
end

function Omnivore:isOpen(path)
    return self.ui and self.ui.document and self.ui.document.file == path
end

function Omnivore:refreshFileManager()
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
end

--- Delete or move the local copy of an archived article, per the "after archiving" setting.
-- Module-level so it still works after the reader that called it has closed.
local function imagesDir(article_path, id)
    local folder = util.splitFilePathName(article_path)
    return ffiUtil.joinPath(folder, ".images/" .. id)
end

local function removeLocalCopy(id, after, dir)
    local a = articles()[id]
    if not a or not fileExists(a.path) or after == "keep" then return false end
    local images = imagesDir(a.path, id)
    local has_images = lfs.attributes(images, "mode") == "directory"
    if after == "move" then
        local archive_dir = ffiUtil.joinPath(dir, "archive")
        if a.path:sub(1, #archive_dir) == archive_dir then return false end
        util.makePath(archive_dir)
        local _dir, name = util.splitFilePathName(a.path)
        local new_path = ffiUtil.joinPath(archive_dir, name)
        if not FileManager:moveFile(a.path, new_path) then return false end
        DocSettings.updateLocation(a.path, new_path, false)
        pcall(function() require("readhistory"):updateItem(a.path, new_path) end)
        if has_images then
            util.makePath(ffiUtil.joinPath(archive_dir, ".images"))
            FileManager:moveFile(images, imagesDir(new_path, id))
        end
        a.path = new_path
        saveState()
        return true
    end
    FileManager:deleteFile(a.path, true) -- also removes the sidecar and history entry
    if has_images then ffiUtil.purgeDir(images) end
    articles()[id] = nil
    saveState()
    return true
end

--- Remove image folders whose article is gone (e.g. deleted in the file browser).
local function cleanOrphanImages(dir)
    local root = ffiUtil.joinPath(dir, ".images")
    if lfs.attributes(root, "mode") ~= "directory" then return end
    for name in lfs.dir(root) do
        if name:match("^%x+%-%x+%-%x+%-%x+%-%x+$") then
            local a = articles()[name]
            if not (a and fileExists(a.path) and imagesDir(a.path, name) == ffiUtil.joinPath(root, name)) then
                ffiUtil.purgeDir(ffiUtil.joinPath(root, name))
            end
        end
    end
end

function Omnivore:readArticleHTML(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local html = f:read("*a")
    f:close()
    -- Only the article body: our header isn't part of the text Omnivore knows.
    local body = html:match("<!%-%- omnivore:content:start %-%->(.*)<!%-%- omnivore:content:end %-%->")
    return body or html
end

function Omnivore:getLastPercent()
    if self.ui.paging then return self.ui.paging:getLastPercent() end
    if self.ui.rolling then return self.ui.rolling:getLastPercent() end
end

--- What KOReader knows about a local article: status, progress and highlights.
function Omnivore:collectDocState(path)
    if self:isOpen(path) then
        local summary = self.ui.doc_settings:readSetting("summary")
        return {
            status = summary and summary.status,
            percent = self:getLastPercent(),
            pages = self.ui.document:getPageCount(),
            annotations = self.ui.annotation and self.ui.annotation.annotations or {},
        }
    end
    if not DocSettings:hasSidecarFile(path) then return nil end
    local ds = DocSettings:open(path)
    local summary = ds:readSetting("summary")
    return {
        status = summary and summary.status,
        percent = ds:readSetting("percent_finished"),
        pages = ds:readSetting("doc_pages"),
        annotations = ds:readSetting("annotations") or {},
    }
end

---------------------------------------------------------------------------------------------------
-- Sending local changes
---------------------------------------------------------------------------------------------------

--- Send new highlights, edited notes and reading progress of one article.
-- Returns false, err, detail on a network or auth error (callers stop); counts go in `r`.
function Omnivore:pushArticle(api, id, a, doc, r)
    if not doc or not a or not fileExists(a.path) then return true end
    if self:get("send_highlights") then
        a.hl = a.hl or {}
        local html
        for _i, item in ipairs(doc.annotations or {}) do
            local text = type(item.text) == "string" and util.cleanupSelectedText(item.text) or ""
            if item.drawer and text ~= "" then
                local key = tostring(item.datetime) .. "|" .. (type(item.pos0) == "string" and item.pos0 or "")
                local note = type(item.note) == "string" and item.note or ""
                local sent = a.hl[key]
                if not sent then
                    html = html or self:readArticleHTML(a.path) or ""
                    local hint = item.pageno and doc.pages and doc.pages > 0 and (item.pageno / doc.pages) or nil
                    local ok_loc, loc = pcall(Locator.locate, html, text, hint)
                    if not ok_loc then
                        logger.warn("Omnivore: locating highlight failed", loc)
                        loc = nil
                    end
                    local hid, err, detail = api:createHighlight{
                        article_id = id,
                        quote = text,
                        note = note,
                        color = KO_TO_OMNIVORE_COLOR[item.color] or "yellow",
                        patch = loc and loc.patch,
                        prefix = loc and trim(loc.prefix:gsub("%s+", " ")),
                        suffix = loc and trim(loc.suffix:gsub("%s+", " ")),
                        percent = loc and loc.percent or (hint and hint * 100),
                    }
                    if hid then
                        a.hl[key] = { id = hid, note = note }
                        r.highlights = r.highlights + 1
                        saveState()
                    elseif err == "network" or err == "auth" then
                        return false, err, detail
                    else
                        table.insert(r.errors, T(_("Highlight in “%1”: %2"), shortTitle(a.title), tostring(detail)))
                    end
                elseif sent.note ~= note then
                    local ok, err, detail = api:updateHighlight(sent.id, note)
                    if ok then
                        sent.note = note
                        r.highlights = r.highlights + 1
                        saveState()
                    elseif err == "network" or err == "auth" then
                        return false, err, detail
                    end
                end
            end
        end
    end
    if self:get("send_progress") and doc.percent then
        local pct = math.floor(doc.percent * 100 + 0.5)
        if doc.status == "complete" then pct = 100 end
        -- Only forward: Omnivore keeps the furthest position (it refuses a lower one unless forced),
        -- so opening a fresh copy at the top and closing it never winds progress back.
        if pct > (a.progress_sent or 0) then
            local ok, err, detail = api:saveProgress(id, pct)
            if err == "network" or err == "auth" then
                return false, err, detail
            end
            a.progress_sent = pct -- on refusal, Omnivore is already further along
            if ok then r.progress = r.progress + 1 end
            saveState()
        end
    end
    return true
end

function Omnivore:shouldArchive(doc)
    if not doc then return false end
    if self:get("archive_finished") and doc.status == "complete" then return true end
    if self:get("archive_read") and doc.percent and doc.percent >= 0.995 then return true end
    return false
end

---------------------------------------------------------------------------------------------------
-- Downloading
---------------------------------------------------------------------------------------------------

local function sniffImageType(data)
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return "image/png" end
    if data:sub(1, 3) == "\255\216\255" then return "image/jpeg" end
    if data:sub(1, 4) == "GIF8" then return "image/gif" end
    if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then return "image/webp" end
    if data:sub(1, 256):find("<svg", 1, true) then return "image/svg+xml" end
    return nil
end

function Omnivore:fetchImage(url)
    local sink = {}
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, headers = socket.skip(1, http.request{
        url = url,
        sink = ltn12.sink.table(sink),
        headers = { ["User-Agent"] = "Mozilla/5.0 (KOReader; Omnivore plugin)" },
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.dbg("Omnivore: image", url, "HTTP", code)
        return nil
    end
    local data = table.concat(sink)
    if #data == 0 or #data > 8 * 1024 * 1024 then return nil end
    local ctype = headers and headers["content-type"] and headers["content-type"]:match("^%s*([%w%.%+%-]+/[%w%.%+%-]+)")
    if not ctype or not ctype:match("^image/") then ctype = sniffImageType(data) end
    if not ctype then return nil end
    return data, ctype
end

local IMAGE_EXT = {
    ["image/jpeg"] = "jpg", ["image/jpg"] = "jpg", ["image/png"] = "png", ["image/gif"] = "gif",
    ["image/webp"] = "webp", ["image/svg+xml"] = "svg", ["image/bmp"] = "bmp",
}

local function attr(tag, name)
    local v = tag:match("%s" .. name .. '%s*=%s*"([^"]*)"') or tag:match("%s" .. name .. "%s*=%s*'([^']*)'")
    return v and util.htmlEntitiesToUtf8(v) or nil
end

-- Hosted Omnivore rewrote image URLs through an image proxy that no longer exists:
-- https://proxy-prod.omnivore-image-cache.app/<size,signature>/<original URL>
local function unproxy(url)
    return url and url:match("^https?://[^/]*omnivore%-image%-cache%.app/[^/]*/(https?://.+)$")
end

--- Where an <img> can be fetched from, best first.
local function imageCandidates(tag)
    local list, seen = {}, {}
    local function add(url)
        if url and url:match("^https?://") and not seen[url] then
            seen[url] = true
            table.insert(list, url)
        end
    end
    local src = attr(tag, "src")
    add(attr(tag, "data%-omnivore%-original%-src"))
    add(unproxy(src))
    if not unproxy(src) then add(src) end
    add(attr(tag, "data%-src"))
    return list
end

--- Save the article's images next to it (in a hidden .images/<id>/ folder) and point the
-- <img> tags at them, so the article reads offline. Separate files keep the HTML small, which
-- matters: a page with inlined base64 images takes many times longer to open the first time.
-- `on_image(i, total)` returning false stops.
function Omnivore:saveImages(content, img_dir, rel_dir, on_image)
    local tags, total = {}, 0
    for tag in content:gmatch("<[Ii][Mm][Gg][^>]+>") do
        if not tags[tag] then
            local candidates = imageCandidates(tag)
            if #candidates > 0 then
                tags[tag] = candidates
                total = total + 1
            end
        end
    end
    if total == 0 then return content end
    if lfs.attributes(img_dir, "mode") == "directory" then ffiUtil.purgeDir(img_dir) end
    util.makePath(img_dir)
    local saved, local_src, i, n = {}, {}, 0, 0
    for tag, candidates in pairs(tags) do
        i = i + 1
        if on_image and on_image(i, total) == false then break end
        for _i, url in ipairs(candidates) do
            if saved[url] == nil then
                saved[url] = false
                local data, ctype = self:fetchImage(url)
                if data then
                    n = n + 1
                    local name = n .. "." .. (IMAGE_EXT[ctype] or "img")
                    local f = io.open(ffiUtil.joinPath(img_dir, name), "wb")
                    if f then
                        f:write(data)
                        f:close()
                        saved[url] = rel_dir .. name
                    end
                end
            end
            if saved[url] then
                local_src[tag] = saved[url]
                break
            end
        end
    end
    if n == 0 then ffiUtil.purgeDir(img_dir) end
    return (content:gsub("<[Ii][Mm][Gg][^>]+>", function(tag)
        local src = local_src[tag]
        tag = tag:gsub('%ssrcset%s*=%s*"[^"]*"', ""):gsub("%ssrcset%s*=%s*'[^']*'", "")
        tag = tag:gsub('%ssizes%s*=%s*"[^"]*"', "")
        if src then
            src = util.htmlEscape(src)
            local replaced
            tag, replaced = tag:gsub('(%ssrc%s*=%s*)"[^"]*"', function(pre) return pre .. '"' .. src .. '"' end, 1)
            if replaced == 0 then
                tag, replaced = tag:gsub("(%ssrc%s*=%s*)'[^']*'", function(pre) return pre .. '"' .. src .. '"' end, 1)
            end
            if replaced == 0 then
                tag = tag:gsub("^<[Ii][Mm][Gg]", function(open) return open .. ' src="' .. src .. '"' end, 1)
            end
        end
        return tag
    end))
end

function Omnivore:buildHTML(article, content)
    local esc = util.htmlEscape
    local title = str(article.title) or _("Untitled")
    local url = str(article.originalArticleUrl) or str(article.url)
    local author = str(article.author)
    local meta = {}
    local site = str(article.siteName) or siteOf(url)
    if site then table.insert(meta, site) end
    if author then table.insert(meta, author) end
    local published = str(article.publishedAt)
    if published then table.insert(meta, published:sub(1, 10)) end
    local rt = readingTime(article.wordsCount)
    if rt then table.insert(meta, rt) end
    local labels = {}
    for _i, l in ipairs(tbl(article.labels) or {}) do
        if str(l.name) then table.insert(labels, l.name) end
    end
    local out = {
        "<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n",
        '<meta name="omnivore-id" content="', esc(article.id), '">\n',
        '<meta name="omnivore-slug" content="', esc(str(article.slug) or ""), '">\n',
        url and ('<meta name="omnivore-url" content="' .. esc(url) .. '">\n') or "",
        author and ('<meta name="author" content="' .. esc(author) .. '">\n') or "",
        "<title>", esc(title), "</title>\n",
        "<style>", CSS, "</style>\n</head>\n<body>\n",
        '<div class="omnivore-header">\n<h1>', esc(title), "</h1>\n",
        #meta > 0 and ('<p class="omnivore-meta">' .. esc(table.concat(meta, " · ")) .. "</p>\n") or "",
        #labels > 0 and ('<p class="omnivore-meta">' .. esc(table.concat(labels, ", ")) .. "</p>\n") or "",
        url and ('<p class="omnivore-meta"><a href="' .. esc(url) .. '">' .. esc(siteOf(url) or url) .. "</a></p>\n") or "",
        "</div>\n<!-- omnivore:content:start -->",
        content,
        "<!-- omnivore:content:end -->\n</body>\n</html>\n",
    }
    return table.concat(out)
end

--- Pick a file name from the title; reuse it if it already holds this article (or an old,
-- untagged download of it), otherwise add " (2)", " (3)"…
function Omnivore:pathFor(id, title, dir, ext)
    local base = util.getSafeFilename(title, dir, 160)
    if base == "" then base = id end
    local candidate = ffiUtil.joinPath(dir, base .. ext)
    local n = 2
    while fileExists(candidate) do
        local owner = self:getArticleId(candidate)
        if owner == nil or owner == id then break end
        candidate = ffiUtil.joinPath(dir, base .. " (" .. n .. ")" .. ext)
        n = n + 1
    end
    return candidate
end

local function writeFile(path, data)
    local tmp = path .. ".part"
    local f, err = io.open(tmp, "w")
    if not f then return false, err end
    f:write(data)
    f:close()
    os.remove(path)
    return os.rename(tmp, path)
end

local function downloadToFile(url, path)
    local tmp = path .. ".part"
    local f = io.open(tmp, "w")
    if not f then return false end
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = socket.skip(1, http.request{ url = url, sink = ltn12.sink.file(f) })
    socketutil:reset_timeout()
    if code ~= 200 then
        os.remove(tmp)
        return false
    end
    os.remove(path)
    return os.rename(tmp, path)
end

--- Download one item. `on_image(i, n)` reports image progress (return false to stop).
-- Returns the local path, or nil, err, detail.
function Omnivore:downloadItem(api, item, on_image)
    local dir = self:getDirectory()
    util.makePath(dir)
    local id = item.id
    local article, err, detail = api:article(item.slug)
    if not article then return nil, err, detail end
    article.id = id
    local title = str(article.title) or _("Untitled")
    local path

    if article.contentReader == "PDF" then
        local url = str(article.url)
        path = self:pathFor(id, title, dir, ".pdf")
        if not url or not downloadToFile(url, path) then
            return nil, "api", _("the PDF couldn't be downloaded")
        end
    else
        local content = str(article.content)
        if not content or content == "" then
            return nil, "api", _("Omnivore has no content for it yet")
        end
        path = self:pathFor(id, title, dir, ".html")
        if self:get("download_images") then
            content = self:saveImages(content, imagesDir(path, id), ".images/" .. id .. "/", on_image)
        end
        local ok, werr = writeFile(path, self:buildHTML(article, content))
        if not ok then return nil, "api", tostring(werr) end
    end

    local progress = num(article.readingProgressPercent) or 0
    local old = articles()[id]
    articles()[id] = {
        path = path,
        title = title,
        slug = str(article.slug),
        url = str(article.originalArticleUrl) or str(article.url),
        progress_sent = math.floor(progress),
        hl = old and old.hl or nil,
    }
    saveState()
    -- Open where you left off in Omnivore.
    if progress > 1 and progress < 100 and not DocSettings:hasSidecarFile(path) then
        local ds = DocSettings:open(path)
        ds:saveSetting("last_percent", progress / 100)
        ds:saveSetting("percent_finished", progress / 100)
        ds:flush()
    end
    return path
end

---------------------------------------------------------------------------------------------------
-- Sync
---------------------------------------------------------------------------------------------------

function Omnivore:onSynchronizeOmnivore()
    if not self:isConfigured() then
        self:editServerSettings()
        return true
    end
    if self.syncing then return true end
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            self.syncing = true
            local ok, err = pcall(self.sync, self)
            self.syncing = false
            if not ok then
                logger.err("Omnivore: sync failed", err)
                Trapper:clear()
                UIManager:show(InfoMessage:new{ text = T(_("Omnivore sync failed:\n%1"), tostring(err)) })
            end
        end)
    end)
    return true
end

function Omnivore:sync()
    local api = self:api()
    local r = { downloaded = 0, archived = 0, removed = 0, highlights = 0, progress = 0, saved = 0,
                deleted = 0, processing = 0, failed = 0, errors = {} }
    local stopped = false
    Trapper:setPausedText(_("Stop syncing with Omnivore?"), _("Stop"), _("Continue"))

    local function step(text)
        if stopped then return false end
        if not Trapper:info(text .. "\n\n" .. _("Tap to stop.")) then stopped = true end
        return not stopped
    end

    local function fatal(err, detail)
        Trapper:clear()
        saveState()
        UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
    end

    step(_("Connecting to Omnivore…"))
    local me, err, detail = api:me()
    if not me then return fatal(err, detail) end
    local sync_started = os.time()

    -- 1. Actions saved while offline.
    local q = queue()
    if #q > 0 and step(T(N_("Sending 1 saved action…", "Sending %1 saved actions…", #q), #q)) then
        local remaining = {}
        for i, job in ipairs(q) do
            local ok
            if err ~= "network" and err ~= "auth" then
                if job.type == "save" then
                    ok, err, detail = api:saveUrl(job.url)
                    if ok then r.saved = r.saved + 1 end
                elseif job.type == "archive" then
                    ok, err, detail = api:setArchived(job.id, true)
                    if ok then
                        r.archived = r.archived + 1
                        local a = articles()[job.id]
                        if a then a.archived = true end
                    end
                elseif job.type == "delete" then
                    ok, err, detail = api:delete(job.id)
                    if ok then r.deleted = r.deleted + 1 end
                else
                    ok = true
                end
            end
            if not ok then
                if err == "network" or err == "auth" then
                    table.insert(remaining, job)
                else
                    table.insert(r.errors, T(_("Couldn't %1 “%2”: %3"), job.type,
                        shortTitle(job.title or job.url or job.id), tostring(detail)))
                end
            end
        end
        stateStore().data.queue = remaining
        saveState()
        if err == "network" or err == "auth" then return fatal(err, detail) end
    end

    -- 2. Highlights, notes, progress and finished articles.
    local ids = {}
    for id, a in pairs(articles()) do
        if fileExists(a.path) then table.insert(ids, id) end
    end
    for i, id in ipairs(ids) do
        local a = articles()[id]
        local doc = self:collectDocState(a.path)
        if doc then
            if not step(T(_("Sending highlights and progress… (%1/%2)"), i, #ids)) then break end
            local ok, perr, pdetail = self:pushArticle(api, id, a, doc, r)
            if not ok then return fatal(perr, pdetail) end
            if not a.archived and self:shouldArchive(doc) then
                local aok, aerr, adetail = api:setArchived(id, true)
                if aok then
                    a.archived = true
                    r.archived = r.archived + 1
                    saveState()
                elseif aerr == "network" or aerr == "auth" then
                    return fatal(aerr, adetail)
                end
            end
        end
    end

    -- 3. Articles archived or deleted elsewhere (Omnivore app, web, another device).
    if not stopped and step(_("Checking for changes in Omnivore…")) then
        local since = stateStore().data.last_remote_check
        local remote_ok = true
        if since then
            local cursor, pages = nil, 0
            repeat
                local res, uerr, udetail = api:updatesSince(since, cursor)
                if not res then
                    remote_ok = false
                    table.insert(r.errors, errorText(uerr, udetail))
                    break
                end
                for _i, edge in ipairs(res.edges) do
                    local a = str(edge.itemID) and articles()[edge.itemID]
                    if a then
                        local node = tbl(edge.node)
                        if edge.updateReason == "DELETED" or (node and node.isArchived == true) then
                            a.archived = true
                        elseif node and node.isArchived == false and a.archived and not fileExists(a.path) then
                            articles()[edge.itemID] = nil -- back in the inbox: download it again
                        end
                    end
                end
                cursor, pages = res.cursor, pages + 1
            until not res.has_next or not cursor or pages >= 20
        else
            -- First sync: ask about what's already on the device.
            local local_ids = {}
            for id, a in pairs(articles()) do
                if fileExists(a.path) and not a.archived then table.insert(local_ids, id) end
            end
            if #local_ids > 0 then
                local res = api:search("in:all includes:" .. table.concat(local_ids, ","), #local_ids)
                for _i, item in ipairs(res and res.items or {}) do
                    local a = articles()[item.id]
                    if a and item.isArchived == true then a.archived = true end
                end
            end
        end
        if remote_ok then
            stateStore().data.last_remote_check = isoUTC(sync_started - 300)
        end
        saveState()
    end

    -- Local copies of archived articles.
    local after, dir = self:get("after_archive"), self:getDirectory()
    if after ~= "keep" then
        for id, a in pairs(articles()) do
            if a.archived and fileExists(a.path) and not self:isOpen(a.path) then
                if removeLocalCopy(id, after, dir) then r.removed = r.removed + 1 end
            end
        end
    end

    cleanOrphanImages(dir)

    -- 4. New articles.
    if not stopped and step(T(_("Looking for new articles (%1)…"), self:filterDescription())) then
        local limit = self:get("articles_per_sync")
        local query = self:syncQuery()
        local items, cursor = {}, nil
        while #items < limit do
            local page, serr, sdetail = api:search(query, math.min(50, limit - #items), cursor, false)
            if not page then
                table.insert(r.errors, errorText(serr, sdetail))
                break
            end
            for _i, item in ipairs(page.items) do table.insert(items, item) end
            if not page.has_next or not page.cursor then break end
            cursor = page.cursor
        end
        local todo = {}
        for _i, item in ipairs(items) do
            local a = articles()[item.id]
            if item.state == "PROCESSING" then
                r.processing = r.processing + 1
            elseif not a then
                table.insert(todo, item)
            elseif not fileExists(a.path) and a.archived then
                table.insert(todo, item) -- unarchived since we removed it
            end
            -- Known article whose file you deleted yourself: left alone (Browse can fetch it).
        end
        for i, item in ipairs(todo) do
            local title = shortTitle(str(item.title))
            if not step(T(_("Downloading %1 of %2…\n\n%3"), i, #todo, title)) then break end
            local path, derr, ddetail = self:downloadItem(api, item, function(n, total)
                return step(T(_("Downloading %1 of %2…\n\n%3\n\nImage %4 of %5"), i, #todo, title, n, total))
            end)
            if path then
                r.downloaded = r.downloaded + 1
            elseif derr == "network" or derr == "auth" then
                return fatal(derr, ddetail)
            else
                r.failed = r.failed + 1
                table.insert(r.errors, T(_("“%1”: %2"), title, tostring(ddetail)))
            end
        end
    end

    stateStore().data.last_sync_time = os.time()
    saveState()
    Trapper:clear()
    self:refreshFileManager()
    UIManager:show(InfoMessage:new{
        text = self:summary(r, stopped),
        timeout = (#r.errors == 0) and 5 or nil,
    })
end

function Omnivore:summary(r, stopped)
    local lines = { stopped and _("Sync stopped.") or _("Sync finished.") }
    local function add(n, text) if n > 0 then table.insert(lines, T(text, n)) end end
    add(r.downloaded, N_("Downloaded 1 new article.", "Downloaded %1 new articles.", r.downloaded))
    add(r.highlights, N_("Sent 1 highlight or note.", "Sent %1 highlights and notes.", r.highlights))
    add(r.progress, N_("Updated reading progress of 1 article.", "Updated reading progress of %1 articles.", r.progress))
    add(r.archived, N_("Archived 1 article in Omnivore.", "Archived %1 articles in Omnivore.", r.archived))
    add(r.removed, N_("Removed 1 archived article from this device.", "Removed %1 archived articles from this device.", r.removed))
    add(r.saved, N_("Saved 1 link to Omnivore.", "Saved %1 links to Omnivore.", r.saved))
    add(r.deleted, N_("Deleted 1 article from Omnivore.", "Deleted %1 articles from Omnivore.", r.deleted))
    if #lines == 1 and #r.errors == 0 and not stopped then
        table.insert(lines, _("Everything is up to date."))
    end
    add(r.processing, N_("1 article is still being fetched by Omnivore; it will download next time.",
        "%1 articles are still being fetched by Omnivore; they will download next time.", r.processing))
    if #r.errors > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Problems:"))
        for i = 1, math.min(5, #r.errors) do table.insert(lines, "• " .. r.errors[i]) end
        if #r.errors > 5 then table.insert(lines, T(_("…and %1 more."), #r.errors - 5)) end
    end
    return table.concat(lines, "\n")
end

--- On close: send this article's progress and new highlights right away (quietly).
function Omnivore:onCloseDocument()
    if not self:isConfigured() or not self:get("send_on_close") then return end
    if not (self:get("send_progress") or self:get("send_highlights")) then return end
    local path = self.ui.document and self.ui.document.file
    local id = path and self:getArticleId(path)
    if not id then return end
    local doc = self:collectDocState(path)
    UIManager:scheduleIn(1, function()
        if not NetworkMgr:isOnline() then return end
        local a = articles()[id]
        if not a then return end
        local r = { highlights = 0, progress = 0, errors = {} }
        local ok, err = self:pushArticle(self:api(true), id, a, doc, r)
        logger.dbg("Omnivore: sent on close", ok, err, r.highlights, r.progress)
    end)
end

---------------------------------------------------------------------------------------------------
-- Actions on single articles
---------------------------------------------------------------------------------------------------

function Omnivore:queueAction(job)
    table.insert(queue(), job)
    saveState()
end

--- Archive (or delete, when `delete` is true) the article open in the reader, then close it.
function Omnivore:finishCurrent(delete)
    local path = self.ui.document and self.ui.document.file
    local id = path and self:getArticleId(path)
    if not id then
        UIManager:show(InfoMessage:new{ text = _("This document isn't an Omnivore article.") })
        return
    end
    local a = articles()[id]
    local doc = self:collectDocState(path)
    local after = delete and "delete" or self:get("after_archive")
    local dir = self:getDirectory()
    local done_text
    local api = self:api(true)
    local online = NetworkMgr:isOnline()
    local ok, err
    if online then
        local r = { highlights = 0, progress = 0, errors = {} }
        if not delete then self:pushArticle(api, id, a, doc, r) end
        if delete then ok, err = api:delete(id) else ok, err = api:setArchived(id, true) end
    end
    if ok then
        done_text = delete and _("Deleted from Omnivore.") or _("Archived in Omnivore.")
    elseif not online or err == "network" then
        self:queueAction({ type = delete and "delete" or "archive", id = id, title = a and a.title })
        done_text = delete and _("You're offline: it will be deleted from Omnivore at the next sync.")
                           or _("You're offline: it will be archived in Omnivore at the next sync.")
    else
        UIManager:show(InfoMessage:new{ text = errorText(err) })
        return
    end
    if a then a.archived = true end
    saveState()

    self.ui:onClose()
    UIManager:nextTick(function()
        if after ~= "keep" then removeLocalCopy(id, after, dir) end
        if FileManager.instance then
            FileManager.instance:reinit(dir)
        else
            FileManager:showFiles(dir)
        end
        UIManager:show(InfoMessage:new{ text = done_text, timeout = 3 })
    end)
end

function Omnivore:onArchiveOmnivoreArticle()
    local path = self.ui.document and self.ui.document.file
    local id = path and self:getArticleId(path)
    if not id then
        UIManager:show(InfoMessage:new{ text = _("This document isn't an Omnivore article.") })
        return true
    end
    local a = articles()[id] or {}
    local after = self:get("after_archive")
    local what = after == "delete" and _("The copy on this device will be deleted.")
        or after == "move" and _("The copy on this device will be moved to the archive folder.")
        or _("The copy on this device will be kept.")
    UIManager:show(ConfirmBox:new{
        text = T(_("Archive “%1” in Omnivore and close it?\n\n%2"), shortTitle(a.title), what),
        ok_text = _("Archive"),
        ok_callback = function() self:finishCurrent(false) end,
    })
    return true
end

function Omnivore:deleteCurrent()
    local path = self.ui.document and self.ui.document.file
    local id = path and self:getArticleId(path)
    local a = id and articles()[id] or {}
    UIManager:show(ConfirmBox:new{
        text = T(_("Delete “%1” from Omnivore and from this device?"), shortTitle(a.title)),
        ok_text = _("Delete"),
        ok_callback = function() self:finishCurrent(true) end,
    })
end

function Omnivore:sendCurrentNow()
    local path = self.ui.document and self.ui.document.file
    local id = path and self:getArticleId(path)
    if not id then return end
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Sending to Omnivore…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local r = { highlights = 0, progress = 0, errors = {} }
        local ok, err, detail = self:pushArticle(self:api(), id, articles()[id], self:collectDocState(path), r)
        UIManager:close(info)
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
        elseif #r.errors > 0 then
            UIManager:show(InfoMessage:new{ text = table.concat(r.errors, "\n") })
        else
            local parts = {}
            if r.highlights > 0 then
                table.insert(parts, T(N_("Sent 1 highlight or note.", "Sent %1 highlights and notes.", r.highlights), r.highlights))
            end
            if r.progress > 0 then table.insert(parts, _("Reading progress updated.")) end
            if #parts == 0 then table.insert(parts, _("Omnivore already has everything from this article.")) end
            UIManager:show(InfoMessage:new{ text = table.concat(parts, "\n"), timeout = 3 })
        end
    end)
end

--- "example.com/page" -> "https://example.com/page"; nil if it isn't a web link.
local function normaliseLink(url)
    url = trim(url)
    if url:match("^https?://[^%s/]+%.[^%s]+") then return url end
    if not url:match("^%a+:") and url:match("^[%w%-]+%.[%w%-%.]+[^%s]*$") then return "https://" .. url end
    return nil
end

--- Returns false (and says why) when `url` isn't a web link.
function Omnivore:saveLink(url)
    url = normaliseLink(url)
    if not url then
        UIManager:show(InfoMessage:new{ text = _("That doesn't look like a web link, e.g. https://example.com/article") })
        return false
    end
    local function saveForLater()
        self:queueAction({ type = "save", url = url })
        UIManager:show(InfoMessage:new{
            text = T(_("It will be saved to Omnivore at the next sync:\n%1"), BD.url(url)), timeout = 3,
        })
    end
    if not self:isConfigured() or not NetworkMgr:isOnline() then
        saveForLater()
        return
    end
    local info = InfoMessage:new{ text = _("Saving to Omnivore…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local ok, err, detail = self:api(true):saveUrl(url)
    UIManager:close(info)
    if ok then
        UIManager:show(InfoMessage:new{ text = T(_("Saved to Omnivore:\n%1"), BD.url(url)), timeout = 2 })
    elseif err == "network" then
        saveForLater()
    else
        UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
    end
end

function Omnivore:showSaveLinkDialog()
    local dialog
    dialog = InputDialog:new{
        title = _("Save a link to Omnivore"),
        input_hint = "https://…",
        input_type = "text",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local url = dialog:getInputText()
                    if not normaliseLink(url) then
                        -- Keep the dialog (and what was typed) open.
                        UIManager:show(InfoMessage:new{
                            text = _("That doesn't look like a web link, e.g. https://example.com/article"),
                            timeout = 3,
                        })
                        return
                    end
                    UIManager:close(dialog)
                    self:saveLink(url)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Omnivore:onGoToOmnivoreFolder()
    local dir = self:getDirectory()
    util.makePath(dir)
    if self.ui.document then self.ui:onClose() end
    if FileManager.instance then
        FileManager.instance:reinit(dir)
    else
        FileManager:showFiles(dir)
    end
    return true
end

function Omnivore:openLocal(path)
    if self.browser then
        UIManager:close(self.browser)
        self.browser = nil
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        require("apps/reader/readerui"):showReader(path)
    end
end

---------------------------------------------------------------------------------------------------
-- Library browser
---------------------------------------------------------------------------------------------------

function Omnivore:onBrowseOmnivore()
    if not self:isConfigured() then
        self:editServerSettings()
        return true
    end
    NetworkMgr:runWhenOnline(function() self:showBrowser(VIEWS[1]) end)
    return true
end

function Omnivore:loadBrowserPage()
    local b = self.browse
    local info = InfoMessage:new{ text = _("Loading…") }
    UIManager:show(info)
    UIManager:forceRePaint()
    local page, err, detail = self:api():search(b.view.query, 25, b.cursor, false)
    UIManager:close(info)
    if not page then
        UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
        return false
    end
    for _i, item in ipairs(page.items) do table.insert(b.items, item) end
    b.cursor, b.has_next, b.total = page.cursor, page.has_next, page.total
    return true
end

function Omnivore:browserItemTable()
    local b = self.browse
    local list = {}
    for _i, item in ipairs(b.items) do
        local a = articles()[item.id]
        local here = a and fileExists(a.path)
        local pct = math.floor(num(item.readingProgressPercent) or 0)
        local mandatory = {}
        if here then table.insert(mandatory, _("on device")) end
        if pct > 0 then table.insert(mandatory, pct .. "%") end
        table.insert(list, {
            text = str(item.title) or _("Untitled"),
            mandatory = table.concat(mandatory, " · "),
            bold = here,
            item = item,
        })
    end
    if b.has_next then
        table.insert(list, { text = _("Load more…"), load_more = true })
    elseif #list == 0 then
        table.insert(list, { text = _("Nothing here."), empty = true, dim = true })
    end
    return list
end

function Omnivore:browserSubtitle()
    local b = self.browse
    local here = 0
    for _i, item in ipairs(b.items) do
        local a = articles()[item.id]
        if a and fileExists(a.path) then here = here + 1 end
    end
    local total = b.total or #b.items
    return T(N_("1 article", "%1 articles", total), total) .. " · " .. T(_("%1 on this device"), here)
end

function Omnivore:refreshBrowser(select_number)
    if not self.browser then return end
    self.browser:switchItemTable(T(_("Omnivore · %1"), self.browse.view.text), self:browserItemTable(),
        select_number or -1, nil, self:browserSubtitle())
end

function Omnivore:showBrowser(view)
    self.browse = { view = view, items = {}, cursor = nil, has_next = false }
    if not self:loadBrowserPage() then return end
    if self.browser then
        self:refreshBrowser(1)
        return
    end
    local plugin = self
    self.browser = Menu:new{
        title = T(_("Omnivore · %1"), view.text),
        subtitle = self:browserSubtitle(),
        item_table = self:browserItemTable(),
        is_borderless = true,
        is_popout = false,
        covers_fullscreen = true,
        title_bar_fm_style = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap = function() plugin:showViewChooser() end,
        onMenuSelect = function(_menu, entry) plugin:onBrowserSelect(entry) return true end,
        onMenuHold = function(_menu, entry) plugin:onBrowserSelect(entry) return true end,
        close_callback = function()
            if plugin.browser then UIManager:close(plugin.browser) end
            plugin.browser = nil
        end,
    }
    UIManager:show(self.browser)
end

function Omnivore:showViewChooser()
    local dialog
    local buttons = {}
    for _i, view in ipairs(VIEWS) do
        table.insert(buttons, {{
            text = view.text,
            callback = function()
                UIManager:close(dialog)
                self:showBrowser(view)
            end,
        }})
    end
    table.insert(buttons, {
        {
            text = _("Labels…"),
            callback = function()
                UIManager:close(dialog)
                self:chooseLabel(function(label)
                    self:showBrowser({ text = label, query = string.format('in:all label:"%s" sort:saved-desc', label:gsub('"', "")) })
                end)
            end,
        },
        {
            text = _("Search…"),
            callback = function()
                UIManager:close(dialog)
                self:askSearch()
            end,
        },
    })
    dialog = ButtonDialog:new{ title = _("Show"), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function Omnivore:askSearch()
    local dialog
    dialog = InputDialog:new{
        title = _("Search Omnivore"),
        input_hint = _("words, or filters like label:news"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = trim(dialog:getInputText())
                    UIManager:close(dialog)
                    if q ~= "" then
                        local query = q:match("in:%a+") and q or ("in:all " .. q)
                        self:showBrowser({ text = "“" .. q .. "”", query = query })
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Omnivore:onBrowserSelect(entry)
    if entry.empty then return end
    if entry.load_more then
        local n = #self.browse.items
        if self:loadBrowserPage() then self:refreshBrowser(n + 1) end
        return
    end
    local item = entry.item
    local a = articles()[item.id]
    local local_path = a and fileExists(a.path) and a.path
    local details = {}
    local site = str(item.siteName) or siteOf(str(item.originalArticleUrl) or str(item.url))
    if site then table.insert(details, site) end
    if str(item.author) then table.insert(details, item.author) end
    local rt = readingTime(item.wordsCount)
    if rt then table.insert(details, rt) end
    local pct = math.floor(num(item.readingProgressPercent) or 0)
    if pct > 0 then table.insert(details, T(_("%1% read"), pct)) end
    local labels = {}
    for _i, l in ipairs(tbl(item.labels) or {}) do
        if str(l.name) then table.insert(labels, l.name) end
    end
    local title = (str(item.title) or _("Untitled")) .. "\n\n" .. table.concat(details, " · ")
    if #labels > 0 then title = title .. "\n" .. table.concat(labels, ", ") end
    local description = str(item.description)
    if description then
        description = trim(description:gsub("%s+", " "))
        if #description > 240 then
            description = util.fixUtf8(description:sub(1, 240), ""):gsub("%s+%S*$", "") .. "…"
        end
        title = title .. "\n\n" .. description
    end

    local dialog
    local function close() UIManager:close(dialog) end
    local function download(open)
        close()
        local info = InfoMessage:new{ text = T(_("Downloading…\n\n%1"), shortTitle(item.title)) }
        UIManager:show(info)
        UIManager:forceRePaint()
        local path, err, detail = self:downloadItem(self:api(), item)
        UIManager:close(info)
        if not path then
            UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
            return
        end
        self:refreshFileManager()
        if open then
            self:openLocal(path)
        else
            self:refreshBrowser()
            UIManager:show(InfoMessage:new{ text = _("Downloaded."), timeout = 1 })
        end
    end
    local function setArchived(archived)
        close()
        local ok, err, detail = self:api():setArchived(item.id, archived)
        if not ok then
            UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
            return
        end
        if a then
            a.archived = archived or nil
            saveState()
            if archived and not self:isOpen(a.path) then
                removeLocalCopy(item.id, self:get("after_archive"), self:getDirectory())
                self:refreshFileManager()
            end
        end
        for i, it in ipairs(self.browse.items) do
            if it.id == item.id then table.remove(self.browse.items, i) break end
        end
        if self.browse.total then self.browse.total = self.browse.total - 1 end
        self:refreshBrowser()
        UIManager:show(InfoMessage:new{
            text = archived and _("Archived.") or _("Moved to the inbox."), timeout = 1,
        })
    end
    local function deleteItem()
        close()
        UIManager:show(ConfirmBox:new{
            text = T(_("Delete “%1” from Omnivore?"), shortTitle(item.title))
                .. (local_path and ("\n\n" .. _("The copy on this device will be deleted too.")) or ""),
            ok_text = _("Delete"),
            ok_callback = function()
                local ok, err, detail = self:api():delete(item.id)
                if not ok then
                    UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
                    return
                end
                if local_path and not self:isOpen(local_path) then
                    removeLocalCopy(item.id, "delete", self:getDirectory())
                    self:refreshFileManager()
                end
                for i, it in ipairs(self.browse.items) do
                    if it.id == item.id then table.remove(self.browse.items, i) break end
                end
                if self.browse.total then self.browse.total = self.browse.total - 1 end
                self:refreshBrowser()
            end,
        })
    end

    local buttons = {}
    if local_path then
        table.insert(buttons, {{ text = _("Open"), callback = function() close() self:openLocal(local_path) end }})
    else
        table.insert(buttons, {
            { text = _("Download"), callback = function() download(false) end },
            { text = _("Download and open"), callback = function() download(true) end },
        })
    end
    table.insert(buttons, {
        item.isArchived == true
            and { text = _("Move to inbox"), callback = function() setArchived(false) end }
            or { text = _("Archive"), callback = function() setArchived(true) end },
        { text = _("Delete"), callback = deleteItem },
    })
    dialog = ButtonDialog:new{ title = title, title_align = "left", buttons = buttons }
    UIManager:show(dialog)
end

---------------------------------------------------------------------------------------------------
-- Settings dialogs
---------------------------------------------------------------------------------------------------

function Omnivore:testConnection(server_url, api_key, on_success)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Connecting to Omnivore…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local me, err, detail = OmnivoreAPI:new{ server_url = server_url, api_key = api_key }:me()
        UIManager:close(info)
        if me then
            UIManager:show(InfoMessage:new{
                text = T(_("Connected to %1\nas %2."), BD.url(server_url), me.name or me.username or "?"),
                timeout = 3,
            })
            if on_success then on_success() end
        else
            UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
        end
    end)
end

function Omnivore:editServerSettings(touchmenu)
    local dialog
    local help = _([[Server address: where your Omnivore API runs. For self-hosted Omnivore that is usually the API port, e.g. https://omnivore.example.com:4000 (the plugin adds /api/graphql itself).

API key: create one in Omnivore's web app under Settings → API Keys, then paste it here. On devices without a clipboard you can also put it in koreader/settings/omnivore.lua as api_key.]])
    dialog = MultiInputDialog:new{
        title = _("Omnivore server"),
        fields = {
            {
                description = _("Server address"),
                text = self:get("server_url"),
                hint = "https://omnivore.example.com:4000",
            },
            {
                description = _("API key"),
                text = self:get("api_key"),
                hint = "00000000-0000-0000-0000-000000000000",
                text_type = "password",
            },
        },
        buttons = {
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
                { text = _("Help"), callback = function() UIManager:show(InfoMessage:new{ text = help }) end },
            },
            {
                {
                    text = _("Test"),
                    callback = function()
                        local f = dialog:getFields()
                        self:testConnection(OmnivoreAPI.normalizeServerURL(f[1]), trim(f[2]))
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local f = dialog:getFields()
                        local server, key = OmnivoreAPI.normalizeServerURL(f[1]), trim(f[2])
                        self:set("server_url", server)
                        self:set("api_key", key)
                        UIManager:close(dialog)
                        if touchmenu then touchmenu:updateItems() end
                        if server ~= "" and key ~= "" then self:testConnection(server, key) end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Omnivore:chooseLabel(callback)
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Loading labels…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local labels, err, detail = self:api():labels()
        UIManager:close(info)
        if not labels then
            UIManager:show(InfoMessage:new{ text = errorText(err, detail) })
            return
        end
        if #labels == 0 then
            UIManager:show(InfoMessage:new{ text = _("Your Omnivore library has no labels yet.") })
            return
        end
        local dialog
        local buttons = {}
        for _i, name in ipairs(labels) do
            table.insert(buttons, {{ text = name, callback = function() UIManager:close(dialog) callback(name) end }})
        end
        dialog = ButtonDialog:new{ title = _("Choose a label"), title_align = "center", buttons = buttons, rows_per_page = 10 }
        UIManager:show(dialog)
    end)
end

function Omnivore:editQuery(touchmenu)
    local dialog
    dialog = InputDialog:new{
        title = _("Custom search"),
        input = self:get("filter_query") ~= "" and self:get("filter_query") or "in:inbox sort:saved-desc",
        description = _("Omnivore search syntax, for example:\nin:inbox label:news sort:saved-desc\nin:inbox is:unread -label:long"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Use"),
                is_enter_default = true,
                callback = function()
                    self:set("filter_query", trim(dialog:getInputText()))
                    self:set("filter", "query")
                    UIManager:close(dialog)
                    if touchmenu then touchmenu:updateItems() end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

---------------------------------------------------------------------------------------------------
-- Menu
---------------------------------------------------------------------------------------------------

function Omnivore:syncMenuText()
    local extras = {}
    local last = stateStore().data.last_sync_time
    if last then table.insert(extras, T(_("last: %1"), ago(last))) end
    local pending = #queue()
    if pending > 0 then table.insert(extras, T(N_("1 waiting", "%1 waiting", pending), pending)) end
    if #extras == 0 then return _("Sync now") end
    return T(_("Sync now (%1)"), table.concat(extras, ", "))
end

function Omnivore:currentArticleId()
    local path = self.ui.document and self.ui.document.file
    return path and self:getArticleId(path)
end

function Omnivore:addToMainMenu(menu_items)
    menu_items.omnivore = {
        text = _("Omnivore"),
        sub_item_table_func = function() return self:getMenuItems() end,
    }
end

function Omnivore:getMenuItems()
    local items = {}
    if not self:isConfigured() then
        table.insert(items, {
            text = _("Set up Omnivore…"),
            keep_menu_open = true,
            callback = function(touchmenu) self:editServerSettings(touchmenu) end,
            separator = true,
        })
    else
        table.insert(items, {
            text_func = function() return self:syncMenuText() end,
            callback = function() self.ui:handleEvent(Event:new("SynchronizeOmnivore")) end,
        })
    end
    table.insert(items, {
        text = _("Browse library"),
        enabled_func = function() return self:isConfigured() end,
        callback = function() self.ui:handleEvent(Event:new("BrowseOmnivore")) end,
    })
    table.insert(items, {
        text = _("Save a link…"),
        callback = function() self:showSaveLinkDialog() end,
    })
    table.insert(items, {
        text = _("Open download folder"),
        callback = function() self.ui:handleEvent(Event:new("GoToOmnivoreFolder")) end,
        separator = true,
    })
    if self.ui.document then
        table.insert(items, {
            text = _("This article"),
            enabled_func = function() return self:currentArticleId() ~= nil end,
            separator = true,
            sub_item_table = {
                {
                    text = _("Archive in Omnivore and close"),
                    callback = function() self:onArchiveOmnivoreArticle() end,
                },
                {
                    text = _("Send highlights and progress now"),
                    callback = function() self:sendCurrentNow() end,
                },
                {
                    text = _("Delete from Omnivore…"),
                    callback = function() self:deleteCurrent() end,
                },
            },
        })
    end
    table.insert(items, {
        text = _("Settings"),
        sub_item_table_func = function() return self:getSettingsItems() end,
    })
    table.insert(items, {
        text = _("About"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _([[Omnivore for KOReader

Sync downloads the newest articles from your Omnivore inbox (or the label or search you choose), sends your highlights, notes and reading progress back to Omnivore, and archives the articles you finish.

Mark an article as finished (or use "This article → Archive") and it is archived in Omnivore at the next sync. Articles archived or deleted in the Omnivore app are removed from this device too.

Links you save while offline are sent at the next sync.

If you delete a downloaded article yourself, sync won't download it again; use Browse library to get it back.]]),
            })
        end,
    })
    return items
end

function Omnivore:getSettingsItems()
    local function toggle(key, text, help)
        return {
            text = text,
            help_text = help,
            checked_func = function() return self:get(key) end,
            callback = function() self:set(key, not self:get(key)) end,
        }
    end
    local function afterChoice(value, text)
        return {
            text = text,
            radio = true,
            checked_func = function() return self:get("after_archive") == value end,
            callback = function() self:set("after_archive", value) end,
        }
    end
    return {
        {
            text_func = function()
                return self:isConfigured() and T(_("Server: %1"), self:get("server_url")) or _("Server and API key…")
            end,
            keep_menu_open = true,
            callback = function(touchmenu) self:editServerSettings(touchmenu) end,
        },
        {
            text_func = function()
                return T(_("Download folder: %1"), require("apps/filemanager/filemanagerutil").abbreviate(self:getDirectory()))
            end,
            keep_menu_open = true,
            callback = function(touchmenu)
                require("ui/downloadmgr"):new{
                    onConfirm = function(path)
                        self:set("directory", path)
                        if touchmenu then touchmenu:updateItems() end
                    end,
                }:chooseDir(self:getDirectory())
            end,
            separator = true,
        },
        {
            text_func = function() return T(_("What to download: %1"), self:filterDescription()) end,
            sub_item_table = {
                {
                    text = _("Newest in the inbox"),
                    radio = true,
                    checked_func = function() return self:get("filter") == "inbox" end,
                    callback = function() self:set("filter", "inbox") end,
                },
                {
                    text_func = function()
                        local l = self:get("filter_label")
                        return l ~= "" and T(_("Inbox items labelled “%1”"), l) or _("Inbox items with a label…")
                    end,
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function() return self:get("filter") == "label" end,
                    callback = function(touchmenu)
                        self:chooseLabel(function(label)
                            self:set("filter_label", label)
                            self:set("filter", "label")
                            if touchmenu then touchmenu:updateItems() end
                        end)
                    end,
                },
                {
                    text = _("Custom search…"),
                    radio = true,
                    keep_menu_open = true,
                    checked_func = function() return self:get("filter") == "query" end,
                    callback = function(touchmenu) self:editQuery(touchmenu) end,
                    separator = true,
                },
                {
                    text_func = function() return T(_("Articles per sync: %1"), self:get("articles_per_sync")) end,
                    keep_menu_open = true,
                    callback = function(touchmenu)
                        UIManager:show(SpinWidget:new{
                            title_text = _("Articles per sync"),
                            info_text = _("How many articles from the top of the list to keep on this device."),
                            value = self:get("articles_per_sync"),
                            value_min = 1,
                            value_max = 200,
                            value_step = 1,
                            value_hold_step = 10,
                            default_value = DEFAULTS.articles_per_sync,
                            callback = function(spin)
                                self:set("articles_per_sync", spin.value)
                                if touchmenu then touchmenu:updateItems() end
                            end,
                        })
                    end,
                },
                toggle("download_images", _("Download images"),
                    _("Save the articles' images so they show offline. Turn off for smaller, faster downloads.")),
            },
        },
        {
            text = _("When you finish an article"),
            sub_item_table = {
                toggle("archive_finished", _("Archive it in Omnivore when marked as finished")),
                toggle("archive_read", _("Also archive it when read to the end")),
                {
                    text = _("Then, on this device:"),
                    enabled_func = function() return false end,
                },
                afterChoice("delete", _("Delete the local copy")),
                afterChoice("move", _("Move it to the “archive” subfolder")),
                afterChoice("keep", _("Keep it where it is")),
            },
        },
        {
            text = _("Send to Omnivore"),
            sub_item_table = {
                toggle("send_highlights", _("Highlights and notes"),
                    _("New highlights appear in place in the article in Omnivore; edited notes are updated.")),
                toggle("send_progress", _("Reading progress")),
                toggle("send_on_close", _("Send right after closing an article"),
                    _("Otherwise they are sent at the next sync.")),
            },
        },
    }
end

return Omnivore
