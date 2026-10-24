require "test_helper"
require_relative "../../bin/lib/harness_key"

# [integration] The client's list of the requests a harness key is presented on
# (HarnessKey::DOORS) agrees with the board's (accepts_harness_key), route by
# route, both ways: the tooling never presents the key where the board refuses
# it, and never sends the shared token where the board takes the key.
class HarnessKeyClientDoorsTest < ActiveSupport::TestCase
  CLAIM = { "stage" => "building", "event" => { "source" => "cli" } }.freeze

  # Every api/v1 route as [verb, a concrete path, controller class, action].
  def api_routes
    Rails.application.routes.routes.filter_map do |route|
      controller, action = route.defaults.values_at(:controller, :action)
      next unless controller.to_s.start_with?("api/v1/") && route.verb.present?

      path = route.path.spec.to_s.sub("(.:format)", "").gsub(/:[a-z_]+/, "x")
      [ route.verb, path, "#{controller.camelize}Controller".safe_constantize, action.to_s ]
    end
  end

  def server_door?(klass, action)
    klass.respond_to?(:harness_key_doors) && klass.harness_key_doors.key?(action)
  end

  test "every route the board opens to the key, the client presents it on" do
    opened = api_routes.select { |_, _, klass, action| server_door?(klass, action) }
    assert_operator opened.size, :>=, 25

    opened.each do |verb, path, _, action|
      next if verb == "PUT" # Rails routes an update by PUT too; the tooling sends PATCH

      body = action == "update" ? CLAIM : {}
      assert HarnessKey.accepts?(verb, path, body), "the client does not present the key on #{verb} #{path} (#{action})"
    end
  end

  test "every route the client presents the key on, the board opens" do
    api_routes.each do |verb, path, klass, action|
      next unless HarnessKey.accepts?(verb, path, CLAIM)

      assert server_door?(klass, action), "the client presents the key on #{verb} #{path}, which #{klass}##{action} refuses"
    end
  end

  test "the client's claim fields are the board's" do
    assert_equal Api::V1::TasksController::HARNESS_CLAIM_FIELDS, HarnessKey::CLAIM_FIELDS
  end
end
