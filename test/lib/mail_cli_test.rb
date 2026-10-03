# frozen_string_literal: true

# [unit] bin/lib/mail_cli.rb — the local half of bin/mail. No Heroku, no Rails:
# the "runner" here executes the generated script in a plain `ruby` subprocess
# with a stub MailExport, so the script itself is exercised, and the output is
# salted with the noise a real `heroku run` prints.
#
#   ruby -Itest test/lib/mail_cli_test.rb

require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/mail_cli"

class MailCliTest < Minitest::Test
  TOKEN = "t0k3n"

  # Runs the script for real against a stub MailExport that echoes the request
  # inside `answer`, wrapping it in Heroku-shaped noise on both streams.
  def subprocess_runner(answer: nil, noise: true)
    lambda do |script|
      stub = <<~RUBY
        module MailExport
          def self.call(request)
            #{answer ? "JSON.parse(#{JSON.generate(answer).inspect})" : '{ "echo" => request }'}
          end
        end
        puts "[mail] transport=resend" if #{noise}
        warn "Running rails runner - on mcritchie-studio... up, run.1234"
      RUBY
      out, err, status = Open3.capture3("ruby", stdin_data: stub + script)
      raise "script failed: #{err}" unless status.success?

      noise ? [ "Running rails runner - on ⬢ mcritchie-studio... up\n#{out}heroku-cli: update available\n", err ] : [ out, err ]
    end
  end

  def run_cli(verb, args, opts = {}, runner:)
    out = StringIO.new
    err = StringIO.new
    code = MailCli.run(verb, args, MailCli.default_options.merge(opts), runner: runner, out: out, err: err,
                                                                        token: TOKEN)
    [ code, out.string, err.string ]
  end

  def test_parse_since
    assert_equal 7 * 86_400, MailCli.parse_since("7d")
    assert_equal 36 * 3600, MailCli.parse_since("36h")
    assert_equal 2 * 604_800, MailCli.parse_since("2w")
    assert_raises(MailCli::Error) { MailCli.parse_since("week") }
  end

  def test_the_script_round_trips_the_request_through_a_real_ruby_process
    request = MailCli.build_request("desk", [ "42" ], MailCli.default_options.merge(save: :default))
    out, = subprocess_runner.call(MailCli.runner_script(request, TOKEN))

    assert_equal({ "verb" => "desk_item", "id" => 42, "files" => true }, MailCli.extract(out, TOKEN)["echo"])

    request = MailCli.build_request("thread", [ "subject:\"$5 off\" from:a@example.com" ], MailCli.default_options)
    out, = subprocess_runner.call(MailCli.runner_script(request, TOKEN))

    assert_equal "subject:\"$5 off\" from:a@example.com", MailCli.extract(out, TOKEN)["echo"]["query"],
                 "quotes and `$` survive the trip unmangled"
  end

  def test_extract_ignores_noise_between_chunks_and_survives_large_payloads
    big = "x" * (MailCli::CHUNK * 3)
    out, = subprocess_runner(answer: { "body" => big }).call(
      MailCli.runner_script({ "verb" => "doctor" }, TOKEN)
    )
    lines = out.lines
    lines.insert(3, "[mail] transport=resend id=abc\n") # between chunk 1 and chunk 2

    assert_equal big, MailCli.extract(lines.join, TOKEN)["body"]
  end

  def test_the_script_never_contains_its_own_line_prefix
    refute_includes MailCli.runner_script({ "verb" => "doctor" }, TOKEN), "@@mail:#{TOKEN}@@"
  end

  def test_extract_refuses_a_missing_or_truncated_answer
    assert_raises(MailCli::Error) { MailCli.extract("Running ...\nError R14\n", TOKEN) }
    assert_raises(MailCli::Error) { MailCli.extract("@@mail:#{TOKEN}@@ eyJ4Ijox\n", TOKEN) }
  end

  def test_desk_item_save_writes_files_and_prints_the_body
    files = [ { "name" => "item-5.eml", "base64" => ["raw"].pack("m0") },
              { "name" => "../../escape.pdf", "base64" => ["%PDF"].pack("m0") } ]
    item = { "id" => 5, "status" => "received", "from" => "a@example.com", "subject" => "Hi",
             "body" => "Body text", "attachments" => [ "Terms.pdf" ], "quarantined" => false, "files" => files }

    Dir.mktmpdir do |dir|
      code, out, = run_cli("desk", [ "5" ], { save: dir }, runner: subprocess_runner(answer: { "item" => item }))

      assert_equal 0, code
      assert_match(/Body text/, out)
      assert_equal "raw", File.read(File.join(dir, "item-5.eml"))
      assert_equal "%PDF", File.read(File.join(dir, "escape.pdf")), "a name cannot climb out of DIR"
    end
  end

  def test_a_quarantined_item_prints_the_report_and_saves_nothing
    item = { "id" => 6, "status" => "quarantined", "from" => "x@example.org", "subject" => "Hi",
             "quarantined" => true, "notice" => "QUARANTINED — report it to the operator",
             "dkim" => "Authentication-Results dkim: dkim=fail", "files" => [] }

    Dir.mktmpdir do |dir|
      target = File.join(dir, "out")
      code, out, = run_cli("desk", [ "6" ], { save: target }, runner: subprocess_runner(answer: { "item" => item }))

      assert_equal 0, code
      assert_match(/report it to the operator/, out)
      assert_match(/dkim=fail/, out)
      assert_match(/--save wrote nothing/, out)
      refute File.exist?(target)
    end
  end

  def test_thread_save_writes_the_transcript_beside_the_attachments
    answer = { "thread_id" => "t-1", "transcript" => "From: a@example.com\n\nHello",
               "files" => [ { "name" => "0-terms.pdf", "base64" => ["%PDF"].pack("m0") } ] }
    Dir.mktmpdir do |dir|
      code, out, = run_cli("thread", [ "subject:Terms" ], { save: dir }, runner: subprocess_runner(answer: answer))

      assert_equal 0, code
      assert_match(/Hello/, out)
      assert_equal [ "0-terms.pdf", "transcript.txt" ], Dir.children(dir).sort
    end
  end

  def test_doctor_failure_exits_one
    answer = { "ok" => false, "failures" => [ "MX gone" ], "notes" => [] }
    code, out, = run_cli("doctor", [], runner: subprocess_runner(answer: answer))

    assert_equal 1, code
    assert_match(/FAIL MX gone/, out)
  end

  def test_a_remote_error_exits_one_and_says_why
    code, _out, err = run_cli("desk", [ "9" ], runner: subprocess_runner(answer: { "error" => "no desk item 9" }))

    assert_equal 1, code
    assert_match(/no desk item 9/, err)
  end

  def test_usage_errors_exit_two_without_running_anything
    never = ->(_script) { flunk "the runner must not be called on a usage error" }

    assert_equal 2, run_cli("desk", %w[1 2], runner: never).first
    assert_equal 2, run_cli("desk", [ "abc" ], runner: never).first
    assert_equal 2, run_cli("thread", [], runner: never).first
    assert_equal 2, run_cli("send", [], runner: never).first
  end
end
