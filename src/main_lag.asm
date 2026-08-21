; Interception proof build: the deterministic demo script (SCRIPT_TBL)
; drives both pads, with every input delayed by 20 game ticks (1 second).
; SPIKE_TRACE is on so run_lagcheck.sh can correlate the dedicated
; LAG_RING (SHADOW_CTRL/SHADOW_CTRL_R -- the polled shadow pair, a direct
; un-smoothed echo of exactly what the delay ring handed back each tick)
; against the d=0 build (basketball_lag0), NOT the whole-state TRACE_RING
; checksum (Golf's §7.33 default): this cart's four always-armed native
; timer entries (game clock, shot clock, animation walk, ball blink) are
; delay-INVARIANT ambient state that would swamp the much smaller
; input-driven signal in a whole-checksum correlation -- Shark Shark's
; exact §7.38 failure shape. See src/debug.asm/src/ram.asm.
; TRACE_STOP is short (250 ticks, under the 256-wrap boundary) so the
; scripted portion is still inside the ring's last lap when it parks.
SPIKE_DELAY     EQU     20
SPIKE_SCRIPT    EQU     1
SPIKE_TRACE     EQU     1
TRACE_STOP      EQU     250     ; < 256: ring never wraps, index i == tick i
STALL_N         EQU     0
SPIKE_ECHO      EQU     0
SPIKE_RECORD    EQU     0
SPIKE_REPLAY    EQU     0
NET_SESSION     EQU     0
AUTO_JOIN       EQU     0
NET_FUZZ        EQU     0
NET_HUD         EQU     0
SPIKE_VIRT      EQU     1
        INCLUDE "src/core.asm"
