# frozen_string_literal: true

# Unit tests for bin/lib/board_checks.rb — the checks_run read and read-back
# bin/control-check verifies its stamp with.
#
#   ruby -Itest test/lib/board_checks_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../../bin/lib/board_checks"

class BoardChecksTest < Minitest::Test
  def with_stub_bin(body)
    Dir.mktmpdir do |dir|
      stub = File.join(dir, "task-stub")
      File.write(stub, "#!#{RbConfig.ruby}\n#{body}\n")
      FileUtils.chmod("+x", stub)
      yield stub
    end
  end

  def showing(record)
    with_stub_bin("puts #{JSON.generate(record).dump}") { |stub| yield stub }
  end

  def test_fetch_reads_the_tasks_checks_run
    showing({ "metadata" => { "devops" => { "checks_run" => ["[unit] a", "[control@abc] b"] } } }) do |stub|
      assert_equal ["[unit] a", "[control@abc] b"], BoardChecks.fetch(stub, "demo")
    end
  end

  def test_fetch_is_an_empty_array_when_the_task_has_none
    showing({ "metadata" => { "devops" => { "kind" => "bug" } } }) do |stub|
      assert_equal [], BoardChecks.fetch(stub, "demo")
    end
  end

  def test_fetch_is_nil_on_failure_or_bad_json
    with_stub_bin("exit 1") { |stub| assert_nil BoardChecks.fetch(stub, "demo") }
    with_stub_bin('puts "not json"') { |stub| assert_nil BoardChecks.fetch(stub, "demo") }
    assert_nil BoardChecks.fetch("/nonexistent/task", "demo")
  end

  def test_fetch_is_nil_when_the_record_has_no_devops
    # "I did not find the shape I was looking for" is not evidence of absence.
    showing({ "metadata" => {} }) { |stub| assert_nil BoardChecks.fetch(stub, "demo") }
    showing([]) { |stub| assert_nil BoardChecks.fetch(stub, "demo") }
  end

  def test_missing_after_write_counts_duplicates_not_membership
    showing({ "metadata" => { "devops" => { "checks_run" => ["[unit] a"] } } }) do |stub|
      assert_equal ["[unit] a"], BoardChecks.missing_after_write(stub, "demo", ["[unit] a", "[unit] a"]),
                   "two copies were expected and one persisted — one is lost"
    end
  end

  def test_missing_after_write_names_the_lines_the_board_lost
    showing({ "metadata" => { "devops" => { "checks_run" => ["[unit] a"] } } }) do |stub|
      assert_equal ["[control@abc] b"], BoardChecks.missing_after_write(stub, "demo", ["[unit] a", "[control@abc] b"])
    end
  end

  def test_missing_after_write_is_empty_when_everything_persisted
    showing({ "metadata" => { "devops" => { "checks_run" => ["[unit] a", "[control@abc] b", "extra"] } } }) do |stub|
      assert_equal [], BoardChecks.missing_after_write(stub, "demo", ["[unit] a", "[control@abc] b"])
    end
  end

  def test_missing_after_write_is_nil_when_the_read_back_fails
    with_stub_bin("exit 1") do |stub|
      assert_nil BoardChecks.missing_after_write(stub, "demo", ["[unit] a"]),
                 "UNVERIFIABLE is distinct from a confirmed loss"
    end
  end
end
