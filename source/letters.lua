-- Letter-sprite text rendering, ported from emmenu.py Letters — the
-- original print() (EB.C:319-350) at native scale. Used by the main menu;
-- the presentation screens (milestone 7) will share it.

local gfx <const> = playdate.graphics

Letters = {}

local letterTable <const> = gfx.imagetable.new("images/letters")
assert(letterTable, "failed to load letters sprite set")

-- Sprite order in the letters set (emmenu.py PRINT_CHARS, verified against
-- the converted sprites): sprite 0 = space, 1-26 = a-z, 27-34 = Polish
-- accented letters, 35-44 = digits 0-9, 45-50 = ":|?()_" (50 is the boxed
-- block-cursor glyph).
local ORDER <const> = {
    "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
    "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "ą", "ć", "ę", "ł", "ń", "ó", "ś", "ż",
    "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ":", "|", "?", "(", ")", "_",
}

local glyphs = {}                  -- character -> glyph image
for i, ch in ipairs(ORDER) do
    glyphs[ch] = letterTable:getImage(i + 1)   -- cell N = sprite index N
end

-- one character at a time, grouping UTF-8 continuation bytes (the Polish
-- letters in ORDER are multi-byte strings)
local CHAR <const> = "[\1-\127\194-\244][\128-\191]*"

local function charCount(s)
    local n = 0
    for _ in s:gmatch(CHAR) do
        n = n + 1
    end
    return n
end

-- Pixel width of a rendered line (24 px grid, emmenu.py CHAR_WIDTH).
function Letters.width(text)
    return 24 * charCount(text)
end

-- Draw a single line at (x, y), no centering, no '*' handling. faded
-- dims the glyphs (the port's stand-in for the Python menu's gray-out).
function Letters.drawLine(text, x, y, faded)
    for ch in text:lower():gmatch(CHAR) do
        local glyph = glyphs[ch]
        if glyph then
            if faded then
                glyph:drawFaded(x, y, 0.5, gfx.image.kDitherTypeBayer4x4)
            else
                glyph:draw(x, y)
            end
        end
        x = x + 24
    end
end

-- Draw a line centered on the 400 px screen width.
function Letters.drawCentered(text, y, faded)
    Letters.drawLine(text, (400 - Letters.width(text)) // 2, y, faded)
end

-- Port of print() (EB.C:319-350): '*' separates lines and the text block
-- is centered on the area at (ox, oy) sized (w, h). Same deviation as the
-- Python port: the C px=py=255 mode centers on the bordered playfield;
-- here the block centers on the given area.
function Letters.printText(text, ox, oy, w, h)
    if text == "" then
        return
    end
    local lines = {}
    for line in (text .. "*"):gmatch("([^*]*)%*") do
        lines[#lines + 1] = line
    end
    local y = (h - 24 * #lines) // 2
    for _, line in ipairs(lines) do
        Letters.drawLine(line, ox + (w - 24 * charCount(line)) // 2, oy + y)
        y = y + 24
    end
end
