// MatMulB.bsv --- Design B: K-serial.
//
// Mul is split across K_DIM cycles.  On step l, for all sixteen (i, j) at once:
//
//     C[i][j] += A[i][l] * B[l][j]
//
// i.e. one outer product per cycle: sixteen multipliers and sixteen
// accumulating adders, used four times, instead of sixty-four multipliers and
// sixteen four-input adder trees used once.
//
// Sequential-order requirement (spec §3).  While a Mul is in flight it is still
// reading A and B and writing C.  So, until it finishes:
//   * LoadA / LoadB must wait -- they would change an operand underneath it;
//   * ReadC must wait          -- it would see a partial sum, and its zeroing
//                                 would be overwritten by the next step;
//   * another Mul must wait    -- there is only one set of accumulators.
// This design takes the simplest legitimate answer: every request waits while
// `rg_busy` is set.  Design C removes the wait for loads.
//
// Keep the (* synthesize *) attribute: `make depth` needs it to find the
// module boundary.

package MatMulB;

import Vector   :: *;
import FIFOF    :: *;
import MM_Types :: *;

// ================================================================
// One outer product: C += (column l of A) x (row l of B).
//
// The critical path is now one multiply and ONE add per output, rather than a
// multiply followed by a K-term sum.  The index `l` is dynamic, so selecting
// column l of A and row l of B adds a 4:1 mux in front of each multiplier.

function C_Mat f_step (A_Mat a, B_Mat b, C_Mat c, Bit #(2) l);
   C_Mat o = c;
   for (Integer i = 0; i < m_dim; i = i + 1)
      for (Integer j = 0; j < n_dim; j = j + 1)
	 o[i][j] = c[i][j] + (signExtend (a[i][l]) * signExtend (b[l][j]));
   return o;
endfunction

// ================================================================

(* synthesize *)
module mkMatMul (MatMul_IFC);

   Reg #(A_Mat) rg_a <- mkReg (replicate (replicate (0)));
   Reg #(B_Mat) rg_b <- mkReg (replicate (replicate (0)));
   Reg #(C_Mat) rg_c <- mkReg (replicate (replicate (0)));

   // Mul state machine: rg_busy is set while steps 1..K-1 remain; rg_k is the
   // next step to run.
   Reg #(Bool)     rg_busy <- mkReg (False);
   Reg #(Bit #(2)) rg_k    <- mkReg (0);

   // Pulsed in the cycle a Mul is accepted, so step 0 runs in that same cycle.
   // Without it, accepting the Mul would cost a cycle of its own on top of the
   // K steps.
   PulseWire pw_start <- mkPulseWire;

   FIFOF #(MM_Req) f_req <- mkFIFOF;
   FIFOF #(MM_Rsp) f_rsp <- mkFIFOF;

   // ---- One rule per request type (see MatMul.bsv for why).  Every one of
   // them is guarded on !rg_busy: that guard is the "unit is busy" signal, and
   // it reaches the harness as back-pressure through f_req filling up.
   //
   // The loads and ReadC also carry `! pw_start`.  It is never false when
   // their request is at the head (pw_start means the head is a Mul), but
   // without it bsc cannot see that they and rl_mul_step are never enabled
   // together, and reports conflicts on rg_a, rg_b and rg_c.

   rule rl_load_a (f_req.first matches tagged LoadA .w &&& !rg_busy &&& !pw_start);
      f_req.deq;
      let a = rg_a;
      a[w.row] = reverse (unpack (w.word));
      rg_a <= a;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_load_b (f_req.first matches tagged LoadB .w &&& !rg_busy &&& !pw_start);
      f_req.deq;
      let b = rg_b;
      b[w.row] = reverse (unpack (w.word));
      rg_b <= b;
      f_rsp.enq (mm_rsp_none);
   endrule

   // Accept a Mul.  Its response carries no value and no information about
   // the result, so it can be sent now; the in-order property is kept because
   // nothing behind it can respond until the steps have finished.
   rule rl_mul_accept (f_req.first matches tagged Mul &&& !rg_busy);
      f_req.deq;
      f_rsp.enq (mm_rsp_none);
      pw_start.send;
   endrule

   // The arithmetic.  ONE rule does every step, so there is exactly one copy
   // of the sixteen multipliers -- bsc instantiates the hardware of each rule
   // separately, and a second rule calling f_step would double the array.
   rule rl_mul_step (rg_busy || pw_start);
      Bit #(2) k = rg_busy ? rg_k : 0;
      rg_c <= f_step (rg_a, rg_b, rg_c, k);
      if (k == fromInteger (k_dim - 1))
	 rg_busy <= False;
      else begin
	 rg_busy <= True;
	 rg_k    <= k + 1;
      end
   endrule

   rule rl_read_c (f_req.first matches tagged ReadC .x &&& !rg_busy &&& !pw_start);
      f_req.deq;
      let c = rg_c;
      Acc v = c [x.row][x.chunk];
      c [x.row][x.chunk] = 0;
      rg_c <= c;
      f_rsp.enq (mm_rsp_value (pack (v)));
   endrule

   // ---- The interface.

   method Action req (MM_Req r) = f_req.enq (r);

   method ActionValue #(MM_Rsp) rsp;
      f_rsp.deq;
      return f_rsp.first;
   endmethod
endmodule

endpackage: MatMulB
