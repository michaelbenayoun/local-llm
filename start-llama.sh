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

# Presets
run_preset() {
  local name="$1"
  local ctx=$(resolve_ctx "${2:-128k}")
  local thinking="${3:-false}"

  case "$name" in
    gemma4-26b)
      echo "📋 Preset: Gemma 4 26B A4B (bartowski Q6_K_L)"
      echo "   Context:           $2 ($ctx tokens)"
      echo "   Reasoning:         $thinking"
      echo "   KV cache:          q8_0 (quantized)"
      echo "   Performance cores: $PERF_CORES"
      echo ""
      llama-server \
        -hf bartowski/google_gemma-4-26B-A4B-it-GGUF:Q6_K_L \
        --port "$PORT" \
        --threads "$PERF_CORES" \
        -ngl 99 \
        -c "$ctx" \
        -b 2048 \
        -ub 1024 \
        --parallel 1 \
        -fa on \
        --cache-type-k q8_0 \
        --cache-type-v q8_0 \
        --temp 1.0 \
        --top-p 0.95 \
        --top-k 64 \
        --reasoning $([ "$thinking" = "true" ] && echo "on" || echo "off")
      ;;
    *)
      echo "Unknown preset: $name"
      echo "Available presets: gemma4-26b"
      exit 1
      ;;
  esac
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
  echo "  $0 --preset <name> [ctx-size] [--thinking]   # use a preset"
  echo "  $0 <hf-model> [ctx-size] [--thinking]        # custom model"
  echo ""
  echo "Context size aliases: 8k, 16k, 32k, 64k, 128k, 256k, 512k"
  echo ""
  echo "Examples:"
  echo "  $0 --preset gemma4-26b                       # 128k ctx, no thinking"
  echo "  $0 --preset gemma4-26b 64k                   # 64k ctx"
  echo "  $0 --preset gemma4-26b 64k --thinking        # 64k ctx + thinking mode"
  echo "  $0 ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M 32k"
  echo "  $0 ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M 32k --thinking"
  exit 1
fi

# Preset mode
if [ "$1" = "--preset" ]; then
  if [ -z "$2" ]; then
    echo "Usage: $0 --preset <name> [ctx-size] [--thinking]"
    exit 1
  fi
  PRESET_NAME="$2"
  PRESET_CTX="128k"
  PRESET_THINKING="false"
  shift 2
  for arg in "$@"; do
    case "$arg" in
      --thinking) PRESET_THINKING="true" ;;
      *)          PRESET_CTX="$arg" ;;
    esac
  done

  echo "🚀 Starting llama-server"
  run_preset "$PRESET_NAME" "$PRESET_CTX" "$PRESET_THINKING" &
  LLAMA_PID=$!

# Custom model mode
else
  HF_MODEL="$1"
  CUSTOM_CTX="32k"
  CUSTOM_THINKING="false"
  shift 1
  for arg in "$@"; do
    case "$arg" in
      --thinking) CUSTOM_THINKING="true" ;;
      *)          CUSTOM_CTX="$arg" ;;
    esac
  done
  CTX_SIZE=$(resolve_ctx "$CUSTOM_CTX")
  echo "🚀 Starting llama-server"
  echo "   Model:             $HF_MODEL"
  echo "   Context size:      $CUSTOM_CTX ($CTX_SIZE tokens)"
  echo "   Reasoning:         $CUSTOM_THINKING"
  echo "   Performance cores: $PERF_CORES"
  echo "   GPU layers:        99 (all on Metal)"
  echo "   KV cache:          q8_0 (quantized)"
  echo ""
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
    --reasoning $([ "$CUSTOM_THINKING" = "true" ] && echo "on" || echo "off") &
  LLAMA_PID=$!
fi

trap 'echo ""; echo "🛑 Shutting down llama-server..."; kill "$LLAMA_PID" 2>/dev/null; exit' INT TERM

wait_for_server

# Get model name from server
MODEL_ID=$(curl -s "http://127.0.0.1:$PORT/v1/models" | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])")

echo ""
echo "✅ Server ready"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Model ID: $MODEL_ID"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

wait $LLAMA_PID
