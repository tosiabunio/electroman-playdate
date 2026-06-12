"""Headless smoke test for the Playdate Lua port.

Runs the game logic (game/level/actives/hero.lua) under a plain Lua runtime
(via lupa) with the Playdate API stubbed out, then fuzz-plays every screen
that has active entities on every level: random input, forced weapon power,
update + draw each frame. Catches runtime errors (nil indexing, bad sprite
indices, state machine breakage) that pdc's compile pass cannot.

Usage:  python tools/headless_smoke.py   (from the project root)
Needs:  pip install lupa
"""

import json
import os
import sys

from lupa import LuaRuntime

SRC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "source")


def to_lua(o):
    """Render a JSON-decoded value as a Lua literal."""
    if o is None:
        return "nil"
    if isinstance(o, bool):
        return "true" if o else "false"
    if isinstance(o, (int, float)):
        return repr(o)
    if isinstance(o, str):
        return json.dumps(o)
    if isinstance(o, list):
        return "{" + ",".join(to_lua(v) for v in o) + "}"
    if isinstance(o, dict):
        return "{" + ",".join(
            "[%s]=%s" % (json.dumps(k), to_lua(v)) for k, v in o.items()) + "}"
    raise TypeError(type(o))


lua = LuaRuntime()


def decode_file(path):
    full = os.path.join(SRC, path.replace("/", os.sep))
    if not os.path.exists(full):
        return None
    with open(full, "rt") as f:
        return lua.execute("return " + to_lua(json.load(f)))


lua.globals().py_decode = decode_file
lua.globals().SRC = SRC.replace("\\", "/")

lua.execute(r"""
-- Playdate API stubs: images draw into the void
local img = {}
img.__index = img
function img.draw() end
function img.drawFaded() end

playdate = {graphics = {}}
local gfx = playdate.graphics
gfx.kColorBlack = 0
gfx.kColorWhite = 1
gfx.kColorXOR = 2
gfx.kDrawModeCopy = 0
gfx.kDrawModeFillWhite = 1
gfx.image = {new = function() return setmetatable({}, img) end,
             kDitherTypeBayer4x4 = 0}
gfx.imagetable = {new = function(path)
    return {getImage = function(self, i)
        assert(i >= 1, "imagetable index < 1: " .. tostring(i))
        return setmetatable({}, img)
    end}
end}
gfx.pushContext = function() end
gfx.popContext = function() end
gfx.setColor = function() end
gfx.setImageDrawMode = function() end
gfx.fillRect = function() end
gfx.drawRect = function() end
gfx.font = {new = function() return {drawText = function() end} end}

playdate.kButtonUp, playdate.kButtonDown = 1, 2
playdate.kButtonLeft, playdate.kButtonRight = 3, 4
playdate.kButtonA, playdate.kButtonB = 5, 6
playdate.buttonJustPressed = function() return false end
playdate.getSystemMenu = function()
    return {addMenuItem = function() end}
end
-- in-memory datastore (save/load round-trips within one run)
local datastore_files = {}
playdate.datastore = {
    write = function(t, name) datastore_files[name or "data"] = t end,
    read = function(name) return datastore_files[name or "data"] end,
}
playdate.sound = {sampleplayer = {new = function()
    return {
        play = function() end,
        stop = function() end,
        isPlaying = function() return false end,
        setVolume = function() end,
    }
end},
fileplayer = {new = function()
    return {
        play = function() end,
        stop = function() end,
        isPlaying = function() return false end,
        getOffset = function() return 0 end,
        setVolume = function() end,
    }
end}}

json = {decodeFile = function(p) return py_decode(p) end}

dofile(SRC .. "/sound.lua")
dofile(SRC .. "/game.lua")
dofile(SRC .. "/level.lua")
dofile(SRC .. "/actives.lua")
dofile(SRC .. "/hero.lua")
dofile(SRC .. "/hud.lua")
dofile(SRC .. "/letters.lua")
dofile(SRC .. "/menu.lua")
dofile(SRC .. "/music.lua")
dofile(SRC .. "/presentation.lua")
dofile(SRC .. "/debugmenu.lua")

Hero.imageTable = gfx.imagetable.new("images/hero")
Debug.init()
Debug.showCollisions = true
""")

run = lua.eval(r"""
function(levelIndex)
    math.randomseed(12345 + levelIndex)
    Game.loadLevel(levelIndex)
    local name = Level.name
    local screens, frames = 0, 0
    for n = 0, 255 do
        if Game.state ~= "play" or Game.currentLevel ~= levelIndex then
            break   -- fuzz input hit a level exit; this level is done
        end
        local list = Level.actives[n + 1]
        if list and #list > 0 then
            screens = screens + 1
            Level.changeScreen(n)
            Hero:spawn(6, 3)
            -- walk the debug menu: every entry, adjust both ways (net
            -- zero), no activations
            Debug.show()
            for _ = 1, 9 do
                Debug.menuAction("right")
                Debug.menuAction("left")
                Debug.drawMenu()
                Debug.menuAction("down")
            end
            Debug.menuOpen = false
            for _ = 1, 120 do
                Hero.ctl.left = math.random(4) == 1
                Hero.ctl.right = math.random(4) == 1
                Hero.ctl.up = math.random(6) == 1
                Hero.ctl.down = math.random(10) == 1
                Hero.ctl.fire = math.random(2) == 1
                if Hero.power == 0 then
                    Hero.power = math.random(5)
                    Hero.ammo = 99
                end
                Actives.update(Level.active)
                Hero:update()
                Game.checkLevelExit()
                -- a level exit switched to the level-completed (or
                -- congratulations) presentation: gameplay updates stop,
                -- like the real loop's Game.state dispatch
                if Game.state ~= "play"
                        or Game.currentLevel ~= levelIndex then
                    break
                end
                Actives.flushPending()
                Actives.draw(Level.active, false)
                Hero:display()
                Actives.draw(Level.active, true)
                Hud.draw()
                Debug.drawCollisions()
                Game.counter = Game.counter + 1
                frames = frames + 1
            end
        end
    end
    return name, screens, frames
end
""")

menu_test = lua.eval(r"""
function()
    -- fresh boot: no save, the menu must land on NEW GAME
    Game.state = "menu"
    Menu.open()
    Menu.draw()
    Menu.action("up"); Menu.action("down"); Menu.draw()
    assert(Menu.action("select") == "new_game",
           "no-save menu should select new game")
    -- play to the start checkpoint, collect a real disk, auto-save
    Game.loadLevel(0)
    local diskScreen, disk
    for n = 0, 255 do
        for _, e in ipairs(Level.actives[n + 1] or {}) do
            if e:getTouch() == 5 then   -- TOUCH_FLOPPY
                diskScreen, disk = n, e
                break
            end
        end
        if disk then break end
    end
    assert(disk, "no floppy found on level 0")
    Game.disks = 1
    Game.diskPositions = {{screen = diskScreen, x = disk.x, y = disk.y}}
    Game.save()
    assert(Game.loadSave(), "save did not round-trip")
    -- with a save, the menu offers CONTINUE and it restores the game:
    -- spawn at the checkpoint, disks restored and stripped from the map,
    -- weapon power NOT restored (vestigial-by-design, EB.C:1389)
    Menu.open()
    Menu.draw()
    assert(Menu.action("select") == "continue",
           "with a save the menu should offer continue")
    assert(Game.continueGame(), "continueGame failed")
    assert(Game.state == "play", "continue should enter gameplay")
    assert(Game.disks == 1, "continue should restore collected disks")
    assert(Hero.power == 0, "continue must not restore weapon power")
    for _, e in ipairs(Level.actives[diskScreen + 1]) do
        assert(not (e:getTouch() == 5 and e.x == disk.x and e.y == disk.y),
               "restored disk should be stripped from the map")
    end
    -- presentation screens: title (with the song-pos image flip),
    -- level-completed (printText message incl. digits), congratulations
    Presentation.title()
    assert(Game.state == "presentation", "title should enter presentation")
    assert(Music.songPos() == 0, "songPos should start at 0")
    Presentation.draw()
    Presentation.levelCompleted(3, 3)
    Presentation.draw()
    Presentation.congratulations()
    Presentation.draw()
    Music.stop()
    return true
end
""")


def main():
    names = lua.eval("#Game.levelNames")
    failures = 0
    try:
        menu_test()
        print("menu/save     OK")
    except Exception as exc:
        failures += 1
        print("menu/save FAILED: %s" % exc)
    for i in range(names):
        try:
            name, screens, frames = run(i)
            print("level %-8s OK  (%d screens, %d frames)"
                  % (name, screens, frames))
        except Exception as exc:
            failures += 1
            print("level index %d FAILED: %s" % (i, exc))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
