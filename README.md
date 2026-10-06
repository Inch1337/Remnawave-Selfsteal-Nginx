# Remnawave Self-Steal Nginx

**Work in progress.** The current `install.sh` runs read-only preflight checks. It does not install nginx, obtain certificates, or change the VPS.

The planned v0.1.0 release will provide a local TLS endpoint at `127.0.0.1:9443` for a Remnawave Node using Docker host networking. Remnawave configuration remains manual.

## Current preflight requirements

- Ubuntu 24.04 on x86_64
- No existing nginx installation
- Ports 80 and 9443 available
- A domain pointing directly to the VPS IPv4, with no AAAA record
- Docker host networking if a Remnawave Node container is detected

Low RAM and missing swap produce warnings. Less than 2 GiB of free disk space stops the check.

## Current use

Copy `install.sh` to the VPS and run:

```bash
sudo bash install.sh
```

The script asks for a domain and reports its checks. A successful result means only that the current preflight passed.