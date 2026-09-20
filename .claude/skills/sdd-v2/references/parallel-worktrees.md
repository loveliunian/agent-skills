# 并行开发工作副本(git worktree)

本文是**并行派发 feature** 的完整操作规程。并行度按总控规则 6 分级:tables 无交集且目录不重叠可 3~4 个,目录重叠最多 2 个,共享表一律串行。主会话按本文执行。改编自 coleam00/skills(MIT)的 worktree-create / worktree-merge 两个技能,按本项目三条硬约束重写(见下)。

## 本项目三条硬约束(为什么不能照搬通用流程)

1. **common 必须串行先行**:并行 `mvn install` 会写坏本地 Maven 仓库(d:/zxb/repository)里的 common jar,服务构建即报 `ZipFile invalid LOC header`。所以:副本开工前,主检出必须先串行 install 一次 common;所有副本内**禁止 install**。
2. **共享远程单库**:开发库 xyls_v1 是团队共享库,多个副本各跑 Flyway 会污染迁移历史(workflow 服务的 checksum 已经错位过一次)。所以:副本内**禁止起服务、禁止连库写数据**,健康检查退化为编译+单测冒烟。
3. **design/ 不入库**(.gitignore 忽略):副本里没有规范套件。实现代理读 spec、写 impl 日志都必须用**主检出的绝对路径**。

## 前置:串行闸门(主检出,一次)

fan-out 之前在主检出跑(约 1~2 分钟),**只做一次,后续各批并行直接复用**(common 源码未变就不必重跑;common 有新交付时重跑一次再 fan-out):

```
cd backend && mvn -q -pl common -am install -DskipTests -Djacoco.skip=true -Dcyclonedx.skip=true
```

此后各副本构建服务模块时,common 走本地仓库已装的构件,不需要也不会再 install。

## 一、建副本

每个 feature 一个副本(在主检出执行;`worktrees/` 已在 .gitignore,不会污染工作区):

```
git worktree add worktrees/sdd-<F编号> -b sdd/<F编号>
```

基线默认当前 HEAD。若想从远端干净基线拉,改用 `-b sdd/<F编号> origin/master`,但要确认依赖的前置 feature 已在 origin/master 里。

副本内**不需要**拷任何东西:deploy/.env 只有起服务才用(副本禁止起服务);.claude/ 副本里没有也不影响(spec-implementer 的规则文件由主会话在派发时直接给)。

## 二、派发(每副本一个 spec-implementer)

派发提示词在常规内容(spec 目录路径、impl-config 路径、规则文件)之外,**必须加四条副本纪律**:

1. **工作目录**:只在 `worktrees/sdd-<F编号>/` 内改代码;编译/测试命令都在副本目录里跑
2. **规范材料走主检出绝对路径**:读 spec 用 `D:/my_work/xiangshe/design/<F编号>/`;impl 日志写 `D:/my_work/xiangshe/design/_work/impl-logs/<F编号>.md`(F 编号不同,并行不冲突);禁止在副本里新建 design/ 目录
3. **禁止 `mvn install`**(护共享本地仓库);构建一律 `compile` / `test`
4. **禁止起服务、禁止连 xyls_v1 写数据**(护共享库);健康检查=本 feature 涉及模块的 `mvn -q -pl <模块> -am -DskipTests compile` + 相关单测

## 三、合并(主检出,走一次性集成分支)

1. 前置检查:确认当前在仓库根、不在 worktrees/ 里;确认两个分支都存在(`git rev-parse --verify sdd/<F编号>`)
2. 从当前分支拉集成分支:`git checkout -b integration-<第一个F编号>`
3. 按依赖顺序逐个 `git merge --no-ff sdd/<F编号>`;**每合并一个立刻跑** compile + 守卫测试(backend: `mvn -q -DskipTests compile` + ArchUnit 守卫;frontend: `npm run lint`),把破坏定位到引入它的那个分支。3~4 个副本并行时,分支间有改动目录重叠的(改动文件清单先 `git diff --name-only master...sdd/<F编号>` 比对)排到最后合,冲突概率最低
4. 全部合完跑完整校验:`sdd.py --stage deliver <F编号>` 逐 feature 跑,再派 spec-reviewer 做独立评审
5. 集成分支全绿后 `--no-ff` 合回原分支(通常 master),删集成分支

**冲突**:停下,点名冲突分支和文件,列人工解决步骤(解决 → git add → git commit → 重跑本文第三节)。**禁止自动解决冲突**。
**失败回滚**:`git checkout <原分支>` → `git branch -D integration-<F编号>`,集成分支即用即弃,主线零接触。

## 四、清理(征询用户后执行)

```
git worktree remove worktrees/sdd-<F编号>
git branch -d sdd/<F编号>
```

## Windows 注意

- 杀进程:`netstat -ano | findstr :<端口>` 找 PID,`taskkill /F /PID <pid>`;`mvn spring-boot:run` 杀父进程会残留 java 子进程占端口(本项目已实测)
- 检查是否在 worktrees 里:Git Bash 下 `[[ $(pwd) == */worktrees/* ]]` 可用
- 分支名带 `/`(如 sdd/F003)在 worktrees/ 下会产生嵌套目录,Windows 合法但留意路径长度;worktree 目录名用 `sdd-F003`(横线)避开
