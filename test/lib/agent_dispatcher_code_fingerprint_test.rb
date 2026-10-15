# frozen_string_literal: true

# [unit] The dispatcher restarts itself on new code
# (AgentMailbox::CodeFingerprint + Dispatcher#check_code). The fingerprint
# digests the files the process loaded from its repo plus config/agent_routes.yml
# and nothing else; the loop re-reads it on the ping beat and restarts only after
# the SAME new digest is seen on two checks in a row. Temp dirs and a stub
# board client only: nothing reaches the board, launchd or Claude.
#   ruby -Itest test/lib/agent_dispatcher_code_fingerprint_test.rb
require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../../bin/lib/agent_dispatcher"

class AgentDispatcherCodeFingerprintTest < Minitest::Test
  # A board that never has a message: claim answers nothing, the rest record.
  class IdleClient
    attr_reader :pings

    def initialize = @pings = []
    def claim(**) = { "data" => nil }
    def ping(payload) = @pings << payload
    def renew(*, **) = nil
    def release(*, **) = nil
  end

  def setup
    @root = Dir.mktmpdir("dispatcher-repo")
    %w[bin/lib config lib].each { |d| FileUtils.mkdir_p(File.join(@root, d)) }
    write("bin/dispatcher", "entry")
    write("bin/lib/agent_dispatcher.rb", "loop v1")
    write("bin/lib/agent_mailbox.rb", "mailbox v1")
    write("config/agent_routes.yml", "souls: xan")
    write("lib/unrelated.rb", "not loaded")
    @now = Time.at(1_800_000_000)
    @out = StringIO.new
  end

  def teardown = FileUtils.rm_rf(@root)

  def write(rel, body) = File.write(File.join(@root, rel), body)
  def path(rel) = File.join(@root, rel)

  def fingerprint
    loaded = [ path("bin/lib/agent_dispatcher.rb"), path("bin/lib/agent_mailbox.rb"), "/gems/json/lib/json.rb" ]
    AgentMailbox::CodeFingerprint.for_process(repo_root: @root, entry: path("bin/dispatcher"), loaded: loaded)
  end

  def test_it_covers_the_entry_the_repo_files_it_loaded_and_the_routes_only
    assert_equal [ "bin/dispatcher", "bin/lib/agent_dispatcher.rb", "bin/lib/agent_mailbox.rb", "config/agent_routes.yml" ].sort,
                 fingerprint.files.map { |f| f.delete_prefix("#{File.realpath(@root)}/").delete_prefix("#{@root}/") }.sort
  end

  def test_an_edit_to_a_loaded_file_or_the_routes_changes_the_digest
    fp = fingerprint
    before = fp.call
    assert_equal before, fp.call, "stable while nothing changes"

    write("bin/lib/agent_mailbox.rb", "mailbox v2")
    refute_equal before, (after_code = fp.call)

    write("config/agent_routes.yml", "souls: xan, avi")
    refute_equal after_code, fp.call, "a routing change restarts it too: souls are read only at startup"
  end

  def test_an_unrelated_file_does_not_change_the_digest
    fp = fingerprint
    before = fp.call
    write("lib/unrelated.rb", "changed by an unrelated release")
    write("bin/lib/new_helper.rb", "a file the dispatcher never loaded")

    assert_equal before, fp.call
  end

  def test_a_deleted_file_digests_as_missing_without_raising
    fp = fingerprint
    before = fp.call
    File.delete(path("bin/lib/agent_mailbox.rb"))

    refute_equal before, fp.call
  end

  # --- the loop's check ------------------------------------------------------

  def dispatcher(fp)
    AgentMailbox::Dispatcher.new(client: IdleClient.new, souls: %w[xan], worker: "fp-test", out: @out,
                                 clock: -> { @now }, sleeper: ->(_) { }, repo_root: @root, idle_wait: 0,
                                 version: "test", fingerprint: fp)
  end

  def tick_at(disp, seconds)
    @now += seconds
    disp.tick
  end

  def test_it_restarts_only_after_the_same_new_digest_twice_on_the_ping_beat
    disp = dispatcher(fingerprint)
    tick_at(disp, 1)

    write("bin/lib/agent_dispatcher.rb", "loop v2")
    tick_at(disp, 10)
    refute disp.stopping?, "the check runs on the ping beat, not every tick"

    tick_at(disp, 60)
    refute disp.stopping?, "one sighting of a new digest is not enough"

    tick_at(disp, 60)
    assert disp.stopping?
    assert disp.restarting?
    assert_equal 1, @out.string.scan(/code changed \(\h{12} -> \h{12}\); restarting on the new code/).size,
                 "one log line for the restart"
  end

  def test_a_checkout_read_mid_change_does_not_restart
    disp = dispatcher(fingerprint)

    write("bin/lib/agent_dispatcher.rb", "half written")
    tick_at(disp, 60)
    write("bin/lib/agent_dispatcher.rb", "loop v1") # the move finished back where it was
    tick_at(disp, 60)
    tick_at(disp, 60)

    refute disp.stopping?, "a digest that did not hold for two checks never restarts it"
  end

  def test_a_still_moving_checkout_waits_for_the_digest_to_settle
    disp = dispatcher(fingerprint)

    write("bin/lib/agent_dispatcher.rb", "step one")
    tick_at(disp, 60)
    write("bin/lib/agent_dispatcher.rb", "step two")
    tick_at(disp, 60)
    refute disp.stopping?, "two DIFFERENT new digests in a row are not a settled change"

    tick_at(disp, 60)
    assert disp.restarting?
  end

  def test_a_fingerprint_that_raises_keeps_the_running_code
    calls = 0
    fp = -> { (calls += 1) == 1 ? "baseline" : raise(Errno::EACCES) }
    disp = dispatcher(fp)
    tick_at(disp, 60)
    tick_at(disp, 60)

    refute disp.stopping?
    assert_match(/code check failed \(Errno::EACCES\); keeping the running code/, @out.string)
  end

  def test_no_fingerprint_means_no_self_restart
    disp = dispatcher(nil)
    5.times { tick_at(disp, 60) }

    refute disp.stopping?
  end

  def test_a_restart_drains_until_the_run_deadline_but_a_signal_cuts_it_to_grace
    disp = dispatcher(-> { "same" })
    disp.restart_for_new_code!
    log = StringIO.new
    disp.instance_variable_set(:@out, log)
    disp.shutdown
    assert_match(/stopping for new code: 0 run\(s\) in flight, waiting up to #{AgentMailbox::Dispatcher::RUN_DEADLINE}s/,
                 log.string)

    started = @now
    disp.stop!
    assert_equal started + AgentMailbox::Dispatcher::GRACE,
                 disp.send(:drain_deadline, started, AgentMailbox::Dispatcher::RUN_DEADLINE, AgentMailbox::Dispatcher::GRACE),
                 "SIGTERM mid-drain (launchd's bootout) caps it at GRACE, under the plist's ExitTimeOut"
  end
end
