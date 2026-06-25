#!/usr/bin/env python3
"""
config_edit_bench.py — measure how reliably a local (OpenAI-compatible) LLM
performs *surgical* edits on deeply-nested YAML and JSON.

The hard part isn't applying the change — it's reproducing a large nested
document verbatim while changing only the requested fields. Small / low-bit
models tend to silently drop or mutate a sibling field. This benchmark catches
exactly that: it builds a big config, asks for a handful of path-precise edits,
parses the model's output, flattens both expected and actual to leaf paths, and
flags ANY deviation across every leaf — not just the edited ones.

Usage:
  python3 config_edit_bench.py                      # both formats, 3 runs each
  python3 config_edit_bench.py --runs 5 --only json
  python3 config_edit_bench.py --services 8 --containers 5   # crank complexity
  python3 config_edit_bench.py --url http://127.0.0.1:8080/v1 --model local

Key resolution: --key, else $LLAMA_API_KEY, else parsed from
/etc/setup-ubuntu-ai/llama-server.env (the setup-ubuntu-ai service env).

Thinking models: their reasoning goes to message.reasoning_content; the final
document lands in message.content. Give a generous --max-tokens so the model
finishes reasoning AND re-emits the whole document (default 12000).
"""
import argparse, copy, json, re, subprocess, sys, urllib.request

try:
    import yaml
except ImportError:
    sys.exit("Need PyYAML:  pip install pyyaml   (or: apt install python3-yaml)")


# ----------------------------- API ---------------------------------------
def resolve_key(cli_key):
    if cli_key:
        return cli_key
    import os
    if os.environ.get("LLAMA_API_KEY"):
        return os.environ["LLAMA_API_KEY"]
    try:
        out = subprocess.check_output(
            "sudo grep -oP '(?<=--api-key )\\S+' /etc/setup-ubuntu-ai/llama-server.env",
            shell=True, stderr=subprocess.DEVNULL).decode().strip()
        return out or None
    except Exception:
        return None


def ask(url, key, model, prompt, max_tokens, timeout):
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content":
             "You are a precise config editor. Apply ONLY the requested changes "
             "by their exact paths. Preserve every other key, value and list item "
             "EXACTLY. Output ONLY the full modified document in one fenced code block."},
            {"role": "user", "content": prompt}],
        "temperature": 0.0, "max_tokens": max_tokens}).encode()
    hdr = {"Content-Type": "application/json"}
    if key:
        hdr["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url.rstrip("/") + "/chat/completions", body, hdr)
    j = json.load(urllib.request.urlopen(req, timeout=timeout))
    ch = j["choices"][0]
    return ch["message"]["content"], ch.get("finish_reason"), j["usage"]["completion_tokens"]


def code_block(t):
    m = re.search(r"```[a-zA-Z]*\n(.*?)```", t, re.S)
    if m:
        return m.group(1)
    # fall back to the outermost braces (JSON) if no fence
    i, jx = t.find("{"), t.rfind("}")
    return t[i:jx + 1] if 0 <= i < jx else t


def flatten(o, p=""):
    d = {}
    if isinstance(o, dict):
        for k, v in o.items():
            d.update(flatten(v, p + "/" + str(k)))
    elif isinstance(o, list):
        for i, v in enumerate(o):
            d.update(flatten(v, p + "/" + str(i)))
    else:
        d[p] = o
    return d


# ----------------------- document generators -----------------------------
def make_json(n_services):
    def svc(name, port, shards):
        return {
            "name": name,
            "network": {"port": port, "protocol": "https",
                        "timeouts": {"connectMs": 500, "readMs": 3000, "writeMs": 3000, "idleMs": 60000}},
            "database": {"engine": "postgres",
                         "primary": {"host": name + "-db-0", "port": 5432,
                                     "pool": {"min": 2, "max": 20, "acquireMs": 3000, "idleMs": 10000}},
                         "replicas": [{"host": "%s-db-r%d" % (name, i), "port": 5432, "weight": 1, "readOnly": True} for i in range(2)],
                         "shards": {"shard%d" % j: {"range": [j * 100, (j + 1) * 100 - 1], "node": "%s-shard-%d" % (name, j)} for j in range(shards)}},
            "cache": {"provider": "redis",
                      "nodes": [{"host": "%s-cache-%d" % (name, i), "port": 6379, "role": "primary" if i == 0 else "replica"} for i in range(2)],
                      "ttl": {"default": 60, "long": 3600, "short": 10}, "eviction": "lru"},
            "resilience": {"retries": {"max": 3, "backoffMs": 200, "jitter": True},
                           "circuitBreaker": {"enabled": True, "threshold": 0.5, "windowSec": 30, "halfOpenAfterSec": 15},
                           "rateLimit": {"rps": 100, "burst": 150, "perClient": {"rps": 10, "burst": 20}}},
            "auth": {"required": True, "scopes": [name + ":read", name + ":write"],
                     "jwt": {"issuer": "https://auth.local", "audience": name, "leewaySec": 30}},
            "features": {"flags": {"newPipeline": False, "betaUi": True, "experimentalCache": False},
                         "rollout": {"percent": 25, "cohort": "internal"}},
            "observability": {"metrics": {"enabled": True, "intervalSec": 15, "histogramBuckets": [0.1, 0.5, 1, 2.5, 5]},
                              "tracing": {"enabled": True, "sampler": {"type": "ratio", "ratio": 0.1}},
                              "logging": {"level": "info", "json": True, "redactFields": ["password", "token"]}},
            "endpoints": [{"path": "/%s/v1/items" % name, "methods": ["GET", "POST"], "auth": {"required": True, "scopes": [name + ":read"]}},
                          {"path": "/%s/v1/items/:id" % name, "methods": ["GET", "PUT", "DELETE"], "auth": {"required": True, "scopes": [name + ":write"]}}]}
    names = ["orders", "payments", "inventory", "shipping", "catalog", "search", "billing", "notifications"][:max(2, n_services)]
    doc = {"apiVersion": "platform/v2",
           "metadata": {"name": "core-platform", "env": "production", "owner": "infra",
                        "labels": {"team": "infra", "costCenter": "cc-42"}},
           "global": {"region": "us-east-1",
                      "tls": {"minVersion": "1.2", "ciphers": ["TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384"]},
                      "cors": {"allowedOrigins": ["https://app.local"], "allowedMethods": ["GET", "POST", "PUT", "DELETE"], "maxAgeSec": 600}},
           "services": {nm: svc(nm, 8000 + i, 2 + i % 2) for i, nm in enumerate(names)}}
    exp = copy.deepcopy(doc)
    exp["services"][names[0]]["database"]["primary"]["pool"]["max"] = 50
    exp["services"][names[1]]["features"]["flags"]["newPipeline"] = True
    exp["services"][names[0]]["cache"]["ttl"]["medium"] = 600
    exp["services"][names[2 % len(names)]]["resilience"]["circuitBreaker"]["threshold"] = 0.7
    exp["global"]["tls"]["minVersion"] = "1.3"
    prompt = ("Edit this JSON. Apply EXACTLY these 5 changes and nothing else:\n"
              "1) services.%s.database.primary.pool.max -> 50\n"
              "2) services.%s.features.flags.newPipeline -> true\n"
              "3) add new key services.%s.cache.ttl.medium with value 600\n"
              "4) services.%s.resilience.circuitBreaker.threshold -> 0.7\n"
              "5) global.tls.minVersion -> \"1.3\"\n"
              "Keep ALL other keys, values and list items identical.\n\n```json\n"
              % (names[0], names[1], names[0], names[2 % len(names)])
              + json.dumps(doc, indent=2) + "\n```")
    return doc, exp, prompt, json.loads


def make_yaml(n_containers):
    def cont(name, img, port):
        return {"name": name, "image": img, "imagePullPolicy": "IfNotPresent",
                "ports": [{"containerPort": port, "name": "http", "protocol": "TCP"}],
                "env": [{"name": "LOG_LEVEL", "value": "info"}, {"name": "DB_HOST", "value": name + "-db"},
                        {"name": "DB_PORT", "value": "5432"}, {"name": "CACHE_HOST", "value": name + "-cache"}],
                "envFrom": [{"configMapRef": {"name": name + "-config"}}, {"secretRef": {"name": name + "-secrets"}}],
                "resources": {"requests": {"cpu": "250m", "memory": "256Mi"}, "limits": {"cpu": "500m", "memory": "512Mi"}},
                "livenessProbe": {"httpGet": {"path": "/healthz", "port": port}, "initialDelaySeconds": 10, "periodSeconds": 15, "timeoutSeconds": 3, "failureThreshold": 3},
                "readinessProbe": {"httpGet": {"path": "/ready", "port": port}, "initialDelaySeconds": 5, "periodSeconds": 10, "timeoutSeconds": 2, "successThreshold": 1},
                "volumeMounts": [{"name": "config", "mountPath": "/etc/app", "readOnly": True}, {"name": "data", "mountPath": "/var/data"}],
                "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}}
    cnames = ["api", "worker", "sidecar", "metrics", "proxy", "cron"][:max(2, n_containers)]
    doc = {"apiVersion": "apps/v1", "kind": "Deployment",
           "metadata": {"name": "payment-stack", "namespace": "prod",
                        "labels": {"app": "payment", "tier": "backend", "version": "1.4.2"},
                        "annotations": {"prometheus.io/scrape": "true", "prometheus.io/port": "9090"}},
           "spec": {"replicas": 3, "revisionHistoryLimit": 5,
                    "selector": {"matchLabels": {"app": "payment"}},
                    "strategy": {"type": "RollingUpdate", "rollingUpdate": {"maxSurge": 1, "maxUnavailable": 0}},
                    "template": {"metadata": {"labels": {"app": "payment", "tier": "backend"}, "annotations": {"sidecar.istio.io/inject": "true"}},
                                 "spec": {"serviceAccountName": "payment-sa", "terminationGracePeriodSeconds": 30,
                                          "initContainers": [cont("migrate", "registry.local/migrate:1.4.2", 8081)],
                                          "containers": [cont(n, "registry.local/payment-%s:1.4.2" % n, 8080 + i) for i, n in enumerate(cnames)],
                                          "affinity": {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": {"nodeSelectorTerms": [{"matchExpressions": [{"key": "disktype", "operator": "In", "values": ["ssd"]}, {"key": "region", "operator": "In", "values": ["us-east-1"]}]}]}},
                                                       "podAntiAffinity": {"preferredDuringSchedulingIgnoredDuringExecution": [{"weight": 100, "podAffinityTerm": {"labelSelector": {"matchLabels": {"app": "payment"}}, "topologyKey": "kubernetes.io/hostname"}}]}},
                                          "tolerations": [{"key": "dedicated", "operator": "Equal", "value": "payment", "effect": "NoSchedule"}],
                                          "topologySpreadConstraints": [{"maxSkew": 1, "topologyKey": "topology.kubernetes.io/zone", "whenUnsatisfiable": "DoNotSchedule", "labelSelector": {"matchLabels": {"app": "payment"}}}],
                                          "volumes": [{"name": "config", "configMap": {"name": "payment-config"}}, {"name": "data", "emptyDir": {"sizeLimit": "1Gi"}}]}}}}

    def c(d, n):
        return [x for x in d["spec"]["template"]["spec"]["containers"] if x["name"] == n][0]
    worker = cnames[1]
    exp = copy.deepcopy(doc)
    c(exp, "api")["resources"]["limits"]["memory"] = "1Gi"
    exp["spec"]["replicas"] = 5
    c(exp, worker)["env"].append({"name": "LOG_FORMAT", "value": "json"})
    exp["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] = 1
    c(exp, "api")["livenessProbe"]["failureThreshold"] = 5
    ystr = yaml.safe_dump(doc, sort_keys=False, default_flow_style=False)
    prompt = ("Edit this Kubernetes YAML. Apply EXACTLY these 5 changes and nothing else:\n"
              "1) container named 'api': resources.limits.memory -> 1Gi\n"
              "2) spec.replicas -> 5\n"
              "3) container named '%s': append a new env var name=LOG_FORMAT value=json\n"
              "4) spec.strategy.rollingUpdate.maxUnavailable -> 1\n"
              "5) container named 'api': livenessProbe.failureThreshold -> 5\n"
              "Do not change any other container or field.\n\n```yaml\n" % worker + ystr + "```")
    return doc, exp, prompt, yaml.safe_load


# ------------------------------- run -------------------------------------
def run_case(label, doc, exp, prompt, parse, args, key):
    fe = flatten(exp)
    n_leaves = len(flatten(doc))
    print("\n== %s ==  (%d leaf fields, 5 surgical edits)" % (label, n_leaves))
    ok = 0
    for i in range(args.runs):
        try:
            txt, fr, tk = ask(args.url, key, args.model, prompt, args.max_tokens, args.timeout)
            got = parse(code_block(txt))
            fg = flatten(got)
            bad = [k for k in set(fe) | set(fg) if fe.get(k) != fg.get(k)]
            if not bad:
                ok += 1
                print("  run %d: OK   (tokens=%d, finish=%s)" % (i + 1, tk, fr))
            else:
                print("  run %d: FAIL %d deviation(s): %s%s (tokens=%d, finish=%s)"
                      % (i + 1, len(bad), bad[:5], " ..." if len(bad) > 5 else "", tk, fr))
        except Exception as e:
            print("  run %d: ERROR %s" % (i + 1, str(e)[:80]))
    print("  -> %s: %d/%d exact" % (label, ok, args.runs))
    return ok


def main():
    ap = argparse.ArgumentParser(description="Nested YAML/JSON surgical-edit reliability benchmark.")
    ap.add_argument("--url", default="http://127.0.0.1:8080/v1", help="OpenAI-compatible base URL")
    ap.add_argument("--model", default="local", help="model id (any string for single-model llama-server)")
    ap.add_argument("--key", default=None, help="API key (else $LLAMA_API_KEY, else llama-server.env)")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--max-tokens", type=int, default=12000, help="raise for thinking models")
    ap.add_argument("--timeout", type=int, default=600)
    ap.add_argument("--services", type=int, default=4, help="JSON complexity (number of services)")
    ap.add_argument("--containers", type=int, default=3, help="YAML complexity (number of containers)")
    ap.add_argument("--only", choices=["json", "yaml", "both"], default="both")
    args = ap.parse_args()
    key = resolve_key(args.key)

    print("Endpoint: %s   Model: %s   Runs: %d   max_tokens: %d" % (args.url, args.model, args.runs, args.max_tokens))
    results = {}
    if args.only in ("json", "both"):
        results["JSON"] = run_case("JSON", *make_json(args.services), args=args, key=key)
    if args.only in ("yaml", "both"):
        results["YAML"] = run_case("YAML", *make_yaml(args.containers), args=args, key=key)
    print("\n=== SUMMARY ===")
    for k, v in results.items():
        print("  %-5s %d/%d exact" % (k, v, args.runs))


if __name__ == "__main__":
    main()
