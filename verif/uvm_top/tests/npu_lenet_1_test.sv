//=============================================================================
// npu_lenet_1_test.sv — LeNet Single-Sample UVM Test
//
// Uses bd_if.load_memh DPI-C function to preload fixture data directly
// into shared RAM (fast backdoor), then drives the NPU through the full 9-layer
// LeNet pipeline via npu_lenet_seq.
//
// At the end, reads FC2 logits, performs argmax, and compares the predicted
// class with the expected label from the fixture.
//
// Plusargs:
//   +fixture_dir=<path>     fixture root (default: datasets/mnist/lenet_fixture)
//   +sample_name=<name>     sample sub-directory (default: sample_00000_label_7)
//   +rq_conv2_mult=<n>      Requant Conv2 multiplier (default: 0x004DEB00)
//   +rq_conv2_shift=<n>     Requant Conv2 shift (default: 17)
//   +rq_fc1_mult=<n>        Requant FC1 multiplier (default: 0x00623031)
//   +rq_fc1_shift=<n>       Requant FC1 shift (default: 16)
//   +rq_fc2_mult=<n>        Requant FC2 multiplier (default: 0x003A2E8C)
//   +rq_fc2_shift=<n>       Requant FC2 shift (default: 15)
//=============================================================================

`timescale 1ns / 1ps

class npu_lenet_1_test extends soc_base_test;

  `uvm_component_utils(npu_lenet_1_test)

  //-----------------------------------------------------------------------------
  // Fixture / configuration parameters
  //-----------------------------------------------------------------------------
  string fixture_dir;
  string sample_name;
  int    rq_conv2_mult;
  int    rq_conv2_shift;
  int    rq_fc1_mult;
  int    rq_fc1_shift;
  int    rq_fc2_mult;
  int    rq_fc2_shift;

  function new(string name = "npu_lenet_1_test", uvm_component parent = null);
    super.new(name, parent);
    fixture_dir     = "datasets/mnist/lenet_fixture";
    sample_name     = "sample_00000_label_7";
    rq_conv2_mult   = 32'h004DEB00;
    rq_conv2_shift  = 17;
    rq_fc1_mult     = 32'h00623031;
    rq_fc1_shift    = 16;
    rq_fc2_mult     = 32'h003A2E8C;
    rq_fc2_shift    = 15;
  endfunction

  //-----------------------------------------------------------------------------
  // Helper: read a single integer from a text file
  //-----------------------------------------------------------------------------
  function int read_label_file(string path);
    int fd;
    int value;
    fd = $fopen(path, "r");
    if (fd == 0) begin
      `uvm_error("LENET_TEST", $sformatf("Cannot open label file: %0s", path))
      return -1;
    end
    value = -1;
    if ($fscanf(fd, "%d", value) != 1) begin
      `uvm_error("LENET_TEST", $sformatf("Failed to read label from %0s", path))
    end
    $fclose(fd);
    return value;
  endfunction

  //-----------------------------------------------------------------------------
  // run_phase: load fixtures, run pipeline, check result
  //-----------------------------------------------------------------------------
  task run_phase(uvm_phase phase);
    npu_lenet_seq lenet_seq;
    virtual backdoor_if bd_if;
    string sample_dir;
    string weights_dir;
    string path_input;
    string path_conv1_w;
    string path_conv2_w;
    string path_fc1_w;
    string path_fc2_w;
    string path_label;
    int expected_class;
    int pred_class;
    int signed best_val;
    int s;
    int signed logit_val;
    int backdoor_val;

    phase.raise_objection(this);
    #200;

    //---------------------------------------------------------------------------
    // Get backdoor virtual interface from config_db
    //---------------------------------------------------------------------------
    if (!uvm_config_db#(virtual backdoor_if)::get(this, "", "bd_if", bd_if))
      `uvm_fatal("LENET_TEST", "backdoor_if not found in config_db")

    //---------------------------------------------------------------------------
    // Parse plusargs
    //---------------------------------------------------------------------------
    void'($value$plusargs("fixture_dir=%s",  fixture_dir));
    void'($value$plusargs("sample_name=%s",  sample_name));
    void'($value$plusargs("rq_conv2_mult=%d",  rq_conv2_mult));
    void'($value$plusargs("rq_conv2_shift=%d", rq_conv2_shift));
    void'($value$plusargs("rq_fc1_mult=%d",    rq_fc1_mult));
    void'($value$plusargs("rq_fc1_shift=%d",   rq_fc1_shift));
    void'($value$plusargs("rq_fc2_mult=%d",    rq_fc2_mult));
    void'($value$plusargs("rq_fc2_shift=%d",   rq_fc2_shift));

    sample_dir  = {fixture_dir, "/", sample_name};
    weights_dir = {fixture_dir, "/weights"};

    path_input   = {sample_dir, "/input.memh"};
    path_conv1_w = {weights_dir, "/conv1_weights.memh"};
    path_conv2_w = {weights_dir, "/conv2_weights.memh"};
    path_fc1_w   = {weights_dir, "/fc1_weights.memh"};
    path_fc2_w   = {weights_dir, "/fc2_weights.memh"};
    path_label   = {sample_dir, "/label.txt"};

    `uvm_info("LENET_TEST", $sformatf("Fixture: %0s, sample: %0s", fixture_dir, sample_name), UVM_NONE)

    //---------------------------------------------------------------------------
    // 预加载 all fixture data into shared RAM via backdoor interface
    //---------------------------------------------------------------------------
    `uvm_info("LENET_TEST", "Loading input image...", UVM_NONE)
    bd_if.load_memh(path_input,   32'h0000_0100, 196);

    `uvm_info("LENET_TEST", "Loading Conv1 weights...", UVM_NONE)
    bd_if.load_memh(path_conv1_w, 32'h0000_1000, 125);

    `uvm_info("LENET_TEST", "Loading Conv2 weights...", UVM_NONE)
    bd_if.load_memh(path_conv2_w, 32'h0002_0000, 6250);

    `uvm_info("LENET_TEST", "Loading FC1 weights...", UVM_NONE)
    bd_if.load_memh(path_fc1_w,   32'h0009_0000, 100000);

    `uvm_info("LENET_TEST", "Loading FC2 weights...", UVM_NONE)
    bd_if.load_memh(path_fc2_w,   32'h000F_3000, 1250);

    `uvm_info("LENET_TEST", "All fixture data loaded into shared RAM", UVM_NONE)

    //---------------------------------------------------------------------------
    // Create and configure the LeNet sequence
    //---------------------------------------------------------------------------
    lenet_seq = npu_lenet_seq::type_id::create("lenet_seq");
    lenet_seq.cluster_mode   = 2'd2;
    lenet_seq.rq_conv2_mult  = rq_conv2_mult;
    lenet_seq.rq_conv2_shift = rq_conv2_shift;
    lenet_seq.rq_fc1_mult    = rq_fc1_mult;
    lenet_seq.rq_fc1_shift   = rq_fc1_shift;
    lenet_seq.rq_fc2_mult    = rq_fc2_mult;
    lenet_seq.rq_fc2_shift   = rq_fc2_shift;
    lenet_seq.poll_timeout   = 20000000;

    `uvm_info("LENET_TEST", "=== Starting LeNet Pipeline ===", UVM_NONE)
    lenet_seq.start(env.axil_ag.seqr);

    //---------------------------------------------------------------------------
    // Check pipeline result
    //---------------------------------------------------------------------------
    if (lenet_seq.error) begin
      `uvm_error("LENET_TEST", $sformatf("LeNet pipeline failed: error_code=0x%02x", lenet_seq.error_code))
    end else if (!lenet_seq.done) begin
      `uvm_error("LENET_TEST", "LeNet pipeline did not complete (timeout)")
    end else begin
      `uvm_info("LENET_TEST", "LeNet pipeline completed. Computing argmax...", UVM_NONE)

      // 读 FC2 logits via backdoor to cross-check
      `uvm_info("LENET_TEST", "FC2 logits (AXI-Lite vs backdoor):", UVM_NONE)
      for (s = 0; s < 10; s++) begin
        backdoor_val = bd_if.read32(32'h000F_5000 + s * 4);
        `uvm_info("LENET_TEST", $sformatf("  logit[%0d]: AXI=%0d (0x%08x)  RAM=%0d (0x%08x)",
          s, lenet_seq.fc2_logits[s], lenet_seq.fc2_logits[s],
          backdoor_val, backdoor_val), UVM_NONE)
      end

      // Argmax
      pred_class = 0;
      best_val   = -32'sd2147483648;
      for (s = 0; s < 10; s++) begin
        logit_val = lenet_seq.fc2_logits[s];
        if (logit_val > best_val) begin
          best_val   = logit_val;
          pred_class = s;
        end
      end

      // 读 expected label
      expected_class = read_label_file(path_label);
      if (expected_class == -1) begin
        `uvm_warning("LENET_TEST", "Could not read expected label, using label from sample name")
        // 回退: try argmax.txt
        expected_class = read_label_file({sample_dir, "/argmax.txt"});
      end

      `uvm_info("LENET_TEST", $sformatf("Predicted class=%0d  Expected class=%0d  best_logit=%0d",
        pred_class, expected_class, best_val), UVM_NONE)

      if (pred_class == expected_class) begin
        `uvm_info("LENET_TEST", "=== npu_lenet_1_test PASSED ===", UVM_NONE)
      end else begin
        `uvm_error("LENET_TEST", $sformatf("Classification mismatch: predicted=%0d expected=%0d",
          pred_class, expected_class))
      end
    end

    phase.drop_objection(this);
  endtask

endclass
