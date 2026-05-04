#!/bin/bash

PORT=8080
PERF_CORES=$(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo 8)

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
    gemma4-26b-a4b)
      HF_MODEL="bartowski/google_gemma-4-26B-A4B-it-GGUF:Q6_K_L"
      DEFAULT_CTX="64k"
      DEFAULT_REASONING="on"
      DEFAULT_REASONING_BUDGET="1024"
      EXTRA_FLAGS="--temp 1.0 --top-p 0.95 --top-k 64"
      echo "📋 Preset: Gemma 4 26B A4B (bartowski Q6_K_L, thinking budget: 1024)"
      ;;
    gemma4-26b-a4b-uncensored)
      HF_MODEL="llmfan46/gemma-4-26B-A4B-it-ultra-uncensored-heretic-GGUF:Q6_K"
      DEFAULT_CTX="64k"
      DEFAULT_REASONING="on"
      DEFAULT_REASONING_BUDGET="1024"
      EXTRA_FLAGS="--temp 1.0 --top-p 0.95 --top-k 64"
      echo "📋 Preset: Gemma 4 26B A4B Ultra Uncensored Heretic (llmfan46 Q6_K, thinking budget: 1024)"
      ;;
    qwen3.6-27b)
      HF_MODEL="unsloth/Qwen3.6-27B-GGUF:Q6_K"
      DEFAULT_CTX="64k"
      DEFAULT_REASONING="on"
      # Thinking-mode params (general) per Qwen3 recommendations; -n caps output at 32k tokens
      EXTRA_FLAGS="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0 --repeat-penalty 1.0 -n 32768"
      echo "📋 Preset: Qwen3.6 27B (unsloth Q6_K, thinking on)"
      ;;
    qwen3.6-35b-a3b-uncensored)
      HF_MODEL="HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M"
      DEFAULT_CTX="64k"
      DEFAULT_REASONING="on"
      # Thinking-mode params (general) per Qwen3 recommendations; -n caps output at 32k tokens
      EXTRA_FLAGS="--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.0 --presence-penalty 0.0 --repeat-penalty 1.0 -n 32768"
      echo "📋 Preset: Qwen3.6 27B (unsloth Q6_K, thinking on)"
      ;;
    *)
      echo "Unknown preset: $1"
      echo "Available presets: gemma4-26b, gemma4-26b-uncensored, qwen3-27b"
      exit 1
      ;;
  esac
}

# Parse trailing args: optional ctx size, reasoning mode, and budget.
# Presets may set DEFAULT_REASONING; explicit flags always win.
parse_trailing_args() {
  CTX="$DEFAULT_CTX"
  REASONING="${DEFAULT_REASONING:-auto}"
  REASONING_BUDGET="${DEFAULT_REASONING_BUDGET:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --thinking)    REASONING="on" ;;
      --no-thinking) REASONING="off" ;;
      --budget)      shift; REASONING_BUDGET="$1" ;;
      *)             CTX="$1" ;;
    esac
    shift
  done
}

# Wait for server — no fixed timeout so downloads don't get cut off.
# Exits immediately if the llama-server process dies.
wait_for_server() {
  local elapsed=0
  echo "⏳ Waiting for server (may take a while if model needs to download)..."
  until curl -s "http://127.0.0.1:$PORT/health" | grep -q "ok"; do
    sleep 1
    elapsed=$((elapsed + 1))
    if ! kill -0 "$LLAMA_PID" 2>/dev/null; then
      echo "❌ llama-server exited unexpectedly after ${elapsed}s"
      exit 1
    fi
    if [ $((elapsed % 30)) -eq 0 ]; then
      echo "   Still waiting... (${elapsed}s elapsed)"
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
  echo "  gemma4-26b            → bartowski/google_gemma-4-26B-A4B-it-GGUF:Q6_K_L"
  echo "  gemma4-26b-uncensored → llmfan46/gemma-4-26B-A4B-it-ultra-uncensored-heretic-GGUF:Q6_K"
  echo "  qwen3-27b             → unsloth/Qwen3.6-27B-GGUF:Q6_K  (thinking on, 32k out)"
  echo ""
  echo "Usage:"
  echo "  $0 --preset <name> [ctx-size] [--thinking|--no-thinking] [--budget N]"
  echo "  $0 <hf-model> [ctx-size] [--thinking|--no-thinking] [--budget N]"
  echo ""
  echo "Context size aliases: 8k, 16k, 32k, 64k, 128k, 256k, 512k"
  echo "Reasoning: presets may default to on/off; explicit flag always wins"
  echo "Budget:    --budget N  (-1 = unrestricted, 0 = off, N = token limit)"
  echo ""
  echo "Examples:"
  echo "  $0 --preset gemma4-26b                          # 64k ctx, reasoning auto"
  echo "  $0 --preset gemma4-26b --no-thinking            # reasoning off"
  echo "  $0 --preset gemma4-26b --thinking --budget 2048 # cap at 2048 think tokens"
  echo "  $0 --preset qwen3-27b                           # 128k ctx, thinking on"
  echo "  $0 --preset qwen3-27b --no-thinking             # instruct mode"
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
echo "   Reasoning:         $REASONING${REASONING_BUDGET:+ (budget: $REASONING_BUDGET tokens)}"
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
  --reasoning "$REASONING" \
  ${REASONING_BUDGET:+--reasoning-budget "$REASONING_BUDGET"} \
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
