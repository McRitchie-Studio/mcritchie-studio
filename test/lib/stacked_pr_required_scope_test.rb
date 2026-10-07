# frozen_string_literal: true

# Guard catalog row 1.12: StackedPr.guard_base takes `repo_scope:` as a REQUIRED keyword,
# so a caller that forgets which repo to probe fails at the call, before any gh read,
# instead of reaching a false :not_stacked from the cwd's repo. Run directly:
#   ruby -Itest test/lib/stacked_pr_required_scope_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/stacked_pr"

class StackedPrRequiredScopeTest < Minitest::Test
  def test_omitting_the_repo_scope_is_an_argument_error_before_any_probe
    listed = []
    error = assert_raises(ArgumentError) do
      StackedPr.guard_base(base: "feat/parent", accepted: "accepted", slug: "demo-task",
                           pr_url: "https://github.com/o/r/pull/701",
                           list: ->(head) { listed << head; ["[]", true] },
                           edit: ->(_base) { true }, say: ->(_line) {})
    end

    assert_includes error.message, "repo_scope"
    assert_empty listed, "a call without a scope must not reach the probe"
  end
end
