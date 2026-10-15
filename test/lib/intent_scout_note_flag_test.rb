# frozen_string_literal: true

# [unit] `bin/task note` posts one note per call. The intent scout's allow rule is
# `task note <slug> --comment *` (bin/lib/intent_scout.rb#note_rule), and a prefix
# rule cannot stop a trailing `--handoff "..."`; this refusal is what holds the
# scout to comments. The refusal comes before any board call, so the child points
# at a closed port and a sandboxed HOME: a request would fail loudly, not post.
#
#   ruby -Itest test/lib/intent_scout_note_flag_test.rb

require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class IntentScoutNoteFlagTest < Minitest::Test
  BIN = File.expand_path("../../bin/task", __dir__)

  def setup
    @sandbox = Dir.mktmpdir("task-note-sandbox")
    @child = TaskUsageSandboxEnv.child_env(@sandbox)
    @desk = File.join(@sandbox, "desk")
    FileUtils.mkdir_p(File.join(@desk, ".git"))
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if File.directory?(@sandbox)
  end

  # Runs bin/task against a listener that records whether anything connected.
  def run_note(*flags)
    server = TCPServer.new("127.0.0.1", 0)
    connected = false
    thread = Thread.new do
      server.accept.close
      connected = true
    rescue IOError
      nil
    end
    env = SessionEnv.neutralized({ "TASK_API_BASE" => "http://127.0.0.1:#{server.addr[1]}",
                                   "AGENT_API_SECRET" => "test-secret", "TASK_SKIP_MARKER" => "1" }.merge(@child))
    _out, err, status = Open3.capture3(env, RbConfig.ruby, BIN, "note", "demo-task", *flags, "--agent", "avi", chdir: @desk)
    [err, status, connected]
  ensure
    server&.close
    thread&.join(1)
  end

  def test_unit_note_refuses_two_note_flags_in_one_call
    [ %w[--comment brief --handoff done], %w[--comment brief --qa-feedback broken],
      %w[--comment brief --clarification why], %w[--comment one --comment two] ].each do |flags|
      err, status, connected = run_note(*flags)

      refute status.success?, "#{flags.inspect} must die"
      refute connected, "#{flags.inspect}: refused before any board call"
      assert_match(/per call/, err, flags.inspect)
    end
  end
end
