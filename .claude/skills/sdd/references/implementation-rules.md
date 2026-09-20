# 实现规则(给实现者/子代理的完整参考)

本文是实现步的规则全集。派发子代理时,把本文连同 spec 目录一起交给它。

## 1. 唯一依据原则

- 只读:`spec.md` / `spec.json` / `openapi.yaml`(如有)/ 上级的 `constitution.md` / `guard-tests-setup.md` / `impl-config.json`
- 禁止读详设原文。spec 是详设经过清单确认、spec 确认两道门口检查后的唯一合法形态,详设里 spec 没吸收的内容视为被有意排除
- 遇到 spec 覆盖不了的情况(缺字段语义、缺边界值、缺异常分支):**不猜**。登记 Q 到 `specs/open-questions.json`(编号顺延,blocking 按影响定),代码里写 `// [Q编号] 待澄清:一句话` 占位,先实现已明确的部分
- **占位接口的 L3 断言规则**(复盘 2026-09-20):凡占位接口(空集占位/恒值占位),其 L3 用例必须**显式断言占位行为并在用例名/注释标 [Q编号]**(如 `total=0 // [Q047] 待用户数据源`),禁止普通空断言——数据源接入后旧断言必红,强制销账,杜绝占位静默混过全链路

## 2. R 编号标注约定(硬要求)

每条规则 R<n> 实现完成后,在**真正承载该规则的代码处**留标注:

- 后端 Java:方法体首行或分支处 `// F003-R2 用户登录需校验验证码`
- 前端 TS/Vue:`// F003-R2 ...` 注释,规则写在触发该逻辑的函数/守卫处
- SQL:`-- F003-R2 ...`
- 测试类/用例名允许包含 `F003-R2`(如 `shouldRejectLogin_whenCaptchaWrong_F003_R2`)

纪律:

1. 标注贴实现处,不许统一堆在文件头或 README 凑数——脚本只验证存在性,凑数会被代码评审(交付确认)打回
2. 一条规则跨多个落点是正常的,每处都可以标;脚本对超过 5 处的会警告,确认不是滥标即可
3. 一段代码承载多条规则时,写全:`// F003-R2 / F003-R5`

## 3. 守卫测试

- guard-tests-setup.md 中已定义的守卫(ArchUnit 四类、ESLint、契约绑定)是底线,实现中必须保持全绿
- 新写的业务规则若 constitution 标了 `[测试]` 强度,必须落成自动化测试,测试名带 R 编号(见第 2 节)
- 守卫挡路时:先检查是不是自己实现偏了;确认实现符合 spec 而守卫仍红 → 停,报告主会话交用户裁决,禁止改守卫迁就实现

## 4. impl 日志格式

写到 `specs/_work/impl-logs/<F编号>.md`,必须包含(校验脚本按此解析):

```markdown
# F003 实现日志

## 执行命令
- backend-compile: mvn -q -DskipTests compile → exit 0
- backend-test: mvn -q test → exit 0
- frontend-lint: npm run lint → exit 0

## 守卫
- ArchUnit ContractEndpointBindingGuardTest: 全绿
- (其余守卫逐个列)

## 验收走查
- A1 (R2): 步骤… → 结果: 符合/不符合(原因)
- A2 (API:POST /api/xxx): 步骤… → 结果: …

## 待澄清
- [Q012] 余额扣减顺序未写明,已占位于 XxxService.java:88
```

要点:命令名必须与 impl-config.json 中登记的 name 完全一致,且每条带 `exit <数字>`;全部验收 A 编号必须出现;守卫段必写(收尾检查会检索"守卫"字样)。

## 5. 边界纪律

- 只改本 feature 涉及的文件;发现要动别的 feature 的地盘 → 停,报告,不做
- 不重构顺手代码、不"捎带"修别的 bug(发现的问题报告主会话)
- 数据库变更只做 spec.tables 登记过的表;spec 没登记的表不许动
- 接口实现必须与 openapi.yaml 一致(路径、方法、字段名、类型);发现不一致按冲突处理,不迁就
