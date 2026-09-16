#!/usr/bin/env bash
set -euo pipefail
# .cursor/skills/devflow/hooks/detect-platform.sh
# 用途：检测当前环境是否支持 devflow v3.6 的 Gate。
# 运行：bash hooks/detect-platform.sh

# 1. 检测 shell 类型
detect_shell() {
  local os
  os=$(uname 2>/dev/null || echo "Windows")
  case "$os" in
    Darwin*)
      echo "macOS 原生 bash/zsh"
      return 0 ;;
    Linux*)
      if grep -q Microsoft /proc/version 2>/dev/null; then
        echo "WSL (Linux 子系统)"
      else
        echo "Linux 原生"
      fi
      return 0 ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "Windows Git Bash"
      return 0 ;;
    *)
      echo "Windows 原生（非 Git Bash）"
      return 1 ;;
  esac
}

# 2. 检测 bash 版本
detect_bash_version() {
  if [ -n "$BASH_VERSION" ]; then
    echo "Bash 版本: $BASH_VERSION"
    case "${BASH_VERSINFO[0]}" in
      2) echo "[WARN] Bash 2.x 过旧"; return 1;;
      3) echo "[OK] Bash 3.2（Git Bash / macOS 默认）"; return 0;;
      4|5) echo "[OK] Bash 4+"; return 0;;
      *) echo "[?] Bash 未知版本"; return 0;;
    esac
  elif [ -n "$ZSH_VERSION" ]; then
    echo "Zsh 版本: $ZSH_VERSION"
    return 0
  else
    echo "[FAIL] 当前 shell 不是 bash/zsh，v3.6 Gate 不受支持"
    return 1
  fi
}

# 3. 检测关键命令是否可用
check_core_commands() {
  local missing=0
  for cmd in bash grep find awk sed wc mktemp xargs comm tr git jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[FAIL] 缺少命令: $cmd"
      missing=$((missing + 1))
    fi
  done
  
  # POSIX 关键选项
  echo "test" | grep -E "test" >/dev/null 2>&1 || { echo "[FAIL] grep -E 不可用"; missing=$((missing + 1)); }
  echo "test" | grep -oE "test" >/dev/null 2>&1 || { echo "[FAIL] grep -oE 不可用"; missing=$((missing + 1)); }

  if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "[FAIL] 缺少 SHA-256 工具（shasum 或 sha256sum）"
    missing=$((missing + 1))
  fi

  if ! command -v rsync >/dev/null 2>&1; then
    echo "[WARN] 缺少 rsync：普通同步可回退，--delete 精确同步不可用"
  fi
  
  if [ "$missing" -eq 0 ]; then
    echo "[OK] 核心命令全部可用"
    return 0
  fi
  return 1
}

# 4. 检测 CRLF 问题
check_crlf() {
  if [ -f "$0" ]; then
    if file "$0" 2>/dev/null | grep -q CRLF; then
      echo "[WARN] 本脚本是 CRLF 格式，bash 可能报 '\r: command not found'"
      echo "  修复: .gitattributes 加 '*.sh text eol=lf'，重新 clone"
      return 1
    fi
  fi
  return 0
}

# 5. 主函数
main() {
  echo "===== v3.6 平台检测 ====="
  echo ""
  echo "[Shell 环境]"
  detect_shell
  echo ""
  echo "[Shell 版本]"
  detect_bash_version
  echo ""
  echo "[核心命令]"
  check_core_commands
  echo ""
  echo "[CRLF 检查]"
  check_crlf
  echo ""
  echo "===== 检测完成 ====="
}

main "$@"
