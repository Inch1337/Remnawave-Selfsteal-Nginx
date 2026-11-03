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

STATE_DIR=/etc/remnawave-selfsteal
MARKER=$STATE_DIR/site-template
WEBROOT=/var/www/remnawave-selfsteal
INDEX=$WEBROOT/index.html
TRANSACTION=$STATE_DIR/template-transaction
STAGED_INDEX=$WEBROOT/.template-stage-index
STAGED_MARKER=$STATE_DIR/.template-stage-marker

matches_index_file() {
  local expected=$1 file=$2 saved=${site_template:-welcome} result=0
  site_template=$expected
  cmp -s <(render_index_html) "$file" || result=1
  site_template=$saved
  return "$result"
}

matches_index() {
  matches_index_file "$1" "$INDEX"
}

matches_marker() {
  [[ -f $MARKER && ! -L $MARKER ]] &&
    cmp -s <(printf '%s\n' "$1") "$MARKER"
}

remove_stage_file() {
  local file=$1
  if [[ -e $file || -L $file ]]; then
    if [[ -L $file || ! -f $file || $(stat -c %u -- "$file") != 0 ]]; then
      echo "Error: unsafe template staging path: $file" >&2
      return 1
    fi
    rm -- "$file"
  fi
}

clear_transaction() {
  local file
  for file in ready committed index.html site-template meta .ready.tmp .committed.tmp; do
    if [[ -f $TRANSACTION/$file ]]; then
      rm -- "$TRANSACTION/$file"
    fi
  done
  rmdir -- "$TRANSACTION"
}

recover_template_transaction() {
  local entry name old new had_marker
  local -a metadata
  if [[ ! -e $TRANSACTION && ! -L $TRANSACTION ]]; then
    return 0
  fi
  if [[ -L $TRANSACTION || ! -d $TRANSACTION ||
        $(stat -c '%u:%a' -- "$TRANSACTION") != '0:700' ]]; then
    echo "Error: unsafe template transaction directory." >&2
    return 1
  fi
  while IFS= read -r entry; do
    name=${entry##*/}
    case $name in
      index.html|site-template|meta|ready|committed|.ready.tmp|.committed.tmp) ;;
      *) echo "Error: unexpected template transaction file: $entry" >&2; return 1 ;;
    esac
    if [[ -L $entry || ! -f $entry || $(stat -c %u -- "$entry") != 0 ]]; then
      echo "Error: unsafe template transaction file: $entry" >&2
      return 1
    fi
  done < <(find "$TRANSACTION" -mindepth 1 -maxdepth 1 -print)

  if [[ ! -f $TRANSACTION/ready ]]; then
    # Preparation was incomplete, or cleanup began after a completed change.
    clear_transaction
    echo "Incomplete template preparation removed."
    return 0
  fi
  if ! cmp -s <(printf 'ready\n') "$TRANSACTION/ready" ||
     ! mapfile -t metadata < "$TRANSACTION/meta" ||
     [[ -z ${metadata[0]+x} || -z ${metadata[1]+x} ||
        -z ${metadata[2]+x} || -n ${metadata[3]+x} ]]; then
    echo "Error: invalid template transaction record." >&2
    return 1
  fi
  old=${metadata[0]}
  new=${metadata[1]}
  had_marker=${metadata[2]}
  case $old in welcome|studio|journal) ;; *) return 1 ;; esac
  case $new in welcome|studio|journal) ;; *) return 1 ;; esac
  [[ $had_marker == 0 || $had_marker == 1 ]] || return 1
  if [[ ! -f $TRANSACTION/index.html ||
        $(stat -c %a -- "$TRANSACTION/index.html") != 644 ]] ||
     ! matches_index_file "$old" "$TRANSACTION/index.html"; then
    echo "Error: template page backup is missing or invalid." >&2
    return 1
  fi
  if (( had_marker )); then
    if [[ ! -f $TRANSACTION/site-template ||
          $(stat -c %a -- "$TRANSACTION/site-template") != 600 ]] ||
       ! cmp -s <(printf '%s\n' "$old") "$TRANSACTION/site-template"; then
      echo "Error: template marker backup is missing or invalid." >&2
      return 1
    fi
  elif [[ -e $TRANSACTION/site-template ]]; then
    echo "Error: unexpected template marker backup." >&2
    return 1
  fi
  if [[ ! -f $INDEX || -L $INDEX || $(stat -c %a -- "$INDEX") != 644 ]] ||
     { ! matches_index "$old" && ! matches_index "$new"; }; then
    echo "Error: installed page was changed during template switching." >&2
    return 1
  fi
  if [[ -L $MARKER || ( -e $MARKER && ! -f $MARKER ) ]]; then
    echo "Error: template marker was changed during switching." >&2
    return 1
  fi
  if [[ -f $MARKER ]]; then
    if [[ $(stat -c %a -- "$MARKER") != 600 ]] ||
       { ! matches_marker "$old" && ! matches_marker "$new"; }; then
      echo "Error: template marker was changed during switching." >&2
      return 1
    fi
  elif (( had_marker )); then
    echo "Error: template marker disappeared during switching." >&2
    return 1
  fi
  remove_stage_file "$STAGED_INDEX" || return 1
  remove_stage_file "$STAGED_MARKER" || return 1

  if [[ -f $TRANSACTION/committed ]]; then
    if ! cmp -s <(printf 'committed\n') "$TRANSACTION/committed" ||
       ! matches_index "$new" || ! matches_marker "$new"; then
      echo "Error: committed template change is inconsistent." >&2
      return 1
    fi
    clear_transaction
    echo "Completed template change confirmed: $new."
    return 0
  fi

  cp -p -- "$TRANSACTION/index.html" "$STAGED_INDEX"
  mv -fT -- "$STAGED_INDEX" "$INDEX"
  if (( had_marker )); then
    cp -p -- "$TRANSACTION/site-template" "$STAGED_MARKER"
    mv -fT -- "$STAGED_MARKER" "$MARKER"
  else
    rm -f -- "$MARKER"
  fi
  clear_transaction
  echo "Interrupted template change rolled back to $old."
}

cleanup_state_temporary_files
check_directory_path "$WEBROOT"
[[ -d $WEBROOT && ! -L $WEBROOT ]] || {
  echo "Error: installed site directory is missing." >&2
  exit 1
}
recover_template_transaction || exit 1
remove_stage_file "$STAGED_INDEX" || exit 1
remove_stage_file "$STAGED_MARKER" || exit 1
read_site_template || exit 1
old_template=$site_template
if [[ ! -f $INDEX || -L $INDEX || $(stat -c %a -- "$INDEX") != 644 ]] ||
   ! matches_index "$old_template"; then
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

finish_template_change() {
  local status=$?
  trap - EXIT
  if [[ -d $TRANSACTION ]] && ! recover_template_transaction; then
    echo "Error: automatic recovery failed; keep the transaction directory for repair." >&2
    status=1
  fi
  exit "$status"
}
trap finish_template_change EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -m 700 -- "$TRANSACTION"
cp -p -- "$INDEX" "$TRANSACTION/index.html"
had_marker=0
if [[ -f $MARKER ]]; then
  cp -p -- "$MARKER" "$TRANSACTION/site-template"
  had_marker=1
fi
printf '%s\n%s\n%s\n' "$old_template" "$selected" "$had_marker" > "$TRANSACTION/meta"
chmod 600 "$TRANSACTION/meta"
printf 'ready\n' > "$TRANSACTION/.ready.tmp"
chmod 600 "$TRANSACTION/.ready.tmp"
mv -T -- "$TRANSACTION/.ready.tmp" "$TRANSACTION/ready"

site_template=$selected
render_index_html > "$STAGED_INDEX"
render_site_template_marker > "$STAGED_MARKER"
chmod 644 "$STAGED_INDEX"
chmod 600 "$STAGED_MARKER"
mv -fT -- "$STAGED_INDEX" "$INDEX"
mv -fT -- "$STAGED_MARKER" "$MARKER"
matches_index "$selected"
matches_marker "$selected"
printf 'committed\n' > "$TRANSACTION/.committed.tmp"
chmod 600 "$TRANSACTION/.committed.tmp"
mv -T -- "$TRANSACTION/.committed.tmp" "$TRANSACTION/committed"
recover_template_transaction
echo "Site template changed: $old_template -> $selected"
