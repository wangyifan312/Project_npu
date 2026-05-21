#!/bin/bash
# run_sim.sh — unified simulation entry point for NPU verification
# Usage: ./sim/run_sim.sh <test_name>
#   test_name: tb_npu_top | tb_task1 | tb_task2 | tb_task3 | tb_task6 | tb_fc | tb_top | tb_shared | tb_system | tb_checker
set -e

cd "$(dirname "$0")/.."
SIMDIR=sim
mkdir -p "$SIMDIR"

IVERILOG="iverilog -g2012 -Wall"
VVP="vvp"

# Shared RTL sources used by most tests
NPU_RTL="rtl/npu/*.v"
BUS_RTL="rtl/bus/axi_interconnect.v"
SOC_RTL="rtl/soc/axi4_ram.v rtl/soc/shared_ram.v"

case "$1" in
    tb_npu_top)
        $IVERILOG -o "$SIMDIR/tb_npu_top.vvp" $SOC_RTL $NPU_RTL tb/integration/tb_npu_top.v
        $VVP "$SIMDIR/tb_npu_top.vvp"
        ;;
    tb_task1)
        $IVERILOG -o "$SIMDIR/tb_task1.vvp" rtl/soc/axi4_ram.v $NPU_RTL tb/integration/tb_task1_illegal.v
        $VVP "$SIMDIR/tb_task1.vvp"
        ;;
    tb_task2)
        $IVERILOG -o "$SIMDIR/tb_task2.vvp" rtl/soc/axi4_ram.v $NPU_RTL tb/integration/tb_task2_multiblock.v
        $VVP "$SIMDIR/tb_task2.vvp"
        ;;
    tb_task3)
        $IVERILOG -o "$SIMDIR/tb_task3.vvp" $BUS_RTL tb/integration/tb_task3_axilite.v
        $VVP "$SIMDIR/tb_task3.vvp"
        ;;
    tb_task6)
        $IVERILOG -o "$SIMDIR/tb_task6.vvp" rtl/soc/axi4_ram.v $NPU_RTL tb/integration/tb_task6_pingpong.v
        $VVP "$SIMDIR/tb_task6.vvp"
        ;;
    tb_fc)
        $IVERILOG -o "$SIMDIR/tb_fc_reject.vvp" $NPU_RTL tb/unit/tb_fc_reject.v
        $VVP "$SIMDIR/tb_fc_reject.vvp"
        ;;
    tb_checker)
        $IVERILOG -o "$SIMDIR/tb_task_checker.vvp" tb/unit/tb_task_checker.v rtl/npu/task_checker.v
        $VVP "$SIMDIR/tb_task_checker.vvp"
        ;;
    tb_top)
        $IVERILOG -o "$SIMDIR/tb_top.vvp" $SOC_RTL $BUS_RTL $NPU_RTL rtl/cpu/picorv32/picorv32.v rtl/soc/top.v tb/integration/tb_top.v
        $VVP "$SIMDIR/tb_top.vvp"
        ;;
    tb_shared)
        $IVERILOG -o "$SIMDIR/tb_shared.vvp" rtl/soc/shared_ram.v tb/integration/tb_task4_shared_mem.v
        $VVP "$SIMDIR/tb_shared.vvp"
        ;;
    tb_system)
        $IVERILOG -o "$SIMDIR/tb_system.vvp" rtl/soc/shared_ram.v $BUS_RTL $NPU_RTL tb/integration/tb_task4_system.v
        $VVP "$SIMDIR/tb_system.vvp"
        ;;
    all)
        echo "=== Task 1 ===" && ./sim/run_sim.sh tb_task1
        echo "=== Regression ===" && ./sim/run_sim.sh tb_npu_top
        echo "=== Task 2 ===" && ./sim/run_sim.sh tb_task2
        echo "=== Task 3 ===" && ./sim/run_sim.sh tb_task3
        echo "=== Task 4 (shared) ===" && ./sim/run_sim.sh tb_shared
        echo "=== Task 4 (system) ===" && ./sim/run_sim.sh tb_system
        echo "=== Task 5 (FC) ===" && ./sim/run_sim.sh tb_fc
        echo "=== Task 6 ===" && ./sim/run_sim.sh tb_task6
        echo "=== Task Checker Unit ===" && ./sim/run_sim.sh tb_checker
        echo "=== Top Smoke ===" && ./sim/run_sim.sh tb_top
        echo "=== Done ==="
        ;;
    *)
        echo "Usage: $0 <test_name>"
        echo "  tb_npu_top  — NPU regression (single-block Conv)"
        echo "  tb_task1     — Task 1 illegal param check"
        echo "  tb_task2     — Task 2 multi-block Conv"
        echo "  tb_task3     — Task 3 AXI-Lite decoupling"
        echo "  tb_task6     — Task 6 ping-pong bank sequencing"
        echo "  tb_fc        — Task 5 FC rejection"
        echo "  tb_checker   — task_checker unit test"
        echo "  tb_top       — top-level smoke test"
        echo "  tb_shared    — Task 4 shared memory unit test"
        echo "  tb_system    — Task 4 system-level test"
        echo "  all          — run consolidated regression suite"
        ;;
esac
