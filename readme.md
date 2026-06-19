# network_8

基于 FPGA 的环形光互联网络节点原型工程，面向多节点板卡之间的数据转发、广播探活、去重和链路健壮性验证。

## 项目概览

- 以 `node_top.v`/`node.v` 保留双端口板级兼容入口，实际可参数化逻辑位于 `node_core.v`。
- 支持单播数据包、广播数据包与广播状态包。
- 使用同步头、长度字段和 CRC32 完成帧同步、边界保护和完整性校验。
- 通过上报/转发两张去重表分别抑制重复上报和重复转发，通过滑动窗口维护节点在线状态。
- 采用模块化架构：模块按功能边界拆分，各自维护独立的轻量 FSM，通过标准握手接口互联。

## 目录结构

```text
constrs_1/imports/example_design/    Vivado 约束文件
sim_1/imports/simulation/functional/ 初始化数据文件
sources_1/imports/example_design/    示例设计导入文件
sources_1/new/                       自定义核心模块
sources_1/ip/                        Vivado FIFO IP 核
docs/architecture.md                 详细设计文档
```

## 模块层次结构

```
node.v (兼容性封装，仅实例化 node_top)
  └── node_top.v (2 光口板级 wrapper，保持旧接口)
      └── node_core.v (NUM_PORTS 可参数化核心，使用扁平端口总线)
        ├── node_id_latch.v          — 首次脉冲 ID 锁存
        ├── port_cdc.v               — 异步 FIFO 跨时钟域 + 端口输出寄存器
        │     └── async_fifo.v ×(2×NUM_PORTS) — 每端口 RX/TX 各一个异步 FIFO
        ├── frame_rx.v ×NUM_PORTS    — 每端口独立帧接收状态机
        ├── rx_dispatcher.v          — 帧分类与本地分发
        ├── rx_report_fifo.v         — 接收上报同步 FIFO + app_rx 读出重组
        ├── liveness_timer.v         — 1 秒定时器
        ├── liveness_table.v         — 滑动窗口生存状态表
        ├── local_packet_generator.v — 本地帧描述符生成（数据包/探活包）
        ├── forward_engine.v         — 转发去重 + 转发决策
        │     └── dedup_table.v      — 上报/转发去重表复用实现
        ├── tx_enqueue_engine.v      — 本地包/转发包组帧 + 按端口入队
        │     └── crc32_calc.v       — CRC32 计算引擎
        ├── tx_frame_fifo.v ×NUM_PORTS — 主 clk 域每端口完整帧队列
        ├── frame_meta_fifo.v ×NUM_PORTS — 每端口帧长度/入队时间队列
        └── port_tx_queue_sender.v ×NUM_PORTS — 队列到 TX async FIFO 搬运器
```

## 核心模块

### `node_top.v` — 2 光口板级 wrapper

保留现有板级接口和工程入口，仍使用 `rx_clk0/rx_clk1`、`tx_clk0/tx_clk1`、`in0/in1`、`out0/out1`、`valid_in0/valid_in1`、`valid_out0/valid_out1`。内部将两个端口打包为 `node_core` 的扁平总线：

- `rx_clk_bus = {rx_clk1, rx_clk0}`
- `tx_clk_bus = {tx_clk1, tx_clk0}`
- `in_flat = {in1, in0}`
- `valid_in_bus = {valid_in1, valid_in0}`

`out0/out1` 和 `valid_out0/valid_out1` 从 `node_core` 的 `out_flat/valid_out` 拆出。此 wrapper 固定实例化 2 个光口，用于保持当前 Vivado 工程兼容。

### `node_core.v` — 参数化网络核心

真正参数化的纯连线核心，将所有功能模块按数据流连接在一起。不含协议过程逻辑，仅做实例化和总线拼接。端口使用 `NUM_PORTS` （`NUM_PORTS >= 2`）展开的扁平总线：

```verilog
input  wire [NUM_PORTS-1:0]    rx_clk,
input  wire [NUM_PORTS-1:0]    tx_clk,
input  wire [NUM_PORTS*32-1:0] in_flat,
input  wire [NUM_PORTS-1:0]    valid_in,
output wire [NUM_PORTS*32-1:0] out_flat,
output wire [NUM_PORTS-1:0]    valid_out
```
`app_payload_addr/app_payload_data` 接口默认假设：
`app_payload_addr` 给出后，`app_payload_data` 在同一周期内已经对应当前地址有效。
因此，上层若使用组合读 RAM，可直接连接。

若上层使用同步 BRAM，由于 BRAM 读数据通常延迟 1 个 clk 周期，
上层必须自行完成地址/数据对齐：例如对 `app_payload_addr` 打一拍后作为 BRAM 读地址，
并保证返回到 app_payload_data 的数据正好对应网络层当前正在发送的 payload word。

其余 `app_frame_*`、`app_rx_*`、生存状态和 `network_congested` 接口语义与 `node_top` 保持一致。支持的参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `SYNC_WORD` | `32'hA31E57BD` | 帧同步头 |
| `BROADCAST` | `8'hFF` | 广播地址 |
| `MAX_PAYLOAD` | `256` | 最大 payload（words） |
| `LIVENESS_WIN` | `5` | 存活滑动窗口宽度 |
| `NODE_COUNT` | `255` | 最大节点数 |
| `DEDUP_DEPTH` | `64` | 上报去重表和转发去重表深度 |
| `FIFO_DEPTH` | `8192` | 异步 FIFO 深度 |
| `RX_REPORT_FIFO_DEPTH` | `2048` | 接收上报同步 FIFO 深度 |
| `CLK_FREQ_HZ` | `160_000_000` | 主时钟频率 |
| `CONGEST_TIMEOUT_SEC` | `5` | 拥塞阻塞超时秒数 |
| `TX_QUEUE_TIMEOUT_SEC` | `CONGEST_TIMEOUT_SEC` | 发送队列队首帧超时秒数 |
| `TX_QUEUE_TIMEOUT_CYCLES` | `CLK_FREQ_HZ * TX_QUEUE_TIMEOUT_SEC` | 发送队列队首帧超时周期数 |
| `NUM_PORTS` | `2` | `node_core` 光模块端口数 |

### `node.v` — 兼容性封装

与 `node_top.v` 的接口完全一致，内部仅做参数传递和端口直连。保留此模块以兼容旧版工程入口。

### `node_id_latch.v` — 节点 ID 锁存器

仅响应复位释放后的**第一次** `node_id_valid` 脉冲，锁存 `node_id` 幅值为本机 ID。后续脉冲全部忽略。锁存前 `id_locked=0`，所有下游逻辑均处于复位状态，忽略所有数据流动。

- 输入: `node_id_valid`, `node_id`
- 输出: `my_id`, `id_locked`

### `port_cdc.v` — 端口跨时钟域

隔离光模块接口时钟域（`rx_clk[p]`, `tx_clk[p]`）与内部主时钟域：

- 在每个 `rx_clk[p]` 域独立同步 `id_locked` 和 `rst`，作为 RX FIFO 写使能和复位控制
- 在每个 `tx_clk[p]` 域独立同步 `rst`，用于端口输出寄存器复位
- 每端口实例化一对 `async_fifo`（RX + TX）
- 保留 TX FIFO 写时钟域的 `wr_data_count` 状态输出；整帧空间预检查由主时钟域每端口 `tx_frame_fifo` 的 `data_count` 完成
- TX 侧持续监测 FIFO 非空，在端口自己的 `tx_clk[p]` 域输出 `out_flat[p*32 +: 32]` 和 `valid_out[p]`

### `frame_rx.v` — 帧接收器

每个端口实例化一个，8 状态 FSM 完成帧同步与校验：

| 状态 | 功能 |
|------|------|
| HUNT | 扫描同步字 `0xA31E57BD`，命中后初始化 CRC |
| HEADER1 | 提取 `(srcID, dstID, count)` |
| HEADER2 | 提取 `len16`，若 `> MAX_PAYLOAD` 则丢弃回到 HUNT |
| PAYLOAD | 按 word 读入 payload buffer |
| CRC | 读取接收端 CRC 值，对本地 CRC 计算执行 finalize |
| CRC_WAIT | 等待 `crc32_calc` 的时序输出更新 |
| CHECK | 比较本地 CRC 与接收 CRC，一致则置 `frame_ready=1` |
| DONE | 等待上层 `frame_consumed` 后释放 |

### `rx_dispatcher.v` — 帧分类与本地分发

从多端口 Round-Robin 轮询已就绪的帧，按优先级分类处理：

- **SELFCHK**: `srcID == my_id` → 丢弃（自己发出的包绕回），不走后续去重路径
- **LIVENESS**: 任意 CRC 正确且 `srcID != my_id` 的帧都会用 `srcID` 更新生存状态表
- **REPORT DEDUP**: 对满足 `local_should_deliver` 的帧先查询上报去重表；只有未上报过的 `(srcID,count)` 才写入接收上报同步 FIFO，完整写入后再插入上报去重表
- **FORWARD DEDUP**: `srcID != my_id` 的帧全部提交给 `forward_engine` 查询转发去重表；已经成功转发过的帧不再转发
- **LOCAL DELIVERY**: 未上报过的新帧且满足 `local_should_deliver` 条件（`dstID == my_id` 或 `dstID == 0xFF && len16 > 0`）→ 先写入接收上报同步 FIFO，再由 FIFO 读侧通过 `app_rx_*` 接口反馈给上层
- **DISCARD**: 不需要本地上报且不需要转发的帧直接丢弃；重复上报和重复转发分别由两张去重表独立抑制

10 状态 FSM: `POLL → CLASSIFY → (REPORT_LOOKUP → REPORT_DECIDE) → FWD_REQ → FWD_WAIT → (LOCAL_ROOM → LOCAL_HDR0 → LOCAL_HDR1 → LOCAL_PAY) / POLL`

### `forward_engine.v` — 转发去重与转发引擎

所有非本机源帧的**转发去重入口**，只判断该帧是否已经成功转发过：

- S_IDLE: 等待候选帧，接受 `rx_dispatcher` 发来的候选
- S_LOOKUP: 查询转发去重表，检查 `(srcID, count)` 是否已成功转发过
- S_DECIDE: 去重决策
  - 已转发过：置 `candidate_duplicate=1`，本次不再转发
  - 未转发过且无需转发（`!candidate_should_forward`）：置 `candidate_done`，不插入转发去重表
  - 未转发过且需要转发：提交 `forward_req` 给 `tx_enqueue_engine`
- S_REQ: 等待 `tx_enqueue_engine` 返回；只有 `forward_accept=1 && forward_dropped=0` 时才插入转发去重表。若所有目标端口队列都没有完整帧空间，`forward_dropped=1`，该帧不会被标记为已转发，后续重复到达时仍可再次尝试转发
- 输出 `candidate_duplicate` 表示“转发重复”，不再参与本地上报去重

- 当前转发策略为 best-effort per-port enqueue。
对于 NUM_PORTS > 2 的复杂拓扑，若部分目标端口跳过，后续不会由转发层自动补发。
若需要可靠多路径传播，应增加 per-port pending mask 或 ACK/重传机制。

### `tx_enqueue_engine.v` — 发送入队引擎

仲裁并组帧本地包（来自 `local_packet_generator`）和转发包（来自 `forward_engine`）：

- 转发包优先级高于本地包
- 完整帧格式保持 `SYNC_WORD`、`{src,dst,count}`、`{len16,16'd0}`、payload、CRC32
- CRC32 只覆盖 header1/header2/payload，不覆盖 `SYNC_WORD`
- 每帧入队前按 `4 + len16` 检查目标端口 `tx_frame_fifo` 剩余空间；空间不足的端口不写，避免半帧
- 本地包只写入当前有足够空间的端口队列；`network_congested` 面向上层 app 帧按当前 `app_len16 + 4` 检查空间，小包不再要求端口必须能容纳 `MAX_PAYLOAD + 4` 的最大帧
- 转发包只写入 `forward_port_mask` 中有足够空间的端口；若所有目标端口都不可用，`forward_accept=1` 且 `forward_dropped=1`
- payload 读取使用 `payload_index`，它只是本地 buffer/RAM 索引，不是协议帧字段

### `tx_frame_fifo.v` / `frame_meta_fifo.v` / `port_tx_queue_sender.v` — 每端口发送队列

- `tx_frame_fifo` 是主 `clk` 域同步 FIFO，word 宽度 34bit，格式为 `{sof,eof,data[31:0]}`
- `frame_meta_fifo` 与 `tx_frame_fifo` 一一对应，每帧保存 `{enqueue_time, frame_words}`；`tx_enqueue_engine` 在完整帧入队完成时同步写入 meta
- 每个端口各有一个独立队列，端口之间不再共享 `frame_tx` 的 payload 推进节拍
- `port_tx_queue_sender` 将该端口队列中的 32bit data word 搬运到 `port_cdc.v` 原有 TX async FIFO；async FIFO `full=1` 时暂停该端口，不影响其他端口继续发送
- 若队首帧尚未开始写入 TX async FIFO，且 `current_time - enqueue_time >= TX_QUEUE_TIMEOUT_CYCLES`，`port_tx_queue_sender` 进入 DROP 状态，连续读出 `frame_words` 个 word 并丢弃，同时弹出 meta；DROP 不写 TX async FIFO
- 一旦某帧已经开始写入 TX async FIFO，sender 会尽量等待 `full` 解除并写完整帧，不在帧中途超时丢弃
- 该超时机制不是可靠传输机制，被丢弃的帧不会由网络层自动重传
- port_tx_queue_sender 的超时丢弃仅作用于尚未开始写入 TX async FIFO 的队首帧。
一旦某帧已经开始写入 TX async FIFO，sender 会等待该端口 tx_full 解除后继续写完该帧。
因此，若外部链路长期不读取导致 TX async FIFO 长期 full，该端口会保持暂停状态，直到外部链路恢复；该行为只影响对应端口，不影响其他端口。

### `local_packet_generator.v` — 本地包生成器

生成两种本地帧描述符：

1. **数据帧**: 当上层 `app_frame_valid && app_frame_ready` 时，锁存 `app_dst_id` / `app_len16`，生成帧描述符；payload 通过 `app_payload_addr` 逐 word 读取 `app_payload_data`
2. **探活帧**: 无上层数据帧请求时，每秒自动生成一个 `dstID=0xFF, len16=0` 的广播状态包

- 数据帧优先级高于探活帧
- `app_frame_accepted` 只表示发送请求描述符已锁存，不表示 payload 已经读完
- `app_frame_done` 是本地 app 数据帧完成信号；上层必须等到它置位后才能释放或改写本次 payload RAM
- `app_len16 > MAX_PAYLOAD` 时 `app_frame_ready` 保持低电平，并通过 `app_len_error` 提示上层；已接受的数据帧直接使用 `app_len16` 作为 `packet_len16`，不会再做截断
- `network_congested=1` 时压低 `app_frame_ready`，禁止上层继续写入新数据包；该信号按当前合法 `app_len16 + 4` 判断是否至少有一个端口能容纳完整帧，避免小包被最大帧空间判断误阻塞
- 维护 `count` 计数器（数据帧和探活帧共用）

### `liveness_timer.v` — 探活定时器

从主时钟频率参数自动计算 1 秒计数阈值，产生 `tick_1s` 脉冲。

### `liveness_table.v` — 生存状态表

滑动窗口探活机制，窗口大小 5：

- 收到 `(srcID, count)` 的帧时将窗口对应位 LSB 置 1
- 每 1 秒所有窗口左移一位，启动逐节点上传状态机
- 上传阶段每拍输出一个节点，`alive = |window[node]`
- 窗口内容不受 `rst` 清零控制

### `dedup_table.v` — 去重表

FIFO 老化机制，深度 64。以 `(srcID, count)` 为去重键。当前系统实例化两张表：

- **上报去重表**：位于 `rx_dispatcher`，只在本地上报帧完整写入 `rx_report_fifo` 后插入，用于避免同一数据包重复上报给上层
- **转发去重表**：位于 `forward_engine`，只在转发请求被 `tx_enqueue_engine` 确认为非丢弃完成后插入，用于避免同一数据包重复转发；所有目标端口队列都无完整帧空间时不会插入，因此后续重复包仍有机会再次转发

- lookup: 遍历所有有效条目匹配
- insert: 写指针处写入新条目；表满时覆盖最老条目

### `crc32_calc.v` — CRC32 计算模块

以太网标准 CRC-32（多项式 `0x04C11DB7`），generate 块展开为 32 级纯组合逻辑 LFSR，单周期处理一个 32-bit word。

### `async_fifo.v` — 异步 FIFO

跨时钟域 FIFO 包装器，采用 **First Word Fall Through (FWFT)** 模式：

- `USE_IP=1`（默认）: 实例化 Vivado `fifo_generator_32_512` IP 核
- `USE_IP=0`（仿真）: 纯 RTL 行为模型（双口 RAM + 格雷码指针 + 两级同步器）
- 导出写时钟域 `wr_data_count`，保留给端口级 TX async FIFO 状态观测；完整帧空间预检查在主时钟域的 `tx_frame_fifo` 上完成

### `sync_fifo.v` — 同步 FIFO

同频域 FIFO 参考实现，基于双指针 + 计数器管理空满状态，支持同时读写。

### `rx_report_fifo.v` — 接收上报 FIFO

本地上报数据在送到上层前先进入 `fifo_generator_sync` 同步 FIFO。FIFO 宽度 32bit，深度 2048，配置为 FWFT，并导出 12bit `data_count`。

- 写侧由 `rx_dispatcher` 驱动，格式为 `{srcID,dstID,count}`、`{len16,16'h0}`、payload words
- 写入前使用 `data_count` 预检查 `2 + len16` 个 word 的完整空间，避免上报 FIFO 中出现半帧
- 读侧重组 header，继续通过原有 `app_rx_frame_valid/ready` 与 `app_rx_payload_valid/ready` 给上层读取
- Yosys/仿真可通过 `USE_IP=0` 使用 `sync_fifo` 行为模型；Vivado 默认实例化 `fifo_generator_sync`

## 数据流概览

```
光模块 RX → async_fifo (rx_clk* → clk) → frame_rx → rx_dispatcher
                                                         ├── self-check (srcID == my_id) → 丢弃
                                                         ├── 存活性更新 → liveness_table
                                                        ├── local_should_deliver → 上报去重表 → rx_report_fifo → app_rx_* 上层接口
                                                        └── (srcID != my_id) 全部 → forward_engine (转发去重)
                                                                                      └── 未转发过 && 需转发 → tx_enqueue_engine
                                                                                                                     ├── tx_frame_fifo ×NUM_PORTS
                                                                                                                     │     └── port_tx_queue_sender ×NUM_PORTS
                                                                                                                     │           └── async_fifo (clk → tx_clk*) → 光模块 TX
                                                                                                                     └── local_packet_generator ← app_frame_* 上层接口
                                                                                                                           └── liveness_timer (1s tick)
```

## 协议摘要

- 拓扑：双端口环形互联，节点自发包向两个方向扩散
- 地址：`0x00` 到 `0xFE` 为单播地址，`0xFF` 为广播地址；`dstID=0xFF,len16=0` 是状态包，`dstID=0xFF,len16>0` 是广播数据包
- 帧格式：同步头 + 头部字段 `{srcID, dstID, count}` + `{len16, reserved}` + 可变长 payload + CRC32
- `app_payload_addr` / `app_rx_payload_addr` 是上层本地 payload RAM 的读写索引，不属于帧格式
- 健壮性：`len16` 限制最大 payload 256 words，异常帧直接丢弃
- 去重键：`(srcID, count)`
- 在线判定：最近 5 个周期内任意一次收到即判定在线

## 当前状态

- 工程已完成模块化 RTL 拆分，各模块职责清晰、接口标准化
- `node.v` 为兼容性封装，`node_top.v` 为 2 光口板级 wrapper，实际可参数化逻辑入口为 `node_core.v`
- 生产环境中 `async_fifo.v` 优先实例化 Vivado FIFO IP（`fifo_generator_32_512.xci`），该 FIFO IP 已经被设定为 FWFT 模式；TX 整帧空间预检查位于每端口主时钟域 `tx_frame_fifo`，队首帧超时丢弃由 `frame_meta_fifo` 和 `port_tx_queue_sender` 完成
- 接收上报路径使用 Vivado `fifo_generator_sync` 同步 FIFO IP（`sources_1/ip/fifo_generator_sync/fifo_generator_sync.xci`），32bit 宽、FWFT、有 `data_count` 接口；上层 `app_rx_*` 从该 FIFO 的读侧获取数据
- 当前转发策略为 best-effort per-port enqueue。
对于 NUM_PORTS > 2 的复杂拓扑，若部分目标端口跳过，后续不会由转发层自动补发。
若需要可靠多路径传播，应增加 per-port pending mask 或 ACK/重传机制。

## 使用建议

1. 在 Vivado 中导入 `sources_1`、`constrs_1` 和 `sim_1` 对应文件
2. 当前双光口工程以 `sources_1/new/node_top.v` 为板级入口检查接口兼容性；扩展更多光口时以 `sources_1/new/node_core.v` 为核心入口配置 `NUM_PORTS`
3. 先完成单节点环回或双节点最小系统仿真，再扩展到多节点组网验证

## 仿真测试

### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_ring.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 仿真工具 | iverilog 12.0 / Vivado XSim |
| Yosys 版本 | 0.9 |
| 测试日期 | 2026-06-19 |
| RTL 版本 | commit `051ce58` |

### Yosys 综合检查

```
read_verilog: 22 files 通过
hierarchy -top node_top: 22 modules
proc: 通过
check: 通过 (0 errors, 0 warnings)
opt:  通过 (1074 changes)
```

设计统计: 6305 cells, 93650 wire bits, 14 memories (1.3 Mbits)

### 8 节点环形拓扑

```
Node0 -- Node1 -- Node2 -- Node3 -- Node4 -- Node5 -- Node6 -- Node7 -- (回 Node0)

连接: node[i].out0 → node[(i+1)%8].in1 (顺时针)
      node[i].out1 → node[(i+7)%8].in0 (逆时针)
链路: 1 拍 pipeline 寄存
时钟: 统一 100 MHz (CLK_PERIOD=10 ns)，rx_clk/tx_clk 均接主 clk
```

### 测试用例

| # | 测试 | 发送方 | 目标 | Payload | 预期 |
|---|------|--------|------|---------|------|
| 1 | 单播跨环 | Node0 → Node4 | 4 words (A000_0000..) | Node4 收到，无重复上报 |
| 2 | 反方向单播 | Node5 → Node1 | 3 words (B000_0000..) | Node1 收到，payload 正确 |
| 3 | 广播数据包 | Node2 → 0xFF | 2 words (C000_0000..) | 其余 7 节点各收 1 次 |
| 4 | 连续小包 ×5 | Node0 → Node3 | 1 word ×5 (D000_0000..) | Node3 收 5 个不同 count 包 |
| 5 | 最大 payload | Node6 → Node7 | 256 words (E000_0000..) | Node7 收完整 256 word，无 len_error |

### 测试结果 (iverilog 12.0, 2026-06-19)

**历史状态: 阻塞 — TX 通路无输出（已被后续 LINKSEQ/RXSEQ 诊断更新）**

| 检查项 | 结果 |
|--------|------|
| iverilog 编译 | 通过 (0 errors) |
| Yosys 综合检查 | 通过 |
| 复位/ID 分配 | 通过 (`send_app_frame` 完成握手，`app_frame_done` 正常脉冲) |
| `network_congested` | 0 (未拥塞) |
| `valid_out0/valid_out1` (全节点) | 历史观测曾记录为始终为 0；后续诊断已确认 Node0 的 `valid_out0/valid_out1` 会拉高 |
| `received_frame_count` (全节点) | 全 0 — 无节点收到任何帧 |

**历史根本原因分析 (已被后续诊断更新):**

测试平台中 `send_app_frame` 任务正确完成了 `app_frame_valid/ready` 握手和 `app_frame_done` 等待，
帧已由 `tx_enqueue_engine` 写入 per-port `tx_frame_fifo`/`frame_meta_fifo` 队列，
早期曾判断 `port_tx_queue_sender` → TX async FIFO → `port_cdc` 输出寄存器链路上 `valid_out` 始终为 0。
后续 `LINKSEQ/RXSEQ` 诊断已确认 Node0 有 TX 输出，当前重点改为排查 TX/link 首字重复。

**排查方向:**
- `port_tx_queue_sender` 是否进入 S_DROP（超时丢弃）或停在 S_IDLE
- TX async FIFO 的 `wr_en` / `full` / `empty` 信号状态
- `port_cdc` 中 `rst_tx_sync` 是否持续拉高阻塞输出
- `id_locked` 两级同步到 `tx_clk` 域的时序

### 修复的仿真基础设施问题

| 问题 | 修复 |
|------|------|
| `sim/ip_stubs.v` 中 `fifo_generator_32_512`/`fifo_generator_sync` 的 `empty` 在 reset 后错误设为 0 | 重写为完整行为模型（格雷码指针 + 两级同步器） |
| iverilog 不支持 task 数组参数 | 改为模块级全局数组 `expected_counts_g` |
| `assign_node_ids` 中 `@(negedge rst)` 死等 | 移除，改为相对延时 |
| `app_payload_data` 重复声明、`generate` 变量名冲突 | 拆分 g_payload / g_node 独立 generate 块 |

### 运行仿真

**iverilog (命令行):**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -o sim_build\tb_8node_ring.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v
vvp sim_build\tb_8node_ring.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_ring.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_ring`
3. Run Behavioral Simulation
4. 在波形中追踪 `u_node[0].u_node_core.g_tx[0].u_port_tx_queue_sender.*` 定位 TX 阻塞点

## 详细设计

完整设计说明见 [docs/architecture.md](docs/architecture.md)。

## 修改要求

1. 节点编号改为外部输入脉冲赋值，所有的逻辑都在脉冲赋值后运行，在此之前忽略任何数据流动，且只关注第一个脉冲，后续的脉冲全部忽略
2. 是否发送数据帧由上层模块给信号控制，数据帧内容（包括目的节点，数据长度，数据内容）也由上层模块给出，没有数据帧时就发送生存状态帧
3. 接收机收到数据帧也可以据此获知 srcID 对应的节点存活
4. 生存状态帧数据不随复位清零，不受复位控制
5. 向多个发送端口写入同一个帧前，使用每端口 `tx_frame_fifo` 的 `data_count` 检查整帧空间；空间不足的端口跳过，不写入半帧
6. `network_congested` 按当前上层 `app_len16 + 4` 判断完整帧空间，禁止上层写入当前无端口可容纳的新包并暂停 RX 继续读入；当前转发包所有目标端口都不可用时返回 `forward_dropped`

## 本次修改范围

- `tx_enqueue_engine.v`：把 `network_congested` 从“按最大帧空间预检”改成“按当前 `app_len16 + 4` 真实帧长预检”，并保留 `local_room_mask` 作为本地请求的实际入队目标选择。
- `node_core.v`：补接 `app_frame_valid` / `app_len16` 到 `tx_enqueue_engine`。
- `tb_8node_ring.v`：修复 Test 1 检查流程，加入 `LINKDBG` / `RXDBG` / `FWDDBG` 分层调试和自动诊断摘要。
- `docs/architecture.md`：同步记录 `network_congested` 的新语义。

## 本次仿真结论

- `iverilog -g2012 -o sim_build/tb_8node_ring.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`：通过。
- `vvp sim_build/tb_8node_ring.vvp`：Test 1 超时失败，但已不再误查 `last_rx_*`，会先打印 `Node4 未收到任何 app_rx 帧` 再输出诊断。
- `LINKDBG`：Node1 / Node7 的第一跳都看到了 `0xA31E57BD`，说明环网连线和首拍数据确实到达 RX 侧。
- `RXDBG`：Node1 / Node7 的 `frame_rx` 没有拉起 `frame_ready`，且 `crc_res` / `crc_rcv` 不一致。
- 自动诊断结论：`RX FIFO/frame_rx/CRC parse problem; inspect frame_rx.st, crc_res, crc_rcv.`

这说明当前失败点更靠近 RX 解析链路，而不是 Test 1 的判定逻辑本身。

## FIFO 模型对比调试结论

本轮在 `tb_8node_ring.v` 中为 Test 1 增加了 `LINKSEQ`、`RXSEQ` 和更详细的 `RXDBG` 字段，覆盖 Node1 port1 与 Node7 port0 的首跳输入、RX FIFO 读出、`frame_rx.sid/did/cnt/plen/tlen/wi` 以及 CRC 状态。同时在 `async_fifo.v` 中增加 `IVERILOG_BEHAV_FIFO` 仿真宏：默认 Vivado/RTL 行为仍按 `USE_IP=1` 实例化 FIFO IP，只有 iverilog 编译加入 `-DIVERILOG_BEHAV_FIFO` 时才强制使用内置行为模型。

两组命令均可完成编译，但 `vvp` 都在 Test 1 超时退出：

- stub 模式：`iverilog -g2012 -o sim_build/tb_8node_ring_stub.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`
- 行为 FIFO 模式：`iverilog -g2012 -DIVERILOG_BEHAV_FIFO -o sim_build/tb_8node_ring_behav.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`

两种模式的关键前 8 个 word 完全一致：

- Node1/Node7 `LINKSEQ`: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`
- Node1/Node7 `RXSEQ`: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`

因此当前自动诊断结论是：同一首跳端口在链路输入侧已经看到连续两个 `SYNC_WORD`，RX FIFO 读出只是复现了该序列；这不像是 `sim/ip_stubs.v` 的 FIFO IP stub 单独造成的问题。优先怀疑 `port_cdc` TX 输出时序或 testbench link pipeline 在 `valid/data` 对齐上重复了首字。`frame_rx` 中 `sid/did/plen/wi` 错位和 CRC 不一致是后续结果：第二个 `SYNC_WORD` 被当作 header1 消费，导致最后一个 payload 被误当作 CRC。下一步应继续在 Node0 `valid_out0/valid_out1` 和 `port_cdc` TX 侧增加 TXSEQ，对比 TX async FIFO 读出、TX sender 输出与 testbench link 输入，暂不需要先大改 `frame_rx` 或协议格式。

## TXSEQ 分层调试结论

本轮继续在 `tb_8node_ring.v` 中增加 Node0 TX 侧分层序列监控：`ENQSEQ`、`QSEQ`、`TXWRSEQ`、`TXFIFOSEQ`、`OUTSEQ`，并保留已有 `LINKSEQ/RXSEQ/RXDBG/FWDDBG`。两种仿真模式仍然都能完成编译，但 Test 1 都会超时：

- stub 模式：`iverilog -g2012 -o sim_build/tb_8node_ring_stub.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`
- 行为 FIFO 模式：`iverilog -g2012 -DIVERILOG_BEHAV_FIFO -o sim_build/tb_8node_ring_behav.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`

两种模式的关键前 8 个 word 一致：

- Node0 `ENQSEQ` port0/port1: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- Node0 `QSEQ` port0/port1: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- Node0 `TXWRSEQ` port0/port1: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`
- Node0 `TXFIFOSEQ` port0/port1: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`
- Node0 `OUTSEQ` port0/port1: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`
- Node1/Node7 `LINKSEQ`: `a31e57bd a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003`

因此重复 `SYNC_WORD` 第一次出现在 `TXWRSEQ`，而不是 `tx_enqueue_engine` 写入侧、`tx_frame_fifo` 读出侧、TX async FIFO、`port_cdc` 输出寄存器或 testbench link pipeline。当前定位结论是：`port_tx_queue_sender` 写 TX FIFO 的时序重复了第一个队列 word。更具体地说，`QSEQ` 已经按正确顺序从 `tx_frame_fifo` 看到 `SYNC/header1/header2/...`，但 `TXWRSEQ` 写入 TX FIFO 时变成 `SYNC/SYNC/header1/...`，后续 RX CRC 错位只是这个 TX 侧重复首字的结果。

建议的最小 RTL 修复方向是只改 `port_tx_queue_sender.v` 的读写协议：不要在拉起 `frame_rd_en` 的同一个周期直接把当前 `frame_dout` 写入 TX FIFO；应把 FIFO 读出 word 先锁存成一拍有效数据，再用该锁存数据产生 `tx_wr_en/tx_din`。这样可以避免同步 FIFO 的注册读使能让 sender 消费到上一拍队头 word。协议格式、`frame_rx`、CRC 和 per-port FIFO 结构暂时不需要改。

## 发布脚本

仓库新增了一个 PowerShell 发布脚本：[`scripts/publish_to_main.ps1`](scripts/publish_to_main.ps1)。

它只接受显式路径，避免把 `sim_build/` 之类的临时文件误提交到主线。示例：

```powershell
.\scripts\publish_to_main.ps1 -Message "fix tx/rx debug" -Paths `
    readme.md `
    sim_1/new/tb_8node_ring.v `
    sources_1/new/async_fifo.v `
    scripts/publish_to_main.ps1
```

脚本会在 `main` 分支上完成 `git add`、`git commit` 和 `git push origin main`，因此可以直接把当前改动发布到 GitHub 的 `main`。
