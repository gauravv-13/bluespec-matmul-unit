// MatMul.bsv --- Design C: K-serial with double buffering.
//
// The arithmetic is Design B's: one outer product per cycle, K_DIM cycles per
// Mul.  What changes is that the Mul no longer reads the A and B that loads
// write.  There are two banks of each:
//
//   rg_a,  rg_b   -- the LOAD bank.  LoadA / LoadB always write here.  This is
//                    the architectural A and B: what a one-request-at-a-time
//                    unit would hold after the requests seen so far.
//   rg_ma, rg_mb  -- the MUL bank.  Captured from the load bank in the cycle a
//                    Mul is accepted, and the only operands the steps read.
//
// So while a Mul runs on the MUL bank, the next tile's loads fill the LOAD bank
// and never wait for it.
//
// Why "capture" rather than ping-pong between two banks with a select bit.
// A plain ping-pong makes the next loads write into the bank the Mul-before-
// last used.  If a tile reloads only some rows (legal: nothing requires all
// four), the next Mul would read the other rows from TWO tiles ago -- but
// sequential semantics say they hold the values from ONE tile ago.  The
// harness always reloads every row, so that bug passes the testbench and is
// still wrong under spec §3.  Copying the whole load bank into the Mul bank at
// accept time is the correct version, for the same 512 bits of state.
//
// Timing.  The accept cycle only captures the operands; the K_DIM steps run in
// the K_DIM cycles after it, so a Mul takes K_DIM + 1 cycles from accept to
// finish.  Loads do not notice: they flow from the very next cycle.  A ReadC
// that follows a Mul does: it waits K_DIM cycles rather than K_DIM - 1, one
// extra stall per readout.  Running step 0 in the accept cycle would remove
// that stall, but step 0 would then have to read the load bank while steps
// 1..K-1 read the Mul bank -- a 2:1 mux in front of every multiplier operand,
// on the critical path of every cycle.  Measured, that trade loses: 256 fewer
// cycles per workload, 6 more levels of logic depth.
//
// What still waits while a Mul is in flight:
//   * ReadC   -- C is still being accumulated; it must see the finished sum.
//   * Mul     -- there is one Mul bank and one set of accumulators.
// Loads do not wait: they touch only the load bank.
//
// Keep the (* synthesize *) attribute: `make depth` needs it to find the
// module boundary.

package MatMul;

import Vector   :: *;
import FIFOF    :: *;
import MM_Types :: *;

// ================================================================
// One outer product: C += (column l of A) x (row l of B).  Same as Design B.

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

   // Load bank: architectural A and B.
   Reg #(A_Mat) rg_a  <- mkReg (replicate (replicate (0)));
   Reg #(B_Mat) rg_b  <- mkReg (replicate (replicate (0)));

   // Mul bank: the operands of the Mul in flight.
   Reg #(A_Mat) rg_ma <- mkReg (replicate (replicate (0)));
   Reg #(B_Mat) rg_mb <- mkReg (replicate (replicate (0)));

   Reg #(C_Mat) rg_c  <- mkReg (replicate (replicate (0)));

   // Mul state machine: rg_busy is set while steps remain; rg_k is the next.
   Reg #(Bool)     rg_busy <- mkReg (False);
   Reg #(Bit #(2)) rg_k    <- mkReg (0);

   FIFOF #(MM_Req) f_req <- mkFIFOF;
   FIFOF #(MM_Rsp) f_rsp <- mkFIFOF;

   // ---- Loads: no busy guard.  They share no state with rl_mul_step, so bsc
   // can fire a load and a step in the same cycle.

   rule rl_load_a (f_req.first matches tagged LoadA .w);
      f_req.deq;
      let a = rg_a;
      a[w.row] = reverse (unpack (w.word));
      rg_a <= a;
      f_rsp.enq (mm_rsp_none);
   endrule

   rule rl_load_b (f_req.first matches tagged LoadB .w);
      f_req.deq;
      let b = rg_b;
      b[w.row] = reverse (unpack (w.word));
      rg_b <= b;
      f_rsp.enq (mm_rsp_none);
   endrule

   // Accept a Mul: snapshot the load bank into the Mul bank and start the
   // state machine.  The steps start next cycle (see "Timing" above).
   rule rl_mul_accept (f_req.first matches tagged Mul &&& !rg_busy);
      f_req.deq;
      rg_ma   <= rg_a;
      rg_mb   <= rg_b;
      rg_busy <= True;
      rg_k    <= 0;
      f_rsp.enq (mm_rsp_none);
   endrule

   // The arithmetic, on the Mul bank only.  ONE rule does every step, so
   // there is one copy of the sixteen multipliers.
   rule rl_mul_step (rg_busy);
      rg_c <= f_step (rg_ma, rg_mb, rg_c, rg_k);
      if (rg_k == fromInteger (k_dim - 1)) rg_busy <= False;
      rg_k <= rg_k + 1;
   endrule

   // ReadC must wait for any Mul in flight: it has to return the finished sum,
   // and its zeroing must not be overwritten by a later step.  The guard also
   // lets bsc see that this rule and rl_mul_step never fire together, so they
   // do not conflict on rg_c.
   rule rl_read_c (f_req.first matches tagged ReadC .x &&& !rg_busy);
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

endpackage: MatMul
