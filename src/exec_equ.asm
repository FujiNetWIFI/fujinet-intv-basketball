; EXEC ROM entry points and RAM locations used by the netcode patch.
; Addresses are the shared EXEC's (identical across every port so far --
; confirmed for this cart in build/basketball.dis, spikes/NOTES.md M0).

X_RAND1         EQU     $167D   ; LFSR random entry, flavour 1 -- 3 sites
                                ;  ($5313, $56D3, $5A26, M0)
X_RAND2         EQU     $169E   ; LFSR random entry, flavour 2 -- 5 sites
                                ;  ($52DF, $5B99, $5BA1, $5BD5, $5BFC, M0)

EXEC_RNG        EQU     $035E   ; 16-bit LFSR state (System RAM)
EXEC_ISR_DEF    EQU     $1126   ; the EXEC's default game-time ISR --
                                ;  this cart never installs its own (M0:
                                ;  $0100/$0101 read $1126 live at every
                                ;  boot-dump point sampled), so
                                ;  RS_CLAMP_ISR's clamp is a structural
                                ;  no-op here, kept anyway for the family's
                                ;  standard defensive insurance

; EXEC decoded per-controller input cells, rewritten by the scan each pass.
EXEC_IN_L       EQU     $011F   ; left controller decoded input -- the
                                ;  ONLY $011F reference in the ROM ($544C
                                ;  ADDI #$011F,R2) serves BOTH seats via
                                ;  [$011F + seat] (Armor Battle/Frog Bog's
                                ;  hybrid shape) -- patched to SHADOW_CTRL
EXEC_IN_R       EQU     $0120   ; right controller decoded input (never
                                ;  read directly by the cart -- reached
                                ;  only via [$011F+1] -- but still the
                                ;  correct address for VIRT_CAPTURE's
                                ;  generic live-pad feed, and SHADOW_CTRL+1
                                ;  must land here symbolically)
EXEC_KP_L       EQU     $0121   ; left keypad event/state cell (vdispatch.asm
EXEC_KP_R       EQU     $0122   ;  references these unconditionally --
                                ;  engine-shaped only; zero references
                                ;  anywhere in this cart, M0)
EXEC_HTBL       EQU     $035D   ; input-handler table pointer (game-managed)
EXEC_RAW_L      EQU     $0123   ; left controller raw (inverted port) value
EXEC_RAW_R      EQU     $0124   ; (zero references either, M0 -- no raw-
                                ;  latch shadow pair needed, unlike Armor
                                ;  Battle's tank-rotation logic)

; SC_ISR_SAVE: RS_CLAMP_ISR (src/netcode/resync.asm, copied unchanged) runs
; unconditionally from RS_REBASE.  This cart has NO real ISR-vector save/
; restore of its own (M0: no $0100/$0101 writes anywhere), so unlike Shark
; Shark/Boxing/Soccer this alias is a harmless spare cell, not load-bearing
; state -- the family's standard shape for a cart with no ISR dance (Sea
; Battle's/Golf's own precedent).  Defined in ram.asm ($81AD/$81AE, a
; netcode-RAM spare pair, never written by the cart).

; DANCE_SETTLE (src/vdispatch.asm, copied unchanged) unconditionally checks
; $0101 against SC_ISR_BODY's page before repainting a terminal screen --
; PORTING.md §7.10.  This cart never installs a custom ISR body (M0), so
; $0101 never reads anything but the EXEC default's high byte ($11) --
; SC_ISR_BODY's own high byte must differ from that so the check resolves
; immediately (BNEQ taken on the first sample) instead of spinning the
; full wait every call.  Sea Battle's/Golf's own no-dance precedent.
SC_ISR_BODY     EQU     $0000

; ---------------------------------------------------------------------------
; Timer table -- 6 slots at $5027 (header pointer $5002), FOUR words each
; (target lo/hi, interval lo/hi).  Slot 0 is ALREADY the EXEC's own SFX
; entry (unlike every prior port, which had to ADD a defensive placeholder
; there) -- MASTER_TICK goes in slot 1, replacing the original $5063.
; Slots 2-5 dispatch NATIVELY (PORTING.md §7.31): $17D5 cannot reach slot 2
; until MASTER_TICK (slot 1) fully returns, so a stall spinning inside
; MASTER_TICK freezes every later native slot exactly as atomically as
; virtualization would, at a fraction of the code.
; ---------------------------------------------------------------------------
NB_TICK1        EQU     $5063   ; slot 1 ORIGINAL target -- primary game
                                ;  logic, 20 Hz: input dispatch (both
                                ;  seats), ball/player motion.  Nothing
                                ;  else in the relocated table reaches
                                ;  this address (§7.31's own trap)
NB_TICK2        EQU     $51FF   ; slot 2, interval $0009 (2.22 Hz): game
                                ;  clock, prints at BACKTAB $023D
NB_TICK3        EQU     $5233   ; slot 3, interval $0009 (2.22 Hz): shot
                                ;  clock, prints at BACKTAB $024D
NB_TICK4        EQU     $5289   ; slot 4, interval $0003 (6.66 Hz):
                                ;  object/animation walk
NB_TICK5        EQU     $5074   ; slot 5, interval $8001 (stopped/one-
                                ;  shot): MOB0 field+7 toggle (ball blink)

; Original entry intervals, UNCHANGED in the relocated table -- native
; dispatch needs no countdown seeding of its own: the EXEC's own boot-time
; X_TIMER_INIT copies these words into $0125-$0130 from whatever the header
; points at, exactly as it always did.
NB_INT2         EQU     $09
NB_INT3         EQU     $09
NB_INT4         EQU     $03
NB_INT5_LO      EQU     $01     ; slot 5's interval is $8001 (stopped) --
NB_INT5_HI      EQU     $80     ;  both bytes needed since the high byte
                                ;  carries the stop flag

; Game-state cells (all inside $015D-$01EF, the block .START zero-fills =
; the engine CRC range).
NB_PHASE        EQU     $0163   ; seat/phase flag word.  bit $80 = P0
                                ;  input disabled (L_542D), bit $40 = P1
                                ;  input disabled (L_543B), active-low --
                                ;  BOTH set ($C0) is dead-ball/tip-off,
                                ;  the planned resync quiescent point
                                ;  (§7.6).  L_543B also XORs bit 0
                                ;  (seat<->team mapping) -- verify on
                                ;  screen once playable.  Written only at
                                ;  ~15 phase-transition call sites, never
                                ;  recomputed per-tick the way Shark
                                ;  Shark's SS_QUIESCENT was (§7.39's
                                ;  opposite case) -- confirm this holds
                                ;  before trusting a QUIESCE=1 direct force.
