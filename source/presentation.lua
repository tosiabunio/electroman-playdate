-- Presentation screens (emmenu.py MusicScreen, EB.C:1204-1295): a
-- full-screen 320x200 bitmap with looping pattern music — the title page
-- (tit1/tit2 alternating, synced to the music), the level-completed
-- screen, and the congratulations screen. Device adaptations: any button
-- is fire; the Esc "exit to dos? (y or n)" overlay is dropped (no quit
-- concept on the console), as is the loading animation (EB.C:460-472 —
-- asset loads are near-instant).

local gfx <const> = playdate.graphics

Presentation = {mode = nil, nextLevel = nil}

-- the 320x200 bitmap centered on the 400x240 screen, 1:1 like gameplay
local ORGX <const>, ORGY <const> = 40, 20

local img1, img2, message

local function show(mode, name1, name2, msg, song)
    Presentation.mode = mode
    img1 = gfx.image.new("images/" .. name1)
    img2 = name2 and gfx.image.new("images/" .. name2) or img1
    message = msg
    Game.state = "presentation"
    Music.play(song)
end

-- Title page (EB.C:1475): tit1/tit2 to tit_song.
function Presentation.title()
    show("title", "tit1", "tit2", "", "tit")
end

-- "Well done" screen after a completed level (EB.C:1532): back bitmap +
-- cod_song + the MESSAGES.H:25 MELEVCMP message.
function Presentation.levelCompleted(levelNumber, nextLevel)
    Presentation.nextLevel = nextLevel
    show("levelcomplete", "back", nil,
         "good job* *level " .. levelNumber .. "*completed* *press fire",
         "cod")
end

-- Game-completed screen (EB.C:1556): over bitmap + end_song.
function Presentation.congratulations()
    show("congrats", "over", nil, "", "fin")
end

function Presentation.draw()
    local img = img1
    if Presentation.mode == "title" then
        -- the original redraws at every 4th pattern, alternating the
        -- bitmap (EB.C:1222-1240): patterns 0-2 scr1, 3-6 scr2, 7-10
        -- scr1, ... (emmenu.py MusicScreen.current_image)
        if ((Music.songPos() + 1) // 4) % 2 == 1 then
            img = img2
        end
    end
    if img then
        img:draw(ORGX, ORGY)
    end
    Letters.printText(message, ORGX, ORGY, 320, 200)
end
