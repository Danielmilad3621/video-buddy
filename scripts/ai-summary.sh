#!/bin/bash
# ai-summary.sh <prompt> <transcript file> <summary file>: 4.0, the one place a paid AI summary is requested (the app's
# Summarize and Regenerate, and Raycast's Summarize for other sites).
#   - only when allowed: VS_AI_APPROVED=1 (the app sets it from Settings → Summaries → Allow AI summaries, off by default;
#     Raycast's summarize.sh reads the same setting). Otherwise nothing is sent, exit 3.
#   - the cheapest model the account is entitled to, fixed: claude-haiku-5-5. One turn, at most $1.00 per request
#     (the CLI's own budget check). No retry, no fallback model: a failed request fails.
#   - the summary is written (via .part) only when the answer is a success with text; never an error message.
#   - prints "AI: <model> · $<cost> · <tokens in> tokens in, <tokens out> out" and appends one line per request to
#     $VS_AI_LOG (default ~/Library/Logs/Video Buddy/ai-usage.log).
# ai-summary.sh --check: finds the Claude CLI the way a request would and checks it supports the limits, without
# sending anything (claude --version and --help only).
set -uo pipefail
export PATH="/opt/homebrew/bin:$HOME/.local/bin:$PATH"   # Raycast and the app don't load your shell profile
model=claude-haiku-5-5
claude=claude
# test runs only (an isolated build started with test hooks passes VS_TEST_RUN): a stand-in CLI, never the real one
[[ ${VS_TEST_RUN:-} == 1 && -n ${VS_TEST_CLAUDE:-} ]] && claude=$VS_TEST_CLAUDE

if [[ ${1:-} == --check ]]; then
  path=$(command -v "$claude") || { echo "AI check: the Claude CLI isn't found (looked in $PATH)"; exit 1; }
  version=$("$claude" --version < /dev/null 2> /dev/null | head -1); help=$("$claude" --help < /dev/null 2> /dev/null)
  # the documented limits (--max-turns isn't in --help, but the CLI accepts it: an extra limit, not the safeguard)
  for flag in --max-budget-usd --output-format --model; do
    [[ $help == *"$flag"* ]] || { echo "AI check: $path ($version) has no $flag"; exit 1; }
  done
  echo "AI check: ok: $path ($version); --max-budget-usd, --output-format and --model supported; model $model"
  exit 0
fi

prompt=${1:?prompt} in=${2:?transcript file} out=${3:?summary file}
log=${VS_AI_LOG:-$HOME/Library/Logs/Video Buddy/ai-usage.log}
record() { mkdir -p "$(dirname "$log")" && echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$log"; }
if [[ ${VS_AI_APPROVED:-} != 1 ]]; then
  echo "AI summaries are off (Video Buddy → Settings → Summaries → Allow AI summaries). Nothing was sent." >&2
  record "refused (AI summaries are off), nothing sent"
  exit 3
fi
[[ -s $in ]] || { echo "No transcript to summarize: $in" >&2; exit 1; }
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ai-summary.XXXXXX")
trap 'rm -rf "$tmp"; rm -f "$out.part"' EXIT
trap 'exit 143' TERM INT

"$claude" -p --model "$model" --output-format json --max-turns 1 --max-budget-usd 1.00 "$prompt" < "$in" > "$tmp/r.json"
code=$?
line=$(jq -r '"\(.modelUsage // {} | keys | join(", ") | if . == "" then "?" else . end) · $\(.total_cost_usd // "?") · \((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0) + (.usage.cache_read_input_tokens // 0)) tokens in, \(.usage.output_tokens // 0) out\(if .is_error then " · error: \(.subtype // .result // "?")" else "" end)"' "$tmp/r.json" 2> /dev/null) \
  || line="? · no answer (exit $code)"
echo "AI: $line"
if [[ $code == 0 ]] && jq -e '(.is_error | not) and ((.result // "") | length > 0)' "$tmp/r.json" > /dev/null 2>&1; then
  jq -r .result "$tmp/r.json" > "$out.part" && mv "$out.part" "$out"
  record "ok · $line"
  exit 0
fi
record "failed · $line"
echo "The AI summary failed; nothing was saved and it isn't retried." >&2
exit 1
