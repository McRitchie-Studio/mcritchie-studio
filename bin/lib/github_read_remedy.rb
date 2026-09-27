# frozen_string_literal: true

require_relative "fast_lane"

# The remedy a refusal prints when a GitHub read this process performed ITSELF —
# in Ruby, over HTTP, through Github::Client — could not be read.
#
# ── THE DEFECT THIS EXISTS TO STOP ───────────────────────────────────────────
#
# A printed remedy is a CAUSAL CLAIM: "run this and the refusal clears." When it
# does not, the operator loops, and every other refusal the house prints loses a
# little credit. bin/reviewer-select printed, on both of its credential refusals:
#
#     eval "$(bin/gh-auth-refresh --export)"
#
# That command's whole stdout contract is ONE line — `export GH_TOKEN='…'`
# (bin/gh-auth-refresh:209, and its header states the contract in as many words).
# But the read that had just failed was `Task#derived_authors_probe` →
# Github::TaskDerivation → Github::Client → Github::AppToken, and with App creds
# absent (the local case: neither the hub primary nor a desk .env carries
# GITHUB_APP_ID/GITHUB_APP_PRIVATE_KEY, measured 2026-09-27) AppToken#resolve
# returns `ENV[FALLBACK_TOKEN_ENV]` — **GITHUB_TOKEN**. GH_TOKEN is never
# consulted on that path; nothing there shells out to `gh` at all.
#
# So the operator followed the printed line verbatim and got the byte-identical
# refusal. Measured A/B on PR head 35efa05a, one working token, --file advisory:
#
#     ambient .env GITHUB_TOKEN        → `none` IS UNVERIFIED
#     GH_TOKEN=<working>               → `none` IS UNVERIFIED, byte for byte
#     GITHUB_TOKEN=<working>           → `none` IS CONTRADICTED ("…name: xan")
#
# ── THE RULE: THE CONSUMER PICKS THE VARIABLE ────────────────────────────────
#
# `eval "$(bin/gh-auth-refresh --export)"` is not a wrong string. It is the RIGHT
# string for a caller whose reader is `gh`, and the house is full of those:
# bin/task's archive guard shells `gh pr view` (bin/task:613), so
# lib/open_pr_guard.rb's remedy names GH_TOKEN correctly; bin/lib/acting_identity.rb
# probes `gh api user`, likewise. What makes a remedy true or false is not its
# text but WHICH PROCESS will read the variable it sets. So this module takes the
# env var name from the caller — which passes the consumer's own constant,
# `Github::AppToken::FALLBACK_TOKEN_ENV` — rather than hard-coding a spelling that
# can drift away from the thing it is supposed to refresh.
#
# ── WHY THE TOKEN COMES FROM bin/gh-token ────────────────────────────────────
#
# bin/gh-token is the one place a GitHub credential comes from (its own header
# says so), it prints the token on stdout as its documented contract, and it
# honours the lane's identity via GH_APP_ITEM. `bin/gh-auth-refresh` cannot serve
# here: its job is the keyring plus GH_TOKEN, and widening its single-line stdout
# contract would break the eval contract every other caller depends on.
#
# The path is resolved through FastLane so the printed line runs from ANY desk —
# a bare `bin/gh-token` typed on a satellite or gem desk dies as `No such file or
# directory`, which reads like a broken install rather than a wrong path.
module GithubReadRemedy
  module_function

  # `export <ENV>="$(<abs>/bin/gh-token)"` — a line an operator pastes into the
  # shell they will re-run the refusing command from.
  #
  # env_name: the variable THE READ CONSUMES. Callers pass their reader's own
  #           constant; nothing here guesses it.
  # bin_dirs: the speaking script's own __dir__ (a re-run remedy names the very
  #           script that is talking — see FastLane.resolve_bin).
  #
  # The double quotes around the substitution are deliberate: an unquoted `$( )`
  # would word-split a token, and `export X=$(…)` with an empty result silently
  # exports the empty string — which `gh` and AppToken both treat as "unset".
  def refresh_command(env_name, bin_dirs)
    name = env_name.to_s.strip
    raise ArgumentError, "refresh_command needs the env var the read consumes" if name.empty?

    %(export #{name}="$(#{FastLane.resolve_bin("gh-token", bin_dirs)})")
  end

  # A failure reason squeezed onto ONE line. The reason quoted into these refusals
  # is a GitHub API error whose body is multi-line JSON; interpolated raw it breaks
  # the indented refusal block's shape and every single-line log grep over it.
  def one_line(reason)
    reason.to_s.gsub(/\s+/, " ").strip
  end
end
