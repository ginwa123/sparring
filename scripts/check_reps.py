import json
import sys

d = json.load(open("results/bench_results.json"))
total = 0
ok = True
for fw in d["endpoints"]:
    for ep in d["endpoints"][fw]:
        n = d["endpoints"][fw][ep]["reps"]
        total += n
        if n != 3:
            print("BAD", fw, ep, n)
            ok = False
print("all cells have 3 reps, total runs:", total if ok else "INCOMPLETE")
