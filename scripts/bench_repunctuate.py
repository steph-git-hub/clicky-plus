#!/usr/bin/env python3
"""Full eval: local qwen3.5-4b (app's :8841 server) vs worker Haiku.
50 real dictations, latency percentiles, quality + word-preservation."""
import json, time, urllib.request, random, re, statistics as st

WORKER = "https://clicky-proxy.sapierso.workers.dev/repunctuate"
LOCAL = "http://127.0.0.1:8841/v1/chat/completions"

def post(url, body, timeout=90):
    req = urllib.request.Request(url, json.dumps(body).encode(),
        {"content-type": "application/json", "User-Agent": "Clicky/1.0"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()), time.time() - t0

SYS = post(WORKER, {"promptOnly": True})[0]["prompt"]

rows = []
for day in ['2026-06-02','2026-06-03','2026-06-04','2026-06-05','2026-06-06']:
    try:
        p = f'/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/transcripts/{day}.jsonl'
        for line in open(p):
            try: r = json.loads(line)
            except: continue
            raw = (r.get('rawTranscript') or '').strip()
            if r.get('mode') in ('vtt_hold','vtt_toggle') and 8 <= len(raw.split()) <= 100:
                rows.append(raw)
    except FileNotFoundError: pass

random.seed(7)
sample = random.sample(list(dict.fromkeys(rows)), min(50, len(rows)))
print(f"{len(rows)} rows pooled, testing {len(sample)} unique\n")

def run_local(text):
    body = {"model": "qwen3.5-4b", "temperature": 0, "max_tokens": 1024,
            "messages": [{"role": "system", "content": SYS},
                         {"role": "user", "content": text}],
            "chat_template_kwargs": {"enable_thinking": False}}
    r, dt = post(LOCAL, body)
    return r["choices"][0]["message"]["content"].strip(), dt

def run_worker(text):
    r, dt = post(WORKER, {"text": text})
    return r["output"].strip(), dt

run_local("warm up.")

EXP = {"wanna":"want to","gonna":"going to","gotta":"got to","kinda":"kind of",
       "sorta":"sort of","outta":"out of","lemme":"let me","gimme":"give me",
       "dunno":"don't know","tryna":"trying to","shoulda":"should have",
       "coulda":"could have","woulda":"would have","yep":"yes","nope":"no"}
norm = lambda s: re.sub(r"[^a-z0-9' ]", " ", s.lower()).split()
def viol(out, src):
    expanded = src
    for k, v in EXP.items(): expanded = re.sub(rf"\b{k}\b", v, expanded, flags=re.I)
    return norm(out) != norm(src) and norm(out) != norm(expanded)

lts, wts = [], []
same = 0
lviol, wviol = [], []
for i, text in enumerate(sample):
    lo, lt = run_local(text)
    wo, wt = run_worker(text)
    lts.append(lt); wts.append(wt)
    if lo == wo: same += 1
    if viol(lo, text): lviol.append((i, text, lo))
    if viol(wo, text): wviol.append((i, text, wo))

def pct(xs, p): return sorted(xs)[max(0, int(round(p/100*len(xs)))-1)]
n = len(sample)
print(f"identical: {same}/{n} ({100*same/n:.0f}%)")
print(f"word-preservation violations: local {len(lviol)}, haiku {len(wviol)}")
for tag, xs in [("LOCAL", lts), ("HAIKU", wts)]:
    print(f"{tag}: mean {st.mean(xs):.2f}s  p50 {pct(xs,50):.2f}s  p90 {pct(xs,90):.2f}s  p99 {pct(xs,99):.2f}s  max {max(xs):.2f}s")
print("\n-- local violations (first 5):")
for i, t, o in lviol[:5]:
    print(f"  IN:  {t[:110]}\n  OUT: {o[:110]}\n")
print("-- haiku violations (first 5):")
for i, t, o in wviol[:5]:
    print(f"  IN:  {t[:110]}\n  OUT: {o[:110]}\n")
