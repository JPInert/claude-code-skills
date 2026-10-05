#!/bin/bash
# ns2.sh <domain> -> prints the domain only if NO nameservers answer on three public resolvers.
# Prefilter only: no false negatives, some false positives (the WHOIS confirm step catches them).
d="$1"
a=$(dig +short +time=3 +tries=1 @1.1.1.1 NS "$d" 2>/dev/null)
[ -n "$a" ] && exit 0
b=$(dig +short +time=3 +tries=1 @8.8.8.8 NS "$d" 2>/dev/null)
[ -n "$b" ] && exit 0
c=$(dig +short +time=4 +tries=2 @9.9.9.9 NS "$d" 2>/dev/null)
[ -n "$c" ] && exit 0
echo "$d"
