`timescale 1ns / 1ps

module tb_nx_monitor;

//==================== 信号 ====================
reg        clk_400m;
reg        resetn;
reg        compare0;
reg        nx_vaild;
wire [26:0] nx_data;
wire        nx_last;

//==================== DUT 例化 ====================
nx_monitor u_dut (
    .clk_400m(clk_400m),
    .resetn  (resetn),
    .compare0(compare0),
    .nx_vaild(nx_vaild),
    .nx_data (nx_data),
    .nx_last (nx_last)
);

//==================== 400MHz 时钟 (2.5ns) ====================
initial clk_400m = 1'b0;
always #1.25 clk_400m = ~clk_400m;

//==================== 可控方波生成器 ====================
reg        square_en;
reg [63:0] half_period_ns = 64'd50_000;   // 默认 10kHz

initial begin
    compare0 = 1'b0;
    forever begin
        if (square_en) begin
            #(half_period_ns);
            compare0 = ~compare0;
        end else begin
            compare0 = 1'b0;              // 停止时强制拉低, 便于相位可控
            #1;
        end
    end
end

//==================== 主测试流程 ====================
initial begin
    resetn    = 1'b0;
    nx_vaild  = 1'b0;
    square_en = 1'b0;

    //============================================================
    // 阶段 1: 10kHz 方波
    //============================================================
    $display("\n============================================================");
    $display("   阶段 1: 10kHz 方波 (半周期 50us), 期望 nx_data = 10");
    $display("============================================================");

    half_period_ns = 64'd50_000;   // 10kHz

    #100;
    // 复位释放与方波启动同步, 使测量窗口起点对应 compare0 = 0
    resetn    = 1'b1;
    square_en = 1'b1;

    // 等待数据缓存完成 (内部经两级缓存后 nx_last 拉高)
    wait (nx_last == 1'b1);
    $display("[%0t ns] nx_last=1, nx_data=%0d (数据已缓存好)", $time, nx_data);

    // 等待一段时间, 模拟对端准备好再发握手
    #5_000;                         // 5us

    // 拉高 vaild
    $display("[%0t ns] 拉高 nx_vaild", $time);
    nx_vaild = 1'b1;

    // 保持 10us
    #10_000;
    $display("[%0t ns] 拉低 nx_vaild", $time);
    nx_vaild = 1'b0;

    // 检查 vaild 拉低时 last 是否还保持高 (last 不早于 vaild 拉下)
    if (nx_last === 1'b1)
        $display("[%0t ns] OK: vaild 拉低时 nx_last 仍为高", $time);
    else
        $display("[%0t ns] ERROR: nx_last 早于 vaild 拉低!", $time);

    // 等待 last 由 DUT 主动拉低 (握手成功 -> busy -> 清除缓存)
    wait (nx_last == 1'b0);
    $display("[%0t ns] nx_last 拉低, 一次握手完成, nx_data=%0d",
             $time, nx_data);

    if (nx_data == 27'd10)
        $display("  >>> 阶段1 结果: 通过 (nx_data = 10)");
    else
        $display("  >>> 阶段1 结果: 失败 (期望 10, 实际 %0d)", nx_data);

    //============================================================
    // 复位 DUT, 切换为 100kHz
    //============================================================
    #2_000;
    resetn    = 1'b0;
    square_en = 1'b0;
    #100;
    half_period_ns = 64'd5_000;    // 100kHz

    //============================================================
    // 阶段 2: 100kHz 方波
    //============================================================
    $display("\n============================================================");
    $display("   阶段 2: 100kHz 方波 (半周期 5us), 期望 nx_data = 100");
    $display("============================================================");

    resetn    = 1'b1;
    square_en = 1'b1;

    wait (nx_last == 1'b1);
    $display("[%0t ns] nx_last=1, nx_data=%0d (数据已缓存好)", $time, nx_data);

    #5_000;                         // 5us
    $display("[%0t ns] 拉高 nx_vaild", $time);
    nx_vaild = 1'b1;

    #10_000;                        // 10us
    $display("[%0t ns] 拉低 nx_vaild", $time);
    nx_vaild = 1'b0;

    if (nx_last === 1'b1)
        $display("[%0t ns] OK: vaild 拉低时 nx_last 仍为高", $time);
    else
        $display("[%0t ns] ERROR: nx_last 早于 vaild 拉低!", $time);

    wait (nx_last == 1'b0);
    $display("[%0t ns] nx_last 拉低, 一次握手完成, nx_data=%0d",
             $time, nx_data);

    if (nx_data == 27'd100)
        $display("  >>> 阶段2 结果: 通过 (nx_data = 100)");
    else
        $display("  >>> 阶段2 结果: 失败 (期望 100, 实际 %0d)", nx_data);

    #2_000;
    $display("\n============================================================");
    $display("                     测试结束");
    $display("============================================================");
    $finish;
end

endmodule