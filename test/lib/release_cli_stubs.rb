# frozen_string_literal: true

# Subprocess stubs shared by the release-CLI tests.
#
# These live OUTSIDE the release CLI harness on purpose. The harness is a frozen
# hotspot in config/test_health.yml, and the ratchet's remedy for "I need to add
# something" is to give the thing its own named home rather than append. A stub injected into a subprocess is a reusable fixture, not a
# test, so it belongs here.
module ReleaseCliStubs
  # A token broker that answers every mint with a fake token and reaches nothing,
  # so a push under test passes the ship's pre-mint. One per test process.
  def self.token_broker
    @token_broker ||= begin
      dir = Dir.mktmpdir("release-cli-broker")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      File.join(dir, "gh-token").tap do |path|
        File.write(path, "#!/bin/sh\necho stub-deployer-token\n")
        File.chmod(0o755, path)
      end
    end
  end

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
  # PREPEND + super, not a copy. An earlier version restated bin/release.rb's own
  # `!gem_meta_for(repo)["release_check"].to_s.strip.empty?` inline, which is a
  # second home for a predicate that has one — change the real one and this stub
  # keeps asserting the old rule, green. Overriding only the ONE repo and calling
  # super for every other keeps production as the single source.
  NOT_SELF_GATED = <<~'RUBY'
    self.singleton_class.prepend(Module.new do
      def self_gated_gem?(repo)
        repo.to_s == "solana-studio" ? false : super
      end
    end)
  RUBY

  # The ship's final publish with its three RubyGems reads answered: a candidate
  # tagged at the frozen SHA, and the two comparisons named instead of run. Their
  # real behaviour is driven in release_ship_final_gem_test.rb.
  FINAL_PUBLISH = <<~'RUBY'
    def publish_gem(repo, version, before_push: nil) = $stdout.puts("PUBLISH-CALLED " + repo + " " + version)
    def confirm_published_checksum!(repo, version, _sha) = $stdout.puts("CHECKSUM-CONFIRMED " + repo + " " + version)
    def verify_live_final!(repo, version, candidate) = $stdout.puts("LIVE-FINAL-COMPARED " + repo + " " + version + " " + candidate)
    def ensure_release_tag!(*) = nil
    def gem_stamp_problems(*) = [] # these fixtures' conductor carries no release metadata
    self.singleton_class.prepend(Module.new do
      def git_capture(*args) = args.join(" ").include?("tag --points-at") ? ["rc-0.11.0.rc1\n", true] : super
    end)
  RUBY
end
