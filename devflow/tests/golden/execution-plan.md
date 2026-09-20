# demo-pay 执行契约

> 生成时间：2026-09-17 10:00:00（UTC）　数据来源：execution-plan.json 结构化产物自动渲染


<!-- 审计指纹: execution-plan.json sha256=6d7510e53a8e33d063465d0e39398fd5c788483f69e97afa15e253d573133213（由 df_render 自动生成，人工勿改） -->

## 任务矩阵（Task = 切片；每行 = 一个 exact target）

| Task | Acceptance | DesignRef | Target | Action | Invariants | Verify | Risk | 依赖 |
|------|-----------|-----------|--------|--------|------------|--------|------|------|
| T-01 | M-01-F01-A01 | anchor: api-contracts §3.2.1、anchor: business-rules R1 | `PayController#create` | MODIFY | 响应结构不得变化；幂等键校验不得移除 | PayControllerTest#create | MEDIUM | — |
| T-02 | M-01-F01-A01 | anchor: data-model §2.2.1 | `PayMapper.xml#insert` | MODIFY | 不得引入 N+1 | PayMapperTest#insert | LOW | — |
| T-03 | M-01-F01-A01 | anchor: implementation-handoff §14.2 | `PayControllerTest` | ADD | — | PayControllerTest | LOW | T-01 |

## 切片分组

- **S-01**: 支付创建行为闭环（API + Mapper + Test）（任务: T-01、T-02、T-03）

## P3 完成度自检绑定

- 全部 T-* 任务完成后才能运行 `/audit-completeness P3 <feature>`
