# 11 条核心原则详细解释（v3.9.4 抽出）

> **目的**：SKILL.md 只能放简介，详细解释移到这里。
> **来源**：SKILL.md §"核心原则" 7-11 条。

---

## 原则 7：模板-产物对齐（Template-Artifact Alignment）

每个阶段产物的章节标题必须与 `templates/<对应>-模板.md` 的 H2/H3 标题对齐。Agent 写产物前必须先 `Read` 模板，写完后必须跑对应 gate 验证对齐。Gate 失败 = 阻塞。

**违反后果**：写出来的产物可能格式不对、字段缺失、和 gate 不匹配。check-skill-usage.sh §8 会暴露"templates 使用率低"。

---

## 原则 8：Gate-First 纪律

每个 Phase 产物写入文件后必须先跑 gate 取得 `EXIT_CODE=0`，才能进入下一 Phase。禁止"先写代码，再补 gate"。

**违反后果**：写到一半的产物被推到下一 Phase，错误被埋。

---

## 原则 9：即时反哺（Just-in-Time Feedback）

任何 gate 失败、P0 阻断、模板-产物不对齐事件必须立即写入 `.devflow/<feature>/feedback/feedback.md`，禁止等到 P10 才记录。`scripts/hooks/after-gate-fail-hook.sh` 只写项目本地队列；修改已安装 skill 需要用户明确批准。

**违反后果**：错误被埋到 P10 才被发现，浪费整轮。

---

## 原则 10：中断恢复（Interrupt-Recovery）· v3.9.2 NEW

任何 build 失败（`mvn compile` / `npm run build`）**必须**先跑 `checkpoint-state.sh save <feature> <phase> <subphase> 1 "<blocker>" "<next_action>"` 记录 blocker，再尝试修复。禁止"跳过失败、继续往下"。

任何用户切换话题/agent 退出/会话中断时，**必须**先 `checkpoint-state.sh save ...` 再转去处理别的话题。

**违反后果**：下次回来不知道"卡在哪、缺什么、怎么修"。check-skill-usage.sh §5 会暴露"state.json 有 blocker"。

---

## 原则 11：Build-Watchdog 即时校验（v3.9.3 NEW）

agent 写完任何 `.java` / `.xml` / `.sql` / `.vue` / `.ts` 后，必须立即调用 `bash scripts/build-watchdog.sh check <feature>`。失败 = 阻塞，禁止"我等会儿再编译"。

Phase 切换前必须调 `bash scripts/build-watchdog.sh gate <feature>` 生成 P3-build 收据。

**违反后果**：编译错误被埋到下次跑 Phase 出口 gate 才暴露。check-skill-usage.sh §6 会暴露"build-watchdog gate 收据缺失或 FAIL"。

---

## 实战教训（M-01 项目）

| 时间 | 原则违反 | 后果 | 修复 |
|------|----------|------|------|
| 2026-08-19 | 原则 10 | mvn compile 卡死 + 用户换话题，没 checkpoint → M-01 永远停在 P3 | 加 checkpoint-state.sh |
| 2026-08-20 | 原则 11 | agent 写 .java 不调 build-watchdog，编译错误被埋 | 加 build-watchdog.sh |
| 2026-08-20 | 原则 9 | 错误没即时反哺到 CHANGELOG | v3.9.1 已加 hook |

---

## 一自检命令

```bash
bash ~/.<tool>/skills/devflow/scripts/check-skill-usage.sh
bash ~/.<tool>/skills/devflow/scripts/checkpoint-state.sh resume <feature>
bash ~/.<tool>/skills/devflow/scripts/build-watchdog.sh detect <feature>
```

任何 FAIL/WARN 都意味着：本原则被违反。
