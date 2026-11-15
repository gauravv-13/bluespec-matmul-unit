# ACA Mini-Project: Matrix-Multiply Unit

A 4×4×4 tiled matrix-multiply unit (`C += A × B`, Int8 operands, Int32 accumulator) written in Bluespec SystemVerilog. It exposes a request/response interface where each request moves a single 32-bit word, so that it can later become a RISC-V custom instruction.

## Designs

| Design | File | Idea | W1 / W2 cycles | Cells | Logic depth |
|---|---|---|--:|--:|--:|
| A | `MatMulA.bsv` | Fully combinational: whole tile in one cycle (64 multipliers) | 40,961 / 299,009 | 113,160 | 71 |
| B | `MatMulB.bsv` | K-serial: one outer product per cycle (16 multipliers); loads wait for the Mul | 53,249 / 397,313 | 32,535 | 55 |
| **C** | `MatMulC.bsv` | K-serial with an operand snapshot, so the next tile loads while a Mul runs | 41,985 / 300,033 | 32,787 | 54 |

**Design C is the submitted design** (`MatMul.bsv`). It has the best cycles × depth and cells × depth of the three. All three pass the testbench on both workloads with zero errors.

## Files

- `MatMul.bsv`: the submitted design (Design C)
- `MatMulA.bsv`, `MatMulB.bsv`, `MatMulC.bsv`: the three design variants
- `MM_Types.bsv`: the interface and types shared with the harness (not to be modified)
- `TbMatMul.bsv`: the testbench, which checks results against a reference model on two workloads
- `REPORT.md`: measurements, predictions vs. results, and design rationale
- `SPEC.pdf`: the project specification

## Build and run

You need the [Bluespec compiler](https://github.com/B-Lang-org/bsc) (`bsc`).

```sh
bsc -sim -g mkTbMatMul -u TbMatMul.bsv
bsc -sim -e mkTbMatMul -o sim
./sim
```

The testbench imports the `MatMul` package. To test a different variant, copy it over `MatMul.bsv` and rename its `package` / `endpackage` to `MatMul`.

| Workload | Shape | Requests |
|---|---|--:|
| W1 | 64 × 64 × 64 (16 Muls per readout) | 40,960 |
| W2 | 64 × 512 × 64 (128 Muls per readout) | 299,008 |
