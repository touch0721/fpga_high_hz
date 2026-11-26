`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : t1_monitor   (200MHz + TDC, compare0 -> compare1)
// Description : 时间间隔测量
//               compare0 上升沿 = START
//               compare1 上升沿 = STOP
//
//   200MHz 粗计数 + 两条 CARRY4 延迟线做 TDC 插值。
//
//   输出 64 位，按 32/32 分割：
//     t1_data[63:32] = 粗计数（整数拍，每拍 5 ns），不足 32 位高位补 0
//     t1_data[31:0]  = TDC 小数（ps，0~4999），不足 32 位高位补 0
//
//   MCU 换算：T_ps = t1_data[63:32] * 5000 + t1_data[31:0]
//
//   注意：
//   1) CARRY4 链要加 keep / 连续进位链约束；
//   2) TAPS 要保证 > 5ns（快角），默认 384；
//   3) tau_ps 由码密度法标定后写入；
//   4) 假设 compare0 先到、compare1 后到；反向时结果按 0 处理。
//   5) 100 ms = 2e7 拍，粗计数 32 位够用。
//////////////////////////////////////////////////////////////////////////////////
module t1_monitor(
    input  wire        clk_200m,     // 200MHz 粗计数/TDC 采样
    input  wire        clk_50m,
    input  wire        resetn,       // 异步复位，低有效
    input  wire        compare0,     // START：上升沿
    input  wire        compare1,     // STOP ：上升沿
    input  wire [15:0] tau_ps,       // 标定值：每抽头延迟（ps）
    input  wire        t1_vaild,     // 50MHz 域 ack
    output reg  [63:0] t1_data,      // [63:32] 整数拍，[31:0] TDC ps
    output reg         t1_last
);
    localparam integer TAPS = 384;
    localparam integer G = TAPS/8;
    localparam [5:0]   LAST_MIN_HOLD = 6'd32;

    //==================================================================
    // TDC 延迟线：compare0 / compare1 各驱动一条 CARRY4 链
    //==================================================================
    wire [TAPS-1:0] tap_a, tap_b;
    wire [TAPS:0]   cy_a, cy_b;
    assign cy_a[0] = 1'b0;
    assign cy_b[0] = 1'b0;

    genvar gi;
    generate
    for (gi = 0; gi < TAPS/4; gi = gi + 1) begin : g_tdc
        wire [3:0] co_a, co_b;

        CARRY4 ua (
            .CO     (co_a),
            .DI     (4'b0000),
            .S      (4'b1111),
            .CYINIT ((gi == 0) ? compare0 : 1'b0),
            .CI     (cy_a[gi*4])
        );
        CARRY4 ub (
            .CO     (co_b),
            .DI     (4'b0000),
            .S      (4'b1111),
            .CYINIT ((gi == 0) ? compare1 : 1'b0),
            .CI     (cy_b[gi*4])
        );

        assign cy_a[gi*4 + 4] = co_a[3];
        assign cy_b[gi*4 + 4] = co_b[3];
        assign tap_a[gi*4 +: 4] = co_a;
        assign tap_b[gi*4 +: 4] = co_b;
    end
    endgenerate




    //==================================================================
    // 200MHz 采样抽头
    //==================================================================
    reg [TAPS-1:0] samp_a, samp_b;
    always@ (posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            samp_a <= {TAPS{1'b0}};
            samp_b <= {TAPS{1'b0}};
        end else begin
            samp_a <= tap_a;
            samp_b <= tap_b;
        end
    end

    //==================================================================
    // 粗计数
    //==================================================================
    reg [31:0] coarse;
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) coarse <= 32'd0;
        else         coarse <= coarse + 32'd1;
    end

    //==================================================================
    // 两个输入各自 2FF + 上升沿
    //==================================================================
    reg c0_s1, c0_s2;
    reg c1_s1, c1_s2;
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            c0_s1 <= 1'b0;
            c0_s2 <= 1'b0;
            c1_s1 <= 1'b0;
            c1_s2 <= 1'b0;
        end else begin
            c0_s1 <= compare0;
            c0_s2 <= c0_s1;
            c1_s1 <= compare1;
            c1_s2 <= c1_s1;
        end
    end
    wire start_evt = c0_s1 & ~c0_s2;    // compare0 上升沿
    wire stop_evt  = c1_s1 & ~c1_s2;    // compare1 上升沿

    //==================================================================
    // 2 级流水 popcount
    //==================================================================
    reg [TAPS-1:0] samp_f;
    reg [3:0]      pc1 [0:G-1];
    reg [8:0]      pc2;
    reg [2:0]      pstate;
    reg            psrc;          // 0=start, 1=stop

    reg [31:0] c1_lat, c2_lat;
    reg [8:0]  k1_lat, k2_lat;
    reg        start_seen;

    reg [63:0] t_meas;
    reg        meas_tog;

    integer ip;
    integer is;
    reg [8:0] pc_sum;
    always@(*) begin
        pc_sum = 9'd0;
        for (is = 0; is < G; is = is + 1)
            pc_sum = pc_sum + pc1[is];
    end

    // 片上拆分
    wire [31:0] dc_cnt = c2_lat - c1_lat;
    wire signed [11:0] dk = $signed({3'b0, k1_lat}) - $signed({3'b0, k2_lat});
    reg  [31:0] p_dc;             // 粗计数（整数拍）
    reg signed [31:0] p_fr;       // TDC 小数（ps，可正可负）

    always@ (posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            samp_f     <= {TAPS{1'b0}};
            for (ip = 0; ip < G; ip = ip + 1)
                pc1[ip] <= 4'd0;
            pc2        <= 9'd0;
            pstate     <= 3'd0;
            psrc       <= 1'b0;
            c1_lat     <= 32'd0;
            c2_lat     <= 32'd0;
            k1_lat     <= 9'd0;
            k2_lat     <= 9'd0;
            start_seen <= 1'b0;
            p_dc       <= 32'd0;
            p_fr       <= 32'sd0;
            t_meas     <= 64'd0;
            meas_tog   <= 1'b0;
        end else begin
            case (pstate)

            //---- 空闲：抓 START / STOP ----
            3'd0: begin
                if (start_evt) begin
                    samp_f <= samp_a;
                    c1_lat <= coarse;
                    psrc   <= 1'b0;
                    pstate <= 3'd1;
                end else if (stop_evt && start_seen) begin
                    samp_f <= samp_b;
                    c2_lat <= coarse;
                    psrc   <= 1'b1;
                    pstate <= 3'd1;
                end
            end

            //---- popcount 第 1 级：8 bit 分组 ----
            3'd1: begin
                for (ip = 0; ip < G; ip = ip + 1)
                    pc1[ip] <= samp_f[8*ip]   + samp_f[8*ip+1] + samp_f[8*ip+2] + samp_f[8*ip+3]
                             + samp_f[8*ip+4] + samp_f[8*ip+5] + samp_f[8*ip+6] + samp_f[8*ip+7];
                pstate <= 3'd2;
            end

            //---- popcount 第 2 级 ----
            3'd2: begin
                pc2    <= pc_sum;
                pstate <= 3'd3;
            end

            //---- 取 K ----
            3'd3: begin
                if (psrc == 1'b0) begin
                    k1_lat     <= pc2;
                    start_seen <= 1'b1;
                    pstate     <= 3'd0;
                end else begin
                    k2_lat <= pc2;
                    pstate <= 3'd4;
                end
            end

            //---- 取粗计数与小数 ----
            3'd4: begin
                p_dc   <= dc_cnt;                          // 整数拍
                p_fr   <= dk * $signed({1'b0, tau_ps});    // ps，有符号
                pstate <= 3'd5;
            end

            //---- 打包：高 32 整数拍，低 32 TDC ps ----
            3'd5: begin
                if (p_fr >= 0) begin
                    t_meas <= {p_dc, p_fr[31:0]};
                end else begin
                    t_meas <= { (p_dc == 32'd0) ? 32'd0 : (p_dc - 32'd1),
                                (p_fr + 32'sd5000 < 0) ? 32'd0 : (p_fr + 32'sd5000) };
                end

                meas_tog   <= ~meas_tog;
                start_seen <= 1'b0;
                pstate     <= 3'd0;
            end

            default: pstate <= 3'd0;
            endcase
        end
    end

    //==================================================================
    // 输出握手（与 nx/n0 相同的 4 相），t1_data 为 64 位打包值
    //==================================================================
    localparam [1:0] S_IDLE = 2'd0,
                     S_LAST = 2'd1,
                     S_TRAN = 2'd2,
                     S_CLR  = 2'd3;

    reg [1:0]  state;
    reg        meas_tog_seen;
    reg [63:0] data_int;
    reg        data_vld_int;
    reg        busy;
    reg [5:0]  last_hold;

    reg [63:0] data_s1;
    reg        last_s1;

    (* ASYNC_REG = "TRUE" *) reg vld_s1, vld_s2;

    always@(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            state         <= S_IDLE;
            meas_tog_seen <= 1'b0;
            data_int      <= 64'd0;
            data_vld_int  <= 1'b0;
            busy          <= 1'b0;
        end else begin
            case (state)

            S_IDLE: begin
                if (meas_tog != meas_tog_seen) begin
                    meas_tog_seen <= meas_tog;
                    data_int      <= t_meas;      // 64 位打包值
                    data_vld_int  <= 1'b1;
                    state         <= S_LAST;
                end
            end

            S_LAST: begin
                if (t1_last && vld_s2) begin
                    busy  <= 1'b1;
                    state <= S_TRAN;
                end
            end

            S_TRAN: begin
                if (busy && !vld_s2 && (last_hold == LAST_MIN_HOLD)) begin
                    busy         <= 1'b0;
                    data_vld_int <= 1'b0;
                    state        <= S_CLR;
                end
            end

            S_CLR: begin
                if (!t1_last)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    //==================================================================
    // t1_last 最小保持
    //==================================================================
    always@(posedge clk_200m or negedge resetn) begin
        if (!resetn)
            last_hold <= 6'd0;
        else if (t1_last) begin
            if (last_hold != LAST_MIN_HOLD)
                last_hold <= last_hold + 1'b1;
        end else
            last_hold <= 6'd0;
    end

    //==================================================================
    // 输出二级缓存：t1_data 与 t1_last 同拍对齐
    //==================================================================
    always@ (posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            data_s1 <= 64'd0;
            last_s1 <= 1'b0;
            t1_data <= 64'd0;
            t1_last <= 1'b0;
        end else begin
            data_s1 <= data_int;
            last_s1 <= data_vld_int;

            t1_data <= data_s1;
            t1_last <= last_s1;
        end
    end

    //==================================================================
    // 50MHz ack 同步
    //==================================================================
    always@(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            vld_s1 <= 1'b0;
            vld_s2 <= 1'b0;
        end else begin
            vld_s1 <= t1_vaild;
            vld_s2 <= vld_s1;
        end
    end
    
    
    
    
    
    
    
    
    
    
    
//    ila_0 u_ila (
//    .clk    (clk_200m),                 // 想看 t1 内部，建议改 clk_200m
//    .probe0 (compare0),                // 1
//    .probe1 (compare1),                // 1
//    .probe2 (t1_last),                 // 1
//    .probe3 (c1_lat),             // 32
//    .probe4 (c2_lat),             // 32
//    .probe5 (pstate)              // 3
//);
    
    
    
    
    
    
    
    

endmodule