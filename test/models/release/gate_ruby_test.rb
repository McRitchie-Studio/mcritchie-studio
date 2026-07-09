require "test_helper"

class Release
  # Regression coverage for the local-gate ruby pin (Release::GateRuby).
  #
  # GATE-HOST ENV (the bug this closes — rel-38f895, 2026-07-09): on the McRitchie
  # gate host `which ruby` is brew's ruby@3.3 (the app ruby, by design), while CI
  # runs mise 3.3.11. The pre-QA / ship gates spawn `bin/rails test`; that suite's
  # deploy-tooling meta-tests spawn bin/release / bin/dor-check subprocesses whose
  # `#!/usr/bin/env ruby` shebang resolves `ruby` off PATH → brew's ruby, whose
  # gem home DIVERGES from mise's → `already initialized constant
  # Gem::Platform::JAVA` at subprocess boot → nonzero exit → the meta-tests
  # false-fail (3-6 failures, run-to-run). Prepending mise's ruby bin dir to the
  # gate subprocess PATH makes the suite AND its children resolve `env ruby` to
  # mise → local == CI, so the collision can't happen.
  #
  # NOTE brew@3.3 and mise are BOTH ruby 3.3.11 — the split is the GEM HOME, not
  # the version — so the integration assertions check the resolved ruby PATH, not
  # RUBY_VERSION (which can't tell brew from mise apart).
  class GateRubyTest < ActiveSupport::TestCase
    # --- pure env overlay ----------------------------------------------------
    test "[unit] prepends the mise ruby bin dir to PATH so env ruby resolves to mise" do
      overlay = GateRuby.env(ruby_bin_dir: "/m/ruby/3.3.11/bin", path_env: "/usr/bin:/bin")
      assert_equal({ "PATH" => "/m/ruby/3.3.11/bin:/usr/bin:/bin" }, overlay)
    end

    test "[unit] the pinned bin dir LEADS PATH (wins the shebang lookup)" do
      overlay = GateRuby.env(ruby_bin_dir: "/m/bin", path_env: "/opt/homebrew/opt/ruby@3.3/bin:/usr/bin")
      assert overlay["PATH"].start_with?("/m/bin:"),
        "mise must lead PATH so `env ruby` beats brew; got #{overlay["PATH"].inspect}"
    end

    test "[unit] returns an EMPTY overlay (fall back to the shell ruby) when unavailable" do
      assert_equal({}, GateRuby.env(ruby_bin_dir: nil, path_env: "/usr/bin"))
      assert_equal({}, GateRuby.env(ruby_bin_dir: "", path_env: "/usr/bin"))
      assert_equal({}, GateRuby.env(ruby_bin_dir: "   ", path_env: "/usr/bin"))
    end

    test "[unit] tolerates a blank inherited PATH" do
      assert_equal({ "PATH" => "/m/bin" }, GateRuby.env(ruby_bin_dir: "/m/bin", path_env: ""))
    end

    # --- pure path helpers ---------------------------------------------------
    test "[unit] install_dir + ruby_bin_dir point at the mise ruby install for the pin" do
      assert_equal "/home/x/.local/share/mise/installs/ruby/3.3.11",
        GateRuby.install_dir(home: "/home/x")
      assert_equal "/home/x/.local/share/mise/installs/ruby/3.3.11/bin",
        GateRuby.ruby_bin_dir(home: "/home/x")
    end

    test "[unit] resolve_ruby_bin_dir is nil when the pinned ruby isn't installed" do
      Dir.mktmpdir do |home|
        assert_nil GateRuby.resolve_ruby_bin_dir(home: home), "no install dir → nil → caller falls back"
      end
    end

    test "[unit] resolve_ruby_bin_dir returns the bin dir when the pinned ruby exists" do
      Dir.mktmpdir do |home|
        bin = GateRuby.ruby_bin_dir(home: home)
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "ruby"), "#!/bin/sh\n")
        File.chmod(0o755, File.join(bin, "ruby"))
        assert_equal bin, GateRuby.resolve_ruby_bin_dir(home: home)
      end
    end

    test "[unit] RUBY_PIN tracks the repo's canonical ruby (.ruby-version)" do
      # The bin/release wrapper resolves the gate ruby from .ruby-version; this pin
      # must not drift from it, or the gate would pin a DIFFERENT ruby than the
      # wrapper (re-opening the very divergence this closes).
      pinned = Rails.root.join(".ruby-version").read.strip
      assert_equal pinned, GateRuby::RUBY_PIN,
        "GateRuby::RUBY_PIN (#{GateRuby::RUBY_PIN}) must equal .ruby-version (#{pinned})"
    end

    # --- real toolchain: the divergence the fix closes -----------------------
    # `command -v ruby` is EXACTLY the PATH lookup the `#!/usr/bin/env ruby`
    # shebang (that bin/rails / bin/release subprocesses take) performs — without
    # booting ruby+gems, which is downstream and depends on the ambient bundler
    # env (clean in the real gate). So these assert the resolution the overlay
    # actually controls: does the pinned PATH make `env ruby` land on mise.
    test "[integration] the overlay makes `env ruby` resolve to the mise ruby (not brew)" do
      bin_dir = GateRuby.resolve_ruby_bin_dir
      skip "mise ruby@#{GateRuby::RUBY_PIN} not installed on this host" unless bin_dir

      overlay = GateRuby.env(ruby_bin_dir: bin_dir)
      resolved = IO.popen([overlay, "sh", "-c", "command -v ruby"], &:read).to_s.strip
      assert_equal File.join(bin_dir, "ruby"), resolved,
        "the pinned gate PATH must resolve `env ruby` to mise (not brew), got #{resolved.inspect}"
      refute_includes resolved, "homebrew", "must NOT be brew's ruby: #{resolved.inspect}"
    end

    test "[integration] a GRANDCHILD lookup under the overlay also lands on mise ruby" do
      bin_dir = GateRuby.resolve_ruby_bin_dir
      skip "mise ruby@#{GateRuby::RUBY_PIN} not installed on this host" unless bin_dir

      # The suite spawns bin/release / bin/dor-check, which themselves spawn more
      # ruby — that transitive PATH inheritance is the whole point (the brew/mise
      # mix is what collided). A nested shell must ALSO resolve ruby to mise.
      overlay = GateRuby.env(ruby_bin_dir: bin_dir)
      resolved = IO.popen([overlay, "sh", "-c", "sh -c 'command -v ruby'"], &:read).to_s.strip
      assert_equal File.join(bin_dir, "ruby"), resolved,
        "env ruby in a grandchild under the overlay must resolve to mise, got #{resolved.inspect}"
    end
  end
end
