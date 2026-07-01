class AddAtomicEventToAtomicActions < ActiveRecord::Migration[8.1]
  # Attribution FK: each raw tool-call action rolls up under the session's current
  # OPEN AtomicEvent (the span the agent declared it was working in). Nullable —
  # an action captured with no open span (or before any span was opened) simply
  # carries a null atomic_event_id.
  #
  # ON DELETE SET NULL (on_delete: :nullify) mirrors the model's dependent:
  # :nullify at the DB layer: removing a span — even via a bulk delete_all that
  # skips callbacks — orphans its actions rather than destroying them, so the
  # narrated history always survives a teardown.
  def change
    add_reference :atomic_actions, :atomic_event, null: true, index: true
    add_foreign_key :atomic_actions, :atomic_events, on_delete: :nullify
  end
end
