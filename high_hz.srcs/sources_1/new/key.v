`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : key_func
// Description : 按键切换 func_mux
//   key 低有效，按下一次切换一次：
//     001 → 010 → 100 → 001 → …
//   50 MHz 时钟，20 ms 消抖，切换后的值锁存在 func_mux 寄存器里。
//////////////////////////////////////////////////////////////////////////////////
module key_func #(
    parameter integer DEBOUNCE_CNT = 20'd1_000_000   // 20 ms @ 50 MHz
)(
    input  wire       clk,          // 50 MHz
    input  wire       resetn,       // 异步复位，低有效
    input  wire       key,          // 按键，低有效
    output reg  [2:0] func_mux      // 001 / 010 / 100
);

    //==================================================================
    // 1) 异步输入打两拍
    //==================================================================
    (* ASYNC_REG = "TRUE" *) reg key_s1, key_s2;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            key_s1 <= 1'b1;
            key_s2 <= 1'b1;
        end else begin
            key_s1 <= key;
            key_s2 <= key_s1;
        end
    end

    //==================================================================
    // 2) 消抖：电平稳定 20 ms 才更新 key_stable
    //==================================================================
    reg        key_stable;
    reg [19:0] db_cnt;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            key_stable <= 1'b1;
            db_cnt     <= 20'd0;
        end else if (key_s2 != key_stable) begin
            if (db_cnt == DEBOUNCE_CNT - 1) begin
                key_stable <= key_s2;
                db_cnt     <= 20'd0;
            end else begin
                db_cnt <= db_cnt + 20'd1;
            end
        end else begin
            db_cnt <= 20'd0;
        end
    end

    //==================================================================
    // 3) 按下沿检测：key_stable 由 1 → 0 表示一次按下
    //==================================================================
    reg key_stable_d;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) key_stable_d <= 1'b1;
        else         key_stable_d <= key_stable;
    end

    wire press = key_stable_d & ~key_stable;   // 一次按下，1 拍脉冲

    //==================================================================
    // 4) 循环切换并锁存
    //==================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            func_mux <= 3'b001;
        end else if (press) begin
            case (func_mux)
                3'b001: func_mux <= 3'b010;
                3'b010: func_mux <= 3'b100;
                3'b100: func_mux <= 3'b001;
                default: func_mux <= 3'b001;
            endcase
        end
    end

endmodule