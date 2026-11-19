--[[--
Minimal client for the Omnivore GraphQL API (hosted or self-hosted).

Every call returns `result` on success, or `nil, err_kind, detail` on failure, where
`err_kind` is one of "network", "auth", "http", "json", "api".

@module omnivoreapi
]]

local JSON = require("json")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local OmnivoreAPI = {
    server_url = nil, -- e.g. "https://omnivore.example.com" (no trailing /api/graphql)
    api_key = nil,
    block_timeout = nil, -- seconds; defaults to socketutil's LARGE_* values
    total_timeout = nil,
}

function OmnivoreAPI:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

--- Accepts "host", "https://host/", "https://host:4000/api/graphql" and returns "https://host[:port]".
function OmnivoreAPI.normalizeServerURL(url)
    if type(url) ~= "string" then return "" end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return "" end
    if not url:match("^https?://") then
        url = "https://" .. url
    end
    url = url:gsub("/+$", "")
    url = url:gsub("/api/graphql$", "")
    url = url:gsub("/+$", "")
    return url
end

-- JSON libraries differ in how they represent null; only accept real values.
local function str(v) return type(v) == "string" and v or nil end
local function num(v) return type(v) == "number" and v or nil end
local function tbl(v) return type(v) == "table" and v or nil end
OmnivoreAPI.str, OmnivoreAPI.num, OmnivoreAPI.tbl = str, num, tbl

--- Random UUID v4 (Omnivore expects client-generated IDs for highlights and saves).
function OmnivoreAPI.uuid()
    local f = io.open("/proc/sys/kernel/random/uuid", "r")
    if f then
        local id = f:read("*l")
        f:close()
        if id and #id == 36 then return id end
    end
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
        return string.format("%x", v)
    end))
end

--- Low-level GraphQL POST.
function OmnivoreAPI:request(query, variables, opts)
    opts = opts or {}
    if not self.server_url or self.server_url == "" or not self.api_key or self.api_key == "" then
        return nil, "auth", "not configured"
    end
    local payload = { query = query }
    if variables then payload.variables = variables end
    local body = JSON.encode(payload)
    local sink = {}
    local request = {
        url = self.server_url .. "/api/graphql",
        method = "POST",
        headers = {
            ["Authorization"] = self.api_key,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Content-Length"] = tostring(#body),
            ["User-Agent"] = "KOReader-omnivore.koplugin",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    }
    socketutil:set_timeout(opts.block_timeout or self.block_timeout or socketutil.LARGE_BLOCK_TIMEOUT,
                           opts.total_timeout or self.total_timeout or socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if headers == nil then
        logger.warn("Omnivore: network error", status or code)
        return nil, "network", tostring(status or code)
    end
    local content = table.concat(sink)
    local ok, result = pcall(JSON.decode, content)
    if not ok or type(result) ~= "table" then
        logger.warn("Omnivore: HTTP", code, "non-JSON response:", content:sub(1, 200))
        if code == 401 or code == 403 then return nil, "auth", code end
        return nil, (code == 200) and "json" or "http", code
    end
    if code ~= 200 then
        -- Omnivore answers an unknown API key with HTTP 500 and {"errors":[{}]}.
        logger.warn("Omnivore: HTTP", code, content:sub(1, 200))
        if code == 401 or code == 403 or (code == 500 and tbl(result.errors) and not tbl(result.data)) then
            return nil, "auth", code
        end
        return nil, "http", code
    end
    if tbl(result.errors) and not tbl(result.data) then
        local first = result.errors[1]
        local msg = type(first) == "table" and str(first.message) or "unknown error"
        logger.warn("Omnivore: GraphQL error", msg)
        return nil, "api", msg
    end
    return result.data or {}
end

--- Unwraps a union result such as `{ __typename = "XSuccess", ... }` / `{ errorCodes = {...} }`.
local function unwrap(data, field)
    local r = data and tbl(data[field])
    if not r then return nil, "api", "empty response" end
    if tbl(r.errorCodes) then
        return nil, "api", table.concat(r.errorCodes, ", ")
    end
    return r
end

-- Fields used for every downloaded/listed item.
local ITEM_FIELDS = [[
    id title slug url originalArticleUrl author siteName description
    wordsCount savedAt publishedAt readingProgressPercent isArchived
    state contentReader pageType
    labels { name color }
]]

function OmnivoreAPI:me()
    local data, err, detail = self:request([[query { me { id name profile { username } } }]])
    if not data then return nil, err, detail end
    local me = tbl(data.me)
    if not me then return nil, "auth", "no user" end
    return {
        id = str(me.id),
        name = str(me.name),
        username = me.profile and str(me.profile.username),
    }
end

--- One page of search results. Returns { items = {...}, has_next = bool, cursor = string, total = n }.
function OmnivoreAPI:search(query, first, after, include_content)
    local q = [[
        query Search($after: String, $first: Int, $query: String, $includeContent: Boolean) {
            search(first: $first, after: $after, query: $query, includeContent: $includeContent, format: "html") {
                ... on SearchSuccess {
                    edges { node { ]] .. ITEM_FIELDS .. (include_content and " content" or "") .. [[ } }
                    pageInfo { hasNextPage endCursor totalCount }
                }
                ... on SearchError { errorCodes }
            }
        }
    ]]
    local data, err, detail = self:request(q, {
        query = query, first = first or 20, after = after, includeContent = include_content and true or false,
    })
    if not data then return nil, err, detail end
    local r, uerr, udetail = unwrap(data, "search")
    if not r then return nil, uerr, udetail end
    local items = {}
    for _, edge in ipairs(tbl(r.edges) or {}) do
        if tbl(edge.node) then table.insert(items, edge.node) end
    end
    local page = tbl(r.pageInfo) or {}
    return {
        items = items,
        has_next = page.hasNextPage == true,
        cursor = str(page.endCursor),
        total = num(page.totalCount),
    }
end

--- Full content of one article, by slug (used when opening an item from the browse list).
function OmnivoreAPI:article(slug)
    local q = [[
        query GetArticle($slug: String!) {
            article(username: "me", slug: $slug, format: "html") {
                ... on ArticleSuccess { article { ]] .. ITEM_FIELDS:gsub("state contentReader pageType", "contentReader pageType") .. [[ content } }
                ... on ArticleError { errorCodes }
            }
        }
    ]]
    local data, err, detail = self:request(q, { slug = slug })
    if not data then return nil, err, detail end
    local r, uerr, udetail = unwrap(data, "article")
    if not r then return nil, uerr, udetail end
    return tbl(r.article)
end

--- Items created, updated or deleted since an ISO date. Returns { edges = {...}, has_next, cursor }.
function OmnivoreAPI:updatesSince(since, after)
    local q = [[
        query Updates($since: Date!, $after: String) {
            updatesSince(since: $since, after: $after, first: 100) {
                ... on UpdatesSinceSuccess {
                    edges { updateReason itemID node { id isArchived } }
                    pageInfo { hasNextPage endCursor }
                }
                ... on UpdatesSinceError { errorCodes }
            }
        }
    ]]
    local data, err, detail = self:request(q, { since = since, after = after })
    if not data then return nil, err, detail end
    local r, uerr, udetail = unwrap(data, "updatesSince")
    if not r then return nil, uerr, udetail end
    local page = tbl(r.pageInfo) or {}
    return { edges = tbl(r.edges) or {}, has_next = page.hasNextPage == true, cursor = str(page.endCursor) }
end

function OmnivoreAPI:setArchived(id, archived)
    local data, err, detail = self:request([[
        mutation Archive($input: ArchiveLinkInput!) {
            setLinkArchived(input: $input) {
                ... on ArchiveLinkSuccess { linkId }
                ... on ArchiveLinkError { errorCodes }
            }
        }
    ]], { input = { linkId = id, archived = archived ~= false } })
    if not data then return nil, err, detail end
    return unwrap(data, "setLinkArchived")
end

--- Deleting an item in Omnivore is "un-bookmarking" it.
function OmnivoreAPI:delete(id)
    local data, err, detail = self:request([[
        mutation Delete($input: SetBookmarkArticleInput!) {
            setBookmarkArticle(input: $input) {
                ... on SetBookmarkArticleSuccess { bookmarkedArticle { id } }
                ... on SetBookmarkArticleError { errorCodes }
            }
        }
    ]], { input = { articleID = id, bookmark = false } })
    if not data then return nil, err, detail end
    return unwrap(data, "setBookmarkArticle")
end

--- percent: 0..100
function OmnivoreAPI:saveProgress(id, percent)
    local data, err, detail = self:request([[
        mutation Progress($input: SaveArticleReadingProgressInput!) {
            saveArticleReadingProgress(input: $input) {
                ... on SaveArticleReadingProgressSuccess { updatedArticle { id } }
                ... on SaveArticleReadingProgressError { errorCodes }
            }
        }
    ]], { input = { id = id, readingProgressPercent = percent, readingProgressAnchorIndex = 0 } },
        { block_timeout = self.block_timeout or 10, total_timeout = self.total_timeout or 20 })
    if not data then return nil, err, detail end
    return unwrap(data, "saveArticleReadingProgress")
end

function OmnivoreAPI:saveUrl(url, labels)
    local input = { url = url, source = "koreader", clientRequestId = OmnivoreAPI.uuid() }
    if labels and #labels > 0 then
        input.labels = {}
        for _, name in ipairs(labels) do table.insert(input.labels, { name = name }) end
    end
    local data, err, detail = self:request([[
        mutation Save($input: SaveUrlInput!) {
            saveUrl(input: $input) {
                ... on SaveSuccess { url clientRequestId }
                ... on SaveError { errorCodes message }
            }
        }
    ]], { input = input })
    if not data then return nil, err, detail end
    return unwrap(data, "saveUrl")
end

--- highlight = { article_id, quote, note, color, percent (0..100), patch, prefix, suffix }
-- `patch` (see highlightlocator.lua) lets Omnivore show the highlight in place in the article;
-- without it the highlight still appears in the article's notebook.
function OmnivoreAPI:createHighlight(h)
    local input = {
        id = OmnivoreAPI.uuid(),
        shortId = OmnivoreAPI.uuid():gsub("-", ""):sub(1, 8),
        articleId = h.article_id,
        quote = h.quote,
        type = "HIGHLIGHT",
        color = h.color or "yellow",
    }
    if h.note and h.note ~= "" then input.annotation = h.note end
    if h.percent then input.highlightPositionPercent = h.percent end
    if h.patch then input.patch = h.patch end
    if h.prefix then input.prefix = h.prefix end
    if h.suffix then input.suffix = h.suffix end
    local data, err, detail = self:request([[
        mutation Highlight($input: CreateHighlightInput!) {
            createHighlight(input: $input) {
                ... on CreateHighlightSuccess { highlight { id } }
                ... on CreateHighlightError { errorCodes }
            }
        }
    ]], { input = input })
    if not data then return nil, err, detail end
    local r, uerr, udetail = unwrap(data, "createHighlight")
    if not r then return nil, uerr, udetail end
    return tbl(r.highlight) and str(r.highlight.id) or input.id
end

function OmnivoreAPI:updateHighlight(highlight_id, note, color)
    local input = { highlightId = highlight_id, annotation = note or "" }
    if color then input.color = color end
    local data, err, detail = self:request([[
        mutation UpdateHighlight($input: UpdateHighlightInput!) {
            updateHighlight(input: $input) {
                ... on UpdateHighlightSuccess { highlight { id } }
                ... on UpdateHighlightError { errorCodes }
            }
        }
    ]], { input = input })
    if not data then return nil, err, detail end
    return unwrap(data, "updateHighlight")
end

function OmnivoreAPI:labels()
    local data, err, detail = self:request([[
        query { labels { ... on LabelsSuccess { labels { name color } } ... on LabelsError { errorCodes } } }
    ]])
    if not data then return nil, err, detail end
    local r, uerr, udetail = unwrap(data, "labels")
    if not r then return nil, uerr, udetail end
    local names = {}
    for _, l in ipairs(tbl(r.labels) or {}) do
        if str(l.name) then table.insert(names, l.name) end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

return OmnivoreAPI
