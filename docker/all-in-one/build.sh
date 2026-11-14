#!/bin/bash
# build.sh — build the Sando Pulse all-in-one image from this checkout.
#
#   docker/all-in-one/build.sh            # podman if present, else docker
#
# Steps: (1) build the Pulse binary on the host with Zig 0.17.1,
# (2) vendor the Ubuntu 24.04 .debs for Postgres 16 + PostGIS 3.4.2 +
# pgvector 0.6.0 + Redis 7.0 at ARCHIVE (candidate) versions — mixing
# installed and candidate versions breaks dpkg configuration, so every
# .deb comes from the archive, never from /var/cache/apt/archives,
# (3) build the image. No network is used inside the image build.
#
# Requirements on the build host: Zig 0.17.1, an Ubuntu 24.04 apt setup
# (or any Debian-based host whose apt lists carry the noble packages),
# podman or docker. The .debs (~210 MB) and the binary are staged under
# docker/all-in-one/ and are NOT committed to git.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AIO="$ROOT/docker/all-in-one"
ZIG="${ZIG:-$HOME/.local/bin/zig}"
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/workspace/tmp/pulse-cache-docker}"
TAG="${TAG:-sando-pulse:all-in-one-0.1.0}"
BUILDER="${BUILDER:-$(command -v podman || command -v docker)}"

echo "== 1. pulse binary (zig 0.17.1, ReleaseSafe) =="
# -Dcpu=baseline: a native-target binary inherits the build host's CPU
# features — the GitHub runner that built the 2026-11-14 image has
# AVX-512, so the shipped binary contained EVEX instructions and died
# with SIGILL on machines without it (this VM and the Ryzen 3 3250U
# laptop). Baseline runs everywhere; the 5ms hot-path cost is nil.
"$ZIG" build -Doptimize=ReleaseSafe -Dcpu=baseline --prefix /tmp/pulse-build-out
cp /tmp/pulse-build-out/bin/pulse "$AIO/pulse"

echo "== 2. vendored .debs (archive candidate versions) =="
# Prefer Ubuntu-archive versions for everything: the build host may
# carry a third-party repo (the GitHub runner ships PostgreSQL from
# PGDG), and those versions are not in the Ubuntu archive, so they
# cannot be downloaded. Pinning the Ubuntu origin above all others
# makes the candidate the Ubuntu version. Non-fatal if sudo is
# unavailable — the Python below falls back to reading the Packages
# lists directly for any package whose candidate is still third-party.
if command -v sudo >/dev/null 2>&1; then
    printf 'Package: *\nPin: release o=Ubuntu\nPin-Priority: 1001\n' \
        | sudo tee /etc/apt/preferences.d/ubuntu-archive-first >/dev/null 2>&1 \
        || echo "  NOTE: could not write apt pin, continuing without it"
    echo "  apt pin (Ubuntu origin first) in place; candidate check:"
    apt-cache policy libpq5 postgresql-common 2>/dev/null | grep -E '^(libpq5|postgresql-common):|Candidate:' || true
fi
mkdir -p "$AIO/debs"
python3 - "$AIO" <<'EOF'
import subprocess, re, sys, glob, os
aio = sys.argv[1]
roots = ["postgresql-16", "postgresql-16-postgis-3", "postgresql-16-pgvector",
         "redis-server", "postgresql-client-16", "curl", "ca-certificates"]
out = subprocess.run(["apt-cache", "depends", "--recurse", "--no-recommends",
                      "--no-suggests", "--no-conflicts", "--no-breaks",
                      "--no-replaces", "--no-enhances"] + roots,
                     capture_output=True, text=True).stdout
pkgs = sorted({l.strip() for l in out.splitlines()
               if l.strip() and not l.startswith(" ") and "<" not in l})
# NOTE: download the FULL closure, including packages the base image
# already ships. Subtracting base packages is unsafe: the base image
# may carry older versions than the archive candidates (perl-base .6
# vs .7 broke dpkg with strict "=" deps). Reinstalling an identical
# version is a no-op; upgrading one fixes the skew.
needed = pkgs


def ubuntu_archive_version(pkg):
    # Read the Ubuntu archive version straight out of the Packages
    # lists. apt-cache is unreliable on the GitHub runner (policy /
    # madison / showpkg all see only installed versions, while
    # apt-get download sees the full archive), so this bypasses it.
    # Prefer noble-updates, then security, then backports, then noble.
    matched = 0
    for suite in ["noble-updates", "noble-security", "noble-backports", "noble"]:
        pattern = ("/var/lib/apt/lists/*archive.ubuntu.com_ubuntu_dists_"
                   f"{suite}_*_binary-amd64_Packages")
        for path in sorted(glob.glob(pattern)):
            matched += 1
            try:
                text = open(path, errors="ignore").read()
            except OSError:
                continue
            for stanza in text.split("\n\n"):
                lines = stanza.splitlines()
                if not lines or lines[0] != f"Package: {pkg}":
                    continue
                for ln in lines:
                    if ln.startswith("Version: "):
                        return ln.split(None, 1)[1].strip()
    if matched == 0:
        # Diagnostic: the lists are not where the glob expects them.
        print(f"  DIAG {pkg}: no *archive.ubuntu.com Packages files matched in /var/lib/apt/lists")
        try:
            names = sorted(os.listdir("/var/lib/apt/lists"))[:20]
            print(f"  DIAG lists dir first 20: {names}")
        except OSError as e:
            print(f"  DIAG cannot list /var/lib/apt/lists: {e}")
    return None


specs = []
skipped = []
for pkg in needed:
    # The candidate version is what apt-get download fetches, and it is
    # right for almost every package — EXCEPT packages shadowed by a
    # third-party repo installed on the build host. The GitHub runner's
    # PostgreSQL comes from PGDG, so the candidates for libpq5,
    # postgresql-16, postgresql-client-16, postgresql-common and
    # postgresql-client-common are PGDG versions (e.g. 293.pgdg24.04+1)
    # that are not in the Ubuntu archive and cannot be downloaded.
    # For those, use the Ubuntu archive version from the Packages lists.
    pol = subprocess.run(["apt-cache", "policy", pkg],
                         capture_output=True, text=True).stdout
    candidate = None
    for line in pol.splitlines():
        if line.strip().startswith("Candidate:"):
            candidate = line.strip().split(None, 1)[1]
    if candidate and "pgdg" in candidate:
        arch_ver = ubuntu_archive_version(pkg)
        if arch_ver is None:
            raise SystemExit(
                f"no Ubuntu-archive version for {pkg}, candidate is third-party {candidate}")
        print(f"  WARN {pkg}: candidate {candidate} is third-party, using Ubuntu-archive {arch_ver}")
        specs.append(f"{pkg}={arch_ver}")
    elif candidate and candidate != "(none)":
        specs.append(f"{pkg}={candidate}")
    else:
        # Installed-only on this host (no candidate): the version
        # already ships in the ubuntu:24.04 base image, so the
        # dependency is satisfied there and no .deb is needed. Record
        # it loudly — if dpkg -i later complains about this package,
        # the skip is the first suspect.
        print(f"  SKIP {pkg}: installed-only, no candidate")
        skipped.append(pkg)
open(f"{aio}/download-specs.txt", "w").write("\n".join(specs))
print(f"  {len(specs)} packages, {len(skipped)} skipped: {skipped}")
EOF
cd "$AIO/debs"
rm -f ./*.deb
xargs -a "$AIO/download-specs.txt" -n 1 -P 4 apt-get download

echo "== 3. image build ($BUILDER) =="
cd "$ROOT"
# Podman defaults to OCI format, which drops HEALTHCHECK; docker format
# keeps it (and plain `docker build` produces docker format anyway).
FORMAT_ARGS=()
if [ "$(basename "$BUILDER")" = "podman" ]; then FORMAT_ARGS=(--format docker); fi
"$BUILDER" build "${FORMAT_ARGS[@]}" -f docker/all-in-one/Dockerfile -t "$TAG" .
"$BUILDER" images "$TAG"
echo "Built $TAG. Run it with: docker run -d --name pulse -p 9000:9000 -v pulse-data:/var/lib/postgresql/data $TAG"
