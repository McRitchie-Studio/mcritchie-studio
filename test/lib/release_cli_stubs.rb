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

  # Makes solana-studio read as NOT self-gated. NO registered gem is non-self-gated now, but the
  # two preflight guards that refuse one (the gem-only candidate and the no-swept-consumer case)
  # must still bite for the next runner-less gem, so they CREATE the condition. Injected after
  # `load bin/release.rb`, so the production script grows no test-only seam. PREPEND + super, not
  # a copy: restating `!gem_meta_for(repo)["release_check"].to_s.strip.empty?` is a second home
  # for the predicate. Overriding only the ONE repo and calling super keeps production the single
  # source.
  # History: task stand-up-onchain-engine.
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

  # Prepare's reuse path (a final already live at a re-run) with its two reads
  # named instead of run: the served gem compared with this tree, and the tag a
  # stopped run never pushed. Their real behaviour is driven in
  # release_gem_final_at_prepare_test.rb.
  REUSED_FINAL = <<~'RUBY'
    def verify_reused_final!(repo, _tip, final) = $stdout.puts("REUSE-VERIFIED " + repo + " " + final)
    def ensure_release_tag!(repo, version, _frozen) = $stdout.puts("TAG-ENSURED " + repo + " v" + version)
  RUBY
end
