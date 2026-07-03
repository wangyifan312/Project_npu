//=============================================================================
// npu_axi_gemm_peak_test.sv — AXIfed NPU GEMM Peak Microbenchmark
//
// STATUS: SUPPLEMENTAL — not primary competition evidence (yet).
//
// GEMM C[M×N] = A[M×K] × B[K×N] mapped as M FC tasks (row-by-row).
// All-1 data: golden C[i][j] = K.
// Four levels: L0(8×64×8), L1(16×128×16), L2(64×256×64), L3(64×512×64).
// KNOWN LIMIT: K>64 triggers multi-chunk FC (CLAUDE.md §9.1).
//=============================================================================

`timescale 1ns / 1ps

class npu_axi_gemm_peak_test extends soc_base_test;

  `uvm_component_utils(npu_axi_gemm_peak_test)

  function new(string name = "npu_axi_gemm_peak_test", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  task run_phase(uvm_phase phase);
    npu_fc_task_seq fc_seq;
    byte unsigned input_vec[];
    byte unsigned weight_mat[];
    byte unsigned golden_row[];
    bit [31:0] cycle_lo, mac_lo, mac_hi;
    bit [63:0] math_mac;
    int i, j, lvl, row;
    int M_v, K_v, N_v;
    int total_cycles, rows_ok;
    int M_arr[4], K_arr[4], N_arr[4];
    bit row_fail;

    phase.raise_objection(this);
    #200;

    M_arr[0] = 8;   K_arr[0] = 64;  N_arr[0] = 8;
    M_arr[1] = 16;  K_arr[1] = 128; N_arr[1] = 16;
    M_arr[2] = 64;  K_arr[2] = 256; N_arr[2] = 64;
    M_arr[3] = 64;  K_arr[3] = 512; N_arr[3] = 64;

    `uvm_info("TEST", "", UVM_NONE)
    `uvm_info("TEST", "##################################################################", UVM_NONE)
    `uvm_info("TEST", "#  AXI-FED NPU GEMM PEAK MICROBENCHMARK", UVM_NONE)
    `uvm_info("TEST", "##################################################################", UVM_NONE)

    for (lvl = 0; lvl < 4; lvl++) begin
      M_v = M_arr[lvl]; K_v = K_arr[lvl]; N_v = N_arr[lvl];
      math_mac = 64'(M_v) * K_v * N_v;
      total_cycles = 0; rows_ok = 0; row_fail = 1'b0;

      `uvm_info("TEST", "", UVM_NONE)
      `uvm_info("TEST", $sformatf("======== L%d: M=%0d K=%0d N=%0d math_mac=%0d ========", lvl, M_v, K_v, N_v, math_mac), UVM_NONE)

      // Build weight B[K×N]: all-1 INT8, row-major [output][input]
      weight_mat = new[K_v * N_v];
      for (i = 0; i < K_v * N_v; i++) weight_mat[i] = 8'd1;

      // Build golden: each output element = K (INT32)
      golden_row = new[N_v * 4];
      for (j = 0; j < N_v; j++) begin
        golden_row[j*4 + 0] = K_v & 8'hFF;
        golden_row[j*4 + 1] = (K_v >> 8) & 8'hFF;
        golden_row[j*4 + 2] = (K_v >> 16) & 8'hFF;
        golden_row[j*4 + 3] = (K_v >> 24) & 8'hFF;
      end

      // Process each row of GEMM as an FC task
      for (row = 0; row < M_v; row++) begin
        // Build input A[row,:]: all-1
        input_vec = new[K_v];
        for (j = 0; j < K_v; j++) input_vec[j] = 8'd1;

        fc_seq = npu_fc_task_seq::type_id::create("fc_seq");
        fc_seq.input_data  = input_vec;
        fc_seq.weight_data = weight_mat;
        fc_seq.input_c     = K_v;
        fc_seq.output_c    = N_v;
        fc_seq.expected_output_bytes = N_v * 4;
        fc_seq.cluster_mode          = 2'd0;
        fc_seq.input_base   = 32'h0000_0100;
        fc_seq.weight_base  = 32'h0001_0000;
        fc_seq.output_base  = 32'h0002_0000;

        fc_seq.start(env.axil_ag.seqr);

        if (fc_seq.done && !fc_seq.error) begin
          // 验证输出
          if (fc_seq.actual_output.size() != N_v * 4) begin
            `uvm_error("TEST", $sformatf("L%d row %0d: output size %0d != expected %0d",
              lvl, row, fc_seq.actual_output.size(), N_v*4))
            row_fail = 1'b1;
            break;
          end
          for (j = 0; j < N_v * 4; j++) begin
            if (fc_seq.actual_output[j] != golden_row[j]) begin
              `uvm_error("TEST", $sformatf("L%d row %0d: byte %0d mismatch: actual=%0d expected=%0d",
                lvl, row, j, fc_seq.actual_output[j], golden_row[j]))
              row_fail = 1'b1;
              break;
            end
          end
          if (!row_fail) rows_ok = rows_ok + 1;
        end else begin
          `uvm_error("TEST", $sformatf("L%d row %0d: FC failed (done=%0d error=%0d)",
            lvl, row, fc_seq.done, fc_seq.error))
          row_fail = 1'b1;
        end

        if (row_fail) break;
      end

      // 读 performance counters (via a helper base sequence)
      begin
        soc_base_seq rd_seq;
        rd_seq = soc_base_seq::type_id::create("rd_seq");
        rd_seq.start(env.axil_ag.seqr);
        rd_seq.axil_read32(`NPU_REG_PERF_CYCLE_LO, cycle_lo);
        rd_seq.axil_read32(`NPU_REG_PERF_MAC_LO, mac_lo);
        rd_seq.axil_read32(`NPU_REG_PERF_MAC_HI, mac_hi);
        total_cycles = cycle_lo;
      end

      `uvm_info("TEST", $sformatf("=== AXI GEMM PEAK SUMMARY [L%d] ===", lvl), UVM_NONE)
      `uvm_info("TEST", $sformatf("  level                   = L%d", lvl), UVM_NONE)
      `uvm_info("TEST", $sformatf("  M=%0d K=%0d N=%0d", M_v, K_v, N_v), UVM_NONE)
      `uvm_info("TEST", $sformatf("  math_mac_count          = %0d", math_mac), UVM_NONE)
      `uvm_info("TEST", $sformatf("  task_cycles (last row)  = %0d", total_cycles), UVM_NONE)
      `uvm_info("TEST", $sformatf("  correctness_pass        = %s (%0d/%0d rows)", (rows_ok==M_v)?"YES":"NO", rows_ok, M_v), UVM_NONE)
      `uvm_info("TEST", $sformatf("  multi_chunk (K>64)      = %s", (K_v>64)?"YES (known issue)":"NO"), UVM_NONE)
      `uvm_info("TEST", "==================================================================", UVM_NONE)

      if (row_fail) begin
        if (K_v > 64) begin
          `uvm_info("TEST", $sformatf("DIAGNOSIS: L%d FAIL K=%0d>64 → multi-chunk FC bug (CLAUDE.md §9.1). K chunks=%0d.", lvl, K_v, (K_v+63)/64), UVM_NONE)
        end
        break;
      end
    end

    `uvm_info("TEST", $sformatf("=== AXI GEMM PEAK COMPLETE: %0d/4 levels passed ===", lvl), UVM_NONE)

    phase.drop_objection(this);
  endtask

endclass
