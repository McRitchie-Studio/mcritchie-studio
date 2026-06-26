# frozen_string_literal: true

# Standalone coverage for bin/session-preflight. The command is intentionally
# tested through its CLI seams so it can be used before Rails or the live task
# board are available.

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

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

  private

  def run_preflight(*args, env: {})
    Open3.capture3(
      env,
      RbConfig.ruby, SCRIPT, "--root", @repo, *args,
      chdir: @repo
    )
  end

  def write_task(stage: "building", devops: default_devops, latest_activity: nil)
    path = File.join(@sandbox, "task.json")
    payload = {
      "slug" => "add-session-preflight",
      "title" => "Add Session Preflight",
      "stage" => stage,
      "metadata" => { "devops" => devops },
      "task_url" => "https://mcritchie.studio/tasks/add-session-preflight"
    }
    payload["latest_activity"] = latest_activity if latest_activity
    File.write(path, "#{JSON.pretty_generate(payload)}\n")
    path
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
    out, err, status = Open3.capture3("git", *args, chdir: @repo)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
    out
  end

  def head
    git("rev-parse", "HEAD").strip
  end
end
