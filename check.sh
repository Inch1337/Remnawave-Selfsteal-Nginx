#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/install.sh"

STATE_DIR=/etc/remnawave-selfsteal
STATE_FILE=$STATE_DIR/state.conf
if [[ -L $STATE_DIR || -L $STATE_FILE || ! -f $STATE_FILE ]]; then
  echo "Error: valid installation state is missing." >&2
  exit 1
fi
mapfile -t state_lines < "$STATE_FILE"
if (( ${#state_lines[@]} != 3 )) ||
   [[ ${state_lines[0]} != DOMAIN=* ||
      ${state_lines[1]} != TARGET_PORT=9443 ||
      ${state_lines[2]} != VERSION=0.1.0 ]]; then
  echo "Error: invalid installation state." >&2
  exit 1
fi
domain=${state_lines[0]#DOMAIN=}
if ! valid_domain "$domain"; then
  echo "Error: invalid domain in installation state." >&2
  exit 1
fi

failed=0
report() {
  local label=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf '%-23s [OK]\n' "$label"
  else
    printf '%-23s [FAIL]\n' "$label"
    failed=1
  fi
}

check_ubuntu() {
  local ID VERSION_ID
  . /etc/os-release
  [[ $ID == ubuntu && $VERSION_ID == 24.04 ]]
}

check_dns() {
  local ip a_result addresses aaaa_result
  ip=$(curl -4fsS --max-time 10 https://api.ipify.org) || return 1
  a_result=$(LC_ALL=C resolvectl --legend=no --cache=no --synthesize=no \
    --protocol=dns --type=A query "$domain" 2>&1) || return 1
  addresses=$(awk '$2 == "IN" && $3 == "A" {print $4}' <<< "$a_result" | sort -u)
  [[ $addresses == "$ip" ]] || return 1
  if aaaa_result=$(LC_ALL=C resolvectl --legend=no --cache=no --synthesize=no \
    --protocol=dns --type=AAAA query "$domain" 2>&1); then
    return 1
  fi
  [[ $aaaa_result == *"does not have any RR of the requested type"* ]]
}

check_http_site() {
  local file=/etc/nginx/sites-available/remnawave-selfsteal.conf
  local link=/etc/nginx/sites-enabled/remnawave-selfsteal.conf
  check_directory_path "${file%/*}" &&
    check_directory_path "${link%/*}" || return 1
  [[ -f $file && ! -L $file && -L $link ]] &&
    [[ $(readlink -- "$link") == ../sites-available/remnawave-selfsteal.conf ]] &&
    cmp -s <(render_http_nginx_config) "$file"
}

check_https_site() {
  local file=/etc/nginx/sites-available/remnawave-selfsteal-tls.conf
  local link=/etc/nginx/sites-enabled/remnawave-selfsteal-tls.conf
  check_directory_path "${file%/*}" &&
    check_directory_path "${link%/*}" || return 1
  [[ -f $file && ! -L $file && -L $link ]] &&
    [[ $(readlink -- "$link") == ../sites-available/remnawave-selfsteal-tls.conf ]] &&
    cmp -s <(render_https_nginx_config) "$file"
}

check_webroot() {
  local webroot=/var/www/remnawave-selfsteal
  check_directory_path "$webroot/.well-known/acme-challenge" || return 1
  [[ -d $webroot && ! -L $webroot ]] &&
    [[ -d $webroot/.well-known/acme-challenge &&
       ! -L $webroot/.well-known &&
       ! -L $webroot/.well-known/acme-challenge &&
       ! -L $webroot/index.html ]] &&
    cmp -s <(render_index_html) "$webroot/index.html"
}

check_http_listener() {
  local addresses
  addresses=$(ss -H -ltn '( sport = :80 )' | awk '{print $4}') || return 1
  [[ $addresses == *'0.0.0.0:80'* ]]
}

check_http_page() {
  local response
  response=$(curl -4fsS --noproxy '*' --max-time 10 \
    --resolve "$domain:80:127.0.0.1" "http://$domain/") || return 1
  [[ $response == "$(render_index_html)" ]]
}

check_hook() {
  local hook=/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal-nginx.sh
  check_directory_path "${hook%/*}" || return 1
  [[ -f $hook && ! -L $hook && -x $hook ]] &&
    cmp -s <(render_deploy_hook) "$hook"
}

check_renewal_dry_run() {
  check_renewal_record
}

echo "Remnawave Self-Steal Check"
report "Ubuntu 24.04" check_ubuntu
report "DNS" check_dns
report "nginx config" nginx -t
report "nginx service" systemctl is-active --quiet nginx
report "Webroot" check_webroot
report "HTTP site" check_http_site
report "HTTP :80" check_http_listener
report "HTTP page" check_http_page
report "Certificate" check_certificate
report "Renewal webroot" certificate_renewal_uses_webroot
report "HTTPS site" check_https_site
report "TLS 1.3 + HTTP/2 :9443" check_local_tls
report "Certbot timer" systemctl is-active --quiet certbot.timer
report "Deploy hook" check_hook
report "Renewal + deploy record" check_renewal_dry_run

if (( failed != 0 )); then
  echo "SELF-STEAL INCOMPLETE" >&2
  exit 1
fi
echo "SELF-STEAL READY"
