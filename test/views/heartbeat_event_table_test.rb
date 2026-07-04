require "test_helper"

# [component] the event-grouped heartbeat table partial — the PRIMARY rows are
# agent-narrated AtomicEvent spans (category · reason -> outcome), each rolling up
# the raw AtomicActions attributed to it as a read-only drill-down. Actions with a
# null atomic_event_id render in the trailing "Unlabeled" group. Read-only: the
# table has no inline grading controls (grading lives in the drawer).
class HeartbeatEventTableTest < ActionView::TestCase
  def event(**attrs)
    AtomicEvent.create!({ session_id: "s", category: "Explore", reason_slug: "find issue with api",
                          opened_at: Time.current, seq: attrs.fetch(:seq, 0) }.merge(attrs))
  end

  def action(**attrs)
    AtomicAction.create!({ session_id: "s", kind: "grep", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current }.merge(attrs))
  end

  test "[component] renders each span as a row with category, reason, and outcome" do
    closed = event(category: "Explore", reason_slug: "find issue with api",
                   outcome_slug: "found the nil-guard", closed_at: Time.current, seq: 0)
    a1 = action(atomic_event_id: closed.id, seq: 0, kind: "grep",
                event_slug: "Grep for the capture seam", input: "grep -rn AtomicAction app/models")
    a2 = action(atomic_event_id: closed.id, seq: 1, kind: "read", event_slug: "Read the model")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[closed, [a1, a2]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "table[data-test=heartbeat-event-table]"
    assert_select "tbody[data-test=heartbeat-event][data-category=Explore]"
    assert_select "tbody[data-test=heartbeat-event] tr[data-test=heartbeat-event-row]", 1
    assert_select ".hb-catchip", text: "Explore"
    assert_includes rendered, "find issue with api"
    assert_includes rendered, "found the nil-guard"
    # the count of attributed actions
    assert_select "[data-test=event-action-count]", text: "2 actions"
  end

  test "[component] an open span (no outcome) renders the in-progress placeholder" do
    open = event(category: "Workflow", reason_slug: "certify and open the PR",
                 outcome_slug: nil, closed_at: nil, seq: 0)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[open, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-in-progress]"
    assert_match(/in progress/, rendered)
    assert_no_match(/found the nil-guard/, rendered)
  end

  test "[component] a span drills down into its attributed actions with kind and input" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0, kind: "grep",
                event_slug: "Grep the seam", input: "grep -rn AtomicEvent app/models")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "tr[data-test=heartbeat-event-action]", 1
    assert_select "tr[data-test=heartbeat-event-action] .hb-kind", text: "grep"
    assert_includes rendered, "Grep the seam"
    # the raw tool-call input surfaces in the drill-down
    assert_includes rendered, "grep -rn AtomicEvent app/models"
  end

  test "[component] actions drill down oldest to newest within a span" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    first  = action(atomic_event_id: ev.id, seq: 0, event_slug: "alpha first read")
    second = action(atomic_event_id: ev.id, seq: 1, event_slug: "omega later read")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [first, second]]], unlabeled: [], pokemon_by_slug: {} }

    assert_operator rendered.index("alpha first read"), :<, rendered.index("omega later read")
  end

  test "[component] actions with a null span land in the read-only Unlabeled group" do
    orphan = action(atomic_event_id: nil, seq: 0, kind: "bash",
                    event_slug: "Unnarrated boot step", input: "spin up the runtime")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [orphan], pokemon_by_slug: {} }

    assert_select "tbody[data-test=heartbeat-unlabeled]"
    assert_select "tbody[data-test=heartbeat-unlabeled] .hb-catchip", text: "Unlabeled"
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-test=heartbeat-event-action]", 1
    assert_includes rendered, "Unnarrated boot step"
  end

  test "[component] every unlabeled action collapses into a SINGLE consolidated group" do
    a = action(atomic_event_id: nil, seq: 0, kind: "boot", event_slug: "first orphan", session_id: "s1")
    b = action(atomic_event_id: nil, seq: 1, kind: "boot", event_slug: "second orphan", session_id: "s2")
    c = action(atomic_event_id: nil, seq: 2, kind: "boot", event_slug: "third orphan", session_id: "s1")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [a, b, c], pokemon_by_slug: {} }

    # exactly ONE Unlabeled group, holding every orphan action — never several
    assert_select "tbody[data-test=heartbeat-unlabeled]", 1
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-test=heartbeat-event-action]", 3
  end

  test "[component] drilled-down action rows carry no inline radios — they open the drawer" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    # the span row now carries quick-grade radios, but the ACTION drill-down row does not
    assert_select "tr[data-test=heartbeat-event-action] input[type=radio]", false
    # a drilled-down action still links to its grading drawer
    assert_includes rendered, heartbeat_feedback_path(a1)
  end

  test "[component] the span row rolls up its actions into Pokémon, model, tokens, and cost" do
    ev = event(seq: 0, mascot: "snorlax", closed_at: Time.current, outcome_slug: "done")
    a1 = action(atomic_event_id: ev.id, seq: 0, model: "claude-opus-4-8", tokens_in: 9400, tokens_out: 360, cost: 0.05)
    a2 = action(atomic_event_id: ev.id, seq: 1, model: "claude-opus-4-8", tokens_in: 6800, tokens_out: 2400, cost: 0.09)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1, a2]]], unlabeled: [], pokemon_by_slug: {} }

    # aggregated across the span's actions, not per-action; model + tokens now stack
    # inside one merged cell (each keeping its data-test hook)
    assert_select "[data-test=event-tokens]", text: "16.2k/2.8k"
    assert_select "[data-test=event-cost]", text: "$0.1400"
    assert_select "[data-test=event-model]", text: "opus-4-8"
    assert_select "td.hb-modeltok [data-test=event-model]"
    assert_select "td.hb-modeltok [data-test=event-tokens]"
    # the span mascot resolves to a name on its avatar title (slug titleized here — no
    # seeded Pokémon passed)
    assert_select "[data-test=event-mascot][title=?]", "Snorlax"
  end

  test "[component] narration stacks the reason on line one and the result beneath" do
    ev = event(seq: 0, reason_slug: "find issue with api",
               outcome_slug: "found the nil-guard", closed_at: Time.current)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    # reason/status share the compact header; result stays beneath it.
    assert_select "td.hb-narr .hb-narrline.hb-narr-head .hb-slug", text: "find issue with api"
    assert_select "td.hb-narr .hb-narrline.hb-narr-result", text: /found the nil-guard/
  end

  test "[component] each span row carries inline good/not quick-grade radios for both graders" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    # a quick-grade form per grader, both posting to the E2 span grade endpoint
    assert_select "form[data-test=event-inline-grade]", 2
    assert_select "form[data-test=event-inline-grade][action=?]", heartbeat_event_grade_path(ev), 2
    assert_select "form[data-test=event-inline-grade][data-grader=alex] input[name=disposition][value=good]"
    assert_select "form[data-test=event-inline-grade][data-grader=alex] input[name=disposition][value=not]"
    assert_select "form[data-test=event-inline-grade][data-grader=mcr] input[type=hidden][name=grader][value=mcr]"
  end

  test "[component] the two graders' quick-grades sit in SEPARATE Alex + McRitchie cells, no grade button" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    # Grade split into two columns: an Alex cell and a McRitchie audit cell, each holding
    # ONLY its own grader's inline quick-grade form (not one shared, side-by-side row).
    assert_select "td[data-test=event-grade-cell] form[data-test=event-inline-grade][data-grader=alex]", 1
    assert_select "td[data-test=event-grade-cell] form[data-grader=mcr]", false
    assert_select "td[data-test=event-grade-cell-mcr] form[data-test=event-inline-grade][data-grader=mcr]", 1
    assert_select "td[data-test=event-grade-cell-mcr] form[data-grader=alex]", false
    # the old shared inline-grades container and the "grade ▸" drawer button are gone
    assert_select "[data-test=event-inline-grades]", false
    assert_select "[data-test=event-grade-open]", false
    assert_select ".hb-gradebtn", false
  end

  test "[component] an existing span grade pre-checks its inline disposition radio" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(atomic_event: ev, grader: "alex", disposition: "good",
                                slug: "clean span with a crisp outcome")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {},
                     event_grades: { ev.id => { "alex" => grade } } }

    assert_select "form[data-test=event-inline-grade][data-grader=alex] input[value=good][checked]"
    assert_select "form[data-test=event-inline-grade][data-grader=alex] input[value=not][checked]", false
    assert_select "form[data-test=event-inline-grade][data-grader=alex] [data-test=event-clear-grade-alex]"
  end

  test "[component] the span row shows a distinct open vs done status badge" do
    open_span = event(seq: 0, reason_slug: "certify and open the PR", closed_at: nil, outcome_slug: nil)
    done_span = event(seq: 1, reason_slug: "run the unit suite", closed_at: Time.current, outcome_slug: "green")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[open_span, []], [done_span, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-status]", text: "open"
    assert_select "[data-test=event-status]", text: "done"
  end

  test "[component] the narration header carries status and action count" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "green")
    a1 = action(atomic_event_id: ev.id, seq: 0)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "td.hb-narr .hb-narr-head .hb-narr-status .hb-bullet"
    assert_select "td.hb-narr .hb-narr-head [data-test=event-status]", text: "done"
    assert_select "[data-test=event-action-count]", text: "1 action"
  end

  test "[component] compact rows hide status column, task slugs, and action placeholders" do
    ev = event(seq: 0, task_slug: "hidden-span-task", closed_at: Time.current, outcome_slug: "green")
    a1 = action(atomic_event_id: ev.id, seq: 0, task_slug: "hidden-action-task", outcome: "ok")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "th", text: "Status", count: 0
    assert_select "th", text: "Status / Task", count: 0
    assert_no_match(/hidden-span-task/, rendered)
    assert_no_match(/hidden-action-task/, rendered)
    assert_select "tr[data-test=heartbeat-event-action] .hb-outcome", false
    assert_no_match(/open action drawer/, rendered)
    assert_select "tr[data-test=heartbeat-event-action] td.hb-actionblank[colspan='2']", 1
  end

  test "[component] a stage-change span badges as its target stage using the board pill" do
    slug = "stage-change-status-badge"
    ev   = event(seq: 0, task_slug: slug, opened_at: 3.minutes.ago,
                 closed_at: 1.minute.ago, outcome_slug: "moved to submitted")
    te   = TaskEvent.new(task_slug: slug, from_stage: "building", to_stage: "submitted",
                         kind: "transition", occurred_at: 2.minutes.ago)

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {},
                     stage_transitions: { slug => [te] } }

    # the board badge pill, humanized + stage-colored, with a stable data hook
    assert_select "[data-test=event-status][data-stage=submitted] .badge", text: "Submitted"
    # it replaces the generic done chip
    assert_select "[data-test=event-status]", text: "done", count: 0
  end

  test "[component] a span with no in-window transition keeps the plain done badge" do
    slug = "no-window-match"
    ev   = event(seq: 0, task_slug: slug, opened_at: 2.minutes.ago,
                 closed_at: 1.minute.ago, outcome_slug: "done")
    te   = TaskEvent.new(task_slug: slug, to_stage: "submitted", kind: "transition",
                         occurred_at: 5.minutes.ago) # before the span opened

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {},
                     stage_transitions: { slug => [te] } }

    assert_select "[data-test=event-status]", text: "done"
    assert_select "[data-test=event-status][data-stage]", false
  end

  test "[component] left row cells expand actions and grade cells open the sidebar" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    # the row still carries the click styling, but its left-side cells expand actions
    # while the grade columns own the drawer target.
    assert_select "tr.hb-evtrow.hb-clickrow[data-test=heartbeat-event-row]", 1
    assert_select "tr.hb-evtrow td.hb-openzone", minimum: 6
    assert_includes rendered, '@click="open = !open"'
    assert_match(/data-test="event-grade-cell"\s+@click\.stop="openDrawer/, rendered)
    assert_match(/data-test="event-grade-cell-mcr"\s+@click\.stop="openDrawer/, rendered)
    assert_includes rendered, heartbeat_event_feedback_path(ev)
    assert_no_match(/tr class="hb-evtrow hb-clickrow"[^>]*openDrawer/, rendered)
    # the old dedicated "grade ▸" button is still gone
    assert_select "[data-test=event-grade-open]", false
  end

  test "[component] a shared turn fades the tokens AND cost cells of every action after the first" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    first  = action(atomic_event_id: ev.id, seq: 0, source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    second = action(atomic_event_id: ev.id, seq: 1, source_turn_uuid: "turn-A",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    # the controller's session-level walk marks the 2nd action of the shared turn
    shared = Set.new([second.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [first, second]]], unlabeled: [], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    # the turn's first action keeps its normal color — no faded cell
    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    # the 2nd action fades BOTH its tokens and its cost cell, each with the inherit tooltip
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
    assert_select "tr[data-seq='1'] td.hb-turn-shared[title=?]",
                  "shared with this turn's first action", 2
    # only the color changes — the token value itself (now in the merged model/tokens
    # cell) is untouched
    assert_select "tr[data-seq='1'] td.hb-turn-shared .hb-mt-tokens", text: "9.4k/360"
  end

  test "[component] a solo-turn action and a blank-turn action are never faded" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    solo  = action(atomic_event_id: ev.id, seq: 0, source_turn_uuid: "turn-solo",
                   tokens_in: 100, tokens_out: 10, cost: 0.01)
    blank = action(atomic_event_id: ev.id, seq: 1, source_turn_uuid: nil,
                   tokens_in: 200, tokens_out: 20, cost: 0.02)
    # neither is a duplicate, so the controller flags nothing
    shared = Set.new

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [solo, blank]]], unlabeled: [], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    assert_select "td.hb-turn-shared", false
  end

  test "[component] exactly one primary per turn even when the turn's calls split across spans" do
    span1 = event(seq: 0, reason_slug: "first span", closed_at: Time.current, outcome_slug: "done")
    span2 = event(seq: 1, reason_slug: "second span", closed_at: Time.current, outcome_slug: "done")
    primary = action(atomic_event_id: span1.id, seq: 0, source_turn_uuid: "turn-split",
                     tokens_in: 9400, tokens_out: 360, cost: 0.05)
    echo    = action(atomic_event_id: span2.id, seq: 1, source_turn_uuid: "turn-split",
                     tokens_in: 9400, tokens_out: 360, cost: 0.05)
    # the controller walks the WHOLE session chronologically, so the echo (in span2)
    # is the sole duplicate even though it lives under a different span than the primary
    shared = Set.new([echo.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[span1, [primary]], [span2, [echo]]], unlabeled: [],
                     pokemon_by_slug: {}, shared_turn_ids: shared }

    # the primary (in span1) stays full color; only the echo (in span2) fades its two cells
    assert_select "tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tr[data-seq='1'] td.hb-turn-shared", 2
    assert_select "tr[data-test=heartbeat-event-action] td.hb-turn-shared", 2
  end

  test "[component] a shared turn in the Unlabeled group fades its later rows too" do
    first  = action(atomic_event_id: nil, seq: 0, source_turn_uuid: "turn-U",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    second = action(atomic_event_id: nil, seq: 1, source_turn_uuid: "turn-U",
                    tokens_in: 9400, tokens_out: 360, cost: 0.05)
    shared = Set.new([second.id])

    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [first, second], pokemon_by_slug: {},
                     shared_turn_ids: shared }

    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-seq='0'] td.hb-turn-shared", false
    assert_select "tbody[data-test=heartbeat-unlabeled] tr[data-seq='1'] td.hb-turn-shared", 2
  end

  test "[component] the mascot column header now reads Agent" do
    render partial: "heartbeat/event_table",
           locals: { event_rows: [], unlabeled: [], pokemon_by_slug: {} }

    assert_select "thead th", text: "Agent"
    assert_select "thead th", text: "Pokémon", count: 0
  end

  test "[component] a span with an acting soul stacks the soul avatar+name over the base mascot avatar+name" do
    avi  = Agent.new(slug: "avi", name: "Avi", metadata: { "emoji" => "📋", "color" => "#FB7185" })
    ev   = event(seq: 0, mascot: "shellder", agent: "avi", closed_at: Time.current, outcome_slug: "reviewed")
    poke = Pokemon.new(slug: "shellder", name: "Shellder")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: { "shellder" => poke },
                     agents_by_slug: { "avi" => avi } }

    # the acting soul avatar renders server-side (Nokogiri-visible) ON TOP, tinted
    assert_select "[data-test=agent-stack]"
    assert_select "[data-test=agent-soul][data-soul=avi] .rounded-full"
    # the base session mascot avatar renders BENEATH, inside the same stack
    assert_select "[data-test=agent-stack] [data-test=event-mascot] .rounded-full"
    # the names live in the side column: the soul is the primary, the base mascot the sub
    assert_select "[data-test=agent-stack] .hb-names .hb-nameprimary", text: "Avi"
    assert_select "[data-test=agent-stack] .hb-names .hb-namesub", text: "Shellder"
  end

  test "[component] a span with no acting soul renders the base mascot as a SOLO stack (no soul)" do
    ev = event(seq: 0, mascot: "sandshrew", agent: nil, closed_at: Time.current, outcome_slug: "done")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {} }

    # still an agent-stack, but flagged solo with no acting-soul avatar and no sub name
    assert_select "[data-test=agent-stack].hb-solo"
    assert_select "[data-test=agent-soul]", false
    assert_select "[data-test=agent-stack].hb-solo [data-test=event-mascot].hb-mascotava .rounded-full"
    assert_select "[data-test=agent-stack].hb-solo .hb-names .hb-nameprimary", text: "Sandshrew"
    assert_select "[data-test=agent-stack] .hb-namesub", false
  end

  test "[component] drill-down actions inherit their span's acting soul" do
    avi = Agent.new(slug: "avi", name: "Avi", metadata: { "emoji" => "📋" })
    ev  = event(seq: 0, mascot: "shellder", agent: "avi", closed_at: Time.current, outcome_slug: "reviewed")
    a1  = action(atomic_event_id: ev.id, seq: 0, mascot: "shellder", kind: "read")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, [a1]]], unlabeled: [], pokemon_by_slug: {},
                     agents_by_slug: { "avi" => avi } }

    assert_select "tr[data-test=heartbeat-event-action] [data-test=agent-soul][data-soul=avi]"
  end

  test "[component] a span's existing grade markers render server-side from event_grades" do
    ev = event(seq: 0, closed_at: Time.current, outcome_slug: "done")
    grade = ActionGrade.create!(atomic_event: ev, grader: "alex", disposition: "good",
                                slug: "tight span with a clean outcome")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[ev, []]], unlabeled: [], pokemon_by_slug: {},
                     event_grades: { ev.id => { "alex" => grade } } }

    # the Alex marker is server-rendered (Nokogiri-visible), carrying its slug
    assert_select "[data-test=event-grade-alex]"
    assert_select "td[data-test=event-grade-cell] .hb-evtfeedback-stack " \
                  "form[data-test=event-inline-grade] + [data-test=event-grade-alex]"
    assert_includes rendered, "tight span with a clean outcome"
    # and the tbody carries the hydration data the Alpine row reads
    assert_select "tbody[data-test=heartbeat-event][data-alex-graded=true]"
  end

  test "[component] a span's key method renders as a copyable chip with a lang badge" do
    closed = event(outcome_slug: "seam found", closed_at: Time.current,
                   key_method: "AtomicAction.capture(session_id:)", key_method_lang: "ruby")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[closed, []]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "[data-test=event-key-method] [data-test=key-method-chip][data-lang=ruby]", count: 1
    assert_select "[data-test=key-method-chip] [data-test=key-method-lang]", text: "ruby"
    assert_select "[data-test=key-method-chip] [data-test=key-method-code]", text: "AtomicAction.capture(session_id:)"
    # The copy button carries the full call as its clip payload (Alpine renders the glyph).
    assert_select "[data-test=key-method-copy][data-clip=?]", "AtomicAction.capture(session_id:)"
    assert_includes rendered, "window.copyText", "the shared copy helper ships with the chip"
  end

  test "[component] an action row renders its key-method chip and its goal summary" do
    closed = event(outcome_slug: "done", closed_at: Time.current)
    with = action(atomic_event_id: closed.id, seq: 0, kind: "bash",
                  summary: "list board tasks to find slugs",
                  key_method: "bin/task list | head -60", key_method_lang: "bash")
    bare = action(atomic_event_id: closed.id, seq: 1, kind: "read")

    render partial: "heartbeat/event_table",
           locals: { event_rows: [[closed, [with, bare]]], unlabeled: [], pokemon_by_slug: {} }

    assert_select "tr[data-test=heartbeat-event-action] td.hb-subnarr [data-test=action-key-method] " \
                  "[data-test=key-method-chip][data-lang=bash]", count: 1
    assert_select "tr[data-test=heartbeat-event-action] td.hb-subnarr [data-test=action-summary]",
                  text: "list board tasks to find slugs", count: 1
    # The right side no longer carries a visible drawer hint; command + summary stay
    # in the action narration cell.
    assert_select "tr[data-test=heartbeat-event-action] td.hb-gradehint", false
    assert_no_match(/open action drawer/, rendered)
  end
end
