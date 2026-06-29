//=============================================================================
// filelist.f — UVM Top-Level Testbench Compile Order
//
// RTL sources are listed first, then UVM infrastructure.  All paths are
// relative to the project root.  +incdir+ directives in the VCS invocation
// resolve `include paths.
//
// Required +incdir+ paths for compilation:
// +incdir+rtl/npu +incdir+rtl/soc +incdir+rtl/bus +incdir+rtl/cpu/picorv32
// +incdir+verif/uvm_top/tb +incdir+verif/uvm_top/interfaces
// +incdir+verif/uvm_top/agents/axil +incdir+verif/uvm_top/agents/status +incdir+verif/uvm_top/agents/dma_mon
// +incdir+verif/uvm_top/env +incdir+verif/uvm_top/sequences/base
// +incdir+verif/uvm_top/sequences/common +incdir+verif/uvm_top/sequences/tasks
// +incdir+verif/uvm_top/sequences/networks
// +incdir+verif/uvm_top/tests +incdir+verif/uvm_top/pkg +incdir+verif/uvm_top/ref_model
//=============================================================================

//-----------------------------------------------------------------------------
// RTL: CPU
//-----------------------------------------------------------------------------
rtl/cpu/picorv32/picorv32.v

//-----------------------------------------------------------------------------
// RTL: Bus fabric
//-----------------------------------------------------------------------------
rtl/bus/axi_interconnect.v
rtl/soc/axi4_ram.v
rtl/soc/shared_ram.v

//-----------------------------------------------------------------------------
// RTL: NPU compute array
//-----------------------------------------------------------------------------
rtl/npu/mac_pe.v
rtl/npu/mac_tile_4x4.v
rtl/npu/array_top.v
rtl/npu/pe_cluster.v
rtl/npu/compute_core.v

//-----------------------------------------------------------------------------
// RTL: NPU control / scheduling
//-----------------------------------------------------------------------------
rtl/npu/cluster_scheduler.v
rtl/npu/output_arbiter.v
rtl/npu/block_scheduler.v
rtl/npu/task_checker.v
rtl/npu/npu_ctrl.v

//-----------------------------------------------------------------------------
// RTL: NPU datapath
//-----------------------------------------------------------------------------
rtl/npu/postproc.v
rtl/npu/perf_counter.v
rtl/npu/requant_i32_to_i8.v
rtl/npu/bias_add_requant_i32_to_i8.v
rtl/npu/residual_add_requant_i8.v
rtl/npu/gap8x8_requant_i8.v
rtl/npu/write_beat_fifo.v

//-----------------------------------------------------------------------------
// RTL: NPU DMA / memory
//-----------------------------------------------------------------------------
rtl/npu/dma_axi_reader.v
rtl/npu/dma_axi_writer.v
rtl/npu/act_read_path.v
rtl/npu/weight_read_path.v
rtl/npu/npu_buffer.v

//-----------------------------------------------------------------------------
// RTL: NPU frontends
//-----------------------------------------------------------------------------
rtl/npu/conv_frontend.v
rtl/npu/fc_frontend.v

//-----------------------------------------------------------------------------
// RTL: NPU top / SoC top
//-----------------------------------------------------------------------------
rtl/npu/npu_top.v
rtl/soc/top.v

//-----------------------------------------------------------------------------
// UVM interfaces (compiled before the package)
//-----------------------------------------------------------------------------
verif/uvm_top/interfaces/axil_if.sv
verif/uvm_top/interfaces/soc_probe_if.sv
verif/uvm_top/interfaces/backdoor_if.sv

//-----------------------------------------------------------------------------
// UVM package (pulls in all UVM component sources via `include)
//-----------------------------------------------------------------------------
verif/uvm_top/pkg/soc_top_uvm_pkg.sv

//-----------------------------------------------------------------------------
// DPI-C reference model (C source)
//
// NOTE: This file #includes "npu_ref_model.h", so the VCS command line MUST
// include +incdir+verif/uvm_top/ref_model for the header to be found.
//-----------------------------------------------------------------------------
verif/uvm_top/ref_model/npu_ref_model.c

//-----------------------------------------------------------------------------
// Top-level testbench module
//-----------------------------------------------------------------------------
verif/uvm_top/tb/tb_soc_top_uvm.sv
