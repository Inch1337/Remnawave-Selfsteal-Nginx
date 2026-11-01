#!/usr/bin/env bash
set -euo pipefail

verbose=0
if (( $# > 1 )); then
  echo "Usage: bash check.sh [--status|--verbose]" >&2
  exit 2
fi
case ${1:-} in
  "") ;;
  --status|--verbose) verbose=1 ;;
  --help|-h)
    echo "Usage: bash check.sh [--status|--verbose]"
    exit 0
    ;;
  *)
    echo "Usage: bash check.sh [--status|--verbose]" >&2
    exit 2
    ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/install.sh"

read_installed_domain || exit 1
read_site_template || exit 1

failed=0
warned=0
CERT_WARNING_SECONDS=$((14 * 24 * 60 * 60))
diagnostic_hint() {
  case $1 in
    "Ubuntu 24.04") echo "Requires Ubuntu 24.04; check /etc/os-release." ;;
    DNS) echo "Check the domain A record, public VPS IPv4 and absence of AAAA." ;;
    "nginx config") echo "Inspect the nginx error above and the site files in /etc/nginx/sites-available/." ;;
    "nginx service") echo "Inspect: systemctl status nginx --no-pager; journalctl -u nginx -n 50 --no-pager" ;;
    Webroot|"HTTP site"|"HTTPS site") echo "Check installer-managed files; rerun bash install.sh --install after resolving any manual changes." ;;
    "HTTP :80") echo "Check the nginx listener and whether another service occupies TCP/80." ;;
    "HTTP redirect") echo "Check the local HTTP response and the managed nginx HTTP site." ;;
    Certificate) echo "Check the certificate for this domain and /var/log/letsencrypt/letsencrypt.log." ;;
    "Renewal webroot") echo "Check the domain's Certbot renewal configuration and its webroot mapping." ;;
    "TLS 1.3 + HTTP/2 :9443") echo "Check nginx on 127.0.0.1:9443 and its certificate; inspect journalctl -u nginx." ;;
    "Certbot timer") echo "Inspect: systemctl status certbot.timer --no-pager" ;;
    "Deploy hook") echo "Check the managed Certbot deploy hook and its executable permission." ;;
    "Renewal + deploy record") echo "After fixing renewal or the deploy hook, rerun bash install.sh --install." ;;
  esac
}

show_certificate_status() {
  local certificate=/etc/letsencrypt/live/$domain/fullchain.pem
  local expiry issuer expiry_epoch now_epoch days_left
  expiry=$(openssl x509 -in "$certificate" -noout -enddate 2>/dev/null) || return 0
  issuer=$(openssl x509 -in "$certificate" -noout -issuer 2>/dev/null) || return 0
  expiry=${expiry#notAfter=}
  printf '  Domain: %s\n  Expires: %s\n  %s\n' "$domain" "$expiry" "$issuer"
  if expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null); then
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    printf '  Days remaining: %d\n' "$days_left"
  fi
}

show_timer_status() {
  local next_run
  next_run=$(systemctl show certbot.timer --property=NextElapseUSecRealtime --value 2>/dev/null) || return 0
  if [[ -n $next_run && $next_run != n/a ]]; then
    printf '  Next timer run: %s\n' "$next_run"
  fi
}

report() {
  local label=$1 output
  shift
  if output=$("$@" 2>&1); then
    if [[ $label == Certificate ]] &&
       ! openssl x509 -in "/etc/letsencrypt/live/$domain/fullchain.pem" \
         -noout -checkend "$CERT_WARNING_SECONDS" >/dev/null 2>&1; then
      printf '%-23s [WARN]\n' "$label"
      echo "  Certificate expires in less than 14 days; check Certbot renewal."
      warned=1
    else
      printf '%-23s [OK]\n' "$label"
    fi
    if (( verbose )); then
      case $label in
        DNS) [[ -z $output ]] || printf '  %s\n' "${output//$'\n'/$'\n  '}" ;;
        Certificate) show_certificate_status ;;
        "Certbot timer") show_timer_status ;;
      esac
    fi
  else
    printf '%-23s [FAIL]\n' "$label"
    if (( verbose )); then
      [[ -z $output ]] || printf '  %s\n' "${output//$'\n'/$'\n  '}"
      printf '  Hint: '
      diagnostic_hint "$label"
    fi
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
  response=$(curl -4sS --noproxy '*' --max-time 10 -o /dev/null \
    -w '%{http_code} %{redirect_url}' \
    --resolve "$domain:80:127.0.0.1" "http://$domain/") || return 1
  [[ $response == "301 https://$domain/" ]]
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
report "HTTP redirect" check_http_page
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
if (( warned != 0 )); then
  echo "SELF-STEAL READY WITH WARNINGS"
  exit 0
fi
echo "SELF-STEAL READY"
