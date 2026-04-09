# local-llm

Run Claude Code against a local model via [llama.cpp](https://github.com/ggerganov/llama.cpp).

## Requirements

- `llama-server` (from llama.cpp, installable via `brew install llama.cpp`)
- `claude` CLI

## Usage

### 1. Start the server

```bash
# Recommended preset (Gemma 4 26B, 128k ctx)
start-llama --preset gemma4-26b

# Different context size (aliases or raw integer)
start-llama --preset gemma4-26b 64k
start-llama --preset gemma4-26b 200000

# With reasoning mode
start-llama --preset gemma4-26b 128k --thinking

# Any HuggingFace GGUF model
start-llama <hf-repo:file> [ctx-size]
start-llama ggml-org/gemma-4-E4B-it-GGUF:Q4_K_M 32k
```

Context size aliases: `8k`, `16k`, `32k`, `64k`, `128k`, `256k`, `512k` — or any integer.

### 2. Run Claude Code

```bash
cc-local
cc-local --resume
```

`cc-local` auto-detects the running model from the server. Any additional arguments are forwarded to the `claude` CLI.

## Shell setup

Add to your `.zshrc`:

```bash
alias start-llama="~/local-llm/start-llama.sh"
source ~/local-llm/shell/cc-local.sh
```

## References

This repo was built using the following resources:

- [Running Claude Code with local LLMs](https://pchalasani.github.io/claude-code-tools/integrations/local-llms/)
- [Running Google Gemma 4 locally with llama.cpp](https://ai.georgeliu.com/p/running-google-gemma-4-locally-with)
