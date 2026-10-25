#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: $0 OUTDIR [DOMAIN]" >&2
	exit 2
}

[[ $# -ge 1 ]] || usage
out=$1
domain=${2:-example.org}
days=30

mkdir -p "$out"
umask 077

if [[ -s "$out/cert.pem" && -s "$out/key.pem" && -s "$out/ca.pem" ]]; then
	echo "TLS material already present in $out"
	exit 0
fi

openssl ecparam -name prime256v1 -genkey -noout -out "$out/ca.key"
openssl req -x509 -new -key "$out/ca.key" -sha256 -days "$days" \
	-subj "/CN=Benchmark Lab CA" \
	-addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign" \
	-out "$out/ca.pem"

openssl ecparam -name prime256v1 -genkey -noout -out "$out/key.pem.tmp"
openssl pkcs8 -topk8 -nocrypt -in "$out/key.pem.tmp" -out "$out/key.pem"
rm -f "$out/key.pem.tmp"

cat >"$out/leaf.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${domain},DNS:*.${domain},DNS:mail.${domain}
EOF

openssl req -new -key "$out/key.pem" -subj "/CN=mail.${domain}" -out "$out/leaf.csr"
openssl x509 -req -in "$out/leaf.csr" -CA "$out/ca.pem" -CAkey "$out/ca.key" \
	-CAcreateserial -sha256 -days "$days" -extfile "$out/leaf.ext" -out "$out/leaf.pem"
cat "$out/leaf.pem" "$out/ca.pem" >"$out/cert.pem"
rm -f "$out/leaf.csr" "$out/leaf.ext" "$out/ca.srl" "$out/ca.key"
chmod 0644 "$out/cert.pem" "$out/leaf.pem" "$out/ca.pem"
chmod 0600 "$out/key.pem"
echo "TLS material written to $out (cert.pem = leaf + CA chain, key.pem, ca.pem)"
