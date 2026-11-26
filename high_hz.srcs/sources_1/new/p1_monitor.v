`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : p1_monitor  (单输入占空比测量, 200MHz + 双 TDC)
//
//   compare0 方波：
//     上升沿1 -> 下降沿 -> 上升沿2
//     高电平 H = H_c*5000 + (k1-k2)*tau
//     周期   P = P_c*5000 + (k1-k3)*tau
//     占空比 = H / P                     （除法在 MCU 做）
//
//   输出 96 位（发相对值，高位置 0）：
//     p1_data[31:0]  = H_c = c2 - c1     （28 位有效，高位补 0）
//     p1_data[63:32] = P_c = c3 - c1     （28 位有效，高位补 0）
//     p1_data[79:64] = {6'd0, d_h}       （d_h = k1-k2，低 10 位补码）
//     p1_data[95:80] = {6'd0, d_p}       （d_p = k1-k3，低 10 位补码）
//
//   MCU 换算：
//     H = H_c*5000 + d_h*tau
//     P = P_c*5000 + d_p*tau
//     duty = H / P
//
//   注意：
//   1) CARRY4 链要加 keep / 连续进位链约束；
//   2) TAPS*τ 要大于 5 ns（200MHz 周期），默认 384；
//   3) 本模块只做减法，不做乘法、不做除法；
//   4) d_h/d_p 是 10 位补码，MCU 需掩 0x03FF 后按 bit9 扩展符号。
//////////////////////////////////////////////////////////////////////////////////
module p1_monitor(
    input  wire        clk_200m,     // 200MHz
    input  wire        resetn,       // 异步复位，低有效
    input  wire        compare0,     // 被测方波
    input  wire        p1_vaild,     // 50MHz 域 ack
    output reg  [95:0] p1_data,      // {d_p, d_h, P_c, H_c}
    output reg         p1_last
);

    localparam integer G = 48;
    localparam integer TAPS = 384;
    localparam [5:0]   LAST_MIN_HOLD = 6'd32;

    //==================================================================
    // TDC 两条链：A 由 compare0 上升沿启动，B 由 compare0 下降沿启动
    //==================================================================
    wire [TAPS-1:0] tap_a, tap_b;
    wire [TAPS:0]   cy_a, cy_b;
    assign cy_a[0] = 1'b0;
    assign cy_b[0] = 1'b0;

    genvar gi;
    generate
    for (gi = 0; gi < 96; gi = gi + 1) begin : g_tdc
        wire [3:0] co_a, co_b;

        CARRY4 ua (
            .CO     (co_a),
            .DI     (4'b0000),
            .S      (4'b1111),
            .CYINIT ((gi == 0) ? compare0  : 1'b0),
            .CI     (cy_a[gi*4])
        );
        CARRY4 ub (
            .CO     (co_b),
            .DI     (4'b0000),
            .S      (4'b1111),
            .CYINIT ((gi == 0) ? ~compare0 : 1'b0),
            .CI     (cy_b[gi*4])
        );

        assign cy_a[gi*4 + 4] = co_a[3];
        assign cy_b[gi*4 + 4] = co_b[3];
        assign tap_a[gi*4 +: 4] = co_a;
        assign tap_b[gi*4 +: 4] = co_b;
    end
    endgenerate

    //==================================================================
    // 200MHz 采样
    //==================================================================
    reg [TAPS-1:0] samp_a, samp_b;
    always @(posedge clk_200m or negedge resetn) begin
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
    // 边沿检测
    //==================================================================
    reg c0_s1, c0_s2;
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            c0_s1 <= 1'b0;
            c0_s2 <= 1'b0;
        end else begin
            c0_s1 <= compare0;
            c0_s2 <= c0_s1;
        end
    end
    wire rise_evt =  c0_s1 & ~c0_s2;
    wire fall_evt = ~c0_s1 &  c0_s2;

    //==================================================================
    // 三边沿捕获：上升1 -> 下降 -> 上升2
    //==================================================================
    reg [TAPS-1:0] sr1, sf, sr2;
    reg [31:0]     c1, c2, c3;
    reg [2:0]      st;          // 0=等上升1, 1=等下降, 2=等上升2, 3=处理

    reg [95:0] meas;
    reg        meas_tog;

    //==================================================================
    // popcount 流水（3 个样本依次处理）
    //==================================================================
    reg [TAPS-1:0] samp_mux;
    reg [3:0]      pc1 [0:G-1];
    reg [8:0]      pc2;
    reg [3:0]      pst;         // 0..10
    reg [8:0]      k1, k2, k3;

    integer ip, is;
    reg [8:0] pc_sum;
    always @(*) begin
        pc_sum = 9'd0;
        for (is = 0; is < G; is = is + 1)
            pc_sum = pc_sum + pc1[is];
    end

    // 组合量：粗计数差值 + K 差值
    wire signed [9:0] d_h_w = $signed({1'b0, k1}) - $signed({1'b0, k2});
    wire signed [9:0] d_p_w = $signed({1'b0, k1}) - $signed({1'b0, k3});
    wire [31:0]       H_c_w = c2 - c1;
    wire [31:0]       P_c_w = c3 - c1;

    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            st       <= 3'd0;
            sr1      <= {TAPS{1'b0}};
            sf       <= {TAPS{1'b0}};
            sr2      <= {TAPS{1'b0}};
            c1       <= 32'd0;
            c2       <= 32'd0;
            c3       <= 32'd0;
            pst      <= 4'd0;
            samp_mux <= {TAPS{1'b0}};
            k1       <= 9'd0;
            k2       <= 9'd0;
            k3       <= 9'd0;
            meas     <= 96'd0;
            meas_tog <= 1'b0;
            for (ip = 0; ip < G; ip = ip + 1)
                pc1[ip] <= 4'd0;
        end else begin

            //---------------- 边沿捕获 ----------------
            case (st)
            3'd0: if (rise_evt) begin
                      sr1 <= samp_a;      // 上升沿第一拍采样
                      c1  <= coarse;
                      st  <= 3'd1;
                  end
            3'd1: if (fall_evt) begin
                      sf  <= samp_b;      // 下降沿第一拍采样
                      c2  <= coarse;
                      st  <= 3'd2;
                  end
            3'd2: if (rise_evt) begin
                      sr2 <= samp_a;
                      c3  <= coarse;
                      st  <= 3'd3;
                  end
            3'd3: if (pst == 4'd10)
                      st <= 3'd0;
            default: st <= 3'd0;
            endcase

            //---------------- 三个样本依次 popcount ----------------
            if (st == 3'd3) begin
                case (pst)
                4'd0: begin
                    samp_mux <= sr1;
                    pst      <= 4'd1;
                end
                4'd1: begin
                    for (ip = 0; ip < G; ip = ip + 1)
                        pc1[ip] <= samp_mux[8*ip]   + samp_mux[8*ip+1] + samp_mux[8*ip+2] + samp_mux[8*ip+3]
                                 + samp_mux[8*ip+4] + samp_mux[8*ip+5] + samp_mux[8*ip+6] + samp_mux[8*ip+7];
                    pst <= 4'd2;
                end
                4'd2: begin
                    pc2 <= pc_sum;
                    pst <= 4'd3;
                end
                4'd3: begin
                    k1       <= pc2;
                    samp_mux <= sf;
                    pst      <= 4'd4;
                end
                4'd4: begin
                    for (ip = 0; ip < G; ip = ip + 1)
                        pc1[ip] <= samp_mux[8*ip]   + samp_mux[8*ip+1] + samp_mux[8*ip+2] + samp_mux[8*ip+3]
                                 + samp_mux[8*ip+4] + samp_mux[8*ip+5] + samp_mux[8*ip+6] + samp_mux[8*ip+7];
                    pst <= 4'd5;
                end
                4'd5: begin
                    pc2 <= pc_sum;
                    pst <= 4'd6;
                end
                4'd6: begin
                    k2       <= pc2;
                    samp_mux <= sr2;
                    pst      <= 4'd7;
                end
                4'd7: begin
                    for (ip = 0; ip < G; ip = ip + 1)
                        pc1[ip] <= samp_mux[8*ip]   + samp_mux[8*ip+1] + samp_mux[8*ip+2] + samp_mux[8*ip+3]
                                 + samp_mux[8*ip+4] + samp_mux[8*ip+5] + samp_mux[8*ip+6] + samp_mux[8*ip+7];
                    pst <= 4'd8;
                end
                4'd8: begin
                    pc2 <= pc_sum;
                    pst <= 4'd9;
                end
                4'd9: begin
                    k3  <= pc2;
                    pst <= 4'd10;
                end
                4'd10: begin
                    // {6'd0, d_p, 6'd0, d_h, P_c, H_c}
                    meas     <= {6'd0, d_p_w,
                                 6'd0, d_h_w,
                                 P_c_w, H_c_w};
                    meas_tog <= ~meas_tog;
                    pst      <= 4'd0;
                end
                default: pst <= 4'd0;
                endcase
            end
        end
    end

    //==================================================================
    // 输出握手（与 t1 相同的 4 相）
    //==================================================================
    localparam [1:0] S_IDLE = 2'd0,
                     S_LAST = 2'd1,
                     S_TRAN = 2'd2,
                     S_CLR  = 2'd3;

    reg [1:0]  state;
    reg        meas_tog_seen;
    reg [95:0] data_int;
    reg        data_vld_int;
    reg        busy;
    reg [5:0]  last_hold;

    reg [95:0] data_s1;
    reg        last_s1;

    (* ASYNC_REG = "TRUE" *) reg vld_s1, vld_s2;

    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            state         <= S_IDLE;
            meas_tog_seen <= 1'b0;
            data_int      <= 96'd0;
            data_vld_int  <= 1'b0;
            busy          <= 1'b0;
        end else begin
            case (state)

            S_IDLE: begin
                if (meas_tog != meas_tog_seen) begin
                    meas_tog_seen <= meas_tog;
                    data_int      <= meas;
                    data_vld_int  <= 1'b1;
                    state         <= S_LAST;
                end
            end

            S_LAST: begin
                if (p1_last && vld_s2) begin
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
                if (!p1_last)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    //==================================================================
    // p1_last 最小保持
    //==================================================================
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn)
            last_hold <= 6'd0;
        else if (p1_last) begin
            if (last_hold != LAST_MIN_HOLD)
                last_hold <= last_hold + 1'b1;
        end else
            last_hold <= 6'd0;
    end

    //==================================================================
    // 输出二级缓存
    //==================================================================
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            data_s1 <= 96'd0;
            last_s1 <= 1'b0;
            p1_data <= 96'd0;
            p1_last <= 1'b0;
        end else begin
            data_s1 <= data_int;
            last_s1 <= data_vld_int;

            p1_data <= data_s1;
            p1_last <= last_s1;
        end
    end

    //==================================================================
    // 50MHz ack 同步
    //==================================================================
    always @(posedge clk_200m or negedge resetn) begin
        if (!resetn) begin
            vld_s1 <= 1'b0;
            vld_s2 <= 1'b0;
        end else begin
            vld_s1 <= p1_vaild;
            vld_s2 <= vld_s1;
        end
    end

endmodule