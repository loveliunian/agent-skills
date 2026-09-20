#!/usr/bin/env bash
# artifact_gate.sh · 版本随 SKILL.md
# 用途：P0b / P7 / P8 / P9 四个"无独立 gate 脚本"阶段的产物检查。
# 背景： 重写 execute_gate 时，无脚本阶段只 echo 一句就 return 0——
#      P7/P8/P9（部署/监控/文档）在主循环里必然自动放行，恰是 4 项目实验中
#      3 个跳过的阶段（"孤儿脚本"问题的镜像：有脚本没人调 → 没脚本的自动过）。
# 用法：artifact_gate.sh <P0b|P7|P8|P9> <feature>
set -uo pipefail

PHASE="${1:-}"
FEATURE="${2:-}"
if [ -z "$PHASE" ] || [ -z "$FEATURE" ]; then
  echo "Usage: artifact_gate.sh <P0b|P7|P8|P9> <feature>"
  echo "  P0b: docs/需求/<f>-PRD评审.md（评审报告，遗留问题=0，DF/AW 深度契约 v3.14.0；兼容英文历史路径）"
  echo "  P7 : docs/发布/<f>-部署记录.md（部署记录，含日期；兼容英文历史路径）"
  echo "  P8 : docs/发布/<f>-监控配置.md（监控配置，含监控三件套要素；兼容英文历史路径）"
  echo "  P9 : docs/ 下 ≥5 份用户/开发文档（排除流程产物目录）"
  exit 2
fi
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
devflow_feature_validate "$FEATURE" || exit 2

FAIL=0; PASS=0; WARN=0
EVIDENCE_PATH=""
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
p0()   { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

verify_client_release() {
  local state_file="${STATE_DIR:-.devflow}/${FEATURE}.state.json"
  [ -f "$state_file" ] || return 0
  command -v jq >/dev/null 2>&1 || { p0 "jq required for client release verification"; return; }
  local platform client_dir frozen_hash
  platform=$(jq -r '.scope.frontend // "pc-web"' "$state_file")
  client_dir=$(jq -r '.scope.frontend_dir // empty' "$state_file")
  frozen_hash=$(jq -r '.scope.client_manifest_sha256 // empty' "$state_file")
  case "$platform" in
    pc-web|mini-program|app)
      if [ -z "$frozen_hash" ] || [ "$frozen_hash" = "null" ]; then
        p0 "client manifest is not frozen; run devflow-state.sh client-freeze $FEATURE after P2"
      elif bash "$(cd "$(dirname "$0")" && pwd)/client-adapter.sh" release "$platform" "$client_dir" --strict --expected-manifest-sha "$frozen_hash"; then
        pass "$platform release command"
      else
        p0 "$platform release command failed"
      fi
      ;;
    not-applicable) pass "client release not applicable" ;;
    *) p0 "invalid client platform: $platform" ;;
  esac
}

case "$PHASE" in
  P0b)
    echo "=== P0b PRD 评审产物 Gate ==="
    # v3.22.0: 中文优先、英文回退
    R="$(df_resolve_doc "$FEATURE" prd_review .md requirements)"
    [ -n "$R" ] || R="docs/需求/${FEATURE}-PRD评审.md"
    EVIDENCE_PATH="$R"
    # v3.14.1: 领域专项清单（PRD 阶段）——平台非 not-applicable 或存在对接信号时强制
    DC="$(df_resolve_doc "$FEATURE" prd_domain_checklist .md requirements)"
    [ -n "$DC" ] || DC="docs/需求/${FEATURE}-PRD领域清单.md"
    DC_PLATFORM="pc-web"; DC_DEP=0
    DC_STATE="${STATE_DIR:-.devflow}/${FEATURE}.state.json"
    if [ -f "$DC_STATE" ] && command -v jq >/dev/null 2>&1; then
      DC_PLATFORM=$(jq -r '.scope.frontend // "pc-web"' "$DC_STATE" 2>/dev/null)
    fi
    P0B_SCAN_DIRS=()
    for _d in "docs/需求" "docs/requirements" "docs/详细设计" "docs/detailed-design"; do [ -d "$_d" ] && P0B_SCAN_DIRS+=("$_d/${FEATURE}"*.md); done
    for dc_f in "${P0B_SCAN_DIRS[@]}"; do
      [ -f "$dc_f" ] || continue
      if grep -qE '(外部系统|第三方|对接|接口文档|数据源|依赖).{0,48}(系统|平台|接口|API|数据)|API 文档' "$dc_f" 2>/dev/null; then DC_DEP=1; break; fi
    done
    if [ ! "$DC_PLATFORM" = "not-applicable" ] || [ "$DC_DEP" = "1" ]; then
      if [ ! -f "$DC" ]; then
        p0 "missing domain checklist: ${DC}（运行 gen-domain-checklist.sh ${FEATURE} --stage prd）"
      else
        DC_OPEN=$(awk '/^- \[ \]/{o++} END{print o+0}' "$DC")
        DC_DONE=$(awk '/^- \[[xX]\]/{d++} END{print d+0}' "$DC")
        # v3.14.3: 用 index() 字节子串判定——LC_ALL=C 下多字节否定字符类不可靠
        DC_BADFMT=$(awk '/^- \[[xX]\]/{{ ev=index($0,"（证据：")
      if (ev>0) { tail=substr($0,ev+15); gsub(/[[:space:]）]/,"",tail); if (length(tail)>0) e++; else b++ }
      else if (index($0,"N-A")>0) { na=substr($0,index($0,"N-A")+3); gsub(/[[:space:]）、，。]/,"",na); if (length(na)>=2) e++; else b++ }
      else b++ }} END{print b+0}' "$DC")
        DC_DONE=$(grep -ciE '^- \[x\]' "$DC" 2>/dev/null || true)
        if [ "${DC_OPEN:-0}" -gt 0 ]; then p0 "domain checklist open items: $DC_OPEN"
        elif [ "${DC_DONE:-0}" -lt 1 ]; then p0 "domain checklist empty/unanswered"
        elif [ "${DC_BADFMT:-0}" -gt 0 ]; then p0 "domain checklist ${DC_BADFMT} items checked without evidence/N-A"
        else pass "domain checklist answered with evidence"; fi
      fi
    fi
    if [ ! -f "$R" ]; then
      p0 "missing: $R"
    else
      pass "prd-review.md exists"
      LINES=$(wc -l < "$R" | tr -d ' ')
      if [ "$LINES" -ge 10 ]; then pass "report substance: ${LINES} lines"; else p0 "report too short: ${LINES} lines (< 10)"; fi
      # 遗留问题 = 0：出现"待澄清/未决/遗留："且非"无/0"则算未闭环
      OPEN=$(grep -E "待澄清|未决|遗留[:：]" "$R" 2>/dev/null | grep -cvE "无|0|无。|—|-$" || true)
      if [ "${OPEN:-0}" -eq 0 ]; then pass "no open issues declared"; else p0 "open issues found: ${OPEN} 行（遗留问题必须=0）"; fi

      # ---------- v3.14.0 评审深度契约（规范见 concepts/review-depth-methodology.md） ----------
      # v3.24.0(A14)：与共用深度方法论统一——DF 按实际发现，允许 ZERO-DF；
      # 不再默认要求 DF 总数 ≥5 / 每角色 ≥1（凑数反模式）。每角色必须有 DF 或
      # 含核查实质的 ZERO-DF 证据；AW 下限保留。
      AW_MIN="${DEEP_AW_MIN:-2}"

      STRIP=$(mktemp -t p0b-depth.XXXXXX)
      awk '/^```/{infence=!infence; next} !infence' "$R" > "$STRIP"

      echo "--- 深度契约：DF 深层发现 ---"
      DF_TOTAL=$(grep -cE '^#### DF-[0-9]+' "$STRIP" || true)
      pass "DF deep findings counted by actual findings (actual: $DF_TOTAL)"

      DF_BAD=$(LC_ALL=C awk 'BEGIN{bad=0}
        # locale-proof 空字段判定：剥标签与 ASCII 杂质后，剩余仅为全角冒号(\357\274\232)或全角空格(\343\200\200)视为空
        function blank_tail(r) {
          gsub(/[- \t:]/, "", r)
          return (r == "" || r == "\357\274\232" || r == "\343\200\200" || r == "\357\274\232\343\200\200" || r == "\343\200\200\357\274\232")
        }
        /^#### DF-[0-9]+/ {
          if (inblock && (fsce || fimp || fsug || fver || floc)) { bad++ }
          inblock=1; fsce=1; fimp=1; fsug=1; fver=1; floc=1; next
        }
        /^#### / && inblock { if (fsce || fimp || fsug || fver || floc) { bad++ }; inblock=0; next }
        inblock {
          if ($0 ~ /^- 触发场景/) { r=$0; sub(/^- 触发场景/, "", r); if (!blank_tail(r)) fsce=0 }
          else if ($0 ~ /^- 影响链/) { r=$0; sub(/^- 影响链/, "", r); if (!blank_tail(r)) fimp=0 }
          else if ($0 ~ /^- 完善建议/) { r=$0; sub(/^- 完善建议/, "", r); if (!blank_tail(r)) fsug=0 }
          else if ($0 ~ /^- 验证方式/) { r=$0; sub(/^- 验证方式/, "", r); if (!blank_tail(r)) fver=0 }
          else if ($0 ~ /^- 文档位置/) {
            r=$0; sub(/^- 文档位置/, "", r)
            gsub(/[- \t:]/, "", r)
            gsub(/\302\247/, "", r)
            gsub(/\357\274\232/, "", r)
            if (r ~ /^[0-9]+(\.[0-9]+)*$/) floc=0
          }
        }
        END { if (inblock && (fsce || fimp || fsug || fver || floc)) { bad++ }; print bad }
      ' "$STRIP")
      if [ "$DF_BAD" -eq 0 ]; then
        pass "all DF blocks complete (五字段非空、位置 §x.y)"
      else
        p0 "incomplete DF blocks: $DF_BAD — 五字段缺一判无效"
      fi

      echo "--- 深度契约：各角色 DF 或 ZERO-DF 证据（v3.24.0 按实际发现） ---"
      ROLE_LINES=$(grep -E '^- 归属评委' "$STRIP" | sed -E 's/^- 归属评委//' || true)
      for role_entry in "业务|产品:业务专家" "技术|后端|研发:技术负责人" "前端|交互|UX|UI:前端交互" "测试|QA:测试开发" "安全|合规:安全合规"; do
        role_pat="${role_entry%%:*}"
        role_label="${role_entry#*:}"
        role_cnt=$(printf '%s\n' "$ROLE_LINES" | grep -cE "$role_pat" || true)
        zero_cnt=$(grep -cE "^#### ZERO-DF.*${role_label}" "$STRIP" || true)
        if [ "$role_cnt" -ge 1 ] || [ "$zero_cnt" -ge 1 ]; then
          pass "review evidence by ${role_label}: DF=$role_cnt ZERO-DF=$zero_cnt"
        else
          p0 "DF/ZERO-DF evidence by ${role_label}: 0 — 该角色评审深度不足或未参与（按实际发现，零发现须附 ZERO-DF 核查记录）"
        fi
        if [ "$role_cnt" -eq 0 ] && [ "$zero_cnt" -gt 0 ]; then
          zero_hollow=$(LC_ALL=C awk -v role="$role_label" '
            function blank(r){ gsub(/[[:space:]:：、，。-]/,"",r); return (r=="") }
            BEGIN{inblk=0; bad=0; fields=0; lines=0}
            /^#### ZERO-DF/ && $0 ~ role {inblk=1; fields=0; lines=0; next}
            /^#### / && inblk { if (fields<2 && lines<3) bad++; inblk=0; next }
            inblk { if (!blank($0)) { lines++; if ($0 ~ /核查范围|核查清单|证据|验证方式|已核查|核对/) fields++ } }
            END{ if (inblk && fields<2 && lines<3) bad++; print bad }
          ' "$STRIP")
          [ "$zero_hollow" -eq 0 ] || p0 "${role_label} 的 ZERO-DF 块缺核查实质（${zero_hollow} 个空块）——零发现必须附核查范围、证据锚点与验证方式"
        fi
      done

      echo "--- 深度契约：AW 对抗场景走查 ---"
      AW_COUNT=$(grep -cE '(^|[^A-Za-z])AW-[0-9]+' "$STRIP" || true)
      if [ "$AW_COUNT" -ge "$AW_MIN" ]; then
        pass "adversarial walkthroughs >= ${AW_MIN} (actual: $AW_COUNT)"
      else
        p0 "adversarial walkthroughs < ${AW_MIN} (actual: $AW_COUNT) — 端到端走查是 PRD 评审最有效的深挖探针"
      fi
      AW_BAD=$(LC_ALL=C awk 'BEGIN{bad=0}
        /(^|[^A-Za-z])AW-[0-9]+/ {
          if ($0 !~ /结果/) { bad++; next }
          if ($0 ~ /\{/) { bad++; next }
          if ($0 !~ /DF-[0-9]/ && $0 !~ /[0-9]\.[0-9]/) { bad++ }
        }
        END { print bad }
      ' "$STRIP")
      if [ "$AW_BAD" -eq 0 ]; then
        pass "every AW ends with a valid 结果"
      else
        p0 "AW entries missing valid 结果: $AW_BAD — 每条走查必须以 发现 DF-xx 或 §锚点证据 收尾"
      fi

      echo "--- 深度契约：PRD 专属章节 ---"
      if grep -q '探针执行记录' "$R"; then
        pass "probe execution record section present"
      else
        p0 "missing 探针执行记录 — P1/P2/P4/P5 四类探针未留痕不得下结论"
      fi

      if grep -qE '无歧义术语' "$R"; then
        pass "ambiguity explicitly declared absent"
      elif grep -q '歧义术语' "$R"; then
        UNRESOLVED=$(awk '/歧义术语/{intab=1} intab && /^\| *[0-9]/ && ($0 ~ /⏳|未决议|待定/) {c++} END{print c+0}' "$R")
        RESOLVED=$(awk '/歧义术语/{intab=1} intab && /^\| *[0-9]/ && ($0 ~ /已决议|✅/) {c++} END{print c+0}' "$R")
        if [ "${UNRESOLVED:-0}" -eq 0 ] && [ "${RESOLVED:-0}" -ge 1 ]; then
          pass "ambiguity resolution table complete ($RESOLVED resolved)"
        else
          p0 "ambiguity table incomplete: resolved=$RESOLVED unresolved=$UNRESOLVED — 歧义术语必须逐条决议"
        fi
      else
        p0 "missing 歧义术语决议表（或显式声明\"无歧义术语\"）"
      fi

      # ---------- v3.21.0: 权限码三方对账（L-P0-001 机检前移至 P0b；与 s0 §7 同库同口径） ----------
      # 双格式归一（perm: 前缀 + 反引号三段式）、缺矩阵 P0（声明式豁免）、seed ⊆ matrix。
      # `|| true`：p0() 计数已入 FAIL，返回码仅防 set -e 误传播。
      if source "$(cd "$(dirname "$0")" && pwd)/perm_reconcile_lib.sh"; then
        # v3.22.0: 事实源/澄清文档路径中英双语
        AG_MATRIX="docs/详细设计/_权限矩阵.md"; [ -f "$AG_MATRIX" ] || AG_MATRIX="docs/detailed-design/_权限矩阵.md"
        AG_MENU="docs/详细设计/_菜单Seed索引.md"; [ -f "$AG_MENU" ] || AG_MENU="docs/detailed-design/_菜单Seed索引.md"
        AG_CLAR="$(df_resolve_doc "$FEATURE" clarification .md requirements)"
        [ -n "$AG_CLAR" ] || AG_CLAR="docs/需求/${FEATURE}-需求澄清.md"
        perm_reconcile_three_way "$AG_MATRIX" "$AG_CLAR" "$AG_MENU" || true
      fi

      if grep -q '边界条件枚举' "$R"; then
        pass "boundary enumeration section present"
      else
        p0 "missing 边界条件枚举 — P2 边界探针未留痕"
      fi

      SHALLOW=$(grep -niE '已阅|LGTM|无明显问题|整体没问题|没有发现问题' "$R" || true)
      if [ -z "$SHALLOW" ]; then
        pass "no shallow sign-off phrases"
      else
        p0 "shallow sign-off phrases found — 零发现结论必须附已核查清单+§锚点证据"
      fi
      rm -f "$STRIP"
    fi
    ;;
  P7)
    echo "=== P7 部署记录产物 Gate ==="
    # v3.22.0: 部署记录中文优先、英文回退
    R="$(df_resolve_doc "$FEATURE" deploy_record .md deploy)"
    [ -n "$R" ] || R="docs/发布/${FEATURE}-部署记录.md"
    EVIDENCE_PATH="$R"
    STATE_FILE="${STATE_DIR:-.devflow}/${FEATURE}.state.json"
    if [ ! -f "$R" ]; then
      p0 "missing: $R"
    elif [ ! -f "$STATE_FILE" ]; then
      p0 "missing frozen workflow state: $STATE_FILE"
    else
      pass "deploy-record.md exists"
      grep -qE '^DEPLOYMENT_ID=.+$' "$R" && pass "deployment id declared" || p0 "missing DEPLOYMENT_ID"
      artifact_path=$(sed -n 's/^ARTIFACT_PATH=//p' "$R" | head -1)
      artifact_sha=$(sed -n 's/^ARTIFACT_SHA256=//p' "$R" | head -1)
      if [ -n "$artifact_path" ] && [ -f "$artifact_path" ] && printf '%s' "$artifact_sha" | grep -qE '^[0-9a-fA-F]{64}$'; then
        actual_sha=$(hash_file "$artifact_path")
        [ "$actual_sha" = "$artifact_sha" ] && pass "artifact exists and sha256 matches" || p0 "artifact SHA-256 mismatch: $artifact_path"
      else
        p0 "missing artifact path or artifact SHA-256"
      fi
      grep -qE '^ENVIRONMENT=.+$' "$R" && pass "environment declared" || p0 "missing ENVIRONMENT"
      # v3.26.3: L-STACK-002 入检——部署清单必须显式声明认证通道状态。生产环境
      # dev-privileged=true = 认证绕过上生产（教训中的 P1-006 事故模式）；
      # 声明缺失即 P0（fail-closed），staging 允许 true 但必须显式声明。
      ENV_VALUE=$(sed -n 's/^ENVIRONMENT=//p' "$R" | head -1)
      DEV_PRIV=$(sed -n 's/^DEV_PRIVILEGED=//p' "$R" | head -1)
      case "$DEV_PRIV" in
        false) pass "DEV_PRIVILEGED=false declared (auth enforced)" ;;
        true)
          if [ "$ENV_VALUE" = "production" ]; then
            p0 "DEV_PRIVILEGED=true 上生产 = 认证绕过（L-STACK-002）——须实现真实认证通道并置 false"
          else
            warn "DEV_PRIVILEGED=true（staging）——生产部署前必须置 false 并实现真实认证"
          fi ;;
        *) p0 "missing DEV_PRIVILEGED（部署清单必须显式声明认证通道状态，L-STACK-002）" ;;
      esac
      # v3.26.2: 健康状态改为"声明=校验基准"——部署记录声明 HEALTH_HTTP_STATUS（须为
      # 2xx），实时探测结果必须与声明一致。旧版硬编码 200（204 No Content 等合法 2xx
      # 健康端点被误判失败）；非 2xx 声明仍拒绝（健康=成功语义不变）。
      HEALTH_HTTP_STATUS=$(sed -n 's/^HEALTH_HTTP_STATUS=//p' "$R" | head -1)
      case "$HEALTH_HTTP_STATUS" in
        2[0-9][0-9]) pass "declared health status is 2xx: ${HEALTH_HTTP_STATUS}" ;;
        *) p0 "missing or invalid HEALTH_HTTP_STATUS（须为 2xx 三位数字）: ${HEALTH_HTTP_STATUS:-<empty>}" ; HEALTH_HTTP_STATUS="" ;;
      esac
      # v3.14.6: 实时健康探测——部署记录必须给出 HEALTH_URL 且当前返回 200（防只写文档不验证）
      HEALTH_URL=$(sed -n 's/^HEALTH_URL=//p' "$R" | head -1)
      # v3.14.6: SSRF 防护——拒绝 link-local / 云 metadata / 非 http(s) 目标
      case "$HEALTH_URL" in
        http://*|https://*) : ;;
        *) p0 "HEALTH_URL must be http(s): $HEALTH_URL"; HEALTH_URL="" ;;
      esac
      case "$HEALTH_URL" in
        *169.254.*|*[Ff][Ee]80:*|*metadata*)
          p0 "HEALTH_URL points to link-local/metadata range: $HEALTH_URL"; HEALTH_URL="" ;;
      esac
      if [ -z "$HEALTH_URL" ]; then
        p0 "missing HEALTH_URL（实时探测地址）"
      else
        # v3.14.11: 实时探测为强制项——运行未验证不得写成完成
        # v3.26.2: 实测状态必须等于声明的 HEALTH_HTTP_STATUS（2xx）
        LIVE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$HEALTH_URL" 2>/dev/null)
        LIVE=${LIVE:-000}
        [ "$LIVE" = "$HEALTH_HTTP_STATUS" ] \
          && pass "live HEALTH_URL returned ${LIVE} (declared): ${HEALTH_URL}" \
          || p0 "live HEALTH_URL ${HEALTH_URL} returned ${LIVE} (expected ${HEALTH_HTTP_STATUS:-declared}) — 运行未验证不得写成完成"
        # v3.15.1: BUILD_INFO_URL 强制（不再 WARN 放行）——任意静态 HTTP 200 不构成运行证据；
        # 运行实例必须回显与本制品绑定的标识（ARTIFACT_SHA256 前 12 位 hex 或 DEPLOYMENT_ID 原值），
        # 证明"正在运行的实例就是该制品"，而非任意可达服务。
        BUILD_INFO_URL=$(sed -n 's/^BUILD_INFO_URL=//p' "$R" | head -1)
        if [ -z "$BUILD_INFO_URL" ]; then
          p0 "missing BUILD_INFO_URL（运行实例须回显制品哈希/部署 ID 以绑定制品）"
        else
          case "$BUILD_INFO_URL" in
            http://*|https://*) : ;;
            *) p0 "BUILD_INFO_URL must be http(s): $BUILD_INFO_URL"; BUILD_INFO_URL="" ;;
          esac
          case "$BUILD_INFO_URL" in
            *169.254.*|*[Ff][Ee]80:*|*metadata*) p0 "BUILD_INFO_URL points to link-local/metadata range: $BUILD_INFO_URL"; BUILD_INFO_URL="" ;;
          esac
          if [ -n "$BUILD_INFO_URL" ]; then
            BI=$(curl -sS --max-time 10 "$BUILD_INFO_URL" 2>/dev/null || true)
            dep_id=$(sed -n 's/^DEPLOYMENT_ID=//p' "$R" | head -1)
            sha_prefix=$(printf '%s' "$artifact_sha" | cut -c1-12)
            if [ -z "$BI" ]; then
              p0 "BUILD_INFO_URL 不可达: $BUILD_INFO_URL"
            elif { [ -n "$sha_prefix" ] && printf '%s' "$BI" | grep -qF "$sha_prefix"; } \
              || { [ -n "$dep_id" ] && printf '%s' "$BI" | grep -qF "$dep_id"; }; then
              pass "BUILD_INFO 回显与制品绑定的标识（SHA 前缀/部署 ID 命中）"
            else
              p0 "BUILD_INFO 未回显本制品标识（无 ARTIFACT_SHA256 前缀 ${sha_prefix:-?} 亦无 DEPLOYMENT_ID ${dep_id:-?}）——无法证明运行实例即该制品"
            fi
          fi
        fi
      fi
      release_evidence_path=$(sed -n 's/^RELEASE_EVIDENCE_PATH=//p' "$R" | head -1)
      if [ -n "$release_evidence_path" ] && [ -f "$release_evidence_path" ]; then
        if [ "$release_evidence_path" = "$artifact_path" ]; then
          p0 "release evidence must be separate from the deployed artifact"
        elif [ "$(wc -c < "$release_evidence_path" | tr -d ' ')" -lt 20 ] \
          || ! grep -qE '[0-9]{2}' "$release_evidence_path"; then
          p0 "release evidence too thin (<20 bytes or no numeric token): $release_evidence_path"
        else
          pass "release evidence file exists and is separate from artifact"
        fi
      else
        p0 "missing RELEASE_EVIDENCE_PATH file"
      fi
      verify_client_release
    fi
    ;;
  P8)
    echo "=== P8 监控配置产物 Gate ==="
    # v3.22.0: 监控配置中文优先、英文回退
    R="$(df_resolve_doc "$FEATURE" monitor_config .md deploy)"
    [ -n "$R" ] || R="docs/发布/${FEATURE}-监控配置.md"
    EVIDENCE_PATH="$R"
    if [ ! -f "$R" ]; then
      p0 "missing: $R"
    else
      pass "monitor-config.md exists"
      metrics_endpoint=$(sed -n 's/^METRICS_ENDPOINT=//p' "$R" | head -1)
      # v3.15.13: METRICS_ENDPOINT 与 BUILD_INFO_URL 同口径防护——协议白名单 +
      # link-local/metadata 黑名单（封堵 file:// 探测与 169.254.169.254 云元数据 SSRF）
      case "$metrics_endpoint" in
        http://*|https://*) : ;;
        *) p0 "METRICS_ENDPOINT must be http(s): ${metrics_endpoint:-<empty>}"; metrics_endpoint="" ;;
      esac
      case "$metrics_endpoint" in
        *169.254.*|*[Ff][Ee]80:*|*metadata*) p0 "METRICS_ENDPOINT points to link-local/metadata range: $metrics_endpoint"; metrics_endpoint="" ;;
      esac
      metrics_output=$(mktemp)
      if [ -n "$metrics_endpoint" ] && curl -fsS --max-time 5 "$metrics_endpoint" > "$metrics_output" 2>/dev/null && grep -qE '^# (HELP|TYPE)[[:space:]]' "$metrics_output"; then
        pass "metrics endpoint returned Prometheus content"
        # v3.15.1: 伪 Prometheus 防护——仅 HELP/TYPE 头不够，必须有真实采样行（指标名+数值）
        SAMPLES=$(grep -cE '^[a-zA-Z_:][a-zA-Z0-9_:]*(\{[^}]*\})?[[:space:]]+[-0-9]' "$metrics_output" || true)
        if [ "${SAMPLES:-0}" -ge 5 ]; then
          pass "metrics contain >=5 real sample lines (actual: $SAMPLES)"
        else
          p0 "metrics endpoint has only ${SAMPLES:-0} sample lines (<5) —— HELP/TYPE 头不构成运行证据"
        fi
      else
        p0 "metrics endpoint unavailable or not Prometheus: $metrics_endpoint"
      fi
      rm -f "$metrics_output"
      grep -qE '^LOG_QUERY=.+$' "$R" && pass "log query declared" || p0 "missing LOG_QUERY"
      # v3.15.1: LOG_QUERY 必须附真实查询证据文件（含结果、≥2 行）——任意字符串声明不算
      log_query_evidence=$(sed -n 's/^LOG_QUERY_EVIDENCE=//p' "$R" | head -1)
      if [ -n "$log_query_evidence" ] && [ -f "$log_query_evidence" ] \
        && [ "$(wc -l < "$log_query_evidence" | tr -d ' ')" -ge 2 ]; then
        pass "log query evidence file exists with results"
      else
        p0 "missing LOG_QUERY_EVIDENCE (path=${log_query_evidence:-未声明}; 须为含真实查询结果且 ≥2 行的文件)"
      fi
      # v3.15.1: ALERT_RULE 必须指向真实告警规则文件（含 alert:/expr: 定义）——任意 ID 声明不算
      alert_rule=$(sed -n 's/^ALERT_RULE=//p' "$R" | head -1)
      if [ -n "$alert_rule" ] && [ -f "$alert_rule" ] \
        && grep -qE '^[[:space:]]*-?[[:space:]]*alert:' "$alert_rule" \
        && grep -qE 'expr:' "$alert_rule"; then
        pass "alert rule file exists with alert/expr definition"
      else
        p0 "missing ALERT_RULE rule file (path=${alert_rule:-未声明}; 须为含 alert: 与 expr: 的规则文件)"
      fi
      alert_output=$(sed -n 's/^ALERT_TEST_OUTPUT=//p' "$R" | head -1)
      if grep -qx 'ALERT_TESTED=PASS' "$R" && [ -n "$alert_output" ] && [ -f "$alert_output" ]; then
        # v3.15.1: 告警实测输出必须非空（≥20B）且含 触发/通知确认/恢复记录 三要素——空白输出文件不算
        if [ "$(wc -c < "$alert_output" | tr -d ' ')" -lt 20 ]; then
          p0 "alert test output is empty/too thin (<20 bytes): $alert_output"
        else
          alerts_struct_ok=1
          for marker in ALERT_TRIGGERED NOTIFICATION_CONFIRMED RECOVERY_RECORDED; do
            marker_val=$(sed -n "s/^${marker}=//p" "$alert_output" | head -1)
            if [ -z "$marker_val" ] || printf '%s' "$marker_val" | grep -qiE '^(no|none|null|false)$'; then
              p0 "alert test output missing ${marker}=<记录>（触发/通知确认/恢复记录三要素缺一不可）"
              alerts_struct_ok=0
            fi
          done
          [ "$alerts_struct_ok" -eq 1 ] && pass "alert test output records trigger/notification/recovery"
        fi
        # v3.14.0: 文档声明与实测输出交叉核对（code02 教训：告警实测 FAIL 而文档写 PASS）
        # v3.14.11-fix(jmmp2): 否定语句（如"无 FAIL 项"）曾命中 FAIL 词边界正则被误报——先排除否定语境行
        if grep -vE "(无|没有|未|不含|0[[:space:]]*个|0[[:space:]]*项)[^。]{0,20}FAIL" "$alert_output" 2>/dev/null \
          | grep -qE '(^|[^A-Za-z])FAIL([^A-Za-z]|$)'; then
          p0 "alert test output contains FAIL but monitor-config declares ALERT_TESTED=PASS: $alert_output"
        else
          pass "alert test output exists and is consistent with ALERT_TESTED=PASS"
        fi
      else
        p0 "missing ALERT_TESTED=PASS with ALERT_TEST_OUTPUT file"
      fi
    fi
    ;;
  P9)
    echo "=== P9 文档更新产物 Gate ==="
    # v3.22.0: 文档索引中文优先、英文回退（均在 docs/ 根）
    R="docs/${FEATURE}-文档索引.md"
    [ -f "$R" ] || R="docs/${FEATURE}-docs-index.md"
    EVIDENCE_PATH="$R"
    if [ ! -f "$R" ]; then
      p0 "missing documentation index: $R"
    else
      seen_paths=""
      # v3.15.1: 五类文档语义章节关键词——"标题 + line1~4"级占位文档不再算 substantive
      doc_keywords_for() {
        case "$1" in
          USER_DOC)       echo '使用|快速开始|指南|入门|操作|FAQ' ;;
          DEVELOPER_DOC)  echo '开发|构建|环境|调试|架构|本地运行' ;;
          API_DOC)        echo '接口|API|端点|参数|请求|响应' ;;
          OPERATIONS_DOC) echo '运维|部署|监控|告警|故障|巡检' ;;
          RELEASE_NOTES)  echo '变更|版本|发布|修复|新增|已知' ;;
        esac
      }
      for key in USER_DOC DEVELOPER_DOC API_DOC OPERATIONS_DOC RELEASE_NOTES; do
        path=$(sed -n "s/^${key}=//p" "$R" | head -1)
        declared_sha=$(sed -n "s/^${key}_SHA256=//p" "$R" | head -1)
        if [ -z "$path" ]; then
          p0 "missing $key"
          continue
        fi
        if printf '%s\n' "$seen_paths" | grep -qxF "$path"; then
          p0 "$key duplicates document path: $path"
          continue
        fi
        # v3.15.1: 目标文档哈希声明 + 校验（index 须固化五份文档各自 SHA-256）
        if [ -z "$declared_sha" ] || ! printf '%s' "$declared_sha" | grep -qE '^[0-9a-f]{64}$'; then
          p0 "missing ${key}_SHA256 (64-hex) in docs index"
          continue
        fi
        if [ ! -f "$path" ]; then
          p0 "$key path missing: $path"
          continue
        fi
        actual_sha=$(hash_file "$path")
        if [ "$actual_sha" != "$declared_sha" ]; then
          p0 "$key document SHA mismatch: $path (declared=$declared_sha actual=$actual_sha)"
          continue
        fi
        doc_lines=$(wc -l < "$path" | tr -d ' ')
        doc_headings=$(grep -cE '^#{1,3} ' "$path" || true)
        doc_body=$(grep -vE '^(#{1,3} |[[:space:]]*$)' "$path" 2>/dev/null | grep -cE '[^[:space:]]' || true)
        if [ "$doc_lines" -ge 10 ] && [ "${doc_headings:-0}" -ge 2 ] && [ "${doc_body:-0}" -ge 5 ]; then
          pass "$key is a substantive document (${doc_lines} lines / ${doc_headings} headings / ${doc_body} body lines)"
        else
          p0 "$key is placeholder-level: ${doc_lines} lines / ${doc_headings} headings / ${doc_body} body lines (须 ≥10 行、≥2 标题、≥5 正文行)"
          continue
        fi
        doc_kw=$(doc_keywords_for "$key")
        if grep -qE "$doc_kw" "$path"; then
          pass "$key carries category-specific semantic section"
        else
          p0 "$key lacks semantic keywords (${doc_kw}) —— 五类文档须各含语义章节"
          continue
        fi
        pass "$key points to a distinct verified document (sha256 ok)"
        seen_paths="${seen_paths}${path}
"
      done
    fi
    ;;
  *)
    echo "Usage: artifact_gate.sh <P0b|P7|P8|P9> <feature>"
    exit 2
    ;;
esac

# ---------- v3.14.0: P7/P8/P9 收据链审计（版本混用/镜像漂移拦截） ----------
# P7 是 P0~P6 全链后的首个收尾 gate，此处全量对账最早发现同链多版本收据
# 与内部/docs 镜像内容漂移（code02/code03 教训：audit-receipts 此前为孤儿工具无人调用）。
if printf '%s' "$PHASE" | grep -qE '^P[789]$'; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
  # v3.28.1(FB-20260919-001): gate 重跑迭代先清理旧收据——若 state 已标 P<phase>=completed
  # 而收据被清理，audit-receipts 会死锁（completed 但无收据）。自动回退 in_progress 允许重跑。
  if command -v jq >/dev/null 2>&1 && [ -f "${STATE_DIR:-.devflow}/${FEATURE}.state.json" ]; then
    _p7_st=$(jq -r --arg ph "$PHASE" '.phases[$ph].status // empty' "${STATE_DIR:-.devflow}/${FEATURE}.state.json" 2>/dev/null || true)
    if [ "$_p7_st" = "completed" ] && [ ! -f "${STATE_DIR:-.devflow}/${FEATURE}/gates/${PHASE}/receipt.txt" ]; then
      jq --arg ph "$PHASE" '.phases[$ph].status = "in_progress"' "${STATE_DIR:-.devflow}/${FEATURE}.state.json" \
        > "${STATE_DIR:-.devflow}/${FEATURE}.state.json.tmp" 2>/dev/null \
        && mv "${STATE_DIR:-.devflow}/${FEATURE}.state.json.tmp" "${STATE_DIR:-.devflow}/${FEATURE}.state.json" \
        && echo "[INFO] state $PHASE=completed 但收据已被本轮清理——自动回退 in_progress 允许重跑"
    fi
  fi
  # v3.16.0: 本轮 PHASE 旧收据先清理（内部+镜像）——gate 重跑迭代证据后，上一轮
  # 收据的 EVIDENCE_SHA256 必然过时（audit 证据绑定重验会误报前置链失败）。
  # 当前 PHASE 收据由本次运行末尾重写；前置链收据不受影响。
  rm -f "${STATE_DIR:-.devflow}/${FEATURE}/gates/${PHASE}/receipt.txt" \
        "docs/${FEATURE}/gates/${PHASE}/receipt.txt" 2>/dev/null
  bash "$SCRIPT_DIR/audit-receipts.sh" "$FEATURE" "${STATE_DIR:-.devflow}" docs \
    || { echo "[P0] receipt chain audit failed (version mixing or mirror drift)"; FAIL=$((FAIL + 1)); }
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"

# ---------- 收据双写（v3.9.6：与其他 gate 对齐） ----------
STATE_DIR="${STATE_DIR:-.devflow}"
RECEIPT_DIR="$STATE_DIR/${FEATURE}/gates/${PHASE}"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
{
  echo "EXIT_CODE=$EXIT_CODE"
  echo "VERSION=artifact@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=$PHASE"
  echo "EVIDENCE_PATH=$EVIDENCE_PATH"
  if [ -n "$EVIDENCE_PATH" ] && [ -f "$EVIDENCE_PATH" ]; then echo "EVIDENCE_SHA256=$(hash_file "$EVIDENCE_PATH")"; else echo "EVIDENCE_SHA256=missing"; fi
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED: $RECEIPT_DIR/receipt.txt" >&2; exit 1; }
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${FEATURE}/gates/${PHASE}"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

[ "$FAIL" -gt 0 ] && { echo "${PHASE} ARTIFACT GATE: FAIL (blocking)"; exit 1; }
echo "${PHASE} ARTIFACT GATE: PASS"
exit 0
