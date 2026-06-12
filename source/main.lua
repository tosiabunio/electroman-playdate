-- Electro Man - Playdate port
-- Hero movement with collision, screen transitions, teleports and animated
-- active entities, ported from python/em.py + emhero.py + emgame.py.

import "CoreLibs/graphics"
import "sound"
import "game"
import "level"
import "actives"
import "hero"
import "hud"
import "letters"
import "menu"
import "music"
import "presentation"
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
-- the system menu replaces the reference's Esc quit-to-menu path (em.py
-- on_k_escape); opening it is already a deliberate act, so the original's
-- "quit (y or n)" confirmation is skipped
pd.getSystemMenu():addMenuItem("main menu", function()
    if Game.state == "play" then
        Music.stop()
        Game.state = "menu"
        Menu.open()
    end
end)
-- the R-key restart (EB.H:68, em.py on_k_r) as a pause-menu item; like
-- "main menu", the system menu is deliberate enough that the original's
-- "restart level? (y or n)" confirmation is skipped. Matches EB.C:1087:
-- a full fresh reload (start position, disks, weapon all reset).
pd.getSystemMenu():addMenuItem("restart level", function()
    if Game.state == "play" then
        Game.loadLevel(Game.currentLevel)
    end
end)
-- boot into the title page (em.py fast_main: title -> menu -> gameplay)
Presentation.title()

-- A/B pressed to accept a menu or presentation screen stay swallowed until
-- released, so the accept press doesn't fire (A) or jump (B) on the first
-- gameplay frames
local swallowA, swallowB = false, false
local function swallowButtons()
    swallowA = true
    swallowB = true
end

function pd.update()
    if Game.state == "presentation" then
        gfx.clear(gfx.kColorBlack)
        Presentation.draw()
        if pd.buttonJustPressed(pd.kButtonA)
                or pd.buttonJustPressed(pd.kButtonB) then
            Music.stop()
            local mode = Presentation.mode
            if mode == "title" then
                Game.state = "menu"
                Menu.open()
            elseif mode == "levelcomplete" then
                Game.loadLevel(Presentation.nextLevel)
                swallowButtons()
            else
                -- congratulations -> back to the title page (em.py
                -- fast_main loops to the top after game completion)
                Presentation.title()
            end
        end
        return
    end

    if Game.state == "menu" then
        local result = Menu.update()
        gfx.clear(gfx.kColorBlack)
        Menu.draw()
        if result == "new_game" then
            Game.loadLevel(0)
            swallowButtons()
        elseif result == "continue" then
            Game.continueGame()
            swallowButtons()
        end
        return
    end

    local menuUp = DEBUG and Debug.menuOpen
    if menuUp then
        -- the game freezes (updates and the frame counter stop) while the
        -- debug menu eats the input
        Debug.update()
    else
        -- controller (emgame.py Controller); A shoots, B doubles as jump
        -- for comfort. Fly mode nudges one tile per d-pad PRESS
        -- (Shift+arrows).
        local ctl = Hero.ctl
        local fly = DEBUG and Hero.debugFly
        local pressed = fly and pd.buttonJustPressed or pd.buttonIsPressed
        swallowA = swallowA and pd.buttonIsPressed(pd.kButtonA)
        swallowB = swallowB and pd.buttonIsPressed(pd.kButtonB)
        ctl.left = pressed(pd.kButtonLeft)
        ctl.right = pressed(pd.kButtonRight)
        ctl.up = pressed(pd.kButtonUp)
            or (not fly and not swallowB and pd.buttonIsPressed(pd.kButtonB))
        ctl.down = pressed(pd.kButtonDown)
        ctl.fire = not swallowA and pd.buttonIsPressed(pd.kButtonA)

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
