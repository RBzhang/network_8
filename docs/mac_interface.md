# MAC 层顶层接口说明

本文档说明 `network_8` 项目中 MAC 层模块对上层业务逻辑和物理层光模块的调用接口。当前建议将以下模块作为对外顶层使用：

- `sources_1/new/node_top.v`：双端口板级 wrapper；
- `sources_1/new/node_top_3port.v`：三端口板级 wrapper；
- `sources_1/new/node_top_4port.v`：四端口板级 wrapper；
- `sources_1/new/node_core.v`：参数化核心模块，适合内部复用或进一步封装。

`node_top_*` wrapper 只负责把独立端口信号打包到 `node_core` 的扁平多端口总线中，不改变 MAC 协议、上层接口和物理层 word 接口。

---

## 1. 接口总体划分

MAC 层顶层接口可以分为 6 类：

| 类别 | 说明 |
|---|---|
| 全局控制接口 | `clk`、`rst`、`node_id_valid`、`node_id` |
| 物理层 RX 接口 | 光模块/物理层输入到 MAC：`rx_clkX`、`inX`、`valid_inX` |
| 物理层 TX 接口 | MAC 输出到光模块/物理层：`tx_clkX`、`outX`、`valid_outX` |
| 上层发送接口 | 上层业务逻辑向 MAC 发包：`app_frame_*`、`app_dst_id`、`app_len16`、`app_payload_*` |
| 上层接收接口 | MAC 向上层业务逻辑上报收到的包：`app_rx_*` |
| 状态监控接口 | 在线状态、拥塞、长度错误、RX 溢出等状态 |

其中：

```text
clk       ：MAC 内部主时钟，上层 app 接口均工作在该时钟域。
rx_clkX   ：第 X 个光口接收侧时钟。
tx_clkX   ：第 X 个光口发送侧时钟。
inX       ：物理层输入到 MAC 的 32-bit word。
valid_inX ：inX 当前周期有效。
outX      ：MAC 输出到物理层的 32-bit word。
valid_outX：outX 当前周期有效。
```

---

## 2. 双端口顶层 `node_top.v` 接口

双端口版本用于当前每块 FPGA 板卡两个光模块的场景。

```verilog
module node_top #(
    parameter SYNC_WORD    = 32'hA31E57BD,
    parameter BROADCAST    = 8'hFF,
    parameter MAX_PAYLOAD  = 256,
    parameter LIVENESS_WIN = 5,
    parameter NODE_COUNT   = 255,
    parameter DEDUP_DEPTH  = 64,
    parameter FIFO_DEPTH   = 8192,
    parameter RX_REPORT_FIFO_DEPTH = 2048,
    parameter CLK_FREQ_HZ  = 160_000_000,
    parameter CONGEST_TIMEOUT_SEC = 5
) (
    input  wire        clk,
    input  wire        rst,

    input  wire        node_id_valid,
    input  wire [7:0]  node_id,

    input  wire        rx_clk0,
    input  wire        rx_clk1,
    input  wire        tx_clk0,
    input  wire        tx_clk1,

    input  wire [31:0] in0,
    input  wire [31:0] in1,
    input  wire        valid_in0,
    input  wire        valid_in1,

    input  wire        app_frame_valid,
    output wire        app_frame_ready,
    output wire        app_frame_accepted,
    output wire        app_frame_done,
    input  wire [7:0]  app_dst_id,
    input  wire [15:0] app_len16,
    output wire [15:0] app_payload_addr,
    input  wire [31:0] app_payload_data,

    output wire        app_rx_frame_valid,
    input  wire        app_rx_frame_ready,
    output wire [7:0]  app_rx_src_id,
    output wire [7:0]  app_rx_dst_id,
    output wire [15:0] app_rx_count,
    output wire [15:0] app_rx_len16,
    output wire        app_rx_payload_valid,
    input  wire        app_rx_payload_ready,
    output wire [15:0] app_rx_payload_addr,
    output wire [31:0] app_rx_payload_data,

    output wire [31:0] out0,
    output wire [31:0] out1,
    output wire        valid_out0,
    output wire        valid_out1,

    output wire        liveness_valid,
    output wire [7:0]  liveness_node,
    output wire        liveness_alive,
    output wire        network_congested,
    output wire        app_len_error,
    output wire        rx_overflow
);
```

---

## 3. 全局控制接口

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `clk` | input | MAC 主时钟 | MAC 内部主时钟，上层 app 接口都工作在该时钟域。 |
| `rst` | input | `clk`，并同步到各端口时钟域 | 高有效复位。 |
| `node_id_valid` | input | `clk` | 节点 ID 有效脉冲。 |
| `node_id[7:0]` | input | `clk` | 当前节点 ID，不能为 `8'hFF`，因为 `8'hFF` 默认为广播 ID。 |

推荐初始化流程：

```verilog
rst = 1'b1;
repeat (N) @(posedge clk);
rst = 1'b0;

@(posedge clk);
node_id       <= 8'd3;
node_id_valid <= 1'b1;

@(posedge clk);
node_id_valid <= 1'b0;
```

`node_id` 通常只应锁定一次。后续上层不应随意改变 `node_id`。如果需要重新设置节点 ID，建议整体复位 MAC，并确认在线表和去重表是否也需要重新初始化。

---

## 4. 物理层 RX 接口：光模块到 MAC

以端口 0 为例：

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `rx_clk0` | input | 物理层 RX 时钟 | 光模块/解码模块输出数据对应的接收时钟。 |
| `in0[31:0]` | input | `rx_clk0` | 输入到 MAC 的 32-bit word。 |
| `valid_in0` | input | `rx_clk0` | `in0` 当前周期有效。 |

端口 1、2、3 的含义完全相同，只是后缀不同。

物理层必须满足：

1. `inX` 和 `valid_inX` 必须同步于对应的 `rx_clkX`；
2. `valid_inX=1` 的那个 `rx_clkX` 上升沿，`inX` 必须稳定；
3. MAC 输入粒度是 32-bit word；
4. 物理层需要保证 word 顺序正确；
5. 物理层需要完成串并转换、字对齐、解扰、解码、链路恢复等工作；
6. MAC 不负责从串行比特流中恢复 32-bit word 边界。

典型输入时序：

```text
rx_clkX:    ↑    ↑    ↑    ↑    ↑
valid_inX:  0    1    1    1    0
inX:            word0 word1 word2
```

只要 `valid_inX=1`，MAC 就会尝试把 `inX` 写入对应端口的 RX 异步 FIFO。若 FIFO 已满，该 word 会被丢弃，并通过 `rx_overflow` 反映错误状态。

---

## 5. 物理层 TX 接口：MAC 到光模块

以端口 0 为例：

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `tx_clk0` | input | 物理层 TX 时钟 | 物理层发送侧时钟。 |
| `out0[31:0]` | output | `tx_clk0` | MAC 输出的 32-bit word。 |
| `valid_out0` | output | `tx_clk0` | `out0` 当前周期有效。 |

物理层发送模块应在 `valid_outX=1` 的 `tx_clkX` 上升沿采样 `outX`：

```verilog
always @(posedge tx_clk0) begin
    if (valid_out0) begin
        phy0_tx_word  <= out0;
        phy0_tx_valid <= 1'b1;
    end else begin
        phy0_tx_valid <= 1'b0;
    end
end
```

当前 MAC 顶层没有 `phy_tx_ready` 或 `tx_readyX` 输入。因此 MAC 默认物理层 TX 侧在 `valid_outX=1` 时一定能够接收该 word。

如果物理层发送模块存在背压，例如 `phy_tx_ready=0` 时不能接收数据，需要在 MAC 和物理层之间额外增加 TX adapter/FIFO，或者后续扩展 MAC 顶层接口，加入 `tx_readyX`。

如果物理层要求连续码流，可以在 `valid_outX=0` 时由物理层发送 idle word：

```verilog
always @(posedge tx_clk0) begin
    if (valid_out0) begin
        phy0_tx_data  <= out0;
        phy0_tx_valid <= 1'b1;
    end else begin
        phy0_tx_data  <= IDLE_WORD;
        phy0_tx_valid <= 1'b1;
    end
end
```

---

## 6. 上层发送接口：业务逻辑到 MAC

上层发送接口用于让应用层发出一个完整 MAC 帧。上层不需要自己生成同步头、源 ID、帧序号和 CRC，只需要提供目的 ID、payload 长度和 payload 数据。

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `app_frame_valid` | input | `clk` | 上层请求发送一帧。 |
| `app_frame_ready` | output | `clk` | MAC 当前可以接受一帧。 |
| `app_frame_accepted` | output | `clk` | MAC 已接受本帧请求，通常为单周期脉冲。 |
| `app_frame_done` | output | `clk` | MAC 已完成本帧 payload 读取/入队。 |
| `app_dst_id[7:0]` | input | `clk` | 目的节点 ID；`8'hFF` 表示广播。 |
| `app_len16[15:0]` | input | `clk` | payload 长度，单位是 32-bit word。 |
| `app_payload_addr[15:0]` | output | `clk` | MAC 请求读取的 payload word 地址。 |
| `app_payload_data[31:0]` | input | `clk` | 上层返回的 payload word。 |

### 6.1 发送握手规则

上层应在 `app_frame_valid && app_frame_ready` 同一个 `clk` 上升沿提交发送请求。

```verilog
always @(posedge clk) begin
    if (rst) begin
        app_frame_valid <= 1'b0;
        app_dst_id      <= 8'd0;
        app_len16       <= 16'd0;
    end else begin
        if (want_send && app_frame_ready) begin
            app_frame_valid <= 1'b1;
            app_dst_id      <= target_id;
            app_len16       <= payload_len_words;
        end else if (app_frame_valid && app_frame_ready) begin
            app_frame_valid <= 1'b0;
        end
    end
end
```

也可以让 `app_frame_valid` 保持到 `app_frame_ready=1` 后再撤销。

### 6.2 payload 长度限制

普通业务帧必须满足：

```text
1 <= app_len16 <= MAX_PAYLOAD
```

注意：

- `app_len16` 的单位是 32-bit word，不是 byte；
- `app_len16=0` 不能作为普通业务帧发送，零长度广播帧由 MAC 内部用于探活；
- `app_len16 > MAX_PAYLOAD` 时，`app_len_error` 会拉高。

例如要发送 16 字节 payload：

```text
16 bytes = 4 words
app_len16 = 4
```

### 6.3 payload 读取规则

`app_payload_data` 必须在 `app_payload_addr` 同周期有效。也就是说，MAC 当前周期给出：

```verilog
app_payload_addr = 16'd5;
```

同一个 `clk` 周期，上层必须提供：

```verilog
app_payload_data = payload_mem[5];
```

如果上层 payload 存在同步 BRAM 中，常见 BRAM 是第 N 拍给地址、第 N+1 拍出数据，这会导致 payload 整体错位。因此需要增加地址/数据对齐 adapter，或者让上层提供异步读 RAM/寄存器数组形式的数据。

### 6.4 payload 保持要求

从 `app_frame_accepted` 到 `app_frame_done` 之间，上层不应修改本次待发送的 payload 缓冲区。因为 MAC 会在这段时间内根据 `app_payload_addr` 逐 word 读取 payload。

推荐上层发送状态机：

```text
IDLE
  等待 app_frame_ready
  设置 dst/len/payload buffer
  拉高 app_frame_valid

WAIT_ACCEPT
  看到 app_frame_accepted
  锁住 payload buffer，不允许修改

WAIT_DONE
  看到 app_frame_done
  释放 payload buffer，可以准备下一帧
```

---

## 7. 上层接收接口：MAC 到业务逻辑

当 MAC 收到目的 ID 为本节点的帧，或者收到广播数据帧时，会通过 `app_rx_*` 接口上报给上层。

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `app_rx_frame_valid` | output | `clk` | 收到一帧，header 有效。 |
| `app_rx_frame_ready` | input | `clk` | 上层准备好接收 header。 |
| `app_rx_src_id[7:0]` | output | `clk` | 源节点 ID。 |
| `app_rx_dst_id[7:0]` | output | `clk` | 目的节点 ID。 |
| `app_rx_count[15:0]` | output | `clk` | 源节点发出的帧序号。 |
| `app_rx_len16[15:0]` | output | `clk` | payload 长度，单位 32-bit word。 |
| `app_rx_payload_valid` | output | `clk` | payload word 有效。 |
| `app_rx_payload_ready` | input | `clk` | 上层准备好接收 payload word。 |
| `app_rx_payload_addr[15:0]` | output | `clk` | 当前 payload word 序号。 |
| `app_rx_payload_data[31:0]` | output | `clk` | 当前 payload word。 |

### 7.1 接收 header 握手

当 `app_rx_frame_valid=1` 时，以下字段有效：

```verilog
app_rx_src_id
app_rx_dst_id
app_rx_count
app_rx_len16
```

上层准备好后拉高：

```verilog
app_rx_frame_ready = 1'b1;
```

当 `app_rx_frame_valid && app_rx_frame_ready` 成立后，header 被消费。如果 `app_rx_len16 == 0`，该帧没有 payload；如果 `app_rx_len16 > 0`，后续进入 payload 接收阶段。

### 7.2 接收 payload 握手

payload 使用 word 级 valid/ready：

```verilog
if (app_rx_payload_valid && app_rx_payload_ready) begin
    rx_buf[app_rx_payload_addr] <= app_rx_payload_data;
end
```

`app_rx_payload_addr` 从 0 递增到 `app_rx_len16-1`。

推荐上层接收状态机：

```verilog
always @(posedge clk) begin
    if (rst) begin
        app_rx_frame_ready   <= 1'b1;
        app_rx_payload_ready <= 1'b1;
    end else begin
        if (app_rx_frame_valid && app_rx_frame_ready) begin
            rx_src <= app_rx_src_id;
            rx_dst <= app_rx_dst_id;
            rx_cnt <= app_rx_count;
            rx_len <= app_rx_len16;
        end

        if (app_rx_payload_valid && app_rx_payload_ready) begin
            rx_payload_mem[app_rx_payload_addr] <= app_rx_payload_data;
        end
    end
end
```

如果上层暂时不能接收，可以拉低 `app_rx_frame_ready` 或 `app_rx_payload_ready`，MAC 会等待。

---

## 8. 状态与探活接口

| 信号 | 方向 | 时钟域 | 说明 |
|---|---:|---|---|
| `liveness_valid` | output | `clk` | 当前 `liveness_node/liveness_alive` 有效。 |
| `liveness_node[7:0]` | output | `clk` | 当前正在上报的节点 ID。 |
| `liveness_alive` | output | `clk` | 该节点是否在线。 |
| `network_congested` | output | `clk` | 当前发送路径拥塞或无法接受新业务帧。 |
| `app_len_error` | output | `clk` | 上层请求发送的 payload 长度超过 `MAX_PAYLOAD`。 |
| `rx_overflow` | output | `clk` | RX 异步 FIFO 曾经溢出。 |

在线表读取示例：

```verilog
always @(posedge clk) begin
    if (liveness_valid) begin
        alive_table[liveness_node] <= liveness_alive;
    end
end
```

当前默认探活机制：

- MAC 内部周期性发送 `dst=BROADCAST`、`len16=0` 的广播探活帧；
- `LIVENESS_WIN` 默认等于 5；
- 默认 `liveness_timer` 每 1 秒产生一次 tick；
- 因此默认离线检测时间约为 5 秒；
- 任意合法收到的非本节点来源数据帧也会刷新对应源节点的在线状态。

---

## 9. MAC 帧格式

MAC 输出到物理层的 32-bit word 流格式如下：

```text
word0: SYNC_WORD
word1: {src_id[7:0], dst_id[7:0], count[15:0]}
word2: {len16[15:0], 16'h0000}
word3..word(3+len16-1): payload[0..len16-1]
last: CRC32
```

字段说明：

| 字段 | 说明 |
|---|---|
| `SYNC_WORD` | 帧同步字，默认 `32'hA31E57BD`。 |
| `src_id` | 源节点 ID，由 MAC 自动填入本节点 ID。 |
| `dst_id` | 目的节点 ID，由上层 `app_dst_id` 指定。 |
| `count` | 源节点本地递增帧序号，由 MAC 自动生成。 |
| `len16` | payload word 数，单位 32-bit word。 |
| `payload` | 上层业务数据。 |
| `CRC32` | 覆盖 `header1`、`header2` 和 `payload`，不覆盖 `SYNC_WORD`。 |

上层不需要自己生成 `SYNC_WORD`、`src_id`、`count` 或 CRC。上层只需要提供：

```text
app_dst_id
app_len16
payload words
```

---

## 10. 三端口与四端口 wrapper

### 10.1 三端口 `node_top_3port.v`

三端口版本相比双端口多出：

```verilog
input  wire        rx_clk2,
input  wire        tx_clk2,
input  wire [31:0] in2,
input  wire        valid_in2,
output wire [31:0] out2,
output wire        valid_out2
```

内部打包顺序为：

```verilog
rx_clk_bus   = {rx_clk2, rx_clk1, rx_clk0};
tx_clk_bus   = {tx_clk2, tx_clk1, tx_clk0};
in_bus       = {in2, in1, in0};
valid_in_bus = {valid_in2, valid_in1, valid_in0};
```

输出解包顺序为：

```verilog
out0 = out_bus[0*32 +: 32];
out1 = out_bus[1*32 +: 32];
out2 = out_bus[2*32 +: 32];
```

### 10.2 四端口 `node_top_4port.v`

四端口版本相比双端口多出端口 2 和端口 3：

```verilog
input  wire        rx_clk2,
input  wire        rx_clk3,
input  wire        tx_clk2,
input  wire        tx_clk3,
input  wire [31:0] in2,
input  wire [31:0] in3,
input  wire        valid_in2,
input  wire        valid_in3,
output wire [31:0] out2,
output wire [31:0] out3,
output wire        valid_out2,
output wire        valid_out3
```

内部打包顺序为：

```verilog
rx_clk_bus   = {rx_clk3, rx_clk2, rx_clk1, rx_clk0};
tx_clk_bus   = {tx_clk3, tx_clk2, tx_clk1, tx_clk0};
in_bus       = {in3, in2, in1, in0};
valid_in_bus = {valid_in3, valid_in2, valid_in1, valid_in0};
```

输出解包顺序为：

```verilog
out0 = out_bus[0*32 +: 32];
out1 = out_bus[1*32 +: 32];
out2 = out_bus[2*32 +: 32];
out3 = out_bus[3*32 +: 32];
```

对上层 app 接口来说，2/3/4 端口版本完全一致；变化只在物理层端口数量。

---

## 11. 推荐外层命名规范

如果还要再包一层更面向系统集成的顶层，建议使用以下前缀：

| 前缀 | 含义 |
|---|---|
| `sys_*` | 系统控制，例如 `sys_clk`、`sys_rst`。 |
| `cfg_*` | 配置，例如 `cfg_node_id`、`cfg_node_id_valid`。 |
| `phy_rx_*` | 物理层输入到 MAC。 |
| `phy_tx_*` | MAC 输出到物理层。 |
| `app_tx_*` | 上层业务逻辑发送到 MAC。 |
| `app_rx_*` | MAC 上报给上层业务逻辑。 |
| `stat_*` | 状态监控。 |

示例：

```verilog
input  wire        sys_clk,
input  wire        sys_rst,

input  wire        cfg_node_id_valid,
input  wire [7:0]  cfg_node_id,

input  wire        phy_rx_clk0,
input  wire [31:0] phy_rx_data0,
input  wire        phy_rx_valid0,

output wire [31:0] phy_tx_data0,
output wire        phy_tx_valid0,

input  wire        app_tx_valid,
output wire        app_tx_ready,
output wire        app_tx_accepted,
output wire        app_tx_done,
input  wire [7:0]  app_tx_dst_id,
input  wire [15:0] app_tx_len_words,
output wire [15:0] app_tx_payload_addr,
input  wire [31:0] app_tx_payload_data,

output wire        app_rx_valid,
input  wire        app_rx_ready,
output wire [7:0]  app_rx_src_id,
output wire [7:0]  app_rx_dst_id,
output wire [15:0] app_rx_count,
output wire [15:0] app_rx_len_words,
output wire        app_rx_payload_valid,
input  wire        app_rx_payload_ready,
output wire [15:0] app_rx_payload_addr,
output wire [31:0] app_rx_payload_data,

output wire        stat_liveness_valid,
output wire [7:0]  stat_liveness_node,
output wire        stat_liveness_alive,
output wire        stat_network_congested,
output wire        stat_app_len_error,
output wire        stat_rx_overflow
```

这一层 wrapper 只做改名和信号重排，不改变 `node_top` 内部逻辑。

---

## 12. 最小调用流程总结

### 12.1 发送一帧

```text
1. 上层准备 payload buffer。
2. 设置 app_dst_id 和 app_len16。
3. 等待 app_frame_ready=1。
4. 拉高 app_frame_valid。
5. 看到 app_frame_accepted 后锁住 payload buffer。
6. 根据 app_payload_addr 输出对应 app_payload_data。
7. 看到 app_frame_done 后释放 payload buffer，可以准备下一帧。
```

### 12.2 接收一帧

```text
1. app_rx_frame_valid=1 时读取 src/dst/count/len。
2. 拉高 app_rx_frame_ready 接收 header。
3. 若 len>0，等待 app_rx_payload_valid。
4. 每次 app_rx_payload_valid && app_rx_payload_ready 时保存 payload word。
5. 收到 app_rx_len16 个 word 后该帧结束。
```

### 12.3 物理层 RX

```text
1. 在 rx_clkX 域给出 32-bit word。
2. valid_inX=1 表示该 word 有效。
3. MAC 自动跨到 clk 域解析。
```

### 12.4 物理层 TX

```text
1. MAC 在 tx_clkX 域输出 outX。
2. valid_outX=1 时 outX 有效。
3. 物理层在 valid_outX=1 的 tx_clkX 上升沿采样 outX。
```

---

## 13. 接入时常见错误

### 13.1 `app_payload_data` 没有和 `app_payload_addr` 同周期匹配

这是最常见问题。如果上层使用同步 BRAM，必须增加一层 adapter，否则 payload 会整体错位。

### 13.2 把 `app_len16` 当作 byte 数

`app_len16` 的单位是 32-bit word，不是 byte。

### 13.3 用 `app_len16=0` 发送普通业务包

普通业务包长度必须大于 0。零长度广播帧由 MAC 内部作为探活包使用。

### 13.4 物理层没有提供 32-bit 对齐 word

MAC 不做串并转换、CDR、字对齐、8b/10b、扰码等物理层处理。

### 13.5 物理层 TX 有背压但 MAC 顶层没有 ready

当前 MAC TX 侧只有 `outX/valid_outX`，没有 `tx_readyX`。如果物理层可能暂停，需要加 adapter/FIFO。

### 13.6 `network_congested=1` 时仍强行提交发送请求

上层必须遵守 valid/ready 规则。只有 `app_frame_valid && app_frame_ready` 成立时，发送请求才被 MAC 接受。

### 13.7 忽略 `rx_overflow`

`rx_overflow=1` 表示 RX FIFO 曾在满状态下收到有效 word，可能已经丢失数据。上层应记录该错误，必要时触发链路恢复或重新初始化。
