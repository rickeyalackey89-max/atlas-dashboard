import json
from pathlib import Path

p = Path("public/data/cloudflare_payload.json")
d = json.loads(p.read_text(encoding="utf-8"))
print("top keys:", list(d.keys()))
print()


def dump_slips(name, slips):
    if not slips:
        return
    if isinstance(slips, dict):
        for k, v in slips.items():
            dump_slips(f"{name}/{k}", v)
        return
    if isinstance(slips, list):
        print(f"{name}: {len(slips)} slips")
        if slips:
            s = slips[0]
            keys = [k for k in s.keys() if "prob" in k.lower() or k in ("ev", "payout_mult", "n_legs")]
            print(f"  first slip keys (probs): {keys}")
            for k in keys:
                print(f"    {k} = {s.get(k)}")


for key in d.keys():
    if "slip" in key.lower() or "recommend" in key.lower() or "marketed" in key.lower():
        dump_slips(key, d[key])
