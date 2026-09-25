# frozen_string_literal: true

# `bin/release notes <release> --post` over notes already delivered (fix 2 of
# close-review-leftovers-bundle). Standalone:
#   ruby -Itest test/lib/release_notes_cli_test.rb
#
# Drives the REAL bin/release.rb in a subprocess with conductor() stubbed: the
# conductor's refusal (Release::Conductor.repost_release_notes, tested in
# test/models/release/notes_delivery_test.rb) must reach the operator as a warning,
# a non-zero exit, and the --force that overrides it.
require "minitest/autorun"
require "open3"
require "json"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class ReleaseNotesCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  def run_cli(argv, result)
    setup = <<~RUBY
      def conductor(ruby, read_only: false)
        $stdout.puts("CONDUCTOR " + ruby)
        JSON.parse(#{result.to_json.inspect})
      end
    RUBY
    script = %(ARGV.replace(#{argv.inspect}); load #{BIN.inspect}; #{setup}; ARGV.replace(#{argv.inspect}); begin; notes; rescue SystemExit => e; puts("EXIT " + e.status.to_s); end)
    env = OutboundSeams.env("TASK_API_BASE" => "http://127.0.0.1:1")
    out, err, status = Open3.capture3(env, "ruby", "-e", script)
    assert status.success?, "bin/release subprocess failed:\n#{out}\n#{err}"
    out
  end

  REFUSED = { "slug" => "rel-x", "message" => "notes", "messages" => [{ "content_chars" => 10, "embeds" => 1, "embed_chars" => 5 }],
              "notes_delivered" => false, "notes_error" => nil, "notes_messages" => 1,
              "notes_already_delivered" => true, "notes_refused" => true }.freeze

  def test_post_over_delivered_notes_warns_names_force_and_exits_nonzero
    out = run_cli(%w[rel-x --post --yes], REFUSED)

    assert_includes out, "already delivered"
    assert_includes out, "bin/release notes rel-x --post --force"
    assert_includes out, "EXIT 1"
    refute_includes out, "release notes: NOT delivered", "a refusal is not a failed delivery"
  end

  def test_force_reaches_the_conductor
    out = run_cli(%w[rel-x --post --force --yes], REFUSED.merge("notes_delivered" => true, "notes_refused" => false))

    assert_includes out, "force: true"
    assert_includes out, "release notes: posted"
  end

  def test_the_preview_says_the_notes_already_went_out
    out = run_cli(%w[rel-x], REFUSED.merge("notes_refused" => false))

    assert_includes out, "already delivered"
    assert_includes out, "force: false"
    assert_includes out, "Previewed rel-x"
  end
end
