---
name: _菜单Seed索引
version: "3.30.6"
description: 菜单 Seed 索引骨架（前端菜单↔后端 seed）
---

# 菜单 Seed 索引（Menu Seed Index）


> 
> **目的**：把"前端页面 ↔ 后端菜单 seed SQL ↔ perm_code ↔ 操作权限码"四者关系汇总到**单一事实源**

---

## 0. 速览

| 维度 | 数量 |
|---|---|
| 模块菜单 seed 文件 | N |
| 4 方言覆盖 | h2/oracle/postgresql/kingbase |

## 1. 命名规则（5 段）

```
V<version>__<module>_seed_menus_<locale>.sql
```

- 段 1：版本号
- 段 2：模块（如 `auth`、`org`、`governance`）
- 段 3：固定 `seed_menus`
- 段 4：语言（如 `zh`）
- 段 5：方言放在文件路径里：`/db/migration/<dialect>/`

## 2. perm_code 规则

- 与 `_权限矩阵.md` 完全一致
- 种子 menu 必须对应存在的 perm_code

## 3. 操作权限项（sys_menu_operation）

- 每个菜单的 CRUD 操作映射到 perm_code

## 4. 4 方言覆盖

| 方言 | 路径 |
|---|---|
| h2 | `backend/<service>/src/main/resources/db/migration/h2/<subdir>/` |
| postgresql | `backend/<service>/src/main/resources/db/migration/postgresql/<subdir>/` |
| oracle | `backend/<service>/src/main/resources/db/migration/oracle/<subdir>/` |
| kingbase | `backend/<service>/src/main/resources/db/migration/kingbase/<subdir>/` |

## 5. ALTER SEQUENCE 重置（方言不一致）

- h2: `ALTER TABLE <tbl> ALTER COLUMN id RESTART WITH (SELECT MAX(id)+1 FROM <tbl>)`
- postgresql: `ALTER SEQUENCE <tbl>_seq RESTART WITH <n>` 或 `ALTER TABLE <tbl> ALTER COLUMN id RESTART WITH <n>`
- oracle: `ALTER SEQUENCE <seq> RESTART START WITH <n>` 或 `DBMS_SEQUENCE.SET_VALUE`
- kingbase: `ALTER SEQUENCE <seq> RESTART WITH <n>`

## 6. 联动索引

- 权限矩阵：`./_权限矩阵.md`
- 工程公约：`./_commons.md` §7
- ER 图：`./_ER图索引.md`
- Schema 变更：`./_Schema变更日志.md`
