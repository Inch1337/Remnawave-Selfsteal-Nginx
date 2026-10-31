#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/install.sh"
domain=example.com

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -- "$fixture/state" "$fixture/bin"
STATE_DIR=$fixture/state
site=$fixture/site.conf
backup=$STATE_DIR/http-v0.1.0.conf.bak

# Run the real migration against fixture files; only nginx validation is stubbed.
cat > "$fixture/bin/nginx" <<'SH'
#!/usr/bin/env bash
exit "${NGINX_TEST_EXIT:-0}"
SH
chmod +x "$fixture/bin/nginx"
export PATH="$fixture/bin:$PATH"

render_legacy_http_nginx_config > "$site"
chmod 644 "$site"
migrate_legacy_http_config "$site" "$backup"
cmp -s <(render_http_nginx_config) "$site"
cmp -s <(render_legacy_http_nginx_config) "$backup"
grep -Fq 'return 301 https://example.com$request_uri;' "$site"
grep -Fq 'location ^~ /.well-known/acme-challenge/' "$site"

# A second run is safe, while an unknown edit must not be overwritten.
migrate_legacy_http_config "$site" "$backup"
printf '\n# custom edit\n' >> "$site"
if migrate_legacy_http_config "$site" "$backup" >/dev/null 2>&1; then
  echo 'Custom HTTP configuration was overwritten.' >&2
  exit 1
fi
grep -Fq '# custom edit' "$site"

# A failed nginx validation restores the old working configuration.
rm -- "$site" "$backup"
render_legacy_http_nginx_config > "$site"
chmod 644 "$site"
export NGINX_TEST_EXIT=1
if migrate_legacy_http_config "$site" "$backup" >/dev/null 2>&1; then
  echo 'HTTP migration accepted an invalid nginx configuration.' >&2
  exit 1
fi
cmp -s <(render_legacy_http_nginx_config) "$site"

echo 'HTTP redirect migration checks passed.'
