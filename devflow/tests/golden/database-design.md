# demo-pay 数据库设计决策

> 本文档承载 DDR 与数据库迁移（v3.27.15 起从详设移出）。

## §1 设计决策记录（DDR）

<!-- anchor: design-decisions -->

<!-- df:begin:ddr-index -->
| 编号 | 决策点 | 备选方案 | 选定 | 理由 |
|---|---|---|---|---|
| DDR-1 | order_no 长度 | varchar(20) / varchar(32) | varchar(64) | 编码规则 18 位定长 + 2 位冗余，预留 3 倍兼容跨系统单号；参照 §13 规范 R-004 |
| DDR-2 | refund_no 类型 | varchar / text | varchar(64) | 须参与唯一索引；text 不能建普通索引（§13 规范 R-007） |
| DDR-3 | 金额精度 | DECIMAL(10,2) / DECIMAL(12,2) | DECIMAL(12,2) | 单笔上限 10^10 分级业务口径，2 位小数满足分账精度；量化：最大流水 9,999,999,999.99 |

> 每条设计决策回答了「为什么这么设计」，并与具体字段一一对应（见下表）。理由均来自业务口径、规范条目或量化数据，不只凭经验。
<!-- df:end:ddr-index -->

<!-- df:begin:ddr-matrix -->
| 表 | 字段 | 关联 DDR |
|---|---|---|
| pay_order | order_no | DDR-1 |
| pay_refund | refund_no | DDR-2、DDR-3 |

全部 2 个字段都能追溯到决定它的设计决策。
<!-- df:end:ddr-matrix -->

## §2 数据库迁移

Flyway 四方言脚本与初始数据见分模块；场景 A（全新功能），无历史数据迁移。
