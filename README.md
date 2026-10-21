# Remnawave Self-Steal Nginx

**Development version. Do not use on a production VPS until the Ubuntu 24.04
integration checks have passed.**

This installer prepares an HTTP webroot for Let's Encrypt and an nginx TLS
endpoint at `127.0.0.1:9443` with HTTP/2 and TLS 1.3 support.
Remnawave Node configuration remains manual.
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
- `curl` with HTTP/2 support, `resolvectl` and `ss` available for the
  read-only preflight. Ubuntu's packaged curl supports HTTP/2.

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

After starting or reloading nginx, the installer waits up to 30 seconds
(plus the final probe timeout) for the expected HTTP challenge or TLS
endpoint to respond. It verifies both TLS 1.3 and negotiated HTTP/2.
Temporary marker files left by an interrupted write are cleaned only while
holding the installation lock, inside the root-owned mode-700 state
directory. Unexpected file types, owners or permissions stop cleanup.

After `--install` reports completion, configure Remnawave manually:

```text
target      = 127.0.0.1:9443
serverNames = your.domain.example
xver        = 0
```

`check.sh` reads installation state and checks DNS, nginx, HTTP, the
certificate, local TLS 1.3/HTTP/2, the renewal hook and the record of a
successful renewal dry run without making changes. Certbot's effective
webroot for the chosen domain is read from its configuration, including
the per-domain `webroot_map`. The successful dry-run record includes hashes
of the renewal configuration and deploy hook. A changed configuration
requires a new dry run on the next `--install`. Dry runs execute the deploy
hook as well. A failed dry run exits with an error and leaves installation
incomplete; repeat `--install` to retry.
`uninstall.sh` removes only verified installer-managed files. It leaves
the nginx and certbot packages installed and asks separately whether to
delete the Let's Encrypt certificate. Keeping the certificate after removal
requires a working HTTP-01 webroot for future renewals.
Uninstall refuses symbolic links in parent directories of managed paths
before removing installed files. Retained nginx packages mean a subsequent
fresh installation still falls under the existing-nginx restriction;
uninstall does not automatically purge packages or unrelated nginx sites.

These changes have not been tested in this editing pass. Live certificate
issuance/renewal, systemd behavior and the real Remnawave connection still
need verification on the test VPS before release.

## Release status

Version `v0.1.0` will be tagged after a clean Ubuntu 24.04 installation,
repeat run, interrupted-run recovery and uninstall have been exercised on
the test VPS. Until then, commands that download from `main` are not a
stable installation method.
