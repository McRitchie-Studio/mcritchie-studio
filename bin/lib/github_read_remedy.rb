# frozen_string_literal: true

require_relative "remedy"

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
# (the `export` branch, bin/gh-auth-refresh#export, and its header states the contract in as many words).
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
# bin/task's archive guard shells `gh pr view` (bin/task#archive_pr_state), so
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
# The command itself is rendered by Remedy.token_export (bin/lib/remedy.rb), the one
# helper every printed remedy goes through; this module keeps the reasoning and the
# one-line squeeze for the failure reason quoted beside it.
module GithubReadRemedy
  module_function

  # A failure reason squeezed onto ONE line. The reason quoted into these refusals
  # is a GitHub API error whose body is multi-line JSON; interpolated raw it breaks
  # the indented refusal block's shape and every single-line log grep over it.
  def one_line(reason)
    reason.to_s.gsub(/\s+/, " ").strip
  end
end
