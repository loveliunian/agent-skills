---
name: INDEX-接口
version: "3.27.4"
description: 接口索引模板（详设 §6 + Controller 注解 + 与 auto 生成版并存）
---

# INDEX-接口.md


> **本文件由 `scripts/generate-interface-index.sh` 自动生成**
> **手工维护请在每个 `M-*` 详设 §6 接口设计 用标准格式填表**
> **生成时间: {DATE}**

---

## 1. 接口路径前缀

| 前缀 | 服务 | 鉴权 |
|---|---|---|
| `/{prefix}` | {service} | {public/JWT/service-role} |

---

## 2. 全量接口索引

> **本节由脚本自动填入**：聚合各 `M-*` 详设 §6 中的 `### <path>` 小节 + Controller 的 `@RequestMapping`

| 方法 | 路径 | 服务 | Controller | 鉴权 | 详设章节 | 备注 |
|---|---|---|---|---|---|---|
| _(自动生成)_ | | | | | | |

---

## 3. 鉴权覆盖统计

| 服务 | 接口数 | @PreAuthorize 数 | 覆盖率 |
|---|---|---|---|
| _(自动生成 — P4再按验收ID和代码路径核验)_ | | | |

---

## 4. 接口分组

- **公开接口**（无鉴权）：登录、注册、验证码、静态资源
- **用户接口**：CRUD 业务数据，需 JWT
- **管理接口**：需管理员角色
- **内部接口**：`/internal/**` 网关层强制内网

---

## 5. OpenAPI / Swagger 自动文档

> 若项目采用OpenAPI，记录实际文档端点；不得假设固定框架或路径。

---

## 6. 生成命令

```bash
bash "$SKILL_ROOT/scripts/generate-interface-index.sh" [DOC_DIR]
# 默认 DOC_DIR=docs/详细设计
```
