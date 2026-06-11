-- Global game state and level sequencing (the gl.* singletons from
-- emglobals.py and the level-exit handling from em.py Gameplay.run).

Game = {
    -- emglobals.py level_names; a level exit loads the next one in order,
    -- finishing past the last entry completes the game
    levelNames = {"elek", "koryt", "mieszk", "magaz",
                  "fiolet", "10x10", "sluzy", "widok", "test"},
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
}

-- em.py load_level: load by index, reset per-level state (EB.C:1461-1464),
-- set the start checkpoint and spawn the hero there.
function Game.loadLevel(index)
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
