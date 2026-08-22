require "test_helper"

# Unit — the batch reader. The board renders dozens of cards, so the ONE thing
# that must not regress is that this stays a single query no matter how many.
class Cert::LocalCheckReaderTest < ActiveSupport::TestCase
  def open_run(slug, started_at: 20.seconds.ago, attempt: 1, sops: [])
    GateRun.create!(subject_type: "task", subject_slug: slug, key: "g1_cert",
                    attempt: attempt, started_at: started_at, sops: sops)
  end

  def task_double(slug) = Struct.new(:slug).new(slug)

  test "maps in-flight attempts by task slug" do
    open_run("alpha")
    open_run("beta")

    map = Cert::LocalCheckReader.new.for_tasks([task_double("alpha"), task_double("beta")])

    assert_equal %w[alpha beta].sort, map.keys.sort
    assert_kind_of Cert::LocalCheck, map["alpha"]
  end

  test "omits tasks whose cert has closed" do
    run = open_run("alpha")
    run.update!(finished_at: Time.current, success: true)

    assert_empty Cert::LocalCheckReader.new.for_tasks([task_double("alpha")])
  end

  test "omits tasks with no cert at all" do
    assert_empty Cert::LocalCheckReader.new.for_tasks([task_double("never-certified")])
  end

  test "reads every card in ONE query" do
    slugs = %w[a b c d e]
    slugs.each { |slug| open_run(slug) }
    tasks = slugs.map { |slug| task_double(slug) }

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      Cert::LocalCheckReader.new.for_tasks(tasks)
    end

    assert_equal 1, queries, "the board must not issue a GateRun query per card"
  end

  test "a retry after a failed cert reports the NEW attempt" do
    # Retries are first-class on GateRun: a failed cert closes and the re-run
    # opens attempt n+1. The card must follow the live one.
    open_run("alpha", attempt: 1, started_at: 10.minutes.ago)
      .update!(finished_at: 9.minutes.ago, success: false)
    open_run("alpha", attempt: 2, started_at: 5.seconds.ago)

    check = Cert::LocalCheckReader.new.for_tasks([task_double("alpha")])["alpha"]

    assert_equal 2, check.attempt, "the closed first attempt must never shadow the live retry"
    assert_predicate check, :running?
  end

  test "the database itself forbids a second in-flight attempt" do
    # Pins WHY the reader can trust `in_flight.first`: index_gate_runs_one_open_per_gate.
    open_run("alpha")

    assert_raises(ActiveRecord::RecordNotUnique) { open_run("alpha", attempt: 2) }
  end

  test "ignores gates that are not g1_cert" do
    GateRun.create!(subject_type: "task", subject_slug: "alpha", key: "g2a_primary",
                    attempt: 1, started_at: 10.seconds.ago)

    assert_empty Cert::LocalCheckReader.new.for_tasks([task_double("alpha")]),
      "a review gate is not a local test run"
  end

  test "no tasks means no query and an empty map" do
    assert_empty Cert::LocalCheckReader.new.for_tasks([])
  end

  test "for_task reads a single card" do
    open_run("alpha")

    assert_kind_of Cert::LocalCheck, Cert::LocalCheckReader.new.for_task(task_double("alpha"))
    assert_nil Cert::LocalCheckReader.new.for_task(task_double("other"))
  end
end
