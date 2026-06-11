-- Active entities: animated and interactive level objects, ported from
-- python/emgame.py entity classes + emdata.py __init_* factories (themselves
-- re-ports of EB_ENEM.C). Entities are created once per level load, in the
-- same tile order and with the same per-screen RNG seeding as the reference,
-- so initial delays and frames match the original frame-for-frame. Their
-- state persists across screen changes; only the current screen's list is
-- updated each frame (em.py loop_run).

local gfx <const> = playdate.graphics
local floor <const> = math.floor

Actives = {}

-- sets outside the level's two sprite tables: explosion frames are weapons
-- sprites 0-7 (emother.py Weapons), the checkpoint cross is info sprite 5,
-- enemies animate from the shared enem set (emother.py Enemies)
local weaponsTable = gfx.imagetable.new("images/weapons")
local infoTable = gfx.imagetable.new("images/info")
local enemTable = gfx.imagetable.new("images/enem")
local weaponsStatus = json.decodeFile("sprites/weapons.ebs")["status table"]
local enemStatus = json.decodeFile("sprites/enem.ebs")["status table"]

-- Status bytes / native bbox for a sprite in an external set's raw status
-- array (same 8-byte layout Level.spriteStatus/spriteBox parse, but indices
-- are 0..63 within the set).
local function extStatus(st, i)
    local base = i * 8
    return st[base + 1], st[base + 2] & 0x1F, st[base + 3], st[base + 4]
end

local function extBox(st, i)
    local base = i * 8
    local l, r, t, b = st[base + 5], st[base + 6], st[base + 7], st[base + 8]
    local x, y = l & 0x7F, t & 0x7F
    return x, y, (r & 0x7F) - x, (b & 0x7F) - y
end

-- enem-set animation spans per enemy number (emother.py Enemies); the
-- spawner's param encodes number and the shoots flag (emdata.py __init_enemy)
local ENEMY_ANIMS <const> = {
    [0] = {MLEFT = {0, 11}, MRIGHT = {12, 22}, SLEFT = {23, 23}, SRIGHT = {24, 24}},
    [1] = {MLEFT = {32, 35}, MRIGHT = {36, 39}, SLEFT = {40, 40}, SRIGHT = {41, 41}},
    [2] = {MLEFT = {42, 42}, MRIGHT = {43, 43}, SLEFT = {44, 44}, SRIGHT = {44, 44}},
    [3] = {MLEFT = {48, 51}, MRIGHT = {52, 55}, SLEFT = {56, 56}, SRIGHT = {57, 57}},
}

-- hero projectile animation spans in the weapons set (emother.py Weapons);
-- level 1 shares one span for both directions
local WEAPON_ANIMS <const> = {
    {L = {8, 15}, R = {8, 15}},
    {L = {20, 23}, R = {16, 19}},
    {L = {28, 30}, R = {24, 26}},
    {L = {34, 35}, R = {32, 33}},
    {L = {38, 39}, R = {36, 37}},
}

-- ---------------------------------------------------------------------------
-- Borland C 3.1 rand(), reimplemented exactly (emglobals.py srand/rand/
-- random). Do not modernize: per-screen random seeding must match the
-- original game. Seed is kept masked to 32 bits; bits 16..30 (the ones
-- rand() returns) are unaffected by the truncation.

local randSeed = 1
local screenRandoms = {}   -- [0..COLS-1], used by delay init modes 5/6

local function srand(seed)
    randSeed = seed
end

local function rand()
    randSeed = (0x015a4e35 * randSeed + 1) & 0xFFFFFFFF
    return (randSeed >> 16) & 0x7FFF
end

local function random(num)
    return floor(rand() * num / 0x8000)
end
Actives.random = random   -- the runtime rand stream (gl.random)

-- emglobals.py init_screen_randoms
function Actives.initScreenRandoms(n)
    srand(256 * n + n)
    random(256)   -- additional call for compatibility reasons
    for i = 0, COLS - 1 do
        screenRandoms[i] = random(256)
    end
    srand(256 * n + n)
end

local function paramOf(sidx)
    local _, _, param = Level.spriteStatus(sidx)
    return param
end

-- ---------------------------------------------------------------------------
-- entity base (emgame.py Entity)

local Entity = {}
Entity.__index = Entity

function Entity:sidx()
    return self.first + self.frame
end

-- Plus-type entities hide between cycles (show == false); the exit
-- indicator blinks with the global frame counter (ExitIndicator.display);
-- everything else is always visible (show == nil).
function Entity:visible()
    if self.blink then
        return (Game.counter & 0x04) ~= 0
    end
    return self.show ~= false
end

-- Touchability follows the CURRENT frame's flags. CyclePlus/PulsePlus are
-- untouchable while hidden (their hidden frame is -1, out of the span);
-- plain Flash stays touchable even when invisible — Python doesn't override
-- is_touchable there. Entities from external sets (explosions, enemies) and
-- cannon projectiles (EnemyProjectile.is_touchable) are never touchable.
function Entity:isTouchable()
    if self.tbl or self.neverTouch then
        return false
    end
    if self.hideTouchable and not self.show then
        return false
    end
    local flags = Level.spriteStatus(self.first + self.frame)
    return (flags & 0x40) ~= 0
end

-- Touch byte of the current frame; the Plus types report 0 while hidden
-- (Cycle/Pulse/FlashPlus get_touch overrides in emgame.py).
function Entity:getTouch()
    if self.tbl or self.neverTouch or (self.hideTouch and not self.show) then
        return 0
    end
    local _, _, _, touch = Level.spriteStatus(self.first + self.frame)
    return touch
end

-- Current-frame bbox of any entity, level-set or external. Out-of-span
-- frames (a hidden Plus type's -1) read the last sprite of the span, like
-- Python's negative list index in Projectile.check_all_collisions.
function Actives.entityBox(e)
    local f = e.frame
    if f < 0 or f >= e.count then
        f = e.count - 1
    end
    if e.ebs then
        return extBox(e.ebs, e.first + f)
    end
    local bx, by, bw, bh = Level.spriteBox(e.first + f)
    return bx, by, bw, bh
end

-- Current-frame status flags, same frame clamping as entityBox.
local function entityFlags(e)
    local f = e.frame
    if f < 0 or f >= e.count then
        f = e.count - 1
    end
    if e.ebs then
        return (extStatus(e.ebs, e.first + f))
    end
    return (Level.spriteStatus(e.first + f))
end

-- Axis-aligned overlap of a box with a collision entry.
local function overlaps(x, y, w, h, c)
    return x < c.x + c.w and x + w > c.x and y < c.y + c.h and y + h > c.y
end

-- Side-aware collision of a box moving toward (dx, dy) against the current
-- screen's collisions (emgame.py Entity.check_collision side rules).
local function blocked(x, y, w, h, dx, dy)
    for _, c in ipairs(Level.collisions) do
        if overlaps(x, y, w, h, c) then
            if dx > 0 and c.L then return true end
            if dx < 0 and c.R then return true end
            if dy > 0 and c.T then return true end
            if dy < 0 and c.B then return true end
        end
    end
    return false
end

-- Initial delay from the init mode (action byte bits 5-7) and a param —
-- emgame.py set_initial_delay. Positions are native pixels; the spawned
-- teleport top can sit at y = -TILE, hence the % COLS wrap (Python's
-- negative list index reads the same last element).
function Entity:setInitialDelay(mode, param)
    local tx, ty = self.x // TILE, self.y // TILE
    if mode == 0 then
        self.delay = (tx + ty) % (param + 1)
    elseif mode == 1 then
        self.delay = tx % (param + 1)
    elseif mode == 2 then
        self.delay = ty % (param + 1)
    elseif mode == 3 then
        self.delay = 0
    elseif mode == 4 then
        self.delay = random(param + 1)
    elseif mode == 5 then
        self.delay = screenRandoms[tx % COLS] % (param + 1)
    elseif mode == 6 then
        self.delay = screenRandoms[ty % COLS] % (param + 1)
    elseif mode == 7 then
        self.frame = random(self.count)
        self.delay = 0
    end
end

-- ---------------------------------------------------------------------------
-- per-kind update procs (emgame.py update methods)

local newEntity   -- defined in the factory section below
local updates = {}

updates.cycle = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
    else
        e.frame = (e.frame + 1) % e.count
        e.delay = paramOf(e.first + e.frame)
    end
end

updates.cycleplus = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
        return
    end
    -- shape_rot_plus_proc EB_ENEM.C:244-275
    e.show = true
    e.frame = e.frame + 1
    if e.frame == e.count then
        -- cycle ended: hide and reset for the next show
        e.frame = -1
        e.show = false
        e.delay = e.emptyDelay
    else
        e.delay = paramOf(e.first + e.frame)
    end
end

updates.pulse = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
    else
        e.frame = e.frame + e.direction
        if e.frame < 0 then
            e.frame = 0
            e.direction = -e.direction
        elseif e.frame == e.count then
            e.frame = e.frame - 1
            e.direction = -e.direction
        end
        e.delay = paramOf(e.first + e.frame)
    end
end

updates.pulseplus = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
        return
    end
    -- shape_pulse_plus_proc EB_ENEM.C:294-330
    e.show = true
    e.frame = e.frame + e.direction
    if e.frame < 0 then
        -- end of cycle: hide and reset for the next show
        e.frame = -1
        e.show = false
        e.direction = 1
        e.delay = e.emptyDelay
    else
        if e.frame == e.count then
            -- bounce at the top (SHAPE_CNTR = SHAPES_NUM - 2)
            e.frame = e.frame - 2
            e.direction = -1
        end
        e.delay = paramOf(e.first + e.frame)
    end
end

updates.flash = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
    else
        e.show = not e.show
        e.delay = paramOf(e.first + e.frame)
    end
end

updates.flashplus = function(e)
    -- On-phase duration is this sprite's param, off-phase the preceding
    -- sprite's param (flash_plus_proc EB_ENEM.C:345-384).
    if e.delay > 0 then
        e.delay = e.delay - 1
    else
        e.show = not e.show
        if e.show then
            e.delay = paramOf(e.first + e.frame)
        else
            e.delay = e.emptyDelay
        end
    end
end

updates.flashspecial = function(e)
    if e.delay > 0 then
        e.delay = e.delay - 1
    else
        e.show = not e.show
        e.delay = 2
    end
end

updates.explosion = function(e)
    -- one animation frame per tick, then remove itself
    -- (explosion_proc EB_ENEM.C:51-56)
    e.frame = e.frame + 1
    if e.frame >= e.count then
        Actives.vanish(e)
    end
end

updates.exit = function(e)
    -- spawn the touchable blinking indicator one tile above once 3 disks
    -- are collected (emgame.py Exit.update; indicator sprite = exit + 1)
    if Game.disks >= 3 and not e.indicatorSpawned then
        e.indicatorSpawned = true
        local ind = newEntity("exitindicator", e.first + 1, 1, e.x, e.y - TILE)
        ind.blink = true
        Level.active[#Level.active + 1] = ind
    end
end

updates.monitor = function(e)
    -- monitor_proc EB_ENEM.C:214-241: flicker between the first two frames;
    -- rarely (1/128) hold a longer "special" animation frame.
    if e.counter == 0 then
        e.frame = random(math.min(2, e.count))
        if e.count > 2 and random(128) == 0 then
            e.frame = random(e.count - 2) + 2
            local param = paramOf(e.first + e.frame)
            if param > 0 then
                e.counter = param + random(param)
            end
        end
    else
        e.counter = e.counter - 1
        if e.counter == 0 then
            e.frame = 0
        end
    end
end

updates.rocketup = function(e)
    -- rocket_proc EB_ENEM.C:400-484 (Y_STEP = st[PARAMB], EB_ENEM.C:436)
    if not e.flying then
        -- fire when the player's center is aligned below (1/8 chance/frame)
        local bx, by, bw, bh = Actives.entityBox(e)
        local pcx = Hero.x + 12
        if e.x + bx - 4 < pcx and pcx < e.x + bx + bw + 4
                and Hero.y > e.y + by + bh then
            if random(8) == 0 then
                e.flying = true
            end
        end
        return
    end
    e.y = e.y - e.speed
    local bx, by, bw, bh = Actives.entityBox(e)
    if blocked(e.x + bx, e.y - e.speed + by, bw, bh, 0, -1) then
        Actives.putExplosion(e.x, e.y)
        Actives.vanish(e)
    elseif e.y < -TILE then
        Actives.vanish(e)
    end
end

updates.rocketdown = function(e)
    if not e.flying then
        -- fire when the player's bottom is aligned above
        local bx, by, bw, bh = Actives.entityBox(e)
        local pcx = Hero.x + 12
        if e.x + bx - 4 < pcx and pcx < e.x + bx + bw + 4
                and Hero.y + 48 < e.y + by then
            if random(8) == 0 then
                e.flying = true
            end
        end
        return
    end
    e.y = e.y + e.speed
    local bx, by, bw, bh = Actives.entityBox(e)
    if blocked(e.x + bx, e.y + e.speed + by, bw, bh, 0, 1) then
        Actives.putExplosion(e.x, e.y)
        Actives.vanish(e)
    elseif e.y > MAX_Y then
        Actives.vanish(e)
    end
end

updates.killingfloor = function(e)
    -- one-shot trigger: drop the screen's bottom collision row and arm the
    -- fall-death check (EB_ENEM.C:486-492, emgame.py KillingFloor)
    Game.killingFloor = true
    Level.dropFloor(Level.screenNumber)
    Actives.vanish(e)
end

updates.cannon = function(e)
    -- cannon_proc EB_ENEM.C:645-679: the firing interval is the cannon
    -- sprite's param in frames (AUX_2, EB_ENEM.C:691); the projectile speed
    -- is the PROJECTILE sprite's param in native px/frame (EB_ENEM.C:661-671)
    if not e.armed then
        local _, _, param = Level.spriteStatus(e.first)
        if param <= 0 then
            param = 8
        end
        e.interval = param
        local _, _, projParam = Level.spriteStatus(e.projSidx)
        e.speed = projParam > 0 and projParam or 4
        e.fireTimer = random(param)
        e.armed = true
        return
    end
    if e.fireTimer > 0 then
        e.fireTimer = e.fireTimer - 1
        return
    end
    -- fire: the projectile spawns just outside the cannon's bbox edge in
    -- the firing direction (EB_ENEM.C:688, 703, 718, 733)
    local cbx, cby, cbw, cbh = Actives.entityBox(e)
    local pbx, pby, pbw, pbh = Level.spriteBox(e.projSidx)
    local px, py = e.x, e.y
    if e.dx < 0 then
        px = e.x + cbx - (pbx + pbw) - 1
    elseif e.dx > 0 then
        px = e.x + cbx + cbw - pbx + 1
    elseif e.dy < 0 then
        py = e.y + cby - (pby + pbh) - 1
    elseif e.dy > 0 then
        py = e.y + cby + cbh - pby + 1
    end
    Actives.spawnEnemyShot(e.projSidx, nil, px, py,
                           e.dx * e.speed, e.dy * e.speed)
    e.fireTimer = e.interval + random(e.interval)
end

updates.enemyshot = function(e)
    -- cannon_miss EB_ENEM.C:581-642
    e.x = e.x + e.vx
    e.y = e.y + e.vy
    e.frame = (e.frame + 1) % e.count
    if e.x < -TILE or e.x > MAX_X or e.y < -TILE or e.y > MAX_Y then
        Actives.vanish(e)
        return
    end
    -- only SOLID walls (2+ colliding sides) stop shots — decorated
    -- platforms don't (cave_test; EnemyProjectile.check_solid_wall_collision)
    local bx, by, bw, bh = Actives.entityBox(e)
    for _, c in ipairs(Level.collisions) do
        if overlaps(e.x + bx, e.y + by, bw, bh, c) then
            local sides = (c.L and 1 or 0) + (c.R and 1 or 0)
                        + (c.T and 1 or 0) + (c.B and 1 or 0)
            if sides >= 2 then
                if (e.vx > 0 and c.L) or (e.vx < 0 and c.R)
                        or (e.vy > 0 and c.T) or (e.vy < 0 and c.B) then
                    Actives.vanish(e)
                    return
                end
            end
        end
    end
end

-- switch an enemy's animation span within the enem set
local function setEnemyAnim(e, name)
    local span = e.anims[name]
    e.anim = name
    e.first = span[1]
    e.count = span[2] - span[1] + 1
end

-- Scan for patrol boundaries from the spawn tile outward, one tile at a
-- time: stop at a wall in the scan direction, and (for platform creatures)
-- where the ground below ends (EB_ENEM.C:867-944 / 1039-1068).
local function enemyInit(e)
    local bx, by, bw, bh = Actives.entityBox(e)
    local function wallAt(px, dir)
        for _, c in ipairs(Level.collisions) do
            if overlaps(px + bx, e.y + by, bw, bh, c) then
                if dir > 0 and c.L then return true end
                if dir < 0 and c.R then return true end
            end
        end
        return false
    end
    local function groundAt(px)
        local checkY = e.y + TILE
        for _, c in ipairs(Level.collisions) do
            if c.T and c.y >= checkY and c.y < checkY + TILE
                    and c.x <= px and px < c.x + c.w then
                return true
            end
        end
        return false
    end

    local x = e.x
    if e.flyer then
        for _ = 1, COLS do
            if x + TILE > MAX_X or wallAt(x + TILE, 1) then break end
            x = x + TILE
        end
    else
        for _ = 1, 12 do
            if wallAt(x + TILE, 1) or not groundAt(x + TILE) then break end
            x = x + TILE
        end
    end
    e.rightBound = x
    x = e.x
    if e.flyer then
        for _ = 1, COLS do
            if x - TILE < 0 or wallAt(x - TILE, -1) then break end
            x = x - TILE
        end
    else
        for _ = 1, 12 do
            if wallAt(x - TILE, -1) or not groundAt(x - TILE) then break end
            x = x - TILE
        end
    end
    e.leftBound = x

    -- remove creatures whose patrol span is under one tile (EB_ENEM.C:933)
    if e.rightBound - e.leftBound < TILE then
        Actives.vanish(e)
        return
    end

    -- face the player (EB_ENEM.C:903-912)
    if Hero.x > e.x then
        e.xStep = math.abs(e.xStep)
        setEnemyAnim(e, "MRIGHT")
    else
        e.xStep = -math.abs(e.xStep)
        setEnemyAnim(e, "MLEFT")
    end
    if e.shoots then
        e.shootTimer = 32 + random(64)
    end
    -- initial step delay from the SPAWNER sprite's param low nibble
    -- (EB_ENEM.C:941)
    e.animDelay = random(256) % ((e.spawnParam & 0x0f) + 1)
    e.state = "patrol"
end

local function enemyPatrol(e)
    if e.animDelay > 0 then
        e.animDelay = e.animDelay - 1
        return
    end
    -- The shoot timer floors at 0 and HOLDS until the animation aligns
    -- (frame == 0) — see EnemyPlatform.update_patrol, EB_ENEM.C:821-831.
    if e.shoots then
        if e.shootTimer > 0 then
            e.shootTimer = e.shootTimer - 1
        end
        if e.shootTimer == 0 and e.frame == 0 then
            e.animDelay = 16
            e.shootTimer = 32 + random(64)
            e.state = "shoot"
            return
        end
    end
    e.x = e.x + e.xStep
    e.frame = (e.frame + 1) % e.count
    -- per-step delay from the current enem sprite's param low nibble
    -- (EB_ENEM.C:837 / 1001)
    local _, _, param = extStatus(enemStatus, e.first + e.frame)
    e.animDelay = param & 0x0f
    -- reverse at the patrol boundaries; platform creatures reset the frame
    -- on the flip, flying ones carry it over (EB_ENEM.C:846 vs 1003-1020)
    if e.xStep < 0 and e.x <= e.leftBound then
        e.xStep = -e.xStep
        setEnemyAnim(e, "MRIGHT")
        e.frame = e.flyer and (e.frame % e.count) or 0
    elseif e.xStep > 0 and e.x >= e.rightBound then
        e.xStep = -e.xStep
        setEnemyAnim(e, "MLEFT")
        e.frame = e.flyer and (e.frame % e.count) or 0
    end
end

local function enemyShoot(e)
    if e.animDelay > 0 then
        e.animDelay = e.animDelay - 1
        return
    end
    -- The shot sprite is the creature's own SLEFT/SRIGHT animation; its
    -- param is the shot speed (EB_ENEM.C:783-797 / 958-966, native px).
    local span = e.anims[e.xStep < 0 and "SLEFT" or "SRIGHT"]
    local shotSidx = span[1]
    local _, _, speed = extStatus(enemStatus, shotSidx)
    local bx, by, bw, bh = Actives.entityBox(e)
    if e.flyer then
        -- flying creatures shoot straight down, just below the bbox
        Actives.spawnEnemyShot(shotSidx, enemStatus,
                               e.x, e.y + by + bh + 1, 0, speed)
    elseif e.xStep < 0 then
        -- one tile left of the bbox (NEW_X = XB - 24, EB_ENEM.C:784)
        Actives.spawnEnemyShot(shotSidx, enemStatus,
                               e.x + bx - TILE, e.y, -speed, 0)
    else
        -- just right of the bbox (NEW_X = XE + 1, EB_ENEM.C:795)
        Actives.spawnEnemyShot(shotSidx, enemStatus,
                               e.x + bx + bw + 1, e.y, speed, 0)
    end
    e.state = "patrol"
end

updates.enemy = function(e)
    if e.state == "init" then
        enemyInit(e)
    elseif e.state == "patrol" then
        enemyPatrol(e)
    else
        enemyShoot(e)
    end
end

-- ---------------------------------------------------------------------------
-- factory (emdata.py __get_active_entity + __init_* per action code)

newEntity = function(kind, first, count, x, y)
    return setmetatable({
        kind = kind, first = first, count = count,
        x = x, y = y, frame = 0, delay = 0,
        update = updates[kind],
    }, Entity)
end

-- Create the entity for an active tile. Returns the entity, plus the sprite
-- index/position of an extra object to instantiate when the tile spawns one
-- (an enterable teleport base spawns its animated top one tile up,
-- emdata.py __init_teleport). Unknown actions fall back to a static display
-- of the placed sprite, matching Python's __init_display default.
function Actives.create(sidx, x, y)
    local _, action, param, touch, init = Level.spriteStatus(sidx)
    local first, last = Level.animEnds(sidx)
    local count = last - first + 1
    local e, extraSidx, extraX, extraY
    if action == 1 then         -- Cycle
        e = newEntity("cycle", first, count, x, y)
        e.frame = sidx - first
        e:setInitialDelay(init, paramOf(sidx))
    elseif action == 2 then     -- Pulse
        e = newEntity("pulse", first, count, x, y)
        e.frame = sidx - first
        e.direction = 1
        e:setInitialDelay(init, paramOf(sidx))
    elseif action == 3 then     -- Monitor
        e = newEntity("monitor", first, count, x, y)
        e.frame = sidx - first
        e.counter = 0
    elseif action == 5 then     -- CyclePlus
        e = newEntity("cycleplus", first, count, x, y)
        e.frame = -1
        e.show = false
        e.hideTouchable = true
        e.hideTouch = true
        e.emptyDelay = first > 0 and paramOf(first - 1) or 0
        e:setInitialDelay(init, e.emptyDelay)
    elseif action == 6 then     -- PulsePlus
        e = newEntity("pulseplus", first, count, x, y)
        e.frame = -1
        e.show = false
        e.direction = 1
        e.hideTouchable = true
        e.hideTouch = true
        e.emptyDelay = first > 0 and paramOf(first - 1) or 0
        e:setInitialDelay(init, e.emptyDelay)
    elseif action == 7 then     -- FlashPlus (single sprite)
        e = newEntity("flashplus", sidx, 1, x, y)
        e.show = false
        e.hideTouch = true
        e.emptyDelay = sidx > 0 and paramOf(sidx - 1) or paramOf(sidx)
        e:setInitialDelay(init, e.emptyDelay)
    elseif action == 9 or action == 10 then   -- RocketUp / RocketDown
        e = newEntity(action == 9 and "rocketup" or "rocketdown", sidx, 1, x, y)
        -- speed = own param, native px/frame (rocket_proc EB_ENEM.C:400-484)
        e.speed = param > 0 and param or 4
        e.flying = false
    elseif action == 11 then    -- KillingFloor trigger
        e = newEntity("killingfloor", sidx, 1, x, y)
    elseif action == 12 then    -- Checkpoint
        e = newEntity("checkpoint", first, count, x, y)
        e.frame = sidx - first
    elseif action == 13 then    -- Teleport base (static)
        e = newEntity("teleport", sidx, 1, x, y)
        if param == 1 then
            -- enterable base: spawn the touchable animated top one tile up,
            -- sprite = one past the base's animation end
            extraSidx, extraX, extraY = last + 1, x, y - TILE
        end
    elseif action == 14 then    -- Flash
        e = newEntity("flash", sidx, 1, x, y)
        e.show = false
        e:setInitialDelay(init, paramOf(sidx))
    elseif action == 15 then    -- Exit (emdata.py __init_exit)
        e = newEntity("exit", sidx, 1, x, y)
    elseif action == 16 and ENEMY_ANIMS[(param & 0x7F) // 3] then
        -- Enemy spawner (emdata.py __init_enemy): param picks the enemy
        -- number (and bit 7 = shoots); number 2 is the flying creature.
        -- Patrol speed comes from the spawner's touch byte (EB_ENEM.C:1179).
        local num = (param & 0x7F) // 3
        e = newEntity("enemy", 0, 1, x, y)
        e.tbl = enemTable
        e.ebs = enemStatus
        e.anims = ENEMY_ANIMS[num]
        e.flyer = num == 2
        e.shoots = (param & 0x80) ~= 0
        e.spawnParam = param
        e.xStep = -touch
        e.deadly = true
        e.state = "init"
        setEnemyAnim(e, "MLEFT")
    elseif action >= 17 and action <= 20 then   -- Cannon L/R/U/D
        e = newEntity("cannon", first, count, x, y)
        e.frame = sidx - first
        -- the projectile is the LAST sprite of the cannon's animation
        -- (EB_ENEM.C:656-657, emdata.py __init_cannon*)
        e.projSidx = last
        local dirs = {[17] = {-1, 0}, [18] = {1, 0},
                      [19] = {0, -1}, [20] = {0, 1}}
        e.dx, e.dy = dirs[action][1], dirs[action][2]
        e.armed = false
    elseif action == 21 then    -- FlashSpecial
        e = newEntity("flashspecial", sidx, 1, x, y)
        e.show = false
        e:setInitialDelay(init, paramOf(sidx))
    else                        -- Display (4) and unported actions
        e = newEntity("static", sidx, 1, x, y)
    end
    return e, extraSidx, extraX, extraY
end

-- Remove an entity from the current screen permanently (Entity.vanish —
-- our per-screen lists are both "current screen" and "level data").
function Actives.vanish(e)
    local list = Level.active
    for i, v in ipairs(list) do
        if v == e then
            table.remove(list, i)
            return
        end
    end
end

-- Spawn an explosion on the current screen (put_explosion EB_ENEM.C:59-67)
function Actives.putExplosion(x, y)
    Level.active[#Level.active + 1] = setmetatable({
        kind = "explosion", tbl = weaponsTable,
        first = 0, count = 8, frame = 0, x = x, y = y,
        update = updates.explosion,
    }, Entity)
end

-- ---------------------------------------------------------------------------
-- projectile spawning (ScreenManager.add_active): new objects queue up and
-- join the screen after the update pass — displayed this frame, updated
-- from the next one, like the reference.

Actives.pending = {}

function Actives.flushPending()
    local p = Actives.pending
    if #p > 0 then
        for i = 1, #p do
            Level.active[#Level.active + 1] = p[i]
        end
        Actives.pending = {}
    end
end

-- Enemy/cannon projectile: ebs == nil means a level-set sprite (cannon
-- shots), otherwise the enem set (creature shots). Kills the player on
-- contact (check_enemy_collision) but is neither touchable nor an obstacle.
function Actives.spawnEnemyShot(sidx, ebs, x, y, vx, vy)
    Actives.pending[#Actives.pending + 1] = setmetatable({
        kind = "enemyshot", first = sidx, count = 1, frame = 0,
        tbl = ebs and enemTable or nil, ebs = ebs,
        x = x, y = y, vx = vx, vy = vy,
        deadly = true, neverTouch = true,
        update = updates.enemyshot,
    }, Entity)
end

-- ---------------------------------------------------------------------------
-- hero projectiles (emhero.py Projectile / EB_HERO.C miss procs)

-- destroy an enemy: explosion at its bbox center (xplode EB_ENEM.C:70-89)
local function killEnemy(e)
    local bx, by, bw, bh = Actives.entityBox(e)
    Actives.putExplosion(e.x + bx + bw // 2 - 6, e.y + by + bh // 2 - 6)
    Actives.vanish(e)
end

-- A shot object explodes at its bbox center; destroyable ones (flag 0x08)
-- leave the next sprite past their animation span behind, tile-aligned and
-- persistent (hit_object EB_HERO.C:528-534, explosion_with_broke_proc).
local function shootObject(e)
    local flags = entityFlags(e)
    local bx, by, bw, bh = Actives.entityBox(e)
    local cx = e.x + bx + bw // 2 - 12
    local cy = e.y + by + bh // 2 - 12
    -- the broken sprite must exist in the level sets (Python catches the
    -- IndexError and degrades to explosion-only)
    if (flags & 0x08) ~= 0 and e.first + e.count <= 127 then
        local brokenSidx = e.first + e.count
        local gx = (e.x // TILE) * TILE
        local gy = (e.y // TILE) * TILE
        Actives.vanish(e)
        -- broken sprite goes in BEFORE the explosion so it draws beneath it
        Level.active[#Level.active + 1] = newEntity("static", brokenSidx, 1, gx, gy)
        Actives.putExplosion(cx, cy)
    else
        Actives.putExplosion(cx, cy)
        Actives.vanish(e)
    end
end

updates.heroshot = function(e)
    -- animate first; level 1 has limited range — it vanishes after one full
    -- animation cycle (short_miss_proc EB_HERO.C:245)
    local prev = e.frame
    e.frame = (e.frame + 1) % e.count
    if e.frame < prev and e.level == 1 then
        Actives.vanish(e)
        return
    end
    e.x = e.x + e.step
    -- off-screen: plain removal, no explosion (EB_HERO.C:224, 252, 282)
    if e.x > MAX_X or e.x < -TILE then
        Actives.vanish(e)
        return
    end
    local bx, by, bw, bh = extBox(weaponsStatus, e.first + e.frame)
    if e.level == 5 then
        -- bow covers both stacked sprites (EB_HERO.C:285-286, 2x there)
        bh = 42
    end
    -- solid wall facing the shot stops it (cave_test EB_HERO.C:234-242)
    for _, c in ipairs(Level.collisions) do
        if overlaps(e.x + bx, e.y + by, bw, bh, c) then
            if (e.step > 0 and c.L) or (e.step < 0 and c.R) then
                if e.level == 5 then
                    -- bow_end_proc triple explosion (EB_HERO.C:214-216)
                    local d = e.step > 0 and 1 or -1
                    Actives.putExplosion(e.x - d, e.y)
                    Actives.putExplosion(e.x + d * 8, e.y + 12)
                    Actives.putExplosion(e.x + d, e.y + 24)
                else
                    Actives.putExplosion(e.x, e.y)
                end
                Actives.vanish(e)
                return
            end
        end
    end
    -- enemy and shootable-object hits (miss_enem_test EB_HERO.C:167-193):
    -- all enemies in one frame can be hit; level 4 penetrates and flies on
    local snapshot = {}
    for i, t in ipairs(Level.active) do
        snapshot[i] = t
    end
    local hitEnemy = false
    for _, t in ipairs(snapshot) do
        if t ~= e then
            local tbx, tby, tbw, tbh = Actives.entityBox(t)
            local hit = e.x + bx < t.x + tbx + tbw
                    and e.x + bx + bw > t.x + tbx
                    and e.y + by < t.y + tby + tbh
                    and e.y + by + bh > t.y + tby
            if hit and t.kind == "enemy" then
                killEnemy(t)
                Actives.putExplosion(e.x, e.y)
                hitEnemy = true
            elseif hit and not t.ebs and (entityFlags(t) & 0x20) ~= 0 then
                -- level-set entity whose CURRENT frame is shootable
                -- (external-set entities carry no shootable flags); like
                -- Python, visibility is NOT checked — only the flags
                shootObject(t)
                Actives.vanish(e)
                return
            end
        end
    end
    if hitEnemy and e.level ~= 4 then
        Actives.vanish(e)
    end
end

-- Spawn a hero shot (fire_weapon EB_HERO.C:337-479). `right` picks the
-- direction-specific weapons animation; level 5 draws two stacked sprites.
function Actives.fireHeroShot(level, right, x, y, step)
    local span = WEAPON_ANIMS[level][right and "R" or "L"]
    Actives.pending[#Actives.pending + 1] = setmetatable({
        kind = "heroshot", tbl = weaponsTable, ebs = weaponsStatus,
        first = span[1], count = span[2] - span[1] + 1, frame = 0,
        x = x, y = y, step = step, level = level, tall = level == 5,
        update = updates.heroshot,
    }, Entity)
end

-- Visual checkpoint activation: jump to the last frame and overlay the
-- small cross from the info set (emgame.py Checkpoint.activate/display)
function Actives.activateCheckpoint(e)
    e.activated = true
    if e.count > 1 then
        e.frame = e.count - 1
    end
end

-- ---------------------------------------------------------------------------
-- per-frame driving (em.py loop_run / display_screen)

function Actives.update(list)
    for _, e in ipairs(list) do
        if e.update then
            e.update(e)
        end
    end
end

-- Draw the entities whose current frame's in_front flag (0x04) matches
-- `front` — in_front actives are deferred until after the hero, like
-- Python's display_deferred. External-set entities (explosions) have no
-- level flags and draw in the behind-hero pass.
function Actives.draw(list, front)
    for _, e in ipairs(list) do
        if e:visible() then
            if e.tbl then
                if not front then
                    e.tbl:getImage(e.first + e.frame + 1)
                        :draw(OFFX + e.x, OFFY + e.y)
                    if e.tall then
                        -- level-5 bow is two stacked sprites (EB_HERO.C bow)
                        e.tbl:getImage(e.first + (e.frame + 1) % e.count + 1)
                            :draw(OFFX + e.x, OFFY + e.y + TILE)
                    end
                end
            else
                local sidx = e.first + e.frame
                local flags = Level.spriteStatus(sidx)
                if ((flags & 0x04) ~= 0) == front then
                    Level.tileImage(sidx):draw(OFFX + e.x, OFFY + e.y)
                    if e.activated then
                        -- activated checkpoint cross (info sprite 5)
                        infoTable:getImage(6):draw(OFFX + e.x, OFFY + e.y)
                    end
                end
            end
        end
    end
end
