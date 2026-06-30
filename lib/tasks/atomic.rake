namespace :atomic do
  # LOCAL DEMO DATA — not a historical backfill. AtomicAction capture is
  # forward-only and nothing emits rows yet, so /alex/heartbeat is empty until a
  # session runs. This seeds ONE representative greenfield trajectory (boot ->
  # recall -> intake -> design -> build -> submit) so the view has something to
  # render locally. Guarded out of production.
  desc "LOCAL-ONLY: seed a representative atomic-action trajectory so /alex/heartbeat has data."
  task demo_seed: :environment do
    raise "atomic:demo_seed is local demo data — refusing to run in production." if Rails.env.production?

    session_id = ENV.fetch("SESSION_ID", "demo-heartbeat-0001")
    mascot     = ENV.fetch("MASCOT", "rotom")
    task_slug  = ENV.fetch("TASK_SLUG", "atomic-action-capture")
    opus       = "claude-opus-4-8"

    # Opus-priced cost from the token split (input $5 / output $25 per 1M); board
    # and harness steps carry no model and so no cost.
    price = ->(tin, tout, model) { model ? (((tin * 5.0) + (tout * 25.0)) / 1_000_000.0).round(4) : 0 }

    # Idempotent: clear any prior demo rows for THIS session before reseeding.
    # destroy_all (not delete_all) so dependent ActionGrade rows go with them —
    # a raw DELETE trips the action_grades foreign key once a trajectory is graded.
    AtomicAction.where(session_id: session_id).destroy_all

    rows = [
      # Session group (null stage) — boot, recall, intake. Mascot is drawn mid-group.
      { kind: "boot",          actor: "harness", stage: nil, mascot: nil,
        ev: "Spin up fresh session runtime",          rs: "Session identity and model resolved" },
      { kind: "boot",          actor: "harness", stage: nil, mascot: nil, ti: 6400,
        ev: "Auto load the operating model docs",     rs: "DevOps cycle gate now enforced" },
      { kind: "recall",        actor: "harness", stage: nil, mascot: nil, ti: 8200,
        ev: "Recall relevant prior session memories", rs: "Known lessons surfaced for reuse" },
      { kind: "draw",          actor: "board",   stage: nil,
        ev: "Draw this session Pokemon mascot",       rs: "Session identity mascot now assigned" },
      { kind: "intake",        actor: "human",   stage: nil,
        ev: "Receive operator feature request message", rs: "Feature intent captured for triage" },
      { kind: "classify",      actor: "agent",   stage: nil, model: opus, ti: 1200, to: 90,
        ev: "Classify the request work kind",         rs: "Identified as a feature task" },
      { kind: "explore",       actor: "agent",   stage: nil, model: opus, ti: 900, to: 60,
        ev: "Identify the target application repo",   rs: "Routed to mcritchie studio repo" },

      # Designed group.
      { kind: "create-task",   actor: "board",   stage: "designed", task: task_slug,
        ev: "Create the production board task",       rs: "Task slug minted and bound" },
      { kind: "plan",          actor: "agent",   stage: "designed", task: task_slug, model: opus, ti: 5200, to: 900, anchor: true,
        ev: "Plan the implementation approach steps", rs: "Critical files and steps identified" },
      { kind: "dor-check",     actor: "board",   stage: "designed", task: task_slug,
        ev: "Run definition of ready build",          rs: "Spec completeness gate passed clean" },

      # Building group — includes a real error outcome and the recovery anchor.
      { kind: "explore",       actor: "agent",   stage: "building", task: task_slug, model: opus, ti: 9400, to: 360,
        ev: "Explore the model and schema seam",      rs: "Found the capture seam quickly" },
      { kind: "test",          actor: "agent",   stage: "building", task: task_slug, model: opus, ti: 3100, to: 780,
        ev: "Write a failing regression test first",  rs: "Red test reproduces the gap" },
      { kind: "edit",          actor: "agent",   stage: "building", task: task_slug, model: opus, ti: 6800, to: 2400,
        ev: "Implement the trajectory view code",     rs: "Controller view and helper written" },
      { kind: "run-test",      actor: "board",   stage: "building", task: task_slug, outcome: "error",
        ev: "Run the unit test suite",                rs: "One spec fails on null stage" },
      { kind: "recover-error", actor: "agent",   stage: "building", task: task_slug, model: opus, ti: 7200, to: 1900, anchor: true,
        ev: "Diagnose and fix the failing spec",      rs: "Sibling default applied to column" },
      { kind: "commit",        actor: "agent",   stage: "building", task: task_slug, model: opus, ti: 300, to: 80,
        ev: "Commit and push the feature branch",     rs: "Branch pushed code now preserved" },

      # Submitted group — full suite, PR, handoff, then a pending review wait.
      { kind: "full-suite",    actor: "board",   stage: "submitted", task: task_slug,
        ev: "Run full suite certification check",     rs: "Full suite and rubocop green" },
      { kind: "open-pr",       actor: "agent",   stage: "submitted", task: task_slug, model: opus, ti: 1800, to: 540,
        ev: "Open a pull request into release",       rs: "PR opened task URL leading" },
      { kind: "move-submitted", actor: "board",  stage: "submitted", task: task_slug,
        ev: "Move the task to submitted stage",       rs: "Build handed off at the seam" },
      { kind: "review-wait",   actor: "board",   stage: "submitted", task: task_slug, outcome: "pending",
        ev: "Await senior QA review verdict",         rs: "Submitted PR now in the queue" }
    ]

    base = 40.minutes.ago
    created = 0
    rows.each_with_index do |row, i|
      tin  = row[:ti].to_i
      tout = row[:to].to_i
      mc   = row.key?(:mascot) ? row[:mascot] : mascot
      action = AtomicAction.capture(
        session_id:      session_id,
        task_slug:       row[:task],
        mascot:          mc,
        kind:            row[:kind],
        event_slug:      row[:ev],
        result_slug:     row[:rs],
        outcome:         row[:outcome] || "ok",
        actor:           row[:actor],
        model:           row[:model],
        tokens_in:       tin,
        tokens_out:      tout,
        cost:            price.call(tin, tout, row[:model]),
        stage:           row[:stage],
        feedback_anchor: row[:anchor] || false,
        occurred_at:     base + (i * 30).seconds,
        duration_ms:     row[:model] ? rand(1500..9000) : nil
      )
      created += 1 if action
    end

    puts "atomic:demo_seed — captured #{created} action(s) for session #{session_id} (mascot #{mascot}, task #{task_slug})."
    warn "  WARNING: only #{created}/#{rows.size} captured — check ErrorLog." if created != rows.size
    puts "  View it at /alex/heartbeat"
  end
end
