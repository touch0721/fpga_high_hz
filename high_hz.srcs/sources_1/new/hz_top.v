`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/11/13 17:16:34
// Design Name: 
// Module Name: hz_top
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module hz_top(
input clk,
input resetn,


input compare0,
input compare1,
input key,


output spi_cs,
output spi_scl,       //spi _接口
output spi_mosi
    );

//reg compare1;

//wire  [2:0]func_mux= 3'b001;




wire clk_50m,clk_400m,clk_200m;
reg clk_800k;


reg pack_vaild;
wire pack_last;
wire pack_busy;
wire fifo_full;


wire [127:0]data_pack;


///////////////////////////////////////////////////////////////////////800k

localparam [31:0] HALF_STEP = 32'd800_000;
    localparam [31:0] HALF_FULL = 32'd25_000_000;

    reg [31:0] acc;

// 


    always @(posedge clk_50m or negedge resetn) begin
        if (!resetn) begin
            acc      <= 32'd0;
            clk_800k <= 1'b0;
        end else if (acc + HALF_STEP >= HALF_FULL) begin
            acc      <= acc + HALF_STEP - HALF_FULL;
            clk_800k <= ~clk_800k;          // 半周期到，翻转
        end else begin
            acc <= acc + HALF_STEP;
        end
    end

/////////////////////////////////////////////////////////////////////////////////////////////


always@(posedge clk_50m or negedge resetn)begin
if(!resetn)
pack_vaild<=1'd0;
else if(pack_vaild && pack_last)
pack_vaild<=1'd0;
else if(!fifo_full)
pack_vaild<=1'd1;
else
pack_vaild<=pack_vaild;
end


//==================================================================
wire locked;


clk_wiz_0 u_pll
   (
    // Clock out ports
    .clk_out1(clk_50m),     // output clk_out1
    .clk_out2(clk_400m),     // output clk_out2
    .clk_out3(clk_200m),
    // Status and control signals
    .reset(~resetn), // input reset
    .locked(locked),       // output locked
   // Clock in ports
    .clk_in1(clk));      // input clk_in1

//reg [95:0]data_pack;
reg  pack_busy_d;

always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)
        pack_busy_d <= 1'b0;      // 复位为 1，保证首个 1->0 能触发
    else
        pack_busy_d <= pack_busy;
end

wire pack_busy_sign = pack_busy_d & ~pack_busy;   // 下降沿，只在一拍为 1    
    
data_spi_send #(
.FRAME_BYTES(16),
    // 一帧位宽，必须等于 FRAME_BYTES*8，也要和 fifo_spi IP 的位宽一致
.FRAME_WIDTH (128)
)u_data_spi_send(
  .clk           (   clk_50m           )      ,           // 50MHz，SPI 位时钟 = clk/4 = 12.5MHz
  .clk_800k      (   clk_800k             ),
  .resetn        (   resetn           )     ,        // 低有效复位
  .frame_data    (   data_pack           )    ,   // 待发送的一帧
  .frame_valid   (   pack_busy_sign           )           ,  // 单周期脉冲：写入一帧
  .fifo_full     (   fifo_full           )         ,    // FIFO 满（说明发得太慢，有丢帧）
  .spi_mosi      (   spi_mosi           )    ,
  .spi_clk       (   spi_scl           )      ,
  .spi_cs        (   spi_cs           )
);    
    
data_packdage u_data_packdage(
.clk_50m      (   clk_50m          ) ,
.clk_400m     (   clk_400m          ) ,
.clk_200m     (   clk_200m          ) ,
.key          (    key         ),
.resetn       (   resetn          ) ,
.pack_vaild    (   pack_vaild          )    ,
.pack_last     (   pack_last           ),
.pack_busy    (   pack_busy          )    ,           //指示接口
.compare0     (   compare0          )    ,
.compare1     (   compare1          )    ,
.data_pack    (   data_pack          )   //外部接口
    );    
endmodule
