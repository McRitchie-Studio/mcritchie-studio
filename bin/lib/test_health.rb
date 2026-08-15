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
# state 18 of 100 e2e specs are already in, un-tracked for the Ruby side until now.
# The ratchet does NOT demand the number go down — it forbids it going UP silently.
module TestHealth
  # A test opener in either dialect: `test "name" do` (declarative) or `def test_x`.
  TEST_OPENER = /^(\s*)(?:test\s+["']|def\s+test_)/
  # Anything that makes a test an assertion rather than a smoke run. `assert_nothing_
  # raised` and `pass` count: they are deliberate statements about behaviour.
  ASSERTION = /\b(?:assert\w*|refute\w*|flunk|pass)\b|\.must_|\.wont_/
  SKIP_CALL = /^\s*skip\b/

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
  def skips(root)
    test_files(root).sum { |file| File.read(file).lines.count { |l| l.match?(SKIP_CALL) } }
  rescue SystemCallError
    0
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
    lines.each_with_index do |line, index|
      match = TEST_OPENER.match(line)
      next unless match

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
