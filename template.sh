#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

if (( $# > 1 )); then
  echo "Usage: bash template.sh [welcome|studio|journal]" >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/install.sh"
acquire_install_lock
read_installed_domain || exit 1
read_site_template || exit 1

STATE_DIR=/etc/remnawave-selfsteal
MARKER=$STATE_DIR/site-template
WEBROOT=/var/www/remnawave-selfsteal
INDEX=$WEBROOT/index.html
old_template=$site_template

cleanup_state_temporary_files
check_directory_path "$WEBROOT" || exit 1
if [[ ! -d $WEBROOT || -L $WEBROOT || ! -f $INDEX || -L $INDEX ||
      $(stat -c %a -- "$INDEX") != 644 ]] ||
   ! cmp -s <(render_index_html) "$INDEX"; then
  echo "Error: installed site page differs from the selected template." >&2
  exit 1
fi
if [[ -f $MARKER && $(stat -c %a -- "$MARKER") != 600 ]]; then
  echo "Error: site template marker has unexpected permissions." >&2
  exit 1
fi

if (( $# == 1 )); then
  selected=$1
else
  echo "Current site template: $old_template"
  echo "Available: 1) Welcome  2) Studio (dark)  3) Journal (light)"
  if ! read -r -p "Choose site template [current]: " selected </dev/tty; then
    echo "Error: cannot read site template choice from terminal." >&2
    exit 1
  fi
  case $selected in
    "") selected=$old_template ;;
    1) selected=welcome ;;
    2) selected=studio ;;
    3) selected=journal ;;
  esac
fi
case $selected in
  welcome|studio|journal) ;;
  *) echo "Error: choose welcome, studio or journal." >&2; exit 2 ;;
esac
if [[ $selected == "$old_template" ]]; then
  echo "Site template is already $selected."
  exit 0
fi

staged_index= backup_index= staged_marker= backup_marker=
page_replaced=0
marker_replaced=0
had_marker=0
committed=0
[[ -f $MARKER ]] && had_marker=1

finish_template_change() {
  local status=$?
  local rollback_failed=0
  trap - EXIT
  if (( ! committed )); then
    if (( marker_replaced )); then
      if (( had_marker )); then
        if ! mv -fT -- "$backup_marker" "$MARKER"; then
          echo "Error: marker rollback failed; backup: $backup_marker" >&2
          rollback_failed=1
        fi
      else
        if ! rm -f -- "$MARKER"; then
          echo "Error: marker rollback failed." >&2
          rollback_failed=1
        fi
      fi
    fi
    if (( page_replaced )); then
      if ! mv -fT -- "$backup_index" "$INDEX"; then
        echo "Error: page rollback failed; backup: $backup_index" >&2
        rollback_failed=1
      fi
    fi
  fi
  for file in "$staged_index" "$staged_marker"; do
    [[ -n $file && -f $file ]] && rm -f -- "$file"
  done
  if (( ! rollback_failed )); then
    for file in "$backup_index" "$backup_marker"; do
      [[ -n $file && -f $file ]] && rm -f -- "$file"
    done
  fi
  exit "$status"
}
trap finish_template_change EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

staged_index=$(mktemp "$WEBROOT/.remnawave-selfsteal.XXXXXX")
backup_index=$(mktemp "$WEBROOT/.template-backup.XXXXXX")
staged_marker=$(mktemp "$STATE_DIR/.remnawave-selfsteal.XXXXXX")
if (( had_marker )); then
  backup_marker=$(mktemp "$STATE_DIR/.template-backup.XXXXXX")
  cp -p -- "$MARKER" "$backup_marker"
fi
cp -p -- "$INDEX" "$backup_index"

site_template=$selected
render_index_html > "$staged_index"
render_site_template_marker > "$staged_marker"
chmod 644 "$staged_index"
chmod 600 "$staged_marker"

page_replaced=1
mv -fT -- "$staged_index" "$INDEX"
marker_replaced=1
mv -fT -- "$staged_marker" "$MARKER"
cmp -s <(render_index_html) "$INDEX"
cmp -s <(render_site_template_marker) "$MARKER"
committed=1
echo "Site template changed: $old_template -> $site_template"
