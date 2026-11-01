# frozen_string_literal: true

# THE RUBY SUITE'S HEALTH, counted from source.
#
# config/e2e_lane.yml already ratchets the browser lane (declared − quarantined ==
# executed) and nothing did the same for the 6,582 Ruby test cases. This is that
# counter, and config/test_health.yml is the contract it is compared against.
#
# WHAT THIS CAN AND CANNOT SEE — say it plainly, because the e2e ratchet's own header
# warns that every escape hatch lived in the gap between "declared" and "ran". This
# reads SOURCE. It can tell you a test declares no assertion, or that it calls `skip`.
# It cannot tell you a test RAN, or that an assertion it declared actually executed
# (a guard clause can return before one). The durable half of that question is
# mutation testing, which the grooming act owns; this half is the cheap one that fails
# in milliseconds and keeps the number honest between grooming passes.
#
# WHY COUNT SKIPS AT ALL. A skip is a test that has been switched off without being
# deleted, so the suite keeps its name and loses its coverage. That is precisely the
# state a quarantined e2e spec is in. The ratchet does NOT demand the number go down —
# it forbids it rising above the merge base's count.
require "open3"
require "ripper"
require "yaml"

module TestHealth
  # A test opener in either dialect: `test "name" do` (declarative) or `def test_x`.
  TEST_OPENER = /^(\s*)(?:test\s+["']|def\s+test_)/
  # Anything that makes a test an assertion rather than a smoke run. `assert_nothing_
  # raised` and `pass` count: they are deliberate statements about behaviour.
  ASSERTION = /\b(?:assert\w*|refute\w*|flunk|pass)\b|\.must_|\.wont_/
  SKIP_CALL = /^\s*skip\b/
  # Used when a repo's config/test_health.yml carries no such key, so a sibling repo can
  # adopt bin/test-health with no config at all. No ceiling means nothing to exceed.
  DEFAULT_COMMENT_CAP = 8
  DEFAULT_TEST_ROOTS = %w[test e2e].freeze
  DEFAULT_PRODUCTION_ROOTS = %w[app lib bin].freeze
  COMMENT_FILE = /\.(?:rb|js|mjs|ts)\z/

  module_function

  # Every *_test.rb under `root`, sorted so a report is stable across machines.
  def test_files(root)
    Dir.glob(File.join(root.to_s, "**", "*_test.rb")).sort
  end

  # [{file:, line:, name:}, ...] for tests that declare NO assertion and do NOT skip.
  #
  # A test with neither is a test that cannot fail for the reason it was written: it
  # exercises code and asserts nothing about it, so it goes green whatever the code
  # does. That is worse than no test, because it reports coverage it does not have.
  def assertion_free(root)
    test_files(root).flat_map { |file| assertion_free_in(File.read(file), file) }
  rescue SystemCallError
    []
  end

  # Explicit `skip` calls. Counted per CALL SITE, not per executed test: a conditional
  # skip may or may not fire at runtime, and this is the static half.
  #
  # HEREDOC BODIES ARE EXCLUDED, and that is not a nicety. This guard's own integration
  # test builds fixture suites out of heredocs, several of which necessarily contain
  # `skip "later"` — the very thing being tested. Counting those made the ratchet fail
  # on the commit that introduced it. Any test that DOCUMENTS a skip in a string or
  # heredoc hits the same false positive, so the fix belongs here rather than in the
  # callers that would otherwise have to write around their own instrument.
  def skips(root)
    test_files(root).sum { |file| skips_in(File.read(file)) }
  rescue SystemCallError
    0
  end

  # ---- the merge base: the one copy of the numbers a diff cannot move ----------
  #
  # The skip count and the frozen hotspots' sizes are compared with the same counts at
  # the merge base, not with numbers stored in config/test_health.yml. A stored number
  # needs an edit on every legitimate move in either direction; the merge base needs
  # none, and it is the one copy the author's own diff cannot reach.
  #
  # TEST_HEALTH_BASE names the base explicitly (the hermetic integration test uses it);
  # otherwise it is `git merge-base HEAD origin/accepted`, the branch every PR merges
  # into. nil means the base cannot be read, and the callers fail closed on nil.
  BASE_BRANCH = "origin/accepted"

  def base_ref(root)
    explicit = ENV["TEST_HEALTH_BASE"].to_s.strip
    sha = if explicit.empty?
            git(root, "merge-base", "HEAD", BASE_BRANCH)
          else
            git(root, "rev-parse", "--verify", "--quiet", "#{explicit}^{commit}")
          end
    sha.to_s.empty? ? nil : sha
  end

  # Stripped stdout on success (possibly empty), nil on failure.
  def git(root, *args)
    out, _err, status = Open3.capture3("git", "-C", root.to_s, *args)
    status.success? ? out.strip : nil
  rescue SystemCallError
    nil
  end

  # { "test/a_test.rb" => source } for every *_test.rb under test/ at `ref`, read in one
  # `git cat-file --batch` pass so a thousand files cost one process.
  def test_sources_at(root, ref)
    listing = git(root, "ls-tree", "-r", "--name-only", ref, "--", "test")
    return nil if listing.nil?

    paths = listing.lines.map(&:strip).select { |path| path.end_with?("_test.rb") }
    blobs(root, paths.map { |path| "#{ref}:#{path}" }).then { |bodies| paths.zip(bodies).to_h }
  end

  # Skip call sites at `ref`, or nil when the ref cannot be read.
  def skips_at(root, ref)
    sources = test_sources_at(root, ref)
    sources&.values&.sum { |source| skips_in(source.to_s) }
  end

  # Line count of `path` at `ref`, or nil when the file is not there.
  def lines_at(root, ref, path)
    blobs(root, ["#{ref}:#{path}"]).first&.lines&.count
  end

  # Frozen files that GREW past their size at the merge base: [{file:, lines:, base:}].
  # A file missing now (deleted or renamed) or absent at the base (new) is not an
  # offender: shrinking and splitting are always allowed.
  def grown(root, frozen, ref)
    Array(frozen).filter_map do |path|
      full = File.join(root.to_s, path)
      next unless File.exist?(full)

      base = lines_at(root, ref, path)
      next if base.nil?

      lines = File.foreach(full).count
      { file: path, lines: lines, base: base } if lines > base
    end
  end

  # The bodies of `specs` (each "<ref>:<path>"), nil for one that does not exist.
  def blobs(root, specs)
    return [] if specs.empty?

    out, status = Open3.capture2("git", "-C", root.to_s, "cat-file", "--batch", stdin_data: specs.join("\n") + "\n",
                                 binmode: true)
    return Array.new(specs.size) unless status.success?

    bodies = []
    cursor = 0
    specs.size.times do
      header_end = out.index("\n", cursor)
      header = out[cursor...header_end]
      cursor = header_end + 1
      if header.end_with?(" missing")
        bodies << nil
        next
      end

      size = header.split(" ").last.to_i
      bodies << out.byteslice(cursor, size).force_encoding(Encoding::UTF_8)
      cursor += size + 1
    end
    bodies
  rescue SystemCallError
    Array.new(specs.size)
  end

  # ---- the comment-block cap ------------------------------------------------
  #
  # A block is a run of full-line comments on adjacent lines. A blank line ends it, so
  # the cap can be dodged with blank lines, which review has to catch. The why fits in
  # eight lines and the story belongs in the PR.

  def comment_cap(config)
    config.dig("comment_blocks", "max_lines") || DEFAULT_COMMENT_CAP
  end

  def test_roots(config)
    config.dig("line_budget", "roots") || DEFAULT_TEST_ROOTS
  end

  # PURE. [{file:, line:, lines:, text:}, ...], one per block, for Ruby or JS `source`.
  def comment_blocks_in(source, file)
    clean = source.scrub
    found = file.end_with?(".rb") ? ruby_comment_lines(clean) : js_comment_lines(clean)
    found.slice_when { |a, b| b[0] != a[0] + 1 }.map do |run|
      { file: file, line: run.first[0], lines: run.size, text: run.map { |_, body| body.strip }.join("\n") }
    end
  end

  # Ripper, not a line regex: a `#` inside a heredoc is fixture text, not a comment.
  def ruby_comment_lines(source)
    lines = source.lines
    Ripper.lex(source).filter_map do |(line, column), type, token, _state|
      next [line, token] if %i[on_embdoc_beg on_embdoc on_embdoc_end].include?(type)
      next unless type == :on_comment

      [line, token] if lines[line - 1].byteslice(0, column).strip.empty?
    end
  end

  # `//` lines only. A /* */ block is not counted; every spec here uses `//`.
  def js_comment_lines(source)
    source.lines.each_with_index.filter_map { |text, index| [index + 1, text] if text.match?(%r{\A\s*//}) }
  end

  # Blocks over `cap` in { path => source }. The regex is a cheap sound filter: a block
  # over the cap needs a run this long, so most files never reach the lexer.
  def long_blocks(sources, cap)
    run = /(?:^[ \t]*(?:#|\/\/).*\R){#{cap + 1}}|^=begin/
    sources.flat_map do |path, source|
      next [] unless path.match?(COMMENT_FILE) && source.to_s.scrub.match?(run)

      comment_blocks_in(source, path).select { |block| block[:lines] > cap }
    end
  end

  # Long blocks in `now` the base cannot account for. A block the base holds verbatim is
  # a move; one no longer than a block it replaced in the same file is an edit. Each
  # base block answers for one block only, so the count of long blocks can only fall.
  def new_long_blocks(now, base, cap)
    changed = (now.keys | base.keys).reject { |path| now[path] == base[path] }
    gone = long_blocks(base.slice(*changed), cap)
    moved = ->(block) { claim(gone) { |old| old[:text] == block[:text] } }
    edited = ->(block) { claim(gone) { |old| old[:file] == block[:file] && old[:lines] >= block[:lines] } }
    long_blocks(now.slice(*changed), cap).reject(&moved).reject(&edited)
  end

  def claim(pool, &match)
    index = pool.index(&match)
    pool.delete_at(index) if index
  end

  # ---- the tree, as git sees it ----------------------------------------------

  # Tracked and untracked-but-not-ignored paths under `roots`, or nil outside git.
  def tree_paths(root, roots)
    listing = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "--", *roots)
    listing&.lines&.map(&:strip)&.select { |path| File.file?(File.join(root.to_s, path)) }
  end

  def comment_sources(root, roots)
    Array(tree_paths(root, roots)).grep(COMMENT_FILE).to_h do |path|
      [path, File.binread(File.join(root.to_s, path)).force_encoding(Encoding::UTF_8)]
    end
  end

  def comment_sources_at(root, ref, roots)
    paths = git(root, "ls-tree", "-r", "--name-only", ref, "--", *roots)&.lines&.map(&:strip)&.grep(COMMENT_FILE)
    return nil if paths.nil?

    paths.zip(blobs(root, paths.map { |path| "#{ref}:#{path}" })).to_h
  end

  # Newlines in text files under `roots`. A file with a NUL byte is binary and counts 0.
  def line_total(root, roots)
    Array(tree_paths(root, roots)).sum do |path|
      body = File.binread(File.join(root.to_s, path))
      body.include?("\0") ? 0 : body.count("\n")
    end
  end

  # Net lines against `ref` by numstat. nil when git cannot answer.
  def net_lines(root, ref, roots)
    stat = git(root, "diff", "--numstat", ref, "--", *roots)
    stat&.lines&.sum do |line|
      added, deleted, = line.split("\t")
      added.to_i - deleted.to_i
    end
  end

  # ---- the line budget --------------------------------------------------------

  # The budget at a glance. `over` compares the tree with the ceiling; `net_*` compare it
  # with the merge base, and are nil when there is no base to read.
  def budget_report(root, config, ref)
    budget = config["line_budget"] || {}
    total = line_total(root, test_roots(config))
    ceiling = budget["ceiling"]
    { total: total, ceiling: ceiling, over: ceiling ? [total - ceiling, 0].max : 0,
      enforce: budget["enforce"] == true,
      net_test: ref && net_lines(root, ref, test_roots(config)),
      net_production: ref && net_lines(root, ref, budget["production_roots"] || DEFAULT_PRODUCTION_ROOTS) }
  end

  def budget_summary(report)
    cap = report[:ceiling] ? "ceiling #{report[:ceiling]}, over by #{report[:over]}" : "no ceiling set"
    "#{report[:total]} test lines (#{cap}); this diff: test #{signed(report[:net_test])}, " \
      "production #{signed(report[:net_production])}; " \
      "#{report[:long_comment_blocks] || "unknown"} grandfathered long comment blocks"
  end

  def signed(number)
    number.nil? ? "unknown" : format("%+d", number)
  end

  # A hard failure only once `enforce` is on: over the ceiling AND adding lines. A PR that
  # cuts lines always passes, or the budget would block the cut that clears it.
  def budget_exceeded?(report)
    report[:enforce] && report[:over].positive? && report[:net_test].to_i.positive?
  end

  # The ceiling at `ref`, or nil when the file or key is absent there. It may only fall.
  def ceiling_at(root, ref)
    body = blobs(root, ["#{ref}:config/test_health.yml"]).first
    body && YAML.safe_load(body)&.dig("line_budget", "ceiling")
  rescue Psych::Exception
    nil
  end

  def ceiling_raised?(root, config, ref)
    before = ceiling_at(root, ref)
    now = config.dig("line_budget", "ceiling")
    !before.nil? && (now.nil? || now > before)
  end

  # Everything the shared check reports, for any repo root: a sibling needs no config.
  def check(root, config = load_config(root))
    ref = base_ref(root)
    report = budget_report(root, config, ref)
    sources = comment_sources(root, test_roots(config))
    report[:long_comment_blocks] = long_blocks(sources, comment_cap(config)).size
    failures = []
    failures << "no merge base with #{BASE_BRANCH}, so the ratchets have no baseline" if ref.nil?
    base = ref && comment_sources_at(root, ref, test_roots(config))
    fresh = base ? new_long_blocks(sources, base, comment_cap(config)) : []
    fresh.each do |block|
      failures << "#{block[:file]}:#{block[:line]} is a #{block[:lines]}-line comment block, new or grown " \
                  "since the merge base; the cap is #{comment_cap(config)}. Keep the why, move the story to the PR."
    end
    failures << "the test-line ceiling rose above the merge base's" if ref && ceiling_raised?(root, config, ref)
    failures << budget_summary(report) if budget_exceeded?(report)
    { report: report, failures: failures }
  end

  def load_config(root)
    path = File.join(root.to_s, "config", "test_health.yml")
    File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
  end

  # PURE. Which lines of `source` are CODE — i.e. not inside a heredoc body.
  #
  # Shared by both detectors, because both were bitten by the same thing: this guard's
  # own tests build fixture suites out of heredocs, and those fixtures necessarily
  # contain `skip "later"` and a deliberately assertion-free test. Scanning heredoc
  # bodies counted the fixtures as real findings and made the ratchet fail on the very
  # commit that introduced it. Any test that DOCUMENTS a skip or a bad test in a string
  # hits the same false positive, so the exclusion belongs in the instrument.
  def code_lines(source)
    tag = nil
    source.lines.map do |line|
      if tag
        tag = nil if line.strip == tag
        next nil
      end
      # Opens a heredoc: <<~TAG, <<-TAG, <<TAG, optionally quoted.
      if (open = line[/<<[~-]?["']?([A-Z_]+)["']?/, 1])
        tag = open
        next nil
      end
      line
    end
  end

  # PURE. Skip call sites in `source`, ignoring anything inside a heredoc body.
  def skips_in(source)
    code_lines(source).count { |line| line&.match?(SKIP_CALL) }
  end

  # PURE, so the vectors below are testable without a repo on disk.
  #
  # Block extraction is INDENT-MATCHED, not brace-counted: a test body ends at the
  # first line that is exactly the opener's indent followed by `end`. That is the
  # house style throughout this suite, and it means a nested block, heredoc or string
  # containing the word `end` cannot truncate the body early and hide the assertions
  # below it — which would report a perfectly good test as assertion-free.
  def assertion_free_in(source, file = "(source)")
    found = []
    lines = source.lines
    # Openers are looked for in CODE only — a test declared inside a heredoc is a
    # fixture, not a test this suite runs. The body is still read from the raw lines,
    # since indent matching already handles nesting correctly.
    code = code_lines(source)
    code.each_with_index do |code_line, index|
      match = code_line && TEST_OPENER.match(code_line)
      next unless match

      line = lines[index]

      indent = match[1]
      closer = "#{indent}end"
      body = []
      ((index + 1)...lines.length).each do |cursor|
        break if lines[cursor].rstrip == closer

        body << lines[cursor]
      end
      joined = body.join
      next if joined.match?(ASSERTION) || joined.match?(SKIP_CALL)

      found << { file: file, line: index + 1, name: test_name(line) }
    end
    found
  end

  def test_name(line)
    line[/^\s*test\s+["'](.+?)["']/, 1] || line[/^\s*def\s+(test_\w+)/, 1] || line.strip
  end
end
