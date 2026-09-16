# XYLS 项目领域检查清单（示例存档）

> 本文件是从通用 skill 提示词中迁出的**项目特定**内容（M-03 治理模块 / ElementServiceImpl 等）。
> 通用 skill 只保留抽象规则；本项目专属的检查项放这里，或放项目自己的 `docs/review/domain-checklist.md`。

## 治理模块专项（M-03 类）

| 检查项 | 命令 | 通过条件 |
|---|---|---|
| Process 删除是否含流程级共享锁 | `find backend/<service>/src/main/java -name "ElementServiceImpl.java" -exec grep -nE "gov:process\|instance-delete\|getActiveInstanceSummary" {} +` | 必须命中 |
| updateElement 是否处理 ACTIVE 引用边 | `grep -nE "HISTORICAL\|gov_reference\|updateReference" backend/<service>/src/main/java/*/service/impl/ElementServiceImpl.java` | updateElement 函数体内必须命中 |

## 实战数据（某次真实审计结果，供规模感知）

- 🔴 27 critical：`ElementServiceImpl` 2544 行（巨型 Service）、`UserServiceImpl` 1136 行、`deploy/init-oracle.sh` 硬编码密码、`deploy/smoke-test-postgresql.sh` 硬编码密码
- 🟡 12 warn：7 个超 500 行 Service、workflow-service 缺 springdoc-openapi
- 🟢 22 pass

## 慢查询风险示例（批量删除 / 导出）

```bash
# 批量删除是否每条单独 commit
find backend/<service>/src/main/java -name "ElementServiceImpl.java" -type f \
  -exec grep -A20 "batchDelete" {} +

# 导出是否全表加载
find backend/<service>/src/main/java -name "ElementServiceImpl.java" -type f \
  -exec grep -A10 "export" {} + | grep -E "selectList|stream|findAll"
```

## 历史教训（作为反例引用）

1. **M-03 测试报告 §3.3** 写"尝试 admin/admin123 及多个常见密码，均返回 401"属审计错误——正确凭证在代码 seed 中是确定的，禁止盲猜/穷举密码式"审计"。
2. **M-03 E2E 测试 48/48 SKIP** 曾被乐观放过——SKIP 率 100% 必须阻断。
3. **v1.7 命名风格**中英混合（如 `M-03-PRD验证报告.md`）已强制改为 kebab-case；示例：`docs/test/m-03-basic-library-validation-report.md`、`docs/retrospectives/m-03-basic-library-retro.md`。
