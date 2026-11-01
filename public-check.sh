#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: bash public-check.sh <domain> [https-port ...]" >&2
  echo "Run from a different Linux machine, not from the VPN node." >&2
}

if (( $# < 1 )); then
  usage
  exit 2
fi

domain=${1,,}
shift
if [[ $domain != *.* || $domain == .* || $domain == *. ||
      $domain == *..* || ! $domain =~ ^[a-z0-9.-]+$ ]]; then
  usage
  exit 2
fi

if (( $# == 0 )); then
  ports=(443)
else
  ports=("$@")
fi
for port in "${ports[@]}"; do
  if [[ ! $port =~ ^[0-9]+$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "Error: invalid HTTPS port: $port" >&2
    exit 2
  fi
done
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 2
fi
if ! command -v getent >/dev/null 2>&1; then
  echo "Error: getent is required to resolve the domain." >&2
  exit 2
fi

failed=0
echo "Public self-steal check: $domain"
if dns_ips=$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u) &&
   [[ -n $dns_ips ]]; then
  printf 'IPv4 resolution: [OK]\n%s\n' "$dns_ips"
else
  echo "IPv4 resolution: [FAIL] (check the public A record)"
  failed=1
fi

if http_result=$(curl -4sS --noproxy '*' --connect-timeout 5 --max-time 15 \
  -o /dev/null -w '%{http_code}|%{redirect_url}|%{remote_ip}' \
  "http://$domain/"); then
  IFS='|' read -r http_code redirect_url http_ip <<< "$http_result"
  if [[ -n $http_ip ]]; then
    echo "HTTP connected IPv4: $http_ip"
  else
    echo "HTTP connected IPv4: unavailable [FAIL]"
    failed=1
  fi
  if [[ $http_code == 301 && $redirect_url == "https://$domain/" ]]; then
    echo "HTTP :80 redirect: [OK]"
  else
    echo "HTTP :80 redirect: [FAIL] (HTTP $http_code, Location: ${redirect_url:-none})"
    failed=1
  fi
else
  echo "HTTP :80: [FAIL] (check DNS and public TCP/80)"
  failed=1
fi

for port in "${ports[@]}"; do
  if https_result=$(curl -4fsS --noproxy '*' --connect-timeout 5 --max-time 15 \
    --tlsv1.3 --tls-max 1.3 -o /dev/null \
    -w '%{http_code}|%{remote_ip}|%{ssl_verify_result}' \
    "https://$domain:$port/"); then
    IFS='|' read -r https_code https_ip tls_verify <<< "$https_result"
    if [[ $https_code == 200 && $tls_verify == 0 && -n $https_ip ]]; then
      echo "HTTPS :$port (TLS 1.3, trusted certificate): [OK] ($https_ip)"
    else
      echo "HTTPS :$port: [FAIL] (HTTP $https_code, TLS verification $tls_verify)"
      failed=1
    fi
  else
    echo "HTTPS :$port: [FAIL] (check the public inbound, SNI and firewall)"
    failed=1
  fi
done

if (( failed != 0 )); then
  echo "PUBLIC SELF-STEAL INCOMPLETE" >&2
  exit 1
fi
echo "PUBLIC SELF-STEAL READY"
