# fpga_high_hz

基于 Xilinx Artix-7 的高精度**频率 / 周期 / 时间间隔 / 占空比**测量 FPGA 工程。
200 MHz 粗计数 + CARRY4 延迟线 TDC 插值，测量结果通过 SPI 以 16 字节定长帧送出，由 MCU 解析显示。

---

## 功能

| 模式 | `func_mux` | 测量内容 | 说明 |
|---|---|---|---|
| 频率 / 周期 | `3'b001` | `compare0` 的频率与周期 | 1 s 闸门计数（nx）+ 相邻上升沿周期（n0） |
| 时间间隔 | `3'b010` | `compare0` 上升沿 → `compare1` 上升沿 | 200 MHz 粗计数 + 双 TDC |
| 占空比 | `3'b100` | `compare0` 的高电平 / 周期 | 200 MHz 粗计数 + 双 TDC（上升沿 / 下降沿各一条链） |

- 按键 `key`（低有效，20 ms 消抖）循环切换三种模式，切换值锁存；
- 板上 PLL：50 MHz 输入 → **50 MHz / 300 MHz / 200 MHz**；
- SPI 从机发送：16 字节/帧，SPI 时钟 800 kHz，模式 3（CPOL=1, CPHA=1）。

> 注意：代码里的 `clk_400m` 实际是 **300 MHz**（PLL clk_out2），命名沿用旧工程，量纲按 300 MHz 计算。

---

## 硬件

| 项目 | 参数 |
|---|---|
| FPGA | XC7A50T-FGG484-2（Artix-7） |
| 工具 | Vivado 2020.2 |
| 输入时钟 | 50 MHz（引脚 Y18） |
| 测量输入 | `compare0` / `compare1`，LVCMOS33 |
| 输出 | SPI：`spi_cs` / `spi_scl` / `spi_mosi` |

### 引脚约束（`top.xdc`）

| 信号 | 引脚 | 说明 |
|---|---|---|
| `clk` | Y18 | 50 MHz 输入 |
| `resetn` | T20 | 异步复位，低有效 |
| `compare0` | J17 | 被测信号 0 |
| `compare1` | K16 | 被测信号 1（t1 模式） |
| `key` | E22 | 模式切换按键，低有效 |
| `spi_cs` | N4 | SPI 片选 |
| `spi_scl` | L3 | SPI 时钟 |
| `spi_mosi` | P5 | SPI 数据 |

---

## 目录结构

```
high_hz.srcs/
├── constrs_1/new/top.xdc            引脚、TDC 保护、false_path
├── sources_1/
│   ├── new/
│   │   ├── hz_top.v                 顶层：PLL、SPI 发送、打包、按键
│   │   ├── data_packdage.v          三模式选择、握手、16 字节帧打包
│   │   ├── nx_monitor.v             1 s 闸门频率计数（27 位）
│   │   ├── n0_monitor.v             相邻上升沿周期（300 MHz 计数，29 位）
│   │   ├── t1_monitor.v             时间间隔：200 MHz + 双 TDC（64 位输出）
│   │   ├── p1_monitor.v             占空比：200 MHz + 双 TDC（96 位输出）
│   │   ├── key.v                    按键消抖 + func_mux 循环
│   │   └── hz_monitor.v             预留
│   ├── imports/new/
│   │   ├── data_stute.v             SPI 发送状态机（FIFO → SPI）
│   │   └── spi_byte.v               SPI 字节/位发送
│   └── ip/
│       ├── clk_wiz_0/               50 → 50/300/200 MHz
│       └── ila_0/                   调试用 ILA（默认注释）
├── sim_1/new/                       各模块 testbench
└── fifo_spi/ip/fifo_spi/            SPI 发送 FIFO
```

---

## 测量原理

### 1. nx / n0（频率 / 周期）

- **nx**：50 MHz 域 1 s 闸门（`SEC_END = 49_999_999`）内数 `compare0` 上升沿，结果即 Hz；
- **n0**：`compare0` 相邻上升沿之间的 **300 MHz** 周期数，周期 = `n0 / 300 MHz`。

低频时 nx 只有 ±1 计数（8 Hz 时 ±12.5%），建议 MCU 在 20 kHz 以下改用 n0 反算频率：

```
f = 300e6 / n0
```

### 2. t1（时间间隔）

```
compare0 上升沿 = START，compare1 上升沿 = STOP
T = 粗计数 × 5 ns + TDC 零头
```

- 200 MHz 粗计数；
- 两条 CARRY4 延迟线（compare0 / compare1），384 抽头，每抽头约 **19 ps**（需标定）；
- 输出 64 位：`[63:32]` 粗计数拍数，`[31:0]` TDC 小数（ps）。

### 3. p1（占空比）

```
上升沿1 → 下降沿 → 上升沿2
H = H_c × 5 ns + (k1 - k2) × tau
P = P_c × 5 ns + (k1 - k3) × tau
duty = H / P
```

- 两条延迟线分别由 `compare0` 和 `~compare0` 启动（上升沿 / 下降沿）；
- 输出 96 位：`H_c` / `P_c` / `d_h` / `d_p`；
- 两条链存在固定偏差，实测约 **2.6 ns**，需要在 H 上扣除（见下文）。

---

## SPI 数据帧

固定 **16 字节**，大端，帧头区分模式，帧尾 `00 F0`。

| 模式 | 帧头 | 数据段 |
|---|---|---|
| 001 | `AA AA` | nx(27) + n0(29) |
| 010 | `AA BB` | t1_data[63:0] |
| 100 | `AA CC` | p1_data[95:0] |

### 模式 001

```
b0 b1   : AA AA
b2 b3   : 00 00
b4      : {5'b0, nx[26:24]}
b5      : nx[23:16]
b6      : nx[15:8]
b7      : nx[7:0]
b8      : {3'b0, n0[28:24]}
b9      : n0[23:16]
b10     : n0[15:8]
b11     : n0[7:0]
b12 b13 : 00 00
b14 b15 : 00 F0
```

### 模式 010

```
b0 b1   : AA BB
b2 b3   : 00 00
b4..b7  : t1_data[63:32]   粗计数
b8..b11 : t1_data[31:0]    TDC ps
b12 b13 : 00 00
b14 b15 : 00 F0
```

### 模式 100

```
b0 b1   : AA CC
b2 b3   : {6'd0, d_p}
b4 b5   : {6'd0, d_h}
b6..b9  : P_c（28 位有效）
b10..b13: H_c（28 位有效）
b14 b15 : 00 F0
```

---

## MCU 解析

### nx / n0

```c
uint32_t nx = ((uint32_t)(b[4] & 0x07) << 24) | ((uint32_t)b[5] << 16)
            | ((uint32_t)b[6] << 8)  |  (uint32_t)b[7];
uint32_t n0 = ((uint32_t)(b[8] & 0x1F) << 24) | ((uint32_t)b[9] << 16)
            | ((uint32_t)b[10] << 8) |  (uint32_t)b[11];

double f = (nx >= 20000) ? (double)nx : (300.0e6 / (double)n0);
```

### t1

```c
uint32_t coarse = ((uint32_t)b[4] << 24) | ((uint32_t)b[5] << 16)
                | ((uint32_t)b[6] << 8)  |  (uint32_t)b[7];
uint32_t ps     = ((uint32_t)b[8] << 24) | ((uint32_t)b[9] << 16)
                | ((uint32_t)b[10] << 8) |  (uint32_t)b[11];

int64_t T_ps = (int64_t)coarse * 5000 + (int64_t)ps;
```

### p1

```c
uint16_t d_p_u = ((uint16_t)b[2] << 8) | b[3];
uint16_t d_h_u = ((uint16_t)b[4] << 8) | b[5];
uint32_t P_c   = ((uint32_t)b[6] << 24) | ((uint32_t)b[7] << 16)
               | ((uint32_t)b[8] << 8)  |  (uint32_t)b[9];
uint32_t H_c   = ((uint32_t)b[10] << 24) | ((uint32_t)b[11] << 16)
               | ((uint32_t)b[12] << 8) |  (uint32_t)b[13];

int16_t d_p = d_p_u & 0x03FF;  if (d_p & 0x0200) d_p -= 0x0400;
int16_t d_h = d_h_u & 0x03FF;  if (d_h & 0x0200) d_h -= 0x0400;

int64_t H = (int64_t)H_c * 5000 + (int64_t)d_h * tau_ps - 2600;  // 固定扣 2.6 ns
int64_t P = (int64_t)P_c * 5000 + (int64_t)d_p * tau_ps;
double duty = (double)H / (double)P;
```

---

## 参数标定

| 参数 | 说明 | 方法 |
|---|---|---|
| `tau_ps` | 每个 TDC 抽头的延迟，约 **19 ps** | 码密度法：输入与 200 MHz 不成整数比的频率（如 1.001 MHz），统计 `d_p` 扫过的跨度，`tau = 5000 / (d_max - d_min)` |
| p1 offset | 两条链固定偏差，约 **2.6 ns** | 输入已知占空比（如 50%），按显示误差反推 |
| t1 offset | 两路输入通道固定差 | 给 compare0/compare1 同一信号（零间隔），读数即为 offset |
| 时钟 ppm | 板载晶振相对信号源的偏差（实测约 +4 ppm） | 输入 10 MHz 基准，比较读数 |

---

## 构建

1. Vivado 2020.2 打开 `high_hz.xpr`；
2. 综合 → 实现 → 生成比特流；
3. 下载到 XC7A50T-FGG484-2；
4. 按 `top.xdc` 接线，SPI 接 MCU，按键切换模式。

---

## 已知限制

- `t1` 的 `ps` 字段在 `p_fr >= 0` 时可能大于 5000（未做正数取模），MCU 直接相加仍然正确，不要按“异常”丢弃；
- 低频（< 1 Hz）时若输入有毛刺，n0 会把一个周期拆成两段，需要在输入端加滤波/滞回；
- `nx` 在低频段量化粗（1 Hz 分辨率），建议用 n0 反算；
- `p1` 的 offset 与 `tau` 必须一起标定，否则占空比会有 0.3% 量级的系统偏差；
- `ila_0` 默认注释，需要时自行例化并匹配探针位宽。

---

## 编码说明

`high_hz.srcs` 下的 `.v` / `.xdc` 源文件为 **GBK** 编码（Vivado 工程原有编码）。
在 GitHub 网页上中文注释可能显示为乱码，克隆后请用 GBK 打开，或自行转换为 UTF-8：

```powershell
Get-ChildItem -Recurse -Include *.v,*.xdc | ForEach-Object {
    $t = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::GetEncoding(936))
    [IO.File]::WriteAllText($_.FullName, $t, (New-Object Text.UTF8Encoding $false))
}
```

`README.md` 本身为 UTF-8。

## 许可

仅用于学习与个人项目，未附带许可证。
