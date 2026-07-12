class Release
  # The spawn ENV for a LOCAL test gate (G3 pre-QA / G4 ship) — the overlay that
  # makes the gate reproduce CI's verdict instead of the gate host's mood.
  #
  # WHY (rel-20260711-7f2913, 2026-07-11): the gates red-flagged genuinely-green
  # code three times in one release; a reviewer nearly EJECTED a good PR on the
  # false negative. Ground truth: the release tip was byte-identical to a
  # clean-CI-green branch. The gate host differs from CI in ways the suite can
  # SEE, so the same commit gets two verdicts. This overlay erases the diffs:
  #
  #   1. RUBY — the host's `ruby` is brew's (the app ruby, by design); CI's is
  #      mise 3.3.11. Divergent gem homes break subprocess-spawning tests. Pinned
  #      by Release::GateRuby (PATH prepend); see that file for the full story.
  #   2. SESSION IDENTITY — an interactive agent session exports
  #      CLAUDE_CODE_SESSION_ID (Codex: CODEX_THREAD_ID); CI and a plain shell
  #      export NEITHER. The suite's deploy-tooling tests spawn bin/task,
  #      bin/fast-check and bin/pr-review via Open3; those INHERIT the var, so
  #      SessionIdentity (bin/lib/session_identity.rb) resolves to the LIVE
  #      operator session and actor/persona defaulting breaks. Scrubbed here, so
  #      the gate's whole process tree is session-less exactly like CI.
  #   3. TEST DATABASE — the gate ran on the shared primary's test DB, so a
  #      concurrent suite (an agent worktree, a hand-run `bin/rails test`) could
  #      pollute it mid-run. Pointed at the gate's PRIVATE test DB via
  #      TEST_DATABASE_URL (the seam config/database.yml already honours, and
  #      which beats DATABASE_URL).
  #
  # A nil value UNSETS the key in the child (Process.spawn semantics) — that's
  # how the session scrub reaches every grandchild the suite spawns, not just the
  # suite itself. `env -u` on the conductor's own shell could not do this: it
  # would unset the var for bin/release, not for the suite it spawns minutes later.
  #
  # PURE + Rails-free (like Release::GateRuby / Release::Repos) so bin/release can
  # require it standalone and a caller can unit-test the overlay without spawning.
  module GateEnv
    module_function

    # The agent-session identity vars. Every one is scrubbed for a gate run: CI
    # names no session, so neither may the gate.
    SESSION_KEYS = %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].freeze

    # PURE. The env overlay a gate subprocess spawns under.
    #   ruby_bin_dir      — mise's ruby bin dir (Release::GateRuby.resolve_ruby_bin_dir),
    #                       or blank on a mise-less host → no PATH pin, everything
    #                       else still applies.
    #   test_database_url — the gate's private test DB; blank → not set (the repo
    #                       falls back to config/database.yml's `database:`).
    #
    # ALWAYS non-empty (the session scrub is unconditional), so bin/release's
    # `env if env && !env.empty?` guard never drops it — a mise-less host still
    # gets the session scrub.
    def env(ruby_bin_dir: nil, test_database_url: nil, path_env: ENV["PATH"].to_s)
      overlay = Release::GateRuby.env(ruby_bin_dir: ruby_bin_dir, path_env: path_env)

      # nil => UNSET in the child. Not "" — SessionIdentity treats a blank id as
      # absent, but a literal "" would still be EXPORTED, and any other reader
      # keying on presence (ENV.key?) would see a session that isn't there.
      SESSION_KEYS.each { |key| overlay[key] = nil }

      url = test_database_url.to_s.strip
      overlay["TEST_DATABASE_URL"] = url unless url.empty?

      overlay
    end
  end
end
