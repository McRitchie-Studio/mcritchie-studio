# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "open3"
require "rbconfig"

# [integration] bin/task's task header carries the merge-time approval block
# (surface-waiting-request-at-merge). This is the seam pr-review-primary.md step 6
# reads: `bin/task show <slug>` right before `gh pr merge`. Drives the real
# print_task in a subprocess, with only the handoff-note GET replaced.
class TaskShowApprovalNoticeTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def print_task_for(devops)
    task = { "slug" => "demo-task", "stage" => "submitted", "title" => "Demo Task",
             "metadata" => { "devops" => devops } }
    script = <<~RUBY
      ARGV.replace([])
      begin
        load #{File.join(ROOT, "bin", "task").inspect}
      rescue SystemExit
        nil
      end
      def latest_handoff_note(_slug) = "Please check the chip copy."
      print_task(JSON.parse(#{task.to_json.dump}))
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-e", script, chdir: ROOT)
    assert_predicate status, :success?, "driving bin/task failed: #{err}"
    [out, err]
  end

  def test_a_waiting_request_prints_the_block_on_stderr_only
    out, err = print_task_for("approval_status" => "waiting", "approval_requested_by" => "steffon",
                              "local_url" => "http://localhost:3015/x")

    assert_includes err, "OPERATOR APPROVAL STILL WAITING"
    assert_includes err, "asked by: steffon"
    assert_includes err, "the note that asked: Please check the chip copy."
    refute_includes out, "OPERATOR APPROVAL", "stdout stays what callers already parse"
    assert_includes out, "demo-task  [submitted]  Demo Task"
  end

  def test_no_request_prints_no_block
    _out, err = print_task_for("approval_status" => "none")

    refute_includes err, "OPERATOR APPROVAL"
  end
end
