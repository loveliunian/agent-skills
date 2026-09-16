## 动机

<!-- 为什么改；关联 Issue 编号 -->

## 改动

<!-- 主要文件与行为变化；如为破坏性变更请显著标注 -->

## 验证

- [ ] `bash devflow/tests/run-tests.sh` 全绿
- [ ] `bash devflow/scripts/check-skill-version.sh` 全绿（版本已递增且全量同步）
- [ ] `bash devflow/scripts/release-audit.sh` 全绿
- [ ] `bash devflow/scripts/secret-scan.sh` 全绿
- [ ] CHANGELOG 已新增对应版本条目

## 其他

- [ ] 不包含真实秘密 / 生产数据
- [ ] 新增第三方内容已登记 `THIRD_PARTY_NOTICES.md`
- [ ] 新增 phases/subagents/templates 资源已登记 `devflow/references/RESOURCE-REGISTRY.md`
