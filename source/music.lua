-- Pattern music (emsound.py MusicPlayer, EB.C:1139-1295). The original
-- engine has no music format: songs are strings of ~2-4 s 8 kHz sample
-- patterns chained gaplessly on a dedicated channel, looping forever.
-- The Playdate port plays each song pre-rendered to one loopable file
-- (python/conversion/bake_presentation.py) — gapless by construction —
-- and recovers song_pos, which the title screen's image flip is synced
-- to, from the player offset and the baked pattern-boundary table.

local snd <const> = playdate.sound

Music = {}

local SONGS <const> = json.decodeFile("music/songs.json")
assert(SONGS, "failed to load music/songs.json")

local player = nil
local ends = nil    -- current song's cumulative pattern ends, in samples
local total = 0

function Music.play(name)
    Music.stop()
    if not Sound.enabled then
        return
    end
    ends = SONGS.ends[name]
    total = ends[#ends]
    player = snd.fileplayer.new("music/" .. name)
    if player then
        player:play(0)   -- loop endlessly
    end
end

function Music.stop()
    if player then
        player:stop()
        player = nil
    end
end

-- Index of the pattern currently playing (MusicPlayer.song_pos).
function Music.songPos()
    if not player then
        return 0
    end
    local sample = (player:getOffset() * SONGS.rate) // 1 % total
    for i = 1, #ends do
        if sample < ends[i] then
            return i - 1
        end
    end
    return 0
end
