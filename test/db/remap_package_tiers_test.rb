require "test_helper"

# [unit] A new app request starts on the Vibe tier, in the model and in the column default.
class RemapPackageTiersTest < ActiveSupport::TestCase
  test "a new app request defaults to the Vibe tier" do
    assert_equal "vibe", AppRequest.new.tier
    assert_equal "vibe", AppRequest.column_defaults["tier"]
  end
end
