#!/usr/bin/env bash
# test-dev-hardening.sh · v3.26.0 开发面硬化回归
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
# v3.26.0（回归修复）: 单 SQL 文件多 CREATE TABLE 时 fields 解析缩进曾漂移到表循环外
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
# v3.26.0: 收据块内的 jq 缺失 p0 发生在旧版 EXIT_CODE 计算之后——"命令失败、收据成功"
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
python3 "$ROOT/scripts/df_pipeline.py" security --input "$W8/.devflow/f1/security.json" --out "$W8/docs/评审/f1-安全审计报告.md" >/dev/null 2>&1 \
  || bad "p3cd 收据夹具渲染失败（df_pipeline security）"
NOJQ_BIN="$TMP/nojq-bin"; mkdir -p "$NOJQ_BIN"
for _t in bash sh env python3 find grep sed awk cat date mktemp cmp shasum sort head tail wc tr cut basename dirname mkdir cp mv rm xargs; do
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

finish "test-dev-hardening"
