#!/bin/bash
# usage: JOIN="fix hop desk" ./run_bank.sh wordsfile outprefix
# Crosses each word with each JOIN stem (both orders), dedupes against allchecked.txt,
# prefilters with ns2.sh at -P 20, confirms with w.sh at -P 3, and self-tests the
# instruments BEFORE and AFTER. Exits 3 and prints VOID if any self-test fails:
# a throttled checker reports false "available", so a failed after-test voids the batch.
set -e
D="$(cd "$(dirname "$0")" && pwd)"   # outputs + allchecked.txt stay in the CALLER's directory
W="$1"; P="$2"
[ -n "$W" ] && [ -n "$P" ] || { echo "usage: JOIN=\"stem1 stem2\" $0 wordsfile outprefix" >&2; exit 2; }
JOIN=${JOIN:-fix}
touch allchecked.txt
python3 - "$W" "$P" "$JOIN" <<'PY'
import sys
words=[w.strip().lower() for w in open(sys.argv[1]).read().split() if w.strip().isalpha()]
JOIN=sys.argv[3].split()
out=[]
for w in set(words):
    if not (3<=len(w)<=8): continue
    out.append(w)
    for j in JOIN:
        if w==j: continue
        for n in (w+j, j+w):
            if 5<=len(n)<=9: out.append(n)
out=[n+".com" for n in dict.fromkeys(out)]
open(sys.argv[2]+"_all.txt","w").write("\n".join(out)+"\n")
print(len(out),"generated")
PY
void() { echo "!! $1 - RESULTS VOID"; exit 3; }
grep -vxFf allchecked.txt "${P}_all.txt" > "${P}_new.txt" || true
echo "$(wc -l < "${P}_new.txt") new after dedupe"
[ -z "$("$D/ns2.sh" google.com)" ] || void "prefilter self-test failed BEFORE the run (google.com looked unregistered)"
[ -n "$("$D/ns2.sh" zzqxjfkdlqp123.com)" ] || void "prefilter self-test failed BEFORE the run (nonsense name looked registered)"
xargs -P 20 -n 1 "$D/ns2.sh" < "${P}_new.txt" > "${P}_nons.txt" 2>/dev/null || true
[ -z "$("$D/ns2.sh" google.com)" ] || void "prefilter THROTTLED during the run"
echo "$(wc -l < "${P}_nons.txt") candidates after prefilter"
[ "$("$D/w.sh" google.com)" = "TAKEN google.com" ] || void "whois self-test failed BEFORE confirm"
xargs -P 3 -n 1 "$D/w.sh" < "${P}_nons.txt" > "${P}_conf.txt" 2>/dev/null || true
[ "$("$D/w.sh" google.com)" = "TAKEN google.com" ] || void "whois THROTTLED during confirm (google.com not TAKEN)"
[ "$("$D/w.sh" zzqxjfkdlqp123.com)" = "FREE zzqxjfkdlqp123.com" ] || void "whois THROTTLED during confirm (nonsense not FREE)"
cat "${P}_new.txt" >> allchecked.txt
echo "FREE: $(grep -c '^FREE' "${P}_conf.txt" || true)   (self-tests passed at both ends)"
