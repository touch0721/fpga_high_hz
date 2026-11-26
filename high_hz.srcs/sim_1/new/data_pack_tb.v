`timescale 1ns / 1ps

module tb_data_packdage;

    reg         clk;
    reg         clk_400m;
    reg         resetn;
    reg         compare0;
    reg         pack_togo;

    wire        pack_busy;
    wire [95:0] data_pack;

    //=========================================================
    // 例化 DUT
    //=========================================================
    data_packdage u_dut (
        .clk_50m       (clk),
        .clk_400m  (clk_400m),
        .resetn    (resetn),
        .pack_togo (pack_togo),
        .pack_busy (pack_busy),
        .compare0  (compare0),
        .data_pack (data_pack)
    );

    //=========================================================
    // 50MHz 系统时钟，周期 20ns
    //=========================================================
    initial clk = 1'b0;
    always #10 clk = ~clk;

    //=========================================================
    // 400MHz 时钟，周期 2.5ns
    //=========================================================
    initial clk_400m = 1'b0;
    always #1.25 clk_400m = ~clk_400m;

    //=========================================================
    // compare0：10MHz 方波，周期 100ns，半周期 50ns
    //   #1 偏移避开 clk_400m 上升沿（50 是 2.5 的整数倍）
    //=========================================================
    initial begin
        compare0 = 1'b0;
        #1;
        forever #50 compare0 = ~compare0;
    end

    //=========================================================
    // 监视 pack_busy 变化
    //=========================================================
    always @(pack_busy)
        $display("[%0t ns] pack_busy = %b", $time, pack_busy);

    //=========================================================
    // 主流程：复位 → 触发一次测量 → 等完成 → 打印 data_pack
    //=========================================================
    initial begin
        resetn    = 1'b0;
        pack_togo = 1'b0;
        #1000;
        resetn = 1'b1;
        #1000;

        $display("[%0t ns] === trigger pack_togo ===", $time);
        pack_togo = 1'b1;
        #100;
        pack_togo = 1'b0;

        // 等测量完成：pack_busy 1 -> 0
        wait (pack_busy == 1'b1);
        $display("[%0t ns] pack_busy went high, measurement started", $time);
        wait (pack_busy == 1'b0);
        $display("[%0t ns] pack_busy went low, measurement done", $time);
        #100;

        // 打印 data_pack
        $display("=========================================");
        $display("data_pack       = 0x%024h", data_pack);
        $display("  header[95:80] = 0x%04h   (exp 0x00aa)", data_pack[95:80]);
        $display("  nx_data[79:48]= 0x%08h (%0d)  (exp 10000)", data_pack[79:48], data_pack[79:48]);
        $display("  n0_data[47:16]= 0x%08h (%0d)  (exp 40)", data_pack[47:16], data_pack[47:16]);
        $display("  tail[15:0]    = 0x%04h   (exp 0x00f0)", data_pack[15:0]);
        $display("=========================================");

        // 同时看内部 latch（因为 data_pack 输出可能没赋值，见下面提醒）
        $display("u_dut.data_pack_latch = 0x%024h", u_dut.data_pack_latch);

        $display("=== SIM DONE ===");
        $finish;
    end

    //=========================================================
    // 超时保护：10ms 还没完成就退出
    //=========================================================
    initial begin
        #10_000_000;
        $display("[%0t ns] TIMEOUT! pack_busy=%b", $time, pack_busy);
        $finish;
    end

endmodule