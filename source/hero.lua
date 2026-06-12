-- Player entity: FSM + movement physics ported from python/emhero.py
-- (itself a re-port of EB_HERO.C). All values are native units — the Python
-- port's numbers are 2x scaled for its desktop window, so everything here
-- is halved (SCALE = 1).

local gfx <const> = playdate.graphics

-- horizontal move vector (Python MOVE_STEP = 8, 2x)
local MOVE_STEP <const> = 4
-- jump/fall vectors LUT based on the PC version (emhero.py, 2x there)
local JUMP_STEPS <const> = {10, 9, 8, 6, 5, 4, 3, 2, 1, 0}
local FALL_STEPS <const> = {1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12,
                            13, 14, 16, 17, 18, 19, 20, 21, 22, 24}
-- frozen frames after teleport-in before regaining control (EB_HERO.C:134)
local TELEPORT_TIME <const> = 12
-- touch types (item_contact() dispatch EB_HERO.C:586-599)
local TOUCH_BATTERY <const> = 1
local TOUCH_TELEPORT <const> = 2
local TOUCH_CHECKPOINT <const> = 3
local TOUCH_BOMB <const> = 4
local TOUCH_FLOPPY <const> = 5
local TOUCH_EXIT <const> = 6
local TOUCH_SPECIAL <const> = 7
-- shots per weapon power level, 0-indexed (emhero.py magazine)
local MAGAZINE <const> = {[0] = 0, 20, 15, 25, 10, 15}
-- weapon temperature increase per power level, 0-indexed (emhero.py heat)
local HEAT <const> = {[0] = 0, 1, 2, 1, 4, 3}
-- projectile spawn offset (mirrored when facing left) and speed per power
-- level (emhero.py PlayerEntity.projectiles, 2x there)
local SHOTS <const> = {
    {ox = 19, oy = 16, step = 14},
    {ox = 23, oy = 16, step = 16},
    {ox = 23, oy = 16, step = 14},
    {ox = 23, oy = 16, step = 12},
    {ox = 18, oy = 4,  step = 16},
}

-- animation table: {top, bottom} hero-set sprite pairs per frame (emhero.py).
-- Lua lists are 1-based; Hero.frame stays 0-based like the reference, so
-- frames index as anims[anim][frame + 1].
local ANIMS <const> = {
    LSTAND = {{0, 1}},
    RSTAND = {{2, 3}},
    LWALK = {{4, 5}, {4, 6}, {4, 7}, {4, 8}, {4, 9},
             {4, 10}, {4, 11}, {4, 12}, {4, 13}, {4, 14}},
    RWALK = {{15, 16}, {15, 17}, {15, 18}, {15, 19}, {15, 20},
             {15, 21}, {15, 22}, {15, 23}, {15, 24}, {15, 25}},
    -- turning left to right (played in reverse for right to left)
    TURN = {{26, 29}, {27, 30}, {28, 31}},
    LLAND = {{32, 33}},
    RLAND = {{34, 35}},
    LJUMP = {{4, 8}},
    RJUMP = {{15, 19}},
    -- entering teleport (played in reverse when leaving)
    TELE = {{36, 42}, {37, 43}, {38, 44}, {39, 45}, {40, 46}, {41, 47}},
}

Hero = {
    imageTable = nil,
    x = 0, y = 0,
    -- single very narrow bounding box for all anims
    -- (Python Rect(16, 12, 16, 84), 2x)
    bbox = {x = 8, y = 6, w = 8, h = 42},
    -- even narrower box for enemy contact (Python Rect(14, 20, 20, 70), 2x;
    -- EB_HERO.C:123)
    enemyBox = {x = 7, y = 10, w = 10, h = 35},
    anim = "RSTAND",
    frame = 0,
    orientation = 1,    -- 0 left, 1 right
    moveX = 0, moveY = 0,
    toGround = 0,
    jump = 0,           -- 0-based index into JUMP_STEPS/FALL_STEPS
    counter = 0,
    turnStep = 0,
    waitCounter = -1,
    deathTimer = 0,
    power = 0,          -- weapon battery power (0..5)
    ammo = 0,           -- shots left in the magazine
    temp = 0,           -- weapon temperature (cooldown HUD)
    cooldown = 0,       -- frames until the next temperature drop
    fired = false,      -- edge trigger: one shot per button press
    debugFly = false,   -- FSM suspended, d-pad nudges (Controller.debug)
    state = nil,
    nextState = nil,
    ctl = {left = false, right = false, up = false, down = false,
           fire = false},
    touched = {},          -- set of touchables hit during this frame's moves
    teleportTarget = nil,  -- {screen, x, y} teleport destination
}

-- ---------------------------------------------------------------------------
-- FSM (emgame.py FSM)

function Hero:switchState(state)
    self.state = state
    state(self, true)
end

function Hero:newState(state)
    self.nextState = state
end

function Hero:runFSM()
    if self.nextState then
        local state = self.nextState
        self.nextState = nil
        self:switchState(state)
    else
        self.state(self, false)
    end
end

-- ---------------------------------------------------------------------------
-- collision queries against Level.collisions (emgame.py Entity)

local function rectsOverlap(ax, ay, aw, ah, bx, by, bw, bh)
    return ax < bx + bw and ax + aw > bx and ay < by + bh and ay + ah > by
end

-- Distance from the bottom of the bbox to the ground (the topmost collided
-- object with a colliding T side). emgame.py check_ground.
function Hero:checkGround()
    local result = ROWS * (TILE + 1)
    local b = self.bbox
    local x = self.x + b.x
    local y = self.y + b.y + b.h
    local best = nil
    for _, c in ipairs(Level.collisions) do
        if c.T and rectsOverlap(x, y, b.w, MAX_Y - y, c.x, c.y, c.w, c.h) then
            if not best or c.y < best then
                best = c.y
            end
        end
    end
    if best then
        result = best - y
    end
    return result
end

-- Collect touchable active entities overlapping the bbox at offset into the
-- touched set (a Lua table keyed by entity — Python dedupes with set()).
-- Touchability and bbox follow the entity's current animation frame.
-- emgame.py get_touching.
function Hero:getTouching(ox, oy)
    local b = self.bbox
    local x, y = self.x + ox + b.x, self.y + oy + b.y
    for _, e in ipairs(Level.active) do
        if e:isTouchable() then
            local bx, by, bw, bh = Level.spriteBox(e:sidx())
            if rectsOverlap(x, y, b.w, b.h, e.x + bx, e.y + by, bw, bh) then
                self.touched[e] = true
            end
        end
    end
end

-- Collision at offset, honoring per-side passability and move direction.
-- emgame.py check_collision.
function Hero:checkCollision(ox, oy, ignoreGround)
    local b = self.bbox
    local x, y = self.x + ox + b.x, self.y + oy + b.y
    for _, c in ipairs(Level.collisions) do
        if rectsOverlap(x, y, b.w, b.h, c.x, c.y, c.w, c.h) then
            if ox > 0 and c.L then
                return true
            elseif ox < 0 and c.R then
                return true
            elseif oy > 0 and c.T and not ignoreGround then
                return true
            elseif oy < 0 and c.B then
                return true
            end
        end
    end
    return false
end

-- Largest non-colliding move toward (ox, oy), multisampled 1px at a time
-- along the dominant axis. emgame.py check_move: its 2px steps and
-- even-clamped minor axis reduce to 1px steps and floor() in native units.
function Hero:checkMove(ox, oy, ignoreGround)
    if ox == 0 and oy == 0 then
        self:getTouching(0, 0)
        return 0, 0
    end
    local swapped = false
    if math.abs(ox) < math.abs(oy) then
        swapped = true
        ox, oy = oy, ox
    end
    local sy = oy / math.abs(ox)
    local fy = 0.005
    local nx = 0
    local lastX, lastY = 0, 0
    local stepX = ox > 0 and 1 or -1
    for _ = 1, math.abs(ox) do
        nx = nx + stepX
        fy = fy + sy
        local ny = math.floor(fy)
        local cx, cy
        if swapped then
            cx, cy = ny, nx
        else
            cx, cy = nx, ny
        end
        -- touches are collected at every sampled offset, including the
        -- colliding one (emgame.py check_move)
        self:getTouching(cx, cy)
        if self:checkCollision(cx, cy, ignoreGround) then
            break
        end
        lastX, lastY = cx, cy
    end
    return lastX, lastY
end

-- Apply the current move vector (emhero.py move). Returns the actual move.
function Hero:move()
    local mx, my = self:checkMove(self.moveX, self.moveY, true)
    self.x = self.x + mx
    self.y = self.y + my
    return mx, my
end

-- Screen-edge transitions (emhero.py check_bounds).
function Hero:checkBounds()
    local b = self.bbox
    local below = (self.y + b.y + b.h) - MAX_Y
    local cs = Level.screenNumber
    if below > 0 then
        cs = cs + (cs < 240 and 16 or -240)
        Level.changeScreen(cs)
        self.y = -(b.y + b.h - below)
    end
    local center = self.x + b.x + b.w // 2
    cs = Level.screenNumber
    if center < 0 then
        cs = cs - (cs > 0 and 1 or -255)
        Level.changeScreen(cs)
        self.x = MAX_X + self.x
    elseif center > MAX_X then
        cs = cs + (cs < 255 and 1 or -255)
        Level.changeScreen(cs)
        self.x = self.x - MAX_X
    end
end

-- ---------------------------------------------------------------------------
-- states (emhero.py PlayerEntity.state_*)

local stateStand, stateMove, stateTurn, stateBeforeJump
local stateJump, stateFall, stateLand
local stateTeleportOut, stateTeleportIn, stateDeath

stateStand = function(self, init)
    if init then
        self.moveX, self.moveY = 0, 0
        if self.toGround > 0 then
            self:switchState(stateFall)
        end
        self.anim = self.orientation == 0 and "LSTAND" or "RSTAND"
        self.frame = 0
    end
    if self.toGround > 0 then
        return self:switchState(stateFall)
    end
    if self.ctl.left or self.ctl.right then
        return self:switchState(stateMove)
    end
    if self.ctl.up then
        return self:switchState(stateBeforeJump)
    end
end

stateTeleportOut = function(self, init)
    -- teleport fade-out (emhero.py state_teleport_out)
    if init then
        self.anim = "TELE"
        self.counter = #ANIMS.TELE - 1
        self.frame = 0
    else
        if self.counter == 0 then
            if Game.exitLevelFlag then
                -- level exit: hold here, the main loop switches the level
                -- once the fade-out is done (EB_HERO.C:853)
                Game.levelExitReady = true
                return
            end
            return self:newState(stateTeleportIn)
        end
        self.frame = self.frame + 1
        self.counter = self.counter - 1
    end
end

stateDeath = function(self, init)
    -- hero_before_kill_proc -> hero_kill_proc -> hero_after_kill_proc
    -- (EB_HERO.C:908-945, emhero.py state_death): explosions around the
    -- hero for 10 frames, ~3 s pause, then respawn at the checkpoint
    if init then
        self.deathTimer = 0
        Actives.putExplosion(self.x - 1, self.y)
        Actives.putExplosion(self.x, self.y + 23)
    end
    self.deathTimer = self.deathTimer + 1
    if self.deathTimer < 10 then
        Actives.putExplosion(self.x - 12 + Actives.random(24),
                             self.y + Actives.random(24))
        Sound.play("blast")
    elseif self.deathTimer >= 70 then
        self:respawn()
    end
end

stateTeleportIn = function(self, init)
    -- Teleport fade-in. After the animation, holds TELEPORT_TIME frames
    -- before returning control (hero_teleport_wait_proc EB_HERO.C:841-871).
    -- The hero is pinned to the target position for the whole state.
    if self.teleportTarget then
        local t = self.teleportTarget
        if t.screen ~= Level.screenNumber then
            Level.changeScreen(t.screen)
        end
        self.x, self.y = t.x, t.y - TILE * 2
    end
    if init then
        -- NOTE: C plays no sound here; the 'area' sample is level entry only
        -- (hero_enter_level_proc EB_HERO.C:681)
        self.anim = "TELE"
        self.counter = #ANIMS.TELE - 1
        self.frame = #ANIMS.TELE - 1
        self.waitCounter = -1   -- not yet in wait phase
    else
        if self.waitCounter >= 0 then
            if self.waitCounter == 0 then
                return self:newState(stateStand)
            end
            self.waitCounter = self.waitCounter - 1
        elseif self.counter == 0 then
            -- animation finished, enter wait phase
            self.waitCounter = TELEPORT_TIME
        else
            self.frame = self.frame - 1
            self.counter = self.counter - 1
        end
    end
end

stateMove = function(self, init)
    if init then
        self.anim = self.orientation == 0 and "LWALK" or "RWALK"
        self.frame = 0
    end
    if self.toGround > 0 then
        return self:switchState(stateFall)
    end
    if self.ctl.up then
        return self:newState(stateBeforeJump)
    end
    if self.ctl.left then
        if self.orientation == 1 then
            return self:switchState(stateTurn)
        end
        self.moveX = -MOVE_STEP
    elseif self.ctl.right then
        if self.orientation == 0 then
            return self:switchState(stateTurn)
        end
        self.moveX = MOVE_STEP
    else
        return self:switchState(stateStand)
    end
    local movedX = self:move()
    if movedX ~= 0 then
        self.frame = (self.frame + 1) % #ANIMS[self.anim]
        -- footstep on frames 2 and 7 (EB_HERO.C:1010,1018)
        if self.frame == 2 or self.frame == 7 then
            Sound.play("footstep")
        end
    else
        -- cannot move farther, play stand animation
        self.anim = self.orientation == 0 and "LSTAND" or "RSTAND"
        self.frame = 0
        self.moveX = 0
    end
end

stateTurn = function(self, init)
    -- matches hero_turn_proc EB_HERO.C:895-906
    if init then
        self.orientation = 1 - self.orientation
        self.anim = "TURN"
        if self.orientation == 1 then
            self.frame = 0
            self.turnStep = 1
        else
            self.frame = 2
            self.turnStep = -1
        end
    else
        local nextFrame = self.frame + self.turnStep
        if nextFrame < 0 or nextFrame >= #ANIMS.TURN then
            return self:newState(stateMove)
        end
        self.frame = nextFrame
    end
end

stateBeforeJump = function(self, init)
    -- 2-frame crouch before the jump proper (hero_before_jump_proc
    -- EB_HERO.C:797-819)
    if init then
        self.counter = 0
        self.anim = self.orientation == 0 and "LLAND" or "RLAND"
        self.frame = 0
    end
    self.counter = self.counter + 1
    if self.counter == 2 then
        return self:newState(stateJump)
    end
end

stateJump = function(self, init)
    if init then
        Sound.play("jump")
        if self.ctl.left then
            self.moveX = -MOVE_STEP
            self.orientation = 0
        end
        if self.ctl.right then
            self.moveX = MOVE_STEP
            self.orientation = 1
        end
        self.jump = 0
        self.anim = self.orientation == 0 and "LJUMP" or "RJUMP"
        self.frame = 0
    end
    -- vertical movement first
    local up = -JUMP_STEPS[self.jump + 1]
    local _, py = self:checkMove(0, up, false)
    self.y = self.y + py
    if py > up or up == 0 then
        -- collided or reached max point, switch to fall next frame
        self:newState(stateFall)
    end
    -- then horizontal movement
    local px = self:checkMove(self.moveX, 0, false)
    self.x = self.x + px
    self.jump = self.jump + 1
end

stateFall = function(self, init)
    if init then
        self.anim = self.orientation == 0 and "LJUMP" or "RJUMP"
        self.frame = 0
        self.moveY = 0
        self.jump = 0
    end
    -- an armed killing floor kills below the (removed) bottom row
    -- (EB_ENEM.C:486-492, emhero.py state_fall)
    if Game.killingFloor
            and self.y + self.bbox.y + self.bbox.h > (ROWS - 1) * TILE then
        return self:newState(stateDeath)
    end
    if self.toGround == 0 then
        return self:switchState(stateLand)
    else
        self.moveY = FALL_STEPS[self.jump + 1]
        if self.toGround < self.moveY then
            self.moveY = self.toGround
        end
        local movedX = self:move()
        -- reset horizontal vector if wall hit while falling
        self.moveX = movedX
        self.jump = self.jump + 1
        if self.jump == #FALL_STEPS then
            -- limit max vertical speed and cancel horizontal then
            self.moveX = 0
            self.jump = self.jump - 1
        end
    end
end

stateLand = function(self, init)
    -- hero_after_fall_proc EB_HERO.C:782-795
    if init then
        self.counter = 2
    end
    self.anim = self.orientation == 0 and "LLAND" or "RLAND"
    self.frame = 0
    self.counter = self.counter - 1
    if self.counter == 0 then
        Sound.play("jumpend")
        return self:newState(stateStand)
    end
end

-- ---------------------------------------------------------------------------

-- Find the teleport destination: the first teleport base above (px, py) in
-- the same column, scanning screens upward (screen - 16) with wrap-around
-- and re-entering each from below. emhero.py find_teleport_target.
function Hero:findTeleportTarget(px, py)
    self.teleportTarget = nil
    local sn = Level.screenNumber
    while not self.teleportTarget do
        local tp = {}
        for _, t in ipairs(Level.teleportsOn(sn)) do
            if t.x == px then
                tp[t.y] = true
            end
        end
        for y = py, 1, -TILE do
            if tp[y] then
                self.teleportTarget = {screen = sn, x = px, y = y}
                break
            end
        end
        py = (ROWS + 1) * TILE
        sn = (sn - 16) % 256
    end
end

-- Contact with enemies and their projectiles kills — ENEM_TEST
-- (EB_HERO.C:601-626): expand the narrow contact box by half the enemy's
-- size and test the enemy's bbox center (POS_COMPARE). Rockets are not
-- deadly — Python's check_enemy_collision doesn't include them either.
function Hero:checkEnemyCollision()
    local b = self.enemyBox
    local pl, pt = self.x + b.x, self.y + b.y
    local pr, pb = pl + b.w, pt + b.h
    for _, e in ipairs(Level.active) do
        if e.deadly then
            local bx, by, bw, bh = Actives.entityBox(e)
            local cx = e.x + bx + bw // 2
            local cy = e.y + by + bh // 2
            local ex, ey = bw // 2, bh // 2
            if pl - ex < cx and cx < pr + ex
                    and pt - ey < cy and cy < pb + ey then
                self:newState(stateDeath)
                return
            end
        end
    end
end

-- DOWN pressed while grounded: the C teleport/exit/special triggers all
-- live in hero_move_proc (KEY_DW + teleport_flag, EB_HERO.C:986), so they
-- only fire from the stand/move states.
function Hero:groundedDown()
    return self.ctl.down
        and (self.state == stateStand or self.state == stateMove)
end

-- Process objects touched during this frame (emhero.py handle_touch,
-- item_contact() dispatch EB_HERO.C:586-599).
function Hero:handleTouch()
    for t in pairs(self.touched) do
        local touch = t:getTouch()
        if touch == TOUCH_BATTERY then
            -- take_battery() EB_HERO.C:491-498: always collected; refills
            -- the magazine even at max power
            self.power = math.min(self.power + 1, 5)
            self.ammo = MAGAZINE[self.power]
            Sound.play("battery")
            Actives.vanish(t)
        elseif touch == TOUCH_TELEPORT then
            if self:groundedDown() then
                Sound.play("teleport")
                self:findTeleportTarget(t.x, t.y)
                self:newState(stateTeleportOut)
            end
        elseif touch == TOUCH_CHECKPOINT then
            -- activate only if different from the current one (EB_HERO.C:514);
            -- activation resets the weapon (EB_HERO.C:519)
            local cp = Game.checkpoint
            if cp.screen ~= Level.screenNumber
                    or cp.x ~= t.x or cp.y ~= t.y then
                Game.checkpoint = {screen = Level.screenNumber,
                                   x = t.x, y = t.y}
                self.power, self.ammo, self.temp = 0, 0, 0
                Sound.play("checkp")
                Actives.activateCheckpoint(t)
                -- auto-save on activation (emhero.py handle_touch:556)
                Game.save()
            end
        elseif touch == TOUCH_BOMB then
            -- bomb() EB_HERO.C:523-535: explode the bomb sprite at its bbox
            -- center and kill the hero
            if self.state ~= stateDeath then
                Sound.play("blast")
                local bx, by, bw, bh = Level.spriteBox(t:sidx())
                Actives.putExplosion(t.x + bx + bw // 2 - 12,
                                     t.y + by + bh // 2 - 12)
                Actives.vanish(t)
                self:newState(stateDeath)
            end
        elseif touch == TOUCH_FLOPPY then
            -- collect a disk; remember its position so a level reset can
            -- re-remove it (EB.C:1391-1395)
            Game.disks = Game.disks + 1
            Game.diskPositions[#Game.diskPositions + 1] =
                {screen = Level.screenNumber, x = t.x, y = t.y}
            Sound.play("disk")
            Actives.vanish(t)
        elseif touch == TOUCH_EXIT then
            -- exit_level() EB_HERO.C:548-560: needs all 3 disks + DOWN in a
            -- grounded state
            if Game.disks >= 3 and self:groundedDown() then
                Sound.play("teleport")
                Game.nextLevelCode = Game.currentLevel + 1
                Game.exitLevelFlag = true
                self.teleportTarget = nil
                self:newState(stateTeleportOut)
            end
        elseif touch == TOUCH_SPECIAL then
            -- special_proc() EB_HERO.C:562-584: param >= 128 is an alternate
            -- level exit; otherwise each use halves param — reaching 0
            -- teleports to the secret area (cave 0xec), else it's a death trap
            if self:groundedDown() then
                local sidx = t:sidx()
                local _, _, param = Level.spriteStatus(sidx)
                if param >= 128 then
                    Sound.play("teleport")
                    Game.nextLevelCode = param
                    Game.exitLevelFlag = true
                    self.teleportTarget = nil
                    self:newState(stateTeleportOut)
                else
                    param = param // 2
                    Level.setSpriteParam(sidx, param)
                    if param == 0 then
                        Sound.play("teleport")
                        self.teleportTarget = {screen = 0xec,
                                               x = 7 * TILE, y = 1 * TILE}
                        self:newState(stateTeleportOut)
                    elseif self.state ~= stateDeath then
                        self:newState(stateDeath)
                    end
                end
            end
        end
    end
end

-- Respawn at the active checkpoint after death (init_level EB.C:1382-1405,
-- emhero.py respawn): restore the level, re-remove collected disks, reset
-- the weapon, and stand at the checkpoint.
function Hero:respawn()
    Level.resetLevel(Game.diskPositions)
    Game.killingFloor = false   -- the reset restored the floors
    self.power, self.ammo, self.temp = 0, 0, 0
    self.deathTimer = 0
    self.touched = {}
    local cp = Game.checkpoint
    Level.changeScreen(cp.screen)
    self:stand(cp.x + TILE // 2, cp.y + TILE)
    self.toGround = self:checkGround()
    self:switchState(stateStand)
    -- level-entry sample (hero_enter_level_proc EB_HERO.C:681)
    Sound.play("area")
end

-- Place the hero's feet (bbox bottom-center) at (px, py) — emhero.py stand().
function Hero:stand(px, py)
    local b = self.bbox
    self.x = px - (b.x + b.w // 2)
    self.y = py - (b.y + b.h)
end

-- Spawn at a checkpoint tile: feet at checkpoint pos + (TILE/2, TILE)
-- (emhero.py respawn, EB.C:1396).
function Hero:spawn(tileX, tileY)
    self:stand(tileX * TILE + TILE // 2, tileY * TILE + TILE)
    self.toGround = self:checkGround()
    self:switchState(stateStand)
end

-- Debug helpers (em.py key_handlers). The nudge replaces runFSM while fly
-- mode is on, one tile per press with the reference's vertical guards
-- (Shift+arrows); everything else in update() still runs, like Python's
-- Controller.debug.
function Hero:debugNudge()
    if self.ctl.left then
        self.x = self.x - TILE
    end
    if self.ctl.right then
        self.x = self.x + TILE
    end
    if self.ctl.up and self.y >= -2 * TILE then
        self.y = self.y - TILE
    end
    if self.ctl.down and self.y <= (ROWS + 2) * TILE then
        self.y = self.y + TILE
    end
end

function Hero:debugKill()
    if self.state ~= stateDeath then
        self:newState(stateDeath)
    end
end

-- emhero.py select_weapon (debug Shift+number)
function Hero:selectWeapon(power)
    self.power = power
    self.ammo = MAGAZINE[power]
end

-- Fire the weapon (fire_weapon EB_HERO.C:337-479): blocked when adding the
-- level's heat would overheat (max temperature 5, EB_HERO.C:324); the last
-- shot in the magazine drops to the previous power level.
function Hero:fireWeapon()
    if self.power == 0 then
        return
    end
    local heat = HEAT[self.power]
    if self.temp + heat > 5 then
        return
    end
    self.temp = self.temp + heat
    self.cooldown = 4
    self.ammo = self.ammo - 1
    Sound.play("shoot" .. self.power)
    local s = SHOTS[self.power]
    if self.orientation == 1 then
        Actives.fireHeroShot(self.power, true,
                             self.x + s.ox, self.y + s.oy, s.step)
    else
        Actives.fireHeroShot(self.power, false,
                             self.x - s.ox, self.y + s.oy, -s.step)
    end
    if self.ammo == 0 then
        -- select_weapon(power - 1)
        self.power = self.power - 1
        self.ammo = MAGAZINE[self.power]
    end
end

-- Weapon temperature decay, one unit per 4 frames down to the idle 1
-- (emhero.py power_and_cooldown).
function Hero:powerAndCooldown()
    if self.power == 0 then
        self.temp = 0
    elseif self.temp == 0 then
        self.temp = 1
    end
    if self.temp > 1 then
        if self.cooldown > 0 then
            self.cooldown = self.cooldown - 1
        else
            self.temp = self.temp - 1
            self.cooldown = 4
        end
    end
end

function Hero:update()
    -- order matches emhero.py update()
    self.touched = {}
    if self.state ~= stateDeath then
        self:getTouching(0, 0)  -- check_touch(): objects at current position
    end
    if self.state ~= stateDeath and self.state ~= stateTeleportIn
            and self.state ~= stateTeleportOut then
        self:checkEnemyCollision()
    end
    self.toGround = self:checkGround()
    if self.debugFly then
        self:debugNudge()
    else
        self:runFSM()
    end
    -- shooting: edge-triggered, only from the normal movement states
    if self.ctl.fire then
        if self.state == stateStand or self.state == stateMove
                or self.state == stateJump or self.state == stateFall
                or self.state == stateLand then
            if not self.fired then
                self:fireWeapon()
                self.fired = true
            end
        end
    else
        self.fired = false
    end
    self:checkBounds()
    self:handleTouch()
    self:powerAndCooldown()
end

function Hero:display()
    local pair = ANIMS[self.anim][self.frame + 1]
    self.imageTable:getImage(pair[1] + 1):draw(OFFX + self.x, OFFY + self.y)
    self.imageTable:getImage(pair[2] + 1):draw(OFFX + self.x, OFFY + self.y + TILE)
end
