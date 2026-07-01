namespace :atomic do
  # LOCAL DEMO DATA — not a historical backfill. AtomicAction capture is
  # forward-only and nothing emits rows yet, so /alex/heartbeat is empty until a
  # session runs. This seeds ONE representative greenfield trajectory (boot ->
  # recall -> intake -> design -> build -> submit) so the view has something to
  # render locally. Guarded out of production.
  #
  # The heartbeat is now event-primary: the agent narrates its trajectory as
  # AtomicEvent SPANS (category · reason -> outcome) and the raw tool-calls
  # attribute to whichever span is OPEN at capture time. So this seed OPENS a span,
  # captures the actions that belong to it, then CLOSES it with an outcome — leaving
  # the final span OPEN (no outcome) so the view renders a real "…in progress" row.
  # The first couple of boot actions are captured with NO span open, so they land in
  # the read-only "Unlabeled" group (context the agent never narrated).
  desc "LOCAL-ONLY: seed a representative narrated event trajectory so /alex/heartbeat has data."
  task demo_seed: :environment do
    raise "atomic:demo_seed is local demo data — refusing to run in production." if Rails.env.production?

    session_id = ENV.fetch("SESSION_ID", "demo-heartbeat-0001")
    # A Gen-1 slug so the mascot AVATAR resolves to a real sprite (the deck seeds only
    # the original 151; a Gen-4 slug like rotom renders only an initials fallback).
    mascot     = ENV.fetch("MASCOT", "snorlax")
    task_slug  = ENV.fetch("TASK_SLUG", "atomic-action-capture")
    opus       = "claude-opus-4-8"

    # Opus-priced cost from the token split (input $5 / output $25 per 1M); board
    # and harness steps carry no model and so no cost.
    price = ->(tin, tout, model) { model ? (((tin * 5.0) + (tout * 25.0)) / 1_000_000.0).round(4) : 0 }

    # Idempotent: clear any prior demo rows for THIS session before reseeding.
    # destroy_all (not delete_all) on the actions so dependent ActionGrade rows go
    # with them — a raw DELETE trips the action_grades foreign key once a trajectory
    # is graded. The spans have no such dependent, so a delete_all clears them.
    AtomicAction.where(session_id: session_id).destroy_all
    AtomicEvent.where(session_id: session_id).delete_all

    # The two pre-narration tool-calls (no span open yet) — they land Unlabeled.
    unlabeled = [
      { kind: "boot", actor: "harness", stage: nil, mascot: nil,           in: "spin up the session runtime",
        ev: "Spin up fresh session runtime",      rs: "Session identity and model resolved" },
      { kind: "boot", actor: "harness", stage: nil, mascot: nil, ti: 6400, in: "auto-load AGENTS.md + CLAUDE.md",
        ev: "Auto load the operating model docs", rs: "DevOps cycle gate now enforced" }
    ]

    # The narrated spans, in order. Each closes with `outcome:` except the LAST,
    # which is left open (outcome: nil) to render the "…in progress" placeholder.
    # A couple carry an acting soul (`agent:` — a senior who did that span) so the
    # heartbeat's stacked Agent column has a live example: the soul renders ON TOP
    # of the base session mascot. Most spans omit it (nil = the base mascot did it).
    spans = [
      { category: "Clarify", reason: "triage the operator request", outcome: "feature intent captured for triage", stage: nil,
        rows: [
          { kind: "recall",   actor: "harness", ti: 8200, in: "recall prior session memories", ev: "Recall relevant prior session memories", rs: "Known lessons surfaced for reuse" },
          { kind: "draw",     actor: "board",                       in: "draw session mascot",       ev: "Draw this session Pokemon mascot",        rs: "Session identity mascot now assigned" },
          { kind: "intake",   actor: "human",                       in: "operator: build the event-grouped heartbeat view", ev: "Receive operator feature request message", rs: "Feature intent captured for triage" },
          { kind: "classify", actor: "agent", model: opus, ti: 1200, to: 90, in: "classify request work kind", ev: "Classify the request work kind", rs: "Identified as a feature task" },
          { kind: "explore",  actor: "agent", model: opus, ti: 900,  to: 60, in: "route to target repo",       ev: "Identify the target application repo", rs: "Routed to mcritchie studio repo" }
        ] },
      { category: "Plan", reason: "shape the task and approach", outcome: "critical files and steps identified", stage: "designed",
        rows: [
          { kind: "create-task", actor: "board", task: task_slug, in: "bin/task create --kind feature --shape ui+db", ev: "Create the production board task", rs: "Task slug minted and bound" },
          { kind: "plan",        actor: "agent", task: task_slug, model: opus, ti: 5200, to: 900, anchor: true, in: "plan the AtomicEvent rollup + drill-down", ev: "Plan the implementation approach steps", rs: "Critical files and steps identified" },
          { kind: "dor-check",   actor: "board", task: task_slug, in: "bin/dor-check event-grouped-heartbeat-view", ev: "Run definition of ready build", rs: "Spec completeness gate passed clean" }
        ] },
      { category: "Explore", reason: "find the capture seam", outcome: "located the model and schema seam", stage: "building",
        rows: [
          { kind: "explore", actor: "agent", task: task_slug, model: opus, ti: 9400, to: 360, in: "grep -rn AtomicEvent app/models", ev: "Explore the model and schema seam", rs: "Found the capture seam quickly" }
        ] },
      { category: "Edit", reason: "implement the event view", outcome: "controller view and helper written", stage: "building",
        rows: [
          { kind: "test", actor: "agent", task: task_slug, model: opus, ti: 3100, to: 780, in: "test/views/heartbeat_event_table_test.rb", ev: "Write a failing regression test first", rs: "Red test reproduces the gap" },
          { kind: "edit", actor: "agent", task: task_slug, model: opus, ti: 6800, to: 2400, in: "app/views/heartbeat/_event_table.html.erb", ev: "Implement the event trajectory view", rs: "Controller view and helper written" }
        ] },
      { category: "Verify", reason: "run the unit suite", outcome: "green after a null-stage fix", stage: "building", agent: "carl",
        rows: [
          { kind: "run-test",      actor: "board", task: task_slug, outcome: "error", in: "bin/rails test test/views/heartbeat_event_table_test.rb", ev: "Run the unit test suite", rs: "One spec fails on null outcome" },
          { kind: "recover-error", actor: "agent", task: task_slug, model: opus, ti: 7200, to: 1900, anchor: true, in: "app/helpers/heartbeat_helper.rb heartbeat_event_outcome", ev: "Diagnose and fix the failing spec", rs: "In-progress fallback applied to outcome" },
          { kind: "commit",        actor: "agent", task: task_slug, model: opus, ti: 300, to: 80, in: "git commit -m 'Add event-grouped heartbeat'", ev: "Commit and push the feature branch", rs: "Branch pushed code now preserved" }
        ] },
      { category: "Workflow", reason: "certify and open the PR", outcome: nil, stage: "submitted", agent: "avi",
        rows: [
          { kind: "full-suite",     actor: "board", task: task_slug, in: "bin/full-suite-check event-grouped-heartbeat-view", ev: "Run full suite certification check", rs: "Full suite and rubocop green" },
          { kind: "open-pr",        actor: "agent", task: task_slug, model: opus, ti: 1800, to: 540, in: "gh pr create --base release", ev: "Open a pull request into release", rs: "PR opened task URL leading" },
          { kind: "move-submitted", actor: "board", task: task_slug, in: "bin/task move event-grouped-heartbeat-view submitted", ev: "Move the task to submitted stage", rs: "Build handed off at the seam" },
          { kind: "review-wait",    actor: "board", task: task_slug, outcome: "pending", in: "await senior QA verdict", ev: "Await senior QA review verdict", rs: "Submitted PR now in the queue" }
        ] }
    ]

    base = 40.minutes.ago
    i = -1                     # running global index -> each action's occurred_at
    at = ->(step) { base + (step * 30).seconds }
    created = 0
    total   = unlabeled.size + spans.sum { |s| s[:rows].size }

    capture_row = lambda do |row|
      i += 1
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
        input:           row[:in],
        outcome:         row[:outcome] || "ok",
        actor:           row[:actor],
        model:           row[:model],
        tokens_in:       tin,
        tokens_out:      tout,
        cost:            price.call(tin, tout, row[:model]),
        stage:           row[:stage],
        feedback_anchor: row[:anchor] || false,
        occurred_at:     at.call(i),
        duration_ms:     row[:model] ? rand(1500..9000) : nil
      )
      created += 1 if action
    end

    # Pre-narration boot actions: captured with NO span open -> Unlabeled group.
    unlabeled.each { |row| capture_row.call(row) }

    # Each span: open it (attributing the rows that follow), capture its rows, then
    # close it with its outcome. The final span is left OPEN (outcome nil).
    spans.each do |span|
      opened_at = at.call(i + 1)
      AtomicEvent.open_event!(
        session_id:  session_id,
        category:    span[:category],
        reason_slug: span[:reason],
        task_slug:   span[:rows].first[:task],
        mascot:      mascot,
        stage:       span[:stage],
        agent:       span[:agent],
        opened_at:   opened_at
      )
      span[:rows].each { |row| capture_row.call(row) }
      next if span[:outcome].nil?          # leave the final span open -> "…in progress"

      AtomicEvent.close_event!(session_id: session_id, outcome_slug: span[:outcome], closed_at: at.call(i) + 5.seconds)
    end

    events = AtomicEvent.where(session_id: session_id)
    puts "atomic:demo_seed — captured #{created}/#{total} action(s) and #{events.count} span(s) " \
         "(#{events.open.count} open) for session #{session_id} (mascot #{mascot}, task #{task_slug})."
    warn "  WARNING: only #{created}/#{total} captured — check ErrorLog." if created != total
    puts "  View it at /alex/heartbeat"
  end
end
