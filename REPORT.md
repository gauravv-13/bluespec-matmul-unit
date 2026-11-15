# Mini-project Part 1: The matrix-multiply unit

Submitted design: **C** in `MatMul.bsv`. All three designs (`MatMulA.bsv`, `MatMulB.bsv`,
`MatMulC.bsv`) pass `TbMatMul` on both workloads with zero errors.

## 1. Measurements

| Design | W1 cycles | W2 cycles | Stalls (W1 / W2) | Cells | Logic depth | Cycles × depth (W1 / W2) | Cells × depth | MACs/request (W1 / W2) |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| A | **40,961** | **299,009** | **1 / 1** | 113,160 | 71 | 2,908,231 / 21,229,639 | 8,034,360 | 6.40 / 7.01 |
| B | 53,249 | 397,313 | 12,289 / 98,305 | **32,535** | 55 | 2,928,695 / 21,852,215 | 1,789,425 | 6.40 / 7.01 |
| C | 41,985 | 300,033 | 1,025 / 1,025 | 32,787 | **54** | **2,267,190 / 16,201,782** | **1,770,498** | 6.40 / 7.01 |

Bold terms are best in that column. Sorted: **cycles** A < C < B · **cells** B < C ≪ A · **depth** C < B < A ·
**cycles×depth** C < A ≈ B · **cells×depth** C < B ≪ A: A wins cycles, B cells, C everything else.

## 2. Predictions (§6.4) and where they were wrong

A tile is 9 requests (4 LoadA, 4 LoadB, 1 Mul) and ℓ is the cycles a Mul occupies.

| Prediction | Measured | Where it went wrong |
|---|---|---|
| A: 8 + ℓ = 9 cycles per tile (ℓ = 1) | 1 stall in total, i.e. 9 per tile |  Right prediction. |
| B: 8 + ℓ = 12 cycles per tile (ℓ = 4), as loads wait for the Mul | 12,289 stalls = 3 × 4,096 Muls + 1 |  Right prediction. |
| C: max(9, ℓ + 1) = 9 cycles per tile, as loads overlap the Mul | 1,025 stalls = 4 × 256 readouts + 1 | Missed that ReadC must wait for the in-flight Mul: 4 stalls per readout. |
| B/C cycle ratio = 12 / 9 = 1.33 | 1.27 (W1), 1.32 (W2) | Right per tile only. Readout requests and C's readout stalls dilute it, most in W1. |
| Cells: A > C > B (64 vs 16 multipliers, plus C's extra copy of A and B) | 113,160 > 32,787 > 32,535 |  Right prediction. C − B is only 0.8%: the 256 snapshot flip-flops. |
| Depth: A > B = C (multiply + 4-term sum vs multiply + one add) | 71 > 55 ≈ 54 | Order is right, but B/C also pay a 4:1 operand mux (≈7 levels) before each multiplier. |

## 3. Answers to §10

**3.1 Did the prediction hold?** See §2.

**3.2 Where do the cycles go?** **A:** only the final response stall. **B:** 3 stalls per Mul: step
0 runs in the accept cycle, and the next tile's first LoadA waits out the other 3. **C:** 4 stalls
per *readout* (Mul→ReadC), none inside the accumulation, so the same 1,025 on W1 and W2.

**3.3 Why is MACs/request the same for all three?** The interface and tile shape fix the request
count: 9 requests buy 64 MACs, plus 16 ReadCs per output tile (6.40 W1, 7.01 W2, → 64 / 9 = 7.11).
A design only sets how many cycles they take. To change MACs/req we can use 64-bit words, bigger S×S×S
tiles (≈ 2S), operand reuse across Muls or descriptor DMA.

**3.4 What sets the longest path?** Isolated pieces through the same yosys flow: 32-bit add is
**18**, 8×8 multiply sign-extended to 32 bits is **39**, MAC **49**, 4:1 operand mux + MAC (one step
of B/C) is  **56** and multiply + 4-term serial sum (A's datapath) is **71** which is exactly A's logic depth. The multiplier dominates: 39 of B's ≈55 levels, on every critical path. Serialising over K
removes three of A's four additions (≈22 levels, since chained adders partly overlap) but adds a 4:1 mux
(≈7). That is the trap: 4× fewer multipliers, only a 23% shorter path.

**3.5 LoadA while a Mul is in progress.** Every step reads a column of every row of A, so no
LoadA may change that A until the last step. For Design B, stalls happen: 3 cycles per tile, no extra state.
For Design C, we do snapshot, that is copying the load bank into a private Mul bank on accept: 256 flip-flops, no cycles.
Later loads only touch the load bank, never the running Mul. ReadC and a new Mul still wait.

**3.6 W2 vs W1.** Per readout W2 costs more: 1,168 vs 160 requests per epoch (73 vs 10 per
output). Per MAC it costs less: 0.143 vs 0.156 requests/MAC, as 16 readouts spread over 128 Muls,
not 16. W2/W1 cycles per MAC: **A 0.913, B 0.933, C 0.893**. C is most sensitive (readout is its
only stall source: 2.5% → 0.34%). B is least, as its stalls scale with Muls.

**3.7 Accumulator width.** **The bound:** the largest signed product is (−2^(W−1))² = 2^(2W−2),
so after T Muls of K products |C| ≤ T·K·2^(2W−2), which must fit in 2^(W_ACC−1) − 1. This gives
**W_ACC ≥ 2·W_ELEM + ⌊log₂(K·T)⌋**. **At 32 bits** it is safe for 32,767 Muls (2048² needs 27).
**At 16 bits** no Mul is safe for full-range Int8 (4 × 2^14 > 32,767), but on the harness data
([−8, 7], ≤ 256 per Mul) 127 are, enough for W1 (16) but not W2 (128). **So** readout bounds T,
which is why the read is destructive.

**3.8 DMA.** **Q1:** immediately, at
the 4×4×4 tile itself, since 32 bytes per 64 MACs is only 2 MACs/byte. At 1 GHz, A (64 MACs/cycle)
needs 32 GB/s, over one DDR4-3200 channel (≈25 GB/s). B/C need 8 GB/s, a third of a shared channel.
Bigger tiles help (MACs/byte = S/2). **Q2:**
**page pinning**, so pages under an in-flight transfer must not move, plus coherence and address
translation.

**3.9 What `make schedule` shows.** All three final designs schedule with `Blocking rules: (none)`
and no warnings, but B did not at first. Its first version guarded `rl_load_a`, `rl_load_b` and
`rl_read_c` on `!rg_busy` only, and `make schedule` printed three G0010 warnings:

```
Warning: (G0010) Rule "rl_load_a" was treated as more urgent than "rl_mul_step". Conflicts:
    "rl_load_a" cannot fire before "rl_mul_step": calls to rg_a.write vs. rg_a.read
    "rl_mul_step" cannot fire before "rl_load_a": calls to rg_busy.write vs. rg_busy.read
```

and the same for `rl_load_b` (`rg_b`) and `rl_read_c` (`rg_c`): each rule writes what the other
reads. In the accept cycle the step fires on `pw_start` while `rg_busy` is still False. That means
the head is a Mul, not a load, but bsc cannot see it through a wire. So we then added
`&&& !pw_start` to those three guards, which made the exclusion explicit and removed all three
warnings. Cycle counts are identical either way.

## 4. Choice

**Priority: time to finish a large multiply (cycles × depth), at reasonable area.** C takes 22 to 24%
less time than A and 26% less than B on W2, with 3.45× fewer cells than A and the best cells ×
depth. Against B it pays 0.8% more cells for 21 to 25% fewer cycles.

**Strongest argument against: the clock may not be ours to set.** In Part 2 the unit sits inside
Fife. If the CPU's critical path exceeds 71 levels, A's depth is free and A wins: 2.4% fewer
cycles, no in-flight state, no hazard or in-order-retirement interaction (C's four-cycle Mul is
what Part 2 warns about). But A costs 3.45× the area and 71 levels is unlikely to hide under a
5-stage RV32I pipeline, so we still choose C.
