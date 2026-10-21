#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/install.sh"
acquire_install_lock

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

assert_managed_file() {
  local file=$1 renderer=$2
  check_directory_path "${file%/*}" || return 1
  if [[ -L $file || ( -e $file && ! -f $file ) ]]; then
    echo "Error: unexpected file type: $file" >&2
    return 1
  fi
  if [[ -f $file ]] && ! cmp -s <("$renderer") "$file"; then
    echo "Error: managed file was changed: $file" >&2
    return 1
  fi
}

assert_managed_link() {
  local link=$1 expected=$2
  check_directory_path "${link%/*}" || return 1
  if [[ -L $link ]]; then
    if [[ $(readlink -- "$link") != "$expected" ]]; then
      echo "Error: managed link was changed: $link" >&2
      return 1
    fi
  elif [[ -e $link ]]; then
    echo "Error: managed link path is occupied: $link" >&2
    return 1
  fi
}

HTTP_FILE=/etc/nginx/sites-available/remnawave-selfsteal.conf
HTTPS_FILE=/etc/nginx/sites-available/remnawave-selfsteal-tls.conf
HTTP_LINK=/etc/nginx/sites-enabled/remnawave-selfsteal.conf
HTTPS_LINK=/etc/nginx/sites-enabled/remnawave-selfsteal-tls.conf
INDEX_FILE=/var/www/remnawave-selfsteal/index.html
HOOK_FILE=/etc/letsencrypt/renewal-hooks/deploy/remnawave-selfsteal-nginx.sh
PACKAGE_MARKER=$STATE_DIR/packages.started
RENEWAL_MARKER=$STATE_DIR/renewal.checked

# Verify all expected content before removing any installed file.
for directory in "$STATE_DIR" /etc/nginx/sites-available /etc/nginx/sites-enabled \
                 /etc/letsencrypt/renewal-hooks/deploy \
                 /var/www/remnawave-selfsteal/.well-known/acme-challenge; do
  check_directory_path "$directory"
done
assert_managed_file "$HTTP_FILE" render_http_nginx_config
assert_managed_file "$HTTPS_FILE" render_https_nginx_config
assert_managed_file "$INDEX_FILE" render_index_html
assert_managed_file "$HOOK_FILE" render_deploy_hook
assert_managed_file "$PACKAGE_MARKER" render_package_marker
if [[ -L $RENEWAL_MARKER || ( -e $RENEWAL_MARKER && ! -f $RENEWAL_MARKER ) ]]; then
  echo "Error: invalid renewal check marker." >&2
  exit 1
fi
if [[ -f $RENEWAL_MARKER ]] && ! valid_renewal_marker "$RENEWAL_MARKER"; then
  echo "Error: renewal check marker was changed." >&2
  exit 1
fi
assert_managed_link "$HTTP_LINK" ../sites-available/remnawave-selfsteal.conf
assert_managed_link "$HTTPS_LINK" ../sites-available/remnawave-selfsteal-tls.conf
cleanup_state_temporary_files
while IFS= read -r entry; do
  case $entry in
    state.conf|packages.started|renewal.checked) ;;
    *)
      echo "Error: unexpected file in installation state: $entry" >&2
      exit 1
      ;;
  esac
done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n')

removed_http=0
removed_https=0
if [[ -L $HTTP_LINK ]]; then
  rm -- "$HTTP_LINK"
  removed_http=1
fi
if [[ -L $HTTPS_LINK ]]; then
  rm -- "$HTTPS_LINK"
  removed_https=1
fi

if (( removed_http || removed_https )) && command -v nginx >/dev/null 2>&1; then
  if ! nginx -t ||
     (systemctl is-active --quiet nginx && ! systemctl reload nginx); then
    if (( removed_http )); then
      ln -s -- ../sites-available/remnawave-selfsteal.conf "$HTTP_LINK"
    fi
    if (( removed_https )); then
      ln -s -- ../sites-available/remnawave-selfsteal-tls.conf "$HTTPS_LINK"
    fi
    echo "Error: nginx validation or reload failed; site links were restored." >&2
    exit 1
  fi
fi

for file in "$HTTP_FILE" "$HTTPS_FILE" "$HOOK_FILE" "$INDEX_FILE" \
            "$PACKAGE_MARKER" "$RENEWAL_MARKER"; do
  if [[ -f $file ]]; then
    rm -- "$file"
  fi
done
rm -- "$STATE_FILE"
rmdir -- "$STATE_DIR"
rmdir -- /var/www/remnawave-selfsteal/.well-known/acme-challenge 2>/dev/null || true
rmdir -- /var/www/remnawave-selfsteal/.well-known 2>/dev/null || true
rmdir -- /var/www/remnawave-selfsteal 2>/dev/null || true

echo "Installer-managed files removed. nginx and certbot packages remain installed."
if [[ -f /etc/letsencrypt/live/$domain/fullchain.pem ]]; then
  answer=
  if read -r -p "Delete the Let's Encrypt certificate for $domain? [y/N] " answer </dev/tty &&
     [[ $answer == y || $answer == Y ]]; then
    certbot delete --cert-name "$domain" --non-interactive
  else
    echo "Certificate kept. Its HTTP-01 renewal needs a working webroot site."
  fi
fi
