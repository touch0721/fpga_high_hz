`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : spi_byte
// Description : 单字节 SPI 移位发送（CPOL=1 / CPHA=1）
//
//   一个字节 8 bit，每 bit 占 4 个 clk（clk=800kHz 时 SCL=200kHz）：
//     ph=0 : SCL 拉低（下降沿），MOSI 在此更新为当前 bit
//     ph=1 : SCL 保持低
//     ph=2 : SCL 拉高（上升沿），从机在此采样
//     ph=3 : SCL 保持高，bit 序号 +1
//   即 MOSI 在 SCL 下降沿改变，上升沿前已稳定，并保持整整一位（4 个 clk）。
//
//   注意：spi_clk / spi_mosi / byte_end 全部是寄存器输出，
//   不再用“不完整 case”推断 latch，仿真波形与硬件一致。
//   byte_end 在 bit7 的上升沿那一拍拉高一拍（比字节结束提前一拍），
//   让上层在下一个下降沿到来前完成 byte_idx 切换（即 data_din 换字节）。
//////////////////////////////////////////////////////////////////////////////////

module spi_byte(
    input        clk,
    input        reset,        // 低有效
    input  [7:0] data_din,     // 当前要发送的字节
    input        to_go,        // 整帧保持高
    output reg   byte_end,     // 每字节一个 clk 宽度的脉冲
    output reg   spi_mosi,
    output reg   spi_clk,
    output       spi_cs
);

    assign spi_cs = !to_go;

    reg [1:0] ph;        // 一个 bit 内的相位 0..3
    reg [2:0] bit_idx;   // 0..7，0 表示 MSB

    wire [2:0] bit_sel = 3'd7 - bit_idx;

    always @(posedge clk or negedge reset) begin
        if (!reset) begin
            ph       <= 2'd0;
            bit_idx  <= 3'd0;
            spi_clk  <= 1'b1;
            spi_mosi <= 1'b1;
            byte_end <= 1'b0;
        end else if (to_go) begin
            byte_end <= 1'b0;                    // 默认低，只有 bit7 的 ph=2 拉高一拍

            case (ph)
            2'd0: begin
                spi_clk  <= 1'b0;                // 下降沿
                spi_mosi <= data_din[bit_sel];   // 数据随下降沿改变
                ph       <= 2'd1;
            end
            2'd1: begin
                spi_clk <= 1'b0;
                ph      <= 2'd2;
            end
            2'd2: begin
                spi_clk <= 1'b1;                 // 上升沿，从机采样
                ph      <= 2'd3;
                if (bit_idx == 3'd7)
                    byte_end <= 1'b1;            // 提前一拍通知上层换字节
            end
            2'd3: begin
                spi_clk <= 1'b1;
                ph      <= 2'd0;
                bit_idx <= (bit_idx == 3'd7) ? 3'd0 : (bit_idx + 3'd1);
            end
            endcase
        end else begin
            ph       <= 2'd0;
            bit_idx  <= 3'd0;
            spi_clk  <= 1'b1;
            spi_mosi <= 1'b1;
            byte_end <= 1'b0;
        end
    end

endmodule