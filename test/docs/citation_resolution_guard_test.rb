# frozen_string_literal: true

require "test_helper"

# EVERY CITATION OF CODE IS A SEAM.
#
# A `path:line` citation is true only at the SHA it was written against: every commit
# to the cited file shifts the lines below its edit, and a shifted citation reads
# exactly like the truth. A seam, `path#symbol`, names a definition, so no edit
# elsewhere in the file can move it. This guard holds the house rule stated in
# docs/agents/modules/docs-maintenance.md under "Citing Code From Prose", in two lanes.
# Neither reads the prose around a citation, so no rephrasing gets past them.
#
#   2. `path#symbol` must land on a DEFINITION in that file. This is what makes a seam
#      trustworthy rather than merely rot-proof.
#   3. No `path:line` citation into this repo exists. The ceiling is zero, so the
#      rotting format cannot come back.
#
# ITS LIMITS:
#
#   A. `definition?` is deliberately broad, so a seam can resolve while naming the
#      wrong landmark in the right file. Resolution proves the symbol is THERE, never
#      that it is the one the sentence is about.
#   B. A citation whose path is not a file in this checkout is skipped: prose here
#      legitimately cites the engine gem, Ruby stdlib, gem internals and sibling repos.
#   C. A prose seam ("in `commit_gem_version!`, at its refusal") is checked by review.
class CitationResolutionGuardTest < ActiveSupport::TestCase
  # The directories a citation into THIS repo can start with. A token that starts
  # anywhere else is not addressed to this checkout and is none of this guard's
  # business.
  REPO_DIRS = %w[app bin config db docs e2e lib public script test].freeze
  DIRS_RE = REPO_DIRS.join("|")

  LINE_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_]):(\d+)(?:-(\d+))?\b}
  SEAM_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_])\#([A-Za-z_][A-Za-z0-9_]*[!?]?)}

  # A RUBY BACKTRACE FRAME IS EVIDENCE, NOT A POINTER. `foo.rb:118:in 'block in
  # apply_moves!'` inside a fixture is a captured crash, what the interpreter said at
  # the SHA it crashed on; counting it would push the next editor to falsify the
  # evidence the test exists to pin. Ruby prints the frame label IN QUOTES (backtick on
  # older rubies, straight on 3.4), and requiring the quote is what keeps a sentence
  # that types `:in ` after a line number inside the census.
  BACKTRACE_FRAME = /\A:in\s+["'`]/

  # What counts as a DEFINITION for lane 2. Deliberately broad (`def`, a class or
  # module, a constant or local assignment, a YAML key, a shell function) because a
  # seam must be able to name any real landmark, including a top-level script's
  # variables. It is still pure resolution: the token either appears in one of these
  # positions in that file or it does not.
  def definition?(lines, symbol)
    q = Regexp.escape(symbol)
    lines.any? do |l|
      # The trailing guard is a LOOKAHEAD, never `\b`: a Ruby name can end in `!` or
      # `?`, and `\b` after a non-word character demands a word character next.
      l.match?(/\b(?:def|class|module|alias)\s+(?:self\.)?#{q}(?![A-Za-z0-9_])/) ||
        l.match?(/^\s*#{q}\s*(?:\(\)|:)(?:\s|\z|\{)/) ||
        # `\z` on the value side is load-bearing: `RELEASE_REPOS =` opens a
        # multi-line literal, so the assignment's own line ends right after the `=`.
        l.match?(/(?:\A|[^.\w])#{q}\s*=(?:[^=~]|\z)/)
    end
  end

  SCANNED_GLOBS = [
    "app/**/*.rb", "bin/*", "bin/lib/**/*.rb", "bin/lib/*.sh",
    "config/**/*.yml", "config/**/*.rb", "db/**/*.rb",
    "docs/**/*.md", "lib/**/*.rb", "test/**/*.rb", ".github/workflows/*.yml"
  ].freeze

  # Historical snapshots record what was true when they were written. THIS FILE is
  # excluded because its fixtures below are citations on purpose.
  EXCLUDED = [%r{/docs/agents/archive/}, %r{/test/docs/citation_resolution_guard_test\.rb\z}].freeze

  # A source-scanning test is exit-blind: if a glob stops matching, the loop body never
  # runs and the test passes having proved nothing. These floors make a green run mean
  # something. The citation floor counts both forms together, so converting a line
  # citation to a seam never walks the tree under it.
  MINIMUM_FILES = 1200
  MINIMUM_CITATIONS = 100

  # LANE 3: no `path:line` citations. A line number rots on the next commit to the file
  # it names, and a seam cannot.
  LINE_CITATION_CEILING = 0

  def test_every_seam_citation_lands_on_a_definition
    offenders = census[:seam].filter_map do |c|
      next if definition?(c[:target], c[:symbol])

      "#{c[:where]} cites #{c[:text]} — #{c[:path]} defines no #{c[:symbol]}"
    end

    assert_census_is_real

    assert_empty offenders, <<~MSG
      #{offenders.size} seam citation(s) name something the cited file does not define:

      #{offenders.join("\n      ")}

      A seam citation is only worth more than a line number because it can be
      CHECKED. Name a definition that is actually in that file — if the landmark
      lives in a sibling (a shim vs. the script it loads), cite the file that
      defines it.
    MSG
  end

  def test_no_citation_names_a_line
    offenders = census[:line]

    assert_census_is_real
    assert_operator offenders.size, :<=, LINE_CITATION_CEILING, <<~MSG
      #{offenders.size} `path:line` citation(s), over the ceiling of #{LINE_CITATION_CEILING}:

      #{offenders.map { |c| "#{c[:where]} cites #{c[:text]}" }.join("\n      ")}

      A line number rots on the next commit to the file it names. Cite the SEAM
      instead: `path#method_name` for a line inside a method, or the nearest constant
      or variable for top-level script code. Lane 2 verifies a seam on every run.
    MSG
  end

  # LANE 3 BITES: the census reads every spelling of a line citation into this repo,
  # a range included, and only a real backtrace frame escapes it.
  def test_the_line_census_counts_a_line_citation_and_spares_a_backtrace_frame
    body = <<~TEXT
      See bin/task:12 for the move, and bin/release.rb:40-48 for the range.
      Crash: bin/release.rb:118:in 'block in apply_moves!'
      Prose: bin/submit:128:in question for the discarded status.
      Elsewhere: turf-monster/app/models/contest.rb:9 and lib/net/protocol.rb:3.
    TEXT

    cited = line_citations_in(body).map { |m| m[0] }

    assert_includes cited, "bin/task:12"
    assert_includes cited, "bin/release.rb:40-48"
    assert_includes cited, "bin/submit:128", "a sentence that types `:in ` is not a frame"
    refute_includes cited, "bin/release.rb:118", "a recorded backtrace frame is evidence, not a pointer"
  end

  REAL_FRAMES = [":in `git': git ls-files", ":in 'DocsArchive.git': git mv",
                 ":in 'block in apply_moves!'"].freeze
  NOT_FRAMES = [":in question for the discarded status.", ":in the sweep", ":inbound",
                ":in  — see above", ":in the release, 'quoted' later"].freeze

  def test_the_backtrace_exemption_requires_the_frames_own_quote
    REAL_FRAMES.each do |tail|
      assert BACKTRACE_FRAME.match?(tail),
             "#{tail.inspect} is what the interpreter prints; exempting it is the whole point"
    end

    NOT_FRAMES.each do |tail|
      refute BACKTRACE_FRAME.match?(tail),
             "#{tail.inspect} is prose, not a frame — exempting it would let a sentence " \
             "carry a line citation out of the census"
    end
  end

  # A seam citation is checked against DEFINITIONS, so the definition rule has to
  # recognise every shape this repo uses to declare a landmark, and must not accept a
  # mere mention.
  def test_the_definition_rule_recognises_the_shapes_this_repo_uses
    lines = [
      "def conductor_payload(ruby)",
      "  def self.refusal(task_bin:, slug:, root:)",
      "BASE_BRANCH = ENV.fetch(\"SHIP_BASE_BRANCH\", \"accepted\")",
      "class CertRootGuard",
      "  wrong_root = CertRootGuard.refusal(task_bin: TASK_BIN)",
      "  release_check: bin/release-check",
      "op_meter_refused() {"
    ]

    %w[conductor_payload refusal BASE_BRANCH CertRootGuard wrong_root release_check
       op_meter_refused].each do |symbol|
      assert definition?(lines, symbol), "#{symbol} is defined here and must resolve"
    end

    mention_only = ["  payload = conductor_payload(with_conductor_session(ruby))",
                    "# see conductor_payload for the Base64 bootstrap"]

    refute definition?(mention_only, "conductor_payload"),
           "a MENTION is not a definition — accepting one is how a seam citation to the " \
           "wrong file (a shim rather than the script it loads) reads as resolved"
  end

  private

  # ONE WALK, read by both lanes. A citation whose path is not a file in THIS checkout
  # is absent from both lists (limit B).
  def census
    @census ||= begin
      line = []
      seam = []
      files = 0

      scan_files.each do |path|
        body = read_text(path) or next

        files += 1
        where = ->(m) { "#{relative(path)}:#{line_of(body, m)}" }

        line_citations_in(body).each do |m|
          line << { where: where.(m), text: m[0] } if target_lines(m[1])
        end

        body.to_enum(:scan, SEAM_CITATION).each do
          m = Regexp.last_match
          target = target_lines(m[1]) or next

          seam << { where: where.(m), text: m[0], path: m[1], symbol: m[2], target: target }
        end
      end

      { files: files, line: line, seam: seam }
    end
  end

  # Every `path:line` match in a body that is not a recorded backtrace frame. Whether
  # the path is a file in this checkout is the caller's question.
  def line_citations_in(body)
    body.to_enum(:scan, LINE_CITATION).map { Regexp.last_match }
        .reject { |m| BACKTRACE_FRAME.match?(body[m.end(0), 8].to_s) }
  end

  def assert_census_is_real
    assert_operator census[:files], :>=, MINIMUM_FILES,
                    "scanned only #{census[:files]} files (expected >= #{MINIMUM_FILES}); the " \
                    "globs have stopped matching, so a clean result here proves nothing"

    found = census[:line].size + census[:seam].size
    assert_operator found, :>=, MINIMUM_CITATIONS,
                    "found only #{found} citations of either form (expected >= " \
                    "#{MINIMUM_CITATIONS}); the patterns have rotted"
  end

  def scan_files
    @scan_files ||= SCANNED_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob)] }
                                 .select { |p| File.file?(p) }
                                 .reject { |p| EXCLUDED.any? { |re| re.match?(p) } }
                                 .uniq
                                 .sort
  end

  # The cited file's lines, or nil when the path is not a file in THIS checkout.
  def target_lines(path)
    @targets ||= {}
    @targets.fetch(path) do
      full = Rails.root.join(path)
      @targets[path] = (File.file?(full) ? read_text(full)&.split("\n", -1) : nil)
    end
  end

  def read_text(path)
    body = File.read(path, encoding: "UTF-8")
    body.valid_encoding? ? body : nil
  rescue ArgumentError, Errno::ENOENT, Errno::EISDIR
    nil
  end

  def line_of(body, match) = body[0, match.begin(0)].count("\n") + 1

  def relative(path) = Pathname.new(path.to_s).relative_path_from(Rails.root).to_s
end
