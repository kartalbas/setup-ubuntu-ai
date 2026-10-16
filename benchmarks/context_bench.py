#!/usr/bin/env python3
"""
context_bench.py — prompt and answer speed of the running server at growing
context lengths, with a needle-in-a-haystack check at each length.

For every length it sends one long document with a fact hidden at a random
depth and asks for it (prompt reading + recall), then a follow-up turn in the
same conversation that asks for a ~300-token answer (prompt-cache reuse +
writing speed at that depth). Each length uses its own document, so no run
reuses another's cache. Also reported: what the disk read meanwhile (Strata
reads its lookup table from the SSD while it answers) and RAM/VRAM in use.

Usage:
  python3 context_bench.py                              # 4k 32k 128k 256k
  python3 context_bench.py --lengths 4096,65536 --url http://127.0.0.1:8080/v1
  python3 context_bench.py --disk sda                   # the disk to watch

Key resolution: --key, else $LLAMA_API_KEY, else read (via sudo) from
/etc/setup-ubuntu-ai/api-key (the setup-ubuntu-ai service credential).
Speeds come from the server's own "timings" (llama.cpp's and Strata's field);
without it, from the wall clock.
"""
import argparse, json, os, random, subprocess, sys, time, urllib.request

WORDS = ("account ledger invoice region warehouse shipment carrier customs depot route tariff pallet "
         "container manifest supplier contract quota audit forecast backlog margin rebate freight "
         "dispatch inventory batch serial vendor clause renewal deadline buffer threshold").split()


def resolve_key(cli_key):
    if cli_key:
        return cli_key
    if os.environ.get("LLAMA_API_KEY"):
        return os.environ["LLAMA_API_KEY"]
    try:
        return subprocess.check_output(["sudo", "head", "-1", "/etc/setup-ubuntu-ai/api-key"],
                                       stderr=subprocess.DEVNULL).decode().strip() or None
    except Exception:
        return None


def haystack(n_chars, rng, needle):
    """Plausible business records (no repetition a cache could share) with the needle at a random depth."""
    lines, size, i = [], 0, 0
    while size < n_chars:
        i += 1
        w = rng.sample(WORDS, 6)
        line = (f"Record {i:06d}: the {w[0]} for {w[1]} {rng.randint(100, 99999)} moved to {w[2]} "
                f"{rng.choice('ABCDEFGHJK')}{rng.randint(1, 99)} after the {w[3]} review; {w[4]} "
                f"{rng.randint(1, 9999)} units, {w[5]} {rng.randint(1, 365)} days.")
        lines.append(line)
        size += len(line) + 1
    depth = rng.uniform(0.1, 0.9)
    lines.insert(int(len(lines) * depth), needle)
    return "\n".join(lines), depth


def chat(url, key, messages, max_tokens, timeout):
    body = json.dumps({"model": "bench", "messages": messages, "max_tokens": max_tokens,
                       "temperature": 0.0, "reasoning_effort": "none",
                       "chat_template_kwargs": {"enable_thinking": False}}).encode()
    hdr = {"Content-Type": "application/json"}
    if key:
        hdr["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url.rstrip("/") + "/chat/completions", body, hdr)
    t0 = time.time()
    j = json.load(urllib.request.urlopen(req, timeout=timeout))
    return j, time.time() - t0


def disk_read_bytes(dev):
    try:
        with open(f"/sys/block/{dev}/stat") as f:
            return int(f.read().split()[2]) * 512
    except OSError:
        return None


def mem_state():
    used = None
    try:
        info = dict(l.split(":", 1) for l in open("/proc/meminfo"))
        kb = lambda k: int(info[k].split()[0])
        used = (kb("MemTotal") - kb("MemAvailable")) / 1048576
    except Exception:
        pass
    vram = None
    try:
        vram = int(subprocess.check_output(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
                                           stderr=subprocess.DEVNULL).decode().split()[0])
    except Exception:
        pass
    return used, vram


def speeds(j, wall):
    t = j.get("timings") or {}
    u = j.get("usage") or {}
    pp = t.get("prompt_per_second")
    tg = t.get("predicted_per_second")
    if tg is None and u.get("completion_tokens"):
        tg = u["completion_tokens"] / wall
    return pp, tg, t.get("cache_n", (u.get("prompt_tokens_details") or {}).get("cached_tokens")), u


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1")
    ap.add_argument("--key")
    ap.add_argument("--lengths", default="4096,32768,131072,253952",
                    help="target prompt tokens, comma-separated (default ends just below 262,144 to leave room)")
    ap.add_argument("--disk", default="sda", help="block device to count reads on (default sda)")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--timeout", type=int, default=3600)
    ap.add_argument("--json", help="also write the results here")
    a = ap.parse_args()
    key = resolve_key(a.key)
    rng = random.Random(a.seed)
    chars_per_token = 3.6                           # corrected after the first request
    rows = []
    print(f"{'target':>8} {'prompt':>8} {'read tok/s':>10} {'needle':>7} {'depth':>6} {'cached':>8} "
          f"{'write tok/s':>11} {'disk GB':>8} {'RAM GiB':>8} {'VRAM MiB':>9}", flush=True)
    for target in [int(x) for x in a.lengths.split(",")]:
        code = str(rng.randint(100000, 999999))
        name = f"{rng.choice(WORDS).title()}-{rng.randint(10, 99)}"
        needle = f"Note for the auditors: the access code of project {name} is {code}."
        doc, depth = haystack(int(target * chars_per_token), rng, needle)
        q = f"What is the access code of project {name}? Answer with the number only."
        msgs = [{"role": "user", "content": f"Here is a document.\n\n{doc}\n\n{q}"}]
        d0 = disk_read_bytes(a.disk)
        j1, w1 = chat(a.url, key, msgs, 32, a.timeout)
        ans = (j1["choices"][0]["message"].get("content") or "").strip()
        pp, _, _, u1 = speeds(j1, w1)
        if pp is None:
            pp = u1.get("prompt_tokens", 0) / w1
        if u1.get("prompt_tokens"):
            chars_per_token = len(msgs[0]["content"]) / u1["prompt_tokens"]
        msgs += [{"role": "assistant", "content": ans},
                 {"role": "user", "content": "Now write about 250 words: how should a warehouse plan its "
                                             "pallet buffer before a customs deadline? Plain prose."}]
        j2, w2 = chat(a.url, key, msgs, 400, a.timeout)
        _, tg, cached, _ = speeds(j2, w2)
        d1 = disk_read_bytes(a.disk)
        ram, vram = mem_state()
        row = {"target": target, "prompt_tokens": u1.get("prompt_tokens"), "prompt_per_s": round(pp, 1),
               "needle_ok": code in ans, "answer": ans[:40], "depth": round(depth, 2), "followup_cached": cached,
               "write_per_s": round(tg, 1) if tg else None,
               "disk_read_gb": round((d1 - d0) / 1e9, 2) if d0 is not None and d1 is not None else None,
               "ram_used_gib": round(ram, 1) if ram else None, "vram_used_mib": vram,
               "prompt_wall_s": round(w1, 1)}
        rows.append(row)
        print(f"{target:>8} {row['prompt_tokens'] or '?':>8} {row['prompt_per_s']:>10} "
              f"{'ok' if row['needle_ok'] else 'MISS':>7} {row['depth']:>6} {str(cached):>8} "
              f"{str(row['write_per_s']):>11} {str(row['disk_read_gb']):>8} {str(row['ram_used_gib']):>8} "
              f"{str(vram):>9}", flush=True)
        if not row["needle_ok"]:
            print(f"         answer was: {ans!r}", flush=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rows, f, indent=1)
    sys.exit(0 if all(r["needle_ok"] for r in rows) else 1)


if __name__ == "__main__":
    main()
