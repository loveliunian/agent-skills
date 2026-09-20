# 性能审计报告 - demo-pay

> 生成时间：2026-09-17 10:00:00（UTC）　数据来源：performance.json 自动汇总（人工勿改）


<!-- 审计指纹: performance.json sha256=14bbdb0abe5b19c4dc321fde613d61fba08f49ee68832f4e220d442393c99890（由 df_render 自动生成，人工勿改） -->

## 场景实测

| 场景 | P95 实测 | 冻结阈值 | 终态 |
|---|---|---|---|
| 分页查询（100 并发 × 5 分钟） | 210 ms | 500 ms | PASS |
| 创建支付单（50 并发 × 5 分钟） | 380 ms | 500 ms | PASS |

## Gate 机器字段（由 df_render 从 JSON 派生，人工勿改）

```text
SCENARIOS_TOTAL=2
SCENARIOS_PASS=2
NPLUS1_SUSPICIOUS=0
```

### 结构化 P95 行（p3 gate 与 JSON 逐场景对账）

```text
P95 210 ms ｜ 分页查询（100 并发 × 5 分钟）
P95 380 ms ｜ 创建支付单（50 并发 × 5 分钟）
```

N+1 可疑模式数：0

结论：核心场景 P95 均低于冻结阈值；Mapper 关联查询已走批量接口，无 N+1。
