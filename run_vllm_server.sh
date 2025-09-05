#!/bin/bash
# run_vllm_server.sh
# 用法:
#   ./run_vllm_server.sh <MODE> [lmcache_enabled] [LOG_DIR]
# 例子:
#   ./run_vllm_server.sh fcfs
#   ./run_vllm_server.sh sjf_prompt_tokens lmcache_enabled /path/to/run-dir

set -o errexit
set -o nounset
set -o pipefail

# 允许的调度策略
VALID_MODES=("fcfs" "sjf_prompt_tokens" "sjf_uncomputed_tokens_local" "sjf_uncomputed_tokens_global")

MODE="${1:-}"
LMFLAG="${2:-}"                    # 传入 "lmcache_enabled" 则启用 LMCache
DATE_TIME="$(date +%Y_%m_%d_%H-%M)"
MODEL_DIR="/home/yshan/Downloads/models/Qwen-1_5b"
CONFIG_FILE="/home/yshan/Programs/LMCache/lmcache_config.yaml"

# 若第 3 个参数给了目录，则把日志写到该目录；否则默认到当前目录下的 vllm_server_log
LOG_DIR="${3:-./vllm_server_log}"
LOGFILE="$LOG_DIR/run_vllm_server.log"

# 1) 校验 MODE
if [[ -z "$MODE" ]]; then
  echo "❌ Missing MODE argument."
  echo "Usage: $0 <MODE> [lmcache_enabled] [LOG_DIR]"
  echo "Available SchedulerPolicy options:"
  printf '  - %s\n' "${VALID_MODES[@]}"
  exit 1
fi
if [[ ! " ${VALID_MODES[@]} " =~ " ${MODE} " ]]; then
  echo "❌ Invalid MODE: $MODE"
  echo "Available SchedulerPolicy options:"
  printf '  - %s\n' "${VALID_MODES[@]}"
  exit 1
fi

# 2) 是否启用 LMCache（仅当第二参数为 lmcache_enabled）
LMCACHE_ENABLED=false
if [[ "$LMFLAG" == "lmcache_enabled" ]]; then
  LMCACHE_ENABLED=true
fi

mkdir -p "$LOG_DIR"

# 3) 组装命令数组（基础部分）
CMD=(
  python -m vllm.entrypoints.openai.api_server
  --model "$MODEL_DIR"
  --port 8000
  --max-model-len 30k
  --block-size 16
  --gpu_memory_utilization 0.2
  --scheduling-policy "$MODE"
  --enable-prefix-caching
  --no-enable-chunked-prefill
  --disable-log-requests
  --disable-uvicorn-access-log
)
# --uvicorn-log-level debug --disable-log-requests --disable-uvicorn-access-log


# 4) 如启用 LMCache，追加 kv-transfer-config 参数
if $LMCACHE_ENABLED; then
  CMD+=( --kv-transfer-config '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}' )
fi

# 5) 环境变量前缀（CUDA 总是设；LMCACHE_CONFIG_FILE 仅在启用时设）
ENV_PREFIX=( "CUDA_VISIBLE_DEVICES=0" )
if $LMCACHE_ENABLED; then
  ENV_PREFIX+=( "LMCACHE_CONFIG_FILE=$CONFIG_FILE" )
fi

# 6) 日志头：把命令按多行打印（和实际执行一致）
{
  echo "===== COMMAND ====="
  if $LMCACHE_ENABLED; then
    echo "CUDA_VISIBLE_DEVICES=0 LMCACHE_CONFIG_FILE=$CONFIG_FILE \\"
  else
    echo "CUDA_VISIBLE_DEVICES=0 \\"
  fi
  printf '  %s \\\n' "${CMD[@]}"
  echo
  echo "Date Time: $DATE_TIME"
  echo "SchedulerPolicy: $MODE"
  echo "LMCache Enabled: $LMCACHE_ENABLED"
  echo "===== OUTPUT ====="
} >> "$LOGFILE"

# 7) 执行命令：
# 说明：此脚本默认前台“挂起”运行（便于被外层用 & 放后台）。
# 输出既写到控制台也追加到 $LOGFILE。
env "${ENV_PREFIX[@]}" "${CMD[@]}" 2>&1 | tee -a "$LOGFILE"
