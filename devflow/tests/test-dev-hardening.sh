#!/usr/bin/env bash
# test-dev-hardening.sh · v3.26.1 开发面硬化回归
# 钉住本轮修复的六个缺陷（修复前均可复现）：
#   1) check-code-standards.sh：单服务目录用法假绿（扫 0 文件报 PASS）+ --strict 单独用
#      法把 flag 吃成目录 + 零服务目录拒绝静默 PASS；
#   2) detect-n-plus-one.sh：单服务目录用法假绿 + JPA findById 循环漏检 + 零服务目录
#      拒绝静默 PASS；
#   3) check-arch-pitfalls.sh：CSRF 死正则（csrf().disable() 永不命中）；
#   4) p3b_code_review_gate.sh：中文路径验收点文件绑不进证据树 → P3b 永远产不出收据；
#   5) p3_security_perf_gate.sh：§5 默认目录假绿 + §4 MyBatis ${} 零覆盖 + --service=
#      形式与裸服务名归一化；
#   6) check-permission-consistency.sh：含数字权限码 + hasAnyAuthority 提取漏检。
# 兼容性注意：本文件跑在 macOS / Git Bash 3.2——ok/bad 必须在顶层调用（子 shell 计数
# 不回传）；变量与多字节字符相邻时一律 ${var} 括号化（bash 3.2 多字节解析怪癖）。
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
source "$TEST_DIR/testlib.sh"

S="$ROOT/scripts"
C="$ROOT/checks"
TMP="$(mktemp -d -t df-devhard.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# in_dir <dir> <cmd...>：在 dir 下执行命令，输出落 $IN_OUT（临时文件），rc 经 IN_RC 回传
# （不用 $(...) 直接包 ok/bad 或 rc——命令替换是子 shell，变量与计数都不回传）
IN_OUT="$TMP/in-dir.last.out"
in_dir() {
  local d="$1"; shift
  ( cd "$d" && "$@" ) > "$IN_OUT" 2>&1
  IN_RC=$?
}
last_out() { cat "$IN_OUT"; }

mk_oversized_controller() {
  local dir="$1"
  mkdir -p "$dir"
  {
    echo "public class AController {"
    for i in $(seq 1 260); do echo "    // line $i padding padding padding padding"; done
    echo "}"
  } > "$dir/AController.java"
}

# ---------- 1. check-code-standards ----------
W1="$TMP/ccs"; mkdir -p "$W1"
mk_oversized_controller "$W1/backend/order-service/src/main/java/com/x/controller"

in_dir "$W1" bash "$C/check-code-standards.sh" backend/order-service
out="$(last_out)"
if [ "$IN_RC" -ne 1 ]; then bad "ccs 单服务用法应对超限 Controller FAIL（rc=${IN_RC}）"; else ok "ccs 单服务用法 FAIL（不再假绿）"; fi
printf '%s\n' "$out" | grep -q "262 行" && ok "ccs 单服务用法真实扫描到文件" || bad "ccs 单服务用法未扫描到文件（疑似仍假绿）"

in_dir "$W1" bash "$C/check-code-standards.sh" --strict
out="$(last_out)"
printf '%s\n' "$out" | grep -q "目录不存在：--strict" && bad "ccs --strict 仍被吃成目录" || ok "ccs --strict 单独用法不再误报目录不存在"

in_dir "$W1" bash "$C/check-code-standards.sh"
out="$(last_out)"
if [ "$IN_RC" -eq 1 ] && printf '%s\n' "$out" | grep -q "262 行"; then
  ok "ccs 默认 backend 口径扫到违规"
else
  bad "ccs 默认口径未扫到违规（rc=${IN_RC}）"
fi

W1b="$TMP/ccs-empty"; mkdir -p "$W1b/backend-nothing"
in_dir "$W1b" bash "$C/check-code-standards.sh"
out="$(last_out)"
if [ "$IN_RC" -eq 1 ] && printf '%s\n' "$out" | grep -qE "目录不存在：backend|未发现服务目录"; then
  ok "ccs backend 缺失 fail-closed"
else
  bad "ccs backend 缺失未拒绝（rc=${IN_RC}）"
fi
W1c="$TMP/ccs-nosvc"; mkdir -p "$W1c/backend/empty-module"
in_dir "$W1c" bash "$C/check-code-standards.sh"
out="$(last_out)"
if [ "$IN_RC" -eq 1 ] && printf '%s\n' "$out" | grep -q "未发现服务目录"; then
  ok "ccs 目录存在但无服务 fail-closed（拒绝零文件假绿）"
else
  bad "ccs 无服务目录未拒绝（rc=${IN_RC}）"
fi

# ---------- 2. detect-n-plus-one ----------
W2="$TMP/n1"; mkdir -p "$W2/backend/order-service/src/main/java/com/x/service/impl"
cat > "$W2/backend/order-service/src/main/java/com/x/service/impl/OrderServiceImpl.java" <<'EOF'
public class OrderServiceImpl {
    void process(java.util.List<Long> ids, com.x.Mapper m, com.x.Repo r) {
        for (Long id : ids) {
            m.selectById(id);
            r.findById(id);
        }
    }
}
EOF
in_dir "$W2" bash "$C/detect-n-plus-one.sh" backend/order-service
out="$(last_out)"
printf '%s\n' "$out" | grep -q "发现 2 处潜在 N+1" \
  && ok "n1 单服务用法检出 2 处（MyBatis + JPA findById，不再假绿）" \
  || bad "n1 单服务用法未检出（尾部输出：$(printf '%s' "$out" | tail -2 | tr '\n' ' ')）"
in_dir "$W2" bash "$C/detect-n-plus-one.sh" backend
out="$(last_out)"
printf '%s\n' "$out" | grep -q "发现 2 处潜在 N+1" && ok "n1 多模块根口径检出" || bad "n1 多模块根口径未检出"

W2b="$TMP/n1-empty"; mkdir -p "$W2b/backend-empty"
in_dir "$W2b" bash "$C/detect-n-plus-one.sh" backend-empty
out="$(last_out)"
if [ "$IN_RC" -eq 1 ] && printf '%s\n' "$out" | grep -q "未发现服务目录"; then
  ok "n1 零服务目录 fail-closed"
else
  bad "n1 零服务目录未拒绝（rc=${IN_RC}）"
fi

# ---------- 3. check-arch-pitfalls CSRF ----------
W3="$TMP/csrf"
mkdir -p "$W3/backend/svc-a/src/main/java/com/x" "$W3/backend/svc-b/src/main/java/com/x"
printf 'class SecurityConfigA { void f(HttpSecurity http) { http.csrf().disable(); } }\n' \
  > "$W3/backend/svc-a/src/main/java/com/x/SecurityConfig.java"
printf 'class SecurityConfigB { void f(HttpSecurity http) { http.csrf(c -> c.ignoringRequestMatchers("/p")); } }\n' \
  > "$W3/backend/svc-b/src/main/java/com/x/SecurityConfig.java"
out="$(cd "$W3" && WORKSPACE="$W3" bash "$C/check-arch-pitfalls.sh" --category security 2>&1)"
printf '%s\n' "$out" | grep -q "CSRF 策略不一致：1 个禁用，1 个白名单" \
  && ok "csrf().disable() 被识别（旧正则永不命中）" \
  || bad "csrf 识别失败（csrf 相关输出：$(printf '%s' "$out" | grep -i csrf | tr '\n' ' ')）"

# ---------- 4. p3b 中文路径证据树 ----------
W4="$TMP/p3bz"
mkdir -p "$W4/backend/order-service/src/main/java" "$W4/docs/需求" "$W4/docs/详细设计" "$W4/docs/评审"
echo "x" > "$W4/backend/order-service/src/main/java/A.java"
cat > "$W4/docs/需求/f1-验收点.md" <<'EOF'
## 验收清单
| acceptance_id | requirement | status |
|---|---|---|
| M-01-F01-A01 | 测试 | PASS |
EOF
echo "# 设计" > "$W4/docs/详细设计/f1-详细设计.md"
cat > "$W4/docs/评审/f1-代码审查报告.md" <<'EOF'
DEVELOPER_ID=dev-agent
REVIEWER_ID=review-agent
REVIEW_SESSION_ID=rs-1
P1 问题：无
覆盖 M-01-F01-A01
EOF
# v3.30.0: p3b 需 state + code-review JSON
(cd "$W4" && bash "$S/devflow-state.sh" init f1 --frontend=not-applicable >/dev/null 2>&1)
gj_copy_sample code-review f1 "$W4"
in_dir "$W4" bash "$S/p3b_code_review_gate.sh" f1 order-service
out="$(last_out)"
if printf '%s\n' "$out" | grep -q "证据树哈希计算失败"; then
  bad "p3b 中文路径仍触发证据树 FATAL"
else
  ok "p3b 中文路径不再触发证据树 FATAL"
fi
[ -f "$W4/.devflow/f1/gates/P3b/receipt.txt" ] \
  && ok "p3b 中文路径产出收据" || bad "p3b 中文路径收据缺失"
if [ "$IN_RC" -eq 0 ]; then
  ok "p3b 中文路径整体 PASS（rc=0）"
else
  bad "p3b 中文路径 rc=${IN_RC}（P0 行：$(printf '%s' "$out" | grep -E '^\[P0\]' | tr '\n' ' ')）"
fi

# ---------- 5. p3_security_perf_gate ----------
W5="$TMP/p3cd"
mkdir -p "$W5/backend/order-service/src/main/java/com/x/dto" "$W5/backend/order-service/src/main/resources/mappers"
cat > "$W5/backend/order-service/src/main/java/com/x/dto/UserVO.java" <<'EOF'
public class UserVO { private String password; private String apiToken; private String secretKey; }
EOF
cat > "$W5/backend/order-service/src/main/resources/mappers/UserMapper.xml" <<'EOF'
<select id="byId">SELECT * FROM t_user WHERE id = ${id}</select>
EOF
in_dir "$W5" bash "$S/p3_security_perf_gate.sh" f1 --mode security
out="$(last_out)"
printf '%s\n' "$out" | grep -q "发现 1 个 DTO 含敏感字段" \
  && ok "p3cd §5 默认口径检出敏感 DTO（旧版扫空目录假绿）" || bad "p3cd §5 默认口径未检出"
printf '%s\n' "$out" | grep -qE '\[P0\].*MyBatis' \
  && ok "p3cd §4 检出 Mapper.xml 美元花括号（旧版零覆盖）" || bad "p3cd §4 未检出美元花括号"
in_dir "$W5" bash "$S/p3_security_perf_gate.sh" f1 --mode security --service=order-service
out="$(last_out)"
printf '%s\n' "$out" | grep -q "SERVICE 归一化" \
  && ok "p3cd --service= 裸服务名归一化生效" || bad "p3cd --service= 归一化未生效"

# ---------- 6. check-permission-consistency ----------
W6="$TMP/perm"
mkdir -p "$W6/docs/detailed-design" "$W6/backend/order-service/src/main/java/com/x/controller"
cat > "$W6/docs/detailed-design/_权限矩阵.md" <<'EOF'
# 权限矩阵
| 权限码 | 说明 |
|---|---|
| `order:v2:list` | 订单 v2 列表 |
EOF
cat > "$W6/backend/order-service/src/main/java/com/x/controller/OrderController.java" <<'EOF'
@RestController
public class OrderController {
    @PreAuthorize("hasAnyAuthority('order:v2:list','order:v3:view')")
    public Object list() { return null; }
}
EOF
out="$(cd "$W6" && DOC_DIR="$W6/docs/detailed-design" bash "$C/check-permission-consistency.sh" 2>&1)"
if [ "$?" -eq 0 ] && printf '%s\n' "$out" | grep -q "GATE PASS"; then
  ok "权限一致性：含数字码 + hasAnyAuthority 双侧对齐（missing=0 new=0）"
else
  bad "权限一致性误报（差异输出：$(printf '%s' "$out" | grep -E '缺|FAIL' | tr '\n' ' ')）"
fi

# ---------- 7. check-entity-db-consistency 多表回归 ----------
# v3.26.1（回归修复）: 单 SQL 文件多 CREATE TABLE 时 fields 解析缩进曾漂移到表循环外
# （每文件只记录最后一个表）；JPA @Table 支持与约束行过滤同场验证。
W7="$TMP/entity"
mkdir -p "$W7/backend/order-service/src/main/java/com/x/entity" \
         "$W7/backend/order-service/src/main/resources/db/migration/h2"
cat > "$W7/backend/order-service/src/main/java/com/x/entity/A.java" <<'EOF'
import javax.persistence.Table;
@Table(name = "t_a")
public class A { private Long id; private String name; }
EOF
cat > "$W7/backend/order-service/src/main/java/com/x/entity/B.java" <<'EOF'
import javax.persistence.Table;
@Table(name = "t_b")
public class B { private Long id; private String name; }
EOF
cat > "$W7/backend/order-service/src/main/resources/db/migration/h2/V1__init.sql" <<'EOF'
CREATE TABLE t_a (
    id BIGINT PRIMARY KEY,
    name VARCHAR(50)
);
CREATE TABLE t_b (
    id BIGINT PRIMARY KEY,
    name VARCHAR(50)
);
EOF
out="$(cd "$W7" && bash "$C/check-entity-db-consistency.sh" 2>&1)"
printf '%s\n' "$out" | grep -q "DDL 表数: 2" \
  && ok "entity/DDL 单文件多表全部抽取（旧版只留最后一个表）" \
  || bad "entity/DDL 多表抽取失败（$(printf '%s' "$out" | grep -E '表数' | tr '\n' ' ')）"
printf '%s\n' "$out" | grep -q "全部一致" \
  && ok "entity/DDL JPA @Table 对账一致 + 约束行不误报" \
  || bad "entity/DDL 对账误报（$(printf '%s' "$out" | grep -E 'WARN|不在' | tr '\n' ' ')）"

# ---------- 8. p3cd 收据 EXIT_CODE 与真实退出码一致性 ----------
# v3.26.1: 收据块内的 jq 缺失 p0 发生在旧版 EXIT_CODE 计算之后——"命令失败、收据成功"
# 矛盾。构造前置全过 + 剥离 jq 的 PATH，钉住 EXIT_CODE=1 与 rc=1 一致。
W8="$TMP/receipt"
mkdir -p "$W8/backend/order-service/src/main/java/com/x/controller" "$W8/.devflow/f1" "$W8/docs/评审"
cat > "$W8/backend/order-service/src/main/java/com/x/controller/OrderController.java" <<'EOF'
@RestController
public class OrderController {
    @PostMapping("/api/x")
    @PreAuthorize("hasAuthority('x:y:z')")
    public Object create() { return null; }
}
EOF
cat > "$W8/.devflow/f1/security.json" <<'EOF'
{
  "feature": "f1",
  "generated_at": "2026-09-17T00:00:00Z",
  "template": {"id": "安全审计-模板", "version": "1"},
  "write_operations_total": 1,
  "preauthorize_coverage": 100,
  "findings": [],
  "report_path": "docs/评审/f1-安全审计报告.md",
  "zero_results": [{"path": "findings", "reason": "fixture 无发现"}]
}
EOF
"${DEVFLOW_PY[@]}" "$ROOT/scripts/df_pipeline.py" security --input "$W8/.devflow/f1/security.json" --out "$W8/docs/评审/f1-安全审计报告.md" >/dev/null 2>&1 \
  || bad "p3cd 收据夹具渲染失败（df_pipeline security）"
NOJQ_BIN="$TMP/nojq-bin"; mkdir -p "$NOJQ_BIN"
for _t in bash sh env "${DEVFLOW_PY[@]}" find grep sed awk cat date mktemp cmp shasum sort head tail wc tr cut basename dirname mkdir cp mv rm xargs; do
  _p="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_p" "$NOJQ_BIN/$_t"
done
in_dir "$W8" env PATH="$NOJQ_BIN" bash "$S/p3_security_perf_gate.sh" f1 --mode security
out="$(last_out)"
_R="$W8/.devflow/f1/gates/P3c/receipt.txt"
if [ "$IN_RC" -eq 1 ] && grep -q "jq 不可用" "$_R" 2>/dev/null; then
  _rc_line="$(grep -m1 '^EXIT_CODE=' "$_R" 2>/dev/null)"
  if [ "$_rc_line" = "EXIT_CODE=1" ]; then
    ok "p3cd 收据 EXIT_CODE 与真实退出码一致（jq 缺失 p0 在收据块内发生，旧版收据误写 0）"
  else
    bad "p3cd 收据 EXIT_CODE 漂移（${_rc_line:-收据缺失}，期望 EXIT_CODE=1）"
  fi
else
  bad "p3cd jq 缺失场景未按预期失败（rc=${IN_RC}，收据 jq 标记：$(grep -c 'jq 不可用' "$_R" 2>/dev/null || echo no-receipt)）"
fi

# ---------- 9. 状态机输入校验边界（v3.26.2） ----------
# accuracy 必须落在 [0,100]；acceptance complete/inc 不得超过验收点总数。
W9="$TMP/state-bounds"
mkdir -p "$W9"
(
  cd "$W9" || exit 1
  bash "$S/devflow-state.sh" init st1 --frontend=not-applicable >/dev/null 2>&1
  bash "$S/devflow-state.sh" acceptance st1 set-count 5 >/dev/null 2>&1
  if bash "$S/devflow-state.sh" accuracy st1 999 >/dev/null 2>&1; then
    bad "state accuracy 999 应被拒绝（0-100 范围）"
  else
    ok "state accuracy 999 被拒绝（0-100 范围校验）"
  fi
  if bash "$S/devflow-state.sh" accuracy st1 87.5 >/dev/null 2>&1; then
    ok "state accuracy 87.5 合法写入"
  else
    bad "state accuracy 87.5 被误拒"
  fi
  if bash "$S/devflow-state.sh" acceptance st1 complete 6 >/dev/null 2>&1; then
    bad "state acceptance complete=6 应被拒绝（超过 count=5）"
  else
    ok "state acceptance complete 超上界被拒绝"
  fi
  if bash "$S/devflow-state.sh" acceptance st1 complete 5 >/dev/null 2>&1; then
    ok "state acceptance complete=5（边界值）合法"
  else
    bad "state acceptance complete=5 被误拒"
  fi
)

# ---------- 10. 模板 FEATURE 词边界替换（v3.26.2） ----------
# generate_from_template 的 s/FEATURE/x/g 曾会误伤 FEATURED 等英文词。
# 三层钉住：① 静态断言 gate 脚本已用词边界；② sed 语义行为探针；③ 真实模板生成仍工作。
# v3.29.8（Linux 实证）: [[:<:]]/[[:>:]] 是 BSD 专有——GNU sed 直接 Invalid character
# class name。断言改为可移植实现的语义探针（非词字符捕获 + 行首/行尾分支）。
grep -qF "FEATURE\([^A-Za-z0-9_]" "$ROOT/scripts/devflow-state-core.sh" \
  && ok "state-core 使用可移植词边界 FEATURE 替换" \
  || bad "state-core 词边界 FEATURE 替换实现缺失"
sed_probe="$(printf "word FEATURE here\nFEATURED stays\nFEATURE\n" | sed -e "s/FEATURE[^A-Za-z0-9_]/f1 /g" -e "s/FEATURE\$/f1/" -e "s/[^A-Za-z0-9_]FEATURE/f1/g")"
_probe_ok=1
printf "%s\n" "$sed_probe" | grep -q "word f1 here" || _probe_ok=0
printf "%s\n" "$sed_probe" | grep -q "FEATURED stays" || _probe_ok=0
printf "%s\n" "$sed_probe" | grep -q "^f1$" || _probe_ok=0
if [ "$_probe_ok" = "1" ]; then
  ok "sed 词边界语义：整词替换、FEATURED 不误伤、行尾命中（双平台可移植）"
else
  bad "sed 词边界语义失效（${sed_probe}）"
fi
W10="$TMP/tpl"
mkdir -p "$W10/docs/out"
in_dir "$W10" bash "$S/devflow-state-template.sh" generate myfeat P0 docs/out/gen.md
if [ "$IN_RC" -eq 0 ] && grep -q "myfeat" "$W10/docs/out/gen.md" 2>/dev/null; then
  ok "真实模板生成仍工作（{FeatureName} 替换为 myfeat）"
else
  bad "真实模板生成失败（rc=${IN_RC}）"
fi

# ---------- 11. 教训入检：arch-pitfalls 三查 + 令牌比较 + checkpoint 日志（v3.26.3） ----------
W11="$TMP/lessons"
mkdir -p "$W11/backend/svc/src/main/java/com/x"
cat > "$W11/backend/svc/src/main/java/com/x/OrderRepo.java" <<'EOF'
public class OrderRepo {
    void q(QueryWrapper w) { w.last("LIMIT 1"); }
}
EOF
cat > "$W11/backend/svc/src/main/java/com/x/BadTx.java" <<'EOF'
public class BadTx {
    @Transactional
    public void tx() { }
    public void caller() { tx(); }
}
EOF
out="$(cd "$W11" && WORKSPACE="$W11" bash "$C/check-arch-pitfalls.sh" --category code 2>&1)"
printf '%s\n' "$out" | grep -q "L-STACK-001" \
  && ok "教训入检：.last LIMIT 四方言破坏被拦（critical）" || bad "教训入检：L-STACK-001 未拦截"
printf '%s\n' "$out" | grep -q "L-STACK-003" \
  && ok "教训入检：@Transactional 同类自调用被拦（critical）" || bad "教训入检：L-STACK-003 未拦截"
out="$(cd "$W11" && WORKSPACE="$W11" bash "$C/check-arch-pitfalls.sh" --category security 2>&1)"
printf '%s\n' "$out" | grep -q "L-STACK-004\|令牌" \
  && ok "教训入检：security 类别可见令牌检查" || true
out="$(cd "$W11" && WORKSPACE="$W11" bash "$C/check-arch-pitfalls.sh" --category perf 2>&1)"
# JSON 拼接（warn 级，随 code 类别）
out="$(cd "$W11" && WORKSPACE="$W11" bash "$C/check-arch-pitfalls.sh" --category code 2>&1)"
printf '%s\n' "$out" | grep -q "L-P3-004" \
  && ok "教训入检：手工 JSON 拼接可检（warn）" || bad "教训入检：L-P3-004 未出现"
mkdir -p "$W11/backend/svc/src/main/java/com/x/dto"
printf 'if (token.equals(expected)) {}\n' > "$W11/backend/svc/src/main/java/com/x/TokenFilter.java"
in_dir "$W11" bash "$S/p3_security_perf_gate.sh" f1 --mode security
out="$(last_out)"
printf '%s\n' "$out" | grep -q "常量时间" \
  && ok "教训入检：p3cd §6 令牌 equals 比较可见（warn）" || bad "教训入检：p3cd 令牌比较未出现"

# checkpoint 独立日志（L-MON-002）
W11b="$TMP/cplog"
mkdir -p "$W11b"
(
  cd "$W11b" || exit 1
  bash "$S/devflow-state.sh" init cp1 --frontend=not-applicable >/dev/null 2>&1
  bash "$S/checkpoint-state.sh" save cp1 P3 "p3_mvn" 1 "blocker-x" "next-y" >/dev/null 2>&1
)
ls "$W11b/.devflow/cp1/checkpoints/"*.log >/dev/null 2>&1 \
  && ok "checkpoint 独立日志落盘（L-MON-002）" \
  || bad "checkpoint 日志未落盘"

# ---------- 12. 探针修复回归（v3.26.5） ----------
W12="$TMP/probes"; mkdir -p "$W12"
cat > "$W12/d.md" <<'EOF'
## §3 业务规则
| 编号 | 分类 | 规则描述 | 错误处理 |
|---|---|---|---|
| R6 | 删除 | 要素需先停用才可删除 | 未停用返回 ELEMENT_NOT_DISABLED |

## §5.3 接口详定义
##### 5.3.1 启停要素（停用/启用）
| Method | 路径 | 操作名 |
|---|---|---|
| PATCH | /api/elements/{type}/{id}/toggle | 启停要素（停用/启用） |
EOF
cat > "$W12/d.json" <<'EOF'
{"apis": [{"method": "PATCH", "path": "/api/elements/{type}/{id}/toggle", "name": "启停要素（停用/启用）"}]}
EOF
out="$("${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/d.md" --design-json "$W12/d.json" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] \
  && ok "rule closure 契约齐全不再误 FAIL（过度捕获收敛）" \
  || bad "rule closure 仍误报（$(printf '%s' "$out" | head -3 | tr '\n' ' ')）"
printf '%s' "$out" | grep -q "RR6" && bad "rule closure 标签双写 RR6 未修" || ok "rule closure 标签无双写"

# 负面：真缺契约仍须 FAIL（修复不得削弱检测）
printf '## §3 业务规则\n| 编号 | 分类 | 规则描述 | 错误处理 |\n|---|---|---|---|\n| R6 | 删除 | 要素需先停用才可删除 | 未停用返回 E |\n\n## §5 接口概览\n| 子域 | Method | 路径 | 操作名 | 权限 |\n|---|---|---|---|---|\n| 要素 | DELETE | /api/elements/{id} | 删除要素 | x:y:z |\n' > "$W12/d2.md"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/d2.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "rule closure 真缺契约仍 FAIL（负面可验证）" \
  || bad "rule closure 负面用例未拦截（rc=${rc}）"

# content_sufficiency: 非 strict 死状态输出不再自相矛盾
cat > "$W12/dead.md" <<'EOF'
## §2.3 状态枚举
| 字段 | 值 | 说明 |
|---|---|---|
| status | DRAFT | 草稿 |
| status | GONE | 废弃 |

## §3 规则
| R1 | DRAFT 可提交 |
EOF
out="$("${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/dead.md" 2>&1)"
if printf '%s' "$out" | grep -q "死状态" && printf '%s' "$out" | grep -q "无死状态"; then
  bad "state-matrix 非 strict 输出矛盾未修"
else
  ok "state-matrix 非 strict 输出不再自相矛盾"
fi
out="$("${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/dead.md" --strict 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "state-matrix --strict 死状态仍 P0（负面可验证）" || bad "state-matrix strict 未拦截（rc=${rc}）"

# field-drift 负面仍 FAIL
printf '# 旧\n`sequence_incr` 序列号机制与指数退避。\n' > "$W12/old.md"
printf '# 新\n无。\n' > "$W12/new.md"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" field-drift --design "$W12/new.md" --legacy "$W12/old.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] && ok "field-drift 负面仍可触发（修复未削弱检测）" || bad "field-drift 检测被削弱"

# 边界：需要X才可执行（拆分顺序含"需要"，不得产出 junk「要二次鉴权」）
printf '## §3 业务规则\n| 编号 | 分类 | 规则描述 | 错误处理 |\n|---|---|---|---|\n| R9 | 导出 | 需要二次鉴权才可执行 | 未二次鉴权返回 E |\n' > "$W12/d3.md"
printf '{"apis":[{"method":"POST","path":"/api/export/challenge","name":"二次鉴权"}]}' > "$W12/d3.json"
out="$("${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/d3.md" --design-json "$W12/d3.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "要二次鉴权"; then
  ok "rule closure 需要X句式收敛（伪造操作不产出）"
else
  bad "rule closure 需要X句式仍过度捕获（rc=${rc}: $(printf '%s' "$out" | head -2 | tr '\n' ' ')）"
fi

# 健壮性：valid_combos 含不可哈希值 → 降级 WARN 而非 traceback 崩溃
printf '## §2.3 状态枚举\n| 字段 | 值 | 说明 |\n|---|---|---|\n| status | A | a |\n| status | B | b |\n| type | X | x |\n| type | Y | y |\n\n## §3 规则\n| R1 | A 可提交 |\n\n## §4 转移\nA 到 B；X 到 Y。\n' > "$W12/combo.md"
printf '{"state_machines": {"fields": ["status", "type"], "valid_combos": [{"status": ["A", "B"], "type": "X"}]}}' > "$W12/combo.json"
out="$("${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/combo.md" --design-json "$W12/combo.json" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "Traceback"; then
  ok "state-matrix 组合结构不可解析时降级 WARN（无崩溃）"
else
  bad "state-matrix 组合结构崩溃未修（rc=${rc}）"
fi

# 反例：业务对象绑定（v3.26.7）——"要素需先停用"不得被"停用字典"满足
printf '## §3 业务规则\n| 编号 | 分类 | 规则描述 | 错误处理 |\n|---|---|---|---|\n| R6 | 删除 | 要素需先停用才可删除 | 未停用返回 E |\n' > "$W12/obj.md"
printf '{"apis":[{"method":"PATCH","path":"/api/dict/toggle","name":"停用字典"}]}' > "$W12/obj.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/obj.md" --design-json "$W12/obj.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "rule closure 无关同动词端点不满足（业务对象绑定）" \
  || bad "rule closure 未绑定业务对象（停用字典被误认可达，rc=${rc}）"

# 反例：组合矩阵枚举数（v3.26.7）——常规三列表两个状态、仅一个合法组合必须 FAIL
printf '## §2.3 状态枚举\n| 字段 | 值 | 说明 |\n|---|---|---|\n| status | DRAFT | 草稿 |\n| status | PUBLISHED | 已发布 |\n\n## §3 规则\n| R1 | DRAFT 可提交 |\n\n## §4 转移\nDRAFT 到 PUBLISHED。\n' > "$W12/enum.md"
printf '{"state_machines": {"fields": ["status"], "valid_combos": [{"status": "DRAFT"}]}}' > "$W12/enum-bad.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/enum.md" --design-json "$W12/enum-bad.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "state-matrix 三列表枚举数提取正确（1 < 2 必 FAIL）" \
  || bad "state-matrix 枚举数仍错（rc=${rc}）"
printf '{"state_machines": {"fields": ["status"], "valid_combos": [{"status": "DRAFT"}, {"status": "PUBLISHED"}]}}' > "$W12/enum-ok.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/enum.md" --design-json "$W12/enum-ok.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "state-matrix 组合齐全（2/2）正常通过" || bad "state-matrix 组合齐全被误拒（rc=${rc}）"

# 反例：状态条件隔断下的对象继承（v3.26.8）——"要素在草稿状态时需先停用"的主语
# 须传到错误码分支"未停用返回"，"停用字典"不得满足
printf '## §3 业务规则\n| 编号 | 分类 | 规则描述 | 错误处理 |\n|---|---|---|---|\n| R6 | 删除 | 要素在草稿状态时需先停用才可删除 | 未停用返回 ELEMENT_NOT_DISABLED |\n' > "$W12/cond.md"
printf '{"apis":[{"method":"PATCH","path":"/api/dict/toggle","name":"停用字典"}]}' > "$W12/cond-bad.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/cond.md" --design-json "$W12/cond-bad.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "rule closure 状态条件隔断下对象继承（停用字典不满足）" \
  || bad "rule closure 条件隔断下对象丢失（rc=${rc}）"
printf '{"apis":[{"method":"PATCH","path":"/api/elements/toggle","name":"启停要素（停用/启用）"}]}' > "$W12/cond-ok.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/cond.md" --design-json "$W12/cond-ok.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "rule closure 同对象端点仍通过（条件句正向）" || bad "rule closure 条件句误拒（rc=${rc}）"

# 反例：组合合法性（v3.26.8）——{DRAFT, UNKNOWN} 数量相同但取值非法必须 FAIL
printf '{"state_machines": {"fields": ["status"], "valid_combos": [{"status": "DRAFT"}, {"status": "UNKNOWN"}]}}' > "$W12/enum-illegal.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/enum.md" --design-json "$W12/enum-illegal.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "state-matrix 非法组合（取值不在枚举域）必 FAIL" \
  || bad "state-matrix 非法组合同数量放行（rc=${rc}）"

# 反例：自然句式"X未Y时拒绝"（v3.26.9）——对象前缀不再令模式 2 整体漏抽
printf '## §3 业务规则\n| 编号 | 分类 | 规则描述 | 错误处理 |\n|---|---|---|---|\n| R6 | 删除 | 要素未停用时拒绝删除 | 无 |\n' > "$W12/nat.md"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/nat.md" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "rule closure 未X时拒绝句式提取（无端点必 FAIL）" \
  || bad "rule closure 自然句式仍漏抽（rc=${rc}）"
printf '{"apis":[{"method":"PATCH","path":"/api/elements/toggle","name":"启停要素（停用/启用）"}]}' > "$W12/nat-ok.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/rule_operation_closure.py" --design "$W12/nat.md" --design-json "$W12/nat-ok.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "rule closure 自然句式正向通过" || bad "rule closure 自然句式误拒（rc=${rc}）"

# 反例：组合混入未声明字段（v3.26.9）——scope=ANY 不得因无枚举域被静默放行
printf '{"state_machines": {"fields": ["status"], "valid_combos": [{"status": "DRAFT"}, {"status": "PUBLISHED", "scope": "ANY"}]}}' > "$W12/enum-scope.json"
"${DEVFLOW_PY[@]}" "$ROOT/scripts/content_sufficiency_probes.py" state-matrix --design "$W12/enum.md" --design-json "$W12/enum-scope.json" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 1 ] \
  && ok "state-matrix 未声明字段必 FAIL" \
  || bad "state-matrix 未声明字段被放行（rc=${rc}）"

# ---------- 13. Runtime Profile 能力门禁 + keypair 工具（v3.27.1） ----------
W13="$TMP/prof"; mkdir -p "$W13"
( cd "$W13" && bash "$S/devflow-state.sh" init g1 --frontend=not-applicable --profile=generic >/dev/null 2>&1 )
jq -r '.scope.profile_id' "$W13/.devflow/g1.state.json" 2>/dev/null | grep -q generic \
  && ok "init --profile=generic 冻结到 state" || bad "init --profile 未冻结"
in_dir "$W13" bash "$S/build-watchdog.sh" gate g1
rc=$IN_RC
if [ "$rc" -ne 0 ] && grep -q "MISSING_CAPABILITY" "$W13/.devflow/g1/gates/P3-build/receipt.txt" 2>/dev/null; then
  ok "build-watchdog generic BLOCKED（收据 EXIT_CODE=1 + MISSING_CAPABILITY）"
else
  bad "build-watchdog generic 未 BLOCKED（rc=${rc}）"
fi
in_dir "$W13" bash "$S/p3_completion_gate.sh" g1 g1
out="$(last_out)"
IN_RC=$IN_RC
printf '%s' "$out" | grep -q "MISSING_CAPABILITY" \
  && ok "p3_completion generic BLOCKED（早期清晰反馈）" \
  || bad "p3_completion generic 未 BLOCKED"
( cd "$W13" && bash "$S/devflow-state.sh" init j1 --frontend=not-applicable --profile=java-spring-flyway >/dev/null 2>&1 )
in_dir "$W13" bash "$S/build-watchdog.sh" gate j1
rc=$IN_RC
if [ "$rc" -eq 0 ] && grep -q "^EXIT_CODE=0$" "$W13/.devflow/j1/gates/P3-build/receipt.txt" 2>/dev/null; then
  ok "java-spring-flyway 正常通过（无栈目录时全跳过）"
else
  bad "java-spring-flyway 正向被误拦（rc=${rc}）"
fi
bash "$S/devflow-state.sh" init p9 --frontend=not-applicable --profile=nope >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "未知 profile 拒绝（fail-closed）" || bad "未知 profile 被接受"

# keypair 工具
in_dir "$TMP" bash "$S/gen-review-keypair.sh" "$TMP/keys"
rc=$IN_RC
if [ "$rc" -eq 0 ] && [ -f "$TMP/keys/attest-private.pem" ] && [ -f "$TMP/keys/attest-public.pem" ]; then
  ok "gen-review-keypair 生成 RSA 密钥对"
else
  bad "gen-review-keypair 失败（rc=${rc}）"
fi
in_dir "$TMP" bash "$S/gen-review-keypair.sh" "$TMP/keys"
rc=$IN_RC
[ "$rc" -ne 0 ] && ok "keypair 重复生成拒绝（防误覆盖）" || bad "keypair 已存在未拒绝"

# p5 中文验收点路径（发现 3——旧版纯英文硬编码到 P5 必失败）
W13b="$TMP/p5zh"; mkdir -p "$W13b/docs/需求" "$W13b/docs/测试用例"
printf '## 验收点\n| M-01-F01-A01 | 登录 |\n' > "$W13b/docs/需求/p5z-验收点.md"
printf '## 用例\n| TC-1 | M-01-F01-A01 | 登录 | x | y | z | 边界:空 |\n' > "$W13b/docs/测试用例/p5z-测试用例.md"
in_dir "$W13b" bash "$S/p5_test_cases_gate.sh" p5z >/dev/null 2>&1
out="$(last_out)"
printf '%s' "$out" | grep -q "验收点全覆盖" \
  && ok "p5 中文命名验收点可解析（旧版只认英文路径）" \
  || bad "p5 中文验收点解析失败（$(printf '%s' "$out" | grep -E '验收点' | head -1)）"

finish "test-dev-hardening"
