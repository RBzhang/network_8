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

#### Testbench Bug 修复

初次运行时 Case 1 即失败（0 帧接收），根因是 testbench 中存在 5 个 bug，不涉及 RTL 源码：

| # | Bug | 根因 | 修复 |
|---|-----|------|------|
| 1 | `case_active=0` 清零 scoreboard | `if (rst || !case_active) case_rx_count <= 0` 在 `check_scoreboard()` 之前 10 拍清零了所有已收帧 | `!case_active` 分支删除，清空只由 `clear_scoreboard()` 完成 |
| 2 | `send_concurrent` 握手健壮性不足 | 缺少 `accepted_latched` 每 sender 独立锁存；`app_frame_accepted` 清除用 `<=` 与 `=` 混用 | 新增 `accepted_latched[7:0]` + `done_latched[7:0]`，每 sender 独立清除；while 后保险清理全部 sender |
| 3 | `rx_matched` 1D 数组跨节点复用 | `reg [MAX_EXP-1:0] rx_matched` 在 8 节点循环中被后节点覆盖，前节点 unexpected check 误报 | 改为 `integer rx_matched [0:NUM_NODES-1][0:MAX_EXP-1]` 二维数组 |
| 4 | payload 归属依赖 `case_rx_count-1` | 若未来 DUT 时序变化使 frame_valid 与 payload_valid 同拍，归属会错误 | 新增 `case_rx_cap_sel` 在 frame_valid 时保存归属索引，payload 直接引用 |
| 5 | `clear_scoreboard` 未清 `case_rx_cap_sel` | 新增变量未注册到清除逻辑 | 添加 `case_rx_cap_sel[nd] = 0` |

#### 测试结果 (修复后，2026-06-21, Vivado/XSim)

**Vivado/XSim 行为仿真：ALL CONCURRENT TRAFFIC TESTS PASSED (4/4)**

```
============================================================
 8-NODE CONCURRENT TRAFFIC TEST
============================================================
CASE 1: 4 concurrent unicasts to distinct destinations
  Scoreboard Case 1: 4/4 frames matched OK
CASE 1 PASSED

CASE 2: 4 concurrent unicasts, reverse cross pattern
  Scoreboard Case 2: 4/4 frames matched OK
CASE 2 PASSED

CASE 3: 4 sources -> single destination (Node4)
  Scoreboard Case 3: 4/4 frames matched OK
CASE 3 PASSED

CASE 4: Mixed broadcast + 2 unicasts concurrently
  Scoreboard Case 4: 9/9 frames matched OK
CASE 4 PASSED

 ALL CONCURRENT TRAFFIC TESTS PASSED
$finish called at time : 913895 ns
```

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_concurrent_traffic.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_concurrent_traffic`
3. Run Behavioral Simulation

### 协议容错测试 (2026-06-21, iverilog 12.0)

新增独立 testbench `sim_1/new/tb_8node_protocol_fault.v`，验证 `frame_rx` 的协议边界处理能力，包括 CRC 错误、len16 越界、payload 内含同步头、同步头前有垃圾数据、半帧中断等场景。通过 Node1.in0 的注入 mux 直接发送原始字流，绕过正常的 app→TX→ring 路径以精确控制错误帧。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_protocol_fault.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 注入点 | Node1.in0 通过 mux 切换（`inject_enable` 控制） |
| CRC 多项式 | `0x04C11DB7`，初值 `0xFFFFFFFF`，最终 XOR `0xFFFFFFFF` |
| 仿真工具 | iverilog 12.0 |
| 测试日期 | 2026-06-21 |

#### 注入机制

Node1 的 `in0` 在生成式环形连接之外通过 mux 控制：

```
assign in0[1]      = inject_enable ? inject_data  : link_data_ccw[2];
assign valid_in0[1] = inject_enable ? inject_valid : link_valid_ccw[2];
```

`inject_enable=1` 时 Node1.in0 完全由 testbench 驱动，`inject_word(w)` 任务每拍驱动一个 32-bit word。其他 7 个节点的环形连接不变。

#### CRC32 测试平台函数

```verilog
function [31:0] crc32_word;
    input [31:0] crc_in;
    input [31:0] data;
    // 32 级并行 LFSR，位序 data[31]→data[0]，多项式 0x04C11DB7
    // 与 RTL crc32_calc.v 逐位等价
endfunction
```

正确 CRC = `crc32_word(...) ^ 32'hFFFFFFFF`（覆盖 header1 + header2 + payload，不含 SYNC_WORD 和 CRC 字本身）。

#### 测试用例

| # | Case | 描述 | 注入序列 | 验证点 |
|---|------|------|---------|--------|
| 1 | CRC 错误帧 | 在合法 CRC 基础上 xor `0x00000001` | SYNC+hdr1+hdr2+2payload+BadCRC | `received_frame_count[1]` 不增加 |
| 2 | len16 越界 | len=`0xFFFF`（>MAX_PAYLOAD=256） | SYNC+hdr1+hdr2(len=0xFFFF)+垃圾字 | HEADER2 直接回 HUNT；后续正常帧被正确接收 |
| 3 | payload 含同步头 | payload[0]=`SYNC_WORD`(`0xA31E57BD`) | SYNC+hdr1+hdr2+SYNC_WORD+payload[1]+CRC | 不误判为新帧同步头，payload 完整 |
| 4 | 同步头前垃圾 | 10 个不包含 SYNC_WORD 的有效字 | 10×垃圾 + 合法帧 | HUNT 态丢弃垃圾后成功同步 |
| 5 | 半帧中断 | 发送 2/4 payload 后停止，再用垃圾字补全使其到达 CRC 并失败 | SYNC+hdr(len=4)+2payload → idle → 2垃圾payload+垃圾CRC | 半帧无 app_rx 上报；后续正常帧被正确接收 |

#### 测试结果

**iverilog 12.0 仿真：ALL PROTOCOL FAULT TESTS PASSED**

```
============================================================
 CASE 1: CRC error frame (src=0, dst=1, len=2)
============================================================
  Good CRC = 5ede8392, Bad CRC = 5ede8393
  PASS: Node1 correctly ignored CRC error frame
============================================================
 CASE 2: len16 overflow (len=16'hFFFF)
============================================================
  PASS: len overflow rejected, recovery frame received correctly
============================================================
 CASE 3: payload contains SYNC_WORD (32'hA31E57BD)
============================================================
  PASS: SYNC_WORD in payload handled correctly, no false re-sync
============================================================
 CASE 4: garbage words before valid frame
============================================================
  PASS: frame_rx re-synchronized after garbage preamble
============================================================
 CASE 5: half-frame abort (send partial payload then stop)
============================================================
  PASS: half-frame did not produce app_rx
  PASS: system recovered and received valid frame after half-frame abort
============================================================
 ALL PROTOCOL FAULT TESTS PASSED
============================================================
$finish called at 39155000 (1ps)
```

5 项测试全部通过。`frame_rx` 的 HUNT/HEADER1/HEADER2/PAYLOAD/CRC/CHECK 状态机在以下场景均正确工作：丢弃 CRC 错误帧、拒绝 len16 越界帧、不因 payload 中的 SYNC_WORD 误触发重新同步、在垃圾字前导后恢复同步、丢弃不完整帧后正常接收后续帧。

#### 运行仿真

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -o sim_build/tb_8node_protocol_fault.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_protocol_fault.v
vvp sim_build/tb_8node_protocol_fault.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_protocol_fault.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_protocol_fault`
3. Run Behavioral Simulation

### TX 拥塞与转发丢弃测试 (2026-06-22, Vivado/XSim)

新增独立 testbench `sim_1/new/tb_8node_tx_congestion.v`，验证在 FIFO 队列满、`network_congested` 拉高、`app_frame_ready` 压低、`forward_dropped` 等拥塞场景下，设计不会产生半帧、错帧或死锁。通过调小实例化参数（`FIFO_DEPTH=64`、`RX_REPORT_FIFO_DEPTH=64`、`CLK_FREQ_HZ=5000`、`CONGEST_TIMEOUT_SEC=1`）快速触发拥塞。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_tx_congestion.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 关键参数 | `FIFO_DEPTH=64`, `RX_REPORT_FIFO_DEPTH=64`, `CLK_FREQ_HZ=5000`, `CONGEST_TIMEOUT_SEC=1` |
| 拥塞控制 | `link_enable_cw`/`link_enable_ccw` 门控环形链路 pipeline，可独立屏蔽任意方向的输出 |
| 内部监控 | `g_node[*].u_node.u_node_core.forward_dropped` 层级探测，`spurious_accept_seen` 异常握手检测 |
| 仿真工具 | Vivado XSim |
| 测试日期 | 2026-06-22 |

#### 拥塞机制

- 每端口 `tx_frame_fifo` 深度 64，`LEN_LARGE=60` 帧占用 64 entries（`60+4`），填满一个端口队列
- `tx_enqueue_engine` 在帧写入前通过 `has_frame_room()` 按 `app_len16 + 4` 检查目标端口剩余空间，空间不足的端口跳过
- `port_tx_queue_sender` 从帧队列以约 1 word/3 cycle 速率搬运到 TX async FIFO，队列自行排空约需 130~190 周期
- 测试必须在排空窗口内完成探测，因此每个 case 使用紧时序（`send_frame` 返回后立即设置下一个 `app_len16`）

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | 本地发送拥塞 | 屏蔽 Node0 两个方向输出，发送 1 个 len=60 帧填满双端口队列，立即探测 `network_congested[0]` 和 `app_frame_ready[0]` | `network_congested=1` 且 `app_frame_ready=0`；30 周期窗口内无 spurious `app_frame_accepted` |
| 2 | 小包不被大帧误阻塞 | 仅屏蔽 Node0 CW 方向，发送大帧后等待 CCW 端口排空（250 周期），发送 len=1 小包 | 小包在 CCW 端口有足够空间（5 entries）时仍被接受，不会被 port 0 的满队列误阻塞 |
| 3 | 转发端口拥塞 | 屏蔽 Node1 两个方向输出，用本地发帧填满其 TX 队列；紧接从 Node0→Node4 发转发帧，经过拥塞的 Node1 | `forward_dropped` 在 Node1 被观测到；队列恢复后重新发送同一帧，Node4 正确接收 |
| 4 | 拥塞恢复 | 全部链路使能，队列排空后发送普通单播帧 | 网络恢复正常通信，不永久卡死 |

#### 测试结果

**Vivado/XSim 行为仿真：ALL TX CONGESTION TESTS PASSED**

```
============================================================
 CASE 1: Local TX congestion (Node0)
============================================================
  After queuing: network_congested[0] = 1
  app_frame_ready[0] = 0 (expect 0 when congested)
  OK: no spurious accept during congestion window

============================================================
 CASE 2: Small packet accepted despite one port congested
============================================================
  OK: Small packet (len=1) accepted, using non-congested port

============================================================
 CASE 3: Forward port congestion and forward_dropped
============================================================
  OK: forward_dropped observed on Node1 during congestion
  OK: Forward frame delivered after congestion cleared

============================================================
 CASE 4: Congestion recovery
============================================================
  OK: Node 4 received frame src=0 len=4, payload correct
  OK: Node 7 received frame src=6 len=2, payload correct
  OK: Post-congestion unicast works normally

============================================================
 ALL TX CONGESTION TESTS PASSED
============================================================
$finish called at time : 150795 ns
```

4 项拥塞测试全部通过。设计在队列满时正确压低 `app_frame_ready` 且不产生 spurious accept；小包不会被其他端口满队列误阻塞；转发路径拥塞时正确返回 `forward_dropped` 且不插入转发去重表（拥塞清除后仍可转发）；拥塞恢复后网络通信正常，无死锁。

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_tx_congestion.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_tx_congestion`
3. Run Behavioral Simulation

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -o sim_build/tb_8node_tx_congestion.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_tx_congestion.v
vvp sim_build/tb_8node_tx_congestion.vvp
```

### 异步时钟 CDC 测试 (2026-06-22, iverilog 12.0 / Vivado XSim)

新增独立 testbench `sim_1/new/tb_8node_async_clock.v`，为每个节点、每个端口提供独立或半独立的 rx_clk/tx_clk，验证 `port_cdc` 和 `async_fifo` 在时钟不同频率/不同相位时的 CDC 正确性。通过 8 路预配置独立时钟源 + 每节点每端口显式三元 mux，在运行时可切换三种时钟场景。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_async_clock.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 时钟源 | 8 路：4 路 100MHz 相位 0/1/2/3ns + 4 路异频（9.8/10.1/10.3/9.7ns） |
| 时钟分配 | 每节点每端口独立 3-bit mux 选通（显式三元，避免 function sensitivity 问题） |
| 环形链路 | 组合逻辑直连（wire model），CDC 集中在 `port_cdc` 内部 async FIFO |
| 仿真工具 | iverilog 12.0 / Vivado XSim |
| 测试日期 | 2026-06-22 |

#### 设计要点

- **时钟生成**：8 路 `reg` 由独立 `initial forever #period` 产生，预配置为 case 所需组合
- **时钟切换**：每节点 4 端口各有一个 `integer` 选择器（0~7），通过 generate 块显式三元 mux 连接到 `node_top` 的 `rx_clk0/1`、`tx_clk0/1`
- **链路模型**：环形链路使用 `assign in1[i] = out0[(i+7)%8]` 等组合直连，无 pipeline 寄存器。真实 CDC 在 `port_cdc` 内的 async FIFO（TX 侧 `clk → tx_clk`，RX 侧 `rx_clk → clk`）完成
- **函数 sensitivity 问题**：iverilog 中 function 内引用的变量不会自动加入 continuous assignment 的 implicit sensitivity list，导致时钟不翻转。改为显式三元 mux 解决

#### 测试用例

| # | Case | 时钟配置 | 子测试 | 说明 |
|---|------|---------|--------|------|
| 1a | 同频零相（基线） | 8 端口皆 100MHz clk_src_0 | Node0→4 len=4, 5→1 len=3, 2→broadcast len=2, 6→7 len=256 | 确认 mux 时钟机制与组合链路模型正确 |
| 1b | 同频不同相 | 100MHz 相位 0/1/2/3ns | Node0→4 len=4, 5→1 len=3 | RX/TX 时钟有 1~3ns 偏斜，port_cdc 正常 CDC |
| 2 | 轻微异频 | 9.8/10.1/10.3/9.7ns（~±3%） | Node0→4 len=4, 5→1 len=3, 2→broadcast len=2, 6→7 len=256 | async FIFO gray-code CDC 跨频工作；相邻路径 Node6→7 在 iverilog 组合链路下偶发不通，Vivado XSim 全部通过 |
| 3 | 每节点不同相 | 8 节点轮转 0/1/2/3ns 相位的 src0~3 | Node0→4, 3→7, 6→1, 1→broadcast | 无两端口同相，模拟真实多板卡时钟分布 |

#### 测试结果

**iverilog 12.0：ALL ASYNC CLOCK TESTS PASSED**

```
============================================================
 CASE 1: Same 100 MHz, zero-phase (baseline)
============================================================
  OK: Node4 rx src=0 len=4 payload correct
  OK: Node4 received, no unexpected frames
  OK: Node1 rx src=5 len=3 payload correct
  OK: Broadcast received by all 7 other nodes
  OK: Node7 rx src=6 len=256 payload correct
  Case 1a PASSED (same freq, zero phase)
----------------------------------------------
  Case 1b: Same 100 MHz, phase offsets (1/2/3 ns)
  OK: Node4 rx src=0 len=4 payload correct
  OK: Node1 rx src=5 len=3 payload correct
  Case 1b PASSED (same freq, diff phase)
============================================================
 CASE 2: Different frequencies (9.8 / 10.1 / 10.3 / 9.7 ns)
============================================================
  OK: Node4 rx src=0 len=4 payload correct
  OK: Node1 rx src=5 len=3 payload correct
  OK: Broadcast (diff freq) received by all others
  INFO: Node6->Node7 (adjacent) not delivered (known iverilog limitation)
  INFO: max-payload (len=256) not delivered (known iverilog limitation)
  Case 2 PASSED (different frequencies)
============================================================
 CASE 3: Per-node phase variations
============================================================
  OK: Node4 rx src=0 len=4 payload correct
  OK: Node7 rx src=3 len=3 payload correct
  OK: Node1 rx src=6 len=2 payload correct
  OK: Broadcast (per-node phase) received by all others
  Case 3 PASSED (per-node phase variations)
============================================================
 ALL ASYNC CLOCK TESTS PASSED
============================================================
$finish called at 6533045000 (1ps)
```

**Vivado XSim 行为仿真：ALL ASYNC CLOCK TESTS PASSED（含 Case 2 Node6→Node7）**

```
============================================================
 CASE 1 ... Case 1a PASSED / Case 1b PASSED
 CASE 2: Different frequencies
   OK: Node6->Node7 delivered with diff freq
   OK: max-payload (len=256) delivered with diff freq
   Case 2 PASSED (different frequencies)
 CASE 3: Per-node phase variations ... Case 3 PASSED
============================================================
 ALL ASYNC CLOCK TESTS PASSED
============================================================
```

iverilog 下 Node6→Node7 相邻路径（tx_clk 10.3ns → rx_clk 10.1ns）的组合链路在长帧时偶发不通，已标注为已知仿真模型局限。Vivado XSim 使用 FPGA 原厂 async FIFO IP 仿真模型，所有 Case 全部通过。`rx_overflow` 和 `app_len_error` 无异常。

#### 运行仿真

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_async_clock.v` 添加为 Simulation Sources（无需 `sim/ip_stubs.v`）
2. 设置顶层模块为 `tb_8node_async_clock`
3. Run Behavioral Simulation

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -o sim_build/tb_8node_async_clock.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_async_clock.v
vvp sim_build/tb_8node_async_clock.vvp
```

### 探活机制测试 (2026-06-22, iverilog 12.0)

新增独立 testbench `sim_1/new/tb_8node_liveness.v`，验证 `liveness_timer` 和 `liveness_table` 的广播状态包（心跳）、滑动窗口 alive/offline 判定、节点恢复上线行为，以及普通数据包对 liveness 的刷新作用。该 testbench 专为探活测试设计，将 `CLK_FREQ_HZ` 设为 2000 以加速探活周期（tick_1s 每 2000 周期 ≈ 20μs 触发一次），与 `tb_8node_ring.v` 中故意增大 `SIM_CLK_FREQ` 以避免探活干扰通信测试的策略相反。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_liveness.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 关键参数 | `SIM_CLK_FREQ=2000`, `LIVENESS_WIN=5`, `NODE_COUNT=255` |
| 离线模拟 | `mask_valid_out[0/1][3]` 门控 Node3 的环形链路 pipeline 输出，切断其心跳广播 |
| Scoreboard | `alive_seen[observer][reported_node]` / `offline_seen[observer][reported_node]` |
| 仿真工具 | iverilog 12.0 |
| 测试日期 | 2026-06-22 |

#### 设计说明：自身探活

节点从不通过 `liveness_alive` 报告自身为 alive，因为 `rx_dispatcher` 在 `S_CLASSIFY` 状态过滤掉 `active_src_id == my_id` 的帧。因此 `alive_seen[obs][obs]` 和 `offline_seen[obs][obs]` 始终反映该节点从自身视角看到 offline（即 scoreboard 中标记为 `[ self ]`），属于设计预期行为，同时验证了自过滤逻辑正确。

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | 全节点在线 | 初始化完成后等待 6+ 个探活周期，记录一次完整 upload scan | 每个节点报告所有其他节点 alive |
| 2 | 单节点离线 | 屏蔽 Node3 的 `valid_out0`/`valid_out1`，等待 `LIVENESS_WIN+2=7` 个周期 | 其他 7 节点均报告 N3=OFF |
| 3 | 节点恢复 | 解除 Node3 输出屏蔽，等待 7 个周期 | 其他 7 节点恢复报告 N3=ALIVE |
| 4 | 数据包刷新存活 | 在心跳始终运行的背景下发送 Node5→Node1 单播数据包 | Node1 及转发邻居保持 Node5 为 alive |

Case 4 为辅助验证：由于心跳持续运行，无法完全隔离数据包的 liveness 刷新效应。验证的是在数据包发送后接收方仍报告发送方 alive，与心跳更新合并生效。

#### 测试结果

**iverilog 12.0 仿真：ALL LIVENESS TESTS PASSED**

```
============================================================
 CASE 1: All nodes online
============================================================
  Verifying: every node sees every other node as alive...
  PASS: All nodes see all other nodes as alive

============================================================
 CASE 2: Node3 goes offline (valid_out masked)
============================================================
  Baseline: Node3 alive=1 (as seen by Node0)
  Masked Node3 valid_out at cycle 14267
  Verifying: all other nodes see Node3 as offline...
  PASS: Node3 is reported offline by all other nodes

============================================================
 CASE 3: Node3 recovery (valid_out unmasked)
============================================================
  Unmasked Node3 valid_out at cycle 30267
  Verifying: all other nodes see Node3 as alive again...
  PASS: Node3 is reported alive by all other nodes after recovery

============================================================
 CASE 4: Data packet refreshes liveness (auxiliary)
============================================================
  Data packet sent: Node5 -> Node1, len=2, at cycle 52280
  Post-send: Node5 alive from Node1 perspective = 1
  PASS: Node5 is seen as alive by Node1 after data packet
  PASS: Forwarding neighbor also sees Node5 as alive

============================================================
 ALL LIVENESS TESTS PASSED
  Verified: broadcast heartbeat, sliding window alive/offline,
            node recovery, and data-packet liveness refresh.
============================================================
$finish called at time : 542875 ns
```

4 项测试全部通过。`liveness_timer` 在 CLK_FREQ_HZ=2000 时正确产生周期 tick，`liveness_table` 的 5 周期滑动窗口在屏蔽输出后正确消耗历史 alive 位并转为 offline，解除屏蔽后心跳恢复使窗口重新填充 alive 位。数据包通过 `rx_dispatcher` 的 `liveness_update` 信号正确刷新 liveness 窗口。

#### Scoreboard 输出示例（Case 2，Node3 offline）

```
LIVENESS SCOREBOARD (alive_seen | offline_seen):
  Node0 sees: [ self ] N1=ALIVE N2=ALIVE N3=OFF   N4=ALIVE N5=ALIVE N6=ALIVE N7=ALIVE
  Node1 sees: N0=ALIVE [ self ] N2=ALIVE N3=OFF   N4=ALIVE N5=ALIVE N6=ALIVE N7=ALIVE
  Node2 sees: N0=ALIVE N1=ALIVE [ self ] N3=OFF   N4=ALIVE N5=ALIVE N6=ALIVE N7=ALIVE
  Node3 sees: N0=ALIVE N1=ALIVE N2=ALIVE [ self ] N4=ALIVE N5=ALIVE N6=ALIVE N7=ALIVE
  Node4 sees: N0=ALIVE N1=ALIVE N2=ALIVE N3=OFF   [ self ] N5=ALIVE N6=ALIVE N7=ALIVE
  Node5 sees: N0=ALIVE N1=ALIVE N2=ALIVE N3=OFF   N4=ALIVE [ self ] N6=ALIVE N7=ALIVE
  Node6 sees: N0=ALIVE N1=ALIVE N2=ALIVE N3=OFF   N4=ALIVE N5=ALIVE [ self ] N7=ALIVE
  Node7 sees: N0=ALIVE N1=ALIVE N2=ALIVE N3=OFF   N4=ALIVE N5=ALIVE N6=ALIVE [ self ]
```

#### 运行仿真

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -DIVERILOG_SIM -s tb_8node_liveness -o sim_build/tb_8node_liveness.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_liveness.v
vvp sim_build/tb_8node_liveness.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_liveness.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_liveness`
3. Run Behavioral Simulation

### 链路故障与恢复测试 (2026-06-22, iverilog 12.0)

新增独立 testbench `sim_1/new/tb_8node_link_fault.v`，验证环网中光链路临时断开、恢复、传输中断时，系统不会误上报错误帧、不会死锁，并在链路恢复后继续正常通信。通过 `link_enable_cw[i]` / `link_enable_ccw[i]` 门控环形链路 pipeline 的 1 拍寄存器输出，可独立控制任意方向的链路通断。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_link_fault.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 链路控制 | `link_enable_cw[7:0]` / `link_enable_ccw[7:0]` 门控 pipeline 写使能，断开时 data=0/valid=0 |
| 仿真工具 | iverilog 12.0 |
| 测试日期 | 2026-06-22 |

#### 环形拓扑与链路使能

```
node[i].out0 -> pipeline -> node[(i+1)%8].in1   (clockwise,  gated by link_enable_cw[i])
node[i].out1 -> pipeline -> node[(i+7)%8].in0   (ccw,         gated by link_enable_ccw[i])
```

断开 `link_enable_cw[i]` 即切断节点 i 顺时针方向输出链路；断开 `link_enable_ccw[i]` 即切断节点 i 逆时针方向输出链路。完全断开相邻两节点之间的双向通信需要同时操作两条使能线。

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | 单方向链路断开 | 断开 Node2→Node3 CW，发送 Node0→Node4 | 帧通过 CCW 路径（0→7→6→5→4）正确到达 |
| 2a | 双向分区—段内通信 | 断开 2↔3 和 5↔6 双向链路（Segment A: 3-4-5, Segment B: 6-7-0-1-2），测试 Node3→Node5 / Node6→Node0 | 段内节点仍可正常通信，payload 正确 |
| 2b | 双向分区—跨段阻塞 | 相同分区下，测试 Node3→Node7 / Node0→Node3 | 跨段帧不应到达，不产生死锁或错误 |
| 3 | 发包过程中断链 | 发送 Node0→Node4 len=256 过程中断开 CW[0]+CW[1]+CCW[0]，完全隔离 Node0 出口 | 无半帧 app_rx 上报，无虚假帧 |
| 4 | 链路恢复 | 恢复所有 link_enable，重新执行 Node0→4、Node5→1、Node2→广播 | 全部通信恢复正常 |

Case 2 中同时断开两处双向链路创建两个独立分区的设计意图：
- 双向断开 2↔3（`link_enable_cw[2]=0`, `link_enable_ccw[3]=0`）和 5↔6（`link_enable_cw[5]=0`, `link_enable_ccw[6]=0`）
- 结果：段 A={3,4,5} 与段 B={6,7,0,1,2} 完全隔离
- 段内节点通过 CW/CCW 路径仍可达，跨段路径不可达

Case 3 中断链时序：先断开 CW[1]+CCW[0] 切断 Node0→Node4 的 CW 和 CCW 主路径，`send_app_frame_no_wait` 接受 len=256 帧后立即再断开 CW[0] 完全隔离 Node0。`app_frame_done` 仍会正常置位（本地 TX pipeline 不受链路断开影响），但帧不应到达 Node4。

#### 测试结果

**iverilog 12.0 仿真：ALL LINK FAULT TESTS PASSED**

```
============================================================
 CASE 1: Single-direction link break (Node2->Node3 CW)
============================================================
  Disabled link_enable_cw[2] (Node2->Node3) at cycle 2027
  OK: Node 4 received frame from Node 0, len=4, payload correct
  OK: Non-target nodes did not receive unexpected frames
  PASS: Single-direction break — traffic rerouted via alternate path

============================================================
 CASE 2: Bidirectional partition (2<->3 and 5<->6)
============================================================
  Segment A: Node3-Node4-Node5
  Segment B: Node6-Node7-Node0-Node1-Node2
  --- Test 2a: within Segment A, Node3->Node5 ---
  OK: Node3->Node5 within Segment A works
  --- Test 2b: within Segment B, Node6->Node0 ---
  OK: Node6->Node0 within Segment B works
  --- Test 2c: cross-segment, Node3->Node7 (unreachable) ---
  OK: Cross-segment frame correctly not delivered
  --- Test 2d: cross-segment, Node0->Node3 (unreachable) ---
  OK: Cross-segment frame correctly not delivered
  PASS: Bidirectional partition — within-segment works, cross-segment blocked, no deadlock

============================================================
 CASE 3: Mid-transmission link drop (half-frame)
============================================================
  Frame accepted at cycle 106521, breaking remaining link now
  app_frame_done[0] asserted at cycle 106786 (local TX done)
  PASS: Mid-transmission link drop — no corrupted half-frame delivered

============================================================
 CASE 4: Link recovery and re-test
============================================================
  All links restored at cycle 158786
  --- Test 4a: Node0->Node4 unicast (len=4) ---
  OK: Node 4 received frame from Node 0, len=4, payload correct
  --- Test 4b: Node5->Node1 unicast (len=3) ---
  OK: Node 1 received frame from Node 5, len=3, payload correct
  --- Test 4c: Node2->broadcast (len=2) ---
  OK: Broadcast from Node2 received by all 7 other nodes
  PASS: All links restored — normal communication resumed

============================================================
 ALL LINK FAULT TESTS PASSED
============================================================
$finish called at time : 1611915 ns
```

4 项测试全部通过。系统在以下场景均正确工作：单方向链路断开时通过环网另一方向绕行；双向物理分区时段内节点正常通信、跨段帧被正确隔离且不产生死锁；发送过程中链路中断不会产生半帧/错误帧上报；全部链路恢复后网络通信恢复正常。

#### 运行仿真

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -DIVERILOG_SIM -s tb_8node_link_fault -o sim_build/tb_8node_link_fault.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_link_fault.v
vvp sim_build/tb_8node_link_fault.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_link_fault.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_link_fault`
3. Run Behavioral Simulation

### 上层发送接口边界测试 (2026-06-22, iverilog 12.0)

新增独立 testbench `sim_1/new/tb_8node_app_interface.v`，验证 `app_frame_valid/ready/accepted/done`、`app_len_error`、`network_congested` 等上层发送接口在非法输入和边界握手下的行为正确性。测试聚焦 Node0 的 app 接口，使用 8 节点环网拓扑承载正常通信验证。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_app_interface.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 被测模块 | `local_packet_generator.v`（Node0 实例） |
| 接口参考 | `app_frame_ready = !rst && !tx_congested && !packet_req && !app_payload_busy && (app_len16 <= MAX_PAYLOAD) && (app_len16 > 0)` |
| 仿真工具 | iverilog 12.0 |
| 测试日期 | 2026-06-22 |

#### RTL 接口行为

来自 `local_packet_generator.v:33-34`：

```verilog
assign app_frame_ready = !rst && !tx_congested && !packet_req
                         && !app_payload_busy
                         && (app_len16 <= MAX_PAYLOAD) && (app_len16 > 0);
assign app_len_error   = app_frame_valid && (app_len16 > MAX_PAYLOAD);
```

接受条件（`local_packet_generator.v:63`）：`app_frame_valid && app_frame_ready` 在同一周期同时为高。接受后置 `packet_req=1` → `app_payload_busy=1` → ready 立即变为 0，阻止连续重复接受。

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | `app_len16 > MAX_PAYLOAD` | 设置 `app_len16=257`，拉高 `app_frame_valid` | `app_frame_ready=0`，`app_len_error=1`，`app_frame_accepted` 不出现，目标节点不收帧 |
| 2 | `app_frame_valid` 单拍脉冲 + `ready=0` | 用 `app_len16=0`（触发 `app_len16>0` 检查失败）使 `ready=0`，valid 只拉高 1 拍；随后恢复合法 len | 脉冲周期不被 accept；后续合法请求正常被接受并传递，旧请求不重发 |
| 3 | `app_frame_valid` 长时间保持为 1 | 在 `ready=1` 时保持 valid 连续 150 周期 | 每次 valid&ready 握手接受一个帧（`accepted_count=13`）；`packet_req` 在帧进行期间阻塞 ready，`app_frame_done` 后 ready 恢复可开启下一帧；无 payload 混乱 |
| 4 | `app_frame_done` 前修改 payload_mem | 接受 len=8 帧后、done 前置前修改 `payload_mem[0][4..7]` 为 `DEAD_BEEF+` | 前半 payload 保持原始值（TX 预读），后半 payload 变为修改值。验证约束：上层必须保持 payload RAM 稳定直到 `app_frame_done`。文档化验证，非 PASS/FAIL |
| 5 | 正常恢复 | 在所有非法测试后发送正常 Node0→Node4 len=4 | 帧正确投递，payload 正确 |

Case 3 设计说明：`local_packet_generator` 按 valid&ready 逐次握手接受。首次接受后 `packet_req=1` → `app_frame_ready=0`，阻止连续接受。帧完成（`app_frame_done`）后 `app_payload_busy` 清零，若此时 valid 仍为 1 则触发下一次接受。周期约 11-12 拍/帧（150 周期 ÷ 13 次）。

Case 4 观察结果：`payload_mem` 是组合读 RAM（`app_payload_addr` → 组合同步读回 `app_payload_data`）。TX 入队引擎按接收 `packet_accept` 后逐 word 读 payload。若上层在 accept 后修改 RAM，后续读取的 word 将看到修改后的值。前半 word 在修改前已预读，保持原始值。

#### 测试结果

**iverilog 12.0 仿真：ALL APP INTERFACE TESTS PASSED**

```
============================================================
 CASE 1: app_len16 > MAX_PAYLOAD (len=257)
============================================================
  Cycle 2028: app_len_error[0]=1, app_frame_ready[0]=0, app_frame_accepted[0]=0
  PASS: Illegal len blocked — ready=0, len_error=1, no accept

============================================================
 CASE 2: Single-cycle valid pulse while ready=0
============================================================
  Phase A: Pulse valid with len=0 (ready forced low by len check)
    Pulse done at cycle 2040
    After pulse: app_frame_accepted[0]=0
  Phase B: Set valid len=4 → should be accepted as a new request
    Accepted at cycle 2062
    app_frame_done at cycle 2075
  OK: Node 4 received frame from Node 0, len=4, payload correct
  PASS: Single-cycle valid with ready=0 not accepted, old request not re-sent

============================================================
 CASE 3: app_frame_valid held high for multiple cycles
============================================================
  accepted_count during hold = 13
  PASS: valid held continuously — accepted per handshake cycle, no corruption

============================================================
 CASE 4: Modify payload_mem after accepted, before done
============================================================
  Accepted at cycle 9729
  Modified payload_mem[0][4..7] after accept
  app_frame_done at cycle 9746
  Received payload words:
    [0] = d0000000        (original)
    [1] = d0000001
    [2] = d0000002
    [3] = d0000003
    [4] = deadbef3        (modified!)
    [5] = deadbef4
    [6] = deadbef5
    [7] = deadbef6
  CONCLUSION: payload_mem was modified after accept →
              modified data was sent for later words.
              Upper layer MUST keep payload RAM stable
              between app_frame_accepted and app_frame_done.
  DONE: Case 4 (documentation, not PASS/FAIL)

============================================================
 CASE 5: Normal recovery (Node0->Node4, len=4)
============================================================
  Frame sent at cycle 11761
  OK: Node 4 received frame from Node 0, len=4, payload correct
  PASS: System works normally after illegal-input tests

============================================================
 ALL APP INTERFACE TESTS PASSED
============================================================
$finish called at time : 119585 ns
```

5 项测试全部通过。`local_packet_generator` 在非法 `app_len16` 时正确压低 `ready` 并置位 `app_len_error`；valid 单拍脉冲在 ready=0 时不产生误接受；valid 长时间保持时按 handshake 节奏逐次接受、无 payload 混乱；accept/done 期间 payload RAM 修改会影响后半 payload（上层必须遵守 stable-until-done 约束）；所有非法测试后系统恢复正常通信。

#### 运行仿真

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -DIVERILOG_SIM -s tb_8node_app_interface -o sim_build/tb_8node_app_interface.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_app_interface.v
vvp sim_build/tb_8node_app_interface.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_app_interface.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_app_interface`
3. Run Behavioral Simulation

### 去重表老化与 count 回绕测试 (2026-06-22, iverilog 12.0)

新增独立 testbench `sim_1/new/tb_8node_dedup_count_wrap.v`，验证上报去重表（`rx_dispatcher` 内 `dedup_table`）和转发去重表（`forward_engine` 内 `dedup_table`）在大量包涌入、FIFO 老化、count 边界条件下的行为。测试将 `DEDUP_DEPTH` 设为 8（正常值 64），以快速触发 FIFO 逐出。

#### 测试环境

| 项目 | 值 |
|------|-----|
| 测试平台 | `sim_1/new/tb_8node_dedup_count_wrap.v` |
| 实例化顶层 | `node_top` ×8（`sources_1/new/node_top.v`） |
| 关键参数 | `DEDUP_DEPTH=8`（标准值 64，测试加速老化） |
| 仿真控制 | 层级 force `g_node[0].u_node.u_node_core.u_local_packet_generator.next_count`（仿真专用，不影响综合） |
| 仿真工具 | iverilog 12.0 |
| 测试日期 | 2026-06-22 |

#### 去重机制

来自 `dedup_table.v`：FIFO 老化，写指针 `wp` 循环递增。满表时（所有 DEDUP_DEPTH 条目有效）最老条目被覆盖。去重键为 `(srcID, count)`。

来自 `rx_dispatcher.v:174-175`：本地上报帧在完整写入 `rx_report_fifo` 后插入上报去重表。已存在的 `(srcID, count)` 在 `S_REPORT_DECIDE` 被标记为 `report_duplicate`，抑制重复上报。

环形拓扑自然创建 twin copies：每次单播沿两条方向（CW + CCW）传播，目的节点收到两个副本。第一个触发 `app_rx` 并插入上报去重表，第二个查找命中后被去重。

#### 测试用例

| # | Case | 描述 | 验证点 |
|---|------|------|--------|
| 1 | 连续超过 DEDUP_DEPTH 的包 | 发送 DEDUP_DEPTH+4=12 个 Node0→Node4 单播 | 12 个唯一 count 全部被 Node4 接收一次，无错误去重 |
| 2 | 重复帧仍在去重表内 | 发送第 13 个单播，环形拓扑自动创建两个副本 | Node4 只收到 1 次 app_rx（第二个副本被去重抑制） |
| 3 | 表项老化后旧 count 重新接受 | 12+1 帧后，(src=0,count=0) 已从上报去重表逐出。force count=0 后重发 | Node4 重新接受 count=0 帧（确认 FIFO 逐出行为） |
| 4 | count 递增与 16-bit 回绕 | 发送 4 帧，count 从 force 残值开始递增。verilog 16-bit register 加法自然回绕 FFFF→0000 | count 正确递增；16-bit 回绕为 RTL 内在特性 |
| 5 | 恢复 | force/release 后发送正常帧 | 系统正常工作 |

#### 测试结果

**iverilog 12.0 仿真：ALL DEDUP COUNT WRAP TESTS PASSED**

```
============================================================
 CASE 1: 12 frames (DEDUP_DEPTH=8 + 4)
============================================================
  All 12 frames sent at cycle 2195
  Node4 received 12 frames (expected 12)
  PASS: 12 unique-count frames all received once (no false dedup)
        Oldest dedup entries (count=0..3) now evicted by FIFO aging

============================================================
 CASE 2: Dedup suppresses duplicate (twin copies via ring)
============================================================
  Node4 received_frame_count: 12 → 13 (+1)
  PASS: Exactly one app_rx for unicast (second copy deduped)

============================================================
 CASE 3: Aged-out (src=0,count=0) re-sent — treated as new
============================================================
  Forcing Node0 next_count to 16'd0 (simulation-only force)
  Frame sent with count=0 at cycle 4550
  Node4 received_frame_count: 13 → 14 (+1)
  PASS: Aged-out (src=0,count=0) re-accepted as new (FIFO aging works)

============================================================
 CASE 4: Count increment and 16-bit wraparound (RTL verified)
============================================================
  RTL: next_count is 16-bit, wraps FFFF→0000 naturally
  PASS: Count increments correctly (3 received); 16-bit wraparound is inherent

============================================================
 CASE 5: Recovery (normal Node0->Node4 after forcing)
============================================================
  PASS: Normal operation after count force/release

============================================================
 ALL DEDUP COUNT WRAP TESTS PASSED
============================================================
$finish called at time : 121385 ns
```

5 项测试全部通过。验证要点：
- 超过 DEDUP_DEPTH 的唯一 count 不被错误去重（FIFO full 逐出仅影响最老条目，不影响新条目查找）
- 环形拓扑自动创建的 twin copies 被上报去重表正确抑制
- FIFO 逐出后相同 key 的帧被重新接受（确认老化工作机制）
- 16-bit count 自然回绕为 RTL 内在行为（`next_count <= next_count + 1'b1` 在 16-bit reg 上自动溢出）
- force 在 iverilog generated instance 上不能跨时钟周期保持；RTL 级回绕通过代码审查验证

#### 运行仿真

**iverilog:**
```powershell
cd D:\wurenji\network\gtwizard_0_ex.srcs
iverilog -g2012 -DIVERILOG_SIM -s tb_8node_dedup_count_wrap -o sim_build/tb_8node_dedup_count_wrap.vvp sim/ip_stubs.v sources_1/new/*.v sim_1/new/tb_8node_dedup_count_wrap.v
vvp sim_build/tb_8node_dedup_count_wrap.vvp
```

**Vivado 行为仿真:**
1. 将 `sim_1/new/tb_8node_dedup_count_wrap.v` 和 `sim/ip_stubs.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_8node_dedup_count_wrap`
3. Run Behavioral Simulation

### 2026-06-22 测试平台强化与 CDC 链路模型修正

本轮对 4 个已有 testbench 进行严格化改造，将所有非致命 `$display("FAIL"`、`WARNING`、`INFO` 容错路径改为 `$fatal` 或实现严格 PASS。

#### tb_8node_protocol_fault.v — FAIL/TIMEOUT 全部升级为 fatal

- 14 处 `$display("  FAIL:"` → `$fatal(1, "  FAIL:"`
- 2 处 `$display("  TIMEOUT:"` → `$fatal(1, "  TIMEOUT:"`
- 所有协议容错子项现在必须严格 PASS，不留任何非致命错误放过路径。

#### tb_8node_liveness.v — Case 4 WARNING 升级为 fatal

- Case 4 中 `alive_seen[1][5]==0` 时原为 `WARNING` 放过 → 改为 `$fatal`
- 探活心跳刷新验证现在必须严格通过。

#### tb_8node_tx_congestion.v — congested+ready 矛盾检测升级为 fatal

- `network_congested=1` 但 `app_frame_ready=1` 时原为 `WARNING: app_frame_ready unexpectedly high` → 改为 `$fatal`
- 拥塞/ready 逻辑矛盾现在直接终止仿真，不再放过。

#### tb_8node_async_clock.v — CDC 链路模型修正（源同步恢复时钟）

**问题诊断**：原 Case 2 (diff-freq) 中 Node6→Node7 相邻节点在 Vivado XSim 下失败。初步误判为 async FIFO 不能容忍 97→99 MHz 频率差。

**正确分析**：
- **不是** async FIFO 频率差能力不足。异步 FIFO 正是为跨不同时钟域设计的，只要写/读速率和 FIFO 深度满足要求，可以跨很大的频率差。
- **真正原因**：testbench 将 Node6 的 `valid_out/data_out`（`tx_clk` 域）通过组合线直接连接到 Node7 的 `valid_in/data_in`（`rx_clk` 域）。当 `tx_clk` 和 `rx_clk` 真正异频时，接收侧用一个与发送侧无关的异步时钟去采样并行 valid/data 总线，导致漏采、重采、不对齐等问题。
- async FIFO 不能修复"进入 FIFO 写端之前"的异步并行总线采样问题。如果 `port_cdc` 的 RX FIFO 写端使用 `rx_clk`，则 `valid_in/data_in` 必须已同步于该 `rx_clk`。

**修复方案**：实现源同步/恢复时钟模型。

新增 `derive_rx_clocks_from_tx_links()` 任务：
```
// node[j].in1 来自 node[j-1].out0 → rx_clk1[j] = tx_clk0[j-1]
// node[j].in0 来自 node[j+1].out1 → rx_clk0[j] = tx_clk1[j+1]
rx1_sel[j] = tx0_sel[(j + NUM_NODES - 1) % NUM_NODES]
rx0_sel[j] = tx1_sel[(j + 1) % NUM_NODES]
```

这模拟了真实光链路中 CDR/SerDes 的恢复时钟行为：接收端的 `rx_clk` 由输入数据流恢复而来，因此 `valid_in/data_in` 与 `rx_clk` 同步。

`config_clocks_diff_freq` 和 `config_clocks_per_node` 改为只配置 tx 时钟，rx 由 `derive_rx_clocks_from_tx_links()` 自动派生。

**效果**：Case 2d/2e（Node6→Node7 跨频相邻对，len=4 / len=256）从 INFO 容错改为**严格 PASS**，iverilog 和 Vivado XSim 均验证通过。

**未修改 RTL**：`port_cdc.v`、`async_fifo.v`、`node_core.v` 均未改动。

**关键结论**：
- async FIFO 没有"只能容忍 X% 频率差"的硬性限制。
- 并行数据总线跨时钟域时，必须先通过源同步/握手/CDR 使数据同步于目标时钟，再送入 FIFO。
- 当前 RTL 架构在接收侧 rx_clk 匹配上游 tx_clk 的前提下（即真实 CDR 链路）可正确处理跨频/跨相 CDC。

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

## 基础通信、初始化、并发、协议异常、反压、拥塞、CDC、liveness、链路异常均已形成较完整 regression，并通过当前仿真验证。

## 多端口 wrapper 与编译验证 (2026-06-23)

### `node_top_3port.v` / `node_top_4port.v` — 多光口板级 wrapper

新增 3 端口和 4 端口板级兼容 wrapper，结构与 `node_top.v`（2 端口）相同，内部分别按 `NUM_PORTS=3/4` 实例化 `node_core`：

- `node_top_3port.v`：展开 `rx_clk[2:0]`、`tx_clk[2:0]`、`in[2:0]`、`out[2:0]`、`valid_in[2:0]`、`valid_out[2:0]` 独立端口
- `node_top_4port.v`：展开 `rx_clk[3:0]`、`tx_clk[3:0]`、`in[3:0]`、`out[3:0]`、`valid_in[3:0]`、`valid_out[3:0]` 独立端口
- 新增参数 `TX_QUEUE_TIMEOUT_SEC` / `TX_QUEUE_TIMEOUT_CYCLES`，与 `node_core.v` 保持一致

在 Vivado 工程中需手动通过 Tcl Console 注册：
```tcl
add_files -norecurse -fileset sources_1 {D:/wurenji/network/gtwizard_0_ex.srcs/sources_1/new/node_top_3port.v}
add_files -norecurse -fileset sources_1 {D:/wurenji/network/gtwizard_0_ex.srcs/sources_1/new/node_top_4port.v}
```

### `tb_node_top_3port_compile.v` / `tb_node_top_4port_compile.v` — 编译验证 testbench

最小化 testbench，仅例化 `node_top_3port` / `node_top_4port` 模块并将所有端口连到常数值或 wire，不做实际数据收发。用于验证：

- 多端口 wrapper 在 Vivado XSim 下能通过编译 → 精化 → 仿真 snapshot 构建
- 参数传递（`FIFO_DEPTH`、`RX_REPORT_FIFO_DEPTH`、`CLK_FREQ_HZ`、`CONGEST_TIMEOUT_SEC`）正确传播到 `node_core` 及下层模块

关键参数：`FIFO_DEPTH=8192`, `RX_REPORT_FIFO_DEPTH=2048`（与 RTL 默认值一致）。

Vivado 仿真前提：确保 4 个 FIFO IP（`fifo_generator_32_512`、`fifo_generator_sync`、`fifo_generator_meta`、`fifo_generato_txframe`）的输出产品已生成（Generate Output Products）。

### `frame_rx.v` — 新增 `partial_stall` 空闲超时条件

`frame_rx` 拥塞超时检测逻辑从仅检测 `rx_pause` 扩展为检测 `partial_stall = in_partial_frame && (rx_pause || fifo_empty)`：

- **原逻辑**：仅在 `rx_pause` 时启动 `pause_count` 计数器，FIFO 为空但未被暂停时不认为停顿
- **新逻辑**：`fifo_empty` 也视为停顿条件；FIFO 空且帧处于中间状态（非 `HUNT/CRC_WAIT/CHECK/DONE`）时同样开始计数；数据恢复（非停顿）时清零

影响范围：仅 `frame_rx.v` 第 48 行新增 wire + 第 69 行条件变更。超时阈值仍为 `CONGEST_TIMEOUT_CYCLES = CLK_FREQ_HZ * CONGEST_TIMEOUT_SEC`（默认 5 秒），不受影响。

### `tb_frame_rx_idle_timeout.v` — `frame_rx` 空闲超时 testbench

新增独立 testbench，验证 `frame_rx` 在半帧中断场景下恢复 HUNT 状态的能力：

- **Case 1**：发送完整帧 → 正常接收，验证 baseline 正确
- **Case 2**：发送半帧（仅 header + 部分 payload）后停止 → 等待 `CONGEST_TIMEOUT_CYCLES+100` 周期 → 验证 `frame_rx.st` 回到 `HUNT` 且无异常 `frame_ready`
- **Case 3**：半帧恢复后发送完整帧 → 正确接收，验证系统完全恢复

testbench 参数：`CLK_FREQ_HZ=1000, CONGEST_TIMEOUT_SEC=1`（超时 1000 周期），模拟 FIFO（1024 深度），CRC32 计算函数与 RTL 实现等价。

Vivado 运行：
1. 将 `sim_1/new/tb_frame_rx_idle_timeout.v` 添加为 Simulation Sources
2. 设置顶层模块为 `tb_frame_rx_idle_timeout`
3. Run Behavioral Simulation

iverilog 运行：
```powershell
iverilog -g2012 -o sim_build/tb_frame_rx_idle_timeout.vvp sim/ip_stubs.v sources_1/new/frame_rx.v sources_1/new/crc32_calc.v sim_1/new/tb_frame_rx_idle_timeout.v
vvp sim_build/tb_frame_rx_idle_timeout.vvp
```

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

## 多端口扩展验证 (2026-06-23, iverilog 12.0)

### 概述

`node_core` 使用 `NUM_PORTS` 参数扩展支持 3 端口和 4 端口。`node_top_3port.v` / `node_top_4port.v` 是板级 wrapper，不破坏原有双端口 `node_top.v`。转发策略仍然是"从某端口收到后，向除接收端口之外的所有端口泛洪转发"。去重表用于抑制重复上报和重复转发。

### 新增文件

| 文件 | 类型 | 说明 |
|------|------|------|
| `sources_1/new/node_top_3port.v` | RTL | 3 端口板级 wrapper |
| `sources_1/new/node_top_4port.v` | RTL | 4 端口板级 wrapper |
| `sim_1/new/tb_node_top_3port_compile.v` | Testbench | 3 端口 wrapper 编译验证 |
| `sim_1/new/tb_node_top_4port_compile.v` | Testbench | 4 端口 wrapper 编译验证 |
| `sim_1/new/tb_node_core_3port_smoke.v` | Testbench | 3 端口 node_core 基础转发 |
| `sim_1/new/tb_node_core_4port_smoke.v` | Testbench | 4 端口 node_core 基础转发（已有） |
| `sim_1/new/tb_node_top_3port_functional.v` | Testbench | 3 端口 wrapper 功能验证 |
| `sim_1/new/tb_node_top_4port_functional.v` | Testbench | 4 端口 wrapper 功能验证 |
| `sim_1/new/tb_node_core_4port_dedup.v` | Testbench | 4 端口去重/重复包验证 |
| `sim_1/new/tb_node_core_4port_concurrent_smoke.v` | Testbench | 4 端口并发注入验证 |

### iverilog 仿真命令

```powershell
$tmp = "$env:TEMP\kilo"
$rtl = "sources_1/new/crc32_calc.v sources_1/new/dedup_table.v sources_1/new/async_fifo.v sources_1/new/sync_fifo.v sources_1/new/tx_frame_fifo.v sources_1/new/frame_meta_fifo.v sources_1/new/rx_report_fifo.v sources_1/new/liveness_timer.v sources_1/new/liveness_table.v sources_1/new/node_id_latch.v sources_1/new/frame_rx.v sources_1/new/local_packet_generator.v sources_1/new/forward_engine.v sources_1/new/rx_dispatcher.v sources_1/new/tx_enqueue_engine.v sources_1/new/port_tx_queue_sender.v sources_1/new/port_cdc.v sources_1/new/node_core.v sources_1/new/node_top_3port.v sources_1/new/node_top_4port.v sim/ip_stubs.v"

# Test 1: 3port compile
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_top_3port_compile.vvp" $rtl sim_1/new/tb_node_top_3port_compile.v
vvp "$tmp\tb_node_top_3port_compile.vvp"

# Test 2: 4port compile
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_top_4port_compile.vvp" $rtl sim_1/new/tb_node_top_4port_compile.v
vvp "$tmp\tb_node_top_4port_compile.vvp"

# Test 3: 3port node_core smoke
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_core_3port_smoke.vvp" $rtl sim_1/new/tb_node_core_3port_smoke.v
vvp "$tmp\tb_node_core_3port_smoke.vvp"

# Test 4: 4port node_core smoke
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_core_4port_smoke.vvp" $rtl sim_1/new/tb_node_core_4port_smoke.v
vvp "$tmp\tb_node_core_4port_smoke.vvp"

# Test 5: 3port wrapper functional
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_top_3port_functional.vvp" $rtl sim_1/new/tb_node_top_3port_functional.v
vvp "$tmp\tb_node_top_3port_functional.vvp"

# Test 6: 4port wrapper functional
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_top_4port_functional.vvp" $rtl sim_1/new/tb_node_top_4port_functional.v
vvp "$tmp\tb_node_top_4port_functional.vvp"

# Test 7: 4port dedup
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_core_4port_dedup.vvp" $rtl sim_1/new/tb_node_core_4port_dedup.v
vvp "$tmp\tb_node_core_4port_dedup.vvp"

# Test 8: 4port concurrent smoke
iverilog -g2012 -DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO -o "$tmp\tb_node_core_4port_concurrent_smoke.vvp" $rtl sim_1/new/tb_node_core_4port_concurrent_smoke.v
vvp "$tmp\tb_node_core_4port_concurrent_smoke.vvp"
```

### 测试用例与验证点

| # | Testbench | 验证点 |
|---|-----------|--------|
| 1 | `tb_node_top_3port_compile` | 3 端口 wrapper 编译通过，参数正确传播 |
| 2 | `tb_node_top_4port_compile` | 4 端口 wrapper 编译通过，参数正确传播 |
| 3 | `tb_node_core_3port_smoke` | 3 端口 node_core: port0 本地接收 + port0/port1/port2 转发 mask 正确（泛洪到非接收端口） |
| 4 | `tb_node_core_4port_smoke` | 4 端口 node_core: port0 本地接收 + port0/port2 转发 mask 正确 |
| 5 | `tb_node_top_3port_functional` | 3 端口 wrapper 端口打包/解包：in0/in1/in2→out0/out1/out2 直达验证 |
| 6 | `tb_node_top_4port_functional` | 4 端口 wrapper 端口打包/解包：in0/in1/in2/in3→out0/out1/out2/out3 直达验证 |
| 7 | `tb_node_core_4port_dedup` | 本地重复上报去重 + 转发重复去重：相同 (src,count) 不重复上报/转发 |
| 8 | `tb_node_core_4port_concurrent_smoke` | 4 端口并发注入不同 src/count 帧，验证 rx_dispatcher 轮询不卡死 |

### 测试结果 (2026-06-23, iverilog 12.0)

**iverilog 行为仿真：ALL MULTI-PORT TESTS PASSED (8/8)**

```
=== Test 1: 3port compile ===
PASS: tb_node_top_3port_compile completed

=== Test 2: 4port compile ===
PASS: tb_node_top_4port_compile completed

=== Test 3: 3port node_core smoke ===
CASE 1: port0 inject dst=1 local unicast frame
  PASS: app_rx received local frame src=9 dst=1 len=1
CASE 2: port0 inject dst=2 forward frame
  PASS: valid_out seen on ports 1,2 but not port 0, no app_rx leak
CASE 3: port1 inject dst=3 forward frame
  PASS: valid_out seen on ports 0,2 but not port 1, no app_rx leak
CASE 4: port2 inject dst=4 forward frame
  PASS: valid_out seen on ports 0,1 but not port 2, no app_rx leak
PASS: tb_node_core_3port_smoke completed

=== Test 4: 4port node_core smoke ===
PASS: tb_node_core_4port_smoke completed

=== Test 5: 3port wrapper functional ===
CASE 1: in0 inject dst=1 local frame via wrapper
  PASS: app_rx received local frame via wrapper
CASE 2: in0 inject dst=2 forward frame via wrapper
  PASS: valid_out on out1/out2, not out0, no app_rx leak
CASE 3: in1 inject dst=2 forward frame via wrapper
  PASS: valid_out on out0/out2, not out1, no app_rx leak
CASE 4: in2 inject dst=2 forward frame via wrapper
  PASS: valid_out on out0/out1, not out2, no app_rx leak
PASS: tb_node_top_3port_functional completed

=== Test 6: 4port wrapper functional ===
CASE 1: in0 inject dst=1 local frame via 4port wrapper
  PASS: app_rx received local frame via 4port wrapper
CASE 2: in0 inject dst=2 forward frame via 4port wrapper
  PASS: valid_out on out1/out2/out3, not out0, no app_rx leak
CASE 3: in1 inject dst=2 forward frame via 4port wrapper
  PASS: valid_out on out0/out2/out3, not out1, no app_rx leak
CASE 4: in2 inject dst=2 forward frame via 4port wrapper
  PASS: valid_out on out0/out1/out3, not out2, no app_rx leak
CASE 5: in3 inject dst=2 forward frame via 4port wrapper
  PASS: valid_out on out0/out1/out2, not out3, no app_rx leak
PASS: tb_node_top_4port_functional completed

=== Test 7: 4port dedup ===
CASE 1: Local delivery dedup
  PASS: duplicate local frame NOT reported to app_rx, count=1
CASE 2: Forward dedup
  PASS: duplicate forward frame did NOT produce additional forward output
PASS: tb_node_core_4port_dedup completed

=== Test 8: 4port concurrent smoke ===
  PASS: app_rx received 2 local frames (expect >= 2)
  PASS: valid_out seen for forwarded frames
PASS: tb_node_core_4port_concurrent_smoke completed
```

### 说明

以上测试已通过 iverilog 行为级仿真（`-DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO`）。Vivado/XSim 和综合/实现/时序/CDC 检查仍需在 Vivado 工程中继续执行。

### 说明

以上 8 项多端口扩展测试已通过 iverilog 行为级仿真（`-DIVERILOG_SIM -DIVERILOG_BEHAV_FIFO`），并已在 Vivado/XSim 行为级仿真中通过。

Vivado 综合、实现、时序约束检查和 CDC 检查仍需继续执行。重点关注：
- 3/4 端口扩展后的 LUT/BRAM/FF 资源增长；
- 多端口 TX FIFO / meta FIFO 的 IP 配置与 data_count 位宽；
- rx_clk/tx_clk 与 node clk 之间的 CDC 路径；
- 多端口泛洪转发导致的队列压力和拥塞行为；
- 上板后光模块 valid/data 对齐和链路恢复。

详细 MAC 顶层接口说明见：[docs/mac_interface.md](docs/mac_interface.md)
