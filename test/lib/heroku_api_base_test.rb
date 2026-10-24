# frozen_string_literal: true

# [unit] HerokuApiBase holds every Heroku base-URL override to the real API or
# loopback, so a planted override cannot collect a bearer token
# (secrets-scrub-follow-ups, N6). bin/heroku-secret-set's end-to-end refusal is
# in test/lib/heroku_secret_set_test.rb; this pins the shared rule and the second
# client, bin/rotate-heroku-ci-key's HerokuApi.
#
# Run directly:  ruby -Itest test/lib/heroku_api_base_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/heroku_api_base"
require_relative "../../bin/lib/heroku_ci_key_rotation"

class HerokuApiBaseTest < Minitest::Test
  REFUSED = [
    "https://evil.example", "https://api.heroku.com.evil.example", "https://api.heroku.com@evil.example",
    "http://api.heroku.com", "https://api.heroku.com:8443", "http://10.0.0.5:9000",
    "https://api.heroku.com/elsewhere", "https://api.heroku.com/?x=1", "", "not a url"
  ].freeze

  # The control: what must still pass, or the rule is merely refusing everything.
  ALLOWED = ["https://api.heroku.com", "https://API.Heroku.com/", "http://127.0.0.1:4567", "http://localhost:80",
             "http://[::1]:9"].freeze

  def test_only_the_real_api_and_loopback_pass
    REFUSED.each do |base|
      assert_raises(HerokuApiBase::Refused, "#{base.inspect} was accepted") { HerokuApiBase.resolve!(base, name: "X") }
    end
    ALLOWED.each { |base| assert_kind_of URI::Generic, HerokuApiBase.resolve!(base, name: "X"), base }
  end

  def test_the_ci_key_rotation_client_refuses_a_foreign_base_as_an_abort
    error = assert_raises(HerokuCiKeyRotation::Abort) { HerokuCiKeyRotation::HerokuApi.new(base: "https://evil.example") }
    assert_includes error.message, "ROTATE_HEROKU_CI_KEY_API_BASE"
    assert HerokuCiKeyRotation::HerokuApi.new(base: "http://127.0.0.1:9"), "loopback must still construct"
  end
end
