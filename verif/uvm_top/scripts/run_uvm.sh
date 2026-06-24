#!/bin/bash
#=============================================================================
# run_uvm.sh — VCS compile-and-run script for UVM top-level testbench
#
# Usage:
#   ./run_uvm.sh [test_name] [verbosity]
#
# Defaults:
#   test_name = soc_shared_ram_rw_test
#   verbosity = UVM_MEDIUM
#
# Environment:
#   VCS_HOME — path to VCS installation
#     Default: /opt/synopsys/vcs-mx/O-2018.09-SP2
#=============================================================================

set -e

TEST=${1:-soc_shared_ram_rw_test}
VERBOSITY=${2:-UVM_MEDIUM}
VCS_HOME=${VCS_HOME:-/opt/synopsys/vcs-mx/O-2018.09-SP2}
export VCS_HOME

PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SIMDIR="${PROJ_ROOT}/sim"
LOGDIR="${SIMDIR}"

mkdir -p "${SIMDIR}"

echo "============================================"
echo " UVM Top-Level Testbench"
echo " Project:   ${PROJ_ROOT}"
echo " Test:      ${TEST}"
echo " Verbosity: ${VERBOSITY}"
echo " VCS_HOME:  ${VCS_HOME}"
echo "============================================"

echo ""
echo "=== Compiling with VCS ==="
vcs -full64 -sverilog -timescale=1ns/1ps \
    -ntb_opts uvm-1.2 \
    +incdir+rtl/npu \
    +incdir+rtl/soc \
    +incdir+rtl/bus \
    +incdir+rtl/cpu/picorv32 \
    +incdir+verif/uvm_top/tb \
    +incdir+verif/uvm_top/interfaces \
    +incdir+verif/uvm_top/agents/axil \
    +incdir+verif/uvm_top/agents/status \
    +incdir+verif/uvm_top/agents/dma_mon \
    +incdir+verif/uvm_top/env \
    +incdir+verif/uvm_top/sequences/base \
    +incdir+verif/uvm_top/sequences/common \
    +incdir+verif/uvm_top/sequences/tasks \
    +incdir+verif/uvm_top/sequences/networks \
    +incdir+verif/uvm_top/tests \
    +incdir+verif/uvm_top/pkg \
    +incdir+verif/uvm_top/ref_model \
    -top tb_soc_top_uvm \
    -o sim/simv_uvm_top \
    -f verif/uvm_top/filelist.f

echo ""
echo "=== Running test: ${TEST} ==="
./sim/simv_uvm_top \
    +UVM_TESTNAME=${TEST} \
    +UVM_VERBOSITY=${VERBOSITY} \
    -l sim/uvm_run.log

echo ""
echo "=== Test complete ==="
echo "Log:  sim/uvm_run.log"
echo "Waves: sim/tb_soc_top_uvm.vcd"
