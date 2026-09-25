# frozen_string_literal: true

# Unit tests for bin/lib/process_table.rb — the OS's own answer to "what is
# running, and since when?", which every presence reader grades claims against.
#
#   ruby -Itest test/lib/process_table_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require_relative "../../bin/lib/process_table"

class ProcessTableTest < Minitest::Test
  OURS = "Mon Jul 13 05:00:00 2026"

  def process(pid:, pgid: nil, state: "S", started_at: OURS, command: "ruby bin/rails test")
    { pid: pid, pgid: pgid || pid, state: state, started_at: started_at, command: command }
  end

  # --- the ps parser: identity is only as good as the field we read -----------

  def test_ps_lines_parse_into_identity
    row = ProcessTable.parse_ps_line("41578  41538 S    Mon Jul 13 05:00:00 2026 ruby bin/rails test test/x.rb")

    assert_equal 41_578, row[:pid]
    assert_equal 41_538, row[:pgid]
    assert_equal "S", row[:state]
    assert_equal "Mon Jul 13 05:00:00 2026", row[:started_at]
    assert_equal "ruby bin/rails test test/x.rb", row[:command]
  end

  def test_an_unparseable_ps_line_yields_no_identity
    assert_nil ProcessTable.parse_ps_line("garbage")
    assert_nil ProcessTable.parse_ps_line("")
    assert_nil ProcessTable.parse_ps_line("x y z Mon Jul 13 05:00:00 2026 cmd"), "a non-integer pid names nobody"
  end

  def test_the_live_table_reads_this_very_process
    row = ProcessTable.live_process(ProcessTable.process_table, Process.pid)

    refute_nil row, "one `ps -Ao` snapshot must include the reader itself"
    assert_equal Process.getpgrp, row[:pgid]
    assert_equal ProcessTable.process_started_at(Process.pid), row[:started_at],
                 "the per-pid start time and the table's must agree, or identity_of can never say :ours"
  end

  def test_a_missing_ps_binary_yields_an_empty_table_rather_than_raising
    assert_equal [], ProcessTable.process_table(ps: "/nonexistent/ps")
    assert_nil ProcessTable.process_started_at(Process.pid, ps: "/nonexistent/ps")
  end

  # --- identity ---------------------------------------------------------------

  def test_identity_matches_on_the_recorded_start_time
    assert_equal :ours, ProcessTable.identity_of(process(pid: 1), OURS)
    assert_equal :not_ours, ProcessTable.identity_of(process(pid: 1), "Wed Jul  9 22:14:03 2026")
  end

  def test_start_time_matching_tolerates_the_ps_day_padding
    # `ps` space-pads the day-of-month ("Jul  9" vs "Jul 9"). A false MISMATCH would
    # grade a live claim :not_ours and under-report a busy machine.
    padded = process(pid: 4300, started_at: "Wed Jul  9 22:14:03 2026")

    assert_equal :ours, ProcessTable.identity_of(padded, "Wed Jul 9 22:14:03 2026"),
                 "same instant, different whitespace — the same process"
  end

  def test_identity_is_unprovable_without_both_sides
    assert_equal :unprovable, ProcessTable.identity_of(nil, OURS)
    assert_equal :unprovable, ProcessTable.identity_of(process(pid: 1), nil)
    assert_equal :unprovable, ProcessTable.identity_of(process(pid: 1, started_at: nil), OURS)
  end

  # --- liveness ---------------------------------------------------------------

  def test_a_zombie_is_neither_live_nor_a_group_member
    table = [process(pid: 10, pgid: 10, state: "Z"), process(pid: 11, pgid: 10)]

    assert ProcessTable.zombie?(table[0])
    assert_nil ProcessTable.live_process(table, 10)
    assert_equal [table[1]], ProcessTable.group_members(table, 10)
  end

  def test_a_non_positive_pid_names_nobody
    table = [process(pid: 10)]

    assert_nil ProcessTable.live_process(table, 0)
    assert_nil ProcessTable.live_process(table, -1)
    assert_equal [], ProcessTable.group_members(table, 0)
  end

  # --- coerce_pid: a pid out of JSON is whatever was on disk ------------------

  def test_coerce_pid_accepts_integers_and_numeric_strings_only
    assert_equal 4300, ProcessTable.coerce_pid(4300)
    assert_equal 4300, ProcessTable.coerce_pid(" 4300 ")
    [{}, [], "not-a-pid", nil, "", true].each do |garbage|
      assert_nil ProcessTable.coerce_pid(garbage), "#{garbage.inspect} is not a pid"
    end
  end
end
