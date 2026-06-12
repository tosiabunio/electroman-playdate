-- Sound effects, ported from emsound.py SoundManager (itself modeled on the
-- original DOS driver, EB.C:1410-1428): up to 8 simultaneous voices; when
-- all are busy a new sound preempts the lowest-priority playing one only if
-- its own priority is strictly higher, otherwise it is dropped.
--
-- One sampleplayer per effect: re-triggering an effect that is still
-- playing restarts it instead of layering a second copy (the one deviation
-- from the pygame mixer, which would pick another channel).

local snd <const> = playdate.sound

Sound = {
    enabled = true,
}

-- effect name -> sample file, priority (EB.H:96-114, EB.C:1410-1428)
local DEFS <const> = {
    shoot1 = {"wpn_1", 4},
    shoot2 = {"wpn_2", 4},
    shoot3 = {"wpn_3", 4},
    shoot4 = {"wpn_4", 4},
    shoot5 = {"wpn_5", 4},
    blast = {"xplosion", 8},
    teleport = {"teleport", 7},
    jump = {"jump", 2},
    jumpend = {"jumpend", 2},
    footstep = {"footstep", 1},
    warning = {"warning", 4},
    warning2 = {"warning2", 4},
    battery = {"battery", 6},
    shoot = {"shoot", 4},      -- enemy shot
    laser = {"laser", 3},      -- cannon / flying creature shot
    checkp = {"checkp", 9},
    disk = {"disk", 9},
    area = {"area", 9},
    ask = {"ask", 9},
    eshoot = {"eshoot", 4},
}

local CHANNELS <const> = 8

-- The converted samples are normalized near digital full-scale (the
-- .u8 -> WAV conversion keeps the original 8-bit range), so at the
-- default volume 1.0 every effect blasts at 0 dBFS and overlapping
-- voices clip. Per-voice attenuation keeps the mix comfortable and
-- leaves headroom for the 8-voice stack.
local VOLUME <const> = 0.4

local players = {}
for name, def in pairs(DEFS) do
    local sp = snd.sampleplayer.new("sounds/" .. def[1])
    if sp then
        sp:setVolume(VOLUME)
        players[name] = {sp = sp, prio = def[2]}
    end
end

function Sound.play(name)
    if not Sound.enabled then
        return
    end
    local p = players[name]
    if not p then
        return
    end
    local busy, lowest = 0, nil
    for _, q in pairs(players) do
        if q.sp:isPlaying() then
            busy = busy + 1
            if not lowest or q.prio < lowest.prio then
                lowest = q
            end
        end
    end
    if busy >= CHANNELS then
        if lowest and p.prio > lowest.prio then
            lowest.sp:stop()
        else
            return   -- all voices equal or higher priority: drop
        end
    end
    p.sp:play(1)
end

-- F7 in the reference
function Sound.toggle()
    Sound.enabled = not Sound.enabled
end
