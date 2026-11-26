`timescale 1ns / 1ps

module tb_hz_top;

    //=========================================================
    // DUT 端口定义
    //=========================================================
    reg         clk;
    reg         compare0;
    reg         resetn;

    wire        spi_cs;
    wire        spi_scl;
    wire        spi_mosi;
    wire [95:0] data_pack;

    //=========================================================
    // 例化 DUT
    //=========================================================
    hz_top u_hz_top (
        .clk       (clk),
        .compare0  (compare0),
        .resetn    (resetn),
        .spi_cs    (spi_cs),
        .spi_scl   (spi_scl),
        .spi_mosi  (spi_mosi)
        
    );

    //=========================================================
    // 层次化引用观察内部关键信号
    //=========================================================
    wire        obs_pack_busy      = u_hz_top.pack_busy;
    
    wire        obs_pack_busy_sign = u_hz_top.pack_busy_sign;
    wire [5:0]  obs_current_state  = u_hz_top.u_data_packdage.current_state;
    wire [26:0] obs_nx_data        = u_hz_top.u_data_packdage.nx_data;
    wire [28:0] obs_nx_data        = u_hz_top.u_data_packdage.n0_data;
    wire [95:0] obs_fifo_latch     = u_hz_top.u_data_spi_send.fifo_latch; 
    wire        obs_rd_rst_busy    = u_hz_top.u_data_spi_send.rd_rst_busy;
    wire        obs_fifo_full      = u_hz_top.u_data_spi_send.fifo_full;                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              
    
    wire        obs_nx_vaild      = u_hz_top.u_data_packdage.nx_vaild;
    wire        obs_n0_vaild      = u_hz_top.u_data_packdage.n0_vaild;
    wire        obs_nx_last      = u_hz_top.u_data_packdage.nx_last;
    wire        obs_n0_last      = u_hz_top.u_data_packdage.n0_last;
    wire        obs_nx_busy      = u_hz_top.u_data_packdage.nx_busy;
    wire        obs_n0_busy      = u_hz_top.u_data_packdage.n0_busy;

    //=========================================================
    // 系统时钟：50MHz，周期 20ns
    //=========================================================
    initial clk = 1'b0;
    always #10 clk = ~clk;

    //=========================================================
    // compare0：动态变频信号
    //=========================================================
    reg [31:0] half_period;
    
    initial begin
        compare0 = 1'b0;
        half_period = 32'd50000; // 默认给个初值
        #1;
        forever #(half_period) compare0 = ~compare0;
    end

    //=========================================================
    // 关键打印监视
    //=========================================================
    always @(posedge obs_pack_busy_sign)
        $display("[%0t ns] SPI 写 FIFO，锁存数据 = 0x%024h", $time, data_pack);

    //=========================================================
    // 主流程：复位 -> 10kHz -> 100kHz -> 10MHz
    //=========================================================
    initial begin
        // 1. 初始复位
        resetn = 1'b0;
        half_period = 32'd50000;  // 初始设为 10kHz (半周期 50us)
        #200; 
        resetn = 1'b1;
        $display("==================================================");
        $display("[%0t ns] reset released, 开始测试 10kHz", $time);

        // 2. 等待内部 FIFO 同步释放，并跑完第一次 10kHz 的 1ms 测频
        // 为了稳妥，这里等 2.0ms，大概能出两次结果
        #2000000; 
        $display("[%0t ns] 10kHz 测试结果观察：", $time);
        $display("           nx_data   = %0d (期望 10)", obs_nx_data);
        $display("           data_pack = 0x%024h", data_pack);

        // 3. 切换至 100kHz (半周期 5us)
        half_period = 32'd5000;
        $display("==================================================");
        $display("[%0t ns] 切换至 100kHz", $time);
        #2000000; 
        $display("[%0t ns] 100kHz 测试结果观察：", $time);
        $display("           nx_data   = %0d (期望 100)", obs_nx_data);
        $display("           data_pack = 0x%024h", data_pack);

        // 4. 切换至 10MHz (半周期 50ns)
        half_period = 32'd50;
        $display("==================================================");
        $display("[%0t ns] 切换至 10MHz", $time);
        #2000000; 
        $display("[%0t ns] 10MHz 测试结果观察：", $time);
        $display("           nx_data   = %0d (期望 10000)", obs_nx_data);
        $display("           data_pack = 0x%024h", data_pack);
        $display("           fifo_latch= 0x%024h", obs_fifo_latch);

        $display("=== SIM DONE ===");
        $finish;
    end

endmodule