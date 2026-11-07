# The CI lane image: ghcr.io/mcritchie-studio/ci-rails:24.04.
#
# WHY. The largest single cause of a red-then-green CI run was the Ubuntu apt mirror
# stalling in the lanes' "Install system packages" step (hub 12 jobs, engine 35
# job-steps in two weeks: refactor-review-2026-11-06, lane-health 2f). A cache and a
# retry loop only made the stall rarer. This image moves every apt fetch OFF the PR
# path: the packages are installed here, once a week, by mirror-ci-images.yml, and the
# lanes run inside the image with no apt step at all. A stalled mirror now fails the
# weekly build, which keeps last week's image, instead of failing somebody's PR.
#
# WHAT. Ubuntu 24.04 (the runners' own release, so the package versions match what the
# lanes installed before), plus the union of every lane's packages:
#   - the Rails lanes: curl libvips postgresql-client imagemagick librsvg2-bin ffmpeg
#     libjemalloc2, and libpq-dev for the pg gem;
#   - the island_animator lane: ffmpeg, python3;
#   - Chromium's shared libraries for the Playwright lanes (`playwright install-deps`),
#     so a lane installs only the browser itself, from Playwright's CDN, never apt;
#   - what a hosted runner has and a bare image lacks: git (actions/checkout needs it
#     for a real .git), build tools for native gems, a UTF-8 locale, sudo, tzdata.
# Ruby and Node: ruby/setup-ruby and actions/setup-node still install the version each
# repo pins. The image also carries what a hosted runner has on PATH before those steps
# run, because suites and early steps rely on it: Node 22 (the engine's versions.json
# major; Rails suites shell out to `node` for their JavaScript unit tests) and Ubuntu's
# system Ruby (stdlib scripts that run before setup-ruby, such as the engine's
# hub-e2e-subset resolver). Measured 2026-11-06 on the engine's Consumer CI: without them
# every consumer suite failed `Errno::ENOENT - node` and the browser subset exited 127.
#
# THE BASE is the hub's own ghcr.io copy of ubuntu:24.04 (mirror-ci-images.yml's
# IMAGES), so the build never pulls from Docker Hub's anonymous quota.
# Guard: test/lib/ci_lane_image_test.rb.
ARG BASE=ghcr.io/mcritchie-studio/ubuntu:24.04
FROM ${BASE}

ARG PLAYWRIGHT_VERSION=1.62.1
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC

# apt is bounded here too: a silent socket drops in 30s and is re-fetched.
RUN printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' \
      > /etc/apt/apt.conf.d/80-retries \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl ffmpeg git gnupg imagemagick jq libffi-dev \
      libjemalloc2 libpq-dev librsvg2-bin libssl-dev libvips libyaml-dev pkg-config \
      postgresql-client python3 python3-venv redis-tools ruby sqlite3 sudo tzdata unzip xz-utils \
      zlib1g-dev zstd \
 && rm -rf /var/lib/apt/lists/*

# Node 22 on PATH, then Chromium's libraries from Playwright's own list for this release.
ARG NODE_VERSION=22.11.0
RUN curl -fsSL --retry 5 "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ -C /usr/local --strip-components=1 \
 && npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium \
 && rm -rf /root/.npm /var/lib/apt/lists/*

# The check the weekly build runs on itself: every binary a lane calls, and the
# libraries ruby-vips and the pg gem load, are present.
RUN for bin in convert ffmpeg ffprobe git node npm npx pg_dump psql rsvg-convert python3 redis-cli ruby sqlite3; do \
      command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }; \
    done \
 && for lib in libvips.so.42 libpq.so.5 libjemalloc.so.2; do \
      ldconfig -p | grep -q "$lib" || { echo "missing: $lib" >&2; exit 1; }; \
    done

# The lanes run as `runner`, uid 1001, the hosted runner's own user (the job container
# is started `--user 1001`): the workspace the runner mounts is owned by 1001, and the
# suites hold permission-based tests (an unwritable /etc, a process group) to a
# non-root user, as on the VM. Passwordless sudo, as there. Git trusts every
# directory system-wide, because the suites run git under their own sandboxed HOME,
# where actions/checkout's per-user safe.directory does not reach. ruby/setup-ruby's
# prebuilt Rubies install under /opt/hostedtoolcache (their fixed prefix), so runner owns it.
# CI_LANE_IMAGE tells a suite it is inside this container (a Selenium Chrome would need
# --no-sandbox here, which is why reusable-ci.yml's `system` lane stays on the VM).
RUN useradd --uid 1001 --create-home --shell /bin/bash runner \
 && echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner && chmod 0440 /etc/sudoers.d/runner \
 && git config --system --add safe.directory '*' \
 && mkdir -p /opt/hostedtoolcache && chown runner:runner /opt/hostedtoolcache
ENV CI_LANE_IMAGE=1

LABEL org.opencontainers.image.source="https://github.com/mcritchie-studio/mcritchie-studio" \
      org.opencontainers.image.description="CI lane image: Ubuntu 24.04 with every lane's apt packages pre-installed"
