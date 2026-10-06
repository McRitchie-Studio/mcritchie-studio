# frozen_string_literal: true

# `bin/release notes`.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_notes_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliNotesTest < ReleaseCliHarness
  def test_notes_defaults_to_a_read_only_dry_run_that_posts_nothing
    out = run_cli(["rel-x"], setup: notes_stub(delivered: false),
                  call: "notes; puts; puts $snippets.to_json")
    snippet, read_only = JSON.parse(out.lines.last).first

    assert read_only, "the default must be a read — nothing is sent"
    assert_includes snippet, "dry_run: true"
    assert_includes out, "DRY RUN (pass --post to send)"
    assert_includes out, "message 1: 1990 content chars (limit 2000)"
    assert_includes out, "the notes body"
    assert_includes snippet, 'slug: "rel-x"'
  end

  def test_notes_post_sends_and_prints_the_real_error_on_failure
    out = run_cli(["rel-x", "--post"], setup: notes_stub(delivered: false, error: NOTES_ERROR),
                  call: "begin; notes; rescue SystemExit => e; puts \"EXIT=\#{e.status}\"; end; puts $snippets.to_json")
    snippet, read_only = JSON.parse(out.lines.last).first

    refute read_only
    assert_includes snippet, "dry_run: false"
    assert_includes out, "release notes: NOT delivered — #{NOTES_ERROR}"
    refute_includes out, "webhook unset?"
    assert_includes out, "EXIT=1", "a failed post must not exit 0"
  end

  def test_notes_without_a_release_refuses
    out = run_cli([], setup: notes_stub(delivered: false),
                  call: "begin; notes; rescue SystemExit => e; puts \"EXIT=\#{e.status}\"; end")

    assert_includes out, "EXIT=1"
  end
end
