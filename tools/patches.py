# In-place patch map for NBABasketball.bin (word address -> as1600 expression).
# Symbols are defined in src/hook.asm / src/ram.asm / src/exec_equ.asm.
# Building with tools/dump_rom.py and NO patch file must stay byte-identical
# to the original (make verify-org -- verified).
#
# STATUS (see spikes/NOTES.md M0-M4 for the evidence trail): header
# relocation, both RNG wrapper flavours (8 sites), the single hybrid
# polled-input site, all six timer-arm/stop sites, and SIX sound-engine-
# state-drift fixes (§7.21 -- one found via `make det` bisection, five
# more via a real `make rig` desync) are decoded and confirmed in the
# dis1600 listing.  `make verify-patch` proves exactly the 39 words below
# differ from the original ROM.
#
# This cart's timer-arm/stop sites are a shape no prior port has needed:
# every one computes its target as `MOVR R7,R1 / SUBI #k,R1` (current-PC-
# relative), not an absolute `MVII #addr,R1` operand.  Because native
# dispatch (PORTING.md Sec7.31) keeps slots 2/3/5 at their ORIGINAL table
# position (only slot 1 is inserted, replacing $5063 with MASTER_TICK), and
# the EXEC's own `.EXEC.811` helper (traced live in the EXEC disassembly)
# re-reads the header's CURRENT timer-table pointer on every call via
# `X_READ_ROM_HDR` field 2 -- rather than a cached boot-time copy -- the
# countdown-cell math ($0125 + (R1-table_base)/2) keeps working unmodified
# as long as R1 still equals NEW_TIMER_TBL + 4*slot at the JSR/J.  Since the
# `MOVR R7,R1` half is unpatched (it always yields the correct live PC) and
# the `SUBI` immediate is the ONLY thing that needs to change, no shim is
# needed at all here -- unlike Boxing's BX_ARM_SHIM/BX_STOP_SHIM, which
# exists because Boxing's sites use a stale ABSOLUTE operand instead.
{
    # --- Cart header ---
    # $5002/$5003: EXEC timer table pointer -> relocated table in $6000 seg.
    0x5002: "NEW_TIMER_TBL AND $FF",
    0x5003: "NEW_TIMER_TBL SHR 8",
    # $5004/$5005: start-of-game vector -> netcode init shim (falls through
    # to the original .START at $5043).
    0x5004: "NET_START AND $FF",
    0x5005: "NET_START SHR 8",

    # --- RNG call sites -> canonical-RNG wrappers ---
    # Each JSR R5,target is the 3-word form (opcode word unpatched; the
    # following two words encode the target as
    # ((target SHR 10) SHL 2) OR $0100, target AND $3FF).
    # X_RAND1 ($167D), 3 sites.
    0x5314: "((NB_RAND1 SHR 10) SHL 2) OR $0100",
    0x5315: "NB_RAND1 AND $3FF",
    0x56D4: "((NB_RAND1 SHR 10) SHL 2) OR $0100",
    0x56D5: "NB_RAND1 AND $3FF",
    0x5A27: "((NB_RAND1 SHR 10) SHL 2) OR $0100",
    0x5A28: "NB_RAND1 AND $3FF",
    # X_RAND2 ($169E), 5 sites.
    0x52E0: "((NB_RAND2 SHR 10) SHL 2) OR $0100",
    0x52E1: "NB_RAND2 AND $3FF",
    0x5B9A: "((NB_RAND2 SHR 10) SHL 2) OR $0100",
    0x5B9B: "NB_RAND2 AND $3FF",
    0x5BA2: "((NB_RAND2 SHR 10) SHL 2) OR $0100",
    0x5BA3: "NB_RAND2 AND $3FF",
    0x5BD6: "((NB_RAND2 SHR 10) SHL 2) OR $0100",
    0x5BD7: "NB_RAND2 AND $3FF",
    0x5BFD: "((NB_RAND2 SHR 10) SHL 2) OR $0100",
    0x5BFE: "NB_RAND2 AND $3FF",

    # --- Polled input -> shadow pair ---
    # $544C/$544D: `ANDI #$0001,R2` (select seat) / `ADDI #$011F,R2` (the
    # ONLY $011F reference in the ROM -- serves BOTH seats via
    # [$011F + seat], Armor Battle/Frog Bog's hybrid shape).  $544D is the
    # ADDI's immediate operand word.
    0x544D: "SHADOW_CTRL",

    # --- Timer-arm/stop sites -> SUBI-immediate-only retarget ---
    # Every site: MOVR R7,R1 (captures the live PC, unpatched -- always
    # correct) / SUBI #k,R1 (k is the word this dict patches) / J or JSR to
    # the REAL EXEC entry point (.EXEC.81E=arm, X_TIMER_STOP=$1838,
    # X_TIMER_START=$1844, all unpatched -- only the immediate moves).
    # NB_SLOT2/NB_SLOT3/NB_SLOT5 (exec_equ.asm) = NEW_TIMER_TBL + 4*slot.
    #
    # $507C/$507D (from L_5079): MOVR R7,R1 at $507B (PC after = $507C) /
    # SUBI #$0041,R1 -- original target $507C-$0041=$503B = orig slot 5
    # ($5074, ball-blink one-shot) -> J .EXEC.81E (arm).
    0x507D: "($507C - NB_SLOT5) AND $FFFF",
    # $5082/$5083 (L_5081): MOVR R7,R1 at $5081 (PC after=$5082) / SUBI
    # #$0047,R1 -- orig target $5082-$0047=$503B = slot 5 -> J X_TIMER_STOP.
    0x5083: "($5082 - NB_SLOT5) AND $FFFF",
    # $5089/$508A (L_5087): MOVR R7,R1 at $5088 (PC after=$5089) / SUBI
    # #$005A,R1 -- orig target $5089-$005A=$502F = slot 2 ($51FF, game
    # clock) -> JSR X_TIMER_STOP.
    0x508A: "($5089 - NB_SLOT2) AND $FFFF",
    # $5090/$5091 (L_508F): MOVR R7,R1 at $508F (PC after=$5090) / SUBI
    # #$005D,R1 -- orig target $5090-$005D=$5033 = slot 3 ($5233, shot
    # clock) -> J X_TIMER_STOP.
    0x5091: "($5090 - NB_SLOT3) AND $FFFF",
    # $5097/$5098 (L_5095, 1st call): MOVR R7,R1 at $5096 (PC after=$5097) /
    # SUBI #$0068,R1 -- orig target $5097-$0068=$502F = slot 2 -> JSR
    # X_TIMER_START.
    0x5098: "($5097 - NB_SLOT2) AND $FFFF",
    # $509D/$509E (L_5095, 2nd call): MOVR R7,R1 at $509C (PC after=$509D) /
    # SUBI #$006A,R1 -- orig target $509D-$006A=$5033 = slot 3 -> JSR
    # .EXEC.81E (arm).
    0x509E: "($509D - NB_SLOT3) AND $FFFF",

    # --- Sound-engine-state-drift fix (PORTING.md §7.21, M2/M4) ---
    # $5861/$5862: L_585D's `JSR R5,L_5CED` (ball-bounce SFX trigger) ->
    # NB_SFX_SKIP.  3-word JSR form, same encoding as the RNG sites.
    0x5861: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",
    0x5862: "NB_SFX_SKIP AND $3FF",
    # M4: a real `make rig` desync (clean through tick 704, first CRC
    # mismatch at tick 768 -- consistent with a rare event, e.g. a scored
    # basket, happening for the first time only after ~38s of masked
    # disc-only fuzz) traced to the SAME hazard class at the five
    # remaining SFX call sites whose callers are NOT followed by inline
    # SFX data (X_PLAY_RAZZ4 x2, X_PLAY_CHEER1 x2, X_PLAY_WHST1 x1) --
    # these are always-3-word `JSR R5,target` calls with ordinary code
    # immediately after, so the SAME NB_SFX_SKIP stub is safe to retarget
    # them to directly (unlike the two remaining X_PLAY_SFX1 sites at
    # $5CFC/$5D19, whose callers ARE followed by inline SFX data that a
    # plain-return stub would misinterpret as code -- left unpatched,
    # see spikes/NOTES.md M4 open items).
    0x5258: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",  # X_PLAY_RAZZ4, site 1
    0x5259: "NB_SFX_SKIP AND $3FF",
    0x5265: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",  # X_PLAY_RAZZ4, site 2
    0x5266: "NB_SFX_SKIP AND $3FF",
    0x58E7: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",  # X_PLAY_CHEER1, site 1
    0x58E8: "NB_SFX_SKIP AND $3FF",
    0x5BAA: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",  # X_PLAY_CHEER1, site 2
    0x5BAB: "NB_SFX_SKIP AND $3FF",
    0x5C4C: "((NB_SFX_SKIP SHR 10) SHL 2) OR $0100",  # X_PLAY_WHST1
    0x5C4D: "NB_SFX_SKIP AND $3FF",
}
