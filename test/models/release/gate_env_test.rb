require "test_helper"
require "open3"

# The gate's spawn env — the overlay that makes a LOCAL gate run reproduce CI's
# verdict instead of the gate host's mood. See Release::GateEnv.
class Release::GateEnvTest < ActiveSupport::TestCase
  E = Release::GateEnv

  RUBY_BIN = "/Users/x/.local/share/mise/installs/ruby/3.3.11/bin".freeze

  # --- the session scrub (the false-negative that nearly ejected a good PR) ---

  test "[unit] env UNSETS both agent-session ids (nil, not empty string)" do
    overlay = E.env(ruby_bin_dir: RUBY_BIN, path_env: "/usr/bin")

    # nil => Process.spawn REMOVES the key from the child's env. "" would still
    # export the var, and a reader keying on presence would see a session that
    # isn't there.
    assert overlay.key?("CLAUDE_CODE_SESSION_ID")
    assert overlay.key?("CODEX_THREAD_ID")
    assert_nil overlay["CLAUDE_CODE_SESSION_ID"]
    assert_nil overlay["CODEX_THREAD_ID"]
  end

  test "[unit] env scrubs the session even on a mise-less host (no ruby pin)" do
    # GateRuby.env returns {} with no ruby_bin_dir. The scrub must survive that,
    # or bin/release's `env if env && !env.empty?` guard drops the overlay whole
    # and the session leaks back into the suite.
    overlay = E.env(ruby_bin_dir: "", path_env: "/usr/bin")

    assert_not overlay.empty?, "a mise-less host must STILL get the session scrub"
    assert_nil overlay["CLAUDE_CODE_SESSION_ID"]
    assert_not overlay.key?("PATH"), "no pinned ruby => no PATH pin"
  end

  # --- the ruby pin still rides (composed from GateRuby) ---------------------

  test "[unit] env keeps the mise ruby leading PATH" do
    overlay = E.env(ruby_bin_dir: RUBY_BIN, path_env: "/usr/bin:/bin")

    assert_equal "#{RUBY_BIN}:/usr/bin:/bin", overlay["PATH"]
  end

  # --- the private test DB ---------------------------------------------------

  test "[unit] env points the suite at the gate's private test DB" do
    overlay = E.env(ruby_bin_dir: RUBY_BIN, test_database_url: "postgres:///x_gate_test")

    assert_equal "postgres:///x_gate_test", overlay["TEST_DATABASE_URL"]
  end

  test "[unit] env omits TEST_DATABASE_URL when none is given" do
    # Blank must not export an empty TEST_DATABASE_URL: config/database.yml
    # renders `url:` from it, and an empty url would override the `database:`
    # fallback with nothing.
    assert_not E.env(ruby_bin_dir: RUBY_BIN).key?("TEST_DATABASE_URL")
    assert_not E.env(ruby_bin_dir: RUBY_BIN, test_database_url: "  ").key?("TEST_DATABASE_URL")
  end

  # --- REGRESSION (end-to-end): the scrub actually reaches a spawned child ----
  #
  # This is the test that FAILS on the old gate. Before the fix the gate's overlay
  # was GateRuby.env — a PATH pin and nothing else — so a gate run launched from
  # an interactive agent session handed CLAUDE_CODE_SESSION_ID straight down to
  # the suite, and from the suite to every bin/task | bin/fast-check | bin/pr-review
  # it spawns via Open3. SessionIdentity then resolved to the OPERATOR'S LIVE
  # SESSION instead of "no session" (what CI sees), and the actor/persona
  # defaulting tests false-failed on green code.
  #
  # It spawns for real (rather than asserting on the hash) because the claim under
  # test is about Process.spawn's nil-means-unset semantics, not about our Hash.
  # capture3 (stdout only): the child re-initializes bundler and warns on stderr
  # (the brew-vs-mise gem-home split), which capture2e would fold into stdout.
  test "[integration] a subprocess spawned under the gate env sees NO session id" do
    parent = { "CLAUDE_CODE_SESSION_ID" => "live-operator-session", "CODEX_THREAD_ID" => "live-codex-thread" }
    probe  = 'print [ENV["CLAUDE_CODE_SESSION_ID"].inspect, ENV["CODEX_THREAD_ID"].inspect].join(",")'

    # Sanity: WITHOUT the overlay the child inherits the live session — this is
    # exactly the pollution the gate suffered.
    leaked, = Open3.capture3(parent, RbConfig.ruby, "-e", probe)
    assert_equal %q("live-operator-session","live-codex-thread"), leaked,
                 "baseline: a plain spawn DOES inherit the agent session"

    # WITH it, the child is session-less — identical to CI.
    overlay = parent.merge(E.env(ruby_bin_dir: ""))
    scrubbed, = Open3.capture3(overlay, RbConfig.ruby, "-e", probe)
    assert_equal "nil,nil", scrubbed,
                 "the gate env must UNSET both session ids in the spawned suite"
  end

  test "[integration] SessionIdentity resolves to no-session under the gate env" do
    # The consumer that actually broke: bin/lib/session_identity.rb resolves
    # CLAUDE_CODE_SESSION_ID -> CODEX_THREAD_ID -> [nil, nil]. Under the gate env
    # it must land on [nil, nil] — the CI posture — even when the conductor was
    # launched from a live agent session.
    parent = { "CLAUDE_CODE_SESSION_ID" => "live-operator-session" }
    probe  = <<~RUBY
      require #{Rails.root.join('bin/lib/session_identity').to_s.inspect}
      print SessionIdentity.identity.inspect
    RUBY

    leaked, = Open3.capture3(parent, RbConfig.ruby, "-e", probe)
    assert_equal %q(["live-operator-session", "claude"]), leaked,
                 "baseline: SessionIdentity picks up the live session"

    scrubbed, = Open3.capture3(parent.merge(E.env(ruby_bin_dir: "")), RbConfig.ruby, "-e", probe)
    assert_equal "[nil, nil]", scrubbed,
                 "under the gate env the suite must see the same no-session env CI does"
  end
end
