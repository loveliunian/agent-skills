---
name: sdd
description: SDD 规范驱动开发(五步流程):解析详设→生成规范→逐功能实现→本地场景测试→复盘,一个 skill 走完。状态机脚本报数驱动,守门引擎校验,确定性纪律由 hook 强制。触发词:sdd、规范驱动、详设转spec、sdd实现、开工实现、sdd回顾、复盘。
---

# SDD 五步流程

详设文档 → feature 清单与 spec 规范 → 代码 → 本地场景验证 → 复盘。

```
①解析 ──→ ②规范 ──→ ③实现(逐功能循环)──→ ④测试 ──→ ⑤复盘
        清单确认          spec确认                交付确认(每个功能)
```

## 铁律:先看状态,再行动

**每次会话/每轮工作开始,第一条命令永远是**:

```
python <本skill目录>/scripts/sdd_state.py <specs目录> state
```

它输出状态机 JSON:每个 feature 的状态、下一动作(nextAction)、整条流水线的下一步(pipelineNext)、未关闭的高阻塞 Q。**你该做什么以 state 的报数为准,不靠记忆和推断**。按报数跳对应手册:

| state 报数 | 手册 |
|---|---|
| 没有 feature 清单 / 有 feature 缺 spec | `step1-parse.md`(解析详设+拆清单) |
| 有待确认的清单 | `step1-parse.md` 第 8 节(清单确认) |
| 有草案 spec | `step2-specs.md`(规范:章程/spec/守卫/放行) |
| 有已确认 spec | `step3-implement.md`(实现循环) |
| 全部已交付 | `step4-test.md`(场景测试+收尾) |
| 收尾检查全绿 | `step5-retro.md`(复盘) |

## 编号速查(数据里会出现的字母)

| 字母 | 含义 | 示例 |
|---|---|---|
| F | 功能项(feature) | F008 |
| R | 业务规则 | F008-R3 |
| A | 验收用例 | A2 |
| Q | 待定问题(未决事项) | Q115 |
| C | 详设分片 | C05 |

## 命令速查

```
python scripts/sdd_state.py <specs> state                       # 状态机报数(永远第一条)
python scripts/sdd_state.py <specs> ready                       # 就绪探测:现在能派发谁(事件驱动)
python scripts/sdd.py <specs> --stage env                       # 环境预检:工具链/网络/端口(放行前必跑,无 MISS)
python scripts/sdd.py <specs> --stage parse                     # ①解析对账
python scripts/sdd.py <specs> --stage list --strict             # ①清单确认检查(建议 --strict)
python scripts/sdd_state.py <specs> approve-list --by <谁>       # ①清单确认回写
python scripts/sdd.py <specs> --stage spec  --strict            # ②spec 确认检查
python scripts/sdd.py <specs> --set-status <F> --status 已确认 --by <谁>   # ②spec 回写
python scripts/sdd.py <specs> --stage start --strict            # ②开工放行
python scripts/sdd.py <specs> --stage begin <F>                 # ③开工登记
python scripts/sdd.py <specs> --stage deliver <F>               # ③交付自查
python scripts/sdd.py <specs> --stage report <F>                # ③交付确认呈报(自动生成)
python scripts/sdd.py <specs> --stage set-status <F> --status 实现中|已交付 --by <谁>
python scripts/sdd.py <specs> --stage done                      # ④收尾检查
```

功能状态值只有四个:**草案 → 已确认 → 实现中 → 已交付**。

## 总控规则(全程生效,各手册不得违反)

1. **门口检查由脚本守门**:推进前必须跑对应 `--stage` 全绿;确认类检查建议带 `--strict`。脚本红着找用户视为违规。
2. **spec 是唯一依据**:实现只读 spec.md/json + openapi.yaml + constitution.md + guard-tests-setup.md,禁止翻详设另起炉灶;详设里 spec 没吸收的内容不许出现在代码里。
3. **禁止编造**:spec 没写清的业务逻辑登记 Q(`open-questions.json`),产物与代码中以 `[Q编号]` 占位;字段口径偏离详设必须登记 Q 留痕(三部曲:详设定口径→spec 引用→迁移落地)。
4. **产物边界**:只写 `specs/` 下文件;唯一例外守卫测试落地源码树,须用户同意。
5. **规则落点留痕**:每条 R 编号至少一处 `F<xxx>-R<n>` 标注贴在实现的代码旁;编译/测试必须实跑并记录退出码。
6. **并行分级**:派发节奏与冲突契约以 step3「事件驱动派发」为唯一口径(ready 探测即就即派;交付闸与评审派发**批量化**——完成通知攒批处理,判据单个不松);并行**数量**按候选 feature 两两比对 `tables[]` 交集与改动目录定级——无交集且目录不重叠可最多 6 个并行;目录重叠最多 2 个;共享表串行。**多模块隔离优先于软隔离**:feature 归属模块不同(见清单 `module` 字段)时各编各的 `mvn -pl <module>`;单模块工程的高冲突对才升级 worktree,按 `references/parallel-worktrees.md` 纪律执行(common 先串行 install 一次、副本禁 install/禁起服务/禁连库)。并行在途时全量 `mvn test` 不算证据,只认隔离副本复跑(step3 铁律)。
7. **委托模式**:`specs/_work/gate-delegation.json` 存在时,各确认点按其配置由 AI 自裁或呈报不阻塞;自裁结论必须追加 `specs/_work/gate-decisions.md`,不落档视同未确认。
   **开工前主动询问**:首次解析前,若开关文件不存在,必须向用户说明并询问是否开启。询问话术要点——
   > 「是否开启**委托模式**?开启后:清单确认、各批 spec 确认、交付确认这些流程关口不再停下来等你,由 AI 按规范自行裁决,但**每一次自裁都会落档到 gate-decisions.md 供你事后追溯**;未决技术取舍也会先做再登记留痕。以下五类情况仍会无条件停下等你:高阻塞问题待裁决、spec 与详设/现有代码矛盾、同一问题修 3 轮仍不收敛、守卫挡路且实现没错、其他 AI 无权拍板的事项。不开则每个关口都会等你确认,节奏慢但步步可控。」
   用户明确同意后才创建开关文件;拒绝或未表态则全程走人工确认。
   **中途开启/关闭均可**:开关即文件存不存在,任何时候用户说"开启委托"即创建文件、自下一个关口起生效(此前已人工确认的记录不追溯重裁);说"关闭委托"即删文件、自下个关口恢复人工确认。用户中途说出意图类表述(如"后面不用问我了""接下来的你自己定")时,AI 应确认一句"是否即开启委托模式"后照此办理。
8. **委托红线(不可自裁)**:高阻塞 Q 待裁决、spec 与详设/现有代码矛盾、评审同一问题 3 轮仍报、测试同一问题修 3 次仍红、守卫挡路且实现没错——五类一律停,呈用户裁决。
9. **双文件纪律**:有 json twin 的产物先写 json 再派生 md,脚本做同源校验;**状态回写一律走命令**(hook 会拦截手工改 status)。
10. **过程目录**:`specs/_work/` 是过程件家(计划、抽取件、日志、委托档),开工放行前不得删除,完成后保留追溯。

## 目录

- `references/step1~5-*.md` — 五步手册,细则只在手册里,本文件不重复
- `references/pipeline-philosophy.md` — 流水线编排思想说明(非操作指导):质量/顺序/并行/红线的机制分工
- `references/guard-tests.md`、`implementation-rules.md`、`parallel-worktrees.md` — 守卫/实现/并行三份参考
- `references/casebook.md` — 事故案例库:手册与报错文案里的"先例 Qxxx/案例"指针都指到这里;新增案例须同时指认催生的机制条目
- `scripts/sdd.py` — 守门引擎;`scripts/sdd_state.py` — 状态机;`schemas/`、`templates/` — 机器 twin 与模板
- 过程件契约(无 schema 的三个):`templates/gate-delegation.template.json`(委托开关)、`templates/q-range-lock.template.json`(并行 Q 编号锁)、`templates/pipeline.template.json`(并行派发表);均落 `specs/_work/`
- `templates/detail-design.example.json` — 详设输入格式**示例**(真实取值,禁止照抄);填写规则见 `templates/detail-design.template.md`

## 适用范围与环境依赖

- 守门引擎与状态机**栈无关**(只依赖文件契约);守卫参考(guard-tests.md)与章程模板以 **Spring Boot 单体/微服务 + Vue3** 为基线,其他栈替换这两份即可,流程与脚本不动
- "确定性纪律由 hook 强制"依赖项目 `.claude/hooks/` 下的 sdd 三件套;复制本 skill 到其他仓库时需一并携带,未装时状态回写纪律降级为自觉遵守
