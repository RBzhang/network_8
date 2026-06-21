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
- `tx_frame_fifo` 和 `frame_meta_fifo` 内部使用自定义 `sync_fifo`（FWFT 输出缓存），非标位宽（34-bit / 48-bit）不适合直接使用 Vivado FIFO IP
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

### 测试结果 (2026-06-20, Vivado/XSim + iverilog 12.0)

**Vivado/XSim 行为仿真：ALL TESTS PASSED**

```
TEST 1: Unicast cross-ring (Node0 -> Node4) — OK
TEST 2: Reverse unicast (Node5 -> Node1) — OK
TEST 3: Broadcast data (Node2 -> all others) — OK
TEST 4: Continuous small packets ×5 (Node0 -> Node3) — OK
TEST 5: Max payload len=256 (Node6 -> Node7) — OK
ALL TESTS PASSED
```

**iverilog stub 仿真：ALL TESTS PASSED**

```
iverilog -g2012 -o sim_build/tb_8node_ring_stub.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v
vvp sim_build/tb_8node_ring_stub.vvp
```

5 项测试全部通过。rx_overflow 粘性标志在所有节点上均有记录（广播测试瞬时 FIFO 满载触发），不影响帧正确投递。

### 节点初始化变体测试 (2026-06-21, Vivado/XSim)

新增独立 testbench `sim_1/new/tb_8node_init_variants.v`，验证 8 节点在多种 `node_id_valid` 初始化顺序、部分初始化和重复 ID 脉冲下的鲁棒性。该 testbench 复用 `tb_8node_ring.v` 的 8 节点例化与环形连接方式，不修改原有 testbench。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_init_variants.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 仿真工具 | Vivado XSim |
| 测试日期 | 2026-06-21 |

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | 正序初始化 | 依次初始化 Node0→Node7，执行 Node0→4、Node3→7、Node6→1 单播 | 目标节点只收一次，非目标不误收 |
| 2 | 反序初始化 | 依次初始化 Node7→Node0，执行 Node0→5、Node2→6 单播 + Node1→all 广播 | 反序不影响通信；广播所有节点各收一次 |
| 3 | 随机序初始化 | 按 3,0,7,2,6,1,5,4 固定伪随机序初始化，执行 Node0→4、Node5→1 | 跨环通信正常 |
| 4 | 部分节点未初始化发包 | 只初始化 Node0-3，发送 Node0→Node4（目标未初始化），再补初始化 Node4-7，再次 Node0→Node4 | 无错误上报/未知节点乱收包/仿真卡死；补初始化后正常通信 |
| 5 | 重复 node_id_valid | Node3 首次锁 ID=3，二次脉冲给 ID=6，验证 Node0→3 成功、Node0→6 不被 Node3 错收 | `node_id_latch` 只锁第一次有效脉冲 |

#### 测试结果

**Vivado/XSim 行为仿真：ALL INIT VARIANT TESTS PASSED**

```
CASE 1: Sequential init Node0 -> Node7    — PASSED
CASE 2: Reverse init Node7 -> Node0       — PASSED
CASE 3: Random order init 3,0,7,2,6,1,5,4 — PASSED
CASE 4: Partial init, send, then complete — PASSED
CASE 5: Duplicate node_id_valid           — PASSED
ALL INIT VARIANT TESTS PASSED
$finish called at time : 167095 ns
```

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_init_variants.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_init_variants`
3. Run Behavioral Simulation

### 全节点单播矩阵测试 (2026-06-21, Vivado/XSim)

新增独立 testbench `sim_1/new/tb_8node_unicast_matrix.v`，对 8 节点环网执行完整的 8×7=56 条单播路径覆盖测试。每条路径使用轮换的 payload 长度，payload 内容编码 src/dst/test_index 便于定位错误。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_unicast_matrix.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 仿真工具 | Vivado XSim |
| 测试日期 | 2026-06-21 |

#### 测试设计

- **payload 长度轮换**：`{1, 2, 3, 4, 7, 16, 64, 256}`，按 `test_index % 8` 循环，每个长度覆盖 7 条路径
- **base_data 编码**：`32'h1000_0000 + (src<<16) + (dst<<8) + test_index`，payload word k = base_data + k
- **逐包确认**：每包流程为 快照基线 → 发包 → 等目标收到 → 校验 header+payload → 验证非目标无误收 → wait_network_idle

#### 测试用例

| src | dst 覆盖 | 路径数 | payload 长度分布 |
|-----|----------|--------|-----------------|
| 0 | 1,2,3,4,5,6,7 | 7 | len=1,2,3,4,7,16,64 |
| 1 | 0,2,3,4,5,6,7 | 7 | len=256,1,2,3,4,7,16 |
| 2 | 0,1,3,4,5,6,7 | 7 | len=64,256,1,2,3,4,7 |
| 3 | 0,1,2,4,5,6,7 | 7 | len=16,64,256,1,2,3,4 |
| 4 | 0,1,2,3,5,6,7 | 7 | len=7,16,64,256,1,2,3 |
| 5 | 0,1,2,3,4,6,7 | 7 | len=4,7,16,64,256,1,2 |
| 6 | 0,1,2,3,4,5,7 | 7 | len=3,4,7,16,64,256,1 |
| 7 | 0,1,2,3,4,5,6 | 7 | len=2,3,4,7,16,64,256 |

#### 测试结果

**Vivado/XSim 行为仿真：ALL UNICAST MATRIX TESTS PASSED (56/56)**

```
8-NODE UNICAST MATRIX TEST: 56 paths (8 src x 7 dst)
============================================================
  PASS [1/56] Node0 -> Node1   len=1
  PASS [2/56] Node0 -> Node2   len=2
  ...
  PASS [56/56] Node7 -> Node6  len=256
============================================================
 ALL UNICAST MATRIX TESTS PASSED  (56/56)
============================================================
```

56 条单播路径全部可达，非目标节点无误收，payload 校验全部通过。rx_overflow 仅在广播/大 payload 测试中有瞬时记录，不影响帧正确投递。

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_unicast_matrix.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_unicast_matrix`
3. Run Behavioral Simulation

### 并发流量测试 (2026-06-21, Vivado/XSim)

新增独立 testbench `sim_1/new/tb_8node_concurrent_traffic.v`，验证多节点同时发包时 `tx_enqueue_engine`、`rx_dispatcher`、`forward_engine`、去重表和每端口 TX 队列不会互相干扰。使用 scoreboard 机制匹配预期帧与接收帧，避免到达顺序不确定导致误判。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_concurrent_traffic.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 仿真工具 | Vivado XSim |
| 测试日期 | 2026-06-21 |

#### 测试用例

| # | Case | 并发模式 | 验证点 |
|---|------|---------|--------|
| 1 | 四个源→四个不同目的 | Node0→4, 1→5, 2→6, 3→7 同时 | 各目标收 1 帧，payload 正确 |
| 2 | 反向交叉 | Node7→3, 6→2, 5→1, 4→0 同时 | 反方向交叉通信正常 |
| 3 | 四源同目的 | Node0,1,2,7 同时→Node4 | Node4 收 4 帧，src 各不同，payload 不混乱 |
| 4 | 广播+单播混合 | Node2→广播(len=2) + Node0→3(len=4) + Node5→1(len=3) | 7 节点各收广播 1 次，单播目标正确收到 |

#### 测试结果 (初次运行)

**Vivado/XSim 行为仿真：Case 1 失败（0 帧接收）**

```
Case 1: 4 concurrent unicasts to distinct destinations
  Scoreboard Case 1: 0/4 frames matched OK
FAIL Case 1: Node 4 expected src=0 fdst=4 len=4 base=a1000000 NOT received
FAIL Case 1: Node 5 expected src=1 fdst=5 len=3 base=a2000000 NOT received
FAIL Case 1: Node 6 expected src=2 fdst=6 len=7 base=a3000000 NOT received
FAIL Case 1: Node 7 expected src=3 fdst=7 len=2 base=a4000000 NOT received
FAIL Case 1: matched 0/4 expected, received 0 total frames
$fatal at 25195 ns
```

**初步分析：** Case 1 中 4 个并发源节点均未成功发出任何帧（0 frames received）。可能原因：
- `send_concurrent` 任务的并发 valid 握手时序与 `local_packet_generator` 的 `app_frame_ready` 条件存在竞态
- `tx_enqueue_engine` 的 `network_congested` 在并发场景下压低 `app_frame_ready`，导致 `app_frame_accepted` 无法触发
- 需要在 Vivado 中追踪 `app_frame_valid[0..3]`、`app_frame_ready[0..3]`、`app_frame_accepted[0..3]` 波形定位握手失败点

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_concurrent_traffic.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_concurrent_traffic`
3. Run Behavioral Simulation

### 修复的 RTL 问题汇总

| # | 问题 | 修复 | 文件 |
|---|------|------|------|
| 1 | `port_tx_queue_sender` 在同一周期 `frame_rd_en + tx_wr_en`，与 FIFO 读时序冲突导致首字重复 | 改为 S_IDLE→S_LOAD→S_WRITE→S_POP_WAIT：S_LOAD 锁存 frame_dout，S_WRITE 写 TX FIFO 成功后拉 frame_rd_en | `port_tx_queue_sender.v` |
| 2 | `port_cdc` TX FIFO 读侧 `.rd_en(!tx_empty)` 组合直连，跨时钟域下可能读到不稳定的 dout | 改为 tx_rd_en_r + tx_pop_pending 安全读法：先锁存 dout，再分两拍完成 rd_en 和 valid_out 清零 | `port_cdc.v` |
| 3 | `forward_engine` 中 `forward_accept` 后 `forward_req` 未撤销时重复采样同一 forward descriptor | 增加 `forward_ack_wait` 状态，等待 `forward_req` 下降后再接受新请求 | `tx_enqueue_engine.v` |
| 4 | `payload_is_forward` 在空闲态抢占 `frame_rx.payload_index` | 限制为 `active_forward && (st == S_PAYLOAD)` 时才有效 | `tx_enqueue_engine.v` |
| 5 | `rx_report_fifo` 读侧 `fifo_dout` 错位导致 Test2 len=1281 | 增加 R_HDR1_WAIT / R_PAYLOAD_WAIT 状态解耦读时序 | `rx_report_fifo.v` |
| 6 | **Test1 首字丢失（根因）**：`tx_enqueue_engine` 中 task 使用阻塞赋值 (`=`) 设置 `queue_din_flat`，在 always 块求值阶段即刻生效。sync_fifo 在同一 posedge 读取时可能看到**下一个 enqueue 状态覆盖后的值**（HEADER1=00040000），而非当前状态的值（SYNC=a31e57bd） | task 删除，改为 always 块内直接使用 NBA (`<=`) + for 循环。NBA 更新延迟到所有 always 块求值完成之后，sync_fifo 读取时始终看到稳定旧值 | `tx_enqueue_engine.v` |
| 7 | `sync_fifo` 使用组合读 `assign dout = mem[rd_ptr]`，在 Vivado/XSim 中表现不稳定 | 改为显式 FWFT 输出缓存：`dout_r` + `out_valid`，写入空 FIFO 直接旁路，内存读取使用 NBA | `sync_fifo.v` |

### Vivado/XSim Test1 调试过程

**问题现象：** `node0_q_port*_first_words` 以 `00040000` 开头（第二字），而非 `a31e57bd`（首字）。ENQ 写入侧正确，错误最早出现在 `tx_frame_fifo` 读出后的 Q 层。后续 TXWR、OUT、LINK、RX 均为已错误序列的传播。

**排查过程：**
1. `port_tx_queue_sender` 诊断：S_LOAD 首次看到的 `frame_dout` 已是 `00040000`，排除 sender 自身问题
2. `sync_fifo` FWFT 改造：组合读 → 输出缓存，Vivado 结果未变
3. **最终定位**：`tx_enqueue_engine.v` 中 `set_all_queue_words` task 用 `=` 设置 `queue_din_flat`（BA），与 sync_fifo 的 `posedge` 读取形成跨模块求值顺序竞争。iverilog 求值顺序恰使 sync_fifo 先读到 SYNC_WORD；Vivado/XSim 顺序相反，enqueue engine 先覆盖为 HEADER1 值

**验证：** 修复后 Vivado/XSim 全部 5 项测试通过，`node0_q_port*_first_words` 正确以 `a31e57bd` 开头。

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

## port_tx_queue_sender 修复后验证

已修复 `port_tx_queue_sender.v` 的读写时序：状态机从原先在同一拍 `frame_rd_en + tx_wr_en + tx_din <= frame_dout`，改为 `S_IDLE -> S_LOAD -> S_WRITE`。`S_LOAD` 只从 `tx_frame_fifo` 取 word 并预置 `tx_din/word_buf`，`S_WRITE` 在下一拍且 `!tx_full` 时才拉高 `tx_wr_en`。若 `tx_full=1`，`word_valid` 和 `tx_din` 保持不变；最后一个 word 成功写入 TX FIFO 后才拉高 `meta_rd_en`。`S_DROP` 仍只用于尚未开始发送的队首帧超时丢弃，不写 TX FIFO。

两组 iverilog 编译均通过：

- stub 模式：`iverilog -g2012 -o sim_build/tb_8node_ring_stub.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`
- 行为 FIFO 模式：`iverilog -g2012 -DIVERILOG_BEHAV_FIFO -o sim_build/tb_8node_ring_behav.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_ring.v`

两组 `vvp` 均不再卡在 Test 1。Test 1 `Node0 -> Node4` 已通过，`TXWRSEQ` 已与 `QSEQ` 对齐：

- `ENQSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- `QSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- `TXWRSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- `TXFIFOSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- `OUTSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`
- `LINKSEQ/RXSEQ`: `a31e57bd 00040000 00040000 a0000000 a0000001 a0000002 a0000003 527e65fd`

完整 5 项测试尚未全部通过：Test 2 `Node5 -> Node1` 暴露新的失败点，Node1 最终检查到 `expected len=3, got len=1281`。日志显示第一份转发帧可以按 `05010000 00030000 b0000000 b0000001 b0000002 3ba7f20a` 到达 Node1，但随后又出现第二份同源同 count 的重复转发帧，其中 Node0 转发侧 `QSEQ/TXWRSEQ` payload 变成 `00000000 00000000 00000000`。该问题已经超出本轮 `port_tx_queue_sender` 同拍写修复范围，下一步应单独检查转发去重和 `tx_enqueue_engine` 读取 forward payload 时的 `payload_index/payload_data` 稳定时序。

## Vivado XSim 仿真修复

Vivado 行为级仿真 `[USF-XSim-62] elaborate step failed` 的根因是 `fifo_generato_txframe` 和 `fifo_generator_meta` 两个 IP 的仿真源文件未被 Vivado 编译进 `sim_1` 仿真文件集。

- **根因**：`fifo_generato_txframe` 和 `fifo_generator_meta` 在 `.xpr` 中位于独立的 `BlockSrcs` 文件集，`sim_1` 文件集的 `SrcSet` 仅指向 `sources_1`，不包含这两个 BlockSrcs IP。`xvlog` 分析阶段只编译了 `fifo_generator_32_512`（在 `sources_1` 内）和 `fifo_generator_sync`，未编译 `fifo_generato_txframe` 和 `fifo_generator_meta`。elaborate 阶段因找不到模块 `fifo_generato_txframe` 而失败。
- **修复**：
  - `sim/ip_stubs.v` 新增 `fifo_generato_txframe`（34-bit × 8192, FWFT）和 `fifo_generator_meta`（48-bit × 512, FWFT）行为 stub 模块，与已有的 `fifo_generator_32_512` / `fifo_generator_sync` stub 风格一致。
  - `gtwizard_0_ex.xpr` 的 `sim_1` 文件集中加入 `sim/ip_stubs.v`，`UsedIn=simulation`，确保 Vivado XSim 编译时包含 stub 定义。
- **影响范围**：`sim/ip_stubs.v`、`gtwizard_0_ex.xpr`。
- **iverilog 兼容**：iverilog 编译命令已包含 `sim/ip_stubs.v`，自动获得新 stub。

## rx_overflow 诊断逻辑修复

Vivado 行为级仿真中所有 5 项测试通过，但末尾出现全节点 `rx_overflow asserted` warning。旧逻辑的根因与修复如下：

- **旧逻辑** (`node_core.v`)：在 `clk` 域直接采样 `|rx_full`（跨域不严谨），且仅凭 `rx_full=1` 置 sticky，不检查 `valid_in`；`rx_full=1` 不代表输入 word 被丢弃（FIFO 满后下一个 `valid_in` 才触发丢弃）。
- **新逻辑** (`port_cdc.v` + `node_core.v`)：
  - `port_cdc.v` 每个端口在 `rx_clk[p]` 域检测 `valid_in[p] && id_locked_rx_sync && rx_full[p]`，置 sticky `rx_overflow_rx`，表示有输入 word 因 FIFO 满被丢弃。
  - 通过 2-FF CDC 同步器将 `rx_overflow_rx` 同步到 `clk` 域 → `rx_overflow_ports[p]`。
  - `node_core.v` 将 `rx_overflow_ports` OR 为标量 `rx_overflow = |rx_overflow_ports`，port_cdc 内已是 sticky，无需 node_core 再 sticky。
- **影响范围**：`port_cdc.v`（新增 `rx_overflow` 输出端口 + rx_clk 域检测 + CDC 同步器）、`node_core.v`（添加 `rx_overflow_ports` 连线，删除旧的 `rx_overflow_r` 逻辑）。
- **未修改**：主数据通路（`sync_fifo`, `tx_frame_fifo`, `frame_meta_fifo`, `port_tx_queue_sender`, `tx_enqueue_engine`, `frame_rx`, `forward_engine`）。
- **iverilog 回归**：stub 模式 ALL TESTS PASSED，无 `rx_overflow` warning。
- **Vivado 预期**：用户需本地重新运行 Vivado XSim，预期 ALL TESTS PASSED 且不再出现全节点 rx_overflow warning。

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
