# syntax=docker/dockerfile:1
# Multi-stage build for the Pulse Zig binary. Std-lib only: no package
# downloads, so the build needs no network beyond the Zig tarball.
FROM debian:bookworm-slim AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*
ARG ZIG_VERSION=0.17.1
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
        -o /tmp/zig.tar.xz \
    && tar -xJf /tmp/zig.tar.xz -C /opt \
    && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig-x86_64-linux-${ZIG_VERSION}:$PATH
WORKDIR /src
COPY . .
RUN zig build -Doptimize=ReleaseSafe --prefix /out

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -r -u 10001 pulse
COPY --from=build /out/bin/pulse /usr/local/bin/pulse
COPY --from=build /src/migrations /app/migrations
WORKDIR /app
USER pulse
EXPOSE 9000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["curl", "-fsS", "http://127.0.0.1:9000/v1/health"]
ENTRYPOINT ["/usr/local/bin/pulse"]
CMD ["serve"]
