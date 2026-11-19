-- Builds Omnivore highlight patches for sample quotes; test/check_patches.py verifies them.
-- Usage: luajit test/gen_patches.lua <repo dir> <sample.html> <out dir>
package.path = arg[1] .. "/?.lua;" .. package.path
local Locator = require("highlightlocator")

local html = assert(io.open(arg[2])):read("*a")
local out_dir = arg[3]
local text = Locator.htmlToText(html)
assert(io.open(out_dir .. "/text.txt", "w")):write(text)

-- Quotes as KOReader would hand them over (whitespace normalised), with a position hint.
local cases = {
    { "Most of what we save is never read.", 0.0 },
    { "the reading part effortless: a quiet device, a clean page, and no notifications.", 0.1 },
    { "Read it later; read it on paper-like glass.", 0.4 },
    { "Read it later.", 0.6 },              -- repeated phrase: the hint picks the occurrence
    { "Read it later, but do read it.", 0.6 }, -- crosses a &nbsp;
    { "改善", 0.6 },                         -- non-ASCII, short
    { "A 5 % improvement every week is a 13× improvement in a year.", 0.65 },
    { "and keep it.", 0.75 },
    { "📚 — and so do accents: café, naïve, façade.", 0.8 }, -- astral char: UTF-16 positions
    { "if read then archive() end", 0.9 },  -- crosses newlines inside <pre>
    { "The end.", 1.0 },
    { "a", 0.5 },                            -- tiny and everywhere
}

local function esc(s)
    return (s:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end))
end

local out = assert(io.open(out_dir .. "/cases.jsonl", "w"))
for _, case in ipairs(cases) do
    local a, b = Locator.find(text, case[1], case[2])
    if a then
        local patch = Locator.patchFor(text, a, b)
        out:write(string.format('{"quote":"%s","a":%d,"b":%d,"patch":"%s"}\n', esc(case[1]), a, b, esc(patch)))
    else
        out:write(string.format('{"quote":"%s","a":null}\n', esc(case[1])))
    end
end
out:close()
