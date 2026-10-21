# Remnawave Self-Steal Nginx

**Development version. Do not use on a production VPS until the Ubuntu 24.04
integration checks have passed.**

This installer prepares an HTTP webroot for Let's Encrypt and an nginx TLS
endpoint at `127.0.0.1:9443`. Remnawave Node configuration remains manual.
It does not edit Docker, Remnawave, Xray or the firewall.

## Supported host

- Ubuntu 24.04 LTS on x86_64, run as root.
- A domain with exactly one A record pointing to the VPS's public IPv4 and
  no AAAA record.
- Ports 80 and 9443 free before the first installation.
- No pre-existing nginx installation. The package-provided default site is
  left in place after nginx is installed.
- No pre-existing Let's Encrypt lineage for the chosen domain.
- If Remnawave Node is present, its Docker network mode must be `host`.
- `curl`, `resolvectl` and `ss` available for the read-only preflight.

Less than 1 GiB RAM or no swap produces a warning. Less than 2 GiB free disk
space stops installation. This installer does not perform a full system
upgrade or reboot.

## Use

Keep `install.sh`, `check.sh` and `uninstall.sh` together. Inspect them before
running on a VPS.

```bash
sudo bash install.sh --check
sudo bash install.sh --install
sudo bash check.sh
```

`--check` performs preflight checks without changing the system. `--install`
may install the `nginx`, `certbot`, `openssl` and `ca-certificates` Ubuntu
packages, create files under
`/etc/remnawave-selfsteal`, `/etc/nginx`, `/var/www/remnawave-selfsteal`
and `/etc/letsencrypt`, and start or reload nginx. It uses Certbot's webroot
mode; Certbot does not rewrite nginx configuration.
The first certificate request asks for a Let's Encrypt contact email.

The installer records its domain in
`/etc/remnawave-selfsteal/state.conf`. Repeating `--install` reuses an
existing valid certificate and expected files. It stops if a managed file
has different contents rather than overwriting it. If a package operation
was interrupted and `dpkg` reports an incomplete transaction, repair that
transaction manually before retrying.

After `--install` reports completion, configure Remnawave manually:

```text
target      = 127.0.0.1:9443
serverNames = your.domain.example
xver        = 0
```

`check.sh` reads installation state and checks DNS, nginx, HTTP, the
certificate, local TLS, the renewal hook and the record of a successful
renewal dry run without making changes. A failed dry run is a warning during
installation, but `check.sh` reports incomplete status until a retry succeeds.
`uninstall.sh` removes only verified installer-managed files. It leaves
the nginx and certbot packages installed and asks separately whether to
delete the Let's Encrypt certificate. Keeping the certificate after removal
requires a working HTTP-01 webroot for future renewals.

## Release status

Version `v0.1.0` will be tagged after a clean Ubuntu 24.04 installation,
repeat run, interrupted-run recovery and uninstall have been exercised on
the test VPS. Until then, commands that download from `main` are not a
stable installation method.
