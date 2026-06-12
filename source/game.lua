-- Global game state and level sequencing (the gl.* singletons from
-- emglobals.py and the level-exit handling from em.py Gameplay.run).

Game = {
    -- the original game's 8 levels; a level exit loads the next one in
    -- order, finishing the 8th completes the game (emglobals.py
    -- level_names minus the python port's debug "test" level)
    levelNames = {"elek", "koryt", "mieszk", "magaz",
                  "fiolet", "10x10", "sluzy", "widok"},
    currentLevel = 0,       -- 0-based like the reference
    disks = 0,
    diskPositions = {},     -- collected disks, re-removed on level reset
    checkpoint = nil,       -- active respawn point {screen, x, y}
    exitLevelFlag = false,
    nextLevelCode = 0,
    levelExitReady = false, -- fade-out finished, switch level now
    completed = false,
    counter = 0,            -- global frame counter (gl.counter), HUD blinking
    killingFloor = false,   -- armed killing-floor fall death (gl.killing_floor)
    state = "menu",         -- "menu" | "play" (em.py fast_main flow)
}

-- em.py load_level: load by index, reset per-level state (EB.C:1461-1464),
-- set the start checkpoint and spawn the hero there.
function Game.loadLevel(index)
    Game.state = "play"
    Game.currentLevel = index
    Level.load(Game.levelNames[index + 1])
    local screen, tileX, tileY = Level.findStart()
    Game.checkpoint = {screen = screen, x = tileX * TILE, y = tileY * TILE}
    Game.disks = 0
    Game.diskPositions = {}
    Game.killingFloor = false
    Hero.power, Hero.ammo, Hero.temp = 0, 0, 0
    Level.changeScreen(screen)
    Hero:spawn(tileX, tileY)
    -- level-entry sample (hero_enter_level_proc EB_HERO.C:681)
    Sound.play("area")
end

-- Save/load, ported from emmenu.py SaveGame (the original's checkpoint
-- save, EB.C:920-948) with the same fields and checksum as the Python
-- port's pyelectroman.sav, stored through playdate.datastore.

local function checksum(data)
    local sum = data.level + data.screen + data.position_x
        + data.position_y + data.disks + data.power
    for _, p in ipairs(data.disk_positions) do
        sum = sum + p[1] + p[2] + p[3]
    end
    return sum % 256
end

-- Auto-save at the just-activated checkpoint (emhero.py handle_touch
-- touch type 3).
function Game.save()
    local cp = Game.checkpoint
    local positions = {}
    for i, d in ipairs(Game.diskPositions) do
        positions[i] = {d.screen, d.x, d.y}
    end
    local data = {
        level = Game.currentLevel,
        screen = cp.screen,
        position_x = cp.x,
        position_y = cp.y,
        disks = Game.disks,
        disk_positions = positions,
        power = Hero.power,
    }
    data.checksum = checksum(data)
    playdate.datastore.write(data, "savegame")
end

-- Read the save back; nil when missing or corrupt.
function Game.loadSave()
    local data = playdate.datastore.read("savegame")
    if not data
            or type(data.level) ~= "number"
            or type(data.screen) ~= "number"
            or type(data.position_x) ~= "number"
            or type(data.position_y) ~= "number"
            or type(data.disks) ~= "number"
            or type(data.power) ~= "number"
            or type(data.disk_positions) ~= "table" then
        return nil
    end
    if data.checksum ~= checksum(data) then
        return nil
    end
    if data.level < 0 or data.level >= #Game.levelNames then
        return nil
    end
    return data
end

-- Continue from the save. Matches the Python flow (em.py fast_main:
-- load_saved_game + gameplay.start): the level loads fresh and the hero
-- spawns at the saved checkpoint. NOTE the reference does NOT restore
-- disks/weapon on continue — load_level resets them right after
-- apply_to_game set them (EB.C:1461/1389); the saved disks/power fields
-- are written for save-format parity only.
function Game.continueGame()
    local sav = Game.loadSave()
    if not sav then
        return false
    end
    Game.loadLevel(sav.level)
    Game.checkpoint = {screen = sav.screen,
                       x = sav.position_x, y = sav.position_y}
    Level.changeScreen(sav.screen)
    Hero:spawn(sav.position_x // TILE, sav.position_y // TILE)
    return true
end

-- Level-exit transition (em.py run, EB.C:263-276). Deviation from the
-- Python reference: Python consumes exit_level_flag the same frame it is
-- set, so its teleport fade-out plays at the NEW level's start; the C
-- original finishes the fade-out first (EB_HERO.C:853), which is what
-- stateTeleportOut's levelExitReady handshake reproduces.
function Game.checkLevelExit()
    if not Game.levelExitReady then
        return
    end
    Game.levelExitReady = false
    Game.exitLevelFlag = false
    if Game.nextLevelCode < #Game.levelNames then
        Game.loadLevel(Game.nextLevelCode)
    else
        Game.completed = true
    end
end
