#!/usr/bin/env python3
"""Polish bench: local qwen3.5-4b vs worker Haiku on real logged dictations.
Two styles: rewrite (toggle) and preserve (polish hotkey). Text-only, no
screenshot, no personal facts — identical context for both engines."""
import json, time, urllib.request, random

VC = "https://clicky-proxy.sapierso.workers.dev/voice-command"
LOCAL = "http://127.0.0.1:8841/v1/chat/completions"

def post(url, body, timeout=120):
    req = urllib.request.Request(url, json.dumps(body).encode(),
        {"content-type": "application/json", "User-Agent": "Clicky/1.0"})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read()), time.time() - t0

def get_prompt(text, style):
    r, _ = post(VC, {"command": "polish", "fieldText": text,
                     "polishStyle": style, "promptOnly": True})
    return r["prompt"], r["userText"]

def run_local(system, user):
    body = {"model": "qwen3.5-4b", "temperature": 0, "max_tokens": 2048,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user}],
            "chat_template_kwargs": {"enable_thinking": False}}
    r, dt = post(LOCAL, body)
    return r["choices"][0]["message"]["content"].strip(), dt

def run_haiku(text, style):
    r, dt = post(VC, {"command": "polish", "fieldText": text,
                      "polishStyle": style,
                      "model": "claude-haiku-4-5-20251001"})
    return r["output"].strip(), dt

# pull real cases from the transcript log
toggle, hold = [], []
for day in ['2026-06-03','2026-06-04','2026-06-05','2026-06-06']:
    try:
        p = f'/Users/stephenpierson/Desktop/Claude Cowork/Obsidian/Steph Vault/Clicky Logs/transcripts/{day}.jsonl'
        for line in open(p):
            try: r = json.loads(line)
            except: continue
            raw = (r.get('rawTranscript') or '').strip()
            if not (15 <= len(raw.split()) <= 120): continue
            if r.get('mode') == 'vtt_toggle': toggle.append(raw)
            elif r.get('mode') == 'polish': hold.append(raw)
    except FileNotFoundError: pass

random.seed(11)
cases = [(t, "rewrite") for t in random.sample(list(dict.fromkeys(toggle)), min(8, len(toggle)))] \
      + [(t, "preserve") for t in random.sample(list(dict.fromkeys(hold)), min(4, len(hold)))]
print(f"{len(toggle)} toggle / {len(hold)} preserve pooled; testing {len(cases)}\n")

out = open('/tmp/polish_bench_results.md', 'w')
lts, wts = [], []
for i, (text, style) in enumerate(cases):
    system, user = get_prompt(text, style)
    lo, lt = run_local(system, user)
    wo, wt = run_haiku(text, style)
    lts.append(lt); wts.append(wt)
    out.write(f"## case {i} [{style}] local {lt:.2f}s / haiku {wt:.2f}s\n\n")
    out.write(f"**IN:** {text}\n\n**LOCAL:** {lo}\n\n**HAIKU:** {wo}\n\n---\n\n")
    print(f"case {i} [{style}] local {lt:.2f}s / haiku {wt:.2f}s")
out.close()
import statistics as st
print(f"\navg latency: local {st.mean(lts):.2f}s, haiku {st.mean(wts):.2f}s")
print("full side-by-side: /tmp/polish_bench_results.md")
