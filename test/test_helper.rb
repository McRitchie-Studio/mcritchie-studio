ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

OmniAuth.config.test_mode = true

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  # Passwordless: mint + consume a magic-link token (create-or-login). The user
  # must have an email. In test the cache is :null_store, so MagicLink skips
  # single-use enforcement and the token consumes cleanly.
  def log_in_as(user)
    token = MagicLink.generate(email: user.email)
    get magic_link_path(token)
  end
end
