-- Main menu (emmenu.py MainMenu), shown at boot and after game over.
-- Device adaptations: no QUIT entry (there is no quit concept on the
-- Playdate — the system menu leaves the game), and the selection is
-- marked with blinking parentheses because the letters set has no '>'
-- arrow glyph (the Python menu's CHAR_MAP '>' is really the '_' cursor).

local pd <const> = playdate

Menu = {}

local OPTIONS <const> = {
    {label = "continue", result = "continue"},
    {label = "new game", result = "new_game"},
}

local selected = 2
local hasSave = false
local blinkTimer = 0
local blinkOn = true

function Menu.open()
    hasSave = Game.loadSave() ~= nil
    selected = hasSave and 1 or 2   -- no save: start on NEW GAME
    blinkTimer, blinkOn = 0, true
end

-- emmenu.py move_selection: wrap around, skip CONTINUE when there is no
-- save, 'ask' blip on change.
local function move(dir)
    local new = selected + dir
    if new < 1 then
        new = #OPTIONS
    elseif new > #OPTIONS then
        new = 1
    end
    if new == 1 and not hasSave then
        new = dir > 0 and 2 or #OPTIONS
    end
    if new ~= selected then
        Sound.play("ask")
    end
    selected = new
end

-- Navigation/selection ("up"/"down"/"select"), exposed separately from
-- the input polling for the headless harness. "select" returns the chosen
-- option's result ("continue"/"new_game"), everything else nil.
function Menu.action(what)
    if what == "up" then
        move(-1)
    elseif what == "down" then
        move(1)
    elseif what == "select" then
        local opt = OPTIONS[selected]
        if opt.result == "continue" and not hasSave then
            return nil
        end
        Sound.play("ask")
        return opt.result
    end
    return nil
end

-- Poll input once per frame; returns the selection result or nil.
function Menu.update()
    -- selection blink, 10 frames at 20 fps (emmenu.py arrow blink)
    blinkTimer = blinkTimer + 1
    if blinkTimer >= 10 then
        blinkTimer = 0
        blinkOn = not blinkOn
    end
    if pd.buttonJustPressed(pd.kButtonUp) then
        Menu.action("up")
    elseif pd.buttonJustPressed(pd.kButtonDown) then
        Menu.action("down")
    elseif pd.buttonJustPressed(pd.kButtonA)
            or pd.buttonJustPressed(pd.kButtonB) then
        return Menu.action("select")
    end
    return nil
end

function Menu.draw()
    Letters.drawCentered("electro man", 56)
    for i, opt in ipairs(OPTIONS) do
        local y = 128 + (i - 1) * 36
        Letters.drawCentered(opt.label, y, i == 1 and not hasSave)
        if i == selected and blinkOn then
            local x = (400 - Letters.width(opt.label)) // 2
            Letters.drawLine("(", x - 30, y)
            Letters.drawLine(")", x + Letters.width(opt.label) + 6, y)
        end
    end
end
