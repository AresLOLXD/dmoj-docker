# areslolxd/runtimes-tier3:karel already contains a fully built judge
# (judge-server AddKarel branch installed under /judge and /env, plus the
# rekarel/karel compiler and VM binaries) — no build steps needed here.
# This image must be built/loaded separately (see README's "Setting up a
# judge" section) — it is not produced by this repo.
# The localhost/ prefix is podman-specific (forces local-store resolution);
# under real Docker, drop it and retag the image for Docker's local store.
FROM localhost/areslolxd/runtimes-tier3:karel
