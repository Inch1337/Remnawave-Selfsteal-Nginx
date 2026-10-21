#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/install.sh"
domain=example.com
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

assert_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "Expected failure: $*" >&2
    exit 1
  fi
}

valid_domain example.com
assert_failure valid_domain 'https://example.com'
assert_failure valid_domain 'example..com'

render_http_nginx_config > "$fixture/http.conf"
render_https_nginx_config > "$fixture/https.conf"
grep -Fxq '    listen 127.0.0.1:9443 ssl http2;' "$fixture/https.conf"
assert_failure grep -Fq '0.0.0.0:9443' "$fixture/https.conf"
grep -Fq 'try_files $uri $uri/ =404;' "$fixture/http.conf"

write_managed_file "$fixture/index.html" 644 render_index_html
write_managed_file "$fixture/index.html" 644 render_index_html
printf 'manual edit\n' >> "$fixture/index.html"
assert_failure write_managed_file "$fixture/index.html" 644 render_index_html
rm -- "$fixture/index.html"
ln -s -- "$fixture/http.conf" "$fixture/index.html"
assert_failure write_managed_file "$fixture/index.html" 644 render_index_html

mkdir -- "$fixture/sites-available" "$fixture/sites-enabled"
touch -- "$fixture/sites-available/ours.conf"
ensure_site_link "$fixture/sites-available/ours.conf" "$fixture/sites-enabled/ours.conf"
if [[ -L $fixture/sites-enabled/ours.conf ]]; then
  ensure_site_link "$fixture/sites-available/ours.conf" "$fixture/sites-enabled/ours.conf"
  [[ $(readlink -- "$fixture/sites-enabled/ours.conf") == ../sites-available/ours.conf ]]
  rm -- "$fixture/sites-enabled/ours.conf"
  ln -s -- ../sites-available/foreign.conf "$fixture/sites-enabled/ours.conf"
  assert_failure ensure_site_link "$fixture/sites-available/ours.conf" "$fixture/sites-enabled/ours.conf"
else
  echo "Symlink checks skipped: this Windows Bash cannot create Unix symlinks."
fi

render_deploy_hook > "$fixture/hook.sh"
grep -Fq '${RENEWED_LINEAGE:-}' "$fixture/hook.sh"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '//CN=example.com' -addext 'subjectAltName=DNS:example.com,DNS:other.example.com' \
  -keyout "$fixture/key.pem" -out "$fixture/cert.pem" >/dev/null 2>&1
certificate_has_domain "$fixture/cert.pem"
domain=ample.com
assert_failure certificate_has_domain "$fixture/cert.pem"
domain=example.com

printf '[renewalparams]\nauthenticator = webroot\nwebroot_path = /var/www/remnawave-selfsteal,\n' > "$fixture/renewal.conf"
certificate_renewal_uses_webroot "$fixture/renewal.conf"
printf '[renewalparams]\nauthenticator = standalone\n' > "$fixture/renewal.conf"
assert_failure certificate_renewal_uses_webroot "$fixture/renewal.conf"

echo "Helper checks passed."
