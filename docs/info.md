## How it works

ZIRH-1 is a self-reporting SEU measurement instrument on IHP SG13G2.
Matched storage targets - a 256-bit ring of ordinary flip-flops and the
same ring built from three voted TMR replicas - circulate a known pattern.
A flipped bit travels to the ring exit, is counted once, and leaves; the
rings re-arm themselves. Three TMR'd, saturating 16-bit counters track:

- PLAIN: flips in the unprotected ring (classic cross-section)
- RAW: any TMR replica disagreement (heals in one cycle)
- ESCAPE: the voted bit is wrong - TMR defeated by a multiple upset

A telemetry framer snapshots the counters atomically every 3.3 ms and
streams a 10-byte frame (sync "ZR", status, three counters, XOR checksum)
over the UART at 114.9 kBd with no CPU and no commands. Between frames the
UART echoes received bytes. The clock/reset block runs a triplicated reset
synchronizer and a TMR heartbeat counter; its mismatch pulses and the UART's
are visible on dedicated pins.

The design closes timing at 50 MHz and runs at 20 MHz: the margin is a
hardening parameter. All TMR replicas live in keep_hierarchy modules, and a
synthesis integrity check verifies on every build that 1554 flip-flops -
including every replica - survive optimization.

## How to test

Reset, then:

1. HEARTBEAT (uo[0]) toggles at ~1.2 Hz: clock, reset and TMR are alive.
2. Set SEL=3 (ui[1:0]): RD_DATA (uio) returns the signature - ID byte 0x5A
   on the high byte (SEL_HI=1), armed flag and pattern mode on the low.
3. Telemetry frames arrive on UART_TX (uo[4]) at 115200 8N1 unprompted:
   check sync bytes 5A 52 and the XOR checksum.
4. Fault injection: point SEL at a counter (0 plain, 1 raw, 2 escape) and
   pulse INJ (ui[6]). The selected counter increments by exactly one -
   readable on RD_DATA and in the next telemetry frame. SEL=1 must not
   move ESCAPE (the voter masks it); SEL=2 must not move RAW (all three
   replicas agree on the wrong value).
5. CLEAR (ui[7]) zeroes the counters. Send any byte to UART_RX (ui[3]) and
   it echoes back between frames.

Pattern mode (ui[5:4]): 00 zeros, 01 ones, 1x checkerboard. Mode changes
re-arm a warm-up window; counting resumes once the rings refill.

## External hardware

None required - any 3.3 V serial adapter for the UART. Optional: RS422
driver/receiver (e.g. MAX490) on a carrier board for an electrically
flight-representative link, an LED on HEARTBEAT, a scope on SEU_EVT
(uo[7]) to watch beam events live.
