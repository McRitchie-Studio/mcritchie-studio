# Record WHICH SOUL performed a narrated span, distinct from the base session
# mascot — so the heartbeat can show the ACTING agent (Avi/Carl/…) STACKED over a
# stable base mascot. NULL means "the base session mascot did it" (no soul
# override). An unknown slug is coerced to NULL by AtomicEvent#normalize_agent
# (non-fatal — a typo never fails a narration), so only a real McRitchie soul
# (AtomicEvent::SOULS) is ever stored. Actions inherit their span's agent; the
# heartbeat reads the per-SPAN agent, so no column lands on atomic_actions.
class AddAgentToAtomicEvents < ActiveRecord::Migration[8.1]
  def change
    add_column :atomic_events, :agent, :string
  end
end
