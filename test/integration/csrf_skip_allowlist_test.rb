require "test_helper"

# [unit] hub-security-gates-pass: every browser controller verifies the CSRF
# token on every write, except the controllers named below, each with its reason.
#
# The check reads each controller's own callback chain rather than grepping for
# a spelling, so `skip_before_action :verify_authenticity_token`,
# `skip_forgery_protection`, a conditional `if:`/`unless:`/`only:` skip and an
# inherited skip all count, and so does `protect_from_forgery with: :null_session`
# (a missing token then signs the request out instead of refusing it, and a
# controller that also reads a bearer token would carry on as that caller).
#
# A JSON write is not an exemption: a same-site page can POST a plain form to a
# `.json` route with the session cookie attached (JsonWritesKeepCsrfTest). A
# controller that must take writes without a session token belongs in the
# bearer-gated /api/v1 namespace (ActionController::API, outside this chain), or
# here, with the reason it is safe.
class CsrfSkipAllowlistTest < ActiveSupport::TestCase
  ALLOWED = {
    "csp_reports" => "the browser posts CSP violation reports on its own, with no page and no token; it only stores a capped, " \
                     "query-stripped telemetry row and is rate-limited (CspReportsController)",
    "unsubscribes" => "the one-click List-Unsubscribe POST comes from the mail client with no page; the URL's token is the credential",
    "webhooks/resend_events" => "Resend's server posts it; the svix signature is the credential (Webhooks::SvixSignature)",
    "webhooks/resend_inbound" => "Resend's server posts it; the svix signature is the credential (Webhooks::SvixSignature)"
  }.freeze

  EXCEPTION_STRATEGY = ActionController::RequestForgeryProtection::ProtectionMethods::Exception

  # The controllers this app and studio-engine define (Rails' own Active Storage,
  # Action Mailbox and health controllers carry their own forgery settings).
  def self.browser_controllers
    Rails.application.eager_load!
    engine_root = Gem.loaded_specs["studio-engine"]&.full_gem_path
    roots = [ Rails.root.join("app").to_s, engine_root ].compact
    ActionController::Base.descendants.select do |klass|
      next false if klass.name.nil?

      file = Object.const_source_location(klass.name)&.first
      file && roots.any? { |root| file.start_with?(root) }
    end
  end

  # Why this controller can take a write without the token, or nil when it cannot.
  def self.csrf_gap(klass)
    callback = klass._process_action_callbacks.find { |cb| cb.filter == :verify_authenticity_token }
    return "verify_authenticity_token is skipped" if callback.nil?

    conditions = Array(callback.instance_variable_get(:@if)) + Array(callback.instance_variable_get(:@unless))
    return "verify_authenticity_token runs only under a condition" if conditions.any?
    return "the forgery strategy is #{klass.forgery_protection_strategy}" unless klass.forgery_protection_strategy == EXCEPTION_STRATEGY

    nil
  end

  test "only the allow-listed controllers take a write without the CSRF token" do
    controllers = self.class.browser_controllers
    gaps = controllers.filter_map { |klass| (gap = self.class.csrf_gap(klass)) && [ klass.controller_path, gap ] }.to_h

    unexpected = gaps.except(*ALLOWED.keys)
    assert_empty unexpected, "These controllers accept a write without the CSRF token. Verify it, move the " \
                             "endpoint under the bearer-gated /api/v1, or add it to ALLOWED with the reason it is safe:\n" +
                             unexpected.map { |path, gap| "  #{path}: #{gap}" }.join("\n")
    assert_empty ALLOWED.keys - gaps.keys, "ALLOWED names a controller that now verifies the token; drop its entry"
  end

  test "the scan reads the controllers it guards" do
    paths = self.class.browser_controllers.map(&:controller_path)
    %w[tasks contents news model_pipeline unsubscribes webhooks/resend_events].each do |path|
      assert_includes paths, path
    end
  end

  test "the detector sees every way a controller can drop the check" do
    json_skip = Class.new(ApplicationController) { skip_before_action :verify_authenticity_token, if: -> { request.format.json? } }
    only_skip = Class.new(ApplicationController) { skip_forgery_protection only: :update }
    full_skip = Class.new(ApplicationController) { skip_before_action :verify_authenticity_token }
    null_session = Class.new(ApplicationController) { protect_from_forgery with: :null_session }

    assert_match(/condition/, self.class.csrf_gap(json_skip))
    assert_match(/condition/, self.class.csrf_gap(only_skip))
    assert_match(/skipped/, self.class.csrf_gap(full_skip))
    assert_match(/strategy/, self.class.csrf_gap(null_session))
    assert_nil self.class.csrf_gap(ApplicationController)
    assert_nil self.class.csrf_gap(TasksController)
  end
end
