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

| 模块 | 作用 |
|------|------|
| `node.v` | 顶层节点模块，负责接收、调度、转发和状态上报 |
| `frame_rx.v` | 单端口收帧状态机，执行同步头检测、长度解析和 CRC 校验 |
| `dedup_table.v` | 基于 FIFO 老化的去重表，抑制环网重复包 |
| `liveness_table.v` | 基于滑动窗口的节点在线状态表 |
| `crc32_calc.v` | 帧校验使用的 CRC32 计算模块 |
| `sync_fifo.v` | 当前工程内使用的同步 FIFO 占位实现 |
| `async_fifo.v` | 端口时钟域与内部时钟域之间使用的异步 FIFO 包装器，实际调用 Vivado FIFO IP |

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
