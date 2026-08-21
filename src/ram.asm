; Netcode RAM layout -- PiRTO II cart RAM, 8-bit cells.
; Declare only $8000-$9BFF in the cfg: $9C00-$9FFF is the FujiNet mailbox,
; and claiming it breaks jzIntv's --fujinet peripheral (AND-ed bus reads).
;
; IMPORTANT -- $8000-$807F is a STIC decode alias and must stay UNUSED:
; the STIC only partially decodes its address, so its control registers
; also respond at $4000, $8000 and $C000.  Nothing may live below $8080.
;
; Base layout is the family's byte-for-byte tail (proven across twelve
; prior ports; PORTING.md §7.16 says any layout change forces a full
; sweep), with two deliberate changes, both swept (resync.asm's
; RS_TAILTBL/IMG_TOTAL, debug.asm's TRACE_RANGES, this file -- all agree,
; see spikes/NOTES.md M1):
;   - SC_CNT2-SC_CNT9 (8 cells, was Boxing's 6-cell SC_CNT2-7): FOUR native
;     countdown pairs, not three -- this cart's slots 2/3/4/5 are all
;     timer-API-stoppable (M0), one more than Boxing's slots 2/3/4.
;   - NET_COUNT moves one cell to make room ($819D -> $819E); this cart
;     has no turn arbiter and no boot-prompt injector, so ARB_SEAT/SS_INJ
;     are dropped rather than relocated.
;
; This cart is STRICTLY 2 SEATS, simultaneous, HYBRID poll+dispatch input
; (M0: exactly ONE $011F reference, `[$011F+seat]`, serving BOTH seats --
; Armor Battle/Frog Bog's shape, not Boxing's dispatch-only shape) -- so,
; unlike Boxing/Shark Shark, there IS a shadow pair here: SHADOW_CTRL/
; SHADOW_CTRL_R, fed by UPDATE_SHADOW (local passthrough) and
; SHADOW_FROM_RINGS (under both the local SPIKE_VIRT path and LS_PASS --
; PORTING.md §7.20's hard-won rule: the ring-feed call must be in BOTH
; places, not just the local one, or a real two-console rig is the only
; thing that will ever catch its absence).

NET_RAM         EQU     $8080   ; base of netcode state (zeroed by NET_START)
NET_RAM_SIZE    EQU     $0180   ; $8080-$81FF zeroed at start

; --- Game timer state --------------------------------------------------
; Names kept canonical (SC_*) across the whole family so lockstep.asm and
; debug.asm -- copied UNCHANGED -- checksum this cart's timer state with
; zero edits (PORTING.md §4).
;
; Native dispatch (exec_equ.asm): slots 2/3/4/5 fire NATIVELY via the real
; $17D5 dispatcher.  SC_CNT2-SC_CNT9 are a per-tick MIRROR of their REAL
; countdowns ($0129-$0130) -- copied in EVERY tick (NB_GAME_TICK) so
; LS_CKSUM sees them, and copied BACK on a resync (NB_REBASE_HOOK, called
; from RS_REBASE) so a state push actually restores the live dispatcher's
; own pacing, not just a shadow copy of it.  Must stay physically
; CONTIGUOUS: LS_CKSUM's tail loop and debug.asm's TRACE_RANGES walk
; $8196-$819D as one auto-incremented range, by symbol name only at the
; two endpoints.
SC_CNT2         EQU     $8196   ; mirror of NB_TICK2's real countdown, lo
SC_CNT3         EQU     $8197   ; mirror of NB_TICK2's real countdown, hi
SC_CNT4         EQU     $8198   ; mirror of NB_TICK3's real countdown, lo
SC_CNT5         EQU     $8199   ; mirror of NB_TICK3's real countdown, hi
SC_CNT6         EQU     $819A   ; mirror of NB_TICK4's real countdown, lo
SC_CNT7         EQU     $819B   ; mirror of NB_TICK4's real countdown, hi
SC_CNT8         EQU     $819C   ; mirror of NB_TICK5's real countdown, lo
SC_CNT9         EQU     $819D   ; mirror of NB_TICK5's real countdown, hi
RS_SPARE0       EQU     $8102   ; ] always zero: kept only so the image tail
RS_SPARE        EQU     $8103   ; ] layout and every bounds constant stay
RS_SPARE1       EQU     $810F   ; ] exactly as the family proved them

DELAY_EN        EQU     $8105   ; virt-dispatch delay depth in game ticks
                                ;  (0 = same-tick dispatch, stock feel)
RNG_LO          EQU     $8106   ; canonical game RNG (mirrors $035E across
RNG_HI          EQU     $8107   ;  sim ticks) -- serves BOTH X_RAND1/X_RAND2
TICK_LO         EQU     $8108   ; 16-bit sim (game) tick counter
TICK_HI         EQU     $8109
SLF_LO          EQU     $810A   ; scripted-input PRNG state (spike c)
SLF_HI          EQU     $810B
FRM_CTR         EQU     $810C   ; frame counter for the stall injector
SCR_IDX         EQU     $810D   ; demo-script row offset ($FF = done -> fuzz)
SCR_CNT         EQU     $810E   ; ticks consumed in the current script row

; SHADOW_CTRL/SHADOW_CTRL_R -- the polled-input shadow pair (§5.3).  MUST
; be consecutive: the patched ADDI computes SHADOW_CTRL + seat directly
; (the same arithmetic the original code did against $011F), so the two
; cells are addressed by offset, not by two independent symbols.
SHADOW_CTRL     EQU     $8136   ; virtual $011F (seat 0 decoded input)
SHADOW_CTRL_R   EQU     $8137   ; virtual $0120 (seat 1 decoded input)

MB_DEV          EQU     $8114   ; mailbox transaction arguments
MB_CMD          EQU     $8115
MB_NPARAM       EQU     $8116
MB_TXLEN_LO     EQU     $8117
MB_TXLEN_HI     EQU     $8118
MB_OK           EQU     $8119   ; 1 = last transaction ACKed
MB_ERR          EQU     $811A   ; FN_ERR / status code (0 = timeout)
MB_PMAX_LO      EQU     $811B   ; worst-case ACKSEQ poll iterations seen
MB_PMAX_HI      EQU     $811C
NAVAIL_LO       EQU     $811D   ; NET_STATUS bytes-available
NAVAIL_HI       EQU     $811E
NREQ_LO         EQU     $8130   ; NET_READ/WRITE length argument
NREQ_HI         EQU     $8131
NGOT_LO         EQU     $8132   ; NET_READ actual byte count
NGOT_HI         EQU     $8133

FIRSTC_LO       EQU     $8110   ; (spike c) tick+1 of first game RNG use
FIRSTC_HI       EQU     $8111
RNGP_LO         EQU     $8112   ; (spike c) previous canonical RNG
RNGP_HI         EQU     $8113

RX_WR           EQU     $8134   ; net stream accumulator write index (mod 256)
RX_RD           EQU     $8135   ; read index
NAME_BUF        EQU     $8150   ; own player name, 8 cells + NUL
NAME_LEN        EQU     $8159
MENU_SEL        EQU     $815A   ; lobby cursor index
MENU_PREV       EQU     $815B   ; previous raw controller value (edge detect)
LOBBY_CNT       EQU     $815C   ; entries in LOBBY_CACHE
SES_TMR_LO      EQU     $815D   ; lobby refresh pacing counter
SES_TMR_HI      EQU     $815E
NET_SEAT        EQU     $8160   ; this console's seat, 0-1 (0 = host)
NET_DELAY       EQU     $8161   ; lockstep input delay d (game ticks)
NET_ACTIVE      EQU     $8162   ; 1 = lockstep netplay engaged
NET_DROPPED     EQU     $8163   ; 1 = peer gone / timeout
SES_STAT        EQU     $8166   ; session progress/error marker (UI/debug)
CRC_PH          EQU     $8167   ; crc send phase counter
LS_TMPB         EQU     $8168   ; lockstep scratch
LS_TMPB2        EQU     $8169
LS_FROZE        EQU     $816A   ; 1 = ISR phase counter currently frozen
LS_SAVE102      EQU     $816B   ; saved $0102 during a stall
LS_WAITC_LO     EQU     $816C   ; gate pump-round counter
LS_WAITC_HI     EQU     $816D
PP_TMP          EQU     $816E   ; pump scratch
SES_SAVE102     EQU     $816F   ; ISR phase counter saved across the session
RESYNC_HOLD     EQU     $8090   ; 1 = sim held for a state resync
RS_R_LO         EQU     $8091   ; agreed resume tick R
RS_R_HI         EQU     $8092
RS_TO_LO        EQU     $8093   ; hold timeout pump counter
RS_TO_HI        EQU     $8094
RS_TMP          EQU     $8095
RS_POS_LO       EQU     $8096   ; serializer/applier image position
RS_POS_HI       EQU     $8097
RS_TMP2         EQU     $8098
GAME_TBL_LO     EQU     $80C0   ; game's live input-handler table ($035D),
GAME_TBL_HI     EQU     $80C1   ;  captured around each game tick.  THREE
                                ;  static cart-side installs (exec_equ.asm)
                                ;  -- adopt-don't-restore applies as usual
                                ;  (§5.3), though this cart's own tables
                                ;  don't change GAME_TBL's identity within
                                ;  a tick the way a boot-prompt cart's do.
VD_TMP          EQU     $80C2   ; virtual dispatcher scratch
VD_SIDE         EQU     $80C3   ; SEAT whose ring the dispatcher reads (0-1)
VD_CUR          EQU     $80C4
VD_PREV         EQU     $80C5
VD_KP           EQU     $80C6
VD_KPPRE        EQU     $80C7

; --- 2-seat state ------------------------------------------------------
NET_COUNT       EQU     $819E   ; players this match, always 2 (no player-
                                ;  count prompt on this cart at all, M0)
SEAT_WM         EQU     $81A0   ; 2 x [wm_lo, wm_hi] per-seat remote input
                                ;  watermarks ($81A0-$81A3); own seat
                                ;  unused; $81A4-$81A7 unused (family
                                ;  layout supports up to 4 seats, this
                                ;  cart only ever uses 2)
VD_CTRL         EQU     $81A8   ; controller index passed to handlers in R1
                                ;  -- the EXEC's own dispatch always hands
                                ;  handlers R1=seat via SUBI #$011F,R1; set
                                ;  to match VD_SIDE on every dispatch call,
                                ;  both seats every tick, so replay
                                ;  reproduces that handoff exactly
                                ;  regardless of whether this cart's own
                                ;  $035D handlers happen to read it.
ROOM_CNT        EQU     $81AA   ; pre-match waiting-room member count
                                ;  (0/1 = browsing the lobby, 2 = in a
                                ;  forming room)
ROOM_HOST       EQU     $81AB   ; 1 = we are roster slot 0 (ENTER sends GO)
LEFT_SEAT       EQU     $81AC   ; seat of whoever ended the match (PEER_LEFT)
SC_ISR_SAVE     EQU     $81AD   ; harmless spare pair (exec_equ.asm): this
                                ;  cart has no cart ISR to clamp -- Sea
                                ;  Battle's/Golf's own no-dance precedent.
                                ;  $81AD-$81AE.
LEFT_NAME       EQU     $81B0   ; leaver's name for the terminal screen (8+NUL)
NAME_TBL        EQU     $81C0   ; 4 x 9 (name8 + NUL), seat-ordered roster
                                ;  from the START payload ($81C0-$81E3) --
                                ;  ROSTER_SLOTS stays 4, a wire-protocol
                                ;  constant shared with every port, not a
                                ;  capacity (only slots 0-1 are ever live
                                ;  here)

; Field diagnostics.  A live session over real hardware leaves no log, so
; these saturating counters are the only evidence an incident produces --
; dump them with `m 8180 4` after a bad game.
DIAG_SLIP       EQU     $8180   ; parser resyncs (byte stream had slipped)
DIAG_REJ        EQU     $8181   ; STATE chunks refused by the resync guards
DIAG_TMO        EQU     $8182   ; mailbox transactions that timed out
DIAG_ERR        EQU     $8183   ; mailbox transactions that replied an error

UI_COLOR        EQU     $818B   ; current text colour, palette index 0-15
                                ;  (UI_CLS resets it to white)

; Live performance HUD (NET_HUD builds only -- see src/netcode/hud.asm).
HUD_PLL         EQU     $8190   ; mailbox poll iterations this window, 16-bit
HUD_PLH         EQU     $8191   ;  (the high cell is what gets displayed)
HUD_STL         EQU     $8192   ; gate stall rounds this window (saturating)
HUD_HLD         EQU     $8193   ; resync-hold pump rounds this window
HUD_LEAD        EQU     $8194   ; smallest (remote watermark - tick) seen, 0-15
HUD_RSY         EQU     $8195   ; resyncs completed since the session started

RS_PEND         EQU     $8187   ; 1 = resync wanted, waiting for quiescent point
RS_PTMO         EQU     $8188   ; game ticks waited so far
RS_WAITED       EQU     $8189   ; ticks the last resync waited (diagnostic)
RS_GATE         EQU     $818A   ; why the last push fired: 1 = quiescent, 2 = cap

PEER_SCR        EQU     $8185   ; 1 = peer-left screen up, sim stopped for good
PEER_WHY        EQU     $8186   ; 1 = server said PEER_LEFT, 0 = we timed out

RXACC           EQU     $8200   ; 256-byte circular net stream accumulator
FRMBUF          EQU     $8300   ; current frame, linear (len,type,payload)
LOBBY_CACHE     EQU     $8380   ; last LOBBY payload (count + 9/entry)

; --- Per-seat input rings (one 256-cell page per seat) ---------------------
; Decoded-input rings: SEAT_RING + seat*$100, $8400-$87FF.
; Keypad-cell rings:   SEAT_KP   + seat*$100, $8800-$8BFF.
; LS_RING_INIT idle-fills all pages (decoded $40, keypad 0).  Only seats
; 0-1 are ever live on this cart, but the family-standard 4-page layout
; is kept for consistency (harmless, matches every sibling port).
SEAT_RING       EQU     $8400
SEAT_KP         EQU     $8800

OWN_CRC         EQU     $8C00   ; 8 x [tick_lo, tick_hi, crc_lo, crc_hi]

TRACE_RING      EQU     $9000   ; 256 x 2-byte per-tick state checksums

; LAG_RING: 256 x 2-word per-tick raw capture of the direct input echo used
; by `make lagcheck` (SPIKE_TRACE builds only, written by debug.asm's
; TRACE_TICK alongside the checksum ring) -- see src/hook.asm/debug.asm for
; which cell this cart tracks; NOT used by `make det`'s determinism proof
; (that uses TRACE_RING's whole-state checksum, unaffected).
LAG_RING        EQU     $9200   ; $9200-$93FF (256 x 2 words)

; SC_PHASE/SC_PHASE_DEAD: the resync-gate predicate resync.asm's RS_PENDING
; reads.  UNLIKE every native-dispatch predecessor, this needs no derived
; netcode-RAM flag at all: NB_PHASE ($0163, exec_equ.asm) is ALREADY a raw
; cart cell inside the standard CRC range, written only at phase-transition
; call sites (M0), so SC_PHASE aliases directly onto it.  RS_PENDING's
; generic ANDI/BNEQ (any bit set) is NOT what this cart needs -- BOTH $80
; and $40 must be set (dead ball, both seats' input disabled), so
; resync.asm carries ONE added line here (CMPI instead of a bare BNEQ),
; the same kind of minimal deviation PORTING.md §4 documents for Sea
; Battle's REBASE_HOOK.
SC_PHASE        EQU     NB_PHASE
SC_PHASE_DEAD   EQU     $C0
