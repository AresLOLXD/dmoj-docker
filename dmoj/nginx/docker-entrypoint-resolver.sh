#!/bin/sh
set -eu

# The Docker/Podman embedded DNS resolver address varies by install and
# network backend (e.g. Docker's fixed 127.0.0.11 vs. Podman/netavark's
# per-network gateway IP), so it can't be hardcoded in the tracked
# nginx.conf. Generate it here from this container's own /etc/resolv.conf
# on every start; nginx.conf includes the result.
NS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
echo "resolver ${NS} valid=10s;" > /etc/nginx/resolver.conf
