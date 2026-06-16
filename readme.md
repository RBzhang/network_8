# network_8

基于 FPGA 的环形光互联网络节点原型工程，面向多节点板卡之间的数据转发、广播探活、去重和链路健壮性验证。

## 项目概览

- 以 `node_top.v` 为核心连线顶层，`node.v` 为兼容性封装，建模双端口光互联节点。
- 支持单播数据包、广播数据包与广播状态包。
- 使用同步头、长度字段和 CRC32 完成帧同步、边界保护和完整性校验。
- 通过去重表抑制环网重复包，通过滑动窗口维护节点在线状态。
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
  └── node_top.v (纯连线顶层)
        ├── node_id_latch.v          — 首次脉冲 ID 锁存
        ├── port_cdc.v               — 异步 FIFO 跨时钟域 + 端口输出寄存器
        │     └── async_fifo.v ×4    — 每端口 RX/TX 各一个异步 FIFO
        ├── frame_rx.v ×NUM_PORTS    — 每端口独立帧接收状态机
        ├── rx_dispatcher.v          — 帧分类与本地分发
        ├── liveness_timer.v         — 1 秒定时器
        ├── liveness_table.v         — 滑动窗口生存状态表
        ├── local_packet_generator.v — 本地帧描述符生成（数据包/探活包）
        ├── forward_engine.v         — 去重 + 转发决策
        │     └── dedup_table.v      — 去重表
        ├── tx_arbiter.v             — 本地包/转发包仲裁
        └── frame_tx.v ×NUM_PORTS    — 每端口帧发送状态机
              └── crc32_calc.v       — CRC32 计算引擎（共享实例）
```

## 核心模块

### `node_top.v` — 连线顶层

参数化的纯连线顶层，将所有功能模块按数据流连接在一起。不含任何过程逻辑，仅做实例化和总线拼接。支持的参数：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `SYNC_WORD` | `32'hA31E57BD` | 帧同步头 |
| `BROADCAST` | `8'hFF` | 广播地址 |
| `MAX_PAYLOAD` | `256` | 最大 payload（words） |
| `LIVENESS_WIN` | `5` | 存活滑动窗口宽度 |
| `NODE_COUNT` | `255` | 最大节点数 |
| `DEDUP_DEPTH` | `64` | 去重表深度 |
| `FIFO_DEPTH` | `512` | 异步 FIFO 深度 |
| `CLK_FREQ_HZ` | `160_000_000` | 主时钟频率 |
| `NUM_PORTS` | `2` | 光模块端口数 |

### `node.v` — 兼容性封装

与 `node_top.v` 的接口完全一致，内部仅做参数传递和端口直连。保留此模块以兼容旧版工程入口。

### `node_id_latch.v` — 节点 ID 锁存器

仅响应复位释放后的**第一次** `node_id_valid` 脉冲，锁存 `node_id` 幅值为本机 ID。后续脉冲全部忽略。锁存前 `id_locked=0`，所有下游逻辑均处于复位状态，忽略所有数据流动。

- 输入: `node_id_valid`, `node_id`
- 输出: `my_id`, `id_locked`

### `port_cdc.v` — 端口跨时钟域

隔离光模块接口时钟域（`rx_clk0/1`, `tx_clk0/1`）与内部主时钟域：

- 将 `id_locked` 信号通过两级同步器传递到各 RX 时钟域，作为 RX FIFO 写使能的门控
- 每端口实例化一对 `async_fifo`（RX + TX）
- TX 侧持续监测 FIFO 非空，在端口自己的 `tx_clk*` 域输出 `out*` 和 `valid_out*`

### `frame_rx.v` — 帧接收器

每个端口实例化一个，7 状态 FSM 完成帧同步与校验：

| 状态 | 功能 |
|------|------|
| HUNT | 扫描同步字 `0xA31E57BD`，命中后初始化 CRC |
| HEADER1 | 提取 `(srcID, dstID, count)` |
| HEADER2 | 提取 `len16`，若 `> MAX_PAYLOAD` 则丢弃回到 HUNT |
| PAYLOAD | 按 word 读入 payload buffer |
| CRC | 读取接收端 CRC 值，对本地 CRC 计算执行 finalize |
| CHECK | 比较本地 CRC 与接收 CRC，一致则置 `frame_ready=1` |
| DONE | 等待上层 `frame_consumed` 后释放 |

### `rx_dispatcher.v` — 帧分类与分发

从多端口并行轮询已就绪的帧，按优先级分类处理：

- **SELFCHK**: `srcID == my_id` → 丢弃（自己发出的包绕回）
- **LOCAL**: `dstID == my_id`（单播命中）→ 通过 `app_rx_*` 接口反馈给上层，不转发
- **BROADCAST DATA**: `dstID == 0xFF && len16 > 0` → 通过 `app_rx_*` 接口反馈给上层，并继续提交给 `forward_engine` 转发
- **FORWARD**: `dstID == 0xFF && len16 == 0` 的状态包或其他目标帧 → 发送给 `forward_engine` 进行去重和转发
- **LIVENESS**: 任意 CRC 正确且 `srcID != my_id` 的帧都会用 `srcID` 更新生存状态表

6 状态 FSM: `POLL → CLASSIFY → LOCAL_HDR → LOCAL_LOAD → LOCAL_PAY → FWD_REQ → FWD_WAIT`

### `forward_engine.v` — 转发引擎

接收 `rx_dispatcher` 发来的转发候选，执行去重查询和转发决策：

- S_IDLE: 等待候选帧
- S_LOOKUP: 查询 `dedup_table`，检查 `(srcID, count)` 是否已存在
- S_DECIDE: 已存在则丢弃，未命中则插入去重表并提交转发请求
- S_REQ: 等待 `tx_arbiter` 接受

### `tx_arbiter.v` — 发送仲裁器

仲裁本地包（来自 `local_packet_generator`）和转发包（来自 `forward_engine`）：

- 转发包优先级高于本地包
- 当所有目标端口 `tx_busy` 均为 0 时，启动所有目标端口的 `frame_tx`
- 本地包向所有端口广播；转发包向非接收端口发送
- 3 状态 FSM: `IDLE → BUSY → WAIT_DROP`

### `frame_tx.v` — 帧发送器

每个端口实例化一个，负责将帧描述符（src/dst/count/len16）序列化为协议帧写入 TX FIFO：

- 写入同步头 → Header1 `{src, dst, count}` → Header2 `{len16, 0}` → Payload → CRC32
- 每写入一个 word 同时送入 CRC32 计算引擎
- 内部实例化 `crc32_calc` 用于在线 CRC 计算
- 7 状态 FSM: `IDLE → SYNC → HEADER1 → HEADER2 → PAYLOAD → CRC → CRC_WAIT → DONE`

### `local_packet_generator.v` — 本地包生成器

生成两种本地帧描述符：

1. **数据帧**: 当上层 `app_frame_valid && app_frame_ready` 时，锁存 `app_dst_id` / `app_len16` / `app_payload_data`，生成帧描述符
2. **探活帧**: 无上层数据帧请求时，每秒自动生成一个 `dstID=0xFF, len16=0` 的广播状态包

- 数据帧优先级高于探活帧
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

FIFO 老化机制，深度 64。以 `(srcID, count)` 为去重键：

- lookup: 遍历所有有效条目匹配
- insert: 写指针处写入新条目；表满时覆盖最老条目

### `crc32_calc.v` — CRC32 计算模块

以太网标准 CRC-32（多项式 `0x04C11DB7`），generate 块展开为 32 级纯组合逻辑 LFSR，单周期处理一个 32-bit word。

### `async_fifo.v` — 异步 FIFO

跨时钟域 FIFO 包装器：

- `USE_IP=1`（默认）: 实例化 Vivado `fifo_generator_32_512` IP 核
- `USE_IP=0`（仿真）: 纯 RTL 行为模型（双口 RAM + 格雷码指针 + 两级同步器）

### `sync_fifo.v` — 同步 FIFO

同频域 FIFO 参考实现，基于双指针 + 计数器管理空满状态，支持同时读写。

## 数据流概览

```
光模块 RX → async_fifo (rx_clk* → clk) → frame_rx → rx_dispatcher
                                                         ├── 本地单播/广播数据包 → app_rx_* 上层接口
                                                         ├── 存活性更新 → liveness_table
                                                         └── 需转发 → forward_engine (去重)
                                                                        └── tx_arbiter (仲裁)
                                                                              ├── frame_tx ×NUM_PORTS
                                                                              │     └── async_fifo (clk → tx_clk*) → 光模块 TX
                                                                              └── local_packet_generator ← app_frame_* 上层接口
                                                                                    └── liveness_timer (1s tick)
```

## 协议摘要

- 拓扑：双端口环形互联，节点自发包向两个方向扩散
- 地址：`0x00` 到 `0xFE` 为单播地址，`0xFF` 为广播地址；`dstID=0xFF,len16=0` 是状态包，`dstID=0xFF,len16>0` 是广播数据包
- 帧格式：同步头 + 头部字段 `{srcID, dstID, count}` + `{len16, reserved}` + 可变长 payload + CRC32
- 健壮性：`len16` 限制最大 payload 256 words，异常帧直接丢弃
- 去重键：`(srcID, count)`
- 在线判定：最近 5 个周期内任意一次收到即判定在线

## 当前状态

- 工程已完成模块化 RTL 拆分，各模块职责清晰、接口标准化
- `node.v` 为兼容性封装，实际逻辑入口为 `node_top.v`
- 生产环境中 `async_fifo.v` 优先实例化 Vivado FIFO IP（`fifo_generator_32_512.xci`）

## 使用建议

1. 在 Vivado 中导入 `sources_1`、`constrs_1` 和 `sim_1` 对应文件
2. 以 `sources_1/new/node_top.v` 为核心入口检查模块连接关系
3. 先完成单节点环回或双节点最小系统仿真，再扩展到多节点组网验证

## 详细设计

完整设计说明见 [docs/architecture.md](docs/architecture.md)。

## 修改要求

1. 节点编号改为外部输入脉冲赋值，所有的逻辑都在脉冲赋值后运行，在此之前忽略任何数据流动，且只关注第一个脉冲，后续的脉冲全部忽略
2. 是否发送数据帧由上层模块给信号控制，数据帧内容（包括目的节点，数据长度，数据内容）也由上层模块给出，没有数据帧时就发送生存状态帧
3. 接收机收到数据帧也可以据此获知 srcID 对应的节点存活
4. 生存状态帧数据不随复位清零，不受复位控制
