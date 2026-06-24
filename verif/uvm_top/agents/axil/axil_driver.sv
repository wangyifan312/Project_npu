`timescale 1ns / 1ps

class axil_driver extends uvm_driver #(axil_seq_item);

  `uvm_component_utils(axil_driver)

  virtual axil_if vif;

  function new(string name = "axil_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual axil_if)::get(this, "", "axil_vif", vif))
      `uvm_fatal("AXIL_DRV", "Virtual axil_if not found in config_db")
  endfunction

  task run_phase(uvm_phase phase);
    axil_seq_item tr;
    forever begin
      seq_item_port.get_next_item(tr);
      if (tr.cmd == axil_seq_item::AXIL_WRITE)
        drive_write(tr);
      else
        drive_read(tr);
      seq_item_port.item_done();
    end
  endtask

  task drive_write(axil_seq_item tr);
    @(posedge vif.clk);
    vif.awaddr  <= tr.addr;
    vif.awvalid <= 1'b1;
    vif.wdata   <= tr.data;
    vif.wstrb   <= tr.strb;
    vif.wvalid  <= 1'b1;
    vif.bready  <= 1'b1;

    wait(vif.awvalid && vif.awready);
    @(posedge vif.clk);
    vif.awvalid <= 1'b0;

    wait(vif.wvalid && vif.wready);
    @(posedge vif.clk);
    vif.wvalid <= 1'b0;

    wait(vif.bvalid && vif.bready);
    tr.resp = vif.bresp;
    @(posedge vif.clk);
    vif.bready <= 1'b0;

    `uvm_info("AXIL_DRV", $sformatf("WRITE addr=0x%08h data=0x%08h strb=0x%0h resp=%0d", tr.addr, tr.data, tr.strb, tr.resp), UVM_MEDIUM)
  endtask

  task drive_read(axil_seq_item tr);
    @(posedge vif.clk);
    vif.araddr  <= tr.addr;
    vif.arvalid <= 1'b1;
    vif.rready  <= 1'b1;

    wait(vif.arvalid && vif.arready);
    @(posedge vif.clk);
    vif.arvalid <= 1'b0;

    wait(vif.rvalid && vif.rready);
    tr.rdata = vif.rdata;
    tr.resp  = vif.rresp;
    @(posedge vif.clk);
    vif.rready <= 1'b0;

    `uvm_info("AXIL_DRV", $sformatf("READ  addr=0x%08h rdata=0x%08h resp=%0d", tr.addr, tr.rdata, tr.resp), UVM_MEDIUM)
  endtask

endclass
