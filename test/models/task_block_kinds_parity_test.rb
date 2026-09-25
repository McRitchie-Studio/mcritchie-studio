# frozen_string_literal: true

require "test_helper"

# bin/task validates `block --kind` against its OWN copy of the block kinds, because
# it runs without Rails loaded. When that copy drifts from Task::BLOCK_KINDS, the CLI
# refuses a kind the board accepts, or stamps one the board does not know.
#
# Retargeted from test/docs/bounce_holder_rule_docs_test.rb (deleted in
# trim-docs-guard-tests, 2026-09-25), which carried this parity check beside a guard
# for the retired verdict-owner gate.
class TaskBlockKindsParityTest < ActiveSupport::TestCase
  test "[unit] bin/task accepts exactly the block kinds the Task model declares" do
    source = Rails.root.join("bin/task").read
    match = source.match(/^BLOCK_KINDS = %w\[([^\]]*)\]/)

    refute_nil match, "bin/task no longer declares BLOCK_KINDS as a %w[] literal — re-point this pin"
    kinds = match[1].split

    refute_empty kinds, "parsed an empty BLOCK_KINDS out of bin/task"
    assert_equal Task::BLOCK_KINDS.sort, kinds.sort,
                 "bin/task accepts #{kinds.inspect} but Task::BLOCK_KINDS is #{Task::BLOCK_KINDS.inspect}"
  end
end
