# Electro Man for Playdate

A port of the 1992 DOS platformer **Electro Body / Electro Man** (xLand
Games) to the [Panic Playdate](https://play.date) console.

The game logic is ported line-by-line from **pyelectroman**, a faithful
pygame reimplementation of the original DOS C source, which serves as the
reference implementation. All gameplay values run at the game's native
scale and the original Borland C 3.1 RNG is reproduced exactly, so entity
animations and random seeding match the original frame-for-frame.

## Status

Ported and playable:

- Screen rendering from 1-bit image tables, with in-front tile layering
- The hero: movement FSM, collision, jumping/falling, screen-edge
  transitions, teleports, all 7 touch types, death and checkpoint respawn
- Shooting: 5 weapon power levels (incl. the double-height level-5 bow),
  weapon heat/overheat, magazines, batteries
- Hostiles: platform and flying enemies, cannons, rockets, killing floors,
  enemy projectiles, contact death
- Shootable/destroyable scenery with broken-sprite debris
- Level sequencing across all levels, disks, exits, secret/special items
- HUD: temperature and power LED bars, disk display

Not ported yet: sound, the main menu, save/load.

## Controls

| Input | Action |
|---|---|
| d-pad left/right | walk |
| d-pad up / A | jump |
| d-pad down | enter teleport / use exit / use special item |
| B | fire |

## Building

Requires the [Playdate SDK](https://play.date/dev/) with
`PLAYDATE_SDK_PATH` set. `pdc` needs an absolute path for the output:

```powershell
& "$env:PLAYDATE_SDK_PATH\bin\pdc.exe" <absolute path>\source <absolute path>\ElectroMan.pdx
& "$env:PLAYDATE_SDK_PATH\bin\PlaydateSimulator.exe" <absolute path>\ElectroMan.pdx
```

## Debug menu

Debug facilities are gated by the `DEBUG` flag at the top of
`source/main.lua` (flip to `false` for release builds).

- **On device / simulator**: the system (pause) menu's *debug menu* item
  opens a modal overlay — d-pad navigates, left/right adjusts, A activates,
  B closes; the game is frozen while it is open. Entries: level jump,
  screen ±1/±16, fly mode (movement FSM suspended, one-tile d-pad nudges),
  collision-box overlay, weapon select, kill hero, give 3 disks.
- **Simulator keyboard**: `1`–`9` level jump, `c` collision boxes, `g` fly
  mode, `k` kill, `f` 3 disks, `[` / `]` screen ±1, `-` / `=` screen ±16.

## Testing

`tools/headless_smoke.py` runs the actual game Lua under a desktop Lua
runtime with the Playdate API stubbed out and fuzz-plays every screen of
every level (~70k frames), catching runtime errors that the `pdc` compile
pass cannot. Run it after any Lua change:

```
pip install lupa
python tools/headless_smoke.py
```

## Project structure

```
source/
  main.lua        fixed 20 fps loop, input, draw order
  game.lua        global game state, level sequencing
  level.lua       level data, sprite metadata, per-screen collisions/baking
  actives.lua     all active entities (animations, hostiles, projectiles)
  hero.lua        the player: FSM, physics, touch handling, weapons
  hud.lua         LED bars and disk display
  debugmenu.lua   debug overlay menu and simulator hotkeys
  images/         1-bit sprite-set image tables (baked from original art)
  levels/         level maps (.ebl JSON, converted from original .ggc)
  sprites/        per-set sprite metadata (.ebs JSON)
  sounds/         converted sound effects (not yet used)
  fonts/          small debug font (from the Playdate SDK resources)
tools/
  headless_smoke.py   headless fuzz-test harness
```

Game assets are converted from the original DOS data files by the asset
pipeline in the pyelectroman project (`conversion/` there): sprite sets are
baked to 1-bit Playdate image tables, levels to JSON, sounds to WAV.

## License

- Code: MIT License (see [LICENSE](LICENSE))
- Art assets: CC BY-SA 4.0 (from the original game)

## Acknowledgments

- Original game by xLand (1992)
- Ported from the pyelectroman reference implementation
- AI development assistance by Claude Code
