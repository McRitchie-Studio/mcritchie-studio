# frozen_string_literal: true

# [unit] bin/lib/drive_cli.rb — the local half of bin/drive (/tasks/drive-filing).
# No Heroku, no Rails: the "runner" runs the generated script in a plain `ruby`
# subprocess with a stub DriveExport, so the script and its STDIN carriage of a
# local file's bytes are exercised, salted with a `heroku run`'s noise.
# Every file name and byte here is invented.
#
#   ruby -Itest test/lib/drive_cli_test.rb

require "minitest/autorun"
require "digest"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/drive_cli"

class DriveCliTest < Minitest::Test
  TOKEN = "t0k3n"
  BYTES = "%PDF-1.4 invented fixture\n".b

  # Runs the script for real against a stub DriveExport. With no answer it
  # echoes the request back (less the bytes, which it md5s instead).
  def subprocess_runner(answer: nil)
    lambda do |script|
      stub = <<~RUBY
        require "digest"
        module DriveExport
          def self.call(request)
            #{answer ? "JSON.parse(#{JSON.generate(answer).inspect})" : <<~ECHO}
              bytes = request["content_base64"] && Base64.strict_decode64(request["content_base64"])
              { "echo" => request.reject { |k, _| k == "content_base64" }.merge("bytes_md5" => bytes && Digest::MD5.hexdigest(bytes)) }
            ECHO
          end
        end
        warn "Running rails runner - on mcritchie-studio... up, run.1234"
      RUBY
      out, err, status = Open3.capture3("ruby", stdin_data: stub + script)
      raise "script failed: #{err}" unless status.success?

      [ "Running rails runner - on ⬢ mcritchie-studio... up\n#{out}heroku-cli: update available\n", err ]
    end
  end

  def run_cli(verb, args, opts = {}, runner:)
    out = StringIO.new
    err = StringIO.new
    code = DriveCli.run(verb, args, DriveCli.default_options.merge(opts), runner:, out:, err:, token: TOKEN)
    [ code, out.string, err.string ]
  end

  def with_file(bytes = BYTES, name: "sample-policy.pdf")
    Dir.mktmpdir do |dir|
      path = File.join(dir, name)
      File.binwrite(path, bytes)
      yield path
    end
  end

  def test_upload_carries_the_bytes_over_stdin_with_their_md5_and_never_on_a_command_line
    captured = nil
    answer = { "filed" => { "folder_path" => "Records/Policies", "name" => "sample-policy.pdf", "md5" => "abc", "byte_size" => 26,
                            "applied" => false, "duplicate" => false, "created_folders" => [] } }
    runner = lambda do |script|
      captured = script
      subprocess_runner(answer:).call(script)
    end
    with_file do |path|
      request = DriveCli.build_request("upload", [ path ], DriveCli.default_options.merge(mailbox: "owner@example.com", folder: "Records/Policies"))
      assert_equal [ "upload", "sample-policy.pdf", Digest::MD5.hexdigest(BYTES), "Records/Policies", false ],
                   request.values_at("verb", "name", "md5", "folder", "apply")
      assert_equal BYTES, Base64.strict_decode64(request["content_base64"])

      code, = run_cli("upload", [ path ], { mailbox: "owner@example.com", folder: "Records/Policies" }, runner:)
      assert_equal 0, code
    end
    assert captured, "the request rides the script on STDIN; the runner's argv is fixed"
    refute_includes captured, "PDF-1.4", "the bytes ride base64, never as text in the script"
  end

  def test_the_echoed_bytes_arrive_whole
    with_file do |path|
      opts = DriveCli.default_options.merge(mailbox: "owner@example.com", folder: "Records", apply: true)
      request = DriveCli.build_request("upload", [ path ], opts)
      script = MailCli.runner_script(request, TOKEN, service: DriveCli::SERVICE, tag: DriveCli::TAG)
      stdout, = subprocess_runner.call(script)
      echo = MailCli.extract(stdout, TOKEN, tag: DriveCli::TAG, service: DriveCli::SERVICE)["echo"]
      assert_equal Digest::MD5.hexdigest(BYTES), echo["bytes_md5"]
      assert_equal true, echo["apply"]
    end
  end

  def test_every_verb_needs_a_mailbox
    code, _out, err = run_cli("mkdir", [ "Records" ], runner: subprocess_runner)
    assert_equal 2, code
    assert_match(/needs --mailbox/, err)
  end

  def test_upload_and_file_attachment_need_a_folder
    with_file do |path|
      code, _out, err = run_cli("upload", [ path ], { mailbox: "owner@example.com" }, runner: subprocess_runner)
      assert_equal 2, code
      assert_match(/--folder PATH is required/, err)
    end
    code, = run_cli("file-attachment", [ "msg-1" ], { mailbox: "owner@example.com" }, runner: subprocess_runner)
    assert_equal 2, code
  end

  def test_a_missing_empty_or_oversized_file_is_refused_before_any_run
    never = ->(_script) { flunk "no run for a refused file" }
    code, = run_cli("upload", [ "/nonexistent/sample.pdf" ], { mailbox: "a@example.com", folder: "R" }, runner: never)
    assert_equal 2, code
    with_file("".b) do |path|
      code, = run_cli("upload", [ path ], { mailbox: "a@example.com", folder: "R" }, runner: never)
      assert_equal 2, code
    end
    with_file("x".b * (DriveCli::MAX_BYTES + 1)) do |path|
      code, _out, err = run_cli("upload", [ path ], { mailbox: "a@example.com", folder: "R" }, runner: never)
      assert_equal 2, code
      assert_match(/the most bin\/drive files is/, err)
    end
  end

  def test_as_renames_and_file_attachment_carries_its_choices
    with_file do |path|
      request = DriveCli.build_request("upload", [ path ], DriveCli.default_options.merge(mailbox: "a@example.com", folder: "R", as: "renamed.pdf"))
      assert_equal "renamed.pdf", request["name"]
    end
    request = DriveCli.build_request("file-attachment", [ "msg-1" ],
                                     DriveCli.default_options.merge(mailbox: "a@example.com", folder: "R", name: "card.pdf", as: "Card.pdf", apply: true))
    assert_equal [ "file_attachment", "msg-1", "card.pdf", "Card.pdf", true ], request.values_at("verb", "message_id", "name", "as", "apply")
  end

  def test_a_dry_upload_says_nothing_changed_and_prints_no_bytes
    answer = { "filed" => { "folder_path" => "Records", "name" => "sample-policy.pdf", "md5" => "abc", "byte_size" => 26,
                            "applied" => false, "duplicate" => false, "created_folders" => [ "Records" ] } }
    with_file do |path|
      code, out, = run_cli("upload", [ path ], { mailbox: "owner@example.com", folder: "Records" }, runner: subprocess_runner(answer:))
      assert_equal 0, code
      assert_match(/Dry run: would file sample-policy\.pdf \(26 bytes, md5 abc\) in Records in owner@example.com's Drive/, out)
      assert_match(/would make Records/, out)
      assert_match(/add --apply/, out)
      refute_includes out, "PDF-1.4"
    end
  end

  def test_an_applied_upload_and_a_duplicate_read_plainly
    filed = { "folder_path" => "Records", "name" => "a.pdf", "md5" => "abc", "byte_size" => 3, "applied" => true,
              "drive_file_id" => "id-9", "url" => "https://drive.google.com/file/d/id-9/view", "created_folders" => [] }
    _code, out, = run_cli("file-attachment", [ "msg-1" ], { mailbox: "o@example.com", folder: "Records" },
                          runner: subprocess_runner(answer: { "filed" => filed.merge("duplicate" => false) }))
    assert_match(/\AFiled a\.pdf .* \(id-9\)\n  https:/, out)

    _code, out, = run_cli("file-attachment", [ "msg-1" ], { mailbox: "o@example.com", folder: "Records" },
                          runner: subprocess_runner(answer: { "filed" => filed.merge("duplicate" => true) }))
    assert_match(/\ASkipped a\.pdf .* already in Records/, out)
  end

  def test_mkdir_reports_dry_and_applied
    _code, out, = run_cli("mkdir", [ "Records/Policies" ], { mailbox: "o@example.com" },
                          runner: subprocess_runner(answer: { "folder" => { "folder_path" => "Records/Policies", "would_create" => [ "Records/Policies" ], "applied" => false } }))
    assert_match(/Dry run: would make Records\/Policies/, out)

    _code, out, = run_cli("mkdir", [ "Records/Policies" ], { mailbox: "o@example.com", apply: true },
                          runner: subprocess_runner(answer: { "folder" => { "folder_path" => "Records/Policies", "folder_id" => "f-2", "created" => [ "Records/Policies" ], "applied" => true } }))
    assert_match(/Made Records\/Policies; now Records\/Policies in o@example.com's Drive \(f-2\)/, out)
  end

  def test_a_hub_error_exits_one
    code, _out, err = run_cli("ls", [], { mailbox: "o@example.com" }, runner: subprocess_runner(answer: { "error" => "o@example.com is not connected" }))
    assert_equal 1, code
    assert_match(/drive: o@example.com is not connected/, err)
  end
end
