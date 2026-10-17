#!/usr/bin/env bash
# benchmarks/harbor_bench.sh — the public agent benchmarks against this
# server, with Harbor (install it with: sudo ./setup.sh bench). Each task runs
# in its own Docker container; the agent (OpenCode or Claude Code, installed by
# Harbor inside it) talks to the server over the Docker bridge, and the
# benchmark's own tests grade the result. Scores compare with public ones.
#
#   benchmarks/harbor_bench.sh tbench            Terminal-Bench 2.1 (89 tasks), OpenCode
#   benchmarks/harbor_bench.sh swe-verified      SWE-bench Verified (500), OpenCode
#   benchmarks/harbor_bench.sh swe-pro           SWE-bench Pro (731), Claude Code — the harness
#                                                Qwen reports Qwen3.8-Flash-Next with
#   benchmarks/harbor_bench.sh tbench -l 1       any further `harbor run` options (here: one task)
#   AGENT=claude-code benchmarks/harbor_bench.sh tbench    another agent
#   benchmarks/harbor_bench.sh swe-verified --summary      the score so far
#
# A job is named after benchmark, agent and model and lives in $BENCH_JOBS_DIR
# (default ~/bench-jobs); running the same benchmark again resumes it. One task
# at a time (the server answers one request at a time; BENCH_CONCURRENCY to
# change). The API key comes from the service credential (sudo) and goes into
# the agent's environment only: job configs are written mode 600, and the jobs
# dir is kept mode 700.
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"

BENCH="${1:?usage: harbor_bench.sh tbench|swe-verified|swe-pro [harbor run options] [--summary]}"; shift
PORT="${LLAMA_PORT:-8080}"
JOBS="${BENCH_JOBS_DIR:-$HOME/bench-jobs}"
case "$BENCH" in
  tbench)       DATASET="terminal-bench/terminal-bench-2-1"; AGENT="${AGENT:-opencode}" ;;
  swe-verified) DATASET="swe-bench/swe-bench-verified";      AGENT="${AGENT:-opencode}" ;;
  swe-pro)      DATASET="scale-ai/swe-bench-pro";            AGENT="${AGENT:-claude-code}" ;;
  *) echo "unknown benchmark: $BENCH (tbench, swe-verified, swe-pro)" >&2; exit 2 ;;
esac

# Docker access: a login from before `setup.sh bench` lacks the docker group.
if ! docker info >/dev/null 2>&1; then
  id -nG "$USER" | tr ' ' '\n' | grep -qx docker || { echo "no Docker access: sudo ./setup.sh bench" >&2; exit 1; }
  exec sg docker -c "$(printf '%q ' "$0" "$BENCH" "$@")"
fi
command -v harbor >/dev/null || { echo "no harbor: sudo ./setup.sh bench" >&2; exit 1; }

KEY="$(sudo -n head -1 /etc/setup-ubuntu-ai/api-key 2>/dev/null || sudo head -1 /etc/setup-ubuntu-ai/api-key)"
H=(-H "Authorization: Bearer ${KEY}")
MODEL="$(curl -fsS "${H[@]}" "http://127.0.0.1:${PORT}/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')" \
  || { echo "the server on :${PORT} does not answer" >&2; exit 1; }
CTX="$(curl -fsS "${H[@]}" "http://127.0.0.1:${PORT}/v1/models" | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"][0]; print(d.get("context_length") or d.get("max_model_len") or 131072)')"
GW="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
JOB="${BENCH}-${AGENT}-${MODEL}"
install -d -m 700 "$JOBS"

if [[ " $* " == *" --summary "* ]]; then
  python3 - "$JOBS/$JOB" <<'PY'
import json, pathlib, sys
job = pathlib.Path(sys.argv[1])
res = [json.loads(p.read_text()) for p in job.glob("*/result.json")]
def reward(r):
    v = (r.get("verifier_result") or {}).get("rewards") or {}
    return v.get("reward", 0) if isinstance(v, dict) else 0
done = [r for r in res if r.get("verifier_result")]
errors = [r for r in res if r.get("exception_info")]
solved = sum(1 for r in done if reward(r) >= 1)
print(f"{job.name}: {solved}/{len(done)} solved"
      + (f" ({solved / len(done) * 100:.1f} %)" if done else "") + f", {len(errors)} errored, {len(res)} trials")
PY
  exit 0
fi

if [[ -f "$JOBS/$JOB/config.json" ]]; then
  echo "▶ resuming ${JOB} (${JOBS}/${JOB})"
  exec harbor job resume -p "$JOBS/$JOB" "$@"
fi

CFG="$(mktemp --suffix=.json)"; chmod 600 "$CFG"; trap 'rm -f "$CFG"' EXIT
URL="http://${GW}:${PORT}"
URL="$URL" DATASET="$DATASET" AGENT="$AGENT" MODEL="$MODEL" CTX="$CTX" JOB="$JOB" JOBS="$JOBS" \
GW="$GW" N="${BENCH_CONCURRENCY:-1}" KEY="$KEY" python3 - "$CFG" <<'PY'
import json, os, sys
e = os.environ
agent = {"name": e["AGENT"], "extra_allowed_hosts": [e["GW"]], "env": {}, "kwargs": {}}
if e["AGENT"] == "opencode":
    agent["model_name"] = "strata/" + e["MODEL"]
    agent["env"]["STRATA_API_KEY"] = e["KEY"]
    agent["kwargs"]["opencode_config"] = {"provider": {"strata": {
        "npm": "@ai-sdk/openai-compatible", "name": "Strata",
        "options": {"baseURL": e["URL"] + "/v1", "apiKey": "{env:STRATA_API_KEY}"},
        "models": {e["MODEL"]: {"name": e["MODEL"], "reasoning": True, "tool_call": True,
                                "interleaved": {"field": "reasoning_content"},
                                "limit": {"context": int(e["CTX"]), "output": 32768}}}}}}
elif e["AGENT"] == "claude-code":
    agent["model_name"] = e["MODEL"]
    agent["env"].update({"ANTHROPIC_BASE_URL": e["URL"], "ANTHROPIC_API_KEY": e["KEY"],
                         "ANTHROPIC_MODEL": e["MODEL"], "ANTHROPIC_SMALL_FAST_MODEL": e["MODEL"],
                         "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"})
else:
    agent["model_name"] = e["MODEL"]
cfg = {"job_name": e["JOB"], "jobs_dir": e["JOBS"], "n_concurrent_trials": int(e["N"]),
       "agents": [agent]}
json.dump(cfg, open(sys.argv[1], "w"), indent=1)
PY
echo "▶ ${DATASET} with ${AGENT} on ${MODEL} (${URL}), job ${JOB} in ${JOBS}"
harbor run -c "$CFG" -d "$DATASET" -y "$@"
chmod -R go-rwx "$JOBS/$JOB" 2>/dev/null || true
