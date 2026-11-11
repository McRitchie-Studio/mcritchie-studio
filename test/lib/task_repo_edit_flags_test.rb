# frozen_string_literal: true

# [unit] `bin/task update --add-repo / --remove-repo` edit devops.repositories in place;
# `--repo` replaces it. --remove-repo also drops the repo's pr_urls entry, since the
# release plans every repo with a PR link. Own file: task_cli_test.rb is a frozen
# append hotspot. History: task release-preflight-hardening.
require "minitest/autorun"
require "json"
require "socket"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class TaskRepoEditFlagsTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)

  def sandbox_root = (@sandbox_root ||= Dir.mktmpdir("task-repo-edit"))

  def teardown
    FileUtils.remove_entry(@sandbox_root) if @sandbox_root && File.directory?(@sandbox_root)
  end

  # Runs the real bin/task against a localhost stub board. [requests, err, status].
  def run_task(args, devops)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    thread = Thread.new { serve(server, requests, devops) }
    env = SessionEnv.neutralized({
      "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}", "AGENT_API_SECRET" => "test-secret",
      "TASK_SKIP_MARKER" => "1", "TASK_CLAIM_NONCE" => "inst-default"
    }.merge(TaskUsageSandboxEnv.child_env(sandbox_root)))
    _out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, *args)
    [requests, err, status]
  ensure
    server&.close
    thread&.join(1)
  end

  def serve(server, requests, devops)
    loop do
      client = server.accept
      line = client.gets or (client.close; next)
      method, path, = line.split(" ")
      headers = {}
      while (h = client.gets) && h != "\r\n"
        k, v = h.split(":", 2)
        headers[k.strip.downcase] = v.strip if v
      end
      body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      requests << { method: method, path: path, body: body }
      payload = if path == "/api/v1/auth" then JSON.generate("token" => "stub-token")
                else JSON.generate("data" => { "slug" => "demo-task", "stage" => "building", "title" => "Demo",
                                               "metadata" => { "devops" => devops } })
                end
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def patched_devops(argv, devops)
    requests, err, = run_task(argv, devops)
    patch = requests.find { |r| r[:method] == "PATCH" }
    refute_nil patch, err
    JSON.parse(patch[:body])["devops"]
  end

  def test_add_repo_appends_without_repeating
    devops = patched_devops(%w[update demo-task --add-repo voicebox --add-repo mcritchie-studio],
                            { "kind" => "bug", "repositories" => %w[mcritchie-studio turf-monster] })
    assert_equal %w[mcritchie-studio turf-monster voicebox], devops["repositories"]
  end

  def test_remove_repo_drops_the_repo_and_its_pr_link
    hub = "https://github.com/McRitchie-Studio/mcritchie-studio/pull/1"
    devops = patched_devops(%w[update demo-task --remove-repo turf-monster],
                            { "kind" => "bug", "repositories" => %w[mcritchie-studio turf-monster],
                              "pr_urls" => { "mcritchie-studio" => hub,
                                             "turf-monster" => "https://github.com/McRitchie-Studio/turf-monster/pull/2" } })
    assert_equal %w[mcritchie-studio], devops["repositories"]
    assert_equal({ "mcritchie-studio" => hub }, devops["pr_urls"])
  end

  def test_repo_edits_refuse_beside_a_replacing_repo
    requests, err, status = run_task(%w[update demo-task --repo a --add-repo b], { "kind" => "bug" })
    refute status.success?
    assert_match(/--add-repo/, err)
    assert_nil requests.find { |r| r[:method] == "PATCH" }
  end
end
