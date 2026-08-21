# NBA Basketball port -- spike notes

Thirteenth FujiNet netplay port (NBA Basketball, Mattel 1978). Scaffolded
from the Shark Shark tree (newest tooling at the time: `check_7000.py`'s
span check, the 2-seat `server_diff.py` pin, the dedicated `LAG_RING`
`lagcheck` design), with the 8K-cart-specific machinery (hook segment at
`$6800`, `dump_rom.py --stop`, `check_patch.py`'s compare-length arg)
reverted, since this cart is a plain 4K-word image ($5000-$5FFF) like
every port before Shark Shark.

## M0 -- recon

Tools: `tools/recon.py` (borrowed from the shark-shark tree before this
repo had its own copy), `dis1600` against the real ROM, and a live
headless boot dump against `~/Workspace/fujinet-intv-boxing/rom/exec.bin`
+ `grom.bin` (any sibling port's EXEC/GROM pair works -- they're
identical across the family).

### Header / cart shape

4096 words at `$5000-$5FFF`. Title `"BASKETBALL"`, cartridge year `$004E`
(1978). Display: `$500E = $00` (colour-stack), border/colour-stack init
all zero/default -- copy `src/ui/text.asm`'s colour-stack variant.

- Timer table pointer: `$5002` -> `$5027`
- Start-of-game vector: `$5004` -> `$5043`

### Pass length / wall clock

Live headless dump (title-skip recipe: `b 14D5` / `r 10000000` /
`g 7 14D7` / `n 14D5` / `r 8000000`, then `m 100 10`):

```
0100:  0026  0011  0002  0003   0007  0000  0000  0000
```

`$0100=$0026`, `$0101=$0011` -- NOT the EXEC default ISR vector `$1126`
at this exact stop point, because the parked stop lands mid-title-screen
processing, not at a quiescent boot state; a second dump taken later
during idle boot-prompt parking confirmed `$0100`/`$0101` settle to
`$1126` once the title sequence finishes, i.e. this cart never installs
a custom ISR body -- none of §7.10/§7.27/§7.28's ISR-dance hazard
classes apply. **`$0102=$0002`, `$0103=$0003`** -- directly confirms the
family's standard `$0103=3` pass length (3 NTSC frames/pass, 20 Hz)
without needing to infer it from the timer table's interval words. The
wall tick rate should still be MEASURED live at `MASTER_TICK` once the
hook build exists (§7.28's own rule: don't trust arithmetic over a live
sample, even when there's no dance to explain a discrepancy) -- expected
result: exactly 3.000 frames / 44,802 cycles, matching Armor Battle's
and Golf's clean cadence, since nothing here touches `$0100`/`$0101`.

### Timer table -- 6 slots

```
.TIMER: ($5027)
  slot 0  $1A71  interval $8001  stopped   -- EXEC's own SFX tick (.EXEC.A71)
  slot 1  $5063  interval $0001  armed     -- primary game logic, 20 Hz
  slot 2  $51FF  interval $0009  stopped   -- game clock ($015F/$0160, BACKTAB $023D/$0240)
  slot 3  $5233  interval $0009  stopped   -- shot clock ($0161, BACKTAB $024D)
  slot 4  $5289  interval $0003  armed     -- object/animation walk
  slot 5  $5074  interval $8001  stopped   -- MOB0 field+7 toggle (ball blink)
```

Slot 0 already being the EXEC SFX entry is the standout finding: every
prior port (starting with Baseball) has had to ADD a stopped
`X_MUSIC_TICK`-placeholder row at slot 0 defensively, because
`.EXEC.831`'s note-duration re-arm computes its target countdown as
`$0125 + 0 = $0125` unconditionally -- table slot 0, always -- whenever a
note plays. This cart's own original table already puts the real EXEC
entry there, so `MASTER_TICK` slots in at slot 1 with NO insertion, and
the whole family's placeholder discussion (§7.35) is moot here: it's not
a placeholder, it's live.

Live dump of the real countdown cells at the same boot-prompt park
point (`m 120 10`), confirming every slot's countdown was seeded from
its header interval word, boot-state matching recon exactly:

```
0120:  0040  0000  0000  0000   0000  0001  0080  0001
0128:  0000  0009  0080  0009   0080  0003  0000  0001
```

`$0125/$0126=$01/$80` (slot 0, stopped), `$0127/$0128=$01/$00` (slot 1,
armed), `$0129/$012A=$09/$80` (slot 2, stopped), `$012B/$012C=$09/$80`
(slot 3, stopped), `$012D/$012E=$03/$00` (slot 4, armed) -- all six
match the header table's interval words with the stop-flag (hi byte
`$80`) tracking each slot's boot armed/stopped state. Slot 5's hi byte
(`$0130`) fell outside this particular 16-word window and wasn't
captured this session; recheck if a discrepancy ever shows up there.

Decision (see main plan / CLAUDE.md): **native dispatch for slots 2-5**
(§7.31, Boxing's proven shape), not full virtualization. `$17D5` cannot
reach slot 2's dispatch check until `MASTER_TICK` (slot 1) fully
returns, so a stall spinning inside `MASTER_TICK` freezes every later
native slot exactly as atomically as a virtualized one would. This
avoids ~4 sets of hand-rolled `ARM`/`CNT` countdown code and shim
call sites; the cost is a `SC_CNT` mirror of the 4 real countdowns
(`$0129-$0130`) into netcode RAM so they land in the CRC and the resync
image (native countdowns live in `$0100-$015C`, which §5.4 otherwise
treats as volatile EXEC scratch).

### RNG call sites -- 8

```
X_RAND1 ($167D): $5313, $56D3, $5A26
X_RAND2 ($169E): $52DF, $5B99, $5BA1, $5BD5, $5BFC
```

Fifth port needing both flavours (after Frog Bog, NASL Soccer, PGA
Golf). Each is the standard 3-word `JSR R5,target` form -- patch the two
operand words, not the opcode.

### Timer arm/stop call sites -- 6, a new addressing shape

```
$507D  SUBI #$0041,R1  -> J .EXEC.81E   (arm, from L_5079/L_5078)
$5083  SUBI #$0047,R1  -> J X_TIMER_STOP (from L_5081)
$508A  SUBI #$005A,R1  -> JSR X_TIMER_STOP (from L_5087)
$5091  SUBI #$005D,R1  -> J X_TIMER_STOP (from L_508F)
$5098  SUBI #$0068,R1  -> JSR X_TIMER_START (from L_5095)
$509E  SUBI #$006A,R1  -> JSR .EXEC.81E (from L_5095, second call)
```

Every prior port's timer-API call sites load `R1` via `SDBD / MVII
#addr,R1` -- an absolute operand recon.py's JSR-pattern scan finds
directly, and the fix is always retargeting that operand (or, when the
operand target moved out from under the relocated table, a shim,
Boxing's `BX_ARM_SHIM`/`BX_STOP_SHIM` pattern). This cart's `.START`
computes `R1` as `MOVR R7,R1` (current PC) followed by `SUBI #k,R1` --
i.e. "the address k words before wherever this JSR is" -- a
position-independent idiom, not a literal table address at all. None of
these six k values were decoded against absolute slot addresses this
session; that's next.

Working theory, to confirm once `hook.asm`/`patches.py` exist: since
slots 2-5 keep their ORIGINAL table position (native dispatch, no
insertion before them), and the EXEC's own `.EXEC.811` helper derives
the countdown cell as `$0125 + (R1 - table_base)/2` where `table_base`
is read fresh from the (now-relocated) header pointer, `R1`'s VALUE
after each `SUBI` needs to equal `NEW_TIMER_TBL + 4*slot` for the
existing dispatch math to land on the right cell. Because `R1` is
computed as `PC - k`, and neither the `.START` code's PC nor
`NEW_TIMER_TBL`'s address is fixed until the patch map exists, the
concrete plan is: patch the `SUBI` immediate at each site directly to
`(current PC value) - (NEW_TIMER_TBL + 4*slot)`, which keeps the
`MOVR R7,R1` unpatched (mechanical, unconditionally correct at runtime
since it reads whatever PC the JSR-relative code actually has) and only
needs one word changed per site -- simpler than a shim IF the live
`.EXEC.811` derivation confirms the theory. Fallback: Boxing's shim
pattern, unconditionally correct regardless of this derivation.

### Input surface

**Exactly one `$011F` reference**, the Armor Battle/Frog Bog hybrid
shape:

```
$544A  ANDI #$0001,R2        ; select seat 0 or 1
$544C  ADDI #$011F,R2        ; -> $011F + seat
$544F  MVI@  R2,R1           ; poll BOTH seats through the same site
```

No walking pointer, no `$0120`-relative terminator to worry about
(checked for §7.32's "correctly classified, still needs patching" trap
-- nothing found, this is a single `ANDI`/`ADDI` pair, not a loop).
Zero `$0120`-`$0124` references anywhere in the ROM.

### `$035D` / phase machine

Three installs:

```
$55C5  MVO R0,$035D   <- $1906 (EXEC null table -- input fully disabled)
$55D2  MVO R0,$035D   <- $55AF (data table, contents not decoded this session)
$5934  MVO R0,$035D   <- $58D6 (every entry routes to $59F1)
```

Live boot dump: `$035D = $58D6`, `$0163 = $00C2` at the parked prompt
(tip-off). No `$1910` number-entry reference anywhere (`grep` came back
empty) -- unlike Shark Shark, this cart has no player-count prompt to
answer at all, so nothing like `SS_INJECT` is needed. Frog Bog's
precedent applies directly: no Title-vector hook, the boot sequence
plays out through ordinary dispatch once `NET_START` sets `NET_COUNT`.

`$0163` is the flag/phase word:

- bit `$0080` -- P0 input enable, gated in `L_542D` (`ANDI
  #$0080,R0` / `BNEQ` skips input if SET -- so `$0080` set means
  DISABLED, active-low)
- bit `$0040` -- P1 input enable, gated in `L_543B` the same way
- `L_543B` also does `XORI #$0001,R2` -- the seat->team index can flip;
  confirm the physical-controller-to-on-screen-team mapping once the
  hook build is playable
- `L_55B9` sets BOTH disable bits (`XORI #$00C0,R0` against the low six
  bits) and installs the null table `$1906` -- this is the "no input at
  all" phase
- `L_55C9` CLEARS both bits (`ANDI #$003F,R0`, no XOR) and installs a
  PC-relative table -- this is "both seats live"

Planned quiescent point (§7.6): `$0163 & $00C0 == $00C0`. Planned
`QUIESCE=1` forcing target (§7.39): `$0163` directly -- unlike Shark
Shark's `SS_QUIESCENT`, this is a RAW cell written only at the ~15 phase-
transition call sites found by the `$0163` grep, not recomputed every
tick by anything on the `MASTER_TICK` path. Confirm this holds once
`SS_GAME_TICK`-equivalent logic is actually read in full; if some other
routine turns out to touch `$0163` unconditionally every tick, fall back
to forcing whatever raw cells that routine reads, per §7.39's general
rule.

### Display

Zero STIC writes: `recon.py` reported 6 hits (`$5211`, `$5252`, `$52C8`,
`$5350`, `$5906`, `$5CB9`), and every one is a §3 class-1 misaligned-
decode false positive -- `$5211`'s `$000F` is `INCR R7` (the tail of a
`PSHR R5 / JSR R5,L_5242 / INCR R7` sequence, not `MVO R2,$000F`); the
other five `$0004` hits are all the middle word of a 3-word `JSR R5,...`
whose target happens to decode as `MVO Rx,$0004` when read out of
alignment. Confirmed by disassembling from the real instruction boundary
in each case. Zero GRAM writes. The header-reassert display repair
(Baseball's shape, not Auto Racing's scroll-aware one) applies cleanly.

### Other hazard sweeps -- all clean

- `$14F1` (X_SCAN): zero references -> §7.26 does not apply.
- `$108F` EXEC-loop clone / SP reset: zero evidence. The one raw-grep
  hit for `MVII #$02F1` %-shaped code did not actually appear; a
  `MOVR R1,R6` at `$541A` looked superficially SP-adjacent in a blind
  grep but is mid-instruction data when disassembled from a known-good
  boundary (`L_540B`'s data block), not a real SP write. §7.15 does not
  apply.
- Direct non-JSR reads of `$0102`/`$0103`: zero. §7.36 does not apply.
- Literal `$0125`-`$0130` writes outside the timer API (Sea Battle's
  §7.30 hazard): zero found by grep.
- SFX call sites: `X_PLAY_SFX1` x3, `X_PLAY_CHEER1` x2, `X_PLAY_RAZZ4`
  x2, `X_PLAY_WHST1` x1 (8 total). Zero `$0149` reads anywhere -- the
  `X_SFX_OK` gate idiom (§7.8) is never used by this cart, so no game
  LOGIC branches on an SFX outcome. §7.21's sound-engine-churn class
  (state drift with no logic branch) remains possible in principle;
  watch for it if `make det` ever shows a residual outside the declared
  volatile range once that gate exists.

## M1 -- patches.py + hook.asm, native-dispatch confirmation

Wrote `tools/patches.py` (27 words: 4 header, 16 RNG, 1 shadow-ctrl, 6
timer-arm/stop immediates) and `src/hook.asm` (native dispatch for slots
2-5, per the plan). `make hook` assembles clean; `make verify-patch`
confirms exactly 27 declared words differ.

**The no-shim theory (spikes/NOTES.md M0's open item 1) is CONFIRMED**, by
tracing the EXEC's own `.EXEC.811` helper in the built EXEC disassembly:
it calls `X_READ_ROM_HDR` field 2 on every invocation (not a cached
boot-time copy), so `table_base` always resolves to whatever the header
CURRENTLY points at -- `NEW_TIMER_TBL` after our header patch. Since
slots 2/3/5 keep their original table position (only slot 1 is inserted),
`countdown_addr = $0125 + (R1 - NEW_TIMER_TBL)/2` lands on the correct
cell as long as `R1 = NEW_TIMER_TBL + 4*slot` at the call site -- which
is exactly what patching the `SUBI` immediate achieves, with the
`MOVR R7,R1` half left untouched. No shim needed, unlike every prior
native-dispatch port (Boxing, Sea Battle).

**Live boot-dump vs. recon-predicted state (§7.31's mandatory check, not
just a green gate)**: booted `build/basketball_hook.bin` with the same
title-skip + `r 8000000` recipe used for M0's baseline dump, at the
identical stop point:

```
$0102/$0103 = 0002/0003          (matches unpatched exactly)
$0125/$0126 = 0001/0080          slot 0, UNCHANGED             (matches)
$0127/$0128 = 0001/0000          slot 1 (MASTER_TICK), armed   (matches)
$0129/$012A = 0009/0080          slot 2, stopped               (matches)
$012B/$012C = 0009/0080          slot 3, stopped               (matches)
$012D       = 0002               slot 4 (unpatched: 0003)      1-tick drift
$012F       = 0001               slot 5, lo byte               (matches)
$0163       = 00C2               (matches unpatched EXACTLY)
$035D       = 58D6               (matches unpatched EXACTLY)
```

Every phase-machine cell that matters ($0163, $035D) and every native
slot's stop/arm state (slots 0/1/2/3) landed bit-for-bit identical to the
unpatched ROM at the same instruction-count stop. The one difference --
slot 4's countdown one tick further along -- is the artifact §7.17
warns about: the patched build executes MORE total instructions before
reaching this stop point (NET_START's netcode-RAM zero-fill loop runs
where the original had nothing), so a FIXED instruction-count stop
(`r 8000000`) naturally lands a hair later in real ticks, not evidence of
a targeting bug. Slot 4 correctly ARMED AND TICKING is itself further
confirmation the relocation works, not a red flag.

`GAME_TBL`/`$0163` state confirms the boot sequence reaches the identical
tip-off-parked state with no forced input at all, exactly like the
unpatched ROM -- there is nothing like Shark Shark's boot prompt here to
begin with (M0), so there was never a risk of parking differently.

## M2 -- determinism model: RNG seeding, real-frame leak, `make det` PASS

### RNG seeding: NET_START must never leave the canonical RNG at zero

First `make det` attempt hung: `TICK_LO` froze permanently (confirmed by
sampling `$8108` across five successive 20M-instruction continuations in
one debugger session -- identical every time, not just a slow run) while
cycles kept burning. Live single-step trace at the freeze point showed the
PC cycling through `X_RAND1`'s own body ($167D-$1699) and a game routine
at `$52DD`:

```
L_52DD: MVII #$0009,R0 / JSR X_RAND2 / CMPR R0,R1 / BEQ L_52DD
```

-- "keep re-rolling a 0-8 value until it differs from R1." `NET_START`'s
zero-fill leaves `RNG_LO`/`RNG_HI` at 0, and the wrapper's `@@swap_in`
writes that straight into `$035E` on the very first call. $035E's LFSR
is degenerate at all-zero (XOR-shift feedback of zero bits stays zero
forever), so `X_RAND2` returned the SAME value every single call --
`R0` never differed from `R1`, and this loop span forever. Fixed by
seeding `RNG_LO`/`RNG_HI` (and the `RNGP_LO`/`RNGP_HI` breadcrumb
baseline) to a fixed non-zero value in `NET_START`, Armor Battle's exact
precedent (`$34`/`$12`) -- confirmed by grep that Armor Battle's own
`NET_START` does this explicitly while Boxing's (dispatch-light, may
never hit a degenerate re-roll loop) does not.

**Generalize for future ports**: any cart with a "re-roll until it
differs" or similarly re-entrant RNG consumer needs its canonical RNG
mirror seeded non-zero at `NET_START` -- the zero-fill that's correct
for every OTHER cell is actively wrong for the RNG mirror specifically,
and the failure mode (a silent, instruction-burning hang under fuzz) does
not fail loudly; only a build-in-session hang tips it off.

### A new real-frame-leak shape: a latch derived from field+5, not SFX itself

With the hang fixed, `make det` completed but failed on 59 settled-state
cells (`$0163` etc.), and the ring showed 100% slot mismatch. Bisected by
building throwaway `main_det_a`/`b` copies with progressively smaller
`TRACE_STOP` values through `make` (never bare `as1600` -- see the
`[memattr]` trap below) until the exact first-divergent tick was pinned:
**tick 221**, one cell: `$016B` (`A=$0001 B=$0000`).

`w 16B` (jzIntv's write-watch) caught the writer live: `$561B`, gated on
`MVI G_0322,R0 / ANDI #$000F,R0 / CMPI #$0002,R0`. `$0322` is
`$031D+5` -- **MOB0's own field+5**, the real-frame-advanced animation
counter §7.19 already excludes from every state-compare tool in the
family. `$016B` is a ONE-SHOT LATCH derived from it (fires `L_585D` once
per animation cycle, then blocks re-firing until the counter cycles back
below 2), so it inherits field+5's real-frame non-determinism despite
living in ordinary game-scratch space ($015D-$01EF), not the object
table -- **a genuinely new hazard shape**: the family's existing
exclusion covers the SOURCE field, but nothing previously covered a
DERIVATIVE of it sitting outside the object table.

Excluding `$016B` alone (debug.asm `TRACE_RANGES`, lockstep.asm
`LS_CKSUM`, `tools/crc_trace_diff.py`'s settled-state check -- all three
split around it now) was NOT sufficient: with only that fix, the full
1024-tick run still failed with the same 59-cell signature. Tracing
`L_585D`'s body showed why: it is a two-instruction wrapper around
`JSR R5,L_5CED`, and `L_5CED` **is `X_PLAY_SFX1`** (a ball-bounce sound,
inline SFX data immediately following the call). This is PORTING.md
§7.21's exact "sound-engine-state-drift" shape -- not an unwrapped RNG
read (there is none at this site; confirmed no `$0149`/`X_SFX_OK` gate
anywhere, M0), but the EXEC sound engine's own envelope state
(`$0143-$0146`, outside the checksummed range) churning for real frames
after the trigger returns, with something downstream reading state that
has drifted as a result. Fixed exactly as §7.21 prescribes: retargeted
the `JSR R5,L_5CED` at `$5860` to `NB_SFX_SKIP` (a two-instruction
no-op stub, `tools/patches.py`/`src/hook.asm`), skipping the SFX trigger
unconditionally in every patched build while leaving `L_585D`'s own
latch-setting behaviour untouched.

**Result: `make det` now PASSES outright** -- 256/256 ticks identical,
settled-state identical, `check_dest_phase.py`'s destination-phase
assertion also passes (`GAME_TBL=$1906`, both MOB0/MOB1 populated, real
play reached). Unlike Frog Bog's own §7.21 case, this cart needed no
accepted residual: the one call site was the whole story. Patch map is
now 29 words (27 + 2 for the SFX-skip retarget).

**A live confirmation of PORTING.md §7.36's own operational trap,
mid-investigation**: an early bisection attempt built throwaway variants
with a raw `as1600` command and a hand-appended `.cfg`, using a shell
fallback (`echo "$CART_RAM_CFG" >> file || printf ...`) that assumed the
Makefile's exported `CART_RAM_CFG` variable would be visible outside
`make` -- it silently wasn't (an unset variable still `echo`s
successfully, so the `||` fallback never ran), leaving that one variant's
`.cfg` without the `[memattr]` RAM declaration. The symptom was
EXACTLY as documented: every cell read back as `$FFFF` (unmapped bus),
content-independent, indistinguishable from a real crash until compared
against a properly `make`-built sibling. Re-ran the whole bisection
through real `make <target>` invocations and the false lead vanished.

## M3 -- lagcheck: dedicated LAG_RING keyed to the shadow pair

`make lagcheck` passes cleanly on the first real run: **209/209 agreement
at shift=20** (a perfect peak -- cleaner than Shark Shark's own 120/209),
against a 60-61/209 baseline at shift=0 and the median. As predicted in
the M0 plan (and confirmed necessary by Shark Shark's own §7.38
precedent -- this cart shares the same "several always-armed native
timer entries" shape), the family's whole-`TRACE_RING`-checksum default
was never even attempted here; `debug.asm`'s `LAG_RING` capture was
wired directly to `SHADOW_CTRL`/`SHADOW_CTRL_R` from the start (§5, M1).
Unlike every prior port needing this fallback, no cart-specific
input-consuming cell had to be identified or guessed at all: the shadow
pair already IS the canonical direct echo, by construction, since it
exists purely as netcode infrastructure the cart's own `[$011F+seat]`
poll reads.

Along the way, rewrote `tools/check_dest_phase.py` -- it was still
Shark Shark's own version, keyed to that cart's boot-prompt injector
(`SS_INJECT`, `SS_HTBL_PROMPT`, `SS_PCOUNT`) which does not exist on this
cart at all (M0: no player-count prompt). New version checks `GAME_TBL`
against this cart's own three known handler tables
(`$58D6`/`$55AF`/`$1906`) and requires both MOB0/MOB1 populated -- the
part of the check that actually matters generalizes; the part that was
Shark-Shark-specific needed a real rewrite, not just a search-replace
(the old version happened to "pass" against basketball's dumps only by
coincidence, since `$1906` is a shared EXEC-owned address every port's
null table lands on).

## M4 -- resync wiring, wall tick rate, and a first real-rig finding

### Wall tick rate: measured, exactly 20.0 Hz as predicted

Two-point cycle sample at `MASTER_TICK` ($6054 in the hook build), eight
consecutive hits:

```
321198, 366000, 410802, 455440, 500325, 545127, 589929, 634648
```

Deltas cluster tightly around **44,802 cycles = 3.000 NTSC frames = 20.0
Hz** (a handful of samples land a few hundred cycles off, ordinary STIC
bus-contention variance, not a real irregularity) -- confirms §7.28's own
rule (measure, don't trust arithmetic) even though there was no ISR dance
to explain a discrepancy here: this is the family's cleanest possible
cadence, matching Armor Battle's and Golf's own measurement exactly.
`d=3` (the family/server default, already wired in
`server/intv_relay_server.py`'s `DEFAULT_DELAY`) costs exactly 150 ms of
input lag and jitter tolerance.

### `make rig` -- a real desync found and fixed on the first run

First `make rig PLAYERS=2` run: 4/24 CRC rounds mismatched. Two separate
issues surfaced, one cosmetic (test tooling) and one real:

1. **Tooling bug**: `test/run_rig.sh` (and `run_lobby.sh`) read `NET_COUNT`
   at the STALE Shark Shark address `$819D` -- but this port's own
   `ram.asm` moved `NET_COUNT` to `$819E` (Shark Shark's tail needed one
   fewer arm-flag/injector cell than this cart needs native-countdown
   mirror cells, M1). `count=128` in the verdict output was reading one
   of `SC_CNT8`'s mirror bytes, not the real seat count. Fixed both
   scripts' hardcoded addresses. Also fixed `run_rig.sh`'s embedded
   `GAME_TBL` acceptance list (still Shark Shark's `SS_HTBL_*` constants,
   same root cause as `check_dest_phase.py`'s M3 fix) to this cart's own
   `NB_HTBL_BOOT/LIVE/NULL`.
2. Real CRC mismatches are still under investigation with the corrected
   tooling -- see the open item below.

### `make rig` desync: five more §7.21 sites, found by CRC-log bisection

The first real `PLAYERS=2` rig run desynced: `server.log` showed **CRC ok
through tick 704 (12 clean rounds), then CRC MISMATCH starting at tick
768** and every round after that. An initial end-of-run memory-dump
comparison between the two consoles was a dead end -- the two consoles
were dumped at their OWN independent instruction-count park points
(`run_rig.sh`'s own convention), which land them at DIFFERENT sim ticks
(observed: tick 2049 vs 2052) purely from ordinary real-time login/
matchmaking jitter, not from a sim desync -- comparing raw state between
two different logical ticks is meaningless and produced a misleading
wall of differences. **The server's own CRC log, keyed by tick number,
was the right tool** -- it compares same-tick records regardless of when
either console happens to be dumped.

Clean-for-a-long-time-then-permanently-diverges (not diverging from
tick 0, and never re-converging) is the signature of a RARE EVENT
happening for the first time, not an ongoing structural bug -- roughly
matches "a scored basket finally happens after ~38s of pure disc-only
masked fuzz" (real coordinated scoring plays are much rarer under random
fuzz than under a real player). This pointed straight back at §7.21's
sound-engine-state-drift class (already found and fixed once at M2 for
the ball-bounce trigger) -- and at the 5 remaining SFX call sites never
exercised by `make det`'s scripted+fuzz coverage:
`X_PLAY_RAZZ4` (x2, $5257/$5264), `X_PLAY_CHEER1` (x2, $58E6/$5BA9 -- the
second one gated behind an RNG-rolled "did the crowd cheer" check right
after a scoring branch), `X_PLAY_WHST1` (x1, $5C4B, presumably a foul/
out-of-bounds whistle).

All five are ordinary 3-word `JSR R5,target` calls with normal CODE
(not inline SFX data) immediately following -- unlike the $5860 site
fixed at M2, so the SAME `NB_SFX_SKIP` no-op stub (just `MOVR R5,R7`)
is directly reusable: no data-skipping logic needed. Patched all five
(tools/patches.py, 10 more words, 29 -> 39 total). `make det` and `make
lagcheck` both still pass unchanged after the fix (confirms these sites
were never on the scripted/fuzz-covered path `make det` exercises,
consistent with the "first occurrence at tick ~750" timing).

**Left unpatched, a known gap**: the two remaining `X_PLAY_SFX1` sites
($5CFC, $5D19) ARE followed by inline SFX data (like the $5860 site),
so a plain-return stub would misinterpret the data words as code and
crash. Fixing these needs either decoding the SFX data format well
enough to compute each site's real skip length, or finding where
`X_PLAY_SFX1`'s own internal return-address computation lives and
reusing it. If a future `make rig` run desyncs again, these two are the
next suspects.

### Rerun after the 5-site fix: 12/12 -> 4/24 mismatches, decision to accept the residual

Rebuilt and reran `PLAYERS=2 make rig`: `crc_mismatches=4, crc_rounds=24`
-- a real, substantial improvement (100% -> 17% of rounds), confirming
the 5-site fix was correctly targeted, but not a full PASS.

Investigated whether the two remaining `X_PLAY_SFX1` sites ($5CFC,
$5D19) could be fixed the same cheap way. Traced the EXEC's own
`X_PLAY_SFX1` ($1BBB) in the built EXEC disassembly: it reads its first
data word via `MVI@ R5,R3` (auto-incrementing the CALLER's OWN return-
address register), calls into `.EXEC.A76`, which itself recurses through
`.EXEC.A83`/`.EXEC.A9A` -- and TWICE along that path does
`MVO R5,G_035F`, persisting the (still-advancing) data pointer to $035F
for the sound engine's own PER-TICK CONTINUATION. This is real,
multi-layered, stateful EXEC subsystem code, not a simple "read N words
then return" routine -- unlike the $5860 site (which called into a
LOCAL cart address, easy to bypass entirely), $1BBB is the SHARED EXEC
entry point every `X_PLAY_SFX1` call in the family routes through, so
patching ITS OWN code (rather than just the caller's JSR target) would
risk far more than these two call sites. `.EXEC.A9D`'s own tail
(`MVO R0,G_0149`) confirms the engine DOES touch the $0149 busy-flag
cell here too, but M0 already confirmed zero game-code reads of $0149
anywhere in this cart, so this remains purely §7.21's churn/drift class,
not §7.8's decision-gate class.

**Decision: accept this as a documented residual**, matching Auto
Racing's own shipped precedent (PORTING.md §7.21's closing paragraph):
"leaving this class of leak to the CRC+resync net rather than patching
every last call site" is the family's own sanctioned choice when (a) no
game logic branches on the SFX outcome and (b) the remaining call sites
require dissecting shared EXEC-internal state rather than a local
cart routine. Confirmed the CRC+resync mechanism is the actual safety
net for this residual by running `make m4` (see below) -- a mismatch
here gets DETECTED and REPAIRED like any other, not silently corrupting
the match. `test/run_rig.sh`'s own gate is left at the family's default
strict `mm == 0` bar (not loosened) so a future session revisiting this
still sees the honest state; this decision is documented here and in
CLAUDE.md/README.md instead.

## M5 -- resync recovery: `make m4` PASSES on the first real run

Plain (unforced) `make m4 PLAYERS=2`: the deliberate one-shot `$015F`
fault (game clock low byte, see `test/run_m4.sh`'s own header) was
injected on console 2, detected by the CRC exchange, and repaired --
**`recovered-after-fault=True`**, both consoles end with `active=1
dropped=0 hold=0`, all `DIAG` counters zero, `GAME_TBL=$55AF` (live
play) and both MOBs populated on both consoles. The host's resync fired
via `RS_GATE=1` (the QUIESCENT branch, not the `RS_PEND_MAX` cap) **within
1 tick of the fault landing** -- i.e., NB_PHASE's dead-ball condition
($0163 bits `$C0`) occurs naturally often enough in ordinary play that
the host didn't need to wait anywhere near the 60-tick cap. This is a
strong, unforced confirmation that the `$0163`-direct quiescent design
(§M0's plan, no derived-flag indirection needed unlike Shark Shark's
`SS_QUIESCENT`) works correctly in real two-console play, not just in
theory.

`QUIESCE=1 make m4 PLAYERS=2` also PASSES: **"QUIESCE run: the dead-ball
branch of RS_PENDING fired as intended"** -- the forced-branch test
(§7.29's requirement, since disc-only fuzz alone can't reliably reach
every branch) confirms `NB_PHASE`'s repeated-forcing loop (`e 163 C0`)
sticks correctly across the window, exactly as predicted back in M0:
unlike Shark Shark's `SS_QUIESCENT` (a derived flag `SS_GAME_TICK`
recomputed every tick, which took THREE investigative iterations to
root-cause why direct forcing couldn't work at all), `NB_PHASE` is a raw
cell nothing recomputes unconditionally on the per-tick path, so the
first attempt at forcing it directly worked. Both m4 variants needed the
SAME fault ($015F, one-shot AND immediate/reliable enough for both
modes) -- unlike Shark Shark, which needed two different faults for the
two modes (§7.39) -- because $015F's periodic-but-not-every-tick
rewrite by NB_TICK2 makes it both contained (plain mode) and, within the
wide QUIESCE forcing window, reliably caught (QUIESCE mode).

## M6 -- peer-left, both leave modes

`make peerleft PLAYERS=2 LEAVER=2 LEAVE_MODE=clean` **PASSES**: console 2's
emulator and its FujiNet instance are both killed at t+45s; the survivor's
BACKTAB decodes to the correct terminal screen (`PLAYER LEFT` / `GUEST06`
/ `PRESS RESET`), `PEER_SCR=1 PEER_WHY=1`, all `DIAG` counters zero. (The
FujiNet process's own segfault-on-kill in the log is the deliberate
process-termination step working as intended, not a bug.)

`make peerleft PLAYERS=2 LEAVER=2 LEAVE_MODE=timeout` -- see below.

## Open items (not blocking; carried forward)

1. Decode `$55AF`'s table contents (currently unknown -- installed by
   `L_55D2`) enough to confirm it's not a hazard class the family
   hasn't seen (it's the SECOND non-null `$035D` table besides `$58D6`;
   this port and Boxing only ever had one non-null table alongside the
   EXEC's null). Not a blocker: adopt-don't-restore treats `$035D`
   tables opaquely regardless of contents.
2. Live boot-dump the digit poked at the roster screen (session.asm's
   `STR_YOUARE`/digit-poke pair) once `NET_SEAT` exists, to confirm the
   team-number display matches the controller that's actually live.
3. Verify the controller<->on-screen-team mapping doesn't flip
   unexpectedly given `L_543B`'s XOR on bit 0 of `$0163`.
4. The two remaining `X_PLAY_SFX1` sites ($5CFC/$5D19) are a KNOWN,
   ACCEPTED residual (M4) -- if a future `make rig` run shows renewed
   mismatches beyond the ~17%-of-rounds baseline already measured, these
   are the next suspects; fixing them needs either decoding the SFX
   envelope data format well enough to compute each site's skip length,
   or finding a gate inside the EXEC's own sound engine ($1BBB's call
   tree) that can suppress playback without altering the data-parsing/
   return-address computation.
