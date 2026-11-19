--[[--
Builds the location "patch" Omnivore uses to place a highlight inside an article.

Omnivore's web reader stores where a highlight sits as a diff-match-patch patch that turns
the article's plain text into the same text with `<omnivore_highlight>` tags around the
quote (see packages/web/lib/highlights/highlightGenerator.ts, generateDiffPatch). The apps
apply that patch with fuzzy matching, so a patch built from the article HTML we downloaded
is enough for KOReader highlights to show up in place in Omnivore.

Pure Lua with no KOReader dependencies, so it can be tested on its own.

@module highlightlocator
]]

local Locator = {}

local START_TAG = "<omnivore_highlight>"
local END_TAG = "</omnivore_highlight>"
local MARGIN = 4      -- diff-match-patch Patch_Margin
local MAX_BITS = 32   -- diff-match-patch Match_MaxBits

-- HTML 4 named entities (name -> code point), generated from Python's html.entities.
local NAMED_ENTITIES = {
    ["AElig"]=198, ["Aacute"]=193, ["Acirc"]=194, ["Agrave"]=192, ["Alpha"]=913, ["Aring"]=197, ["Atilde"]=195, ["Auml"]=196,
    ["Beta"]=914, ["Ccedil"]=199, ["Chi"]=935, ["Dagger"]=8225, ["Delta"]=916, ["ETH"]=208, ["Eacute"]=201, ["Ecirc"]=202,
    ["Egrave"]=200, ["Epsilon"]=917, ["Eta"]=919, ["Euml"]=203, ["Gamma"]=915, ["Iacute"]=205, ["Icirc"]=206, ["Igrave"]=204,
    ["Iota"]=921, ["Iuml"]=207, ["Kappa"]=922, ["Lambda"]=923, ["Mu"]=924, ["Ntilde"]=209, ["Nu"]=925, ["OElig"]=338, ["Oacute"]=211,
    ["Ocirc"]=212, ["Ograve"]=210, ["Omega"]=937, ["Omicron"]=927, ["Oslash"]=216, ["Otilde"]=213, ["Ouml"]=214, ["Phi"]=934,
    ["Pi"]=928, ["Prime"]=8243, ["Psi"]=936, ["Rho"]=929, ["Scaron"]=352, ["Sigma"]=931, ["THORN"]=222, ["Tau"]=932, ["Theta"]=920,
    ["Uacute"]=218, ["Ucirc"]=219, ["Ugrave"]=217, ["Upsilon"]=933, ["Uuml"]=220, ["Xi"]=926, ["Yacute"]=221, ["Yuml"]=376,
    ["Zeta"]=918, ["aacute"]=225, ["acirc"]=226, ["acute"]=180, ["aelig"]=230, ["agrave"]=224, ["alefsym"]=8501, ["alpha"]=945,
    ["amp"]=38, ["and"]=8743, ["ang"]=8736, ["aring"]=229, ["asymp"]=8776, ["atilde"]=227, ["auml"]=228, ["bdquo"]=8222, ["beta"]=946,
    ["brvbar"]=166, ["bull"]=8226, ["cap"]=8745, ["ccedil"]=231, ["cedil"]=184, ["cent"]=162, ["chi"]=967, ["circ"]=710,
    ["clubs"]=9827, ["cong"]=8773, ["copy"]=169, ["crarr"]=8629, ["cup"]=8746, ["curren"]=164, ["dArr"]=8659, ["dagger"]=8224,
    ["darr"]=8595, ["deg"]=176, ["delta"]=948, ["diams"]=9830, ["divide"]=247, ["eacute"]=233, ["ecirc"]=234, ["egrave"]=232,
    ["empty"]=8709, ["emsp"]=8195, ["ensp"]=8194, ["epsilon"]=949, ["equiv"]=8801, ["eta"]=951, ["eth"]=240, ["euml"]=235,
    ["euro"]=8364, ["exist"]=8707, ["fnof"]=402, ["forall"]=8704, ["frac12"]=189, ["frac14"]=188, ["frac34"]=190, ["frasl"]=8260,
    ["gamma"]=947, ["ge"]=8805, ["gt"]=62, ["hArr"]=8660, ["harr"]=8596, ["hearts"]=9829, ["hellip"]=8230, ["iacute"]=237,
    ["icirc"]=238, ["iexcl"]=161, ["igrave"]=236, ["image"]=8465, ["infin"]=8734, ["int"]=8747, ["iota"]=953, ["iquest"]=191,
    ["isin"]=8712, ["iuml"]=239, ["kappa"]=954, ["lArr"]=8656, ["lambda"]=955, ["lang"]=9001, ["laquo"]=171, ["larr"]=8592,
    ["lceil"]=8968, ["ldquo"]=8220, ["le"]=8804, ["lfloor"]=8970, ["lowast"]=8727, ["loz"]=9674, ["lrm"]=8206, ["lsaquo"]=8249,
    ["lsquo"]=8216, ["lt"]=60, ["macr"]=175, ["mdash"]=8212, ["micro"]=181, ["middot"]=183, ["minus"]=8722, ["mu"]=956, ["nabla"]=8711,
    ["nbsp"]=160, ["ndash"]=8211, ["ne"]=8800, ["ni"]=8715, ["not"]=172, ["notin"]=8713, ["nsub"]=8836, ["ntilde"]=241, ["nu"]=957,
    ["oacute"]=243, ["ocirc"]=244, ["oelig"]=339, ["ograve"]=242, ["oline"]=8254, ["omega"]=969, ["omicron"]=959, ["oplus"]=8853,
    ["or"]=8744, ["ordf"]=170, ["ordm"]=186, ["oslash"]=248, ["otilde"]=245, ["otimes"]=8855, ["ouml"]=246, ["para"]=182,
    ["part"]=8706, ["permil"]=8240, ["perp"]=8869, ["phi"]=966, ["pi"]=960, ["piv"]=982, ["plusmn"]=177, ["pound"]=163, ["prime"]=8242,
    ["prod"]=8719, ["prop"]=8733, ["psi"]=968, ["quot"]=34, ["rArr"]=8658, ["radic"]=8730, ["rang"]=9002, ["raquo"]=187, ["rarr"]=8594,
    ["rceil"]=8969, ["rdquo"]=8221, ["real"]=8476, ["reg"]=174, ["rfloor"]=8971, ["rho"]=961, ["rlm"]=8207, ["rsaquo"]=8250,
    ["rsquo"]=8217, ["sbquo"]=8218, ["scaron"]=353, ["sdot"]=8901, ["sect"]=167, ["shy"]=173, ["sigma"]=963, ["sigmaf"]=962,
    ["sim"]=8764, ["spades"]=9824, ["sub"]=8834, ["sube"]=8838, ["sum"]=8721, ["sup"]=8835, ["sup1"]=185, ["sup2"]=178, ["sup3"]=179,
    ["supe"]=8839, ["szlig"]=223, ["tau"]=964, ["there4"]=8756, ["theta"]=952, ["thetasym"]=977, ["thinsp"]=8201, ["thorn"]=254,
    ["tilde"]=732, ["times"]=215, ["trade"]=8482, ["uArr"]=8657, ["uacute"]=250, ["uarr"]=8593, ["ucirc"]=251, ["ugrave"]=249,
    ["uml"]=168, ["upsih"]=978, ["upsilon"]=965, ["uuml"]=252, ["weierp"]=8472, ["xi"]=958, ["yacute"]=253, ["yen"]=165, ["yuml"]=255,
    ["zeta"]=950, ["zwj"]=8205, ["zwnj"]=8204,
}

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                           0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return ""
end

--- Decode numeric and named (HTML 4) character references, as a browser would.
-- KOReader's util.htmlEntitiesToUtf8 only knows a handful of names, and every character that
-- decodes differently from the browser shifts the highlight's position.
function Locator.decodeEntities(s)
    return (s:gsub("&(#?[%w]+);", function(ref)
        local cp
        if ref:match("^#[xX]%x+$") then
            cp = tonumber(ref:sub(3), 16)
        elseif ref:match("^#%d+$") then
            cp = tonumber(ref:sub(2))
        else
            cp = NAMED_ENTITIES[ref]
        end
        if cp then return utf8char(cp) end
    end))
end

--- Plain text of an article's HTML, close to what a browser's Range.toString() returns
-- for the same markup: tags removed, entities decoded, whitespace kept as is.
function Locator.htmlToText(html, decode)
    html = html:gsub("\r\n?", "\n")
    html = html:gsub("<!%-%-.-%-%->", "")
    for _, tag in ipairs({ "script", "style", "noscript", "template" }) do
        local pat = "<" .. tag:gsub("%a", function(c) return "[" .. c:lower() .. c:upper() .. "]" end)
        html = html:gsub(pat .. "[%s>].-</" .. pat:sub(2) .. "%s*>", "")
    end
    html = html:gsub("<[^>]*>", "")
    return (decode or Locator.decodeEntities)(html)
end

-- Length of a UTF-8 string in UTF-16 code units (JavaScript string length).
local function jslen(s)
    local _, continuation = s:gsub("[\128-\191]", "")
    local _, astral = s:gsub("[\240-\244]", "")
    return #s - continuation + astral
end
Locator.jslen = jslen

-- Byte index of the start of the character `n` characters before byte `pos` (1-based).
local function backChars(s, pos, n)
    local i = pos
    while n > 0 and i > 1 do
        i = i - 1
        while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
        n = n - 1
    end
    return i
end

-- Byte index just after `n` characters starting at byte `pos`.
local function forwardChars(s, pos, n)
    local i = pos
    local len = #s
    while n > 0 and i <= len do
        i = i + 1
        while i <= len and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i + 1 end
        n = n - 1
    end
    return i
end

-- JavaScript encodeURI(), then %20 back to a space, as diff-match-patch's patch_toText does.
local function encodeURI(s)
    return (s:gsub("[^%w;,/%?:@&=%+%$%-_%.!~%*'%(%)# ]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end
Locator.encodeURI = encodeURI

local function isUnique(text, pattern)
    local first = text:find(pattern, 1, true)
    return first ~= nil and text:find(pattern, first + 1, true) == nil
end

--- Context around text[a, b) the way diff-match-patch's patch_addContext picks it:
-- grow by MARGIN until the pattern is unique (or long enough), then add MARGIN more.
local function context(text, a, b)
    local padding = 0
    local pattern = text:sub(a, b - 1)
    while not isUnique(text, pattern) and jslen(pattern) < MAX_BITS - 2 * MARGIN do
        padding = padding + MARGIN
        pattern = text:sub(backChars(text, a, padding), forwardChars(text, b, padding) - 1)
    end
    padding = padding + MARGIN
    local pre_start = backChars(text, a, padding)
    local post_end = forwardChars(text, b, padding)
    return text:sub(pre_start, a - 1), text:sub(b, post_end - 1), pre_start
end

local function coords(start, length)
    if length == 0 then return start .. ",0" end
    if length == 1 then return tostring(start + 1) end
    return (start + 1) .. "," .. length
end

local function hunk(start, len1, len2, lines)
    local out = { "@@ -" .. coords(start, len1) .. " +" .. coords(start, len2) .. " @@\n" }
    for _, l in ipairs(lines) do
        if l[2] ~= "" then table.insert(out, l[1] .. encodeURI(l[2]) .. "\n") end
    end
    return table.concat(out)
end

--- Collapse whitespace so a quote from KOReader (normalised by the renderer) can be found in
-- the raw article text. Returns the normalised string and, for each word, its byte position in
-- both strings.
local function normalise(text)
    -- NBSP (2 bytes) -> 2 spaces keeps byte positions unchanged.
    local t = text:gsub("\194\160", "  ")
    local words, raw_pos, norm_pos = {}, {}, {}
    local n = 1
    for p, w in t:gmatch("()(%S+)") do
        table.insert(words, w)
        table.insert(raw_pos, p)
        table.insert(norm_pos, n)
        n = n + #w + 1
    end
    return table.concat(words, " "), raw_pos, norm_pos
end

-- Map a byte position in the normalised string back to the raw text.
local function toRaw(pos, raw_pos, norm_pos)
    local lo, hi = 1, #norm_pos
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if norm_pos[mid] <= pos then lo = mid else hi = mid - 1 end
    end
    if not norm_pos[lo] then return nil end
    return raw_pos[lo] + (pos - norm_pos[lo])
end

--- Find `quote` in `text`. `hint` (0..1) picks the nearest match when the quote repeats.
-- Returns raw byte positions [a, b) or nil.
function Locator.find(text, quote, hint)
    local norm, raw_pos, norm_pos = normalise(text)
    local q = quote:gsub("\194\160", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
    if q == "" then return nil end
    local best, best_dist
    local target = (hint or 0) * #norm
    local init = 1
    while true do
        local s = norm:find(q, init, true)
        if not s then break end
        local dist = math.abs(s - target)
        if not best or dist < best_dist then best, best_dist = s, dist end
        init = s + 1
    end
    if not best then return nil end
    local a = toRaw(best, raw_pos, norm_pos)
    local last = toRaw(best + #q - 1, raw_pos, norm_pos)
    if not a or not last then return nil end
    return a, last + 1
end

--- Build the Omnivore patch for the highlight text[a, b) (raw byte positions, b exclusive).
-- Returns patch, quote, prefix, suffix, percent.
function Locator.patchFor(text, a, b)
    local quote = text:sub(a, b - 1)
    local qlen = jslen(quote)
    local start_js = jslen(text:sub(1, a - 1))
    local percent = #text > 0 and (100 * (a - 1) / #text) or 0
    local prefix = text:sub(backChars(text, a, 100), a - 1)
    local suffix = text:sub(b, forwardChars(text, b, 100) - 1)

    if qlen <= #START_TAG then
        -- diff_cleanupSemantic folds an equality no longer than the edits around it into them,
        -- so a short quote becomes one hunk that replaces the quote with the tagged quote.
        local pre, post = context(text, a, b)
        local start = start_js - jslen(pre)
        local len1 = jslen(pre) + qlen + jslen(post)
        local patch = hunk(start, len1, len1 + #START_TAG + #END_TAG, {
            { " ", pre }, { "-", quote }, { "+", START_TAG .. quote .. END_TAG }, { " ", post },
        })
        return patch, quote, prefix, suffix, percent
    end

    -- Two hunks. The second is computed on the text after the first insertion, as patch_make does.
    local pre1, post1 = context(text, a, a)
    local start1 = start_js - jslen(pre1)
    local len1 = jslen(pre1) + jslen(post1)
    local h1 = hunk(start1, len1, len1 + #START_TAG, { { " ", pre1 }, { "+", START_TAG }, { " ", post1 } })

    local text2 = text:sub(1, a - 1) .. START_TAG .. text:sub(a)
    local e2 = b + #START_TAG
    local pre2, post2 = context(text2, e2, e2)
    local start2 = jslen(text2:sub(1, e2 - 1)) - jslen(pre2)
    local len2 = jslen(pre2) + jslen(post2)
    local h2 = hunk(start2, len2, len2 + #END_TAG, { { " ", pre2 }, { "+", END_TAG }, { " ", post2 } })

    return h1 .. h2, quote, prefix, suffix, percent
end

--- Convenience: locate `quote` in the article HTML and build the patch.
-- Returns a table { patch, quote, prefix, suffix, percent } or nil if the quote isn't found.
function Locator.locate(html, quote, hint, decode)
    local text = Locator.htmlToText(html, decode)
    local a, b = Locator.find(text, quote, hint)
    if not a then return nil end
    local patch, q, prefix, suffix, percent = Locator.patchFor(text, a, b)
    return { patch = patch, quote = q, prefix = prefix, suffix = suffix, percent = percent }
end

return Locator
