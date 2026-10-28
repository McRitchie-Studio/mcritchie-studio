# frozen_string_literal: true

# [unit] SOURCE PIN: every subprocess on the release path runs through
# BoundedCommand (a deadline, then SIGKILL to the child's process group).
#
# On 2026-10-27 a `heroku run` client hung 26 minutes with no dyno, every `op`
# read hung for two hours, and a perl `alarm` wrapper could not kill a hung `op`
# because op ignores SIGALRM. Open3, system() and IO.popen wait as long as the
# child does; Timeout.timeout raises into this thread and leaves the child
# running. So none of them may spawn a child in these files. The one allowance is
# curl, which carries its own --max-time on the same call.
#
#   ruby -Itest test/lib/release_subprocesses_are_bounded_test.rb

require "minitest/autorun"

class ReleaseSubprocessesAreBoundedTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # bin/release.rb and the libraries it calls that spawn on the release path,
  # plus the app-side 1Password reads (Gmail and Workspace credentials).
  FILES = %w[
    bin/release.rb
    bin/lib/ci_status.rb
    bin/lib/gh_auth_retry.rb
    bin/lib/static_cloudflare.rb
    bin/lib/local_services.rb
    app/services/gmail/credentials.rb
    app/services/workspace/credentials.rb
  ].freeze

  UNBOUNDED = /(?:\bOpen3\.\w+|(?<![.\w])system|\bIO\.popen|\bTimeout\.timeout|\bKernel\.spawn|(?<![.\w])spawn)\s*\(/

  def offenders(text, path)
    lines = text.lines
    lines.each_with_index.filter_map do |line, i|
      next if line.lstrip.start_with?("#")
      next unless UNBOUNDED.match?(line)
      # curl bounds itself: --max-time on this line or the next one.
      next if line.include?("/usr/bin/curl") && lines[i, 2].join.include?("--max-time")

      "#{path}:#{i + 1}: #{line.strip}"
    end
  end

  def test_no_release_path_file_spawns_outside_bounded_command
    found = FILES.flat_map { |rel| offenders(File.read(File.join(ROOT, rel)), rel) }

    assert_empty found, "spawn through BoundedCommand (bin/lib/bounded_command.rb), never bare:\n#{found.join("\n")}"
  end

  # The pin bites: the shapes the converted call sites had are caught, and the
  # bounded shapes are not.
  def test_the_pattern_matches_the_unbounded_shapes_it_replaced
    [
      %(  out, status = Open3.capture2e("git", *args)),
      %(  out, err, status = Open3.capture3(env, gh_bin, *args)),
      %(    ok = system(*argv, opts)),
      %(  Open3.popen2e(*argv, opts) do |stdin, out, wait|),
      %(        Open3.popen3("op", "read", item) do |stdin, stdout, stderr, thread|),
      %(  body = Timeout.timeout(5) { read }),
      %(  out, status = Open3.capture2e("/usr/bin/curl", "-sf", url))
    ].each { |line| refute_empty offenders(line, "x"), line }

    [
      %(  out, status = bounded_capture2e("git", *args)),
      %(  result = BoundedCommand.run(env, cmd, deadline: deadline, pgroup: true)),
      %(  out, status = Open3.capture2e("/usr/bin/curl", "-s", "--max-time", "20", url)),
      %(  # Open3.capture2e has no deadline)
    ].each { |line| assert_empty offenders(line, "x"), line }
  end
end
