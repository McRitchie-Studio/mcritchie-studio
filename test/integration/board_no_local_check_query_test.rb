# frozen_string_literal: true

require "test_helper"

# The local cert is retired (docs/agents/archive/g1-cert-2026-10-06.md) and nothing
# opens a g1_cert gate any more, so the board's "local check running" indicator
# could never fire — yet every render still queried in-flight g1_cert rows to feed
# it. The indicator is gone; these pin that the boards no longer ask for it.
#
# The fixture is the WORST case for the old code: a building task with no PR and a
# stale in-flight g1_cert row, which is exactly the shape that read used to find
# and paint. Even that must render nothing and cost no g1 query.
class BoardNoLocalCheckQueryTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex))
    @task = Task.create!(slug: "retired-cert-probe", title: "Retired Cert Probe", stage: "building",
                         metadata: { "devops" => { "repositories" => %w[mcritchie-studio] } })
    # The model keeps g1_cert as a retired key so old rows still validate; this
    # is one of those old rows, still open.
    GateRun.create!(subject_type: "task", subject_slug: @task.slug, key: "g1_cert",
                    attempt: 1, started_at: 3.minutes.ago,
                    sops: [{ "sop" => "mapped-tests", "result" => "running", "at" => 1.minute.ago.iso8601 }])
  end

  test "[integration] /tasks renders the building card with no g1 query and no local-check markup" do
    queries = g1_queries { get tasks_path }

    assert_response :success
    assert_select "#card-#{@task.slug}", 1, "the building card itself must still render"
    assert_empty queries, "the board must not read g1_cert rows; it read:\n#{queries.join("\n")}"
    assert_no_local_check_markup
  end

  test "[integration] /deployments renders with no g1 query and no local-check markup" do
    queries = g1_queries { get deployments_path }

    assert_response :success
    assert_empty queries, "the deploy board must not read g1_cert rows; it read:\n#{queries.join("\n")}"
    assert_no_local_check_markup
  end

  private

  def assert_no_local_check_markup
    assert_select "[data-test='task-local-check']", 0
    assert_select "[data-local-check-state]", 0
    assert_select "[id^='local-check-']", 0
  end

  # Every gate_runs SELECT that names g1_cert, in its SQL text OR its binds. The
  # bind check is load-bearing: `where(key: "g1_cert")` runs as a prepared statement,
  # so the key is a bind value and never appears in the SQL text (the trap
  # test/integration/app_ladder_row_test.rb documents). Matching text alone would
  # count zero against the old code and prove nothing.
  def g1_queries
    hits = []
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if payload[:cached] || payload[:name].to_s == "SCHEMA"

      sql = payload[:sql].to_s
      next unless sql.include?(%(FROM "gate_runs"))

      binds = Array(payload[:binds]).map { |bind| bind.respond_to?(:value_before_type_cast) ? bind.value_before_type_cast : bind }
      binds += Array(payload[:type_casted_binds].respond_to?(:call) ? payload[:type_casted_binds].call : payload[:type_casted_binds])
      hits << "#{sql} #{binds.inspect}" if sql.include?("g1_cert") || binds.flatten.map(&:to_s).include?("g1_cert")
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    hits
  end
end
