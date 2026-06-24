`timescale 1ns / 1ps

class axil_monitor extends uvm_monitor;

  `uvm_component_utils(axil_monitor)

  uvm_analysis_port #(axil_seq_item) ap;
  virtual axil_if vif;

  // Internal state for tracking partially-completed transactions
  bit aw_seen, w_seen;
  bit [31:0] mon_awaddr, mon_wdata;
  bit [3:0]  mon_wstrb;
  bit ar_seen;
  bit [31:0] mon_araddr;

  function new(string name = "axil_monitor", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap = new("ap", this);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", vif))
      `uvm_fatal("AXIL_MON", "Virtual axil_if not found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    axil_seq_item tr;
    forever begin
      @(posedge vif.clk);

      // --- Write transaction detection ---
      // Capture AW channel
      if (vif.awvalid && vif.awready) begin
        mon_awaddr = vif.awaddr;
        aw_seen = 1'b1;
      end
      // Capture W channel
      if (vif.wvalid && vif.wready) begin
        mon_wdata = vif.wdata;
        mon_wstrb = vif.wstrb;
        w_seen = 1'b1;
      end
      // On B handshake (write response)
      if (aw_seen && w_seen && vif.bvalid && vif.bready) begin
        tr = axil_seq_item::type_id::create("tr");
        tr.cmd  = axil_seq_item::AXIL_WRITE;
        tr.addr = mon_awaddr;
        tr.data = mon_wdata;
        tr.strb = mon_wstrb;
        tr.resp = vif.bresp;
        ap.write(tr);
        `uvm_info("AXIL_MON", $sformatf("OBSERVED WRITE addr=0x%08h data=0x%08h strb=0x%0h resp=%0d", tr.addr, tr.data, tr.strb, tr.resp), UVM_MEDIUM)
        aw_seen = 1'b0;
        w_seen  = 1'b0;
      end

      // --- Read transaction detection ---
      // Capture AR channel
      if (vif.arvalid && vif.arready) begin
        mon_araddr = vif.araddr;
        ar_seen = 1'b1;
      end
      // On R handshake (read response)
      if (ar_seen && vif.rvalid && vif.rready) begin
        tr = axil_seq_item::type_id::create("tr");
        tr.cmd   = axil_seq_item::AXIL_READ;
        tr.addr  = mon_araddr;
        tr.rdata = vif.rdata;
        tr.resp  = vif.rresp;
        ap.write(tr);
        `uvm_info("AXIL_MON", $sformatf("OBSERVED READ  addr=0x%08h rdata=0x%08h resp=%0d", tr.addr, tr.rdata, tr.resp), UVM_MEDIUM)
        ar_seen = 1'b0;
      end
    end
  endtask

endclass
