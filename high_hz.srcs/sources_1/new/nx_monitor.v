`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : nx_monitor
// Description : nx 频率测量（门控计数）+ 数据 / last 分离的握手输出
//
// 本版针对原 nx_monitor 的关键问题做了修正：
//   1. 去掉 load_en 中的 ~vld_s2。原代码在 nx_vaild 空闲为高时会永久锁死，
//      导致 nx_last 永远拉不起来。
//   2. 不使用单比特 result_tog 判断"有没有新结果"。等待握手期间如果跨过
//      偶数个窗口，result_tog 会翻回原值，new_result 变 0，同样导致 last
//      不再拉起。本版改用 result_pending 电平标志。
//   3. last 拉高后至少保持 HOLD_CYCLES 个 400M 周期（80 ns，约 4 个 50M
//      周期），保证 50M 侧两级同步器一定能采到；如果 vaild 在 last 之前
//      已经是高电平，也不会出现 last 只高 1 拍、50M 侧完全看不到的情况。
//   4. last 只在"已经看到 ack，且保持时间到"后拉低；没有 ack 时 last
//      一直保持，不会自己拉低。拉低后等 ack 回低，再允许下一帧。
//   5. 数据先装进 nx_data，下一拍才拉高 last；last 为高期间 nx_data 和
//      result_latch 都冻结。last 拉低后才 meas_locked 清零，允许下一次
//      测量结果更新。
//
// 握手时序（标准 4-phase）：
//   IDLE     : 有 pending 结果且当前没有 win_tick -> nx_data <= result_latch
//   ASSERT   : nx_last <= 1（数据已经稳定一拍）
//   WAIT_ACK : 保持 last；等 nx_vaild 同步后为高，并等够 HOLD_CYCLES
//              条件满足 -> nx_last <= 0，解锁测量
//   WAIT_LOW : last 已低，等 nx_vaild 回低 -> 回 IDLE，允许下一帧
//
// 也就是：
//   last ↑ -> 50M 取数 -> vaild ↑ -> last ↓ -> 50M 释放 vaild ↓ -> 下一帧
//
// 关于"last 是否要等 vaild 拉低再拉低"：
//   标准 4-phase 是 last 看到 ack 后就拉低，然后等 ack 回低。若这里改成
//   "必须等 vaild 先拉低才允许 last 拉低"，当对端是"vaild 保持到 last
//   拉低"的从机时，两边会互等死锁。本版按标准 4-phase 实现；如果 50M
//   侧确实要求 last 必须晚于 vaild 拉低，需要两边一起改协议。
//
// 注意：
//   - nx_vaild 是 50M 域 ack。空闲为低，看到 last 后拉高，取数完成后拉低。
//     本版对"空闲为高"的情况也不会锁死 last 的拉起，但会等它回低后才发下一帧。
//   - 50M 侧仍建议用两级同步器同步 nx_last，并在 last 为高时锁存 nx_data。
//   - HOLD_CYCLES 是按 50M 周期 20 ns 估算的；如果 50M 时钟不同，请调整。
//////////////////////////////////////////////////////////////////////////////////

module nx_monitor(
    input  wire        clk_400m,     // 计数/输出域时钟
    input  wire        clk_50m,      // 门控域时钟，产生测量窗口
    input  wire        resetn,       // 异步复位，低有效
    input  wire        compare0,     // 被测信号（异步）
    input  wire        nx_vaild,     // 50MHz 域 ack：高表示本帧已被取走
    output reg  [26:0] nx_data,      // 测量结果：一个窗口内的上升沿个数
    output reg         nx_last       // 数据有效：装数后拉高，ack 后拉低
);

    //============================== 参数 ==============================
    /* 门控窗口终值（50MHz 域，窗口长度 = SEC_END+1 拍）
       49_999       -> 50_000 拍 = 1 ms
       49_999_999   -> 1.000 s（1 计数 = 1 Hz） */
    localparam [28:0] SEC_END = 29'd49_999_999;

    /* last 最小保持时间：32 拍 @400MHz = 80ns = 4 个 50M 周期。
       目的：即使 nx_vaild 在 last 之前就已经为高，也保证 50M 侧
       的两级同步器有足够时间看到 last。它只负责"最早何时允许拉低"，
       不负责"到点自动拉低"；没有 ack 时 last 仍会一直保持。 */
    localparam [5:0] HOLD_LAST = 6'd31;

    //====================== compare0 同步 / 边沿 ======================
    (* ASYNC_REG = "TRUE" *) reg c0_s1;
    (* ASYNC_REG = "TRUE" *) reg c0_s2;
    reg  c0_s3;
    reg  c0_sign;                    // 本域寄存后的上升沿脉冲（1 拍宽）

    //====================== nx_vaild 同步（50M -> 400M）===============
    (* ASYNC_REG = "TRUE" *) reg vld_s1;
    (* ASYNC_REG = "TRUE" *) reg vld_s2;

    //====================== 门控窗口产生（50M 域）====================
    reg [28:0] gate_cnt;
    reg        win_tog;              // 每到窗口终点翻转一次

    //====================== win_tog 同步 / 边沿（400M 域）============
    (* ASYNC_REG = "TRUE" *) reg wt_s1;
    (* ASYNC_REG = "TRUE" *) reg wt_s2;
    reg  wt_s3;
    wire win_tick = wt_s2 ^ wt_s3;   // 窗口终点：1 拍脉冲

    //====================== 测量通路 =================================
    reg [26:0] cnt;                  // 本窗口上升沿计数
    reg [26:0] result_latch;         // 最近一次完整窗口的结果
    reg        result_pending;       // 有尚未送出的结果
    reg        meas_locked;          // 1: 输出帧占用中，冻结 result_latch

    //====================== 输出握手状态机 ===========================
    localparam [1:0] S_IDLE     = 2'd0;
    localparam [1:0] S_ASSERT   = 2'd1;
    localparam [1:0] S_WAIT_ACK = 2'd2;
    localparam [1:0] S_WAIT_LOW = 2'd3;

    reg [1:0] state;
    reg [5:0] hold_cnt;
    reg       ack_seen;              // WAIT_ACK 期间见过 ack（兼容窄 ack 脉冲）

    wire load_start = (state == S_IDLE) && result_pending && !win_tick;
    wire hold_done  = (hold_cnt == HOLD_LAST);

    //==================================================================
    // 输入同步：compare0 3FF + 寄存边沿；nx_vaild 2FF
    //==================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            c0_s1   <= 1'b0;
            c0_s2   <= 1'b0;
            c0_s3   <= 1'b0;
            c0_sign <= 1'b0;
            vld_s1  <= 1'b0;
            vld_s2  <= 1'b0;
        end else begin
            c0_s1   <= compare0;
            c0_s2   <= c0_s1;
            c0_s3   <= c0_s2;
            c0_sign <= c0_s2 & ~c0_s3;   // 两个 FF 输出做与，组合路径极短

            vld_s1  <= nx_vaild;
            vld_s2  <= vld_s1;
        end
    end

    //==================================================================
    // 门控窗口产生（50M 域）：每 SEC_END+1 拍翻转 win_tog
    //==================================================================
    always @(posedge clk_50m or negedge resetn) begin
        if (!resetn) begin
            gate_cnt <= 29'd0;
            win_tog  <= 1'b0;
        end else if (gate_cnt == SEC_END) begin
            gate_cnt <= 29'd0;
            win_tog  <= ~win_tog;
        end else begin
            gate_cnt <= gate_cnt + 29'd1;
        end
    end

    //==================================================================
    // win_tog 同步到 400M 域 + 边沿检测
    //==================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            wt_s1 <= 1'b0;
            wt_s2 <= 1'b0;
            wt_s3 <= 1'b0;
        end else begin
            wt_s1 <= win_tog;
            wt_s2 <= wt_s1;
            wt_s3 <= wt_s2;
        end
    end

    //==================================================================
    // 测量通路：
    //   win_tick 时如果未被锁住，锁存本窗口结果并置 pending；
    //   无论是否锁住，cnt 都从下一窗口重新开始，保证窗口边界不漂。
    //   锁住期间的结果直接丢弃（不送旧数据，也不把多个窗口混在一起）。
    //==================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            cnt            <= 27'd0;
            result_latch   <= 27'd0;
            result_pending <= 1'b0;
        end else begin
            if (win_tick) begin
                if (!meas_locked) begin
                    result_latch   <= cnt;
                    result_pending <= 1'b1;
                end
                // 本拍 c0_sign 归下一窗口，不重不漏
                cnt <= c0_sign ? 27'd1 : 27'd0;
            end else begin
                if (c0_sign)
                    cnt <= cnt + 27'd1;

                // 输出状态机取走当前结果
                if (load_start)
                    result_pending <= 1'b0;
            end
        end
    end

    //==================================================================
    // 数据通路：只在 load_start 时拷贝一次；last 为高期间保持不变
    //==================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn)
            nx_data <= 27'd0;
        else if (load_start)
            nx_data <= result_latch;
    end

    //==================================================================
    // last / 握手状态机
    //   - 装数后下一拍拉高 last；
    //   - last 高期间只等 ack，不主动拉低；
    //   - 看到 ack 且保持时间到，才拉低 last；
    //   - last 低后等 ack 回低，再允许下一帧。
    //==================================================================
    always @(posedge clk_400m or negedge resetn) begin
        if (!resetn) begin
            state       <= S_IDLE;
            nx_last     <= 1'b0;
            hold_cnt    <= 6'd0;
            ack_seen    <= 1'b0;
            meas_locked <= 1'b0;
        end else begin
            case (state)

            //---------------- 空闲：装数，下一拍拉 last ----------------
            S_IDLE: begin
                nx_last     <= 1'b0;
                meas_locked <= 1'b0;

                if (load_start) begin
                    meas_locked <= 1'b1;   // 冻结 result_latch
                    hold_cnt    <= 6'd0;
                    ack_seen    <= 1'b0;
                    state       <= S_ASSERT;
                end
            end

            //---------------- 数据已稳定一拍，拉高 last ----------------
            S_ASSERT: begin
                nx_last  <= 1'b1;
                hold_cnt <= 6'd0;
                ack_seen <= 1'b0;
                state    <= S_WAIT_ACK;
            end

            //---------------- 保持 last，等 ack + 最小保持 --------------
            S_WAIT_ACK: begin
                nx_last <= 1'b1;

                if (vld_s2)
                    ack_seen <= 1'b1;

                if (!hold_done)
                    hold_cnt <= hold_cnt + 6'd1;

                // 只有"确实见过 ack"且"保持时间到"才允许拉低；
                // 没有 ack 时 last 永远保持，不会自己拉低。
                if (hold_done && (ack_seen || vld_s2)) begin
                    nx_last     <= 1'b0;
                    meas_locked <= 1'b0;  // last 低之后才解锁测量
                    state       <= S_WAIT_LOW;
                end
            end

            //---------------- last 已低，等 ack 回低后允许下一帧 ---------
            S_WAIT_LOW: begin
                nx_last <= 1'b0;

                if (!vld_s2)
                    state <= S_IDLE;
            end

            default: begin
                state       <= S_IDLE;
                nx_last     <= 1'b0;
                meas_locked <= 1'b0;
            end

            endcase
        end
    end

endmodule