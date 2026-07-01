class CreateAtomicEvents < ActiveRecord::Migration[8.1]
  # Agent-narrated trajectory EVENTS — the meaningful spans the agent self-declares
  # as it works. Where an AtomicAction is one raw tool call, an AtomicEvent is a
  # SPAN the agent opens ("Explore · find issue with api") and later closes with an
  # outcome ("located the nil-guard bug"). Raw tool-calls attribute server-side to
  # the session's current OPEN event (atomic_actions.atomic_event_id), so a simple
  # task collapses from ~100 noisy rows to a handful of narrated spans.
  #
  # One event is OPEN per session at a time: opening a new one auto-closes the
  # prior open span. closed_at IS NULL means "currently open". category is
  # agent-declared from a fixed vocabulary (see AtomicEvent::CATEGORIES).
  #
  # task_slug / mascot / stage mirror AtomicAction so a view can group a session's
  # spans under the task they belong to without joining through the actions.
  def change
    create_table :atomic_events do |t|
      t.string   :session_id, null: false                 # the session whose trajectory this span belongs to
      t.integer  :seq, null: false, default: 0            # position in the session's span sequence (0-based)
      t.string   :category, null: false                   # agent-declared: Explore | Edit | Verify | … (CATEGORIES)
      t.string   :reason_slug, null: false                # "what am I doing" — e.g. "find issue with api"
      t.string   :outcome_slug                            # "what happened" — set on close; null while open
      t.string   :task_slug                               # slug FK to tasks; null for pre-task spans (boot/intake)
      t.string   :mascot                                  # session/task Pokémon slug; null when not yet drawn
      t.string   :stage                                   # coarse task stage when the span opened; null pre-task
      t.datetime :opened_at, null: false                  # when the agent opened the span
      t.datetime :closed_at                               # when the span closed; null = CURRENTLY OPEN
      t.timestamps
    end

    # The attribution hot path is for_session(sid).open.order(:seq).last, so index
    # the session lanes both by sequence and by open/closed.
    add_index :atomic_events, [:session_id, :seq]
    add_index :atomic_events, [:session_id, :closed_at]
    add_index :atomic_events, [:task_slug, :seq]
    add_index :atomic_events, :opened_at
  end
end
