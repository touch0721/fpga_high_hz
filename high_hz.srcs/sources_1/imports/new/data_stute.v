`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name : data_spi_send
// Description : 一帧数据经 FIFO 缓存后由 SPI 主机逐字节发出去
//
//   写侧：frame_valid 拉高一拍就把 frame_data 压进 FIFO
//   读侧：SPI 空闲且 FIFO 非空 -> 把队首锁存进 fifo_latch 并开始发一整帧；
//         发帧期间 spi_cs 一直拉低，整帧发完才回到空闲
//
//   字节顺序：MSB first，先发 frame_data 的最高字节
//     byte 0 -> [79:72]   HEAD0
//     byte 1 -> [71:64]   HEAD1
//     byte 2 -> [63:56]   PHASE 高
//     byte 3 -> [55:48]   PHASE 低
//     byte 4 -> [47:40]   FREQ0 高
//     byte 5 -> [39:32]   FREQ0 低
//     byte 6 -> [31:24]   FREQ1 高
//     byte 7 -> [23:16]   FREQ1 低
//     byte 8 -> [15: 8]   TAIL0
//     byte 9 -> [ 7: 0]   TAIL1
//
//   spi_byte 内部一个字节占 32 个 clk，CPOL=1 / CPHA=1，
//   clk=50MHz 时 SPI 位时钟 = 12.5MHz，一帧 10 字节 = 6.4us。
//////////////////////////////////////////////////////////////////////////////////

module data_spi_send #(
    
    parameter integer FRAME_BYTES = 13,
    // 一帧位宽，必须等于 FRAME_BYTES*8，也要和 fifo_spi IP 的位宽一致
    parameter integer FRAME_WIDTH = 104
)(
    input  wire                  clk,           // 50MHz，SPI 位时钟 = clk/4 = 12.5MHz
    
    input  clk_800k,
    input  wire                  resetn,        // 低有效复位
    

    input  wire [FRAME_WIDTH-1:0] frame_data,   // 待发送的一帧
    input  wire                   frame_valid,  // 单周期脉冲：写入一帧

    output wire                   fifo_full,    // FIFO 满（说明发得太慢，有丢帧）
    output wire                   spi_mosi,
    output wire                   spi_clk,
    output wire                   spi_cs
);


 

    // 一帧最后一个字节的序号（byte_idx 预留 5 位，最多支持 32 字节一帧）
    localparam [4:0] BYTE_LAST = FRAME_BYTES - 1;

    wire                      fifo_empty;
    wire [FRAME_WIDTH-1:0]    fifo_dout;
    reg  [FRAME_WIDTH-1:0]    fifo_latch;    // 当前正在发送的整帧

    reg  [4:0]                byte_idx;      // 当前正在发送的字节序号
    reg                       sending;       // 一帧发送中
    reg                       to_go;         // 给 spi_byte 的发送使能，整帧保持高
    reg  [7:0]                data_spi;      // 当前字节

    wire                      byte_end;
    wire wr_rst_busy,rd_rst_busy;
    wire wr_en = frame_valid && (!fifo_full)&&(!wr_rst_busy);
    // FWFT：dout 恒为队首；只在起一帧时打一拍 rd_en 弹出该帧，
    // rd_en 常高会把 FIFO 连续抽干、并在发送过程中覆盖 fifo_latch。
    wire start_frame = (!sending)&&(!fifo_empty)&&(!rd_rst_busy);
    wire rd_en       = start_frame;

    wire resetn_fifo;
    reg [3:0] rst_sync_800k;
    wire clk_800k_bufg;

// 2. 例化 BUFG 原语
BUFG u_bufg_800k (
    .I (clk_800k),        // 输入：你由逻辑产生的时钟
    .O (clk_800k_bufg)    // 输出：驱动全局时钟网络的时钟
);

    // 异步复位，同步释放
    always @(posedge clk_800k_bufg or negedge resetn) begin
        if (!resetn) begin
            rst_sync_800k <= 4'd0;
        end else begin
            // 逐级移入 1，计满 15 时释放
            rst_sync_800k <= {rst_sync_800k[2:0], 1'b1};
        end
    end
    
    // 当 rst_sync_800k 变成 1111 时，代表复位释放
    assign resetn_fifo = rst_sync_800k[3];
    
      ila_0 u_ila (
	.clk(clk), // input wire clk
	.probe0(fifo_latch), // input wire [95:0] probe0
	.probe1(spi_cs),
	.probe2(spi_clk),
	.probe3(spi_mosi)	
); 
    
    
    //==========================================================================
    // 帧缓存 FIFO：位宽 x 1024，FWFT（First Word Fall Through）
    // 注意：FIFO 的 srst 是高有效同步复位，所以这里取反
    //==========================================================================
   fifo_spi u_fifo_spi (
  .rst(~resetn_fifo),                  // input wire rst
  .wr_clk(clk),            // input wire wr_clk
  .rd_clk(clk_800k_bufg),            // input wire rd_clk
  .din(frame_data),                  // input wire [95 : 0] din
  .wr_en(wr_en),              // input wire wr_en
  .rd_en(rd_en),              // input wire rd_en
  .dout(fifo_dout),                // output wire [95 : 0] dout
  .full(fifo_full),                // output wire full
  .empty(fifo_empty),              // output wire empty
  .wr_rst_busy(wr_rst_busy),  // output wire wr_rst_busy
  .rd_rst_busy(rd_rst_busy)  // output wire rd_rst_busy
);
    // 起帧那一拍 rd_en=1，dout 正是本帧队首；同一拍锁存，整帧发送期间不再变
    always @(posedge clk_800k_bufg or negedge resetn) begin
        if (!resetn)
            fifo_latch <= {FRAME_WIDTH{1'b0}};
        else if (rd_en)
            fifo_latch <= fifo_dout;
        else
            fifo_latch <= fifo_latch;
    end

    //==========================================================================
    // 发送状态机
    //==========================================================================
    always @(posedge clk_800k_bufg or negedge resetn) begin
        if (!resetn) begin
            sending  <= 1'b0;
            byte_idx <= 5'd0;
            to_go    <= 1'b0;
        end
        else if (!sending) begin
            // FIFO 里有帧就开始发一整帧 (与 rd_en 同一拍，弹出一帧并锁存)
            if (start_frame) begin
                sending  <= 1'b1;
                byte_idx <= 5'd0;
                to_go    <= 1'b1;
            end
        end
        else if (byte_end) begin
            if (byte_idx == BYTE_LAST) begin
                sending  <= 1'b0;       // 整帧发完，回到空闲
                byte_idx <= 5'd0;
                to_go    <= 1'b0;
            end
            else
                byte_idx <= byte_idx + 5'd1;
        end
    end

    //==========================================================================
    // 当前字节：MSB first，byte n 取第 (FRAME_BYTES-1-n) 个低字节
    //   byte 0 -> [FRAME_WIDTH-1 -: 8] (最高字节) ... byte 9 -> [7:0]
    //==========================================================================
    always @(*) begin : byte_mux
        integer i;
        data_spi = 8'h00;
        for (i = 0; i < FRAME_BYTES; i = i + 1)
            if (byte_idx == i[4:0])
                data_spi = fifo_latch[8*(FRAME_BYTES-1-i) +: 8];
    end

    //==========================================================================
    // 单字节 SPI 移位发送（每个字节 32 个 clk）
    //==========================================================================
spi_byte u_spi_byte(
        .clk      (clk_800k_bufg),
        .reset    (resetn),        // spi_byte 内部是低有效复位
        .data_din (data_spi),
        .to_go    (to_go),
        .byte_end (byte_end),
        .spi_mosi (spi_mosi),
        .spi_clk  (spi_clk),
        .spi_cs   (spi_cs)
    );

endmodule
