#!/usr/bin/env python3
"""
opencode_agent_bench.py — the model as a coding agent: OpenCode runs headless
(`opencode run --auto`) on real work in a throwaway directory, and hidden
checks the agent never sees grade the result.

Tasks:
  json-edit     5 surgical edits in a large nested JSON file, edited in place
                (every other leaf must survive)
  yaml-edit     the same for a large Kubernetes Deployment YAML
  bugfix        setup-ubuntu-ai before 3335b85: under Secure Boot the drivers
                step says there is no Canonical-signed module although
                `apt-cache policy` lists one (root cause: `apt-cache … | grep -q`
                under pipefail — grep exits early, apt-cache dies of SIGPIPE)
  refactor      one key list in setup.sh's _restore_rehome instead of two
                copies, behaviour unchanged, with a test
  feature       cfg_validate in lib/config.sh to an exact spec, with tests

Usage:
  python3 opencode_agent_bench.py                       # all tasks
  python3 opencode_agent_bench.py --tasks bugfix,feature --model llm/<model>
  python3 opencode_agent_bench.py --keep                # keep the work dirs

Needs: opencode on PATH (or ~/.local/bin) with a provider for the server, git,
PyYAML; the repository tasks check out this repository's history.
The agent may run any command in its work dir (--auto): run it as a user
whose files you can afford to lose, on a machine you can rebuild.
"""
import argparse, json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import config_edit_bench as ceb   # noqa: E402  (the JSON/YAML generators)

OPENCODE = shutil.which("opencode") or os.path.expanduser("~/.local/bin/opencode")


def sh(cmd, cwd=None, timeout=600, env=None):
    p = subprocess.run(cmd, cwd=cwd, shell=isinstance(cmd, str), capture_output=True, text=True,
                       timeout=timeout, env=env)
    return p.returncode, p.stdout + p.stderr


def agent(work, prompt, model, timeout):
    """One headless OpenCode session; returns (seconds, exit, output tokens, steps, last text)."""
    cmd = [OPENCODE, "run", "--auto", "--format", "json", "--dir", work, "--title", "bench"]
    if model:
        cmd += ["--model", model]
    t0 = time.time()
    try:
        p = subprocess.run(cmd + [prompt], capture_output=True, text=True, timeout=timeout, cwd=work)
        rc, out = p.returncode, p.stdout
    except subprocess.TimeoutExpired as e:
        rc, out = "timeout", (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or "")
    secs = time.time() - t0
    tokens, steps, text = 0, 0, ""
    for line in out.splitlines():
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        part = ev.get("part") or {}
        if ev.get("type") == "step_finish" or part.get("type") == "step-finish":
            steps += 1
            tokens += ((part.get("tokens") or {}).get("output") or 0)
        if part.get("type") == "text" and part.get("text"):
            text = part["text"]
    with open(os.path.join(work, ".bench-agent.jsonl"), "w") as f:
        f.write(out)
    return secs, rc, tokens, steps, text


# ------------------------------------------------------------------ tasks
def task_config_edit(kind):
    def setup(work):
        if kind == "json":
            doc, exp, prompt, parse = ceb.make_json(8)
            path = os.path.join(work, "platform.json")
            with open(path, "w") as f:
                json.dump(doc, f, indent=2)
        else:
            doc, exp, prompt, parse = ceb.make_yaml(6)
            path = os.path.join(work, "deployment.yaml")
            with open(path, "w") as f:
                f.write(ceb.yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))
        edits = prompt.split("\n\n```")[0]
        edits = edits.replace("Edit this JSON.", "Edit platform.json in this directory, in place.") \
                     .replace("Edit this Kubernetes YAML.", "Edit deployment.yaml in this directory, in place.")
        n = len(ceb.flatten(doc))
        state = {"exp": exp, "parse": parse, "path": path, "leaves": n}
        return edits + "\nUse your file edit tool; do not rewrite the file with a script.", state

    def check(work, state):
        try:
            with open(state["path"]) as f:
                got = state["parse"](f.read())
        except Exception as e:
            return False, f"file does not parse: {e}"
        fe, fg = ceb.flatten(state["exp"]), ceb.flatten(got)
        bad = sorted(k for k in set(fe) | set(fg) if fe.get(k) != fg.get(k))
        return not bad, (f"{state['leaves']} leaves, all as expected" if not bad
                         else f"{len(bad)} deviation(s): {bad[:4]}")
    return setup, check


def checkout(work, rev):
    rc, out = sh(["git", "-C", REPO, "worktree", "add", "--detach", work, rev])
    if rc:
        raise RuntimeError(out)
    sh(["git", "-C", work, "config", "user.email", "bench@local"]); sh(["git", "-C", work, "config", "user.name", "bench"])


def repo_tests(work):
    rc, out = sh(["bash", "tests/run.sh"], cwd=work, timeout=900)
    return rc == 0, out.strip().splitlines()[-1] if out.strip() else ""


# The bug before 3335b85, seen from outside: Secure Boot on, the signed module
# in the archive behind a long `apt-cache policy` answer (as apt prints it).
BUGFIX_CHECK = r'''
set -uo pipefail
cd "$1"
for l in $(sed -n 's/^for _lib in \(.*\); do$/\1/p' setup.sh); do . "lib/$l.sh"; done
set +e; trap - ERR
. modules/20-drivers-nvidia.sh
LOG=$(mktemp)
mokutil() { echo "SecureBoot enabled"; }
uname() { echo 7.0.0-38-generic; }
apt-cache() { printf '%s:\n  Installed: (none)\n  Candidate: 7.0.0-38.38+2\n' "$2"; seq 1 20000 | sed 's/^/     /'; }
apt_install() { echo "apt_install $*" >>"$LOG"; }
pkg_installed() { return 1; }
run() { echo "run $*" >>"$LOG"; }
cfg_get() { case "$1" in NVIDIA_MOK_STRATEGY) echo canonical ;; *) echo "${2-}" ;; esac; }
_nv_install_signed_module nvidia-driver-595-open >/dev/null 2>&1
grep -q "apt_install linux-modules-nvidia-595-open-generic" "$LOG"
'''

REFACTOR_CHECK = r'''
set -uo pipefail
cd "$1"
body="$(sed -n '/^_restore_rehome() {/,/^}/p' setup.sh)"
[[ -n "$body" ]] || { echo "no _restore_rehome"; exit 1; }
n=$(grep -o 'LLAMACPP_BIN' <<<"$body" | wc -l)
[[ "$n" -le 1 ]] || { echo "the key list is still written out $n times"; exit 1; }
for l in $(sed -n 's/^for _lib in \(.*\); do$/\1/p' setup.sh); do . "lib/$l.sh"; done
set +e; trap - ERR
eval "$(sed -n '/^_restore_rehome() {/,/^}/p' setup.sh)"
# any helper it now calls that lives in setup.sh
eval "$(awk '/^[a-z_]+\(\) \{/{f=1} f{print} /^\}/{f=0}' setup.sh | grep -v '^main$')" 2>/dev/null
CONFIG_FILE=$(mktemp); DRY_RUN=0
printf 'LLAMA_MODEL="/home/old/models/m.gguf"\nSTRATA_DIR="/home/old/strata"\nSTRATA_DATA_DIR="/home/old/Strata-data"\nMODEL_DIR="/home/old/models"\nLLAMA_HOST="0.0.0.0"\n' >"$CONFIG_FILE"
cfg_load; INVOKING_HOME=/home/new
_restore_rehome >/dev/null 2>&1; cfg_load
[[ "$(cfg_get LLAMA_MODEL)" == /home/new/models/m.gguf && "$(cfg_get STRATA_DIR)" == /home/new/strata \
   && "$(cfg_get STRATA_DATA_DIR)" == /home/new/Strata-data && "$(cfg_get MODEL_DIR)" == /home/new/models \
   && "$(cfg_get LLAMA_HOST)" == 0.0.0.0 ]] || { echo "re-homing changed: $(cat "$CONFIG_FILE")"; exit 1; }
'''

FEATURE_SPEC = """Add a function cfg_validate to lib/config.sh. It checks the loaded config (the CFG array) and prints
one line per problem to stdout, in this exact form:  KEY: reason
and returns 1 if there was any problem, else 0 (printing nothing). Rules, only for keys that are set:
- LLAMA_PORT: an integer from 1 to 65535
- LLAMA_CTX, STRATA_CONTEXT: a positive integer
- ENGINE: llamacpp or strata
- STRATA_KV: int8, q4_0 or k8v4
- STRATA_VISION: yes, no, none, gpu or cpu
- NVIDIA_POWER_LIMIT_W: an integer from 100 to 1000
- if ENGINE is strata, STRATA_FAMILY and STRATA_MODEL must be set (reason: required for ENGINE=strata)
Then make `sudo ./setup.sh config validate` call it (exit 1 on problems), mention it in the usage text,
and add tests for it to tests/run.sh. tests/run.sh must pass."""

FEATURE_CHECK = r'''
set -uo pipefail
cd "$1"
for l in $(sed -n 's/^for _lib in \(.*\); do$/\1/p' setup.sh); do . "lib/$l.sh"; done
set +e; trap - ERR
declare -F cfg_validate >/dev/null || { echo "no cfg_validate"; exit 1; }
v() { CFG=(); local kv; for kv in "$@"; do CFG["${kv%%=*}"]="${kv#*=}"; done; cfg_validate; }
out="$(v LLAMA_PORT=8080 LLAMA_CTX=262144 ENGINE=llamacpp)"; rc=$?
[[ $rc == 0 && -z "$out" ]] || { echo "a good config: rc=$rc out=$out"; exit 1; }
out="$(v)"; [[ $? == 0 && -z "$out" ]] || { echo "an empty config must pass"; exit 1; }
for bad in LLAMA_PORT=0 LLAMA_PORT=70000 LLAMA_PORT=80a LLAMA_CTX=-1 STRATA_CONTEXT=abc ENGINE=vllm \
           STRATA_KV=fp8 STRATA_VISION=maybe NVIDIA_POWER_LIMIT_W=50 NVIDIA_POWER_LIMIT_W=1001; do
  out="$(v "$bad")"; rc=$?
  [[ $rc == 1 && "$out" == "${bad%%=*}: "* ]] || { echo "$bad: rc=$rc out=[$out]"; exit 1; }
done
out="$(v ENGINE=strata STRATA_FAMILY=unsloth)"; rc=$?
[[ $rc == 1 && "$out" == "STRATA_MODEL: "* ]] || { echo "strata without model: rc=$rc out=[$out]"; exit 1; }
out="$(v ENGINE=strata STRATA_FAMILY=unsloth STRATA_MODEL=UD-Q5_K_XL STRATA_KV=k8v4 STRATA_VISION=gpu NVIDIA_POWER_LIMIT_W=400)"
[[ $? == 0 && -z "$out" ]] || { echo "a good strata config: $out"; exit 1; }
n="$(v LLAMA_PORT=0 ENGINE=x | wc -l)"; [[ "$n" == 2 ]] || { echo "two problems, $n lines"; exit 1; }
grep -q 'config validate\|validate' setup.sh || { echo "setup.sh does not know 'config validate'"; exit 1; }
'''


def task_repo(rev, prompt, check_script, run_tests=True):
    def setup(work):
        checkout(work, rev)
        return prompt, {}

    def check(work, state):
        f = os.path.join(work, ".bench-check.sh")
        with open(f, "w") as fh:
            fh.write(check_script)
        rc, out = sh(["bash", f, work], timeout=300)
        hidden = rc == 0
        msg = "hidden check passed" if hidden else "hidden check FAILED: " + out.strip()[-160:]
        if run_tests:
            ok, last = repo_tests(work)
            msg += f"; tests/run.sh: {last}"
            hidden = hidden and ok
        return hidden, msg
    return setup, check


TASKS = {
    "json-edit": task_config_edit("json"),
    "yaml-edit": task_config_edit("yaml"),
    "bugfix": task_repo("57a9089",
        "This is setup-ubuntu-ai, a Bash installer for a local LLM server. Bug report from a machine with Secure Boot "
        "enabled and NVIDIA_MOK_STRATEGY=canonical: `sudo ./setup.sh drivers` prints \"No Canonical-signed "
        "linux-modules-nvidia-595-open-generic in the archive — the DKMS module would need a MOK enrolled at a "
        "physical console\" and installs the DKMS module, whose key is rejected at boot. But `apt-cache policy "
        "linux-modules-nvidia-595-open-generic` on that machine shows `Candidate: 7.0.0-38.38+2`. Find the root cause "
        "in modules/20-drivers-nvidia.sh (and anything else with the same flaw), fix it, and add a regression test to "
        "tests/run.sh that fails without your fix. Run tests/run.sh; it must pass.",
        BUGFIX_CHECK),
    "refactor": task_repo("HEAD",
        "This is setup-ubuntu-ai. In setup.sh, _restore_rehome lists the path keys it re-homes twice, once per loop. "
        "Refactor it so the list exists once, without changing what it does, and add a test to tests/run.sh that a "
        "config whose LLAMA_MODEL, STRATA_DIR and STRATA_DATA_DIR live under another user's home gets them moved to "
        "this user's home (and leaves other keys alone). Run tests/run.sh; it must pass.",
        REFACTOR_CHECK),
    "feature": task_repo("HEAD", "This is setup-ubuntu-ai, a Bash installer. " + FEATURE_SPEC, FEATURE_CHECK),
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tasks", default=",".join(TASKS))
    ap.add_argument("--model", help="provider/model for opencode (default: its configured model)")
    ap.add_argument("--timeout", type=int, default=2400, help="seconds per task (default 40 min)")
    ap.add_argument("--keep", action="store_true", help="keep the work directories")
    ap.add_argument("--json", help="also write the results here")
    a = ap.parse_args()
    rows = []
    for name in a.tasks.split(","):
        setup, check = TASKS[name]
        base = tempfile.mkdtemp(prefix=f"ocbench-{name}-")
        work = os.path.join(base, "work")
        os.makedirs(work, exist_ok=True) if not name in ("bugfix", "refactor", "feature") else None
        try:
            prompt, state = setup(work)
            secs, rc, tokens, steps, text = agent(work, prompt, a.model, a.timeout)
            ok, msg = check(work, state)
        except Exception as e:
            secs, rc, tokens, steps, text, ok, msg = 0, "error", 0, 0, "", False, f"harness error: {e}"
        row = {"task": name, "pass": ok, "minutes": round(secs / 60, 1), "exit": rc, "steps": steps,
               "output_tokens": tokens, "detail": msg, "work": work}
        rows.append(row)
        print(json.dumps(row), flush=True)
        if name in ("bugfix", "refactor", "feature"):
            if not a.keep:
                sh(["git", "-C", REPO, "worktree", "remove", "--force", work])
        if not a.keep:
            shutil.rmtree(base, ignore_errors=True)
    passed = sum(r["pass"] for r in rows)
    print(f"\n{passed}/{len(rows)} tasks passed", flush=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rows, f, indent=1)
    sys.exit(0 if passed == len(rows) else 1)


if __name__ == "__main__":
    main()
