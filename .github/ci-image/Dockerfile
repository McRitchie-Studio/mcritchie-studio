# The CI lane image: ghcr.io/mcritchie-studio/ci-rails:noble.
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
# Ruby and Node are NOT baked in: ruby/setup-ruby and actions/setup-node install the
# version each repo pins, as they did on the bare runner.
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
      postgresql-client python3 python3-venv redis-tools sudo tzdata unzip xz-utils \
      zlib1g-dev zstd \
 && rm -rf /var/lib/apt/lists/*

# Chromium's libraries, from Playwright's own list for this release. A throwaway Node
# runs the installer and is removed; the lanes bring their own Node.
RUN curl -fsSL --retry 5 https://nodejs.org/dist/v22.11.0/node-v22.11.0-linux-x64.tar.xz \
      | tar -xJ -C /tmp \
 && PATH="/tmp/node-v22.11.0-linux-x64/bin:$PATH" \
      npx -y "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium \
 && rm -rf /tmp/node-v22.11.0-linux-x64 /root/.npm /var/lib/apt/lists/*

# The check the weekly build runs on itself: every binary a lane calls is present.
RUN for bin in convert ffmpeg ffprobe git pg_dump psql rsvg-convert vips python3 redis-cli; do \
      command -v "$bin" >/dev/null || { echo "missing: $bin" >&2; exit 1; }; \
    done

LABEL org.opencontainers.image.source="https://github.com/mcritchie-studio/mcritchie-studio" \
      org.opencontainers.image.description="CI lane image: Ubuntu 24.04 with every lane's apt packages pre-installed"
