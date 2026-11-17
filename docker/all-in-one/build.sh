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
         "redis-server", "postgresql-client-16", "curl", "ca-certificates",
         "python3", "python3-venv", "git"]
# python3: the ubuntu:24.04 base image does NOT ship it, and the
# SearXNG install step needs it. python3-venv: Ubuntu splits
# ensurepip out of python3 into python3-venv (python3.12-venv);
# without it `python3 -m ensurepip` does not exist. git: SearXNG's
# setup.py imports searx.version, which shells out to git (and only
# catches CalledProcessError, not a missing binary) — without git
# the package metadata generation fails outright.
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


def load_archive_versions():
    # Parse the Ubuntu archive Packages lists ONCE. Returns
    # {pkg: (first, all)} where `first` is the version from the
    # highest-priority suite (noble-updates, then security, backports,
    # noble) and `all` is every version any list carries. apt-cache
    # is unreliable on the GitHub runner (policy / madison / showpkg
    # all see only installed versions, while apt-get download sees
    # the full archive), so this bypasses it.
    versions = {}
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
                if not lines or not lines[0].startswith("Package: "):
                    continue
                pkg = lines[0].split(None, 1)[1].strip()
                ver = None
                for ln in lines:
                    if ln.startswith("Version: "):
                        ver = ln.split(None, 1)[1].strip()
                        break
                if ver is None:
                    continue
                if pkg in versions:
                    versions[pkg][1].add(ver)
                else:
                    versions[pkg] = (ver, {ver})
    if matched == 0:
        # Diagnostic: the lists are not where the glob expects them.
        print("  DIAG: no *archive.ubuntu.com Packages files matched in /var/lib/apt/lists")
        try:
            names = sorted(os.listdir("/var/lib/apt/lists"))[:20]
            print(f"  DIAG lists dir first 20: {names}")
        except OSError as e:
            print(f"  DIAG cannot list /var/lib/apt/lists: {e}")
    return versions


archive_versions = load_archive_versions()
print(f"  archive versions loaded for {len(archive_versions)} packages")


specs = []
skipped = []
for pkg in needed:
    # The candidate version is what apt-get download fetches — but it
    # is only downloadable when it is actually in the Ubuntu archive.
    # Two known ways it is not: a third-party repo installed on the
    # build host (the GitHub runner's PostgreSQL comes from PGDG, so
    # libpq5 / postgresql-* candidates are PGDG versions like
    # 293.pgdg24.04+1) or a version installed from elsewhere (this
    # VM ships libheif1 1.23.3-1, a Debian version no Ubuntu list
    # carries). In both cases apt-get download fails with "Can't
    # find a source to download version ..." — so use the archive
    # version from the highest-priority suite instead. A candidate
    # that IS in the archive is used as-is, even if it is not the
    # first-suite version (a security fix can outrank updates).
    pol = subprocess.run(["apt-cache", "policy", pkg],
                         capture_output=True, text=True).stdout
    candidate = None
    for line in pol.splitlines():
        if line.strip().startswith("Candidate:"):
            candidate = line.strip().split(None, 1)[1]
    if candidate and candidate != "(none)":
        entry = archive_versions.get(pkg)
        if entry is not None and candidate not in entry[1]:
            print(f"  WARN {pkg}: candidate {candidate} not in Ubuntu archive, using {entry[0]}")
            specs.append(f"{pkg}={entry[0]}")
        else:
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

echo "== 2.5. SearXNG (pinned source + wheelhouse, offline install) =="
# The PyPI package named `searxng` is NOT the search engine (it is an
# unrelated MCP wrapper) — the engine comes from its GitHub repo at the
# exact commit the compose image pins (2026.11.15-2d500cb6b). The host
# downloads the source tarball + the runtime wheels; the Dockerfile
# installs them with --no-index, so no network is needed inside the
# image build. setuptools/wheel ride along for the build backend.
SEARXNG_COMMIT="2d500cb6b"
SEARXNG_TARBALL="$AIO/searxng-src.tar.gz"
if [ ! -s "$SEARXNG_TARBALL" ]; then
    curl -fsSL "https://github.com/searxng/searxng/archive/${SEARXNG_COMMIT}.tar.gz" -o "$SEARXNG_TARBALL"
fi
rm -rf "$AIO/searxng-src"
mkdir -p "$AIO/searxng-src"
tar xzf "$SEARXNG_TARBALL" -C "$AIO/searxng-src" --strip-components=1
mkdir -p "$AIO/wheelhouse"
python3 -m pip download -r "$AIO/searxng-src/requirements.txt" -r "$AIO/searxng-src/requirements-server.txt" setuptools wheel --dest "$AIO/wheelhouse"
# Regenerate the all-in-one settings (six engines enabled, the rest
# disabled) from the pinned source's own defaults, so a SearXNG bump
# re-derives the list instead of going stale.
python3 - "$AIO/searxng-src/searx/settings.yml" "$ROOT/docker/searxng/settings-aio.yml" <<'EOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
m = re.search(r"^engines:\n", text, re.M)
names = re.findall(r"^  - name: ([A-Za-z0-9_.\-]+)\s*$", text[m.start():], re.M)
keep = {"google", "bing", "duckduckgo", "brave", "mojeek", "wikipedia"}
missing = keep - set(names)
if missing:
    raise SystemExit(f"keep-list engines missing from SearXNG defaults: {sorted(missing)}")
disabled = sorted(set(names) - keep)
header = f"""# SearXNG settings for the Sando Pulse all-in-one image
# (docs/WEBSEARCH.md). Generated from the pinned SearXNG source
# (commit 2d500cb6b) — see docker/all-in-one/build.sh.
#
# Same base as docker/searxng/settings.yml (compose), with two
# all-in-one differences:
# - the limiter talks to the Redis that already runs in this image
#   (db 1, so it never collides with Pulse's own keys on db 0);
#   no separate Valkey process is started.
# - only six engines are enabled (google, bing, duckduckgo, brave,
#   mojeek, wikipedia). The defaults enable {len(names)} engines; each one
#   costs startup time, memory, and a fan-out request per query.
#   Everything else is disabled below — this file is generated, do
#   not edit the disabled list by hand; re-run the generator in
#   docker/all-in-one/build.sh.
#
# The secret key comes from the SEARXNG_SECRET env var (the
# entrypoint generates one per boot if unset). It is never written
# in this file.
use_default_settings: true

general:
  instance_name: "Sando Pulse web search"
  # Required by the wikipedia (and wikidata / openstreetmap) engines:
  # without a contact URL they refuse to register at all.
  contact_url: "https://github.com/psrockstar098/sando-pulse"

search:
  safe_search: 1
  formats:
    - html
    - json

server:
  limiter: true

valkey:
  url: redis://127.0.0.1:6379/1

engines:
"""
lines = [header]
for n in disabled:
    lines.append(f"  - name: {n}\n    disabled: true\n")
open(dst, "w").write("".join(lines))
print(f"  settings-aio.yml: {len(names)} engines in defaults, {len(disabled)} disabled, 6 kept")
EOF

echo "== 3. image build ($BUILDER) =="
cd "$ROOT"
# Podman defaults to OCI format, which drops HEALTHCHECK; docker format
# keeps it (and plain `docker build` produces docker format anyway).
FORMAT_ARGS=()
if [ "$(basename "$BUILDER")" = "podman" ] || [ "$(basename "$BUILDER")" = "podman-vfs" ]; then
    FORMAT_ARGS=(--format docker)
    # --network host: this VM's sandbox blocks netavark's setns into a
    # new network namespace (Operation not permitted), so the default
    # build network fails at the first RUN step. The image build is
    # fully offline, so host networking changes nothing it does.
    # (The basename check must match the podman-vfs shim too — it is
    # the documented local builder, not plain podman.)
    FORMAT_ARGS+=(--network host)
fi
"$BUILDER" build "${FORMAT_ARGS[@]}" -f docker/all-in-one/Dockerfile -t "$TAG" .
"$BUILDER" images "$TAG"
echo "Built $TAG. Run it with: docker run -d --name pulse -p 9000:9000 -v pulse-data:/var/lib/postgresql/data $TAG"
