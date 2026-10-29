#!/usr/bin/env bash
# Logs agents in to the Claude subscription: runs `claude setup-token` and saves the
# sk-ant-oat01-… token to the file bin/claude_bridge reads (docs/workflow.md, "Login").
set -euo pipefail

state_dir="${CLAUDE_BRIDGE_STATE:-$HOME/.weworkai-bridge}"
token_file="$state_dir/oauth-token"

# setup-token is interactive (browser login), so it keeps the terminal and the token is pasted back.
claude setup-token

read -rsp "Paste the sk-ant-oat01-… token: " pasted
echo

token="$(grep -oE 'sk-ant-oat01-[A-Za-z0-9_-]+' <<<"$pasted" || true)"
if [[ -z "$token" ]]; then
  echo "Not a subscription token (sk-ant-oat01-…); an API key is not accepted." >&2
  exit 1
fi

mkdir -p "$state_dir"
(umask 077 && printf '%s\n' "$token" >"$token_file")
chmod 600 "$token_file"
echo "Saved to $token_file"
