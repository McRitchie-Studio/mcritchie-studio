# frozen_string_literal: true

# Subprocess stubs shared by the release-CLI tests.
#
# These live OUTSIDE test/lib/release_cli_test.rb on purpose. That file is a
# frozen hotspot in config/test_health.yml — 26 of the last 200 merged PRs touched
# it, all colliding at the bottom of one 7364-line file — and the ratchet's remedy
# for "I need to add something" is to give the thing its own named home rather
# than append. A stub injected into a subprocess is a reusable fixture, not a
# test, so it belongs here.
module ReleaseCliStubs
  # Makes solana-studio read as NOT self-gated.
  #
  # It registered a `release_check` on 2026-08-20, when it grew bin/release-check
  # alongside its Rails engine, so NO registered gem is non-self-gated any more.
  # The two preflight guards that refuse a non-self-gated gem — the gem-only
  # candidate and the no-swept-consumer case — still have to bite for the next gem
  # onboarded without a runner, so they CREATE the condition instead of borrowing
  # it from the registry. A test that needed some real gem to stay runner-less was
  # testing the registry, not the guard.
  #
  # Injected after `load bin/release.rb`, so the production script grows no
  # test-only seam.
  NOT_SELF_GATED = <<~'RUBY'
    def self_gated_gem?(repo)
      return false if repo.to_s == "solana-studio"

      !gem_meta_for(repo)["release_check"].to_s.strip.empty?
    end
  RUBY
end
