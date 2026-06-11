"""Count active entity kinds across all levels (sanity check for the port)."""

import headless_smoke  # noqa: F401  (runs the fuzz; we reuse its lua state)

counts = headless_smoke.lua.eval("""
function()
    local out = {}
    for i = 0, #Game.levelNames - 1 do
        Game.loadLevel(i)
        for n = 1, 256 do
            for _, e in ipairs(Level.actives[n]) do
                out[e.kind] = (out[e.kind] or 0) + 1
            end
        end
    end
    return out
end
""")()

for kind, n in sorted(dict(counts).items()):
    print("%-14s %d" % (kind, n))
