# frozen_string_literal: true

# Standalone coverage for bin/session-preflight. The command is intentionally
# tested through its CLI seams so it can be used before Rails or the live task
# board are available.

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../support/session_env"

class SessionPreflightTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "session-preflight")

  def setup
    @sandbox = Dir.mktmpdir("session-preflight")
    @repo = File.join(@sandbox, "repo")
    FileUtils.mkdir_p(@repo)
    write_feature_shapes
    write_installer(status: 0)
    git("init", "-q")
    git("config", "user.email", "tester@example.com")
    git("config", "user.name", "Tester")
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    git("update-ref", "refs/remotes/origin/release", head)
    git("checkout", "-q", "-b", "feat/session-preflight")
  end

  def teardown
    FileUtils.rm_rf(@sandbox) if @sandbox
  end

  def test_json_preflight_reports_feedback_shape_and_clean_docs
    task = write_task(
      latest_activity: {
        "activity_type" => "qa_feedback",
        "created_at" => "2026-06-26T12:00:00Z",
        "description" => "Reviewer note: check branch freshness first."
      }
    )

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.fetch("ok")
    assert_equal "Reviewer note: check branch freshness first.", report.fetch("latest_feedback").fetch("description")
    assert_equal %w[unit integration], report.fetch("shape").fetch("dor_tiers")
    assert_equal "pass", report.fetch("installed_docs").fetch("status")
  end

  def test_branch_behind_release_is_a_blocker
    task = write_task
    git("checkout", "-q", "--detach", "origin/release")
    release_commit = commit_file("docs/release.md", "release\n", "release moves")
    git("update-ref", "refs/remotes/origin/release", release_commit)
    git("checkout", "-q", "feat/session-preflight")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    refute status.success?

    report = JSON.parse(out)
    assert_equal 1, report.fetch("branch").fetch("behind")
    assert report.fetch("errors").any? { |error| error.include?("behind origin/release") }, report.fetch("errors").inspect
  end

  def test_stale_terminology_scan_blocks_active_docs
    task = write_task
    write_file("docs/agents/modules/stale.md", "Use GET /api/v1/tasks?stage=queued here.\n")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    refute status.success?

    report = JSON.parse(out)
    hit = report.fetch("stale_terms").first
    assert_equal "docs/agents/modules/stale.md", hit.fetch("file")
    assert_equal "legacy queued stage query", hit.fetch("label")
  end

  def test_installed_docs_drift_blocks_preflight
    write_installer(status: 1, stderr: "ERROR: /Users/alex/projects/AGENTS.md is out of date\n")
    task = write_task

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-fetch", "--json")
    refute status.success?

    report = JSON.parse(out)
    assert_equal "fail", report.fetch("installed_docs").fetch("status")
    assert report.fetch("errors").any? { |error| error.include?("installed docs/skills drift") }
  end

  def test_github_state_and_same_file_overlap_are_reported
    task = write_task(devops: default_devops.merge("branch" => "feat/session-preflight"))
    commit_file("docs/agents/index.md", "changed\n", "feature docs")
    fake_bin = write_fake_gh

    out, err, status = run_preflight(
      "--file", task, "--no-install-docs", "--no-fetch", "--json",
      env: { "PATH" => "#{fake_bin}:#{ENV.fetch("PATH", "")}" }
    )
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "CLEAN", report.fetch("pr").fetch("merge_state")
    assert_equal "pass", report.fetch("pr").fetch("checks").first.fetch("state")
    overlap = report.fetch("overlap").fetch("items").first
    assert_equal 6, overlap.fetch("number")
    assert_equal ["docs/agents/index.md"], overlap.fetch("files")
  end

  def test_docs_kind_without_shape_is_exempt_from_shape_gate
    task = write_task(devops: { "kind" => "docs", "branch" => "feat/session-preflight" })

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.fetch("ok")
    assert_empty report.fetch("errors")
    assert_equal true, report.dig("shape", "exempt")
    assert_equal "docs", report.dig("shape", "kind")
  end

  def test_docs_kind_shipping_code_loses_the_exemption
    task = write_task(devops: { "kind" => "docs", "branch" => "feat/session-preflight" })
    write_file("lib/shipped_code.rb", "# real code under CODE_PATH_PREFIXES\n")

    out, _err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    refute status.success?

    report = JSON.parse(out)
    assert_equal false, report.dig("shape", "exempt")
    assert report.fetch("errors").any? { |error| error.include?("devops.shape is missing") }, report.fetch("errors").inspect
  end

  def test_chore_kind_doc_only_diff_keeps_the_exemption
    task = write_task(devops: { "kind" => "chore", "branch" => "feat/session-preflight" })
    write_file("docs/agents/modules/clean-note.md", "Doc-only change keeps the exemption.\n")

    out, err, status = run_preflight("--file", task, "--no-gh", "--no-install-docs", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal true, report.dig("shape", "exempt")
  end

  def test_live_task_show_contract_reports_latest_feedback
    write_fake_task_cli(latest_activity: {
      "activity_type" => "qa_feedback",
      "created_at" => "2026-06-26T18:55:11Z",
      "description" => "Live board feedback should be visible."
    })

    out, err, status = run_preflight("add-session-preflight", "--no-gh", "--no-fetch", "--json")
    assert status.success?, "#{out}\n#{err}"

    report = JSON.parse(out)
    assert_equal "qa_feedback", report.dig("latest_feedback", "activity_type")
    assert_equal "Live board feedback should be visible.", report.dig("latest_feedback", "description")
  end

  def test_live_task_show_falls_back_to_activities_api_for_latest_feedback
    write_fake_task_cli
    activity = {
      "activity_type" => "qa_feedback",
      "created_at" => "2026-06-26T19:41:52Z",
      "description" => "Live activities feedback should be visible before serializer deploy."
    }

    with_activity_api(activity) do |base_url|
      out, err, status = run_preflight(
        "add-session-preflight", "--no-gh", "--no-fetch", "--json",
        env: {
          "AGENT_API_SECRET" => "test-secret",
          "TASK_API_BASE" => base_url
        }
      )
      assert status.success?, "#{out}\n#{err}"

      report = JSON.parse(out)
      assert_equal "qa_feedback", report.dig("latest_feedback", "activity_type")
      assert_equal "Live activities feedback should be visible before serializer deploy.",
                   report.dig("latest_feedback", "description")
      assert_empty report.fetch("warnings").grep(/latest task activity fallback failed/)
    end
  end

  def test_live_task_show_falls_back_to_clarification_activity
    write_fake_task_cli
    activity = {
      "activity_type" => "clarification",
      "created_at" => "2026-06-26T19:42:31Z",
      "description" => "Can you clarify whether this blocks release?"
    }

    with_activity_api(activity) do |base_url|
      out, err, status = run_preflight(
        "add-session-preflight", "--no-gh", "--no-fetch", "--json",
        env: {
          "AGENT_API_SECRET" => "test-secret",
          "TASK_API_BASE" => base_url
        }
      )
      assert status.success?, "#{out}\n#{err}"

      report = JSON.parse(out)
      assert_equal "clarification", report.dig("latest_feedback", "activity_type")
      assert_equal "Can you clarify whether this blocks release?",
                   report.dig("latest_feedback", "description")
      assert_empty report.fetch("warnings").grep(/latest task activity fallback failed/)
    end
  end

  private

  def run_preflight(*args, env: {})
    Open3.capture3(
      SessionEnv.neutralized(env),
      RbConfig.ruby, SCRIPT, "--root", @repo, *args,
      chdir: @repo
    )
  end

  def write_task(stage: "building", devops: default_devops, latest_activity: nil)
    path = File.join(@sandbox, "task.json")
    File.write(path, "#{JSON.pretty_generate("data" => task_payload(stage: stage, devops: devops, latest_activity: latest_activity))}\n")
    path
  end

  def task_payload(stage: "building", devops: default_devops, latest_activity: nil)
    payload = {
      "slug" => "add-session-preflight",
      "title" => "Add Session Preflight",
      "stage" => stage,
      "metadata" => { "devops" => devops },
      "task_url" => "https://mcritchie.studio/tasks/add-session-preflight"
    }
    payload["latest_activity"] = latest_activity if latest_activity
    payload
  end

  def write_fake_task_cli(latest_activity: nil)
    write_file("bin/task", <<~RUBY)
      #!/usr/bin/env ruby
      if ARGV == ["show", "add-session-preflight", "--json"]
        puts #{JSON.generate("data" => task_payload(latest_activity: latest_activity)).inspect}
      else
        warn "unexpected task args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, File.join(@repo, "bin", "task"))
  end

  def with_activity_api(activity)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      loop do
        client = server.accept
        request_line = client.gets.to_s
        headers = {}
        while (line = client.gets)
          break if line == "\r\n"

          key, value = line.split(":", 2)
          headers[key.to_s.downcase] = value.to_s.strip
        end
        client.read(headers.fetch("content-length", "0").to_i)

        body = if request_line.start_with?("POST /api/v1/auth ")
          JSON.generate("token" => "test-token")
        elsif request_line.start_with?("GET /api/v1/activities?")
          JSON.generate("data" => [activity], "meta" => { "page" => 1, "per_page" => 20, "total" => 1 })
        else
          JSON.generate("error" => "unexpected request: #{request_line.strip}")
        end
        status = body.include?("unexpected request") ? "404 Not Found" : "200 OK"
        client.write "HTTP/1.1 #{status}\r\n"
        client.write "Content-Type: application/json\r\n"
        client.write "Content-Length: #{body.bytesize}\r\n"
        client.write "Connection: close\r\n\r\n"
        client.write body
        client.close
      rescue IOError, Errno::EBADF
        break
      ensure
        client&.close unless client&.closed?
      end
    end

    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.join(1)
    thread&.kill if thread&.alive?
  end

  def default_devops
    {
      "kind" => "chore",
      "shape" => "backend",
      "repositories" => ["mcritchie-studio"],
      "risk_tags" => ["devops", "docs"],
      "acceptance" => ["Preflight reports blocker feedback"],
      "test_plan" => ["[unit] command output"],
      "branch" => "feat/session-preflight"
    }
  end

  def write_feature_shapes
    write_file("config/feature_shapes.yml", <<~YAML)
      defaults:
        required_metadata: [acceptance, repositories, risk_tags, test_plan]
      shapes:
        backend:
          description: Backend command.
          dor_tiers: [unit, integration]
          required_metadata: [acceptance, repositories, risk_tags, test_plan]
    YAML
  end

  def write_installer(status:, stderr: "")
    write_file("bin/install-agent-docs", <<~RUBY)
      #!/usr/bin/env ruby
      warn #{stderr.inspect}
      exit #{status}
    RUBY
    File.chmod(0o755, File.join(@repo, "bin", "install-agent-docs"))
  end

  def write_fake_gh
    dir = File.join(@sandbox, "fake-bin")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "gh")
    File.write(path, <<~RUBY)
      #!/usr/bin/env ruby
      require "json"
      case ARGV
      in ["pr", "view", ref, "--json", fields]
        if fields == "files"
          files = ref == "6" ? [{ path: "docs/agents/index.md" }] : [{ path: "README.md" }]
          puts JSON.generate(files: files)
        else
          puts JSON.generate(
            number: 5,
            title: "Add Session Preflight",
            url: "https://github.com/amcritchie/mcritchie-studio/pull/5",
            headRefName: "feat/session-preflight",
            mergeStateStatus: "CLEAN",
            statusCheckRollup: [{ name: "test", conclusion: "SUCCESS", status: "COMPLETED", detailsUrl: "https://example.test" }]
          )
        end
      in ["pr", "list", "--state", state, "--limit", _limit, "--json", _fields]
        if state == "open"
          puts JSON.generate([
            { number: 5, title: "Current", url: "https://example.test/5", headRefName: "feat/session-preflight", updatedAt: "now" },
            { number: 6, title: "Sibling", url: "https://example.test/6", headRefName: "feat/sibling", updatedAt: "now" }
          ])
        else
          puts JSON.generate([])
        end
      else
        warn "unexpected gh args: \#{ARGV.join(" ")}"
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    dir
  end

  def write_file(relative, body)
    path = File.join(@repo, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
  end

  def commit_file(relative, body, message)
    write_file(relative, body)
    git("add", "-A")
    git("commit", "-q", "-m", message)
    head
  end

  def git(*args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: @repo)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
    out
  end

  def head
    git("rev-parse", "HEAD").strip
  end
end
