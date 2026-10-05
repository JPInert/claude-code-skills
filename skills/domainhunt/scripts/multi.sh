#!/bin/bash
# multi.sh <domain.tld> -> FREE / TAKEN / UNK / NOENDPOINT via registry-direct RDAP.
# Refresh the table from https://data.iana.org/rdap/dns.json. .co has no working endpoint.
declare -A B=(
 [cc]="https://tld-rdap.verisign.com/cc/v1/domain/"
 [dev]="https://pubapi.registry.google/rdap/domain/"
 [link]="https://rdap.uniregistry.net/rdap/domain/"
 [fyi]="https://rdap.identitydigital.services/rdap/domain/"
 [click]="https://rdap.registry.click/rdap/domain/"
 [org]="https://rdap.publicinterestregistry.org/rdap/domain/"
 [net]="https://rdap.verisign.com/net/v1/domain/"
 [xyz]="https://rdap.centralnic.com/xyz/domain/"
 [app]="https://pubapi.registry.google/rdap/domain/"
)
d="$1"; t="${d##*.}"; b="${B[$t]}"
[ -z "$b" ] && { echo "NOENDPOINT $d"; exit; }
for i in 1 2 3; do
  c=$(curl -sL -m 20 -o /dev/null -w "%{http_code}" "$b$d")
  case "$c" in 404) echo "FREE $d"; exit;; 200) echo "TAKEN $d"; exit;; esac
  sleep 2
done
echo "UNK$c $d"
