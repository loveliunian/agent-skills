# APP（iOS/Android）专项评审

> 规则来源：App Store Review Guidelines + 工信部应用备案要求
> 核验日期：2026-08-26 ｜ 责任人：每次 P2a 前由评审主持人对照官方最新文档复核一次
- App Store Review Guidelines：https://developer.apple.com/app-store/review/guidelines/
- 工信部应用备案：https://beian.miit.gov.cn/

> 适用：scope.frontend = app。每项给出 ✅ / ❌（附 DF-xx）/ N-A（附理由）。以 Apple App Store Review Guidelines 与工信部/各应用商店最新要求为准。

## 商店审核

- [ ] **Apple 4.2 最小功能**：是否为纯 WebView 壳（高危拒审）？原生能力使用点清单？
- [ ] **热更新禁令**：JSPatch/动态下发代码方案是否存在（违反 2.5.2）？资源动态化与代码动态化的边界是否说清？
- [ ] **Sign in with Apple**：若提供微信/QQ 等三方登录，是否同步提供苹果登录？
- [ ] **Android 备案**：应用市场要求工信部备案号与软件著作权，责任人/时间表？
- [ ] **隐私清单**：PrivacyInfo.xcprivacy（Required Reason API）与各商店隐私报告的采集字段映射？

## 推送与触达

- [ ] **推送通道**：iOS APNs + Android 厂商通道（华为/小米/OPPO/vivo/荣耀）聚合方案选型？未上架厂商机的穿透率预期？
- [ ] **权限时机**：通知/定位/相册权限首次请求时机与拒绝后的引导路径（PRD 是否定义）？

## 支付与合规

- [ ] **IAP 范围**：数字商品/会员是否走 Apple IAP（30% 抽成）？实物商品才能用三方支付——PRD 商品类型边界？
- [ ] **实名/内容安全**：UGC 场景的内容审核（机器+人工）与实名认证链路？

## 工程与发布

- [ ] **深链**：Universal Links / App Links 的域名关联文件与回落 H5 页面？
- [ ] **渠道包与签名**：Android 多渠道打包体系、iOS 签名证书/描述文件有效期与续期责任人？
- [ ] **强更策略**：最低可运行版本拦截接口、强制升级弹窗文案与频控？
- [ ] **灰度发布**：分阶段发布（iOS Phased Release / Android 灰度）与回滚预案？
