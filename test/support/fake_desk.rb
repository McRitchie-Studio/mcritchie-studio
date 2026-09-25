# frozen_string_literal: true

require "json"
require "fileutils"

# A desk on disk, as bin/lib/desk_claim.rb reads one: a git worktree under
# <projects>/<repo>/.worktrees/<slug> whose .agent-context.json binds it to a task
# and names the session sitting at it. The anchor is THIS test process, recorded
# without a start time, so DeskContext grades the desk :unverifiable — a counted,
# live holder — for as long as the test runs.
module FakeDesk
  module_function

  def build(projects, task_slug:, session:, dirty:, repo: "mcritchie-studio", parent: nil)
    dir = File.join(projects, repo, ".worktrees", task_slug)
    FileUtils.mkdir_p(dir)
    git = ->(*args) { system("git", "-C", dir, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed") }
    git.call("init", "-q")
    File.write(File.join(dir, ".gitignore"), ".agent-context.json\n")
    git.call("add", ".gitignore")
    git.call("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "-qm", "init")
    File.write(File.join(dir, ".agent-context.json"), JSON.generate(
      "schema_version" => 2, "app" => repo, "task_slug" => task_slug, "worktree" => dir,
      "session_id" => session, "parent_session_id" => parent, "anchor_pid" => Process.pid
    ))
    File.write(File.join(dir, "work-in-progress.rb"), "# unsaved work\n") if dirty
    dir
  end
end
