; Netcode hook segment for NBA Basketball (Mattel 1978).
;
; STATUS: M0 recon complete (spikes/NOTES.md).  Header relocation, both RNG
; wrapper flavours (8 sites: 3x X_RAND1, 5x X_RAND2), the single hybrid
; polled-input site, and all six timer-arm/stop sites are the declared
; patch map (tools/patches.py).
;
; The cart header's timer-table pointer ($5002) is patched to NEW_TIMER_TBL:
;
;   slot 0  $1A71, interval $8001, stopped.  This is ALREADY the EXEC's own
;           SFX-tick entry (.EXEC.A71) in the CART'S OWN ORIGINAL table --
;           unlike every prior port, nothing has to be inserted here.  If
;           this cart ever calls into the EXEC note engine, the family's
;           usual defensive-placeholder concern (§7.35) is moot: slot 0 is
;           already live, not a placeholder guessing at future need.
;   slot 1  MASTER_TICK, interval 1, always armed -> countdown $0127/$0128.
;           Our master dispatcher, every pass.  Calls NB_TICK1 ($5063, the
;           ORIGINAL slot-1 target) directly -- nothing else in the
;           relocated table reaches it (PORTING.md §7.31).
;   slot 2  NB_TICK2 ($51FF), NATIVE -- unchanged target+interval (game clock).
;   slot 3  NB_TICK3 ($5233), NATIVE -- unchanged target+interval (shot clock).
;   slot 4  NB_TICK4 ($5289), NATIVE -- unchanged target+interval (anim walk).
;   slot 5  NB_TICK5 ($5074), NATIVE -- unchanged target+interval (ball blink).
;
; §7.31's native-dispatch shortcut applies to FOUR of five entries (Boxing's
; precedent): $17D5 cannot reach slot 2's dispatch check until MASTER_TICK
; (slot 1) fully returns, so a stall spinning inside MASTER_TICK freezes
; every later native slot exactly as atomically as a virtualized one would,
; with zero hand-rolled countdown code.  Slots 2/3/4/5 are ALL armed/stopped
; by cart code via the timer API (M0), so all four need a real-countdown
; mirror in the CRC/resync image (ram.asm's SC_CNT2-9, one more pair than
; Boxing's three native entries).
;
; The six timer-arm/stop sites are a shape no prior port has needed: every
; one computes its target as `MOVR R7,R1 / SUBI #k,R1` (current-PC-relative)
; rather than an absolute `MVII #addr,R1` operand, and because slots 2/3/5
; keep their ORIGINAL table position (only slot 1 is inserted), the EXEC's
; own `.EXEC.811` helper (which re-reads the header's CURRENT timer-table
; pointer on every call, traced live in the EXEC disassembly) keeps working
; unmodified as long as R1 still equals NEW_TIMER_TBL + 4*slot at the call
; site.  tools/patches.py therefore patches ONLY the SUBI immediate at each
; of the six sites -- no shim needed, unlike Boxing's NB_ARM_SHIM/
; NB_STOP_SHIM-shaped BX_ARM_SHIM/BX_STOP_SHIM (whose sites use a stale
; ABSOLUTE operand instead).
;
; No X_SCAN self-call hazard: zero references to $14F1 anywhere in the ROM
; (M0), so $035D only needs nulling AFTER the tick, not before as well
; (unlike NASL Soccer, PORTING.md §7.26).
;
; No cart ISR: this cart never writes $0100/$0101 (M0, confirmed live at
; every boot-dump point sampled) -- RS_CLAMP_ISR's clamp (resync.asm,
; unchanged) is a structural no-op here, same shape as Sea Battle/Golf.
;
; NBA Basketball is STRICTLY 2 SEATS, simultaneous, with NO player-count
; prompt at all (unlike Shark Shark's "SELECT 1 OR 2 PLAYERS" -- both
; teams are always live, gated only by the game's own NB_PHASE bits, M0).
; Input is HYBRID poll+dispatch (Armor Battle/Frog Bog's shape, not
; Boxing's dispatch-only shape): exactly ONE `$011F` reference in the whole
; ROM, `[$011F+seat]`, serving BOTH seats -- patched to SHADOW_CTRL, fed by
; UPDATE_SHADOW (local passthrough) and SHADOW_FROM_RINGS (both the local
; SPIKE_VIRT path AND lockstep.asm's LS_PASS -- PORTING.md §7.20's rule
; that a single-process determinism test cannot catch this call's absence
; from the SECOND path).  VD_CTRL tracks VD_SIDE on every dispatch call:
; the EXEC's own scan always hands handlers R1=seat via `SUBI #$011F,R1`
; before the $035D jump, so replaying that handoff faithfully is always
; safe regardless of whether this cart's own handlers happen to read it.

        ORG     $6000

NEW_TIMER_TBL:
        DECLE   $1A71 AND $FF, $1A71 SHR 8  ; EXEC's own SFX tick, UNCHANGED
        DECLE   $01, $80                    ; interval $8001, UNCHANGED
        DECLE   MASTER_TICK AND $FF, MASTER_TICK SHR 8
        DECLE   $01, $00                    ; every pass, always armed
        DECLE   NB_TICK2 AND $FF, NB_TICK2 SHR 8
        DECLE   NB_INT2, $00                ; original interval word, UNCHANGED
        DECLE   NB_TICK3 AND $FF, NB_TICK3 SHR 8
        DECLE   NB_INT3, $00                ; original interval word, UNCHANGED
        DECLE   NB_TICK4 AND $FF, NB_TICK4 SHR 8
        DECLE   NB_INT4, $00                ; original interval word, UNCHANGED
        DECLE   NB_TICK5 AND $FF, NB_TICK5 SHR 8
        DECLE   NB_INT5_LO, NB_INT5_HI      ; original interval word, UNCHANGED
        DECLE   $00, $00                    ; terminator

; Symbolic slot addresses (exec_equ.asm/tools/patches.py) -- must follow
; NEW_TIMER_TBL since as1600 requires a computable EQU expression at the
; point of definition.
NB_SLOT2        EQU     NEW_TIMER_TBL+8
NB_SLOT3        EQU     NEW_TIMER_TBL+12
NB_SLOT5        EQU     NEW_TIMER_TBL+20

; ---------------------------------------------------------------------------
; NET_START -- patched start-of-game vector ($5004, original target
; $5043=.START).  Runs after the title screen, before the EXEC main loop
; starts (the EXEC jumps here with R5 = $108F), so netcode RAM is
; initialized before the first MASTER_TICK.  Falls through to the original
; .START, which sets up the tip-off state.
;
; NB_TICK2-5's real countdowns need NO seeding here: the EXEC's own
; boot-time X_TIMER_INIT (run before .START, from the relocated header
; pointer) already copies NEW_TIMER_TBL's interval words into $0125-$0130,
; using the SAME words the original cart shipped with -- this is the whole
; benefit of leaving those entries native instead of virtualizing them.
; SC_CNT2-SC_CNT9's netcode-RAM mirror starts at NET_START's zero fill,
; which is harmless: MASTER_TICK's first tick refreshes it from the real
; cells before anything reads it.
; ---------------------------------------------------------------------------
NET_START:
        PSHR    R5                      ; EXEC main-loop return
        MVII    #NET_RAM, R4
        MVII    #NET_RAM_SIZE, R1
        CLRR    R0
@@zero: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@zero
        MVII    #SPIKE_DELAY, R0        ; virt-dispatch delay depth (spike knob)
        MVO     R0,     DELAY_EN
        ; Seat defaults for local builds: seat 0 of a 2-player game.  The
        ; netplay path overwrites both from the START payload.
        MVII    #2,     R0
        MVO     R0,     NET_COUNT
        ; Canonical game RNG seed -- MUST be non-zero.  $035E's LFSR is
        ; degenerate at an all-zero state (XOR-shift feedback of zero bits
        ; stays zero forever), and the zero-fill above leaves RNG_LO/HI at
        ; 0 by default.  This cart's own $52DD "re-roll until the value
        ; differs" loop hung forever the first time this was tried with a
        ; zero seed (spikes/NOTES.md M2) -- X_RAND2 kept returning the
        ; same value every call, so the CMPR/BEQ never took the exit
        ; branch.  Fixed for now so identical runs are identical by
        ; construction (Armor Battle's precedent); in netplay this comes
        ; from the START payload instead.
        MVII    #$34,   R0
        MVO     R0,     RNG_LO
        MVII    #$12,   R0
        MVO     R0,     RNG_HI
        MVII    #$34,   R0              ; prev-RNG breadcrumb baseline
        MVO     R0,     RNGP_LO
        MVII    #$12,   R0
        MVO     R0,     RNGP_HI
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_RING_INIT    ; idle-fill the dispatch rings
    ENDI
    IF SPIKE_ECHO <> 0
        JSR     R5,     ECHO_TEST       ; parks with results; never returns
    ENDI
    IF NET_SESSION <> 0
        JSR     R5,     SES_MAIN        ; login/lobby; arms NET_ACTIVE or not
    ENDI
        PULR    R5
        J       $5043

; NET_NULL_TBL: handed to the EXEC scan (via $035D) while dispatch is
; virtualized so its event dispatch resolves null pointers and never calls
; game code from real local input.  Zeros on both sides of the base cover
; negative slot indexes.
NET_NULL_TBL:
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        DECLE   0, 0, 0, 0, 0, 0, 0, 0, 0, 0

; ---------------------------------------------------------------------------
; MASTER_TICK -- timer entry 1 of NEW_TIMER_TBL, dispatched by the EXEC
; every main-loop pass.  May clobber R0-R3.  Returns via the dispatcher's
; R5.
; ---------------------------------------------------------------------------
MASTER_TICK:
        PSHR    R5
    IF STALL_N <> 0
        ; Stall injector (spike c): every 64th pass, busy-spin ~STALL_N
        ; frames INSIDE the dispatch.  The ISR keeps firing but $0102 sits
        ; at 0 mid-pass, so it takes its skip path: display continues,
        ; game logic freezes.
        MVI     FRM_CTR, R0
        INCR    R0
        ANDI    #$3F,   R0
        MVO     R0,     FRM_CTR
        BNEQ    @@no_stall
        DIS
        MVI     $102,   R2
        CLRR    R0
        MVO     R0,     $102
        EIS
        MVII    #STALL_N * 3000, R1     ; ~15 cycles/iter, ~1 frame per 1000
@@spin: DECR    R1
        BNEQ    @@spin
        DIS
        MVO     R2,     $102
        EIS
@@no_stall:
    ENDI
    IF NET_SESSION <> 0
        MVI     NET_ACTIVE, R0
        TSTR    R0
        BEQ     @@mt_local
        JSR     R5,     LS_PASS         ; lockstep netplay path
        PULR    R7
@@mt_local:
    ENDI
        JSR     R5,     UPDATE_SHADOW   ; local passthrough (feels stock)
    IF SPIKE_RECORD <> 0
        JSR     R5,     REC_CAPTURE     ; log the live cells for this tick
    ENDI
    IF SPIKE_VIRT <> 0
        ; Virtualized local dispatch.  BOTH seats replay, every tick: there
        ; is no turn arbiter on this cart -- both teams act simultaneously.
        JSR     R5,     VIRT_CAPTURE
        JSR     R5,     SHADOW_FROM_RINGS
        JSR     R5,     LS_TBL_ADOPT
        MVI     GAME_TBL_HI, R1
        SWAP    R1,     1
        ADD     GAME_TBL_LO, R1
        BEQ     @@mt_no_tbl
        MVO     R1,     $35D
@@mt_no_tbl:
        CLRR    R0
        MVO     R0,     VD_SIDE         ; seat 0
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
        MVII    #1,     R0
        MVO     R0,     VD_SIDE         ; seat 1
        MVO     R0,     VD_CTRL
        JSR     R5,     LS_VDISPATCH
    ENDI
        JSR     R5,     NB_GAME_TICK
    IF SPIKE_VIRT <> 0
        JSR     R5,     LS_TBL_ADOPT
        MVII    #NET_NULL_TBL+4, R0
        MVO     R0,     $35D
    ENDI
    IF SPIKE_TRACE <> 0
        JSR     R5,     TRACE_TICK
    ELSE
        ; sim tick counter (16-bit across two 8-bit cells)
        MVI     TICK_LO, R0
        INCR    R0
        MVO     R0,     TICK_LO
        CMPI    #$100,  R0
        BNEQ    @@mt_out
        MVI     TICK_HI, R0
        INCR    R0
        MVO     R0,     TICK_HI
    ENDI
@@mt_out:
        PULR    R7

; ---------------------------------------------------------------------------
; NB_GAME_TICK -- dispatches NB_TICK1 (the ORIGINAL slot-1 body, which
; nothing else in the relocated table reaches -- PORTING.md §7.31) and
; mirrors the four native, timer-API-stoppable countdowns (slots 2/3/4/5)
; into netcode RAM for LS_CKSUM.  Shared by MASTER_TICK's local path and
; lockstep.asm's LS_PASS (both paths need it -- Sea Battle's hard-won rule,
; PORTING.md: NET_ACTIVE returns via LS_PASS before MASTER_TICK's
; local-only section is ever reached, so anything computed only there goes
; stale under real netplay).  Slots 2/3/4/5 themselves fire NATIVELY, called
; by $17D5 immediately after MASTER_TICK returns -- nothing to do for them
; here beyond the mirror copy.
; Clobbers R0/R1.  Returns via the caller's R5.
; ---------------------------------------------------------------------------
NB_GAME_TICK:
        PSHR    R5
        JSR     R5,     NB_TICK1
        ; Mirror the four native countdowns into netcode RAM.
        MVI     $0129,  R0
        MVO     R0,     SC_CNT2
        MVI     $012A,  R0
        MVO     R0,     SC_CNT3
        MVI     $012B,  R0
        MVO     R0,     SC_CNT4
        MVI     $012C,  R0
        MVO     R0,     SC_CNT5
        MVI     $012D,  R0
        MVO     R0,     SC_CNT6
        MVI     $012E,  R0
        MVO     R0,     SC_CNT7
        MVI     $012F,  R0
        MVO     R0,     SC_CNT8
        MVI     $0130,  R0
        MVO     R0,     SC_CNT9
        PULR    R7

; ---------------------------------------------------------------------------
; NB_RAND1 / NB_RAND2 -- canonical-RNG wrappers for the game's eight RAND
; call sites (3x X_RAND1, 5x X_RAND2; M0, confirmed genuine JSR
; instructions via the linear scan AND cross-checked in dis1600).  The EXEC
; sound engine advances the shared LFSR at $035E from ISR context whenever
; noise SFX play (§5.2) -- and this cart plays plenty (whistle, cheer,
; razz) -- so game logic must not read $035E directly: swap the canonical
; (sim-space) value in, call the EXEC routine with interrupts off, swap the
; advanced value back out.
; Preserves R1/R2 like the underlying EXEC routines; result in R0.
; ---------------------------------------------------------------------------
NB_RAND1:
        PSHR    R5
        DIS
        JSR     R5,     @@swap_in
        JSR     R5,     X_RAND1
        B       @@swap_out

NB_RAND2:
        PSHR    R5
        DIS
        JSR     R5,     @@swap_in
        JSR     R5,     X_RAND2
@@swap_out:
        PSHR    R1
        MVI     EXEC_RNG, R1
        MVO     R1,     RNG_LO
        SWAP    R1,     1
        MVO     R1,     RNG_HI
        PULR    R1
        EIS
        PULR    R7

@@swap_in:
        PSHR    R1
        PSHR    R2
        MVI     RNG_HI, R1
        SWAP    R1,     1
        MVI     RNG_LO, R2
        ADDR    R2,     R1
        MVO     R1,     EXEC_RNG
        PULR    R2
        PULR    R1
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; UPDATE_SHADOW -- local passthrough feed for the polled shadow pair (the
; hybrid model, §5.3).  Runs unconditionally, every MASTER_TICK call (even
; when SPIKE_VIRT is off, so the plain hook build feels stock): mirrors the
; live EXEC-decoded cells straight into SHADOW_CTRL/SHADOW_CTRL_R.  Virt and
; lockstep modes overwrite the pair afterwards (SHADOW_FROM_RINGS).
; Clobbers R0.
; ---------------------------------------------------------------------------
UPDATE_SHADOW:
        MVI     EXEC_IN_L, R0
        MVO     R0,     SHADOW_CTRL
        MVI     EXEC_IN_R, R0
        MVO     R0,     SHADOW_CTRL_R
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; SHADOW_FROM_RINGS -- feed the polled shadow pair from the dispatch rings
; at the CURRENT tick (SEAT_RING + seat*$100, indexed by TICK_LO -- the
; SAME slot LS_VDISPATCH replays, absolute seat numbers, no host/guest
; swap needed: this cart's engine already tracks seat identity by number,
; not by role, on both consoles).  This is what makes the delayed/
; scripted/replayed polled stream agree with the dispatched event stream.
; With d = 0 the slot holds this tick's live capture, so hook and virt
; stay bit-identical (gate: make run-virt).
;
; PORTING.md §7.20: called from BOTH the local SPIKE_VIRT path (MASTER_TICK)
; and lockstep.asm's LS_PASS -- a single-process determinism test (make
; det/lag/virt) cannot distinguish "called from both paths" from "called
; from only one", because both sides of a local test share the same
; process's live cells regardless.  Only a real two-console `make rig` run
; can catch the omission.
; Clobbers R0/R1/R3.
; ---------------------------------------------------------------------------
SHADOW_FROM_RINGS:
        MVI     TICK_LO, R1
        MOVR    R1,     R3
        ADDI    #SEAT_RING, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL
        MOVR    R1,     R3
        ADDI    #SEAT_RING+$100, R3
        MVI@    R3,     R0
        MVO     R0,     SHADOW_CTRL_R
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; NB_SFX_SKIP -- retargeted from L_585D's call to the ball-bounce SFX
; trigger (originally `JSR R5,L_5CED` at $5860, L_5CED = X_PLAY_SFX1 +
; inline SFX data at $5CED).  M2's determinism investigation traced a real
; `make det` divergence to this exact site: it fires every time MOB0's
; real-frame-advanced animation counter ($0322 = field+5, already excluded
; from every state-compare tool per §7.19) passes through a specific
; phase, gated by the one-shot latch $016B (also excluded, since it's
; DERIVED from field+5's own non-determinism -- src/debug.asm
; TRACE_RANGES). Excluding $016B from the checksum was not enough by
; itself: the EXEC's sound engine keeps churning its own internal SFX
; envelope state ($0143-$0146, outside the checksummed range) for real
; frames after the trigger returns, and something downstream in game logic
; reads state that has drifted as a result -- PORTING.md §7.21's exact
; "sound-engine-state drift" shape, not an unwrapped RNG read (there is
; none at this site). A synchronous save/restore around the call does not
; fix this per §7.21's own finding, so the call is skipped entirely,
; unconditionally, in every patched build. L_585D's own latch-setting
; behaviour (MVII #$0001,R5 at $5617, run by its caller) is unaffected --
; only the actual SFX trigger is suppressed. Ball-bounce audio is lost in
; every build (including local, non-netplay hook builds); accepted as the
; family's standard tradeoff for this hazard class.
; ---------------------------------------------------------------------------
NB_SFX_SKIP:
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; NB_REBASE_HOOK -- called from resync.asm's RS_REBASE (one added line;
; resync.asm is otherwise unchanged) after a state image has been applied.
; Restores the four native countdowns from their just-applied SC_CNT*
; mirrors -- without this, a resync would silently desync the timer state
; this cart tracks outside the standard $015D-$01EF image range: the
; pushed image would look right in the mirror but the real dispatcher
; would keep running on its own unsynchronized countdown.
; Clobbers R0.
; ---------------------------------------------------------------------------
NB_REBASE_HOOK:
        MVI     SC_CNT2, R0
        MVO     R0,     $0129
        MVI     SC_CNT3, R0
        MVO     R0,     $012A
        MVI     SC_CNT4, R0
        MVO     R0,     $012B
        MVI     SC_CNT5, R0
        MVO     R0,     $012C
        MVI     SC_CNT6, R0
        MVO     R0,     $012D
        MVI     SC_CNT7, R0
        MVO     R0,     $012E
        MVI     SC_CNT8, R0
        MVO     R0,     $012F
        MVI     SC_CNT9, R0
        MVO     R0,     $0130
        MOVR    R5,     R7
