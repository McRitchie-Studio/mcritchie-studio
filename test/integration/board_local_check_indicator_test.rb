require "test_helper"

# The local-check indicator on the board card — the answer to "this task has been
# in `building` a while, is anything actually happening?"
#
# Covers the [component] tier (the partial's three states, rendered) and the
# [integration] tier (GateRun write funnel → board render → handover to the CI
# meter). The states are asserted on the REAL board page because that is where the
# handover rules live: stage, pr_url, and the CI meter all decide the same slot.
class BoardLocalCheckIndicatorTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  SLOT = "[data-test='task-local-check']".freeze

  def building_task(slug: "local-check-probe", devops: {})
    Task.create!(title: "local check probe", stage: "building", slug: slug,
                 metadata: { "devops" => devops })
  end

  def open_cert(slug, sops:, started_at: 40.seconds.ago)
    GateRun.create!(subject_type: "task", subject_slug: slug, key: "g1_cert",
                    attempt: 1, started_at: started_at, sops: sops)
  end

  def running_sop(sop: "mapped-tests", at: Time.current, cmd: "bin/rails test test/models/x_test.rb")
    { "sop" => sop, "cmd" => cmd, "result" => "running", "at" => at.iso8601 }
  end

  # --- [component] the three states ---

  test "[component] a live cert renders a spinner, the lane name, and a ticking clock" do
    task = building_task
    open_cert(task.slug, sops: [running_sop(at: 5.seconds.ago)], started_at: 2.minutes.ago)

    log_in_as(@admin)
    get tasks_path
    assert_response :success

    assert_select "#{SLOT}[data-local-check-state='running']", 1
    assert_select "#{SLOT} [data-test='task-local-check-spinner']", 1
    assert_select "#{SLOT} [data-test='task-local-check-label']", text: /Running mapped tests/
    # The clock ticks live off the shared release ticker, seeded from the attempt start.
    clock = css_select("#{SLOT} [data-test='task-local-check-clock']").first
    assert clock, "a running check must show a clock"
    assert_equal "running", clock["data-local-check-clock"]
    assert clock["data-release-ticker"], "the clock must tick, not sit at its render-time value"
  end

  test "[component] a dead runner renders STALLED, not a spinner that never ends" do
    # The failure this whole feature exists to prevent: a killed cert (routine —
    # a cold bin/ship outruns some harness timeouts) must not keep claiming work.
    task = building_task
    stale = Cert::LocalCheck::STALE_AFTER + 2.minutes
    open_cert(task.slug, sops: [running_sop(at: stale.ago)], started_at: 20.minutes.ago)

    log_in_as(@admin)
    get tasks_path

    assert_select "#{SLOT}[data-local-check-state='stalled']", 1
    assert_select "#{SLOT} [data-test='task-local-check-spinner']", 0,
                  "a stalled check must NOT keep spinning — that is the lie"
    assert_select "#{SLOT} [data-test='task-local-check-stalled-icon']", 1
    assert_select "#{SLOT} [data-test='task-local-check-label']", text: /stalled/i

    clock = css_select("#{SLOT} [data-test='task-local-check-clock']").first
    assert_equal "stalled", clock["data-local-check-clock"]
    assert_nil clock["data-release-ticker"],
               "a frozen clock must not tick — a rising number would claim progress"
  end

  test "[component] a building task with no cert running renders an empty slot" do
    task = building_task

    log_in_as(@admin)
    get tasks_path

    assert_select SLOT, 0, "no cert means no indicator"
    assert_select "#local-check-#{task.slug}", 1,
                  "the Turbo target must still exist so a later morph has somewhere to land"
  end

  test "[component] the command behind the lane rides along as the tooltip" do
    task = building_task
    open_cert(task.slug, sops: [running_sop(cmd: "bin/rubocop app/models/widget.rb")])

    log_in_as(@admin)
    get tasks_path

    assert_select "#{SLOT}[title='bin/rubocop app/models/widget.rb']", 1
  end

  # --- [integration] the write funnel → the board ---

  test "[integration] the cert's own emits drive the indicator from open to close" do
    task = building_task
    args = { subject_type: "task", subject_slug: task.slug, key: "g1_cert" }
    log_in_as(@admin)

    # 1. bin/gate open — the attempt exists before any lane reports.
    GateRun.open!(**args)
    get tasks_path
    assert_select "#{SLOT}[data-local-check-state='running']", 1
    assert_select "#{SLOT} [data-test='task-local-check-label']",
                  text: /#{Cert::LocalCheck::FALLBACK_LABEL}/

    # 2. A lane announces itself — the card names it.
    GateRun.append_sop!(**args, sop: { "sop" => "spine", "cmd" => "bin/rails test", "result" => "running" })
    get tasks_path
    assert_select "#{SLOT} [data-test='task-local-check-label']", text: /Running core spine/

    # 3. The lane settles and the cert closes — the indicator leaves entirely.
    GateRun.close!(**args, success: true)
    get tasks_path
    assert_select SLOT, 0, "a finished cert is history — the slot must clear"
  end

  test "[integration] heartbeats keep one running row, so a long lane stays alive" do
    task = building_task
    args = { subject_type: "task", subject_slug: task.slug, key: "g1_cert" }
    GateRun.open!(**args)

    # A lane running long enough to beat several times — the case that would read
    # as stalled without a heartbeat, and would bloat the sops list without the
    # supersede rule.
    4.times do |i|
      travel_to (4 - i).minutes.ago do
        GateRun.append_sop!(**args, sop: { "sop" => "full-suite", "cmd" => "bin/rails test", "result" => "running" })
      end
    end
    GateRun.append_sop!(**args, sop: { "sop" => "full-suite", "cmd" => "bin/rails test", "result" => "running" })

    run = GateRun.for_subject("task", task.slug).where(key: "g1_cert").in_flight.first
    assert_equal 1, run.sops.length, "beats must collapse into one row"

    log_in_as(@admin)
    get tasks_path
    assert_select "#{SLOT}[data-local-check-state='running']", 1,
                  "a beating lane is alive however long it has run"
    assert_select "#{SLOT} [data-test='task-local-check-label']", text: /Running full suite/
  end

  # --- [integration] the handover to the CI meter ---

  test "[integration] the indicator yields the slot once bin/ship opens the PR" do
    # The two must never stack: bin/ship runs the cert, then opens the PR, and from
    # that moment the CI meter owns this slot.
    task = building_task(devops: { "pr_url" => "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999" })
    open_cert(task.slug, sops: [running_sop])

    log_in_as(@admin)
    get tasks_path

    assert_select SLOT, 0, "a PR exists — the CI meter takes over from here"
  end

  test "[integration] the gates card never paints a RUNNING lane with the pass glyph" do
    # The `running` marker rides the SAME sops list the task's gate card renders, which
    # painted everything not "fail" green — a killed runner's lane read as PASSED.
    task = building_task(slug: "local-check-gates")
    open_cert(task.slug, sops: [running_sop,
                                { "sop" => "spine", "result" => "pass", "at" => Time.current.iso8601 }])

    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    assert_select "[data-result='running'] [data-test='gate-sop-glyph']", text: "◌"
    assert_select "[data-result='pass'] [data-test='gate-sop-glyph']", text: "✓"
  end

  test "[integration] a submitted task shows no local-check indicator" do
    task = Task.create!(title: "submitted local check probe", stage: "submitted", slug: "local-check-submitted")
    open_cert(task.slug, sops: [running_sop])

    log_in_as(@admin)
    get tasks_path

    assert_select SLOT, 0, "the indicator belongs to `building` alone"
  end
end
