require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "environment banner shows in non-production rails environments" do
    assert show_environment_banner?(
      qa_environment: false,
      rails_env: ActiveSupport::StringInquirer.new("development")
    )
  end

  test "environment banner shows in QA even when Rails runs in production mode" do
    assert show_environment_banner?(
      qa_environment: true,
      rails_env: ActiveSupport::StringInquirer.new("production")
    )
  end

  test "environment banner hides in production when not QA" do
    assert_not show_environment_banner?(
      qa_environment: false,
      rails_env: ActiveSupport::StringInquirer.new("production")
    )
  end

  test "environment banner message calls out QA as non-production" do
    assert_equal "QA Environment · Non-production",
                 environment_banner_message(
                   qa_environment: true,
                   rails_env: ActiveSupport::StringInquirer.new("production")
                 )
  end
end
