-- HUD: the two LED bars and the disk display overlaid on the bottom strip
-- of the play area, ported from emdisplay.py (LEDBar/DiskInfo/Indicators)
-- and emhero.py show_hud. All values native scale (the Python port's are
-- 2x): LED cells are 8x8 crops of info sprite 4, the disk icon a 9x8 crop
-- of info sprite 3.

local gfx <const> = playdate.graphics

Hud = {}

local infoTable = gfx.imagetable.new("images/info")
assert(infoTable, "failed to load info sprite set")

local function subImage(img, x, y, w, h)
    local out = gfx.image.new(w, h)
    gfx.pushContext(out)
    img:draw(-x, -y)
    gfx.popContext()
    return out
end

-- LED segment cells (emdisplay.py LEDBar: info sprite 4, five 16x16 crops 2x)
local ledsImg = infoTable:getImage(5)
local leds = {
    [0] = subImage(ledsImg, 0, 0, 8, 8),
    subImage(ledsImg, 8, 0, 8, 8),
    subImage(ledsImg, 16, 0, 8, 8),
    subImage(ledsImg, 0, 8, 8, 8),
    subImage(ledsImg, 8, 8, 8, 8),
}
-- disk icon (emdisplay.py DiskInfo: info sprite 3, an 18x16 crop 2x)
local diskImg = subImage(infoTable:getImage(4), 0, 0, 9, 8)

-- per-value LED cell layouts, values 0..6 (emdisplay.py Indicators)
local LEFT_MAP <const> = {
    [0] = {2, 3, 3, 3, 3, 3},
    {0, 3, 3, 3, 3, 3},
    {0, 0, 3, 3, 3, 3},
    {0, 0, 1, 3, 3, 3},
    {0, 0, 1, 2, 3, 3},
    {0, 0, 1, 2, 2, 3},
    {0, 0, 1, 2, 2, 2},
}
local RIGHT_MAP <const> = {
    [0] = {2, 3, 3, 3, 3, 3},
    {2, 1, 3, 3, 3, 3},
    {2, 1, 0, 3, 3, 3},
    {2, 1, 0, 0, 3, 3},
    {2, 1, 0, 0, 0, 3},
    {2, 1, 0, 0, 0, 0},
    {2, 1, 0, 0, 0, 0},
}

-- six mapped cells plus the closing terminator cell (LEDBar.display)
local function drawBar(x, y, map)
    for i = 1, 6 do
        leds[map[i]]:draw(x, y)
        x = x + 8
    end
    leds[4]:draw(x, y)
end

function Hud.draw()
    -- left bar: weapon temperature; right bar: power, blinking one level
    -- down while the magazine runs low (emhero.py show_hud)
    local power = Hero.power
    if Hero.ammo < 3 and Hero.power > 0 and (Game.counter & 0x02) ~= 0 then
        power = Hero.power - 1
    end
    drawBar(OFFX + 8, OFFY + 176, LEFT_MAP[Hero.temp % 7])
    drawBar(OFFX + 256, OFFY + 176, RIGHT_MAP[power % 7])
    -- collected disks, blinking once all 3 are in (EB.C:784)
    local disks = math.min(Game.disks, 3)
    if disks > 0 and (disks < 3 or (Game.counter & 0x04) ~= 0) then
        local x = OFFX + 72
        for _ = 1, disks do
            diskImg:draw(x, OFFY + 176)
            x = x + 11
        end
    end
end
