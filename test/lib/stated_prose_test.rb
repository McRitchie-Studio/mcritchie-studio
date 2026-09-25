# frozen_string_literal: true

# Tests for test/support/stated_prose.rb — the population guards over stated prose read.
#
#   ruby -Itest test/lib/stated_prose_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHY THE POPULATION GETS ITS OWN TEST. A grade against the LIVE tree answers "does it
# reach config/ and app/ today". It cannot answer "would it still find anything if the
# reader were broken", because a reader that returns nothing and a tree with no defects are the same green.
#
# THAT IS NOT HYPOTHETICAL — it is what happened. The first draft matched comment
# lines with `/\A\s*#\s?(.*)\z/` against a line that still had its newline. `.` never
# crosses a newline and `\z` is the absolute end of the string, so NO line matched,
# every non-markdown file read as blank, and the first probe of this population
# reported a perfectly clean tree while scanning nothing at all. The assertions below
# are written against prose whose answer is spelled out beside it, so a reader that
# stops reading reds here instead of going quiet.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../support/stated_prose"

class StatedProseTest < Minitest::Test
  # ── [unit] reading a file's prose ──────────────────────────────────────────

  def test_markdown_is_returned_whole
    Dir.mktmpdir do |dir|
      path = File.join(dir, "note.md")
      File.write(path, "# Heading\n\nA claim about five lanes.\n")

      assert_equal "# Heading\n\nA claim about five lanes.\n", StatedProse.prose(path)
    end
  end

  def test_a_ruby_comment_body_is_read_as_prose
    Dir.mktmpdir do |dir|
      path = File.join(dir, "thing.rb")
      File.write(path, "# A claim about five lanes.\nPOOL = %w[a b].freeze\n")

      assert_includes StatedProse.prose(path), "A claim about five lanes."
    end
  end

  def test_code_lines_are_blanked_rather_than_read
    Dir.mktmpdir do |dir|
      path = File.join(dir, "thing.rb")
      File.write(path, "# a claim\nPOOL = %w[a b].freeze\nclass Thing; end\n")
      prose = StatedProse.prose(path)

      refute_includes prose, "POOL", "a constant assignment is not a claim"
      refute_includes prose, "class Thing", "a class body is not a claim"
    end
  end

  # The whole reason blanking beats dropping: an offender cites a line a reader opens.
  def test_line_numbers_survive_blanking
    Dir.mktmpdir do |dir|
      path = File.join(dir, "thing.rb")
      File.write(path, "CODE = 1\nCODE = 2\n# the claim is on line three\n")

      assert_equal 3, StatedProse.prose(path).lines.size
      assert_includes StatedProse.prose(path).lines[2], "the claim is on line three"
    end
  end

  # A lone `#` must become an empty line, or a whole comment block reads as ONE
  # paragraph and a guard's per-paragraph provenance can borrow a command from
  # twenty lines away.
  def test_a_lone_comment_marker_becomes_a_paragraph_break
    Dir.mktmpdir do |dir|
      path = File.join(dir, "thing.rb")
      File.write(path, "# first claim\n#\n# second claim\n")

      assert_equal 2, StatedProse.prose(path).split(/\n[ \t]*\n/).size
    end
  end

  def test_an_indented_yaml_comment_is_read
    Dir.mktmpdir do |dir|
      path = File.join(dir, "registry.yml")
      File.write(path, "key:\n    # an indented claim about lanes\n    value: 1\n")

      assert_includes StatedProse.prose(path), "an indented claim about lanes"
      refute_includes StatedProse.prose(path), "value: 1"
    end
  end

  # ── [unit] the exemption convention ────────────────────────────────────────

  def test_archive_is_excluded_as_a_path_segment_not_a_prefix
    root = "/repo"

    assert StatedProse.excluded?(root, "/repo/docs/archive/old.md")
    refute StatedProse.excluded?(root, "/repo/docs/archived-tasks.md"),
           "a bare /archive fragment exempts this LIVE doc silently"
    refute StatedProse.excluded?(root, "/repo/docs/archiver.md")
  end

  def test_nested_desks_and_this_suite_are_excluded
    root = "/repo"

    assert StatedProse.excluded?(root, "/repo/.worktrees/some-task/docs/agents/index.md"),
           "a desk is a full checkout nested inside the primary"
    assert StatedProse.excluded?(root, "/repo/test/docs/review_lane_docs_test.rb"),
           "a guard cannot scan its own verbatim fixtures"
    assert StatedProse.excluded?(root, "/repo/node_modules/pkg/README.md")
  end

  def test_a_path_outside_the_root_is_excluded_rather_than_raising
    assert StatedProse.excluded?("/repo", "/elsewhere/docs/thing.md")
  end

  def test_a_banner_in_the_first_ten_lines_freezes_the_file
    Dir.mktmpdir do |dir|
      frozen = File.join(dir, "snapshot.md")
      live   = File.join(dir, "live.md")
      deep   = File.join(dir, "deep.md")
      File.write(frozen, "# Audit\n\nARCHIVE-ONLY snapshot.\n")
      File.write(live, "# Spec\n\nStages: shipped then archived.\n")
      File.write(deep, "#{"filler\n" * 12}ARCHIVE-ONLY\n")

      assert StatedProse.frozen_record?(frozen)
      refute StatedProse.frozen_record?(live),
             "the task STAGE word `archived` must not freeze a live spec"
      refute StatedProse.frozen_record?(deep),
             "a banner has to be at the top to be a banner"
    end
  end

  # ── [unit] collecting the population ───────────────────────────────────────

  def test_sources_spans_markdown_and_comment_bearing_sources
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p([File.join(dir, "config"), File.join(dir, "app/services"),
                         File.join(dir, "bin"), File.join(dir, "test/docs")])
      File.write(File.join(dir, "README.md"), "root markdown\n")
      File.write(File.join(dir, "config/registry.yml"), "# a registry claim\n")
      File.write(File.join(dir, "app/services/thing.rb"), "# a service claim\n")
      File.write(File.join(dir, "bin/fast-check"), "#!/usr/bin/env ruby\n# a script claim\n")
      File.write(File.join(dir, "test/docs/guard_test.rb"), "# a fixture\n")

      found = StatedProse.sources(dir).map { |p| StatedProse.rel(dir, p) }

      assert_equal %w[README.md app/services/thing.rb bin/fast-check config/registry.yml],
                   found
    end
  end

  def test_candidates_keeps_frozen_files_that_sources_drops
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "live.md"), "live\n")
      File.write(File.join(dir, "frozen.md"), "POINT-IN-TIME record\n")

      assert_equal %w[frozen.md live.md], StatedProse.candidates(dir).map { |p| StatedProse.rel(dir, p) }
      assert_equal %w[live.md], StatedProse.sources(dir).map { |p| StatedProse.rel(dir, p) }
    end
  end

  def test_a_binary_file_in_bin_is_not_read_as_prose
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "bin"))
      File.binwrite(File.join(dir, "bin/blob"), "\x7FELF\x00\x00binary")

      assert_empty StatedProse.sources(dir)
    end
  end
end
