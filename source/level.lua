-- Level data: tile planes, sprite metadata, per-screen collision lists and
-- pre-baked screen images.
--
-- A native Electro Man screen is 13x8 tiles of 24px = 312x192, centered in the
-- Playdate 400x240 display. A level's screens hold 4 tile planes (painter order
-- 0..3); each plane is 104 cells (row-major, y*13 + x). A cell holds a sprite
-- index: 0 = empty, 1..63 = sprite set 1, 64..127 = sprite set 2. Sets are
-- loaded as 1-bit image tables baked by python/conversion/bake_playdate_images.py
-- (cell N = sprite index N, so getImage(i + 1)).
--
-- Sprite metadata comes from the per-set .ebs JSON (copied verbatim into
-- sprites/): 8 status bytes per sprite (SpriteData.load, emdata.py):
-- flags = sb[0], action = sb[1] & 0x1F, init = (sb[1] & 0xE0) >> 5,
-- param = sb[2]; bbox and per-side (L/R/T/B) passability come from sb[4..7],
-- in native units (SCALE = 1, the Python port's *2 is a desktop-window
-- artifact).

local gfx <const> = playdate.graphics

TILE = 24
COLS = 13
ROWS = 8
MAX_X = COLS * TILE   -- 312
MAX_Y = ROWS * TILE   -- 192
OFFX = (400 - MAX_X) // 2   -- 44
OFFY = (240 - MAX_Y) // 2   -- 24

-- sprite action codes (emdata.py Level.init_functions)
local ACTION_CHECKPOINT <const> = 12
local ACTION_TELEPORT <const> = 13

Level = {
    name = nil,
    data = nil,
    tables = nil,       -- two sprite-set image tables
    status = nil,       -- two status-byte arrays
    screenNumber = 0,
    actives = nil,      -- per-screen active entity lists, built at load
    active = nil,       -- current screen's active entity list
    collisions = nil,   -- current screen: list of {x, y, w, h, L, R, T, B}
    bgImage = nil,      -- current screen: tiles behind the hero
    frontImage = nil,   -- current screen: in_front tiles, drawn over the hero
    droppedFloors = {}, -- screens whose bottom collision row a killing-floor
                        -- trigger removed (EB_ENEM.C:491)
}

-- An active tile is anything flagged 0x80 except pure collision geometry
-- (flags exactly 0x80 with action 0) — emdata.py process().
local function isActiveTile(flags, action)
    return (flags & 0x80) ~= 0 and not (flags == 0x80 and action == 0)
end

function Level.load(name)
    Level.name = name
    Level.data = json.decodeFile("levels/" .. name .. ".ebl")
    assert(Level.data, "failed to load level: " .. name)
    Level.tables = {}
    Level.status = {}
    for i = 1, 2 do
        local setName = Level.data.names[i]
        Level.tables[i] = gfx.imagetable.new("images/" .. setName)
        assert(Level.tables[i], "failed to load sprite set: " .. setName)
        local ebs = json.decodeFile("sprites/" .. setName .. ".ebs")
        assert(ebs, "failed to load sprite metadata: " .. setName)
        Level.status[i] = ebs["status table"]
    end
    Level.buildActives()
end

-- Build every screen's active entity list, re-seeding the RNG per screen
-- exactly like emdata.py Level.load, so randomized initial delays/frames
-- match the reference. Entity state persists across screen changes (Python
-- keeps screen.active for the level's lifetime); rebuilding restores the
-- pristine state (Level.reset_screens).
function Level.buildActives()
    Level.actives = {}
    Level.droppedFloors = {}   -- a level reset restores removed floors
    for n = 0, 255 do
        Actives.initScreenRandoms(n)
        local list = {}
        local screen = Level.data.screens[n + 1]
        if screen then
            for plane = 1, 4 do
                local layer = screen[plane]
                if layer then
                    for i = 1, COLS * ROWS do
                        local sidx = layer[i]
                        if sidx ~= 0 then
                            local flags, action = Level.spriteStatus(sidx)
                            if isActiveTile(flags, action) then
                                local x = ((i - 1) % COLS) * TILE
                                local y = ((i - 1) // COLS) * TILE
                                local e, exSidx, exX, exY =
                                    Actives.create(sidx, x, y)
                                list[#list + 1] = e
                                if exSidx then
                                    list[#list + 1] =
                                        Actives.create(exSidx, exX, exY)
                                end
                            end
                        end
                    end
                end
            end
        end
        Level.actives[n + 1] = list
    end
end

-- Reset the level to pristine state on player death (init_level
-- EB.C:1382-1405 / emgame.py reset_level): rebuild all entities — which
-- restores vanished batteries/bombs — then re-remove the collected disks.
function Level.resetLevel(diskPositions)
    Level.buildActives()
    for _, d in ipairs(diskPositions) do
        local list = Level.actives[d.screen + 1]
        for i, e in ipairs(list) do
            if e.x == d.x and e.y == d.y then
                table.remove(list, i)
                break
            end
        end
    end
end

-- Killing-floor trigger: drop the bottom collision row of a screen, both
-- from the collision list and visually (emgame.py KillingFloor removes the
-- Screen's bottom-row collision objects; ours are baked, so rebake).
function Level.dropFloor(n)
    Level.droppedFloors[n] = true
    if n == Level.screenNumber then
        Level.changeScreen(n)
    end
end

-- Overwrite a sprite's param status byte for the rest of the level session
-- (special items halve their param in place, special_proc EB_HERO.C:562-584).
function Level.setSpriteParam(sidx, value)
    local st, base
    if sidx < 64 then
        st, base = Level.status[1], sidx * 8
    else
        st, base = Level.status[2], (sidx - 64) * 8
    end
    st[base + 3] = value
end

-- Return flags, action, param, touch, init for a level sprite index (1..127).
function Level.spriteStatus(sidx)
    local st, base
    if sidx < 64 then
        st, base = Level.status[1], sidx * 8
    else
        st, base = Level.status[2], (sidx - 64) * 8
    end
    return st[base + 1], st[base + 2] & 0x1F, st[base + 3], st[base + 4],
           (st[base + 2] & 0xE0) >> 5
end

-- Animation span containing a sprite: walk back to the first_frame flag
-- (0x01), then forward to the last_frame flag (0x02). emdata.py get_anim_ends.
function Level.animEnds(sidx)
    local s = sidx
    while s > 0 do
        local flags = Level.spriteStatus(s)
        if (flags & 0x01) ~= 0 then
            break
        end
        s = s - 1
    end
    local first = s
    while s < 128 do
        local flags = Level.spriteStatus(s)
        if (flags & 0x02) ~= 0 then
            break
        end
        s = s + 1
    end
    return first, math.min(s, 127)
end

-- Return native bbox (x, y, w, h) and L/R/T/B passability for a level sprite
-- index. A side collides when its status byte's high bit is clear.
function Level.spriteBox(sidx)
    local st, base
    if sidx < 64 then
        st, base = Level.status[1], sidx * 8
    else
        st, base = Level.status[2], (sidx - 64) * 8
    end
    local l, r, t, b = st[base + 5], st[base + 6], st[base + 7], st[base + 8]
    local x, y = l & 0x7F, t & 0x7F
    return x, y, (r & 0x7F) - x, (b & 0x7F) - y,
           (l & 0x80) == 0, (r & 0x80) == 0, (t & 0x80) == 0, (b & 0x80) == 0
end

-- Map a level sprite index to its image (or nil for empty).
function Level.tileImage(sidx)
    if sidx == 0 then
        return nil
    elseif sidx < 64 then
        return Level.tables[1]:getImage(sidx + 1)
    else
        return Level.tables[2]:getImage(sidx - 64 + 1)
    end
end

-- Find the level-start checkpoint: an active sprite with the checkpoint
-- action and param == 1 (emdata.py process(), EB.C level init).
-- Returns screen number and tile coords.
function Level.findStart()
    for n = 0, 255 do
        local screen = Level.data.screens[n + 1]
        if screen then
            for plane = 1, 4 do
                local layer = screen[plane]
                if layer then
                    for i = 1, COLS * ROWS do
                        local sidx = layer[i]
                        if sidx ~= 0 then
                            local flags, action, param = Level.spriteStatus(sidx)
                            if (flags & 0x80) ~= 0
                                    and action == ACTION_CHECKPOINT
                                    and param == 1 then
                                return n, (i - 1) % COLS, (i - 1) // COLS
                            end
                        end
                    end
                end
            end
        end
    end
    return 0, 0, 0
end

-- Pixel positions of teleport bases (action 13 tiles) on any screen — the
-- destination scan (emhero.py find_teleport_target) inspects screens other
-- than the active one.
function Level.teleportsOn(n)
    local result = {}
    local screen = Level.data.screens[n + 1]
    if screen then
        for plane = 1, 4 do
            local layer = screen[plane]
            if layer then
                for i = 1, COLS * ROWS do
                    local sidx = layer[i]
                    if sidx ~= 0 then
                        local flags, action = Level.spriteStatus(sidx)
                        if (flags & 0x80) ~= 0 and action == ACTION_TELEPORT then
                            result[#result + 1] = {
                                x = ((i - 1) % COLS) * TILE,
                                y = ((i - 1) // COLS) * TILE,
                            }
                        end
                    end
                end
            end
        end
    end
    return result
end

-- Switch the active screen: build its collision list (static tiles with
-- flags == 0x80 and action == 0, emdata.py process()) and pre-bake the
-- STATIC tile planes into two images split by the in_front flag (0x04) so
-- the hero can be drawn between them. Active tiles are not baked — they
-- live in Level.active and are updated/drawn per frame (Actives).
function Level.changeScreen(n)
    Level.screenNumber = n
    Level.active = Level.actives[n + 1]
    local cols = {}
    local front = {}
    local bg = gfx.image.new(MAX_X, MAX_Y, gfx.kColorBlack)
    local screen = Level.data.screens[n + 1]

    local floorDropped = Level.droppedFloors[n]

    -- bake one static tile and register its collision data
    local function place(sidx, tx, ty)
        local flags, action = Level.spriteStatus(sidx)
        if flags == 0x80 and action == 0 then
            -- a triggered killing floor removed this screen's bottom
            -- collision row (EB_ENEM.C:491)
            if floorDropped and ty == ROWS - 1 then
                return
            end
            -- collision geometry (never in_front: flags are exactly 0x80)
            Level.tileImage(sidx):draw(tx * TILE, ty * TILE)
            local bx, by, bw, bh, l, r, t, b = Level.spriteBox(sidx)
            cols[#cols + 1] = {
                x = tx * TILE + bx, y = ty * TILE + by,
                w = bw, h = bh, L = l, R = r, T = t, B = b,
            }
        elseif (flags & 0x80) == 0 then
            -- plain background
            if (flags & 0x04) ~= 0 then
                front[#front + 1] = {sidx, tx, ty}
            else
                Level.tileImage(sidx):draw(tx * TILE, ty * TILE)
            end
        end
    end

    if screen then
        gfx.pushContext(bg)
        for plane = 1, 4 do
            local layer = screen[plane]
            if layer then
                for i = 1, COLS * ROWS do
                    local sidx = layer[i]
                    if sidx ~= 0 then
                        place(sidx, (i - 1) % COLS, (i - 1) // COLS)
                    end
                end
            end
        end
        gfx.popContext()
    end
    Level.collisions = cols
    Level.bgImage = bg
    if #front > 0 then
        local img = gfx.image.new(MAX_X, MAX_Y)
        gfx.pushContext(img)
        for _, f in ipairs(front) do
            Level.tileImage(f[1]):draw(f[2] * TILE, f[3] * TILE)
        end
        gfx.popContext()
        Level.frontImage = img
    else
        Level.frontImage = nil
    end
end
