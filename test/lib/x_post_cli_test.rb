# frozen_string_literal: true

# [integration] bin/x-post driven through the real script, with ffprobe and op
# replaced by stand-ins. Nothing here reaches X or 1Password: the paths under
# test are exactly the ones that must stop BEFORE either.
#
#   ruby -Itest test/lib/x_post_cli_test.rb

require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "digest"
require "rbconfig"

class XPostCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/x-post", __dir__)

  def setup
    @dir     = Dir.mktmpdir("x-post-cli-")
    @video   = File.join(@dir, "clip.mp4")
    @caption = File.join(@dir, "caption.txt")
    @op_mark = File.join(@dir, "op-was-called")
    File.write(@video, "not really a video")
    File.write(@caption, "Find the mistake in my $5 \"Bills\" lineup 👀\n")
    stub("op", "#!/bin/sh\ntouch #{@op_mark}\nexit 1\n")
    probe(fps: "30/1")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def stub(name, body)
    File.join(@dir, name).tap do |path|
      File.write(path, body)
      File.chmod(0o755, path)
    end
  end

  def probe(fps:)
    json = JSON.generate(streams: [{ codec_name: "h264", width: 1080, height: 1920, avg_frame_rate: fps }],
                         format: { duration: "19.0" })
    stub("ffprobe", "#!/bin/sh\ncat <<'JSON'\n#{json}\nJSON\n")
  end

  def run_cli(*args)
    env = { "X_POST_FFPROBE_BIN" => File.join(@dir, "ffprobe"), "X_POST_OP_BIN" => File.join(@dir, "op"),
            "X_POST_LEDGER" => File.join(@dir, "ledger.jsonl"),
            "X_API_KEY" => nil, "X_API_SECRET" => nil, "X_ACCESS_TOKEN" => nil, "X_ACCESS_TOKEN_SECRET" => nil }
    Open3.capture3(env, RbConfig.ruby, BIN, *args)
  end

  def test_check_prints_the_exact_text_and_touches_no_credential
    out, err, status = run_cli("check", @video, "--caption-file", @caption, "--tag", "#BillsMafia")

    assert status.success?, err
    assert_includes out, "  | Find the mistake in my $5 \"Bills\" lineup 👀"
    assert_includes out, "  | #BillsMafia"
    assert_includes out, "1080x1920  30.0fps  19.0s"
    assert_includes out, "ok: postable"
    refute File.exist?(@op_mark), "check must not read 1Password"
  end

  def test_check_refuses_a_video_over_sixty_fps
    probe(fps: "77/1")
    _out, err, status = run_cli("check", @video, "--caption-file", @caption)

    assert_equal 1, status.exitstatus
    assert_includes err, "REFUSED — 77.0fps, over X's 60"
  end

  def test_check_refuses_an_overweight_caption
    File.write(@caption, "a" * 281)
    _out, err, status = run_cli("check", @video, "--caption-file", @caption)

    assert_equal 1, status.exitstatus
    assert_includes err, "weighs 281, over X's 280"
  end

  def test_post_without_yes_refuses_before_any_credential_read
    _out, err, status = run_cli("post", @video, "--caption-file", @caption)

    assert_equal 1, status.exitstatus
    assert_includes err, "not posted: a post is public"
    refute File.exist?(@op_mark), "an unapproved post must not read 1Password"
  end

  def test_post_refuses_a_video_already_in_the_ledger
    row = { sha256: Digest::SHA256.file(@video).hexdigest, post_url: "https://x.com/turfmonstershow/status/1",
            posted_at: "2026-10-04T00:00:00Z" }
    File.write(File.join(@dir, "ledger.jsonl"), "#{JSON.generate(row)}\n")
    _out, err, status = run_cli("post", @video, "--caption-file", @caption, "--yes")

    assert_equal 1, status.exitstatus
    assert_includes err, "already posted 2026-10-04T00:00:00Z → https://x.com/turfmonstershow/status/1"
    refute File.exist?(@op_mark)
  end

  def test_an_unknown_flag_refuses_rather_than_posting
    _out, err, status = run_cli("post", @video, "--caption-file", @caption, "--yess")

    assert_equal 1, status.exitstatus
    assert_includes err, "invalid option: --yess"
  end

  def test_help_exits_zero_without_acting
    _out, err, status = run_cli("--help")

    assert status.success?
    assert_includes err, "bin/x-post check <video.mp4>"
  end

  # An attempt row with nothing after it means a run died mid-post: the video
  # may be live, and only the timeline knows.
  def test_post_refuses_after_an_attempt_that_never_recorded_a_result
    row = { sha256: Digest::SHA256.file(@video).hexdigest, attempted_at: "2026-10-04T01:00:00Z" }
    File.write(File.join(@dir, "ledger.jsonl"), "#{JSON.generate(row)}\n")
    _out, err, status = run_cli("post", @video, "--caption-file", @caption, "--yes")

    assert_equal 1, status.exitstatus
    assert_includes err, "started 2026-10-04T01:00:00Z and never recorded a result, so it may be LIVE"
    refute File.exist?(@op_mark)
  end

  # X answered no, so nothing is live and the next run may proceed: it gets as
  # far as the credential read, which the stand-in op fails.
  def test_post_proceeds_after_an_attempt_x_refused
    sha  = Digest::SHA256.file(@video).hexdigest
    rows = [{ sha256: sha, attempted_at: "2026-10-04T01:00:00Z" }, { sha256: sha, refused_at: "2026-10-04T01:00:09Z" }]
    File.write(File.join(@dir, "ledger.jsonl"), rows.map { |r| JSON.generate(r) }.join("\n") + "\n")
    _out, err, status = run_cli("post", @video, "--caption-file", @caption, "--yes")

    assert_equal 1, status.exitstatus
    refute_includes err, "may be LIVE"
    assert File.exist?(@op_mark), "a refused attempt must not block the retry"
  end


  # `draft` reads ESPN for a real team, so only its REFUSALS run here: they stop
  # before any network call. The recipe itself is pinned in
  # test/services/x/post_draft_test.rb against fixture payloads.
  def test_draft_refuses_an_unknown_team_and_an_ambiguous_city_before_any_read
    _out, err, status = run_cli("draft", "monarchs")
    assert_equal 1, status.exitstatus
    assert_includes err, 'no team matches "monarchs"'

    _out, err, status = run_cli("draft", "new", "york")
    assert_equal 1, status.exitstatus
    assert_includes err, "matches New York Giants and New York Jets"

    _out, err, status = run_cli("draft")
    assert_equal 1, status.exitstatus
    assert_includes err, "draft needs a team"
  end

  def test_ledger_says_so_when_it_holds_only_an_unfinished_attempt
    File.write(File.join(@dir, "ledger.jsonl"), "#{JSON.generate(sha256: 'x', attempted_at: '2026-10-04T01:00:00Z')}\n")
    out, _err, status = run_cli("ledger")

    assert status.success?
    assert_includes out, "no posts recorded"
  end

end
