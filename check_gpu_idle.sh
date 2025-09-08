#!/usr/bin/env bash
# check_gpu_idle.sh
# 用法:
#   ./check_gpu_idle.sh [GPU_ID] [--dry-run]
# 说明:
#   - 检查指定 GPU 上的进程（尽量覆盖 Compute + Graphics）
#   - 排除 Xorg/Xwayland
#   - 默认发现其它进程则 kill -9；加 --dry-run 时只打印不杀

set -euo pipefail

GPU_ID="${1:-0}"
DRY_RUN="${2:-}"

is_dry_run() {
  [[ "$DRY_RUN" == "--dry-run" ]]
}

# 判断是否是 Xorg/Xwayland
is_xorg_like() {
  local exe="$1"
  local base
  base="$(basename "$exe" 2>/dev/null || echo "")"
  case "$exe" in
    */usr/lib/xorg/Xorg) return 0 ;;
  esac
  [[ "$base" == "Xorg" || "$base" == "Xwayland" ]]
}

# 结构化：只列计算进程
collect_pids_compute() {
  nvidia-smi --id="$GPU_ID" \
    --query-compute-apps=pid,process_name,used_memory \
    --format=csv,noheader 2>/dev/null \
    | awk -F',' '{gsub(/^ +| +$/,"",$1); if ($1 ~ /^[0-9]+$/) print $1}' \
    | sort -u
}

# pmon：可看见图形进程
collect_pids_pmon() {
  nvidia-smi pmon -c 1 -i "$GPU_ID" 2>/dev/null \
    | awk '
      $1 ~ /^#/ { next }        # 跳过表头
      NF < 3 { next }
      $2 ~ /^-$/ { next }       # pid 为 "-" 跳过
      $2 ~ /^[0-9]+$/ { print $2 }
    ' | sort -u
}

# 兜底：解析 ASCII Processes 表（修复了分隔线/表头误判）
collect_pids_processes_ascii() {
  nvidia-smi -i "$GPU_ID" 2>/dev/null \
    | awk '/Processes:/,0 {print}' \
    | sed -n '3,$p' \
    | awk '
      # 丢弃分隔线/表头/空行
      function is_sep(line) {
        gsub(/[[:space:]]/, "", line)
        return (line ~ /^\|[-=]+\|$/) || (line ~ /^[|+\-=]+$/)
      }
      {
        raw=$0
        if (raw ~ /^$/) next
        if (raw ~ /Processes:/) next
        if (is_sep(raw)) next
        if (raw ~ /\bPID\b/ && raw ~ /\bType\b/) next

        # 典型数据行：| 0 N/A N/A 12345 C python ... 1023MiB |
        n=split(raw, a, /[[:space:]]+/)
        for (i=1; i<=n; i++) {
          if (a[i] ~ /^[0-9]+$/) {
            pid=a[i]
            if (pid+0 >= 100) { print pid; break }
          }
        }
      }' | sort -u
}

# 过滤 Xorg/Xwayland，并执行 kill 或 dry-run
filter_and_act() {
  local pids=("$@")
  local to_handle=()

  for pid in "${pids[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    local exe
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    [[ -z "$exe" ]] && exe="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
    if is_xorg_like "${exe:-}"; then
      continue
    fi
    to_handle+=("$pid")
  done

  if ((${#to_handle[@]}==0)); then
    echo "✅ GPU ${GPU_ID} 空闲或仅有 Xorg/Xwayland"
    return 0
  fi

  echo "⚠️ GPU ${GPU_ID} 上检测到其他进程："
  for pid in "${to_handle[@]}"; do
    local cmd exe
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]\+$//')"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || echo "$cmd")"
    echo "   PID $pid  CMD: ${exe}"
  done

  if is_dry_run; then
    echo "ℹ️ dry-run 模式：不执行 kill。"
    return 0
  fi

  for pid in "${to_handle[@]}"; do
    echo "   -> kill -9 $pid"
    kill -9 "$pid" || true
  done
  echo "✅ GPU ${GPU_ID} 已清理"
}

main() {
  mapfile -t p1 < <(collect_pids_compute || true)
  mapfile -t p2 < <(collect_pids_pmon || true)
  mapfile -t p3 < <(collect_pids_processes_ascii || true)

  # 合并去重
  mapfile -t all < <(printf "%s\n" "${p1[@]}" "${p2[@]}" "${p3[@]}" \
    | grep -E '^[0-9]+$' | sort -u)

  filter_and_act "${all[@]}"
}

main
