# areslolxd/runtimes-tier3:karel already contains a fully built judge
# (judge-server AddKarel branch installed under /judge and /env, plus the
# rekarel/karel compiler and VM binaries) — no build steps needed here.
# This image must be built/loaded separately (see README's "Setting up a
# judge" section) — it is not produced by this repo.
# The localhost/ prefix on the default below is podman-specific (forces
# local-store resolution instead of a registry lookup). Docker resolves a
# bare local tag without it, so the default here works for Docker as-is;
# podman hosts must override it by setting RUNTIME_TIER3_IMAGE=localhost/areslolxd/runtimes-tier3:karel
# in dmoj/.env (see dmoj/.env.example).
ARG RUNTIME_TIER3_IMAGE=areslolxd/runtimes-tier3:karel
FROM ${RUNTIME_TIER3_IMAGE}
