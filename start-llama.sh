#!/bin/bash

PORT=8080
PERF_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 8)
HEALTH_TIMEOUT=180  # seconds to wait for server startup

# Context size aliases
resolve_ctx() {
  case "$1" in
    8k)   echo 8192   ;;
    16k)  echo 16384  ;;
    32k)  echo 32768  ;;
    64k)  echo 65536  ;;
    128k) echo 131072 ;;
    256k) echo 262144 ;;
    512k) echo 524288 ;;
    *)    echo "$1"   ;;
  esac
}

# Presets: set HF_MODEL, DEFAULT_CTX, and optionally EXTRA_FLAGS
load_preset() {
  case "$1" in
    gemma4-26b)
      HF_MODEL="bartowski/google_gemma-4-26B-A4B-it-GGUF:Q6_K_L"
      DEFAULT_CTX="64k"
      EXTRA_FLAGS="--temp 1.0 --top-p 0.95 --top-k 64"
      echo "📋 Preset: Gemma 4 26B A4B (bartowski Q6_K_L)"
      ;;
    *)
      echo "Unknown preset: $1"
      echo "Available presets: gemma4-26b"
      exit 1
      ;;
  esac
}

# Parse trailing args: optional ctx size and --no-thinking flag
parse_trailing_args() {
  CTX="$DEFAULT_CTX"
  THINKING="true"
  for arg in "$@"; do
    case "$arg" in
      --no-thinking) THINKING="false" ;;
      *)             CTX="$arg" ;;
    esac
  done
}

# Wait for server with timeout
wait_for_server() {
  local elapsed=0
  echo "⏳ Waiting for server (timeout: ${HEALTH_TIMEOUT}s)..."
  until curl -s "http://127.0.0.1:$PORT/health" | grep -q "ok"; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$HEALTH_TIMEOUT" ]; then
      echo "❌ Server failed to start after ${HEALTH_TIMEOUT}s"
      kill "$LLAMA_PID" 2>/dev/null
      exit 1
    fi
  done
}

# No args → list cached models + presets
if [ -z "$1" ]; then
  echo "📦 Cached models available:"
  echo ""
  llama-server --cache-list 2>&1 | grep "^\s*[0-9]" | sed 's/^/  /'
  echo ""
  echo "🎛️  Available presets:"
  echo "  gemma4-26b   → bartowski/google_gemma-4-26B-A4B-it-GGUF:Q6_K_L"
  echo ""
  echo "Usage:"
  echo "  $0 --preset <name> [ctx-size] [--no-thinking]   # use a preset"
  echo "  $0 <hf-model> [ctx-size] [--no-thinking]        # custom model"
  echo ""
  echo "Context size aliases: 8k, 16k, 32k, 64k, 128k, 256k, 512k"
  echo ""
  echo "Examples:"
  echo "  $0 --preset gemma4-26b                          # 64k ctx, thinking on"
  echo "  $0 --preset gemma4-26b 64k                      # 64k ctx, thinking on"
  echo "  $0 --preset gemma4-26b 64k --no-thinking        # 64k ctx, thinking off"
  echo "  $0 ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M 32k"
  exit 1
fi

# Preset mode
if [ "$1" = "--preset" ]; then
  [ -z "$2" ] && { echo "Usage: $0 --preset <name> [ctx-size] [--thinking]"; exit 1; }
  DEFAULT_CTX="128k"
  EXTRA_FLAGS=""
  load_preset "$2"
  shift 2
  parse_trailing_args "$@"
# Custom model mode
else
  HF_MODEL="$1"
  DEFAULT_CTX="32k"
  EXTRA_FLAGS=""
  shift 1
  parse_trailing_args "$@"
  echo "📋 Custom model: $HF_MODEL"
fi

CTX_SIZE=$(resolve_ctx "$CTX")

echo "   Context:           $CTX ($CTX_SIZE tokens)"
echo "   Reasoning:         $THINKING"
echo "   KV cache:          q8_0 (quantized)"
echo "   Performance cores: $PERF_CORES"
echo ""

trap 'echo ""; echo "🛑 Shutting down llama-server..."; kill "$LLAMA_PID" 2>/dev/null; exit' INT TERM

echo "🚀 Starting llama-server"
# shellcheck disable=SC2086
llama-server \
  -hf "$HF_MODEL" \
  --port "$PORT" \
  --threads "$PERF_CORES" \
  -ngl 99 \
  -c "$CTX_SIZE" \
  -b 2048 \
  -ub 1024 \
  --parallel 1 \
  -fa on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  --reasoning $([ "$THINKING" = "true" ] && echo "on" || echo "off") \
  $EXTRA_FLAGS &
LLAMA_PID=$!

wait_for_server

MODEL_ID=$(curl -sf "http://127.0.0.1:$PORT/v1/models" | jq -r '.data[0].id // empty' 2>/dev/null)
if [[ -z "$MODEL_ID" ]]; then
  echo "❌ Could not detect model ID from llama-server"
  kill "$LLAMA_PID" 2>/dev/null
  exit 1
fi

echo ""
echo "✅ Server ready"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Model ID: $MODEL_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

wait $LLAMA_PID
