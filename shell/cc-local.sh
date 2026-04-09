# cc-local: run Claude Code against a local llama-server
# Capture the directory of this file at source time (works in both bash and zsh)
_CC_LOCAL_DIR="${${(%):-%x}:A:h}" 2>/dev/null || _CC_LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cc-local() {
  # Pre-flight: ensure llama-server is up
  if ! curl -sf "http://127.0.0.1:8080/health" | grep -q "ok"; then
    echo "❌ llama-server not running. Start it with: start-llama [--preset <name>] [ctx-size] [--thinking]"
    return 1
  fi

  # Detect whichever model is currently loaded in llama-server
  local model_id
  model_id=$(curl -sf "http://127.0.0.1:8080/v1/models" | jq -r '.data[0].id // empty' 2>/dev/null)
  if [[ -z "$model_id" ]]; then
    echo "❌ Could not detect model ID from llama-server"
    return 1
  fi

  local tmp_dir=$(mktemp -d)
  trap "rm -rf '$tmp_dir'" EXIT

  # Minimum files to skip the setup wizard; merge local-LLM env overrides into settings
  jq '.env |= (. // {}) + {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_ATTRIBUTION_HEADER": "0"}' \
    ~/.claude/settings.json > "$tmp_dir/settings.json" 2>/dev/null \
    || echo '{"env":{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","CLAUDE_CODE_ATTRIBUTION_HEADER":"0"}}' > "$tmp_dir/settings.json"
  cp ~/.claude.json "$tmp_dir/.claude.json" 2>/dev/null || true

  # Point Claude Code at the local server. ANTHROPIC_AUTH_TOKEN is a dummy
  # value; llama-server doesn't require authentication.
  #
  # ANTHROPIC_MODEL + the three DEFAULT_*_MODEL vars force all Claude Code
  # model selections (Opus/Sonnet/Haiku) to route through the local model.
  # Without these, Claude Code would send Anthropic model names the local
  # server doesn't recognise.
  #
  # CLAUDE_CODE_SUBAGENT_MODEL ensures subagents spawned during a session
  # also use the local model.
  #
  # API_TIMEOUT_MS is set very high (~8h) because local inference is slower
  # than the Anthropic API and complex tasks need time to complete.
  #
  # BASH_DEFAULT/MAX_TIMEOUT_MS extend shell command timeouts to ~40 min
  # for long-running operations.
  #
  # MAX_OUTPUT_TOKENS caps output per response to keep generation times
  # reasonable on local hardware. Applies to responses and file reads.
  #
  # AUTO_COMPACT_WINDOW + AUTOCOMPACT_PCT_OVERRIDE trigger context compaction
  # at 90% of a 48k-token window so Claude never hits the limit mid-task.
  #
  # DISABLE_1M_CONTEXT turn off features that would talke too long locally.
  ANTHROPIC_BASE_URL="http://127.0.0.1:8080" \
  ANTHROPIC_AUTH_TOKEN="local" \
  ANTHROPIC_API_KEY="" \
  ANTHROPIC_MODEL="$model_id" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model_id" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$model_id" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$model_id" \
  CLAUDE_CODE_SUBAGENT_MODEL="$model_id" \
  API_TIMEOUT_MS="30000000" \
  BASH_DEFAULT_TIMEOUT_MS="2400000" \
  BASH_MAX_TIMEOUT_MS="2500000" \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS="8192" \
  CLAUDE_CODE_FILE_READ_MAX_OUTPUT_TOKENS="16384" \
  CLAUDE_CODE_AUTO_COMPACT_WINDOW="24000" \
  CLAUDE_AUTOCOMPACT_PCT_OVERRIDE="90" \
  CLAUDE_CODE_DISABLE_1M_CONTEXT="1" \
  CLAUDE_CONFIG_DIR="$tmp_dir" \
  claude \
  "$@"
}
