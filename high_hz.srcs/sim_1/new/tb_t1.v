`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench : tb_hz_top_t1
// Description : compare0 / compare1 都是 25 kHz 方波（周期 40 us），
//               compare1 比 compare0 晚 1 us 上升。
//               期望 t1_data ~= 1,000,000 ps（1 us）。
//////////////////////////////////////////////////////////////////////////////////
module tb_hz_top_t1;

    reg  clk      = 1'b0;
    reg  resetn   = 1'b0;
    reg  compare0 = 1'b0;
    reg  compare1 = 1'b0;

    wire spi_cs;
    wire spi_scl;
    wire spi_mosi;

    // 50 MHz 输入时钟
    always #10 clk = ~clk;

    // compare0：25 kHz，高 20 us / 低 20 us
    // 上升沿出现在 20 us、60 us、100 us ...
    initial begin
        compare0 = 1'b0;
        #20000;
        forever begin
            compare0 = 1'b1; #20000;
            compare0 = 1'b0; #20000;
        end
    end

    // compare1：同样 25 kHz，但比 compare0 晚 1 us
    // 上升沿出现在 21 us、61 us、101 us ...
    initial begin
        compare1 = 1'b0;
        #21000;
        forever begin
            compare1 = 1'b1; #20000;
            compare1 = 1'b0; #20000;
        end
    end

    //==========================================================================
    // 例化 hz_top
    //==========================================================================
    hz_top u_hz_top (
        .clk      (clk),
        .resetn   (resetn),
        .compare0 (compare0),
        .compare1 (compare1),
        .spi_cs   (spi_cs),
        .spi_scl  (spi_scl),
        .spi_mosi (spi_mosi)
    );

    //==========================================================================
    // 直接观察 data_packdage 内部例化的 t1（实例名按你工程里的 u_t1）
    // 如果你的 t1 例化在 hz_top 顶层，把路径改成 u_hz_top.u_t1.xxx
    //==========================================================================
    wire [47:0] t1_data = u_hz_top.u_data_packdage.u_t1.t1_data;
    wire        t1_last = u_hz_top.u_data_packdage.u_t1.t1_last;

    //==========================================================================
    // 主流程
    //==========================================================================
    initial begin
        resetn = 1'b0;
        #1000;
        resetn = 1'b1;

        // 等第一帧 t1 结果
        wait (t1_last === 1'b1);
        #1000;

        $display("=================================================");
        $display(" t1_data = %0d ps", t1_data);
        $display(" expected = 1000000 ps (1 us)");
        $display(" error    = %0d ps", t1_data - 48'd1_000_000);
        $display("=================================================");

        if ((t1_data >= 48'd995_000) && (t1_data <= 48'd1_005_000))
            $display("PASS");
        else
            $display("FAIL");

        $finish;
    end

    // 超时保护
    initial begin
        #2_000_000;
        $display("TIMEOUT: t1_last 一直没拉高");
        $finish;
    end

endmodule