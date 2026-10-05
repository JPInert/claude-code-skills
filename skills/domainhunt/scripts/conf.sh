#!/bin/bash
# conf.sh <domain.com> -> FREE / TAKEN / UNK<http code>, via Verisign RDAP. Blocks above -P 4.
d="$1"
code=$(curl -sL -m 20 -o /dev/null -w "%{http_code}" "https://rdap.verisign.com/com/v1/domain/$d")
case "$code" in 404) echo "FREE $d";; 200) echo "TAKEN $d";; *) echo "UNK$code $d";; esac
