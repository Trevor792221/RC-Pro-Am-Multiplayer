# R.C. Pro-Am – 2 Player patch

An IPS patch for **R.C. Pro-Am (USA) (Rev 1)** on the NES that adds simultaneous
two-player racing, played much like R.C. Pro-Am II's multiplayer: both
players share one screen, the screen follows whoever is ahead, and a player who
falls off the screen is pulled back in behind the leader.

All of the patch's code is new and written for this project. It contains no
code or data from R.C. Pro-Am II. One-player games are unchanged: they run
cycle-for-cycle the same as the unpatched game (see *Testing*).

## Applying

Patch file: [`rcproam_2p.ips`](rcproam_2p.ips)

Base ROM: `R.C. Pro-Am (USA) (Rev 1).nes` (iNES file, 65,552 bytes)

| | CRC32 | SHA-1 |
|---|---|---|
| whole file | `0296E5F4` | `fc133e4eda2ce05e163782d494aedace543a9ed2` |
| without the 16-byte header | `AAED295C` | `e9ddcfc47956fa55623621a2475bf6df70489426` |

Apply it with any IPS tool (Flips, Lunar IPS, an online patcher). The result is
a 98,320-byte file with CRC32 `BA00BA0C`.

The patched ROM has an NES 2.0 header: mapper 1 (MMC1), 32 KB PRG-ROM, 64 KB
CHR-ROM and 8 KB PRG-RAM. It works in current emulators (tested with an
independent emulator, *cynes*, as well as the project's own) and on flash carts
that support MMC1 with PRG-RAM.

## How to play

* On the title screen ("PUSH START / FOR 1 PLAYER") press **SELECT** on
  controller 1, or **START** on controller 2. The text changes to
  **FOR 2 PLAYERS**. Press the same button again to switch back to 1 player.
* Player 1 presses **START** to begin.
* Controls are the same for both players: **B** accelerates, **A** fires,
  **left/right** steer. Only player 1's START pauses the game.

### Rules in a 2 player game

* Player 1 drives the red car. Player 2 drives car 2 (green), which is a CPU
  car in a 1-player game. The other two cars are CPU cars.
* Player 2's car uses the game's own player-car handling, so both cars behave
  exactly alike: same physics, crashes, jumps and weapons.
* Each player collects their own upgrades (tires, turbo, engine), missiles and
  bombs from the track. The NINTENDO letters (and the new vehicle they earn)
  and the score belong to the team.
* Each car has its own position tag (1ST, 2ND, …).
* The screen follows the human who is further along the course and pans
  smoothly when the lead changes. If the other human is off screen for about a
  third of a second, their car is put back on the track a short way behind the
  leader, at a standstill.
* As in the original, the race ends when the first car finishes. You go on to
  the next race if at least one human beat at least one CPU car (the better
  placed human counts). If both humans finish behind both CPU cars, you're out
  and get the usual continue / game over screens.

### Limitations

* The HUD shows player 1's speed and ammunition. Player 2's ammunition is not
  displayed.
* The between-race upgrade screen shows player 1's upgrades.
* Player 2's car has no engine sound.
* Only player 1 can pause.

## How it works

R.C. Pro-Am has almost no unused PRG-ROM (86 bytes) and no free CHR-ROM. To
avoid moving original data around, which would put original game data into the
patch, the new code lives in two **new CHR-ROM banks appended to the end of the
file**. A 45-byte loader, in 47 free bytes at `$F8D1`, copies them into the
8 KB PRG-RAM at `$6000` when the console resets. The original program reaches
the new code through 7 small hooks (listed in `build.py`):

| address | hook |
|---|---|
| `$8028` | reset: run the loader |
| `$9BBF` | object loop, cars 0–3: player 2's car |
| `$9BF5`, `$9BF8` | after the objects move: position tags, pull-along, sprite placement |
| `$AA31` | race result |
| `$D0D1`, `$D120` | title screen text and 1/2 player switch |

Player 2's car runs the game's own player-car code. Before car 2's update, its
state (and that of its missile slot) is swapped with player 1's car slot,
together with the player-only variables (controller, steering, upgrades, ammo).
The player handler then runs as if it were player 1's car, and everything is
swapped back.

The race frame uses almost all of the NES's CPU time after the HUD split.
To keep one-player games identical, hooks that run during a race cost either
0 extra cycles (the object dispatcher is self-modifying code in RAM that is
exactly the original `jmp ($001E)` in 1 player mode) or a multiple of 8 cycles
before the HUD split. The game waits for the split with an 8-cycle polling loop,
so the split and everything after it happen on exactly the same CPU cycle as in
the unpatched game.

## Building

Requirements: Python 3, `ca65`/`ld65` (cc65), and the original ROM.

```
python3 build.py "R.C. Pro-Am (USA) (Rev 1).nes"
```

This assembles `src/mp.s`, writes `build/rcproam_2p.nes`, and regenerates
`rcproam_2p.ips`.

## Testing

`tools/emu` contains a small NES emulator (C, with a Python wrapper) written for
this project, with breakpoints, memory watches and cycle counting. Build it with

```
gcc -O2 -shared -fPIC -o tools/emu/libemu.so tools/emu/emu.c
```

and run the tests (Python 3 with numpy, and Pillow for screenshots):

```
export RCPA_ROM="R.C. Pro-Am (USA) (Rev 1).nes"
python3 tests/test_1p_identical.py   # 1 player: original vs patched, frame by frame
python3 tests/test_2p.py out/         # 2 player scenarios (+ screenshots in out/)
```

`test_1p_identical.py` starts the original and the patched game from the same
machine state and plays both with the same autopilot inputs through several
races, game over and continue, and the attract mode. It compares RAM and the
picture on every frame.
`test_2p.py` covers the title switch, races with both players driving, either
player idle (pull-along and camera), qualifying, player 2's weapons, pickups and
crashes, and several races in a row.
