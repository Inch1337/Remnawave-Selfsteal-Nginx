#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

# Detect an existing installation
STATE_DIR=/etc/remnawave-selfsteal
STATE_FILE=$STATE_DIR/state.conf

if [[ -e $STATE_DIR && ! -f $STATE_FILE ]]; then
  echo "Error: state directory exists without a valid state file." >&2
  exit 1
fi

if [[ -L $STATE_DIR || -L $STATE_FILE ]]; then
  echo "Error: installation state must not be a symlink." >&2
  exit 1
fi

if [[ -f $STATE_FILE ]]; then
  mapfile -t state_lines < "$STATE_FILE"

  if (( ${#state_lines[@]} != 3 )) ||
     [[ ${state_lines[0]} != DOMAIN=* ||
        ${state_lines[1]} != TARGET_PORT=9443 ||
        ${state_lines[2]} != VERSION=0.1.0 ]]; then
    echo "Error: invalid installation state file." >&2
    exit 1
  fi

  saved_domain=${state_lines[0]#DOMAIN=}
  if [[ -z $saved_domain ]]; then
    echo "Error: domain is missing from installation state." >&2
    exit 1
  fi

  echo "Existing installation found for $saved_domain."
  echo "Resume is not implemented yet."
  exit 1
fi

echo "Installation state: new."

# Preflight checks
if [[ ! -r /etc/os-release ]]; then
  echo "Error: cannot identify the operating system." >&2
  exit 1
fi

. /etc/os-release

if [[ ${ID:-} != ubuntu || ${VERSION_ID:-} != 24.04 ]]; then
  echo "Error: only Ubuntu 24.04 is supported." >&2
  exit 1
fi

mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
swap_kib=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
disk_kib=$(df -Pk / | awk 'NR == 2 {print $4}')

# Check vps status
if [[ ! $mem_kib =~ ^[0-9]+$ ||
      ! $swap_kib =~ ^[0-9]+$ ||
      ! $disk_kib =~ ^[0-9]+$ ]]; then
  echo "Error: cannot read RAM, swap or free disk space." >&2
  exit 1
fi

printf 'RAM: %d MiB\n' "$((mem_kib / 1024))"
if (( mem_kib < 1048576 )); then
  echo "Warning: less than 1 GiB RAM."
fi

printf 'Swap: %d MiB\n' "$((swap_kib / 1024))"
if (( swap_kib == 0 )); then
  echo "Warning: no swap is configured."
fi

printf 'Free disk space on /: %d GiB\n' "$((disk_kib / 1048576))"
if (( disk_kib < 2097152 )); then
  echo "Error: less than 2 GiB free disk space." >&2
  exit 1
elif (( disk_kib < 4194304 )); then
  echo "Warning: less than 4 GiB free disk space."
fi

# Checking Architecture
arch=$(uname -m)
printf 'Architecture: %s\n' "$arch"

if [[ $arch != x86_64 ]]; then
  echo "Error: only x86_64 is supported in v0.1.0." >&2
  exit 1
fi

# Is nginx installed
if command -v nginx >/dev/null 2>&1 || [[ -e /etc/nginx/nginx.conf ]]; then
  echo "Error: an existing nginx installation is not supported in v0.1.0." >&2
  exit 1
fi

echo "nginx: not installed."

# Check ports
if ! command -v ss >/dev/null 2>&1; then
  echo "Error: ss is required to check listening ports." >&2
  exit 1
fi

if ! listeners=$(ss -H -ltnp '( sport = :80 or sport = :9443 )'); then
  echo "Error: cannot check listening ports." >&2
  exit 1
fi

if [[ -n $listeners ]]; then
  echo "Error: port 80 or 9443 is already in use:" >&2
  printf '%s\n' "$listeners" >&2
  exit 1
fi

echo "Ports 80 and 9443: free."

# Check docker and it's network
if command -v docker >/dev/null 2>&1; then
  echo "Docker: installed."

  if ! docker_rows=$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null); then
    echo "Error: Docker is installed, but running containers cannot be checked." >&2
    exit 1
  else
    node_name=$(awk '$2 ~ /(^|\/)remnawave\/node(:|@|$)/ {print $1; exit}' <<< "$docker_rows")

    if [[ -z $node_name ]]; then
      echo "Remnawave Node: not detected (allowed)."
    else
      echo "Remnawave Node: $node_name"

      if ! network_mode=$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$node_name"); then
        echo "Error: cannot check Remnawave Node network mode." >&2
        exit 1
      fi

      echo "Remnawave Node network: $network_mode"
      if [[ $network_mode != host ]]; then
        echo "Error: this Node cannot use the planned 127.0.0.1:9443 target." >&2
        exit 1
      fi
    fi
  fi
else
  echo "Docker: not installed (allowed)."
fi

# Domain status
if ! read -r -p "Enter domain: " domain </dev/tty; then
  echo "Error: cannot read domain from terminal." >&2
  exit 1
fi

domain=${domain,,}

if [[ -z $domain || ${#domain} -gt 253 ||
      $domain != *.* || $domain == .* || $domain == *. ]]; then
  echo "Error: enter a valid domain name, without https:// or a trailing dot." >&2
  exit 1
fi

IFS='.' read -r -a labels <<< "$domain"
for label in "${labels[@]}"; do
  if (( ${#label} > 63 )) ||
     [[ ! $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    echo "Error: invalid domain name." >&2
    exit 1
  fi
done

echo "Domain format: OK ($domain)"

# Avalability of domain
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required for the network check." >&2
  exit 1
fi

if ! server_ipv4=$(curl -4fsS --max-time 10 https://api.ipify.org); then
  echo "Error: cannot determine the VPS public IPv4." >&2
  exit 1
fi

if ! command -v resolvectl >/dev/null 2>&1; then
  echo "Error: resolvectl is required for DNS checks." >&2
  exit 1
fi

if ! a_result=$(LC_ALL=C resolvectl --legend=no --cache=no --synthesize=no \
    --protocol=dns --type=A query "$domain" 2>&1); then
  echo "Error: cannot query DNS A records: $a_result" >&2
  exit 1
fi

# Check A record
domain_ipv4=$(awk '$2 == "IN" && $3 == "A" {print $4}' <<< "$a_result" | sort -u)

printf 'VPS public IPv4: %s\n' "$server_ipv4"
printf 'DNS A: %s\n' "$domain_ipv4"

if [[ $domain_ipv4 != "$server_ipv4" ]]; then
  echo "Error: DNS A must point only to this VPS." >&2
  exit 1
fi

if aaaa_result=$(LC_ALL=C resolvectl --legend=no --cache=no --synthesize=no \
    --protocol=dns --type=AAAA query "$domain" 2>&1); then
  echo "Error: DNS AAAA exists; v0.1.0 supports IPv4 only." >&2
  printf '%s\n' "$aaaa_result" >&2
  exit 1
elif [[ $aaaa_result == *"does not have any RR of the requested type"* ]]; then
  echo "DNS AAAA: none."
else
  echo "Error: cannot verify DNS AAAA: $aaaa_result" >&2
  exit 1
fi

echo "DNS matches this VPS."

# Acme.sh avalability
if ! curl -4fsS --connect-timeout 5 --max-time 15 \
    -o /dev/null https://acme-v02.api.letsencrypt.org/directory; then
  echo "Error: Let's Encrypt API is unreachable." >&2
  exit 1
fi

echo "Let's Encrypt API: reachable."

echo "Initial checks passed. No changes have been made to the system."