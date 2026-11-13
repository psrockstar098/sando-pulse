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
"$ZIG" build -Doptimize=ReleaseSafe --prefix /tmp/pulse-build-out
cp /tmp/pulse-build-out/bin/pulse "$AIO/pulse"

echo "== 2. vendored .debs (archive candidate versions) =="
mkdir -p "$AIO/debs"
python3 - "$AIO" <<'EOF'
import subprocess, re, sys
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
specs = []
skipped = []
for pkg in needed:
    pol = subprocess.run(["apt-cache", "policy", pkg],
                         capture_output=True, text=True).stdout
    versions, cur, candidate = [], None, None
    for line in pol.splitlines():
        if line.strip().startswith("Candidate:"):
            candidate = line.strip().split(None, 1)[1]
        m = re.match(r"\s*\**\s*(\S+)\s+\d+\s*$", line)
        if m and m.group(1) not in ("Installed:", "Candidate:"):
            cur = m.group(1)
            continue
        if cur and "http" in line:
            versions.append(cur)
            cur = None
        elif cur and "/var/lib/dpkg/status" in line:
            cur = None
    if versions:
        specs.append(f"{pkg}={versions[0]}")
    elif candidate and candidate != "(none)":
        # No archive entry found (e.g. the host's apt lists lack this
        # package's source) but a candidate exists in the lists: use it.
        print(f"  WARN {pkg}: no archive version, using candidate {candidate}")
        specs.append(f"{pkg}={candidate}")
    else:
        # Installed-only on this host (no archive entry, no candidate):
        # the version already ships in the ubuntu:24.04 base image, so
        # the dependency is satisfied there and no .deb is needed.
        # Record it loudly — if dpkg -i later complains about this
        # package, the skip is the first suspect.
        print(f"  SKIP {pkg}: installed-only, no archive version, no candidate")
        print(f"    policy output: {pol!r}")
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
