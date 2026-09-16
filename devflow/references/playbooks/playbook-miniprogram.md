# 微信小程序专项评审剧本

> 规则来源：微信小程序平台运营规范 & 基础库能力
> 核验日期：2026-08-26 ｜ 责任人：每次 P2a 前由评审主持人对照官方最新文档复核一次
- 微信官方文档：https://developers.weixin.qq.com/miniprogram/dev/framework/
- 运营规范：https://developers.weixin.qq.com/miniprogram/product/

> 适用：scope.frontend = mini-program。每项必须给出结论：✅通过 / ❌不通过（附问题编号 DF-xx） / N-A 不适用（附理由）。
> 依据：微信小程序平台运营规范、基础库能力现状。评审时以官方最新文档为准。

## 资质与审核

- [ ] **类目与资质**：本功能涉及的服务类目是否需要特殊资质（电商/医疗/社交/直播/金融）？主体类型（企业/个体/个人）是否支持该类目？（需附证据：拟选类目 + 资质清单）
- [ ] **审核风险项**：是否存在 iOS 虚拟支付、诱导分享/关注、测试账号缺失等已知拒审项？给审核员提供的测试路径与账号是否就绪？
- [ ] **隐私合规**：是否声明隐私保护指引（privacy 接口 2023 起强制拦截）？收集字段是否符合最小必要？

## 登录与用户身份

- [ ] **登录链路**：wx.login → code → 后端 code2Session 的时序是否在详设中明确？session_key 过期与重新登录策略？
- [ ] **unionid 策略**：是否需要跨小程序/公众号/APP 打通身份？绑定开放平台账号了吗？
- [ ] **手机号授权**：getPhoneNumber 为付费能力，PRD 中"手机号快捷登录"的成本与降级方案是否说明？

## 网络与域名

- [ ] **request 合法域名**：所有后端域名是否 HTTPS 且已备案并配置进小程序后台？开发期"不校验合法域名"是否会泄漏到生产包？
- [ ] **上传下载域名**：uploadFile/downloadFile/WebSocket 域名是否同样登记？

## 包体积与性能

- [ ] **体积预算**：主包 ≤2M、整包 ≤20M 的拆分方案？静态资源（图片/字体/lottie）是否 CDN 化而非打进包内？
- [ ] **分包规划**：独立分包/分包预下载策略与页面归属清单？
- [ ] **启动性能**：首屏数据是否依赖串行请求？是否使用初始渲染缓存/按需注入？

## 能力与 API

- [ ] **支付**：若涉及交易，wx.requestPayment 的主体认证与类目要求是否满足？iOS 虚拟商品是否有规避设计（或砍掉）？
- [ ] **订阅消息**：模板消息已下线，PRD 的通知场景是否改用订阅消息（一次性/长期）？模板 ID 申请责任人？
- [ ] **客服会话**：客服消息仅限用户 48h 内会话窗口，PRD 的"主动触达"预期是否越界？
- [ ] **基础库版本**：所用 API（如 skyline、worklet）的最低基础库版本与线上覆盖率？低版本降级方案？

## UI 与交互

- [ ] **页面栈层级**：连续跳转是否可能超 10 层上限？返回逻辑是否定义？
- [ ] **tabBar 一致性**：PRD 导航结构与 app.json tabBar/tabBar 自定义方案是否一致？
- [ ] **适配**：rpx 方案、iPhone 底部安全区（env(safe-area-inset)）、深色模式范围是否约定？
- [ ] **分享回流**：onShareAppMessage 携带参数的落地承接页是否在 PRD 页面清单中？

## 数据与后端协同

- [ ] **openid 注入**：后端接口如何获得调用者身份（header 带 code 换得的 token）？接口鉴权模型是否覆盖小程序端？

---

## 项目实战经验（jm-mini-program-v2 全链 P0-P10 沉淀，2026-08）

> 来源：山西焦煤在线小程序（24 页纯前端 + 存量后台接口复用型项目）。适用：小程序客户端为主、
> 后台接口复用存量系统、仓库内无自有 Java 服务的交付形态。

### 1. 纯前端项目的 P3 Gate 落地组合

后台接口全部复用存量系统时，仓库内仍需一个**真实可编译的 Maven 契约模块**承载 mvn compile/test/JaCoCo
检查（详设"复用接口"需要机器可验证的同源实现物）：Controller 契约层（注解+路径对齐详设 §3）+
`@Entity` 契约实体（字段名与详设 §2 snake_case 对齐）+ 契约测试。Gate 组合：

```bash
API_REQUIRED=0 PERSISTENCE_REQUIRED=0 bash scripts/p3_completion_gate.sh <bff-service> <feature>
```

实体字段类型须用 import 短名（`private BigDecimal xxx`）而非全限定名——`p4_prd_vs_code.sh` 的
字段解析正则不识别含点的类型声明。

### 2. 页面逻辑测试 harness（UI 验收点首轮验证）

node 环境 mock 全局 `Page`（收集页面定义）/`wx`（storage/导航/Toast/剪贴板）/`getCurrentPages`
后 `require` 页面 JS，即可直接调用 `onLoad/onShow/事件函数` 断言 `data` 变化与 `wx` 调用序列。
效果：核心行为页（登录校验/出价拦截/守卫跳转/金额公式）从"P6 全 SKIP 待真机"变为首轮可 PASS，
仅真机渲染性能/WSS 真连/容器生命周期保留 SKIP——首轮准确率口径更诚实也更高。

### 3. 详设冻结前预判下游 Gate 的解析口径（防 P4b 返工）

- `p4_prd_vs_code.sh` 页面扫描只覆盖 `<CLIENT_DIR>/pages/` 主包——分包页面若写入详设 §7，
  冻结前评估是否主包化（或接受该差异并登记）
- app.json 与 devflow-client.json 的 `pages` 数组必须严格一致（manifest 一致性校验逐项比对）
- 任何页面结构变更后必须重跑 `devflow-state.sh client-freeze`，否则 manifest 哈希校验失败
- `s4_first_pass_snapshot.sh record` 的输入文件不得是 first-pass-results.tsv 自身（自拷贝清空，
  v3.14.11 已加 `-ef` 防呆，结果文件先落独立路径仍是推荐做法）
