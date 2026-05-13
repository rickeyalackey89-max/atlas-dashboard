import json
d = json.load(open("public/data/cloudflare_payload.json", encoding="utf8"))
for key in ["system", "windfall", "demonhunter", "gamescript", "top_hit_list", "marketed_slips"]:
    v = d.get(key)
    if isinstance(v, dict):
        for k2, slips in v.items():
            if isinstance(slips, list) and slips:
                for s in slips[:3]:
                    print(f"{key}/{k2}: legs={s.get('n_legs')} hit_prob={s.get('hit_prob'):.4f} payout={s.get('payout_mult')}")
    elif isinstance(v, list) and v:
        for s in v[:3]:
            print(f"{key}: legs={s.get('n_legs')} hit_prob={s.get('hit_prob'):.4f} payout={s.get('payout_mult')}")
