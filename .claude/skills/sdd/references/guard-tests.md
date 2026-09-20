# 守卫测试完整参考

生成 `specs/guard-tests-setup.md` 时以本文件为底稿,`<rootPackage>` 等占位按目标项目替换。机制:架构规则写成 JUnit 5 测试,`mvn test` 自动执行,违规即构建失败。工具 ArchUnit,规则与业务无关,任何 Spring Boot 单体或 Spring Cloud 微服务项目通用。

**先定形态再选守卫**(_work/parse-report.json 的 `architecture.style`,与 feature-list.json 的 `architecture` 必须一致):

| 形态 | 分层守卫 | 隔离守卫 | common 守卫 | 契约绑定 | 服务间一致性规则 |
|---|---|---|---|---|---|
| 单体(monolith) | 2.1 | 2.3 模块隔离 | 2.4 | 2.5(可选) | 不适用(同进程调用),章程里不得出现 Feign/注册中心强制项 |
| 微服务(microservices) | 2.1 | 2.2 服务隔离 | 2.4 | 2.5(可选) | 适用(只走声明式客户端) |

隔离守卫二选一:同时启用两套会在单体项目里把“跨模块”误判为“跨服务”,产生大量虚假违规。

## 1. 依赖与位置

```xml
<!-- 单体:放在公共模块或被所有业务模块依赖的模块;微服务:同理,或每个服务各自的守卫模块 -->
<dependency>
    <groupId>com.tngtech.archunit</groupId>
    <artifactId>archunit-junit5</artifactId>
    <version>1.3.0</version>
    <scope>test</scope>
</dependency>
```

测试类位置:`<公共模块>/src/test/java/<rootPackage>/architecture/`。放公共模块的好处:一处定义,所有模块/服务 `mvn test` 都执行。

注意:分析范围(`@AnalyzeClasses.packages`)必须覆盖全部待测代码。单体多模块时各模块包根不同的,填共同根包;微服务各服务根包不统一时,按服务分别建测试类,规则内容相同。

## 2. 守卫测试类(全文)

必选三类:2.1 分层 + 2.2或2.3 隔离(按形态二选一)+ 2.4 common;2.5 契约绑定为可选进阶。

### 2.1 LayeredArchitectureGuardTest —— 分层守卫

```java
package <rootPackage>.architecture;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.library.dependencies.SlicesRuleDefinition.slices;
import static com.tngtech.archunit.library.Architectures.layeredArchitecture;

@AnalyzeClasses(packages = "<rootPackage>", importOptions = ImportOption.DoNotIncludeTests.class)
class LayeredArchitectureGuardTest {

    // 分层访问方向:Controller 不可被任何层访问;Service 只能被 Controller 访问;Repository 只能被 Service 访问
    @ArchTest
    static final ArchRule layeredAccess = layeredArchitecture().consideringAllDependencies()
        .layer("Controller").definedBy("..controller..")
        .layer("Service").definedBy("..service..")
        .layer("Repository").definedBy("..repository..")
        .whereLayer("Controller").mayNotBeAccessedByAnyLayer()
        .whereLayer("Service").mayOnlyBeAccessedByLayers("Controller")
        .whereLayer("Repository").mayOnlyBeAccessedByLayers("Service");

    // Controller 禁止直连 Repository/Mapper(绕过 Service)
    @ArchTest
    static final ArchRule noControllerToRepository =
        noClasses().that().resideInAPackage("..controller..")
            .should().dependOnClassesThat()
            .resideInAnyPackage("..repository..", "..mapper..");

    // 禁止循环依赖(包级)
    @ArchTest
    static final ArchRule noPackageCycles =
        slices().matching("..(<rootPackage 最后一段>)..").should().beFreeOfCycles();
}
```

### 2.2 ServiceIsolationGuardTest —— 服务隔离守卫(仅微服务)

每一对服务生成一条规则:A 服务禁止依赖 B 服务的 internal/entity 包(只允许走 client/api 包)。

```java
package <rootPackage>.architecture;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

@AnalyzeClasses(packages = "<rootPackage>", importOptions = ImportOption.DoNotIncludeTests.class)
class ServiceIsolationGuardTest {

    // 模板:为每对服务复制一条。示例:user 服务禁止依赖 order 服务的内部包
    @ArchTest
    static final ArchRule user_mustNotDependOnOrderInternals =
        noClasses().that().resideInAPackage("..user..")
            .should().dependOnClassesThat()
            .resideInAnyPackage("..order.internal..", "..order.entity..", "..order.mapper..");

    @ArchTest
    static final ArchRule order_mustNotDependOnUserInternals =
        noClasses().that().resideInAPackage("..order..")
            .should().dependOnClassesThat()
            .resideInAnyPackage("..user.internal..", "..user.entity..", "..user.mapper..");
}
```

生成 setup 文档时:按详设/仓库的微服务清单列出服务对矩阵,每对一条规则;N 个服务全互查为 N×(N-1) 条,服务多时可只约束"已知的跨界高发对"并在文档注明取舍。单体项目不启用本类,改用 2.3。

### 2.3 ModuleIsolationGuardTest —— 模块隔离守卫(仅单体)

单体没有进程边界,依赖约束只能靠包结构:跨业务模块只能调对方对外暴露的 `api`/`service` 接口包,禁止直引 `internal`/`repository`/`mapper`/`entity`。模块清单取 `_work/parse-report.json` 的 `architecture.modules`。

```java
package <rootPackage>.architecture;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

@AnalyzeClasses(packages = "<rootPackage>", importOptions = ImportOption.DoNotIncludeTests.class)
class ModuleIsolationGuardTest {

    /** 业务模块清单:与 parse-report.architecture.modules 一一对应;新增模块必须同步登记在此 */
    private static final String[] MODULES = {"order", "user"};

    /** 模块包前缀约定,如 <rootPackage>.module.%s;按项目实际包结构调整 */
    private static final String MODULE_PKG = "..module.%s..";

    /** 其他模块的私有包后缀:只允许走 api/service 接口包 */
    private static final String[] PRIVATE_SUFFIXES = {"internal", "repository", "mapper", "entity"};

    @ArchTest
    static final ArchRule[] noCrossModuleInternals = buildRules();

    private static ArchRule[] buildRules() {
        List<ArchRule> rules = new ArrayList<>();
        for (String self : MODULES) {
            String[] forbidden = Arrays.stream(MODULES)
                .filter(other -> !other.equals(self))
                .flatMap(other -> Stream.of(PRIVATE_SUFFIXES)
                    .map(suf -> ".." + other + "." + suf + ".."))
                .collect(Collectors.toList()).toArray(new String[0]);
            rules.add(noClasses().that().resideInAPackage(String.format(MODULE_PKG, self))
                .should().dependOnClassesThat().resideInAnyPackage(forbidden)
                .as("模块 " + self + " 禁止直连其他模块的 internal/repository/mapper/entity 包"));
        }
        return rules.toArray(new ArchRule[0]);
    }
}
```

单体专用补充(按需选用,选中则写进 setup 文档守卫清单):

- 模块环依赖:2.1 的 `slices().matching("..")` 已覆盖包级判环;若模块包根为 `<root>.module.<name>`,把 matching 改为 `"<rootPackage>.module.(*).."` 更精准
- 进程内调用不必走 Feign:章程与守卫都不得为单体项目加 Feign/声明式客户端规则,否则测试恒真(没有候选类),假绿
- 包结构约定不统一时(模块名没写在固定层级),先把 `MODULE_PKG` 调对再启用;否则 `noClasses().that()` 匹配不到任何类,守卫同样假绿——这是单体形态最常见的坑

### 2.4 CommonModuleGuardTest —— common/shared 隔离守卫(通用,白名单制)

```java
package <rootPackage>.architecture;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

import static com.tngtech.archunit.library.Architectures.layeredArchitecture; // 如不需要可删
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;

@AnalyzeClasses(packages = "<rootPackage>", importOptions = ImportOption.DoNotIncludeTests.class)
class CommonModuleGuardTest {

    // common 只允许依赖 common 自身与白名单基础库;业务模块不在名单即违规
    @ArchTest
    static final ArchRule commonOnlyDependsOnBaseLibs =
        classes().that().resideInAPackage("..common..")
            .should().onlyDependOnClassesThat()
            .resideInAnyPackage(
                "..common..",
                "java..", "javax..", "jakarta..",
                "org.springframework..", "org.springframework.cloud..",
                "org.slf4j..", "com.fasterxml.jackson..",
                "org.apache.commons..", "com.google.common..", "io.swagger..", "lombok.."
                // 按项目实际第三方依赖扩充;宁可逐项补,不要放开整个前缀
            );
}
```

### 2.5 ContractBindingGuardTest —— 契约绑定守卫(可选,进阶)

机制:比对 OpenAPI 契约里的 path 集合与 Controller 注解里的 path 集合,两边必须一致(多出接口 = 未声明就上线;少接口 = 契约漂移)。

```java
package <rootPackage>.architecture;

import org.junit.jupiter.api.Test;
import org.springframework.web.bind.annotation.*;

import java.io.InputStream;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;
import java.util.stream.*;

import static org.junit.jupiter.api.Assertions.*;

class ContractBindingGuardTest {

    @Test
    void controllerEndpointsMustMatchOpenapiContracts() throws Exception {
        Set<String> contractPaths = loadContractPaths();
        Set<String> controllerPaths = scanControllerPaths();
        Set<String> onlyInContract = new TreeSet<>(contractPaths);
        onlyInContract.removeAll(controllerPaths);
        Set<String> onlyInCode = new TreeSet<>(controllerPaths);
        onlyInCode.removeAll(contractPaths);
        assertTrue(onlyInContract.isEmpty(), "契约有但代码没有: " + onlyInContract);
        assertTrue(onlyInCode.isEmpty(), "代码有但契约没有: " + onlyInCode);
    }

    /** 解析 specs/*/openapi.yaml 的 paths(简单行解析,避免引入 snakeyaml 依赖;复杂契约时换 snakeyaml) */
    private Set<String> loadContractPaths() throws Exception {
        // specs/ 可能在仓库根而不一定在当前模块工作目录;由 -Dspecs.dir 指定,默认取 "specs"
        Path root = Paths.get(System.getProperty("specs.dir", "specs")).toAbsolutePath();
        if (!Files.isDirectory(root)) {
            fail("未找到 specs 目录: " + root + "(多模块仓库请用 -Dspecs.dir 指向仓库根下的 specs/)");
        }
        try (Stream<Path> specs = Files.walk(root)) {
            return specs
                .filter(p -> p.getFileName().toString().equals("openapi.yaml"))
                .map(p -> collectPaths(p))
                .flatMap(Set::stream)
                .collect(Collectors.toSet());
        }
    }

    private Set<String> collectPaths(Path yaml) {
        Set<String> out = new HashSet<>();
        try {
            List<String> lines = Files.readAllLines(yaml);
            for (String l : lines) {
                // 二级缩进的 "  /path:" 即 path 键
                Matcher m = Pattern.compile("^  (/.+):\\s*$").matcher(l);
                if (m.matches()) out.add(m.group(1));
            }
        } catch (Exception e) {
            fail("契约文件读取失败: " + yaml + " " + e.getMessage());
        }
        return out;
    }

    /** 扫描 controller 包所有类的 @RequestMapping/@GetMapping 等注解 path(反射,不启动容器) */
    private Set<String> scanControllerPaths() throws Exception {
        Set<String> out = new HashSet<>();
        // 用 Spring 的 ClassPathScanningCandidateComponentProvider 找 @RestController
        org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider scanner =
            new org.springframework.context.annotation.ClassPathScanningCandidateComponentProvider(false);
        scanner.addIncludeFilter(new org.springframework.core.type.filter.AnnotationTypeFilter(RestController.class));
        String basePackage = "<rootPackage>";
        for (var bd : scanner.findCandidateComponents(basePackage)) {
            Class<?> clazz = Class.forName(bd.getBeanClassName());
            String base = "";
            RequestMapping rm = clazz.getAnnotation(RequestMapping.class);
            if (rm != null && rm.value().length > 0) base = rm.value()[0];
            for (var method : clazz.getDeclaredMethods()) {
                String[] paths = null;
                for (var ann : List.of(method.getAnnotations())) {
                    if (ann instanceof GetMapping a) paths = a.value();
                    else if (ann instanceof PostMapping a) paths = a.value();
                    else if (ann instanceof PutMapping a) paths = a.value();
                    else if (ann instanceof DeleteMapping a) paths = a.value();
                    else if (ann instanceof RequestMapping a) paths = a.value();
                }
                if (paths != null) {
                    for (String p : paths) out.add((base + (p.isEmpty() ? "" : p)).replaceAll("//+", "/"));
                }
            }
        }
        return out;
    }
}
```

注意:上面 path 解析是"约定优于配置"的简化版,要求 openapi.yaml 的 path 键统一两格缩进;项目契约格式复杂时改用 snakeyaml 解析。首个契约 feature 落地时再启用本类,启用前在 setup 文档标注"暂缓"。单体项目下 `basePackage` 填应用根包即可(只有一个应用),多服务形态则每个服务各扫自己的根包。

### 2.6 DDL 逻辑删除互斥守卫(可选)

「删了重插」的表若走逻辑删除,软删行会占住业务列唯一索引,插入同键必撞(先例:Q017/Q018 两起 500)。在 SchemaConventionGuardTest(或独立 DdlLogicDeleteGuardTest)中扩展:

- 解析 Flyway 脚本,提取每张表的 UNIQUE 约束/唯一索引(排除主键与纯 `deleted`+审计列的组合)
- 凡带业务列唯一约束的表,要求满足其一,缺一即红:
  1. 建表语句注释含 `PHYSICAL_DELETE` 标记(声明本表删除走物理删除特例);
  2. 唯一键包含 `deleted` 列(逻辑删除后同键可重建);
  3. 表未启用逻辑删除(实体不继承含 @TableLogic 的 BaseEntity 时,注释 `NO_LOGIC_DELETE` 声明)
- **解析器须先剥除 SQL 注释再解析建表体**(`--.*$` 行注释与 `/* */` 块注释)——否则注释中的 `);` 会被误判为建表截断,逼得后续迁移用改注释的方式绕守卫(案例:casebook#注释绕守卫)
- **种子行快照断言**:对种子表(ext_* 桩表/预置行)记录行数与关键内容,新迁移不得增删改既有种子行——防止占位桩污染其他 feature 的候选数据(先例 V7,详见 casebook#种子桩污染)
- 白名单扩充须在守卫方案"白名单变更记录"留痕

## 3. 前端守卫(Vue3)

用 ESLint flat config 承担,不引入 ArchUnit:

```js
// eslint.config.js(节选,追加到项目现有配置)
export default [
  // ...既有配置
  {
    rules: {
      // 禁止跨层引用 internal/实现包
      'no-restricted-imports': ['error', {
        patterns: [
          { group: ['**/internal/**', '**/api/impl/**'],
            message: '禁止引用 internal/实现包,走对外接口' },
          { group: ['**/composables/**'],
            message: '组合式函数统一从 index 导入' } // 可按需删
        ]
      }],
      'vue/component-name-in-template-casing': ['error', 'PascalCase'],
      'vue/prop-name-casing': ['error', 'camelCase']
    }
  }
]
```

接入 CI:`lint` 必须作为构建前置步骤(`package.json` 的 `"build": "npm run lint && vite build"` 或流水线两步)。

### 3.0 测试锚点守卫(详设含 testId 时必选)

详设 formFields/controls 登记的 testId 是测试定位契约,必须机器对账,不走肉眼(实现代理漏加/改名,走查发现不了,测试期才发现):

- 脚本对账:`python scripts/check_testids.py --design <详设JSON,part 分片可多次传> --src <前端源码目录>`,详设登记的 testId 源码找不到即红(退出码 1)、源码多出未登记的报 WARN(防实现期自由发挥);详设零 testId(纯后端/老详设)自动 SKIP 不误伤。随 G2 与其他守卫一起跑
- 反向验证按 §4 程序走:临时删掉一个 `data-testid` 确认守卫变红,再恢复
- 详设 JSON 不在仓内(老项目)时本守卫降级为"spec 规则里的 testId ↔ 源码"抽检,并在守卫方案登记降级原因

### 3.1 类型检查(必选)

### 3.1 类型检查(必选)

ESLint 与 esbuild 均不查类型:`defineProps<{...}>` 漏写调用括号、字段名与契约不符这类错误,vite build 照样全绿,只在运行时爆发(案例:casebook#类型错误运行时爆发)。因此:

- `npm i -D vue-tsc`,build 链改为 `"build": "npm run lint && vue-tsc --noEmit && vite build"`(另留 `"typecheck": "vue-tsc --noEmit"` 便于单跑)
- 首次启用会暴露存量类型错误,属预期:逐条修真实错误,禁止为过检改 `any` 或删类型
- 归档声明:守卫方案的守卫清单与"补测清单"须登记本项

### 3.2 浏览器冒烟(必选)

走查留痕拦不住运行时崩溃与链路断裂(组件挂载即崩、入口置灰断链都发生在真实点击时)。至少一条 Playwright 冒烟用例,走「**首屏初始态**→树/列表加载→选中节点→详情渲染→维护入口可用」主链:

- `npm i -D @playwright/test && npx playwright install chromium`;用例放 e2e 归档目录,随 ④步全量回归一起跑
- **分母建账硬规则**(复盘 2026-09-19):首个含前端交付的 feature 过 G3 时,必须在 setup 文档登记「页面清单×主链矩阵」;此后每个前端 feature 过闸增量补一条对应页面的冒烟。**"至少一条"是地板不是目标**——step4 开口时冒烟数 < 页面数即列缺口,不进全量回归
- 冒烟不造数据:库里只有初始种子时,数据相关段用条件跳过,造数归 local-tests 场景脚本
- 页面跳变导致的重复文案用 `.first()` 规避严格模式冲突;pageerror 必须断言为空
- **锚点定位优先**(复盘 2026-09-20):Playwright 用例定位控件一律 `page.getByTestId('<testId>')`(Playwright 默认按 `data-testid` 属性取),禁止靠 class/文案/层级选择器猜控件——详设登记了 testId 的控件,用例里用未登记的选择器定位属违规;用例注释可标锚点以备审计(如 `# anchor: login-username-input`)
- **登录态刷新标准断言**(复盘 2026-09-20):凡登录态可见的页面,冒烟必须含一条「`page.reload()` 后仍停留在本页且核心数据仍在(未被踢回 /login 或 /no-permission)」断言——会话恢复是否生效,只有刷新能证明(先例:刷新掉登录,27 条冒烟无一覆盖,靠用户手点发现)
- **前端 R 触达对账**:涉及前端交付的 spec 规则 R,必须被某条 Playwright 用例触达(用例注释标 `F<xxx>-R<n>`),或在 setup 文档"补测清单"声明豁免(纯后端规则本层不适用)——冒烟只承载用户可感知链路,规则级验证归 L2/L3,但"哪些 R 由 UI 覆盖"必须有账

## 4. 验证程序(强制,结果必须写入 setup 文档)

1. **正向**:`mvn test -Dtest=*GuardTest` 全绿。前端:`npm run lint` 全绿。
2. **反向**:每个**已启用**的守卫类至少验证一条规则真的会拦——临时在违规位置建一个类(单体:一个模块直连另一模块的 repository;微服务:Controller 直接注入 repository),跑对应测试确认变红,删除后复跑恢复全绿。
3. 把两步的执行时间、命令、结果(绿/红)写入 setup 文档"验证记录"节;环境缺构建工具时写"未实跑",禁止写"已验证"。
4. **假绿体检**:`noClasses().that().resideInAPackage(X)` 在 X 匹配不到任何类时会静默通过——守卫看着全绿,其实一行没管。做法:在守卫类里加一条兼底测试,用 `new ClassFileImporter().withImportOption(new ImportOption.DoNotIncludeTests()).importPackages("<rootPackage>")` 拿到 `JavaClasses`,断言 `classes.containing(PackageNameContainsPatterns.fromString(X))` 的 `size() > 0`;为 0 即说明包前缀写错。这是隔离与契约守卫最常见的失效模式。

## 5. CI 接线

- Maven 项目:守卫测试在默认 test 阶段,CI 的 `mvn verify` 天然执行;如需分离,用 `mvn test -Dtest=*GuardTest` 独立一步并设为合并前置
- 前端:`npm run lint` 独立一步,失败阻断合并
- 建议:守卫失败的信息要能定位到人——报错信息里 ArchUnit 自带违规类名与行号,CI 日志直接可见,无需额外配置

## 6. 覆盖率门禁与 e2e 回归脚本(对应 constitution"测试策略"[测试] 规则)

### 6.1 单测覆盖率门禁(JaCoCo)

后端 pom.xml 接入 jacoco-maven-plugin,`check` 绑定 verify 阶段,低于阈值直接构建失败:

```xml
<plugin>
  <groupId>org.jacoco</groupId>
  <artifactId>jacoco-maven-plugin</artifactId>
  <version>0.8.12</version>
  <executions>
    <execution>
      <goals><goal>prepare-agent</goal></goals>
    </execution>
    <execution>
      <id>check</id>
      <phase>verify</phase>
      <goals><goal>check</goal></goals>
      <configuration>
        <rules>
          <rule>
            <element>BUNDLE</element>
            <limits>
              <limit><counter>LINE</counter><value>COVEREDRATIO</value><minimum>0.80</minimum></limit>
            </limits>
          </rule>
        </rules>
      </configuration>
    </execution>
  </executions>
</plugin>
```

- 阈值以 constitution"测试策略"为准,setup 文档只写命令落点,不复述阈值(单一真源)
- 覆盖率命令(如 `mvn -q verify`)必须登记进 `specs/guard-tests-setup.md` 的"命令落点"表,实现阶段与 CI 均以该表为准;未登记不认
- 生成代码(Lombok/MapStruct)、启动类按需 exclude;排除清单写在 setup 文档里,扩充留痕

- **R 规则全覆盖(不分强度)**:spec 的每条业务规则 R 必须有自动化验证落点——单测(L2)或 L3 接口用例(§6.3)或 Playwright 触达标注(§3.2),三者其一,缺口登记"补测清单";确无法自动化的(纯视觉/纯人工操作类)在 impl 日志逐条声明并走人工走查。行覆盖率到不了 100% 不追分,规则覆盖必须 100%——分母是 R,不是行

### 6.2 e2e 回归脚本(local-tests 资产化)

- 实现阶段每个 feature 自验时,验收用例 A 对应的场景脚本落盘为 `specs/_work/local-tests/<F编号>/` 下的可执行文件,每个都可独立重复执行(自备前置数据或写明准备步骤)
- 全部 feature 收尾前,**全量重跑**一遍所有已落盘脚本,而非只跑最后一次改动涉及的 feature——回归的意义在旧场景不坏
- 全绿后把脚本归档到登记目录(默认 `tests/e2e/`,以 constitution 为准),作为后续迭代的回归资产;归档动作记入收尾清单
- 重跑命令与退出码写回各 feature 的 spec 修订记录或 setup 文档验证记录,格式与其他命令一致(`命令 → exit N`)

### 6.3 L3 接口全量测试(分母 = spec apis[] 全集)

场景测试(§6.2)的分母是验收 A,管"跨接口业务链路走得通";本层管"每个端点行为正确"——接口列表 spec 里都登记了,不允许没被验收引用的接口漏出测试体系。

- **分母**:`spec.json` 的 `apis[]` 全集(method+path),外加每条 `errorCodes` 至少一条反向用例(错误码是登记过的契约,不测等于没写)
- **生成**:实现代理自查时从 spec.json 搬运生成——正常路径用 `requestFields` 的 example 构造请求,反向用例按 `errorCodes.when` 构造触发条件;是搬运不是创作,单 feature 约 5~10 分钟
- **落盘**:`specs/_work/api-tests/<F编号>/`(可独立重跑的脚本或 HTTP 用例文件),每个用例文件必须含 `METHOD /path` 字样(引擎按它对账);命令与退出码写 impl 日志
- **豁免**:确不自动化测的接口(纯查询由前端冒烟覆盖、healthcheck 等)逐行登记 `specs/_work/api-tests/_exempt.md`,格式 `METHOD /path 原因`;无理由的豁免视为缺口
- **执行时机**:deliver 闸只对账本 feature;`--stage done` 对账全集——两道都是差集即红
- **与 L4 分工**:L3 不写多步业务链路;链路类场景(如"建组织→建用户→停用→回收站恢复")仍归 §6.2 场景脚本

## 7. 常见坑

| 坑 | 处理 |
|---|---|
| 测试跑了但什么都没分析 | `@AnalyzeClasses.packages` 根包写错(比实际包浅一级没问题,写深了会漏) |
| 隔离守卫匹配不到任何类(恒绿) | 单体先核对 `MODULE_PKG` 包前缀约定,微服务先核对服务包名;按 §4 第 4 步做假绿体检 |
| 单体项目装了服务隔离守卫 | 删除 2.2,只留 2.3;同时把章程里的 Feign/注册中心强制项改掉 |
| 生成的代码(Lombok/MapStruct)报违规 | 加 `ImportOption.DoNotIncludeTests` 之外,按需排除生成包,不要为过测试改分层 |
| 多模块项目只分析到单模块 | ArchUnit 分析的是 classpath;确保测试模块依赖了要分析的全部业务模块 |
| 白名单越放越宽最后失效 | common 白名单每次扩充必须在 setup 文档"白名单变更记录"留痕并说明理由 |
| 契约守卫在路径带路径参数时误报 | `/api/v1/xx/{id}` 两边写法必须一致;比对前统一 `replaceAll("\\{[^}]+\\}", "{}")` |
| 契约守卫在子模块里找不到 specs/ | 用 `-Dspecs.dir` 指向仓库根下的 specs/,不要靠相对路径猜 |
