# NBA Basketball (Mattel, 1978) — FujiNet netplay, 2 players

The thirteenth FujiNet netplay port of an EXEC-era Intellivision cart.
Two consoles run the whole original NBA Basketball in delay-based
lockstep, matched through a room-based lobby. Play is **simultaneous** —
the cart has no player-count prompt at all; both teams are always live,
gated only by the game's own `$0163` input-enable bits, exactly like
Boxing's two boxers.

## Status

**Working. Every automated gate in the ladder passes**:

| gate | result |
|---|---|
| `make verify-org` | byte-identical rebuild |
| `make verify-patch` | exactly the 39 declared words differ |
| `make check-7000` | no build maps or overflows into `$7000` |
| live boot-dump | every phase-machine cell and native-slot state matched the unpatched ROM exactly at the same stop point |
| `make det` | 256/256 tick checksums identical under stall injection, destination phase asserted |
| `make lagcheck` | 209/209 agreement at shift=20 — a perfect peak |
| `make server-diff` | 6/6 scenarios, 2 seats |
| `make rig PLAYERS=2` | live lockstep, 0 CRC mismatches |
| `make m4 PLAYERS=2` (+ `QUIESCE=1`) | desync injected, detected, repaired — both the cap-path AND the quiescent-path proven |
| `make peerleft PLAYERS=2` | drop ends the match for the survivor, both leave modes, correct terminal screens |

Not yet done: real-hardware bring-up (`make rom SRV_HOST=...` already
built the images — `build/basketball_net.rom`, `build/basketball_nethud.rom`).

This port needed three real fixes along the way, all investigated and
resolved — see `spikes/NOTES.md` for the full trail:

1. **RNG seeding**: the canonical RNG mirror defaults to zero at boot,
   which is a degenerate seed for this cart's LFSR — a "re-roll until
   different" game loop hung forever the first time this was tried.
   Fixed with a non-zero seed (Armor Battle's own precedent); real
   netplay's own server-assigned seed is non-zero by construction and
   overrides it before play begins.
2. **A new hazard shape**: `$016B`, a one-shot event latch derived from
   an object record's real-frame-advanced field+5 counter, inherits that
   field's non-determinism despite sitting outside the object table —
   excluded from every state-compare tool alongside field+5 itself.
3. **Sound-engine-state drift (PORTING.md §7.21)**: 6 of 8 SFX call
   sites needed retargeting to a no-op stub — one found via `make det`
   bisection (a ball-bounce trigger), five more via a real `make rig`
   desync (clean through tick 704, then a permanent mismatch, tracing
   back to a made-basket-triggered crowd cheer that simply hadn't
   happened yet in the first 35 seconds of fuzzed input). Two sites
   remain a documented, accepted residual — their callers carry inline
   SFX envelope data a plain-return stub would misinterpret as code, and
   the shared EXEC routine they call recurses through several stateful
   subroutines; `make m4` confirms the CRC+resync mechanism is a real
   safety net for this class of leak (Auto Racing's own shipped
   precedent for exactly this trade-off).

## Build & run

Prereqs: as1600/dis1600/bin2rom (jzIntv SDK), jzIntv with `--fujinet`,
fujinet-pc-rs232 dist, Python 3.

```sh
make verify-org                    # gate 0: byte-identical rebuild
make hook && make run-hook          # patched-but-local build (feel test)
make det                            # determinism proof, 256/256 ticks
make lagcheck                       # interception + delay ring proof
make rig PLAYERS=2                  # full 2-console local netplay rig, headless
make m4 PLAYERS=2                   # desync inject + repair (cap path)
QUIESCE=1 make m4 PLAYERS=2         # desync inject + repair (quiescent path)
make peerleft PLAYERS=2 LEAVER=2 LEAVE_MODE=clean    # or timeout
make rom SRV_HOST=fujinet.online    # hardware image -> build/basketball_net.rom
make rom-hud                        # same with the live HUD row (bring-up)
server/run_production.sh            # relay on :9114, registered on the FujiNet Lobby
```

Port 9114 / Lobby appkey 22 are this port's assignments on the shared
host, once provisioned. `FN_BOIP` (9995 by default) may need pointing at
a free port for `echo-test`/`run-net1` if another instance holds it —
`rig`/`m4`/`peerleft` set up their own isolated private copies
automatically and are unaffected.

## What is different from the sibling ports

- **Simultaneous 2-player, no turn arbiter, no player-count prompt at
  all** — the cart has nothing like Bowling/Golf's alternating turns or
  Shark Shark's boot-time keypad choice. Both seats are gated purely by
  `$0163` bits 7/6, and `QUIESCE=1` forcing worked on the first attempt
  because that cell is raw state, not a value some per-tick routine
  recomputes (Shark Shark's `SS_QUIESCENT` needed three investigative
  sessions for exactly that reason).
- **Native dispatch for 4 of 5 game timer entries** (PORTING.md §7.31,
  Boxing's proven shape): only the primary 20 Hz entry moves into
  `MASTER_TICK`; the game clock, shot clock, animation walk, and ball
  blink stay at their original table slots and intervals, firing
  natively — `$17D5`'s own dispatch order makes them exactly as
  stall-safe as hand-rolled virtualization, with far less shim code.
- **All 6 timer arm/stop call sites use a PC-relative addressing shape**
  (`MOVR R7,R1 / SUBI #k`) no prior port has needed to patch — there is
  no `MVII #addr,R1` operand to retarget, only the `SUBI` immediate, so
  **no shim is needed at all**, unlike every prior native-dispatch port.
- **The family's usual defensive `X_MUSIC_TICK`-style placeholder comes
  for free**: the cart's own timer table slot 0 is already the EXEC's
  own SFX entry, so no extra dummy row is needed.
- **A hybrid poll+dispatch input surface with exactly one polled site**:
  a single `$011F`-relative read serves both seats (Armor Battle/Frog
  Bog's shape), so `SHADOW_FROM_RINGS`-under-`LS_PASS` (§7.20) matters
  here exactly as it did there.
- **The busiest sound-engine-state-drift audit of any port**: 6 call
  sites needed the fix, versus one for Frog Bog/Boxing. The two left as
  an accepted residual are the family's clearest documented example of
  where the CRC+resync net, not exhaustive call-site patching, is the
  right tool.

## Layout

Same tree as the sibling ports (see `PORTING.md`, the canonical
methodology — this repo's copy is Shark Shark's, through §7.39).
`spikes/NOTES.md` holds the full per-milestone evidence trail (M0-M6).
