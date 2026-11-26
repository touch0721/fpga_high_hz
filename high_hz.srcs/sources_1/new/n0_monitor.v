`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : n0_monitor
// Description : 测量 compare0 相邻两个上升沿之间的时钟周期数，以握手方式送出数据
//
//   v2 结构（测量 / 输出 完全解耦）：
//     - 测量通路：compare0 每个上升沿都把 cnt 刷进 period_latch 并翻转 period_tog，
//                 永不因握手而停顿 -- 保证"每次测量都是严格相邻两沿"
//     - 输出通路：FSM 只负责把 period_latch 搬到 n0_data 并做握手，
//                 握手慢就少送样本（丢样本），绝不会把周期数算错
//
//   为什么必须这样改：
//     旧版 FSM 在 S_MEAS 锁存后要停 S_LAST/S_TRAN 等握手，死区约 1000+ 拍；
//     输入周期 372 拍时，死区是周期的 3 倍，读数就被夹在
//     "372（1 个周期）" 和 "1500（1 个周期 + 死区）" 之间跳，且两者都错。
//
//   握手约定（400MHz 域视角）：
//     S_IDLE : 有新测量就装载 → S_LAST
//     S_LAST : n0_last 已拉高，等 valid 拉高（握手成功）
//     S_TRAN : busy=1，等 valid 拉低（且 n0_last 已保持够 LAST_MIN_HOLD）
//     S_CLR  : 等 n0_last 真正落低，再回 S_IDLE（保证帧间有干净的低电平）
//////////////////////////////////////////////////////////////////////////////////

module n0_monitor(
    input  wire        clk_400m,     // 主时钟（400MHz / 300MHz 均可，频率决定量纲）
    input  wire        resetn,       // 异步复位，低有效
    input  wire        compare0,     // 被测信号（异步）
    input  wire        valid,        // 50MHz 域握手响应（原 togo）
    output reg  [28:0] n0_data,      // 测量结果：compare0 相邻上升沿之间的时钟数
    output reg         n0_last       // 数据有效 / 握手标志（原 monitor_busy）
);

    //============================== 状态编码 ==============================
    localparam [1:0] S_IDLE = 2'd0,  // 等新测量结果
                     S_LAST = 2'd1,  // n0_last 已拉高，等 valid
                     S_TRAN = 2'd2,  // 握手成功，数据传输中，等 valid 拉低
                     S_CLR  = 2'd3;  // 等 n0_last 落低

    /* n0_last 最小高电平保持：32 拍 @300MHz = 106ns，@400MHz = 80ns
       保证 50MHz 侧两级同步（40ns）之后一定采得到，不会被削成窄脉冲 */
    localparam [5:0] LAST_MIN_HOLD = 6'd32;

    reg [1:0] state;

    //====================== compare0 同步 / 上升沿 ========================
    (* ASYNC_REG = "TRUE" *) reg compare0_s1;
    (* ASYNC_REG = "TRUE" *) reg compare0_s2;
    reg  compare0_s3;
    reg  compare0_sign;              // 注册后的上升沿脉冲（1 拍宽）

    //====================== valid 同步（50M -> 本域）======================
    (* ASYNC_REG = "TRUE" *) reg valid_s1;
    (* ASYNC_REG = "TRUE" *) reg valid_s2;

    //====================== 测量计数器（15+14 拆分）=======================
    // cnt_l 是 15 位，满值即 15'h7FFF，所以该进位条件是正确的
    reg  [14:0] cnt_l;
    reg  [13:0] cnt_h;

    reg  [28:0] period_latch;        // 最新一次完整测量
    reg         period_tog;          // 每产生一次新测量就翻转
    reg         period_tog_seen;     // FSM 已消费到的位置

    //======================== 输出 / 握手内部状态 =========================
    reg  [28:0] data_int;
    reg         data_vld_int;
    reg         busy;
    reg  [5:0]  last_hold;           // n0_last 连续高的拍数（饱和）

    //============================ 输出二级缓存 ============================
    reg  [28:0] data_s1;
    reg         last_s1;

    //======================================================================
    // 输入同步：compare0 2FF + 边沿；valid 2FF
    //======================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            compare0_s1   <= 1'b0;
            compare0_s2   <= 1'b0;
            compare0_s3   <= 1'b0;
            compare0_sign <= 1'b0;
            valid_s1      <= 1'b0;
            valid_s2      <= 1'b0;
        end else begin
            compare0_s1   <= compare0;
            compare0_s2   <= compare0_s1;
            compare0_s3   <= compare0_s2;
            compare0_sign <= compare0_s2 & ~compare0_s3;

            valid_s1 <= valid;       // 50M -> 本域 2FF
            valid_s2 <= valid_s1;
        end
    end

    //======================================================================
    // 测量通路：自由跑，每个上升沿都刷新一次结果，永不停顿
    //   period_latch / period_tog 在同一拍更新，FSM 侧读到的组合是一致的
    //======================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            cnt_l        <= 15'd0;
            cnt_h        <= 14'd0;
            period_latch <= 29'd0;
            period_tog   <= 1'b0;
        end else if (compare0_sign) begin
            period_latch <= {cnt_h, cnt_l};   // 上一沿到本沿的时钟数
            period_tog   <= ~period_tog;
            cnt_l        <= 15'd1;
            cnt_h        <= 14'd0;
        end else begin
            cnt_l <= cnt_l + 15'd1;
            if (cnt_l == 15'h7FFF)            // 低位满，进高位
                cnt_h <= cnt_h + 14'd1;
        end
    end

    //======================================================================
    // 输出通路：只搬运 + 握手，不影响上面的计数
    //======================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            state           <= S_IDLE;
            period_tog_seen <= 1'b0;
            data_int        <= 29'd0;
            data_vld_int    <= 1'b0;
            busy            <= 1'b0;
        end else begin
            case (state)

            //-------- 有新测量就装载；没有就干等，不干扰计数 --------
            S_IDLE: begin
                if (period_tog != period_tog_seen) begin
                    period_tog_seen <= period_tog;
                    data_int        <= period_latch;   // 只取"最新值"
                    data_vld_int    <= 1'b1;           // 2 拍后 n0_last 拉高
                    state           <= S_LAST;
                end
            end

            //-------- 等 50M 域握手（可在 2 拍后 n0_last 拉高时被采到）----
            S_LAST: begin
                if (n0_last && valid_s2) begin
                    busy  <= 1'b1;
                    state <= S_TRAN;
                end
            end

            //-------- 传输中：valid 拉低后收尾，且 n0_last 已保持够宽 --------
            S_TRAN: begin
                if (busy && !valid_s2 && (last_hold == LAST_MIN_HOLD)) begin
                    busy         <= 1'b0;
                    data_vld_int <= 1'b0;              // 2 拍后 n0_last 拉低
                    state        <= S_CLR;
                end
            end

            //-------- 等 n0_last 真正落低，保证下一帧有干净的上升沿 --------
            S_CLR: begin
                if (!n0_last)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    //======================================================================
    // n0_last 高电平计时（饱和），用于最小保持宽度
    //======================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn)
            last_hold <= 6'd0;
        else if (n0_last) begin
            if (last_hold != LAST_MIN_HOLD)
                last_hold <= last_hold + 1'b1;
        end else
            last_hold <= 6'd0;
    end

    //======================================================================
    // 输出二级缓存：data_int -> data_s1 -> n0_data
    //               data_vld_int -> last_s1 -> n0_last
    //   n0_data 与 n0_last 严格同拍建立，且全程稳定（测量通路不会在
    //   握手期间改写 data_int），50MHz 侧用同步后的 last 作使能即可采样
    //======================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            data_s1 <= 29'd0;
            last_s1 <= 1'b0;
            n0_data <= 29'd0;
            n0_last <= 1'b0;
        end else begin
            data_s1 <= data_int;
            last_s1 <= data_vld_int;
            n0_data <= data_s1;
            n0_last <= last_s1;
        end
    end

endmodule
