#!/bin/bash
# w.sh <domain.com|domain.net> -> FREE / TAKEN / UNKW, via WHOIS port 43 at Verisign.
# Bash's /dev/tcp does not reliably resolve hostnames, so resolve to an IP first.
HOST=${WHOIS_HOST:-whois.verisign-grs.com}
IP=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1{print $1}')
[ -n "$IP" ] || { echo "UNKW $1 (cannot resolve $HOST)"; exit 1; }
d="$1"
for try in 1 2 3; do
  resp=$( (exec 3<>"/dev/tcp/$IP/43" && printf 'domain %s\r\n' "$d" >&3 && timeout 15 cat <&3) 2>/dev/null )
  if grep -qi "No match for" <<<"$resp"; then echo "FREE $d"; exit 0; fi
  if grep -qi "Domain Name:" <<<"$resp"; then echo "TAKEN $d"; exit 0; fi
  sleep 3
done
echo "UNKW $d"
