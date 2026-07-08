# frozen_string_literal: true

require "yaml"

# bin/lib/fast_cert.rb — test SELECTION for the G1 fast cert (bin/fast-check).
#
# The 90/10 rethink of local certification: GitHub CI already runs the FULL
# suite (+ test:system) on every PR push, and bin/dor-check blocks on CI green —
# so a ~6-minute local `bin/rails test` before handoff bought EARLINESS, not
# coverage. The fast cert keeps the earliness (catch the obvious break in ~1
# minute, before the commit/push round-trip) and leans on CI as the full net.
#
# This module is the PURE selection half — mapping a branch diff to the test
# files worth running — so it unit-tests directly (require it, call functions)
# without spawning the runner. bin/fast-check owns orchestration: lanes, gate
# emits, fingerprint-bound evidence.
#
# Selection = union of three sets:
#   1. CONVENTION — each changed file maps to its test by path convention
#      (app/models/x.rb → test/models/x_test.rb, views → their controller test,
#      bin/tool → test/lib/tool_test.rb, a changed *_test.rb includes itself).
#   2. GREP FALLBACK — a changed .rb file with NO existing convention target
#      falls back to a word-boundary grep of its class name (or a bin script's
#      name, or a config file's basename) across test/**/*_test.rb.
#   3. SPINE — config/fast_cert_spine.yml, a curated always-run core (critical
#      model/flow tests, ~10-15s) so a diff that maps to nothing still exercises
#      the money paths. Entries may be files or directories; missing paths are
#      skipped (a satellite worktree runs the hub's script but not its spine).
module FastCert
  # app/<layer>/<rest>.rb → test/<layer>/<rest>_test.rb for these layers
  # (nested paths carry through: app/controllers/api/v1/x_controller.rb →
  # test/controllers/api/v1/x_controller_test.rb).
  APP_LAYERS = %w[models controllers helpers jobs mailers services channels commands].freeze

  module_function

  # --- changed-file collection (mirrors bin/dor-check's changed_files) --------
  # Union of the three base-independent working-tree views (staged, unstaged,
  # untracked) + the committed diff against the release-aware base — so the
  # selection is the same whether the cert runs pre- or post-commit.
  def changed_files(root, base)
    files = []
    [
      %w[diff --cached --name-only],
      %w[diff --name-only],
      %w[ls-files --others --exclude-standard]
    ].each do |args|
      files.concat(capture(["git", "-C", root.to_s, *args]).split("\n"))
    end
    committed = capture(["git", "-C", root.to_s, "diff", "--name-only", "#{base}...HEAD"])
    files.concat(committed.split("\n"))
    files.map(&:strip).reject(&:empty?).uniq
  end

  # origin/release when it exists (post-cutover branches are cut off `release`,
  # which runs AHEAD of main), else origin/main — same default as bin/dor-check.
  def default_diff_base(root)
    ok = system("git", "-C", root.to_s, "rev-parse", "--verify", "origin/release",
                out: File::NULL, err: File::NULL)
    ok ? "origin/release" : "origin/main"
  rescue SystemCallError
    "origin/main"
  end

  # --- convention mapping ------------------------------------------------------
  # One changed path → its candidate test paths (existence NOT checked here; the
  # caller filters against the repo). Unmappable paths (docs, assets, db/) return
  # [] and rely on the grep fallback + spine.
  def convention_candidates(path)
    return [path] if path.match?(%r{\Atest/.+_test\.rb\z})

    case path
    when %r{\Aapp/views/(.+)/[^/]+\z}
      # A view/partial exercises through its controller (or mailer) test:
      # app/views/tasks/_gates.html.erb → test/controllers/tasks_controller_test.rb;
      # app/views/task_mailer/ping.html.erb → test/mailers/task_mailer_test.rb.
      dir = Regexp.last_match(1)
      ["test/controllers/#{dir}_controller_test.rb", "test/mailers/#{dir}_test.rb"]
    when %r{\Aapp/(#{APP_LAYERS.join("|")})/(.+)\.rb\z}
      ["test/#{Regexp.last_match(1)}/#{Regexp.last_match(2)}_test.rb"]
    when %r{\A(?:bin/)?lib/(.+)\.rb\z}
      # lib/foo.rb AND bin/lib/foo.rb → test/lib/foo_test.rb.
      ["test/lib/#{Regexp.last_match(1)}_test.rb"]
    when %r{\Abin/([^/]+)\z}
      # bin/fast-check → test/lib/fast_check_test.rb (the harness-test seam).
      ["test/lib/#{Regexp.last_match(1).tr('-', '_')}_test.rb"]
    else
      []
    end
  end

  # The word this file's grep fallback hunts for across test/: a class name for
  # a .rb file (gate_run.rb → GateRun), the script name for a bin tool
  # (bin/fast-check → "fast-check", how harness tests reference it), the bare
  # basename for a config file (config/fast_cert_spine.yml → "fast_cert_spine").
  # nil = no fallback for this path (views/docs/assets rely on the spine).
  def grep_token(path)
    case path
    when %r{\Abin/([^/]+)\z} then Regexp.last_match(1)
    when /\.rb\z/ then camelize(File.basename(path, ".rb"))
    when %r{\Aconfig/.+\.ya?ml\z} then File.basename(path).sub(/\.ya?ml\z/, "")
    end
  end

  def camelize(str)
    str.to_s.split(/[_\-]/).map { |part| part.sub(/\A[a-z]/) { |c| c.upcase } }.join
  end

  # Every test file under root whose text mentions `token` as a whole word.
  # Read-in-Ruby (not shell grep) for BSD/GNU portability and determinism.
  def grep_tests(root, token)
    return [] if token.to_s.strip.empty?

    re = /\b#{Regexp.escape(token)}\b/
    Dir.glob("test/**/*_test.rb", base: root.to_s).select do |rel|
      File.read(File.join(root, rel)).match?(re)
    rescue StandardError
      false
    end
  end

  # The diff-mapped test set: per changed file, its EXISTING convention targets;
  # when none exist, the grep fallback. Sorted + deduped, paths relative to root.
  def select_tests(root, changed)
    Array(changed).flat_map do |path|
      existing = convention_candidates(path).select { |t| File.file?(File.join(root, t)) }
      existing.empty? ? grep_tests(root, grep_token(path)) : existing
    end.uniq.sort
  end

  # --- spine --------------------------------------------------------------------
  # The curated always-run core from config/fast_cert_spine.yml. Entries may be
  # files or directories; only ones that exist under root survive (the hub's
  # spine list silently no-ops in a satellite checkout).
  def spine(root, config_path)
    data = YAML.safe_load(File.read(config_path.to_s)) || {}
    Array(data["spine"]).map(&:to_s).select { |p| File.exist?(File.join(root, p)) }
  rescue Errno::ENOENT, Psych::SyntaxError
    []
  end

  # Mapped tests already covered by a spine entry (exact file, or inside a spine
  # directory) are dropped from the mapped lane so nothing runs twice.
  def covered_by_spine?(test_path, spine_entries)
    Array(spine_entries).any? { |s| test_path == s || test_path.start_with?("#{s}/") }
  end

  # --- rubocop scope --------------------------------------------------------------
  # The changed files rubocop can actually lint: ruby by extension/name, plus bin
  # scripts with a ruby shebang. Deleted files are skipped (nothing to lint).
  RUBY_PATH_RE = /\.(rb|rake|gemspec|ru)\z/
  RUBY_BASENAMES = %w[Gemfile Rakefile config.ru].freeze

  def lintable_files(root, changed)
    Array(changed).select do |path|
      full = File.join(root, path)
      next false unless File.file?(full)
      next true if path.match?(RUBY_PATH_RE) || RUBY_BASENAMES.include?(File.basename(path))

      path.start_with?("bin/") && ruby_shebang?(full)
    end
  end

  def ruby_shebang?(full)
    File.open(full) { |f| f.gets }.to_s.include?("ruby")
  rescue StandardError
    false
  end

  def capture(argv)
    IO.popen(argv, err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end
end
