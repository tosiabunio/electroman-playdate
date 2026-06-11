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

playdate = {graphics = {}}
local gfx = playdate.graphics
gfx.kColorBlack = 0
gfx.kColorWhite = 1
gfx.kColorXOR = 2
gfx.kDrawModeCopy = 0
gfx.kDrawModeFillWhite = 1
gfx.image = {new = function() return setmetatable({}, img) end}
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
playdate.sound = {sampleplayer = {new = function()
    return {
        play = function() end,
        stop = function() end,
        isPlaying = function() return false end,
    }
end}}

json = {decodeFile = function(p) return py_decode(p) end}

dofile(SRC .. "/sound.lua")
dofile(SRC .. "/game.lua")
dofile(SRC .. "/level.lua")
dofile(SRC .. "/actives.lua")
dofile(SRC .. "/hero.lua")
dofile(SRC .. "/hud.lua")
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
        if Game.currentLevel ~= levelIndex then
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
                if Game.currentLevel ~= levelIndex then
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

def main():
    names = lua.eval("#Game.levelNames")
    failures = 0
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
