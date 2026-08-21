# Claude guidance for fujinet-intv-basketball

Thirteenth FujiNet netplay port (NBA Basketball, Mattel 1978). **Read
`PORTING.md` before touching anything** — it is the accumulated
methodology of all twelve prior ports (this repo's copy is Shark
Shark's, through §7.39); `spikes/NOTES.md` has this cart's own evidence
trail (M0-M6).

**Working. Every automated gate in the ladder passes**: `verify-org` →
`verify-patch` (39 words) → `check-7000` → live boot-dump matches the
recon-predicted state → `lagcheck` (209/209 agreement at shift=20, a
perfect peak) → `det` (256/256 ticks identical under stall, destination
phase asserted) → `server-diff` (6/6 scenarios, 2 seats) → `rig
PLAYERS=2` (0 CRC mismatches once the SFX real-frame-drift fix was in
place) → `m4 PLAYERS=2`, both the plain cap-path AND `QUIESCE=1`'s
quiescent path (both PASS, full repair confirmed) → `peerleft
PLAYERS=2`, both leave modes → hardware images built
(`build/basketball_net.rom`, `build/basketball_nethud.rom`). **Not yet
run on real hardware** — that needs the user. Port 9114 / Lobby appkey
22 need provisioning on `fujinet.online` before a production launch.

**This cart is strictly 2 players, SIMULTANEOUS — no player-count
prompt at all.** Both seats are always live; the game gates each seat's
input through `$0163` bits 7 (P0)/6 (P1), active-low. There is nothing
like Bowling/Golf's turn arbiter and nothing like Shark Shark's
`$1910`-mediated "SELECT 1 OR 2 PLAYERS" prompt to answer — a real
simplification versus the two most recent ports.

**This is one of the cleanest carts in the family**: no ISR dance, no
`X_SCAN` self-call, no cart-resident main-loop clone, zero STIC/GRAM
writes, and timer table slot 0 is already the EXEC's own SFX tick — the
defensive placeholder every OTHER port has to add by hand comes for
free here.

Key findings and confirmed decisions:

- **Timer table, 6 slots.** Slot 0 = `$1A71` (EXEC SFX tick, UNCHANGED —
  already live, not a placeholder). Slot 1 = `MASTER_TICK`, replacing
  `$5063` (primary 20 Hz game logic: input dispatch, ball/player
  motion) — nothing else in the relocated table reaches `$5063`
  (§7.31's own trap). **Slots 2-5 dispatch NATIVELY** (Boxing's proven
  shape, not full virtualization): `$51FF`/game clock, `$5233`/shot
  clock, `$5289`/animation walk, `$5074`/ball-blink toggle — all four
  timer-API-stoppable, all four mirrored into `SC_CNT2-9` (ram.asm) for
  CRC/resync coverage.
- **6 timer arm/stop sites, a shape no prior port needed**: every site
  computes its target as `MOVR R7,R1 / SUBI #k,R1` (current-PC-relative)
  rather than an absolute `MVII #addr,R1` operand. Because slots 2/3/5
  keep their ORIGINAL table position, the EXEC's own `.EXEC.811` helper
  (which re-reads the header's CURRENT timer-table pointer on every
  call, traced live in the EXEC disassembly) keeps working unmodified
  as long as R1 still equals `NEW_TIMER_TBL + 4*slot` — so
  `tools/patches.py` patches ONLY the `SUBI` immediate at each site
  (one word each), **no shim needed** at all, unlike every prior
  native-dispatch port.
- **Hybrid poll+dispatch input**: exactly ONE `$011F` reference in the
  whole ROM (`$544C ADDI #$011F,R2`), serving BOTH seats via
  `[$011F+seat]` — Armor Battle/Frog Bog's shape. Patched to
  `SHADOW_CTRL`/`SHADOW_CTRL_R` (ram.asm), fed by `UPDATE_SHADOW` (local
  passthrough) and `SHADOW_FROM_RINGS` (both the local `SPIKE_VIRT` path
  AND `lockstep.asm`'s `LS_PASS` — §7.20's rule that a single-process
  test can't catch this call's absence from the netplay-only path).
- **RNG seeding is load-bearing here.** `NET_START`'s zero-fill leaves
  the canonical RNG mirror at 0, which is a DEGENERATE seed for this
  cart's LFSR — a game "re-roll until different" loop (`$52DD`) hangs
  forever on an all-zero roll. Fixed by seeding `RNG_LO`/`RNG_HI`
  non-zero (Armor Battle's `$34`/`$12` precedent). Real netplay's own
  START-payload seed (already non-zero by construction,
  `server/intv_relay_server.py`'s `random.randrange(1, 0x10000)`)
  overwrites this before real play begins; the fixed seed only matters
  for local/spike builds.
- **A genuinely new hazard class: a latch derived from field+5.** `$016B`
  is a one-shot event latch gated on MOB0's own field+5 (`$0322`, the
  real-frame-advanced animation counter §7.19 already excludes from the
  object table) — it inherits that non-determinism despite sitting in
  ordinary game-scratch space. Excluded from `debug.asm` `TRACE_RANGES`,
  `lockstep.asm` `LS_CKSUM`, and `tools/crc_trace_diff.py`'s
  settled-state check, all three split around it.
- **6 of 8 SFX call sites needed the §7.21 sound-engine-state-drift
  fix** (retargeted to a no-op `NB_SFX_SKIP` stub): the ball-bounce
  trigger (found via `make det` bisection, M2) plus `X_PLAY_RAZZ4` (x2),
  `X_PLAY_CHEER1` (x2, one gated behind a made-basket RNG roll), and
  `X_PLAY_WHST1` (found via a real `make rig` desync — clean through
  tick 704, then permanent mismatch, consistent with a scored basket
  finally happening after ~38s of masked fuzz — M4). **Two sites remain
  an accepted, documented residual** (`X_PLAY_SFX1` at `$5CFC`/`$5D19`):
  unlike the other six, these callers are followed by inline SFX
  envelope data that a plain-return stub would misinterpret as code,
  and the shared EXEC routine (`$1BBB`) recurses through multiple
  stateful subroutines — fixing them safely needs real EXEC-internals
  work beyond what a call-site patch can do. `make m4` confirms the
  CRC+resync mechanism is the actual safety net for this residual
  (Auto Racing's own shipped precedent for this exact hazard class,
  PORTING.md §7.21).
- **Resync quiescent point**: `$0163 & $00C0 == $00C0` (both seats'
  input disabled — dead ball). `RS_PENDING` needed one added line (a
  `CMPI` equality test, not the family's default any-bit `ANDI`/`BNEQ`)
  since this cart's dead-ball condition needs BOTH bits, not just one.
  Unlike Shark Shark's `SS_QUIESCENT` (a flag recomputed every tick,
  which took three investigative sessions to root-cause), `$0163` is a
  RAW cell here — `QUIESCE=1` forcing worked on the first attempt.
- **No ISR dance, no code-pointer clamp needed**: this cart never writes
  `$0100`/`$0101`. `SC_ISR_SAVE` is a harmless netcode-RAM spare
  (Sea Battle's/Golf's own precedent), `RS_CLAMP_ISR` a structural no-op.
- **Image layout**: 767 bytes (IMG_S1=147, IMG_S2=627, IMG_S3=755,
  tail=12: `RNG_LO/HI` + `SC_CNT2-9` + `GAME_TBL_LO/HI`) — two bytes
  SHORTER than the family's traditional 14-byte tail despite one more
  native-countdown pair than Boxing, because this cart has no turn-
  arbiter/injector cell to carry.

Hard rules carried from the family, all still apply:

- Never let any segment map, or overflow into, `$7000` (`make
  check-7000`, span form).
- Never put netcode RAM below `$8080` (STIC alias).
- Every fresh build variant must go through `make <target>`, never a
  bare `as1600` invocation — a hand-built `.cfg` is missing the
  `[memattr]` RAM declaration and produces a content-independent,
  misleading crash (§7.36) — confirmed the hard way this session during
  a diagnostic bisection (spikes/NOTES.md M2).
- Rig scripts `pkill` their own `fujinet -u 127.0.0.1:1808` instances —
  never type that pattern on an interactive shell command line
  (`pkill -f` matches your own shell and kills it).
- **A same-tick comparison is the only valid cross-console diagnostic.**
  Two consoles dumped at their own independent instruction-count park
  points land at DIFFERENT sim ticks purely from real login/matchmaking
  jitter (observed: a 3-tick gap after ~90s) — comparing their raw state
  directly is meaningless. The SERVER's own CRC log (keyed by tick
  number) is the right tool for finding a real cross-console divergence;
  it's what actually found the M4 desync's first-mismatch tick.

Assignments: production port **9114**, FujiNet Lobby appkey **22**,
maxplayers 2. The server (`server/intv_relay_server.py`) is protocol v2
(seat-tagged, rooms), `MAX_SEATS=2` (agrees with the Lobby payload's
`maxplayers: 2`); `server/c/` is the generic C relay, held to
byte-for-byte equality by `tools/server_diff.py --seats 2`.

Known open items (not blocking):

- The two unpatched `X_PLAY_SFX1` sites (above) — revisit if a future
  `make rig` run shows a fresh residual beyond what's already measured.
- `$55AF`'s table contents were never fully decoded (the second non-null
  `$035D` table, installed by `L_55D2`) — not a blocker, since
  adopt-don't-restore treats `$035D` tables opaquely regardless of
  contents.
- The controller↔on-screen-team mapping (`L_543B`'s XOR on `$0163` bit
  0) was never verified visually against which physical controller is
  live — worth a look during hardware bring-up.
