#!/usr/bin/env bash
#
# Hold `bundle install` until THIS runner reads each locally published gem pinned in
# Gemfile.lock the way bundler will read it, on independent connections, every time.
#
# WHAT BUNDLER READS (bundler 2.5.23, the version every lockfile pins). The runner's
# bundler cache (~/.bundle/cache/compact_index) is COLD: setup-ruby caches only
# vendor/bundle. So:
#   · `/versions` is fetched whole, but on a cold cache it only supplies a non-nil
#     checksum, and a non-nil checksum that does not match a missing local file
#     ALWAYS re-fetches /info (compact_index_client/cache.rb `info`). Its contents
#     cannot hide a version from a cold-cache install, so it is not read here.
#   · `/info/<gem>` on index.rubygems.org (fetcher/base.rb rewrites rubygems.org to
#     the index host) SUPPLIES the versions the resolver enumerates. One plain GET,
#     HTTP/1.1, `Accept-Encoding: gzip;q=1.0,deflate;q=0.6,identity;q=0.3`
#     (Gem::Net::HTTP's default), each worker thread on its OWN connection. A lock
#     pin that is not in that body is the "can no longer be found in that source" /
#     "Could not find studio-engine-X in locally installed gems" red.
#   · `https://rubygems.org/gems/<gem>-<version>.gem`, the download, for a gem that
#     is not already installed.
#
# WHY ONE READ PROVED NOTHING (rel-20261109-900044, hub run 42589062630, job
# 129065907960). The previous version of this script read /info once and printed
# "studio-engine 0.141.0 is on /versions AND /info — this edge is fully caught up" at
# 08:52:18Z, 124s after the 08:50:14Z publish. Bundler on the SAME runner fetched
# /info at 08:52:24-28Z and did not get 0.141.0. The `javascript` job of the same run
# probed at 08:52:17Z and bundled 0.141.0 fine at 08:52:26Z. The cause is how
# RubyGems invalidates the CDN: on a publish it SOFT-purges /info/<gem> and
# /versions (rubygems.org lib/gem_cache_purger.rb and
# app/jobs/upload_info_file_job.rb: `FastlyPurgeJob ... soft: true`, stored with
# `surrogate-control: max-age=3600, stale-while-revalidate=1800`). A soft-purged
# Fastly copy is ALLOWED to answer with the pre-publish body while it revalidates,
# and each new connection lands on a different cache node (measured 2026-11-09: 30
# fresh connections to index.rubygems.org, 30 distinct `x-served-by` nodes). So one
# fresh answer on curl's connection says nothing about bundler's connection.
#
# THE CONDITION. Each poll makes AWAIT_READS separate curl processes (so separate
# connections, as bundler's threads use) read /info/<gem> with bundler's headers,
# then checks the .gem. The gem passes only when EVERY read lists the version and the
# .gem answers 2xx. A stale read is also what makes that node revalidate, so polling
# drains the stale copies this runner can reach; it is a bounded wait on a measured
# condition, not a sleep. An old pin passes on the first poll in about a second.
#
# FAIL CLOSED ON A PROVEN MISS (Alex McRitchie's deterministic-CI ruling, 2026-11-08).
# At AWAIT_TIMEOUT, if the last poll READ a body without the version (or the .gem
# answered 4xx), the step fails with GEM_NOT_SERVED_ON_RUNNER and names the surface:
# bundler would fail anyway, with the false claim that the author removed the gem.
# If the last poll could not reach RubyGems at all, the step warns and exits 0: a
# full bundler-cache hit installs nothing from the network and can still go green,
# and a partial one fails in bundler with a network error, not a false one.
#
# SIGPIPE: every read is a command substitution, never `curl | grep -q`. `grep -q`
# exits on its first match, curl dies of EPIPE, and under `pipefail` a hit reads as
# a miss (measured: status 56). `grep -c` reads the whole input.
#
set -uo pipefail

GEMS=${AWAIT_GEMS:-"studio-engine solana-studio"}
LOCK=${AWAIT_LOCK:-Gemfile.lock}
TIMEOUT=${AWAIT_TIMEOUT:-300}
INTERVAL=${AWAIT_INTERVAL:-5}
READS=${AWAIT_READS:-8}
INDEX_URL=${AWAIT_INDEX_URL:-https://index.rubygems.org}
GEM_URL=${AWAIT_GEM_URL:-https://rubygems.org}
# Gem::Net::HTTP sends this when the request has no Range header, which is bundler's
# cold-cache /info read.
NET_HTTP_ACCEPT_ENCODING="gzip;q=1.0,deflate;q=0.6,identity;q=0.3"

# A non-numeric override must not crash arithmetic mid-flight: use the default.
case $TIMEOUT in ''|*[!0-9]*) TIMEOUT=300 ;; esac
case $INTERVAL in ''|*[!0-9]*) INTERVAL=5 ;; esac
case $READS in ''|*[!0-9]*|0) READS=8 ;; esac

if [ ! -f "$LOCK" ]; then
  echo "::debug::$LOCK not found — nothing to await"
  exit 0
fi

deadline=$(( $(date +%s) + TIMEOUT ))

for gem in $GEMS; do
  # The lockfile spells a resolved gem as "    studio-engine (0.55.0)".
  version=$(sed -n "s/^ *${gem} (\([0-9][^)]*\))\$/\1/p" "$LOCK" | head -1)

  if [ -z "$version" ]; then
    echo "::debug::${gem} is not pinned in ${LOCK} — skipping"
    continue
  fi

  # `/info/<gem>` lists a version as "<version> <deps>|<checksums>". The trailing
  # space keeps 0.5.1 from matching 0.5.10; dots are escaped.
  info_pattern="^$(printf '%s' "$version" | sed 's/\./\\./g') "
  gem_file="${GEM_URL}/gems/${gem}-${version}.gem"
  polls=0

  while :; do
    polls=$(( polls + 1 ))
    listed=0
    stale=0
    unreachable=0

    read_n=0
    while [ "$read_n" -lt "$READS" ]; do
      read_n=$(( read_n + 1 ))
      # One curl process per read: a new connection, as each bundler worker opens.
      if body=$(curl -fsS --http1.1 --compressed --max-time 20 \
                  -H "Accept-Encoding: ${NET_HTTP_ACCEPT_ENCODING}" \
                  "${INDEX_URL}/info/${gem}" 2>/dev/null); then
        hits=$(printf '%s\n' "$body" | grep -cE "$info_pattern" || true)
        if [ "${hits:-0}" -gt 0 ]; then
          listed=$(( listed + 1 ))
        else
          stale=$(( stale + 1 ))
        fi
      else
        unreachable=$(( unreachable + 1 ))
      fi
    done

    # The download bundler makes for a gem it has not installed. -L follows a redirect.
    gem_status=$(curl -sS -o /dev/null -I -L --max-time 20 -w '%{http_code}' "$gem_file" 2>/dev/null || true)
    case $gem_status in
      2??) gem_state=served ;;
      4??) gem_state=missing ;;
      *)   gem_state=unreachable ;;
    esac

    if [ "$listed" -eq "$READS" ] && [ "$gem_state" = served ]; then
      echo "${gem} ${version} is served: /info listed it on ${READS} of ${READS} separate connections and the .gem answered ${gem_status} (poll ${polls})"
      break
    fi

    summary="/info listed it on ${listed} of ${READS} connections (${stale} stale, ${unreachable} unreachable); .gem ${gem_state} (${gem_status:-no answer})"

    if [ "$(date +%s)" -ge "$deadline" ]; then
      if [ "$stale" -gt 0 ] || [ "$gem_state" = missing ]; then
        echo "::error::GEM_NOT_SERVED_ON_RUNNER: ${gem} ${version} after ${TIMEOUT}s (${polls} polls): ${summary}. The RubyGems CDN still serves this runner a copy without the version, so bundle install would fail and wrongly report the version as removed. The lock is correct; the CDN is late. Not a race the release gate re-runs."
        exit 1
      fi
      echo "::warning::${gem} ${version}: RubyGems could not be read after ${TIMEOUT}s (${summary}) — continuing; a full bundler-cache hit needs no network"
      break
    fi

    echo "awaiting ${gem} ${version}: ${summary}"
    sleep "$INTERVAL"
  done
done

exit 0
