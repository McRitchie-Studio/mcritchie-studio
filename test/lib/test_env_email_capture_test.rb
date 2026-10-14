require "test_helper"

# [unit] The suite runs with local email capture OFF, even in a desk whose .env
# sets LOCAL_EMAIL_CAPTURE=1 and whose stack exports AGENT_WORKTREE=1
# (test/test_helper.rb). With capture on, Studio::Email stores the message for
# /_studio/local_emails instead of delivering it, and every email assertion in
# the suite reads zero.
class TestEnvEmailCaptureTest < ActiveSupport::TestCase
  teardown { Studio.local_email_capture = nil }

  test "[unit] the test environment pins both capture switches off" do
    assert_equal "0", ENV["LOCAL_EMAIL_CAPTURE"]
    assert_equal "0", ENV["AGENT_WORKTREE"]

    Studio.local_email_capture = nil
    refute Studio.local_email_capture?, "with no override, the suite does not capture"
  end

  test "[unit] a test can still turn capture on for itself" do
    Studio.local_email_capture = true

    assert Studio.local_email_capture?
  end
end
