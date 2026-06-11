-- Electro Man - Playdate port
-- Hero movement with collision, screen transitions, teleports and animated
-- active entities, ported from python/em.py + emhero.py + emgame.py.

import "CoreLibs/graphics"
import "game"
import "level"
import "actives"
import "hero"
import "hud"
import "debugmenu"

local pd <const> = playdate
local gfx <const> = pd.graphics

-- master switch for the debug facilities (menu, overlays, status line);
-- flip to false for release builds
local DEBUG <const> = true

-- the reference game runs a fixed 20 fps loop (em.py Gameplay.run)
pd.display.setRefreshRate(20)

Hero.imageTable = gfx.imagetable.new("images/hero")
assert(Hero.imageTable, "failed to load hero sprite set")
-- tiny 7px font for the debug readout (from the SDK's Resources/Fonts)
local debugFont <const> = gfx.font.new("fonts/font-rains-1x")
assert(debugFont, "failed to load debug font")
if DEBUG then
    Debug.init()
end
Game.loadLevel(0)

function pd.update()
    if Game.completed then
        gfx.clear(gfx.kColorBlack)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        gfx.drawTextAligned("GAME COMPLETED", 200, 116, kTextAlignment.center)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
        return
    end

    local menuUp = DEBUG and Debug.menuOpen
    if menuUp then
        -- the game freezes (updates and the frame counter stop) while the
        -- debug menu eats the input
        Debug.update()
    else
        -- controller (emgame.py Controller); A doubles as jump for comfort,
        -- B shoots. Fly mode nudges one tile per d-pad PRESS (Shift+arrows).
        local ctl = Hero.ctl
        local fly = DEBUG and Hero.debugFly
        local pressed = fly and pd.buttonJustPressed or pd.buttonIsPressed
        ctl.left = pressed(pd.kButtonLeft)
        ctl.right = pressed(pd.kButtonRight)
        ctl.up = pressed(pd.kButtonUp)
            or (not fly and pd.buttonIsPressed(pd.kButtonA))
        ctl.down = pressed(pd.kButtonDown)
        ctl.fire = pd.buttonIsPressed(pd.kButtonB)

        -- update order matches em.py loop_run: current screen's actives,
        -- then the player (who may switch screens; the new screen's actives
        -- only start updating next frame, like the reference)
        Actives.update(Level.active)
        Hero:update()
        Game.checkLevelExit()  -- em.py run(): after the gameplay update
        -- projectiles spawned this frame join the screen now: drawn this
        -- frame, updated from the next (ScreenManager.update_active in
        -- display_screen)
        Actives.flushPending()
        Game.counter = Game.counter + 1
    end

    gfx.clear(gfx.kColorBlack)
    gfx.setClipRect(OFFX, OFFY, MAX_X, MAX_Y)
    Level.bgImage:draw(OFFX, OFFY)
    Actives.draw(Level.active, false)
    Hero:display()
    if Level.frontImage then
        Level.frontImage:draw(OFFX, OFFY)
    end
    Actives.draw(Level.active, true)
    Hud.draw()   -- over everything, like the reference indicators
    if DEBUG and Debug.showCollisions then
        Debug.drawCollisions()
    end
    gfx.clearClipRect()

    if DEBUG then
        -- status readout in the top margin; the font is 8px/char monospace,
        -- so keep the line under ~50 chars
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        debugFont:drawText(Level.name .. " s" .. Level.screenNumber ..
                           " (" .. Hero.x .. "," .. Hero.y .. ")" ..
                           " d" .. Game.disks .. " pwr" .. Hero.power ..
                           " ammo" .. Hero.ammo .. " tmp" .. Hero.temp ..
                           (Hero.debugFly and "  fly" or ""), 4, 8)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end

    if menuUp then
        Debug.drawMenu()
    end
end
