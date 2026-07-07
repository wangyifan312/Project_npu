// perf_counter: NPU任务性能统计
// 跟踪总周期数、DMA拍数、活跃周期数、阵列利用率
// 增强：计算/加载/存储细分和有效字节计数器
`timescale 1ns / 1ps

module perf_counter (
    input  wire        clk,
    input  wire        rst_n,

    // 控制
    input  wire        task_active,    // 任务执行期间为高
    input  wire        freeze,         // 错误/完成时冻结计数器

    // DMA事件输入（每拍一个脉冲）
    input  wire        read_beat,      // 一个AXI读拍完成
    input  wire        write_beat,     // 一个AXI写拍完成
    input  wire        read_active,    // DMA读端正在传输
    input  wire        write_active,   // DMA写端正在传输

    // --- 增强事件输入 ---
    // 阶段级活跃信号
    input  wire        compute_active,  // COMPUTE/PIPE_RUN状态期间为高
    input  wire        load_active,     // LOAD状态期间为高（act/wgt DMA + LOAD_ARRAY）
    input  wire        store_active,    // STORE状态期间为高
    input  wire        collect_active,  // COLLECT阶段期间为高

    // 读有效字节数（每拍：实际有效载荷，处理部分最后拍）
    // 注意：需要6位，因为最大值为32（0x20），会溢出5位
    input  wire [5:0]  read_byte_cnt,   // 此读拍中的有效字节数（1-32）

    // 写有效字节数（每拍：WSTRB popcount，处理部分最后拍）
    input  wire [5:0]  write_byte_cnt,  // 此写拍中的有效字节数（1-32）

    // MAC计数事件（脉冲，携带本周期完成的MAC数量）
    input  wire        mac_count_valid, // mac_count_add有效时为高
    input  wire [15:0] mac_count_add,   // 本周期完成的MAC数

    // 计算停顿细分
    input  wire        stall_act,       // 等待激活数据
    input  wire        stall_wgt,       // 等待权重数据
    input  wire        stall_acc,       // 等待acc缓冲区
    input  wire        stall_store,     // 等待store/FIFO

    // 阵列填充/排空阶段
    input  wire        array_fill_drain, // 阵列正在填充或排空（非稳态）

    // 遗留阵列输入
    input  wire        array_active,   // 阵列正在计算（window_valid）
    input  wire        array_stall,    // 阵列停顿等待数据
    input  wire [2:0]  cluster_active_inc,
    input  wire [2:0]  cluster_stall_inc,

    // 写事务级计数器输入
    input  wire        write_data_cycle,     // WVALID && WREADY（每AXI W拍）
    input  wire        write_txn_active,     // AW握手到B握手窗口

    // AXI通道握手周期输入
    input  wire        ar_active,            // ARVALID && ARREADY
    input  wire        aw_active,            // AWVALID && AWREADY
    input  wire        b_active,             // BVALID && BREADY
    input  wire        bus_active,           // AR/R/AW/W/B握手的并集

    // 计数器输出（done/error时冻结）
    output wire [31:0] total_cycle_lo,
    output wire [31:0] total_cycle_hi,
    output wire [31:0] read_beat_count,
    output wire [31:0] write_beat_count,
    output wire [31:0] read_active_cycles,
    output wire [31:0] write_active_cycles,
    output wire [31:0] array_active_cycles,
    output wire [31:0] array_stall_cycles,
    output wire [31:0] cluster_active_cycles,
    output wire [31:0] cluster_stall_cycles,
    output wire [31:0] write_data_cycles,
    output wire [31:0] write_txn_cycles,
    output wire [31:0] ar_handshake_cycles,
    output wire [31:0] aw_handshake_cycles,
    output wire [31:0] b_handshake_cycles,
    output wire [31:0] bus_active_cycles,

    // --- 增强计数器输出 ---
    output wire [31:0] compute_cycles,
    output wire [31:0] load_cycles,
    output wire [31:0] store_cycles,
    output wire [31:0] collect_cycles,
    output wire [31:0] read_valid_bytes,
    output wire [31:0] write_valid_bytes,
    output wire [31:0] mac_count_lo,
    output wire [31:0] mac_count_hi,
    output wire [31:0] stall_act_cycles,
    output wire [31:0] stall_wgt_cycles,
    output wire [31:0] stall_acc_cycles,
    output wire [31:0] stall_store_cycles,
    output wire [31:0] array_fill_drain_cycles
);

    // 64位周期计数器
    reg [31:0] cycle_lo, cycle_hi;

    // 拍计数器
    reg [31:0] read_beats, write_beats;

    // 活跃周期计数器
    reg [31:0] rd_active_cyc, wr_active_cyc;
    reg [31:0] arr_active_cyc, arr_stall_cyc;
    reg [31:0] cl_active_cyc, cl_stall_cyc;
    reg [31:0] wr_data_cyc, wr_txn_cyc;
    reg [31:0] ar_cyc, aw_cyc, b_cyc, bus_cyc;
    reg        task_active_d;

    // --- 增强计数器 ---
    reg [31:0] comp_cyc;       // 计算周期数
    reg [31:0] load_cyc;       // 加载周期数
    reg [31:0] store_cyc;      // 存储周期数
    reg [31:0] coll_cyc;       // 收集周期数
    reg [31:0] rd_valid_bytes; // 读有效字节数
    reg [31:0] wr_valid_bytes; // 写有效字节数
    reg [31:0] mac_cnt_lo;     // MAC计数低32位
    reg [31:0] mac_cnt_hi;     // MAC计数高32位
    reg [31:0] s_act_cyc;      // 停顿_激活_周期
    reg [31:0] s_wgt_cyc;      // 停顿_权重_周期
    reg [31:0] s_acc_cyc;      // 停顿_累加_周期
    reg [31:0] s_store_cyc;    // 停顿_存储_周期
    reg [31:0] fill_drain_cyc; // 阵列填充排空周期

    wire counting = task_active && !freeze;
    wire task_start_pulse = task_active && !task_active_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            task_active_d <= 1'b0;
        else
            task_active_d <= task_active;
    end

    // 周期计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_lo <= 32'h0;
            cycle_hi <= 32'h0;
        end else if (task_start_pulse) begin
            {cycle_hi, cycle_lo} <= freeze ? 64'h0 : 64'h1;
        end else if (task_active) begin
            if (!freeze) begin
                {cycle_hi, cycle_lo} <= {cycle_hi, cycle_lo} + 65'd1;
            end
        end
    end

    // 读拍计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_beats <= 32'h0;
        end else if (task_start_pulse) begin
            read_beats <= (!freeze && read_beat) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_beat)
                read_beats <= read_beats + 32'd1;
        end
    end

    // 写拍计数器
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            write_beats <= 32'h0;
        end else if (task_start_pulse) begin
            write_beats <= (!freeze && write_beat) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_beat)
                write_beats <= write_beats + 32'd1;
        end
    end

    // 读活跃周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            rd_active_cyc <= (!freeze && read_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_active)
                rd_active_cyc <= rd_active_cyc + 32'd1;
        end
    end

    // 写活跃周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_active_cyc <= (!freeze && write_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_active)
                wr_active_cyc <= wr_active_cyc + 32'd1;
        end
    end

    // 写数据周期（WVALID && WREADY）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_data_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_data_cyc <= (!freeze && write_data_cycle) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_data_cycle)
                wr_data_cyc <= wr_data_cyc + 32'd1;
        end
    end

    // 写事务周期（AW握手到B握手窗口）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_txn_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            wr_txn_cyc <= (!freeze && write_txn_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_txn_active)
                wr_txn_cyc <= wr_txn_cyc + 32'd1;
        end
    end

    // AR握手周期（ARVALID && ARREADY）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            ar_cyc <= (!freeze && ar_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && ar_active)
                ar_cyc <= ar_cyc + 32'd1;
        end
    end

    // AW握手周期（AWVALID && AWREADY）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            aw_cyc <= (!freeze && aw_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && aw_active)
                aw_cyc <= aw_cyc + 32'd1;
        end
    end

    // B握手周期（BVALID && BREADY）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            b_cyc <= (!freeze && b_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && b_active)
                b_cyc <= b_cyc + 32'd1;
        end
    end

    // 总线活跃周期（AR/R/AW/W/B握手的并集）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            bus_cyc <= (!freeze && bus_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && bus_active)
                bus_cyc <= bus_cyc + 32'd1;
        end
    end

    // 阵列活跃周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            arr_active_cyc <= (!freeze && array_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_active)
                arr_active_cyc <= arr_active_cyc + 32'd1;
        end
    end

    // 阵列停顿周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arr_stall_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            arr_stall_cyc <= (!freeze && array_stall) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_stall)
                arr_stall_cyc <= arr_stall_cyc + 32'd1;
        end
    end

    // 聚合已启用集群的活跃周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl_active_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            cl_active_cyc <= (!freeze && (cluster_active_inc != 3'd0)) ? {29'd0, cluster_active_inc} : 32'd0;
        end else if (task_active) begin
            if (!freeze && (cluster_active_inc != 3'd0))
                cl_active_cyc <= cl_active_cyc + {29'd0, cluster_active_inc};
        end
    end

    // 聚合已启用集群的停顿周期
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl_stall_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            cl_stall_cyc <= (!freeze && (cluster_stall_inc != 3'd0)) ? {29'd0, cluster_stall_inc} : 32'd0;
        end else if (task_active) begin
            if (!freeze && (cluster_stall_inc != 3'd0))
                cl_stall_cyc <= cl_stall_cyc + {29'd0, cluster_stall_inc};
        end
    end

    // ============================================================
    // 增强计数器
    // ============================================================

    // compute_cycles: 计算阶段期间为高（FEED_ACT/DRAIN/COLLECT）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            comp_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            comp_cyc <= (!freeze && compute_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && compute_active)
                comp_cyc <= comp_cyc + 32'd1;
        end
    end

    // load_cycles: LOAD状态期间为高（act DMA, wgt DMA, LOAD_ARRAY等）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            load_cyc <= (!freeze && load_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && load_active)
                load_cyc <= load_cyc + 32'd1;
        end
    end

    // store_cycles: STORE状态期间为高
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            store_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            store_cyc <= (!freeze && store_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && store_active)
                store_cyc <= store_cyc + 32'd1;
        end
    end

    // collect_cycles: 专门在COLLECT阶段期间为高
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            coll_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            coll_cyc <= (!freeze && collect_active) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && collect_active)
                coll_cyc <= coll_cyc + 32'd1;
        end
    end

    // read_valid_bytes: 累积读拍的实际有效载荷字节数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_valid_bytes <= 32'h0;
        end else if (task_start_pulse) begin
            rd_valid_bytes <= (!freeze && read_beat) ? {26'd0, read_byte_cnt} : 32'd0;
        end else if (task_active) begin
            if (!freeze && read_beat)
                rd_valid_bytes <= rd_valid_bytes + {26'd0, read_byte_cnt};
        end
    end

    // write_valid_bytes: 累积写拍的实际有效载荷字节数（基于WSTRB）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_valid_bytes <= 32'h0;
        end else if (task_start_pulse) begin
            wr_valid_bytes <= (!freeze && write_beat) ? {26'd0, write_byte_cnt} : 32'd0;
        end else if (task_active) begin
            if (!freeze && write_beat)
                wr_valid_bytes <= wr_valid_bytes + {26'd0, write_byte_cnt};
        end
    end

    // mac_count: 累积实际MAC操作数
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {mac_cnt_hi, mac_cnt_lo} <= 64'h0;
        end else if (task_start_pulse) begin
            {mac_cnt_hi, mac_cnt_lo} <= (!freeze && mac_count_valid) ?
                {48'd0, mac_count_add} : 64'h0;
        end else if (task_active) begin
            if (!freeze && mac_count_valid)
                {mac_cnt_hi, mac_cnt_lo} <= {mac_cnt_hi, mac_cnt_lo} + {48'd0, mac_count_add};
        end
    end

    // stall_act_cycles: 等待激活数据
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_act_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_act_cyc <= (!freeze && stall_act) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_act)
                s_act_cyc <= s_act_cyc + 32'd1;
        end
    end

    // stall_wgt_cycles: 等待权重数据
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_wgt_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_wgt_cyc <= (!freeze && stall_wgt) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_wgt)
                s_wgt_cyc <= s_wgt_cyc + 32'd1;
        end
    end

    // stall_acc_cycles: 等待acc缓冲区
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_acc_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_acc_cyc <= (!freeze && stall_acc) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_acc)
                s_acc_cyc <= s_acc_cyc + 32'd1;
        end
    end

    // stall_store_cycles: 等待store/FIFO
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_store_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            s_store_cyc <= (!freeze && stall_store) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && stall_store)
                s_store_cyc <= s_store_cyc + 32'd1;
        end
    end

    // array_fill_drain_cycles: 阵列正在填充/排空（非稳态）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fill_drain_cyc <= 32'h0;
        end else if (task_start_pulse) begin
            fill_drain_cyc <= (!freeze && array_fill_drain) ? 32'd1 : 32'd0;
        end else if (task_active) begin
            if (!freeze && array_fill_drain)
                fill_drain_cyc <= fill_drain_cyc + 32'd1;
        end
    end

    // ============================================================
    // 输出赋值
    // ============================================================
    assign total_cycle_lo    = cycle_lo;
    assign total_cycle_hi    = cycle_hi;
    assign read_beat_count   = read_beats;
    assign write_beat_count  = write_beats;
    assign read_active_cycles  = rd_active_cyc;
    assign write_active_cycles = wr_active_cyc;
    assign array_active_cycles = arr_active_cyc;
    assign array_stall_cycles  = arr_stall_cyc;
    assign cluster_active_cycles = cl_active_cyc;
    assign cluster_stall_cycles  = cl_stall_cyc;
    assign write_data_cycles     = wr_data_cyc;
    assign write_txn_cycles      = wr_txn_cyc;
    assign ar_handshake_cycles   = ar_cyc;
    assign aw_handshake_cycles   = aw_cyc;
    assign b_handshake_cycles    = b_cyc;
    assign bus_active_cycles     = bus_cyc;

    // 增强输出
    assign compute_cycles        = comp_cyc;
    assign load_cycles           = load_cyc;
    assign store_cycles          = store_cyc;
    assign collect_cycles        = coll_cyc;
    assign read_valid_bytes      = rd_valid_bytes;
    assign write_valid_bytes     = wr_valid_bytes;
    assign mac_count_lo          = mac_cnt_lo;
    assign mac_count_hi          = mac_cnt_hi;
    assign stall_act_cycles      = s_act_cyc;
    assign stall_wgt_cycles      = s_wgt_cyc;
    assign stall_acc_cycles      = s_acc_cyc;
    assign stall_store_cycles    = s_store_cyc;
    assign array_fill_drain_cycles = fill_drain_cyc;

endmodule
