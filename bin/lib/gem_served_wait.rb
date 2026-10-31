# frozen_string_literal: true

# THE WAIT BETWEEN `gem push` AND THE FIRST CONSUMER LOCK PUSH.
#
# WHAT IT FIXES (task gem-waits-for-rubygems). rel-20261029-00560a published
# studio-engine 0.119.0 at 19:15:48Z. The conductor's wait (await_published_gems!)
# read the compact index and the .gem from THIS machine's CDN edge, saw both, and
# let the consumer lock bumps go. alex-build's `static` job ran `bundle install` at
# 19:16:50Z, 62 seconds after the publish, and its runner's edge still answered
# "Your bundle is locked to studio-engine (0.119.0) ... can no longer be found in
# that source". voicebox's `lint` and `scan_ruby` lost the same race. The ship's
# test gate then stopped twice, and each fix was a hand `gh run rerun --failed`.
#
# ONE FRESH READ IS NOT PROOF. The conductor and a GitHub runner hit different
# Fastly edges, and RubyGems serves the compact index with `cache-control:
# max-age=60`. An edge that cached `/info/<gem>` or `/versions` before the publish
# can keep serving that copy until it expires. So "served" now means: every surface
# bundler reads answered with the version on consecutive polls spanning SETTLE
# seconds (the max-age), and a single miss inside that span starts it over.
#
# THE HOLD IS A HEURISTIC, NOT A BOUND. max-age=60 is what RubyGems asks for, not
# what every edge does: on 2026-10-29 Fastly edges answered with copies 442s and
# 2709s old. The hold narrows the race; it cannot observe a runner's edge, so the
# CI re-run backstop (bin/lib/ci_rerun.rb) still stands behind it.
#
# PURE: the probe, the clock and the sleeper are injected, so the tests drive every
# outcome (served at once, served after N polls, never served) with no network and
# no real sleeping. bin/release.rb wires the real curl probe and monotonic clock.
module GemServedWait
  module_function

  # The named refusal an operator (and a log grep) can find. On it, nothing was
  # pushed: the consumer locks are untouched and a re-run resumes.
  NOT_SERVED = "GEM_NOT_SERVED"

  # RubyGems' compact-index max-age: the longest a pre-publish edge copy should live.
  DEFAULT_SETTLE_S = 60

  # THE SURFACES, in the order bundler reads them. A probe that misses names the
  # FIRST one that did not list the version, so GEM_NOT_SERVED says which CDN object
  # is stale and the printed remedy checks THAT object (task release-gem-doc-followups:
  # the refusal used to say "re-run once /info lists it" even when /info already did).
  SURFACE_INFO = "/info"
  SURFACE_VERSIONS_TAIL = "/versions tail"            # the Range read missed; no full read this poll
  SURFACE_VERSIONS_FULL = "/versions full read"       # the tail and the whole file both missed
  SURFACE_VERSIONS_FULL_FAILED = "/versions full read (failed)" # the whole-file read errored or hit its cap
  SURFACE_GEM = ".gem"

  Result = Struct.new(:outcome, :polls, :elapsed, :miss, keyword_init: true) do
    def served? = outcome == :served
  end

  # Poll +probe+ until it has answered served continuously for +settle+ seconds, or
  # until +timeout+ seconds of wall time have passed.
  #
  #   probe:    -> one read of every surface: true when served; false, or a String
  #             naming the surface that missed (SURFACE_*), when not. The last miss's
  #             name rides on the Result as +miss+ (nil when served or unnamed).
  #   clock:    -> Float seconds, monotonic; read before the first probe and after each
  #   sleeper:  ->(seconds), called between polls, never after the last
  #   on_poll:  ->(poll_number, served, held_seconds), optional progress hook
  #
  # Returns Result(outcome: :served | :timeout, polls:, elapsed:).
  def await(probe:, timeout:, interval:, clock:, sleeper:, settle: DEFAULT_SETTLE_S, on_poll: nil)
    started = clock.call
    held_since = nil
    polls = 0
    miss = nil
    loop do
      polls += 1
      answer = probe.call
      served = answer && !answer.is_a?(String) ? true : false
      miss = served ? nil : (answer.is_a?(String) ? answer : nil)
      now = clock.call
      held_since = served ? (held_since || now) : nil
      held = held_since ? now - held_since : 0
      on_poll&.call(polls, served, held)

      return Result.new(outcome: :served, polls: polls, elapsed: now - started, miss: nil) if served && held >= settle
      return Result.new(outcome: :timeout, polls: polls, elapsed: now - started, miss: miss) if now - started >= timeout

      sleeper.call(interval)
    end
  end

  # PURE. Does a compact-index `/info/<gem>` body list +version+? Lines read
  # "<version> <deps>|<checksums>"; the version is field one, matched WHOLE, so 0.4
  # never satisfies a wait for 0.47.2.
  def info_lists?(body, version)
    body.to_s.lines.any? { |line| line.split(" ", 2).first.to_s.strip == version.to_s }
  end

  # PURE. The first surface whose check answers falsy, or nil when every one answers.
  # +checks+ is an ordered list of [surface, -> Boolean]; it stops at the first miss,
  # so a stale /info never pays for a /versions read.
  def first_miss(checks)
    checks.each { |surface, check| return surface unless check.call }
    nil
  end

  # PURE. Is +version+ of +gem_name+ on `/versions`? +tail_body+ is a Range read of
  # the file's END; +full+ (-> body, :failed, or nil) fetches the WHOLE file, and is
  # called only when the tail misses. See versions_miss for what each answer means.
  #
  # WHY THE TAIL IS NOT ENOUGH (Carl's bounce, 2026-10-29). RubyGems REBUILDS
  # /versions monthly (header `created_at: 2026-10-01T00:00:04Z`): the rebuild folds
  # each gem's versions into ONE alphabetical base line (studio-engine's at line
  # 170981 of 24.6 MB, ending at 0.82.0), and only later publishes are appended at
  # the tail. A 200 KB tail reaches back ~2.5 days. So an ALREADY-LIVE version (a
  # ship's skipped push, a prepare re-run) is in the base line, never the tail, and
  # a tail-only probe looped to GEM_NOT_SERVED on a gem bundler could install.
  def versions_served?(gem_name, version, tail_body, full: nil)
    versions_miss(gem_name, version, tail_body, full: full).nil?
  end

  # PURE. nil when `/versions` lists +version+, else the surface that missed:
  #   the tail missed and +full+ read nothing (nil: rationed, or no reader) → SURFACE_VERSIONS_TAIL
  #   the whole-file read failed (:failed: a curl error or its time cap)  → SURFACE_VERSIONS_FULL_FAILED
  #   the whole file was read and does not list it                       → SURFACE_VERSIONS_FULL
  def versions_miss(gem_name, version, tail_body, full: nil)
    return nil if versions_lists?(drop_cut_line(tail_body), gem_name, version)

    body = full&.call
    return SURFACE_VERSIONS_TAIL if body.nil?
    return SURFACE_VERSIONS_FULL_FAILED if body == :failed

    versions_lists?(body, gem_name, version) ? nil : SURFACE_VERSIONS_FULL
  end

  # PURE. The one command an operator runs to see the surface that missed answer,
  # so GEM_NOT_SERVED's remedy follows the failure. +urls+ carries the three URL
  # templates bin/release.rb owns: info: (gem), versions:, file: (gem, version).
  def remedy(miss, gem_name:, version:, urls:)
    case miss
    when SURFACE_VERSIONS_TAIL, SURFACE_VERSIONS_FULL
      "`curl -s #{urls[:versions]} | grep '^#{gem_name} '` lists #{version} (the whole ~25 MB file: " \
        "a version from before the monthly rebuild is in the base line, not the tail)"
    when SURFACE_VERSIONS_FULL_FAILED
      "`curl -s #{urls[:versions]} | grep '^#{gem_name} '` lists #{version}; the whole-file read failed or hit " \
        "its cap, so raise RELEASE_GEM_VERSIONS_FULL_MAX_TIME (seconds) if this link is slow"
    when SURFACE_GEM
      "`curl -sfIL -o /dev/null #{format(urls[:file], gem_name, version)}` exits 0 (the .gem artifact is served)"
    else
      "`curl -s #{format(urls[:info], gem_name)} | tail -3` lists #{version}"
    end
  end

  # PURE. A Range read starts mid-line: its first line is a FRAGMENT, and a cut
  # "foo-studio-engine 0.119.0 …" reads as "studio-engine 0.119.0". Drop everything
  # up to the first newline. (A server that ignores Range sends the whole file,
  # whose first line is the `created_at:` header, so dropping it costs nothing.)
  def drop_cut_line(body)
    text = body.to_s
    cut = text.index("\n")
    cut ? text[(cut + 1)..] : ""
  end

  # PURE. Does a compact-index `/versions` body list +version+ for +gem_name+? Lines
  # read "<gem> <v1>,<v2>,... <info-md5>", and a gem appears on more than one line as
  # versions are appended, so every line for the gem counts. A yank is "-<v>".
  def versions_lists?(body, gem_name, version)
    listed = false
    body.to_s.each_line do |line|
      name, list, = line.split(" ", 3)
      next unless name == gem_name.to_s

      list.to_s.split(",").each do |v|
        if v == version.to_s then listed = true
        elsif v == "-#{version}" then listed = false
        end
      end
    end
    listed
  end
end
