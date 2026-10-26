#!/bin/bash
# ai-summary-test.sh: 4.0, the paid-AI safeguards checked with a stand-in Claude CLI only. Nothing is ever sent to the API:
# every run either uses the stub (VS_TEST_RUN=1 + VS_TEST_CLAUDE) or has no way to reach the real CLI (HOME and PATH
# pointed at empty folders). Checks ai-summary.sh (the flags, one call, success / budget / error / empty / is_error,
# the off switch, the usage log, --check) and the full Summarize workflow of raycast/summarize.sh (a fake downloader,
# the real on-device transcribe.sh on a spoken sample, the stub). Prints one line per check, then "ai: N passed, M failed".
set -uo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/vb-aitest.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { if [[ $2 == True ]]; then pass=$((pass + 1)); echo "  ✓ $1"; else fail=$((fail + 1)); echo "  ✗ $1  (got: ${3:-$2})"; fi; }
is() { [[ $1 == "$2" ]] && echo True || echo False; }

# the stub: records every call (arguments and stdin size) and answers as $T/mode says
cat > "$T/claude" <<'EOF'
#!/bin/bash
T=$(dirname "$0")
echo "$*" >> "$T/calls"; [[ ${1:-} == -p ]] && wc -c < /dev/stdin | tr -d ' ' >> "$T/stdin-bytes"
case $(cat "$T/mode") in
  ok) echo '{"type":"result","subtype":"success","is_error":false,"result":"**TL;DR**\nA stub summary.","total_cost_usd":0.0051,"usage":{"input_tokens":9,"cache_creation_input_tokens":30000,"cache_read_input_tokens":0,"output_tokens":2600},"modelUsage":{"claude-haiku-5-5":{}}}' ;;
  budget) echo '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"total_cost_usd":1.01,"usage":{"input_tokens":5,"output_tokens":3},"modelUsage":{"claude-haiku-5-5":{}}}'; exit 1 ;;
  crash) echo "API Error: overloaded" >&2; exit 1 ;;
  empty) echo '{"type":"result","subtype":"success","is_error":false,"result":"","total_cost_usd":0.001,"usage":{},"modelUsage":{"claude-haiku-5-5":{}}}' ;;
  iserror) echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Error: something went wrong","total_cost_usd":0.002,"usage":{},"modelUsage":{"claude-haiku-5-5":{}}}' ;;
esac
EOF
chmod +x "$T/claude"
ai="$repo/scripts/ai-summary.sh"
echo "A transcript long enough to summarize." > "$T/in.txt"
run() {  # <mode> [approved]: one request; leaves $code, $said
  echo "$1" > "$T/mode"; rm -f "$T/calls" "$T/out.md"
  said=$(VS_TEST_RUN=1 VS_TEST_CLAUDE="$T/claude" VS_AI_LOG="$T/ai.log" VS_AI_APPROVED=${2:-1} "$ai" "the prompt" "$T/in.txt" "$T/out.md" 2>&1); code=$?
}
calls() { [[ -f $T/calls ]] && wc -l < "$T/calls" | tr -d ' ' || echo 0; }

echo "== ai-summary.sh with a stand-in CLI"
run ok
ok "success: exit 0, the summary saved, one call" "$([[ $code == 0 && $(cat "$T/out.md") == *"A stub summary."* && $(calls) == 1 ]] && echo True || echo False)" "$code $(calls)"
ok "…the exact request: -p --model claude-haiku-5-5 --output-format json --max-turns 1 --max-budget-usd 1.00, no fallback model" \
   "$(is "$(cat "$T/calls")" "-p --model claude-haiku-5-5 --output-format json --max-turns 1 --max-budget-usd 1.00 the prompt")" "$(cat "$T/calls")"
ok "…the transcript went in on stdin" "$(is "$(tail -1 "$T/stdin-bytes")" "$(wc -c < "$T/in.txt" | tr -d ' ')")"
ok "…the model, cost and tokens printed" "$(is "$(grep '^AI:' <<<"$said")" "AI: claude-haiku-5-5 · \$0.0051 · 30009 tokens in, 2600 out")" "$said"
ok "…and recorded in the usage log" "$([[ $(tail -1 "$T/ai.log") == *"ok · claude-haiku-5-5 · \$0.0051 · 30009 tokens in, 2600 out" ]] && echo True || echo False)" "$(tail -1 "$T/ai.log")"
for m in budget crash empty iserror; do
  run $m
  ok "$m: fails (exit 1), nothing saved, no .part, exactly one call (no retry)" "$([[ $code == 1 && ! -e $T/out.md && ! -e $T/out.md.part && $(calls) == 1 ]] && echo True || echo False)" "$code $(calls) $(ls "$T" | grep out)"
done
run budget
ok "budget: the cap's error and its cost are printed and recorded" "$([[ $said == *"error: error_max_budget_usd"* && $(tail -1 "$T/ai.log") == *"failed · claude-haiku-5-5 · \$1.01"* ]] && echo True || echo False)" "$said"
ok "is_error: the error text is never saved as a summary" "$([[ ! -e $T/out.md ]] && echo True || echo False)"
run ok 0
ok "AI summaries off (no VS_AI_APPROVED): refused (exit 3), the CLI never called, recorded as refused" "$([[ $code == 3 && $(calls) == 0 && ! -e $T/out.md && $(tail -1 "$T/ai.log") == *"refused"* ]] && echo True || echo False)" "$code $(calls)"
# without VS_TEST_RUN the stub is ignored: with HOME and PATH pointing at empty folders the real CLI can't be reached either
mkdir -p "$T/emptyhome" "$T/emptybin"
echo ok > "$T/mode"; rm -f "$T/calls"
said=$(env -i HOME="$T/emptyhome" PATH="$T/emptybin:/usr/bin:/bin" TMPDIR="$T" VS_TEST_CLAUDE="$T/claude" VS_AI_APPROVED=1 VS_AI_LOG="$T/ai.log" /bin/bash "$ai" p "$T/in.txt" "$T/out2.md" 2>&1); code=$?
ok "outside a test run the stand-in is ignored (and here no CLI can be found): fails, no call" "$([[ $code != 0 && $(calls) == 0 && $said == *"not found"* ]] && echo True || echo False)" "$code $(calls) $said"
said=$(VS_TEST_RUN=1 VS_TEST_CLAUDE="$T/claude" "$ai" --check 2>&1); code=$?
ok "--check on a CLI without the limits: refused" "$([[ $code == 1 && $said == *"has no --max-budget-usd"* ]] && echo True || echo False)" "$said"

echo "== the full Summarize workflow (raycast/summarize.sh) with a fake downloader, real transcription, the stand-in CLI"
L="$T/layout"; mkdir -p "$L/raycast" "$L/scripts" "$T/out"
cp "$repo/raycast/summarize.sh" "$L/raycast/"; cp "$repo"/scripts/*.sh "$L/scripts/"
say -o "$T/speech.aiff" "This is a short test of the summary workflow. The speaker explains how a cheap model can summarize a video transcript."
/opt/homebrew/bin/ffmpeg -v error -i "$T/speech.aiff" -codec:a libmp3lame -b:a 128k "$T/speech.mp3"
cat > "$T/fake-dl.sh" <<EOF
#!/bin/bash
echo "\$*" >> "$T/downloads"; cp "$T/speech.mp3" "\$3/Test video.mp3"; echo "\$3/Test video.mp3"
EOF
chmod +x "$T/fake-dl.sh"
flow() {  # <mode> <approved: 1 or empty>
  echo "$1" > "$T/mode"; rm -f "$T/calls" "$T/downloads" "$T/out"/*
  said=$(VS_FROM_APP=1 VS_OUT_DIR="$T/out" VS_TEST_RUN=1 VS_TEST_CLAUDE="$T/claude" VS_TEST_DOWNLOADER="$T/fake-dl.sh" VS_AI_LOG="$T/flow.log" \
         VS_AI_APPROVED=$2 "$L/raycast/summarize.sh" "https://example.com/video" 2>&1); code=$?
}
flow ok 1
ok "approved: downloaded (fake), transcribed on this Mac, summarized once, saved" "$([[ $code == 0 && -s $T/out/Test\ video.transcript.txt && $(cat "$T/out/Test video.summary.md") == *"A stub summary."* && $(calls) == 1 ]] && echo True || echo False)" "$code $(calls) $(ls "$T/out" | tr '\n' ' ')"
ok "…the model, cost and tokens in its output; the summary shown (for Raycast); the last line the file" "$([[ $said == *"AI: claude-haiku-5-5 · \$0.0051"* && $said == *"A stub summary."* && $(tail -1 <<<"$said") == "📁 $T/out/Test video.mp3" ]] && echo True || echo False)" "$(tail -3 <<<"$said")"
flow budget 1
ok "the paid request fails: the workflow fails, no summary, no .part, one call" "$([[ $code != 0 && ! -e $T/out/Test\ video.summary.md && ! -e $T/out/Test\ video.summary.md.part && $(calls) == 1 ]] && echo True || echo False)" "$code $(calls) $(ls "$T/out" | tr '\n' ' ')"
flow ok ""
ok "AI summaries off: stopped before downloading anything, the CLI never called" "$([[ $code == 3 && ! -e $T/downloads && $(calls) == 0 && $said == *"AI summaries are off"* ]] && echo True || echo False)" "$code $(calls) $said"
# from Raycast (no VS_FROM_APP): the app's setting decides; in this test its domain has no setting, so it's off
said=$(VS_OUT_DIR="$T/out" VS_TEST_RUN=1 VS_TEST_CLAUDE="$T/claude" VS_TEST_DOWNLOADER="$T/fake-dl.sh" "$L/raycast/summarize.sh" "https://example.com/video" 2>&1); code=$?
setting=$(defaults read local.video-summarizer aiSummariesApproved 2> /dev/null || echo unset)
ok "from Raycast, with Video Buddy's setting $setting: $([[ $setting == 1 ]] && echo allowed || echo "off, stopped before downloading")" \
   "$([[ $setting == 1 ]] && echo True || { [[ $code == 3 && ! -e $T/downloads && $(calls) == 0 ]] && echo True || echo False; })" "$code $said"

echo "ai: $pass passed, $fail failed"
((fail == 0))
