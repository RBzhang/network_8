# network_8

基于 FPGA 的环形光互联网络节点原型工程，面向多节点板卡之间的数据转发、广播探活、去重和链路健壮性验证。

## 项目概览

- 以 `node.v` 为顶层节点模块，建模双端口光互联节点。
- 支持单播数据包与广播状态包两类帧。
- 使用同步头、长度字段和 CRC32 完成帧同步、边界保护和完整性校验。
- 通过去重表抑制环网重复包，通过滑动窗口维护节点在线状态。
- 当前工程包含核心 Verilog 模块、示例设计导入文件和约束文件，适合作为原型验证与后续扩展的基础。

## 目录结构

```text
constrs_1/imports/example_design/   Vivado 约束文件
sim_1/imports/simulation/functional/ 初始化数据文件
sources_1/imports/example_design/   示例设计导入文件
sources_1/new/                      自定义核心模块
```

## 核心模块

### `node.v` — 顶层节点模块

双端口光互联节点的调度核心，参数化端口数（`NUM_PORTS`，默认 2）。实例化所有子模块，通过 19 状态 FSM 实现：

- **POLL**：轮询各端口 RX FIFO，公平调度收到的帧
- **HDR / SELFCHK / DSTCHK**：解析帧头，判断源/目的地址，区分单播与广播
- **LOCAL / DEDUP**：本地消费或查询去重表
- **FWDSYNC / FWDDATA / FWDCRC**：向非接收端口转发帧头、payload 和 CRC
- **SELFSET / SELFDATA / SELFCRC**：每秒生成自报存活广播包
- **DISCARD / SELFDONE**：写出 CRC 字后释放帧接收器

### `frame_rx.v` — 单端口收帧状态机

每个端口实例化一个接收器，7 状态 FSM 完成帧同步与校验：

| 状态 | 功能 |
|------|------|
| HUNT | 扫描同步字 `0xA31E57BD`，命中后初始化 CRC |
| HEADER1 | 提取 `(srcID, dstID, count)` |
| HEADER2 | 提取 `len16`，检测超长帧直接丢弃 |
| PAYLOAD | 按 word 读入 payload buffer，上限 256 个 32-bit word |
| CRC | 读取接收端 CRC 值，对本地 CRC 计算执行 finalize |
| CHECK | 比较本地 CRC 与接收 CRC，一致则置 `frame_ready=1` |
| DONE | 等待调度器置 `frame_consumed` 后释放 |

### `crc32_calc.v` — CRC32 计算模块

以太网标准 CRC-32（多项式 `0x04C11DB7`），单周期处理一个 32-bit word。内部采用 generate 块展开为 32 级纯组合逻辑 LFSR：

- `init=1`：复位 CRC 寄存器为 `0xFFFFFFFF`
- `en=1`：送入 data 执行一次 32-bit 并行 CRC 迭代
- `finalize=1`：对结果执行最终 XOR `0xFFFFFFFF`，下一拍输出

### `dedup_table.v` — 去重表

FIFO 老化机制的去重存储，深度 64。以 `(srcID, count)` 为去重键：

- **lookup**：遍历所有有效条目，匹配 `(srcID, count)`，命中则 `found=1`
- **insert**：在写指针处写入新条目；表满时覆盖最老条目实现硬件老化

保证环形拓扑中已转发的帧不会被二次转发。

### `liveness_table.v` — 生存状态表

滑动窗口（默认 5 周期）记录每个节点是否在线。每个节点维护 `WINDOW` 位 shift register：

- `tick_1s`：全部窗口左移一位，启动逐节点上传状态机
- `update=1`：将 `window[src][0]` 置 1（收到该节点数据包）
- 上传阶段每拍输出一个节点，`alive = |window[node]`（窗口内任一位置位即在线）

### `sync_fifo.v` — 同步 FIFO

同频域 FIFO 占位实现，用于仿真验证。基于双指针 + 计数器的方式管理空满状态，支持同时读写。生产环境中由 `async_fifo.v` 的 Vivado IP 分支替代。

### `async_fifo.v` — 异步 FIFO 包装器

跨时钟域 FIFO，隔离端口 `rx_clk`/`tx_clk` 与内部 `clk` 域：

- **USE_IP=1**（默认）：实例化 Vivado `fifo_generator_32_512` IP 核
- **USE_IP=0**（仿真）：纯 RTL 行为模型——双口 RAM + 格雷码指针 + 两级同步器跨时钟域，完整实现空满检测

## 协议摘要

- 拓扑：双端口环形互联，节点自发包向两个方向扩散。
- 地址：`0x00` 到 `0xFE` 为单播地址，`0xFF` 为广播地址。
- 帧格式：同步头 + 头部字段 + 可变长 payload + CRC32。
- 健壮性：`len16` 限制最大 payload 为 256 个 32-bit word，异常帧直接丢弃。
- 去重键：`(srcID, count)`。
- 在线判定：最近 5 个周期全部未收到目标节点包时判定离线。

## 当前状态

- 工程已完成基础 RTL 拆分，适合继续做仿真、时序约束收敛和真实异步 FIFO 替换。
- `sync_fifo.v` 仍保留为同步 FIFO 占位实现；`node.v` 当前接入的是 `async_fifo.v`，而 `async_fifo.v` 会优先实例化 `sources_1/ip/fifo_generator_32_512/fifo_generator_32_512.xci` 对应的 Vivado FIFO IP，把端口 `rx_clk/tx_clk` 域和内部 `clk` 域隔离开。
- 文档中的协议与实现保持一致性校对仍值得继续加强，尤其是多端口扩展和背压细节。

## 使用建议

1. 在 Vivado 中导入 `sources_1`、`constrs_1` 和 `sim_1` 下对应文件。
2. 以 `sources_1/new/node.v` 为核心入口检查模块连接关系。
3. 先完成单节点环回或双节点最小系统仿真，再扩展到多节点组网验证。

## 详细设计

完整设计说明见 [docs/architecture.md](docs/architecture.md)。



## 修改要求
1. 节点编号改为脉冲幅值，所有的逻辑都在脉冲赋值后运行，在此之前忽略任何数据流动，且只关注第一个脉冲，后续的脉冲全部忽略
2. 是否发送数据帧由上层模块给信号控制，数据帧内容（包括目的节点，数据长度，数据内容）也由上层模块给出，没有数据帧时就发送生存状态帧
3. 接收机收到数据帧也可以据此获知srcID对应的节点存活
4. 生存状态帧数据不随复位清零，不受复位控制
