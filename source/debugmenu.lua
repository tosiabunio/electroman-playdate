-- Debug menu and overlays: the Playdate counterpart of the pygame debug
-- keys (em.py key_handlers — level jump, Ctrl+arrow screen change, Shift+
-- arrow nudges with the FSM suspended, Shift+D death, Shift+F disks,
-- Shift+number weapon select, Tab collision boxes).
--
-- Two entry paths: a modal overlay menu opened from the system (pause)
-- menu — d-pad navigates, A activates, B closes, the game freezes while
-- open — and, in the simulator only, direct keyboard shortcuts via
-- playdate.keyPressed.

local pd <const> = playdate
local gfx <const> = pd.graphics

Debug = {
    menuOpen = false,
    showCollisions = false,   -- gl.show_collisions
}

local font = gfx.font.new("fonts/font-rains-1x")
assert(font, "failed to load debug font")

local sel = 1
local levelSel = 0

-- ---------------------------------------------------------------------------
-- menu entries: label() renders the line, adjust(d) handles left/right,
-- activate() handles A (falls back to adjust(1) for toggles)

local entries = {
    {
        label = function()
            return "level < " .. Game.levelNames[levelSel + 1] .. " >  a loads"
        end,
        adjust = function(d)
            levelSel = (levelSel + d) % #Game.levelNames
        end,
        activate = function()
            Game.loadLevel(levelSel)
            Debug.menuOpen = false
        end,
    },
    {
        label = function()
            return "screen +-1  < " .. Level.screenNumber .. " >"
        end,
        adjust = function(d)
            -- Ctrl+left/right: ±1 with full 256 wrap (em.py on_k_left/right)
            Level.changeScreen((Level.screenNumber + d) % 256)
        end,
    },
    {
        label = function()
            return "screen +-16 < " .. Level.screenNumber .. " >"
        end,
        adjust = function(d)
            -- Ctrl+up/down: ±16 (em.py on_k_up/down)
            Level.changeScreen((Level.screenNumber + d * 16) % 256)
        end,
    },
    {
        label = function()
            return "fly mode [" .. (Hero.debugFly and "on" or "off") .. "]"
        end,
        adjust = function()
            Hero.debugFly = not Hero.debugFly
        end,
    },
    {
        label = function()
            return "collision boxes [" ..
                   (Debug.showCollisions and "on" or "off") .. "]"
        end,
        adjust = function()
            Debug.showCollisions = not Debug.showCollisions
        end,
    },
    {
        label = function()
            return "weapon < " .. Hero.power .. " >"
        end,
        adjust = function(d)
            -- Shift+number: select_weapon(n) (em.py on_k_0..5)
            local p = Hero.power + d
            if p >= 0 and p <= 5 then
                Hero:selectWeapon(p)
            end
        end,
    },
    {
        label = function()
            return "sound [" .. (Sound.enabled and "on" or "off") .. "]"
        end,
        adjust = function()
            Sound.toggle()
        end,
    },
    {
        label = function()
            return "kill hero"
        end,
        activate = function()
            Hero:debugKill()
            Debug.menuOpen = false
        end,
    },
    {
        label = function()
            return "give 3 disks"
        end,
        activate = function()
            Game.disks = 3
        end,
    },
}

-- ---------------------------------------------------------------------------

function Debug.show()
    sel = 1
    levelSel = Game.currentLevel
    Debug.menuOpen = true
end

function Debug.menuAction(action)
    local e = entries[sel]
    if action == "up" then
        sel = (sel - 2) % #entries + 1
    elseif action == "down" then
        sel = sel % #entries + 1
    elseif action == "left" then
        if e.adjust then e.adjust(-1) end
    elseif action == "right" then
        if e.adjust then e.adjust(1) end
    elseif action == "activate" then
        if e.activate then
            e.activate()
        elseif e.adjust then
            e.adjust(1)
        end
    end
end

-- input while the menu is open (the game's update is skipped)
function Debug.update()
    if pd.buttonJustPressed(pd.kButtonUp) then Debug.menuAction("up") end
    if pd.buttonJustPressed(pd.kButtonDown) then Debug.menuAction("down") end
    if pd.buttonJustPressed(pd.kButtonLeft) then Debug.menuAction("left") end
    if pd.buttonJustPressed(pd.kButtonRight) then Debug.menuAction("right") end
    if pd.buttonJustPressed(pd.kButtonA) then Debug.menuAction("activate") end
    if pd.buttonJustPressed(pd.kButtonB) then Debug.menuOpen = false end
end

local PANEL_W <const> = 240
local PANEL_X <const> = (400 - PANEL_W) // 2
local PANEL_Y <const> = 60

function Debug.drawMenu()
    local h = #entries * 10 + 26
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(PANEL_X, PANEL_Y, PANEL_W, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(PANEL_X, PANEL_Y, PANEL_W, h)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    for i, e in ipairs(entries) do
        font:drawText((i == sel and "> " or "  ") .. e.label(),
                      PANEL_X + 6, PANEL_Y + 6 + (i - 1) * 10)
    end
    font:drawText("  a: select   b: close",
                  PANEL_X + 6, PANEL_Y + 12 + #entries * 10)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

-- Collision-box overlay (em.py display_screen + Entity.display_collisions):
-- screen collisions, every active entity's current-frame bbox, and the
-- hero's movement and enemy-contact boxes. XOR so it reads on any tile.
function Debug.drawCollisions()
    gfx.setColor(gfx.kColorXOR)
    for _, c in ipairs(Level.collisions) do
        gfx.drawRect(OFFX + c.x, OFFY + c.y, c.w, c.h)
    end
    for _, e in ipairs(Level.active) do
        local bx, by, bw, bh = Actives.entityBox(e)
        gfx.drawRect(OFFX + e.x + bx, OFFY + e.y + by, bw, bh)
    end
    local b = Hero.bbox
    gfx.drawRect(OFFX + Hero.x + b.x, OFFY + Hero.y + b.y, b.w, b.h)
    b = Hero.enemyBox
    gfx.drawRect(OFFX + Hero.x + b.x, OFFY + Hero.y + b.y, b.w, b.h)
end

-- ---------------------------------------------------------------------------
-- simulator-only keyboard shortcuts (playdate.keyPressed receives keys the
-- simulator itself doesn't consume); mirrors em.py key_handlers
local keys = {
    ["c"] = function() Debug.showCollisions = not Debug.showCollisions end,
    ["g"] = function() Hero.debugFly = not Hero.debugFly end,
    ["k"] = function() Hero:debugKill() end,
    ["f"] = function() Game.disks = 3 end,
    ["m"] = function() Sound.toggle() end,   -- F7 in the reference
    ["["] = function() Level.changeScreen((Level.screenNumber - 1) % 256) end,
    ["]"] = function() Level.changeScreen((Level.screenNumber + 1) % 256) end,
    ["-"] = function() Level.changeScreen((Level.screenNumber - 16) % 256) end,
    ["="] = function() Level.changeScreen((Level.screenNumber + 16) % 256) end,
}

function Debug.key(key)
    local n = tonumber(key)
    if n and n >= 1 and n <= #Game.levelNames then
        Game.loadLevel(n - 1)
        return
    end
    local handler = keys[key]
    if handler then
        handler()
    end
end

function Debug.init()
    pd.getSystemMenu():addMenuItem("debug menu", function()
        Debug.show()
    end)
    function pd.keyPressed(key)
        Debug.key(key)
    end
end
