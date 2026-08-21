; Desync detection + recovery resync (M4).
;
; NOTE: this file is copied from the Shark Shark tree per PORTING.md §4's
; "copy unchanged" list, with TWO deliberate deviations, both documented
; where they occur: (1) RS_REBASE calls NB_REBASE_HOOK (src/hook.asm,
; renamed from Shark Shark's SS_REBASE_HOOK) to restore the four native
; countdown mirrors after a state apply; (2) RS_PENDING's quiescent test
; is a CMPI-equality check, not the family's default ANDI/BNEQ any-bit
; test, because this cart's dead-ball condition needs BOTH phase bits set,
; not just one (see RS_PENDING below).  Like every no-cart-ISR port
; (Sea Battle, Golf), RS_CLAMP_ISR here is a structural no-op: this cart
; never installs a custom ISR (M0), so SC_ISR_SAVE aliases a harmless
; netcode-RAM spare, not real transported state.
;
; Both consoles CRC their ISR-clean game state every 64 ticks (LS_CKSUM) and
; send it; the relay forwards it to the peer.  Each console compares the
; peer's CRC against its own record for the same tick.  On mismatch:
;   guest: sends RESYNC_REQ once and keeps playing
;   host:  waits for a quiescent moment (RS_PENDING), then enters HOLD,
;          pushes the full game-state image + resume tick R; both
;          re-baseline (tick := R, rings idle, watermark R+d-1)
; The sim is frozen during HOLD exactly like a network stall ($0102 frozen
; by LS_PASS), so the pushed snapshot is stable and both sides resume from
; identical state.  The push is gated on a quiescent point so the swap is
; not visible -- see RS_PENDING for the marker and the cap on waiting.
;
; State image (767 bytes, positions 0..766):
;   0..146    $015D-$01EF game scratch (bytes; the whole game state --
;             the phase/seat flag word NB_PHASE ($0163), MOB records are
;             OUTSIDE this range, see below)
;   147..626  $0200-$02EF BACKTAB (240 words, LE byte pairs -- the screen,
;             travels for free)
;   627..754  $031D-$035C object table (64 words, LE byte pairs; both
;             teams' MOB records, $031D-base and $0325-base.  This cart
;             keeps no cart globals above the stack base, matching
;             every prior port's own census)
;   755..766  RNG_LO/HI, SC_CNT2-9 (the four native, timer-API-stoppable
;             entries' real countdown mirrors -- M0), GAME_TBL_LO/HI. 12
;             bytes -- two SHORTER than the family's traditional 14-byte
;             tail (Boxing's own, with three native entries): one more
;             native pair (8 vs Boxing's 6) but no turn-arbiter/injector
;             cell, which every simultaneous-2-seat predecessor still
;             carried. PORTING.md §7.16 sweep done: IMG_S1/S2/S3
;             unchanged, only IMG_TOTAL moves.  No RS_SPARE padding
;             needed in the tail: every cell here carries real state.
; STATE chunk frame: [len][08][pos_lo][pos_hi][data...]; pos_hi = $FF marks
; control: pos_lo 0 = BEGIN (payload R_lo,R_hi), 1 = END.
; (PORTING.md 7.16: any change to the IMG_* constants above requires a
; sweep of every numeric bound in the applier and pusher.  Unswept here:
; the applier's quick guard is pos_hi < 4 [loose, wrap prevention only] and
; the exact bound is symbolic IMG_TOTAL; the pusher is symbolic throughout;
; SES_FLEN's STATE max stays 99.)

IMG_S1          EQU     147
IMG_S2          EQU     627
IMG_S3          EQU     755
IMG_TOTAL       EQU     767
RS_CHUNK        EQU     96
RS_HOLD_TMO     EQU     $0600           ; hold pump rounds before giving up

; ---------------------------------------------------------------------------
; RS_RECORD_CRC -- record own (tick, crc) for later peer comparison.
; Reads the crc from LS_TMPB/LS_TMPB2 (already staged by the send path).
; ---------------------------------------------------------------------------
RS_RECORD_CRC:
        PSHR    R5
        MVI     TICK_LO, R1
        SLR     R1,     2
        SLR     R1,     2
        SLR     R1,     2               ; tick >> 6
        ANDI    #7,     R1
        SLL     R1,     2               ; * 4
        ADDI    #OWN_CRC, R1
        MOVR    R1,     R4
        MVI     TICK_LO, R0
        MVO@    R0,     R4
        MVI     TICK_HI, R0
        MVO@    R0,     R4
        MVI     LS_TMPB, R0
        MVO@    R0,     R4
        MVI     LS_TMPB2, R0
        MVO@    R0,     R4
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ON_CRC -- a peer's CRC frame in FRMBUF (v2: +2 seat, +3/+4 tick,
; +5/+6 crc).  The sender's seat doesn't matter for the comparison: any
; room member whose CRC disagrees with our record for that tick means the
; room has diverged, and the recovery is always a host push + all-rebase.
; ---------------------------------------------------------------------------
RS_ON_CRC:
        PSHR    R5
        MVI     FRMBUF, R0
        CMPI    #6,     R0
        BLT     @@rc_out                ; short frame: +2..+6 would be stale
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rc_out                ; already recovering
        MVI     RS_PEND, R0
        TSTR    R0
        BNEQ    @@rc_out                ; resync already pending
        MVI     FRMBUF+3, R1
        SLR     R1,     2
        SLR     R1,     2
        SLR     R1,     2
        ANDI    #7,     R1
        SLL     R1,     2
        ADDI    #OWN_CRC, R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        CMP     FRMBUF+3, R0
        BNEQ    @@rc_out                ; no record for that tick yet
        MVI@    R4,     R0
        CMP     FRMBUF+4, R0
        BNEQ    @@rc_out
        MVI@    R4,     R0
        CMP     FRMBUF+5, R0
        BNEQ    @@rc_bad
        MVI@    R4,     R0
        CMP     FRMBUF+6, R0
        BEQ     @@rc_out                ; CRCs agree
@@rc_bad:
        ; Mark the resync wanted, but do not act on it here.  Pushing the
        ; instant a CRC disagrees lands the state image mid-play and the ball
        ; and fielders visibly teleport; RS_PENDING holds the push until the
        ; game is ball-dead.  The guest simply keeps playing until the host's
        ; BEGIN arrives -- it must NOT freeze here, or it would sit still
        ; through the very play we are waiting to finish.
        MVII    #1,     R0
        MVO     R0,     RS_PEND
        CLRR    R0
        MVO     R0,     RS_PTMO
        MVI     NET_SEAT, R0
        TSTR    R0
        BEQ     @@rc_out                ; host: RS_PENDING drives the push
        ; guest: ask the host for one, once (the relay fans it out; only
        ; the host acts on it)
        MVII    #FN_TX, R5
        MVII    #3,     R0
        MVO@    R0,     R5
        MVII    #FT_RESYNC, R0
        MVO@    R0,     R5
        MVI     FRMBUF+3, R0
        MVO@    R0,     R5
        MVI     FRMBUF+4, R0
        MVO@    R0,     R5
        MVII    #4,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
@@rc_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ON_REQ -- guest asked for a push (host only, once).
; ---------------------------------------------------------------------------
RS_ON_REQ:
        PSHR    R5
        MVI     NET_SEAT, R0
        TSTR    R0
        BNEQ    @@rq_out
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rq_out
        MVI     RS_PEND, R0
        TSTR    R0
        BNEQ    @@rq_out                ; already pending
        MVII    #1,     R0
        MVO     R0,     RS_PEND
        CLRR    R0
        MVO     R0,     RS_PTMO
@@rq_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_PUSH -- host: hold, BEGIN(R), image chunks, END, re-baseline.
; ---------------------------------------------------------------------------
RS_PUSH:
        PSHR    R5
        JSR     R5,     RS_ENTER_HOLD
        ; R = current tick + 16
        MVI     TICK_HI, R1
        SWAP    R1,     1
        ADD     TICK_LO, R1
        ADDI    #16,    R1
        MVO     R1,     RS_R_LO
        SWAP    R1,     1
        MVO     R1,     RS_R_HI
        ; BEGIN frame
        MVII    #FN_TX, R3
        MVII    #5,     R0
        JSR     R5,     RS_PUTB
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        CLRR    R0
        JSR     R5,     RS_PUTB         ; pos_lo = 0 -> BEGIN
        MVII    #$FF,   R0
        JSR     R5,     RS_PUTB
        MVI     RS_R_LO, R0
        JSR     R5,     RS_PUTB
        MVI     RS_R_HI, R0
        JSR     R5,     RS_PUTB
        MVII    #6,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        ; image chunks
        CLRR    R0
        MVO     R0,     RS_POS_LO
        MVO     R0,     RS_POS_HI
@@ps_chunk:
        MVI     RS_POS_HI, R2
        SWAP    R2,     1
        ADD     RS_POS_LO, R2           ; R2 = pos
        MVII    #IMG_TOTAL, R1
        SUBR    R2,     R1              ; remaining
        BEQ     @@ps_end
        CMPI    #RS_CHUNK, R1
        BLT     @@ps_n
        MVII    #RS_CHUNK, R1
@@ps_n: MVO     R1,     RS_TMP2         ; n (chunk payload bytes)
        MVO     R1,     LS_TMPB         ; copy for NREQ later
        MVII    #FN_TX, R3
        MOVR    R1,     R0
        ADDI    #3,     R0
        JSR     R5,     RS_PUTB         ; len = n + 3
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        MOVR    R2,     R0
        JSR     R5,     RS_PUTB         ; pos_lo
        MOVR    R2,     R0
        SWAP    R0,     1
        JSR     R5,     RS_PUTB         ; pos_hi
@@ps_pl:
        MOVR    R2,     R1
        JSR     R5,     IMG_GET         ; R0 = image[pos]; preserves R2,R3
        JSR     R5,     RS_PUTB
        INCR    R2
        MVI     RS_TMP2, R0
        DECR    R0
        MVO     R0,     RS_TMP2
        BNEQ    @@ps_pl
        MVO     R2,     RS_POS_LO
        SWAP    R2,     1
        MVO     R2,     RS_POS_HI
        MVI     LS_TMPB, R0
        ADDI    #4,     R0              ; frame bytes = len byte + len
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        B       @@ps_chunk
@@ps_end:
        ; END frame
        MVII    #FN_TX, R3
        MVII    #3,     R0
        JSR     R5,     RS_PUTB
        MVII    #FT_STATE, R0
        JSR     R5,     RS_PUTB
        MVII    #1,     R0
        JSR     R5,     RS_PUTB         ; pos_lo = 1 -> END
        MVII    #$FF,   R0
        JSR     R5,     RS_PUTB
        MVII    #4,     R0
        MVO     R0,     NREQ_LO
        CLRR    R0
        MVO     R0,     NREQ_HI
        JSR     R5,     NET_WRITE
        JSR     R5,     RS_REBASE
        PULR    R7

; RS_PUTB -- append R0 to the TX frame at R3 (manual increment).
RS_PUTB:
        MVO@    R0,     R3
        INCR    R3
        MOVR    R5,     R7

; ---------------------------------------------------------------------------
; RS_ON_STATE -- guest side: apply a STATE frame from FRMBUF.
; ---------------------------------------------------------------------------
RS_ON_STATE:
        PSHR    R5
        MVI     FRMBUF, R0
        CMPI    #3,     R0
        BLT     @@rs_bad                ; short frame: +2/+3 would be stale
        MVI     FRMBUF+3, R0
        CMPI    #$FF,   R0
        BEQ     @@rs_ctl
        ; Data chunks are only ever legitimate inside a hold that a BEGIN
        ; opened.  Outside one, a "STATE" frame is by definition a misparse
        ; (the wire carries plenty of $08 bytes), and IMG_PUT would turn its
        ; position straight into a write anywhere in the address space.
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@rs_bad
        ; count = len - 3
        MVI     FRMBUF, R0
        SUBI    #3,     R0
        BLE     @@rs_bad
        MVO     R0,     RS_TMP2
        ; Bounds: the chunk must lie wholly inside the image.  Without this
        ; IMG_PUT walks off the end of RS_TAILTBL and uses ROM CODE WORDS as
        ; destination pointers (STIC registers, GRAM, BACKTAB), and a
        ; position >= $8000 fails the signed range tests and splats a
        ; contiguous run over $0000+ -- the whole STIC register file.
        MVI     FRMBUF+3, R1
        CMPI    #4,     R1
        BGE     @@rs_bad                ; pos >= $400: keeps the 16-bit
                                        ;  reconstruction unwrapped; the
                                        ;  EXACT bound is IMG_TOTAL below.
                                        ;  (In the Armor Battle port a
                                        ;  hardcoded "pos_hi < 3" here
                                        ;  silently dropped the last chunk
                                        ;  -- the tail with RNG/FG_TICK_EN/
                                        ;  GAME_TBL -- when the image grew
                                        ;  past 768; caught by the m4
                                        ;  DIAG_REJ gate.)
        SWAP    R1,     1
        ADD     FRMBUF+2, R1            ; R1 = pos (0..1023)
        ADDR    R0,     R1              ; + count (<= 252), no wrap possible
        CMPI    #IMG_TOTAL+1, R1
        BGE     @@rs_bad                ; chunk overruns the image: drop it
        MVI     FRMBUF+2, R0
        MVO     R0,     RS_POS_LO
        MVI     FRMBUF+3, R0
        MVO     R0,     RS_POS_HI
        MVII    #FRMBUF+4, R3
@@rs_dl:
        MVI@    R3,     R0
        INCR    R3
        MVI     RS_POS_HI, R1
        SWAP    R1,     1
        ADD     RS_POS_LO, R1
        JSR     R5,     IMG_PUT         ; preserves R3
        MVI     RS_POS_LO, R0
        INCR    R0
        MVO     R0,     RS_POS_LO
        CMPI    #$100,  R0
        BNEQ    @@rs_np
        MVI     RS_POS_HI, R0
        INCR    R0
        MVO     R0,     RS_POS_HI
@@rs_np:
        MVI     RS_TMP2, R0
        DECR    R0
        MVO     R0,     RS_TMP2
        BNEQ    @@rs_dl
        B       @@rs_out
@@rs_ctl:
        MVI     FRMBUF+2, R0
        TSTR    R0
        BNEQ    @@rs_endf
        ; BEGIN: hold + record resume tick
        MVI     FRMBUF, R1
        CMPI    #5,     R1
        BLT     @@rs_bad                ; short frame: +4/+5 would be stale
        JSR     R5,     RS_ENTER_HOLD
        MVI     FRMBUF+4, R0
        MVO     R0,     RS_R_LO
        MVI     FRMBUF+5, R0
        MVO     R0,     RS_R_HI
        B       @@rs_out
@@rs_endf:
        CMPI    #1,     R0
        BNEQ    @@rs_out
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BEQ     @@rs_out                ; no hold open: not our END
        JSR     R5,     RS_REBASE
        B       @@rs_out
@@rs_bad:
        ; a refused chunk means a misframed stream reached this far
        MVII    #DIAG_REJ, R4
        JSR     R5,     DIAG_BUMP
@@rs_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_ENTER_HOLD / RS_REBASE
; ---------------------------------------------------------------------------
RS_ENTER_HOLD:
        PSHR    R5
        MVII    #1,     R0
        MVO     R0,     RESYNC_HOLD
        CLRR    R0
        MVO     R0,     RS_TO_LO
        MVO     R0,     RS_TO_HI
        JSR     R5,     RS_CLR_CRC
        PULR    R7

RS_REBASE:
        PSHR    R5
    IF NET_HUD <> 0
        MVI     HUD_RSY, R0
        CMPI    #$FF,   R0
        BEQ     @@rb_hd
        INCR    R0
        MVO     R0,     HUD_RSY
@@rb_hd:
    ENDI
        CLRR    R0
        MVO     R0,     RS_PEND
        MVO     R0,     RS_PTMO
        JSR     R5,     RS_DISPLAY_RESET
        JSR     R5,     RS_CLAMP_ISR
        JSR     R5,     NB_REBASE_HOOK  ; cart-specific (src/hook.asm):
                                        ;  restores the four native
                                        ;  countdowns from their mirrors
        MVI     RS_R_LO, R0
        MVO     R0,     TICK_LO
        MVI     RS_R_HI, R0
        MVO     R0,     TICK_HI
        JSR     R5,     LS_RING_INIT    ; all input rings back to idle
        ; every remote seat's watermark = R + d - 1 (the whole room
        ; re-baselines together: the host's STATE push is a broadcast)
        MVI     RS_R_HI, R1
        SWAP    R1,     1
        ADD     RS_R_LO, R1
        MVI     NET_DELAY, R0
        ADDR    R0,     R1
        DECR    R1
        MVII    #SEAT_WM, R3
        MVII    #4,     R2
@@rb_wm:
        MOVR    R3,     R4
        MVO@    R1,     R4              ; lo (8-bit cell truncates)
        SWAP    R1,     1
        MVO@    R1,     R4              ; hi
        SWAP    R1,     1               ; restore for the next seat
        ADDI    #2,     R3
        DECR    R2
        BNEQ    @@rb_wm
        JSR     R5,     RS_CLR_CRC
        CLRR    R0
        MVO     R0,     RESYNC_HOLD
        MVO     R0,     RS_TO_LO
        MVO     R0,     RS_TO_HI
        MVO     R0,     LS_WAITC_LO
        MVO     R0,     LS_WAITC_HI
        PULR    R7

; ---------------------------------------------------------------------------
; RS_PENDING -- host side, once per game tick: a resync is wanted, so wait for
; a quiescent moment and then push.
;
; "Dead ball" is read straight off NB_PHASE ($0163, exec_equ.asm): BOTH
; bit $80 (P0 input disabled) and bit $40 (P1 input disabled) set means
; neither team can currently act -- the tip-off/dead-ball state (M0),
; reachable between possessions, after a basket, or at any other moment
; the game itself parks input.  Waiting costs a few seconds of the two
; sims running visibly apart, which is why the wait is capped at
; RS_PEND_MAX ticks -- past that a visible jump beats staying desynced,
; and we push regardless.
;
; Taking the snapshot here rather than from inside the frame dispatcher is a
; bonus: the image is now always serialized at the same fixed point in the
; pass, after the tick and its virtual dispatch have finished.
; ---------------------------------------------------------------------------
; $035D is installed exactly ONCE on this cart, at $50A1, and never
; changes -- so the Baseball/Bowling route of reading the phase off the
; adopted handler table does not exist here; NB_PHASE is the cart's own
; equivalent.  UNLIKE the family's default (any bit of SC_PHASE_DEAD set
; means quiescent -- an ANDI/BNEQ), this cart needs BOTH bits set: bit 7
; alone (only P0 disabled) is an ordinary mid-play moment (e.g. a single
; team momentarily can't act), not dead ball -- confirmed by the two
; write sites (M0's L_55B9/L_55C9) always toggling both bits together via
; `XORI #$00C0,R0`/`ANDI #$003F,R0`, never one alone.  So the test is a
; CMPI-equality after the mask, one added line beyond the family's usual
; two (Sea Battle's REBASE_HOOK precedent for a minimal per-cart
; deviation, PORTING.md §4).
RS_PEND_MAX     EQU     60              ; game ticks (~4 s at the measured tick)

RS_PENDING:
        PSHR    R5
        MVI     RS_PEND, R0
        TSTR    R0
        BEQ     @@rp_out
        MVI     NET_SEAT, R0
        TSTR    R0
        BNEQ    @@rp_out                ; only the host pushes
        MVI     RESYNC_HOLD, R0
        TSTR    R0
        BNEQ    @@rp_out                ; push already under way
        MVI     RS_PTMO, R0
        INCR    R0
        MVO     R0,     RS_PTMO
        ; quiescent?  BOTH input-disable bits must be set (dead ball) --
        ; not just any one of them (§5.6-adjacent: this equality form is
        ; the one thing this cart's phase test needs beyond the family
        ; default).
        MVI     SC_PHASE, R0
        ANDI    #SC_PHASE_DEAD, R0
        CMPI    #SC_PHASE_DEAD, R0
        BEQ     @@rp_go                 ; dead ball: the swap is invisible
@@rp_tmo:
        MVI     RS_PTMO, R0
        CMPI    #RS_PEND_MAX, R0
        BLT     @@rp_out                ; still waiting for the play to end
        MVII    #2,     R0              ; gave up: pushing mid-play
        B       @@rp_mark
@@rp_go:
        MVII    #1,     R0              ; quiescent phase: swap is invisible
@@rp_mark:
        MVO     R0,     RS_GATE
        MVI     RS_PTMO, R0
        MVO     R0,     RS_WAITED       ; how long this one actually waited
        JSR     R5,     RS_PUSH
@@rp_out:
        PULR    R7

; ---------------------------------------------------------------------------
; RS_DISPLAY_RESET -- reassert the static half of the display state from the
; cart header.
;
; This cart has ZERO real STIC writes (M0 -- recon's 6 "hits" are all
; class-1 false positives: an INCR R7 and four mid-JSR decode artifacts)
; and no scroll dance at all, so this is the plain Baseball/Bowling form,
; not Auto Racing/Soccer's scroll-aware one: border extension ($0032 from
; $500D) and the colour-stack/border-colour block ($0028-$002C from
; $500F-$5013 -- colour-stack mode, $500E=$00) both come straight from
; the header and are reasserted verbatim.  Also used from the peer-left
; path (LS_PEER_LEFT): with nothing to repaint over it, a plain reassert
; is enough there too -- no separate normalize routine needed.
; ---------------------------------------------------------------------------
RS_DISPLAY_RESET:
        PSHR    R5
        MVI     $500D,  R0
        MVO     R0,     $0032           ; border extension
        MVII    #$500F, R4              ; header: CS0..CS3 then border colour
        MVII    #$0028, R5
        MVII    #5,     R2
@@dr_l: MVI@    R4,     R0
        MVO@    R0,     R5              ; $0028-$002C
        DECR    R2
        BNEQ    @@dr_l
        PULR    R7

; ---------------------------------------------------------------------------
; RS_CLAMP_ISR -- force the cart's saved interrupt vector, and the live one,
; back to the EXEC default after applying a state image.
;
; This cart never installs a custom ISR body (M0: zero $0100/$0101 writes
; anywhere, confirmed live at every boot-dump point sampled), so
; SC_ISR_SAVE (exec_equ.asm/ram.asm) aliases a harmless netcode-RAM spare
; pair, never written by the cart -- this routine is a structural no-op
; here, kept only for the family's standard defensive shape (Sea Battle's/
; Golf's own precedent).  Run by host and guest alike from RS_REBASE, so
; it stays symmetric and CRC-neutral regardless.  Clobbers R0.
; ---------------------------------------------------------------------------
RS_CLAMP_ISR:
        DIS
        MVII    #EXEC_ISR_DEF AND $FF, R0
        MVO     R0,     SC_ISR_SAVE
        MVO     R0,     $100
        MVII    #EXEC_ISR_DEF SHR 8, R0
        MVO     R0,     SC_ISR_SAVE+1
        MVO     R0,     $101
        EIS
        MOVR    R5,     R7

; RS_CLR_CRC -- invalidate every record in the ring.
;
; The fill value is NOT zero.  A record is matched by its stored tick, and a
; zeroed ring reads as a perfectly good record for tick 0 with a checksum of
; 0 -- so the peer's tick-0 CRC, which routinely arrives before this console
; has ticked 0 at all (the handover hold pumps the socket while TICK is still
; 0), compared against nothing and declared a desync.  That cost a full state
; resync near the start of every single match; the server's own CRC log said
; the two consoles agreed the whole time.  CRCs are only ever recorded on a
; 64-tick boundary, so a stored tick_lo of $FF cannot collide with a real one.
RS_CLR_CRC:
        PSHR    R5
        MVII    #OWN_CRC, R4
        MVII    #32,    R1
        MVII    #$FF,   R0
@@cc_l: MVO@    R0,     R4
        DECR    R1
        BNEQ    @@cc_l
        PULR    R7

; ---------------------------------------------------------------------------
; IMG_GET -- R0 = image byte at position R1.  Preserves R2, R3.
; IMG_PUT -- write byte R0 to image position R1.  Preserves R3.
; ---------------------------------------------------------------------------
; 12 entries -- TWO SHORTER than the family's traditional 14-entry tail
; (PORTING.md §7.16 sweep done: IMG_S1/S2/S3 unchanged, only IMG_TOTAL
; moves, 770 -> 767).  Every cell here carries REAL state -- no RS_SPARE
; padding needed: this cart has no arm-flag mirrors at all (native
; dispatch tracks arm/stop as the real countdown's own stop bit, already
; captured by mirroring the countdown itself) and no turn-arbiter/
; boot-prompt-injector cell (no player-count prompt on this cart, M0).
RS_TAILTBL:
        DECLE   RNG_LO, RNG_HI
        DECLE   SC_CNT2, SC_CNT3, SC_CNT4, SC_CNT5      ; $8196-9
        DECLE   SC_CNT6, SC_CNT7, SC_CNT8, SC_CNT9      ; $819A-D
        DECLE   GAME_TBL_LO, GAME_TBL_HI

IMG_GET:
        CMPI    #IMG_S1, R1
        BGE     @@ig_2
        ADDI    #$15D,  R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        MOVR    R5,     R7
@@ig_2: CMPI    #IMG_S2, R1
        BGE     @@ig_3
        SUBI    #IMG_S1, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$200,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
        B       @@ig_w
@@ig_3: CMPI    #IMG_S3, R1
        BGE     @@ig_t
        SUBI    #IMG_S2, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$31D,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
@@ig_w: MVI@    R4,     R0
        TSTR    R1
        BEQ     @@ig_lo
        SWAP    R0,     1
@@ig_lo:
        ANDI    #$FF,   R0
        MOVR    R5,     R7
@@ig_t: SUBI    #IMG_S3, R1
        ADDI    #RS_TAILTBL, R1
        MOVR    R1,     R4
        MVI@    R4,     R1
        MOVR    R1,     R4
        MVI@    R4,     R0
        MOVR    R5,     R7

IMG_PUT:
        MVO     R0,     RS_TMP
        CMPI    #IMG_S1, R1
        BGE     @@ip_2
        ADDI    #$15D,  R1
        MOVR    R1,     R4
        MVI     RS_TMP, R0
        MVO@    R0,     R4
        MOVR    R5,     R7
@@ip_2: CMPI    #IMG_S2, R1
        BGE     @@ip_3
        SUBI    #IMG_S1, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$200,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
        B       @@ip_w
@@ip_3: CMPI    #IMG_S3, R1
        BGE     @@ip_t
        SUBI    #IMG_S2, R1
        MOVR    R1,     R0
        SLR     R0,     1
        ADDI    #$31D,  R0
        MOVR    R0,     R4
        ANDI    #1,     R1
@@ip_w: ; read-modify-write the 16-bit word (chunks arrive lo byte first)
        MOVR    R4,     R2
        MVI@    R4,     R0
        TSTR    R1
        BEQ     @@ip_lo
        ANDI    #$00FF, R0
        MVI     RS_TMP, R1
        SWAP    R1,     1
        ADDR    R1,     R0
        B       @@ip_st
@@ip_lo:
        ANDI    #$FF00, R0
        ADD     RS_TMP, R0
@@ip_st:
        MOVR    R2,     R4
        MVO@    R0,     R4
        MOVR    R5,     R7
@@ip_t: SUBI    #IMG_S3, R1
        ADDI    #RS_TAILTBL, R1
        MOVR    R1,     R4
        MVI@    R4,     R1
        MOVR    R1,     R4
        MVI     RS_TMP, R0
        MVO@    R0,     R4
        MOVR    R5,     R7
