# frozen_string_literal: true

# Standalone test for bin/install-agent-docs' `status_line` array rewrite — the
# `ensure_array_item` / `array_value_span` pair inside `ensure_codex_tui_config`.
# Run directly:
#   ruby -Itest test/commands/install_agent_docs_status_line_array_test.rb
# It is also picked up by the normal `bin/rails test` sweep.
#
# THE DEFECT THIS GUARDS (reproduced against origin/accepted before the fix):
# `ensure_array_item` located `status_line` by its FIRST line and rewrote that line
# in place. For a hand-authored MULTI-LINE array it therefore replaced only the
# opening `status_line = [` and stranded every element line plus the closing bracket
# as bare text:
#
#   status_line = ["thread-title", "model-with-reasoning", "context-remaining"]
#     "model-with-reasoning",
#     "current-dir",
#   ]
#
# That is not valid TOML, and Codex REFUSES to load it rather than reformatting it:
#   Error loading config.toml: …:6:25: key with no value, expected `=`
# So running the installer BRICKED the operator's own Codex runtime config. Blast
# radius is narrow — every single-line layout and every installer-written config was
# fine — but the write is config-corrupting, which is why it is guarded here.
#
# CRITICAL: every run sandboxes HOME and PROJECTS_DIR into a throwaway tmp dir, so
# the installer never touches the operator's real ~/.codex/config.toml.
#
# Tier split (backend shape → unit + integration):
#   test_unit_*        — the config rewriter over fixtures, no install round trip
#   test_integration_* — a full `bin/install-agent-docs install` across the filesystem

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"

class InstallAgentDocsStatusLineArrayTest < Minitest::Test
  ROOT   = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "install-agent-docs")

  # The orphan signature the defect produced: an element line sitting at top level
  # because the array it belonged to was closed off above it.
  ORPHAN_ELEMENT = /^\s+"[a-z-]+",?\s*$/

  MANAGED_ITEMS = %w[thread-title model-with-reasoning context-remaining].freeze

  def setup
    @sandbox = Dir.mktmpdir("install-agent-docs-status-line")
    @home    = File.join(@sandbox, "home")
    @projects = File.join(@sandbox, "projects")
    FileUtils.mkdir_p([@home, @projects])
    @config = File.join(@home, ".codex", "config.toml")

    @rewriter = extract_config_rewriter
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  # ── fixture ───────────────────────────────────────────────────────────────

  # Lift the Ruby that `ensure_codex_tui_config` heredocs into `ruby - "$config"`, so
  # the unit tier drives THE REAL SOURCE rather than a copy that could drift from it.
  #
  # The extraction asserts it found a non-trivial block. Without that, a refactor
  # moving the Ruby out of the heredoc would leave this file passing against an empty
  # program — a test that runs, reports green, and checks nothing.
  def extract_config_rewriter
    body = File.read(SCRIPT)
    block = body[/ruby - "\$config" <<'RUBY'\n(.*?)\nRUBY\n/m, 1]

    refute_nil block,
      "could not find the embedded config rewriter in #{SCRIPT} — if it moved, point " \
      "this test at its new home instead of letting it pass against nothing"
    assert_includes block, "def ensure_array_item",
      "the extracted block must be the rewriter under test"

    path = File.join(@sandbox, "tui_config.rb")
    File.write(path, block)
    path
  end

  def rewrite(toml)
    path = File.join(@sandbox, "config-under-test.toml")
    File.write(path, toml)
    _out, err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, @rewriter, path)
    assert status.success?, "config rewriter crashed: #{err}"
    File.read(path)
  end

  # The `status_line` value, as the lines that make it up.
  def status_line_block(toml)
    lines = toml.lines
    first = lines.index { |line| line.match?(/^\s*status_line\s*=/) }
    refute_nil first, "rewritten config lost its status_line key entirely:\n#{toml}"
    return lines[first, 1] if lines[first].match?(/=\s*\[.*\]/)

    last = ((first + 1)...lines.length).find { |i| lines[i].match?(/^\s*\]/) }
    refute_nil last, "multi-line status_line array was never closed:\n#{toml}"
    lines[first..last]
  end

  def status_line_items(toml)
    status_line_block(toml).join.scan(/"([^"]+)"/).flatten
  end

  # The invariant the defect violated: nothing may be left outside a bracket pair.
  def assert_no_orphaned_elements(toml)
    inside = false
    toml.lines.each_with_index do |line, index|
      inside = true  if line.match?(/=\s*\[\s*(#.*)?$/)
      if !inside && line.match?(ORPHAN_ELEMENT)
        flunk "line #{index + 1} is a bare array element at top level — the config is " \
              "corrupt and Codex will refuse to load it:\n#{toml}"
      end
      inside = false if inside && line.match?(/^\s*\]/)
    end
  end

  # ── unit ──────────────────────────────────────────────────────────────────

  def test_unit_multi_line_status_line_survives_the_rewrite
    result = rewrite(<<~TOML)
      [tui]
      status_line = [
        "model-with-reasoning",
        "current-dir",
      ]
      status_line_use_colors = true
    TOML

    assert_no_orphaned_elements(result)
    assert_equal %w[model-with-reasoning current-dir thread-title],
      status_line_items(result),
      "the operator's own items must survive, with thread-title ADDED to them"
    assert_operator status_line_block(result).length, :>, 1,
      "the operator wrote one element per line; the installer must keep that layout"

    # "Preserving the layout" includes the indentation, which is the claim
    # app-registry.md now makes on the installer's behalf.
    element_indents = status_line_block(result)
      .select { |line| line.match?(/^\s*"/) }
      .map { |line| line[/\A\s*/] }
    assert_equal ["  ", "  ", "  "], element_indents,
      "the added element must adopt the indentation of the ones already there"
  end

  def test_unit_multi_line_without_a_trailing_comma_stays_valid
    result = rewrite(<<~TOML)
      [tui]
      status_line = [
        "model-with-reasoning",
        "current-dir"
      ]
    TOML

    assert_no_orphaned_elements(result)
    assert_equal %w[model-with-reasoning current-dir thread-title], status_line_items(result)
    refute_match(/"current-dir"\s*\n\s*"thread-title"/, result,
      "an element appended after an uncomma'd one must terminate it first, or the " \
      "array is two strings jammed together and TOML rejects it")
  end

  def test_unit_multi_line_already_carrying_thread_title_is_left_alone
    source = <<~TOML
      [tui]
      status_line = [
        "thread-title",
        "current-dir",
      ]
    TOML
    result = rewrite(source)

    assert_equal %w[thread-title current-dir], status_line_items(result),
      "membership is a property of the ARRAY, not of its opening line — checking only " \
      "the first line would append a duplicate thread-title here"
  end

  def test_unit_empty_multi_line_array_gains_the_item
    result = rewrite(<<~TOML)
      [tui]
      status_line = [
      ]
    TOML

    assert_no_orphaned_elements(result)
    assert_equal %w[thread-title], status_line_items(result)
  end

  def test_unit_comment_on_the_opening_line_is_preserved
    result = rewrite(<<~TOML)
      [tui]
      status_line = [ # my layout
        "current-dir",
      ]
    TOML

    assert_no_orphaned_elements(result)
    assert_equal %w[current-dir thread-title], status_line_items(result)
    assert_includes result, "# my layout", "the operator's comment must survive"
  end

  def test_unit_single_line_layout_behaviour_is_unchanged
    result = rewrite(<<~TOML)
      [tui]
      status_line = ["model-with-reasoning", "current-dir"]
    TOML

    assert_includes result, %(status_line = ["model-with-reasoning", "current-dir", "thread-title"]),
      "a single-line array must still be extended in place, on one line"
  end

  def test_unit_non_array_value_is_replaced_with_the_managed_default
    result = rewrite(<<~TOML)
      [tui]
      status_line = "nonsense"
    TOML

    assert_equal MANAGED_ITEMS, status_line_items(result),
      "a scalar cannot be extended, so the managed default replaces it — this is the " \
      "ONE case the installer does not preserve, and app-registry.md says so"
  end

  def test_unit_rewrite_is_idempotent
    source = <<~TOML
      [tui]
      status_line = [
        "model-with-reasoning",
        "current-dir",
      ]
    TOML

    once  = rewrite(source)
    twice = rewrite(once)

    assert_equal once, twice, "running the installer twice must not keep growing the array"
  end

  # ── integration ───────────────────────────────────────────────────────────

  def fake_zsh
    path = File.join(@sandbox, "fake-zsh")
    return path if File.executable?(path)

    File.write(path, <<~SH)
      #!/bin/sh
      if [ "$1" = "-lc" ]; then
        shift
        [ -f "$HOME/.zprofile" ] && . "$HOME/.zprofile"
        exec /bin/sh -c "$1"
      fi
      exec /bin/sh "$@"
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def run_installer
    Open3.capture3(
      SessionEnv.neutralized(
        "HOME" => @home,
        "PROJECTS_DIR" => @projects,
        "CODEX_REQUIREMENTS_PATH" => File.join(@sandbox, "etc", "codex", "requirements.toml"),
        "AGENT_RUNTIME_RUBY_PATH_PREFIX" => File.dirname(RbConfig.ruby),
        "AGENT_RUNTIME_ZSH" => fake_zsh
      ),
      SCRIPT, "install"
    )
  end

  def test_integration_install_does_not_corrupt_a_hand_authored_multi_line_config
    FileUtils.mkdir_p(File.dirname(@config))
    File.write(@config, <<~TOML)
      model = "gpt-5-codex"

      [tui]
      status_line = [
        "model-with-reasoning",
        "current-dir",
      ]
      status_line_use_colors = true
    TOML

    _out, err, status = run_installer
    assert status.success?, "installer failed: #{err}"

    result = File.read(@config)
    assert_no_orphaned_elements(result)
    assert_equal %w[model-with-reasoning current-dir thread-title], status_line_items(result)
    assert_includes result, 'model = "gpt-5-codex"', "unrelated config must be untouched"
  end

  # A `codex`-runtime end-to-end check LIVED HERE and was deliberately removed.
  #
  # It asserted that the installer's output loads in the real Codex binary, guarded
  # by `skip "codex not installed on this machine"`. On a CI runner codex is never
  # installed, so it could NEVER run there — and `config/rails_lane.yml`'s skip
  # ceiling is a RATCHET compared against `origin/release`: keeping it would have
  # raised the baseline permanently, for a test guaranteed to skip forever. That is
  # the "suite quietly growing skips" the ratchet exists to stop, and paying it for
  # coverage CI cannot obtain is the wrong trade.
  #
  # THE FACT IT PROVED IS NOT LOST, and it was established by direct measurement
  # rather than by this test: the pre-fix rewriter was run against a multi-line
  # fixture and `codex exec` REFUSED the result —
  #   Error loading config.toml: …:6:25: key with no value, expected '='
  # while the untouched control loaded fine. Refusal, not reformatting. That
  # verification is recorded on /tasks/wire-doctor-to-codex-inspect.
  #
  # What remains here covers the installer's OUTPUT SHAPE, which is what this repo
  # can actually verify: the array survives multi-line, keeps its indentation, and
  # strands no orphaned elements. If you want the runtime leg back, give it a home
  # that is not gated on a binary CI does not have.


end
