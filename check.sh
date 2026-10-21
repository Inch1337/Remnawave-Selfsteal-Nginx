#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/install.sh"

read_installed_domain || exit 1

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
report "DNS" check_domain_dns
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
