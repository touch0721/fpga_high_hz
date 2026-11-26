`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Testbench  : tb_n0_monitor
// Description: 10kHz / 100kHz 两档 compare0 周期测量 + 50MHz 域握手回环自检
//
//   期望值（400MHz 时钟周期数）：
//     10kHz  -> 100us / 2.5ns = 40000
//     100kHz -> 10us  / 2.5ns = 4000
//
//   检查项：
//     1) n0_data 数值是否正确（±2，覆盖跨域采样量化误差）
//     2) n0_last 不得在 valid 仍为高时拉低
//     3) n0_last 有效期间 n0_data 必须恒定不变
//     4) 每笔传完能自动重启测量（连续多笔都算对即证明）
//
//   跑法：
//     iverilog -o sim tb_n0_monitor.v n0_monitor.v && vvp sim
//     （要波形加 -DDUMP_WAVE 生成 tb_n0_monitor.vcd）
//////////////////////////////////////////////////////////////////////////////////

module tb_n0_monitor;

    //============================ 时钟 / 复位 ============================
    reg clk_400m = 1'b0;              // 400MHz, 周期 2.5ns
    reg clk_50m  = 1'b0;              // 50MHz,  周期 20ns
    reg resetn   = 1'b0;

    always #1.25 clk_400m = ~clk_400m;
    always #10.0 clk_50m  = ~clk_50m;

    //=========================== 被测信号 compare0 =======================
    // 用 real 半周期控制频率：10kHz -> 50000ns，100kHz -> 5000ns
    reg  compare0 = 1'b0;
    real half_ns  = 50000.0;

    initial begin
        forever #(half_ns) compare0 = ~compare0;
    end

    //=============================== DUT ================================
    wire [28:0] n0_data;
    wire        n0_last;
    reg         valid_50m = 1'b0;     // 50MHz 域握手响应（原 togo）

    n0_monitor u_dut (
        .clk_400m (clk_400m),
        .resetn   (resetn),
        .compare0 (compare0),
        .valid    (valid_50m),
        .n0_data  (n0_data),
        .n0_last  (n0_last)
    );

    //================== 50MHz 域接收端模型：同步 last + 回握手 ==================
    // 严格按"先 2FF 同步 last，再用同步后的 last 当使能去采数据"来写
    reg last_s1_50 = 1'b0;
    reg last_s2_50 = 1'b0;

    always @(posedge clk_50m or negedge resetn) begin
        if (!resetn) begin
            last_s1_50 <= 1'b0;
            last_s2_50 <= 1'b0;
        end else begin
            last_s1_50 <= n0_last;
            last_s2_50 <= last_s1_50;
        end
    end

    //============================= 统计变量 =============================
    integer    errors   = 0;
    integer    xfers    = 0;
    integer    skips    = 0;
    integer    expected = 0;
    integer    chk_en   = 1;
    integer    hold_cyc = 2;          // valid 保持多少个 50M 周期
    integer    got_val;
    reg [28:0] cap_data;

    //========================= 收一笔数据（含判定）=========================
    task recv_one;
        begin
            @(posedge clk_50m);
            while (last_s2_50 !== 1'b1) @(posedge clk_50m);  // 等 last 同步过来

            cap_data   = n0_data;        // 此刻数据已稳定 ≥1 个 50M 周期
            got_val    = cap_data;
            valid_50m <= 1'b1;           // 回握手：valid 拉高
            repeat (hold_cyc) @(posedge clk_50m);
            valid_50m <= 1'b0;           // 撤销响应

            if (chk_en) begin
                if ((got_val > expected + 2) || (got_val < expected - 2)) begin
                    $display("[%0t] FAIL : n0_data=%0d, 期望 %0d (±2)", $time, got_val, expected);
                    errors = errors + 1;
                end else begin
                    $display("[%0t] PASS : n0_data=%0d, 期望 %0d", $time, got_val, expected);
                end
                xfers = xfers + 1;
            end else begin
                $display("[%0t] SKIP : n0_data=%0d（换频过渡期，不判）", $time, got_val);
                skips = skips + 1;
            end

            @(posedge clk_50m);
            while (last_s2_50 !== 1'b0) @(posedge clk_50m);  // 等 last 回落再重新武装
        end
    endtask

    //===================== 检查 2：last 不得早于 valid 拉低 =====================
    always @(negedge n0_last) begin
        if ((resetn === 1'b1) && (valid_50m === 1'b1)) begin
            $display("[%0t] FAIL : n0_last 在 valid 仍为高时拉低！", $time);
            errors = errors + 1;
        end
    end

    //=================== 检查 3：last 有效期间 n0_data 恒定 ===================
    reg [28:0] data_q = 29'd0;
    reg        last_q = 1'b0;

    always @(posedge clk_400m) begin
        data_q <= n0_data;
        last_q <= n0_last;
        if ((resetn === 1'b1) && (last_q === 1'b1) && (n0_last === 1'b1) &&
            (n0_data !== data_q)) begin
            $display("[%0t] FAIL : last 有效期间 n0_data 变了 (%0d -> %0d)", $time, data_q, n0_data);
            errors = errors + 1;
        end
    end

    //============================= 看门狗 =============================
    initial begin
        #2_000_000;                                    // 2ms
        $display("\n[%0t] TIMEOUT：2ms 内未跑完，检查握手是否卡死", $time);
        $display("**** TEST FAILED ****");
        $finish;
    end

    //============================= 主激励 =============================
    integer i;

    initial begin
`ifdef DUMP_WAVE
        $dumpfile("tb_n0_monitor.vcd");
        $dumpvars(0, tb_n0_monitor);
`endif
        valid_50m = 1'b0;
        resetn    = 1'b0;
        half_ns   = 50000.0;
        #200;
        resetn = 1'b1;
        $display("==== 复位释放，开始测试（clk_400m = 400MHz）====");

        //----------------- Case 1: 10kHz -> 期望 40000 -----------------
        $display("\n---- Case 1: compare0 = 10kHz（周期 100us），期望 40000 ----");
        half_ns   = 50000.0;
        expected  = 40000;
        chk_en    = 1;
        hold_cyc  = 2;                       // valid 只保持 2 拍
        for (i = 0; i < 3; i = i + 1) recv_one;

        //----------------- Case 2: 100kHz -> 期望 4000 -----------------
        $display("\n---- Case 2: compare0 = 100kHz（周期 10us），期望 4000 ----");
        chk_en    = 0;                       // 换频，先丢 2 笔过渡数据
        half_ns   = 5000.0;
        hold_cyc  = 8;                       // valid 保持 8 拍，验证长握手
        for (i = 0; i < 2; i = i + 1) recv_one;

        expected  = 4000;
        chk_en    = 1;
        for (i = 0; i < 4; i = i + 1) recv_one;

        //--------------------------- 汇总 ----------------------------
        $display("\n==== 判定 %0d 笔，跳过 %0d 笔，错误 %0d 个 ====", xfers, skips, errors);
        if (errors == 0) $display("**** TEST PASSED ****");
        else             $display("**** TEST FAILED ****");
        $finish;
    end

endmodule
