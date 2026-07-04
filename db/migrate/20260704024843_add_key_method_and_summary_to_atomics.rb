class AddKeyMethodAndSummaryToAtomics < ActiveRecord::Migration[8.1]
  def change
    # The load-bearing call of a unit of work (agent-provided on spans, hook-derived
    # on bash actions), plus the language its UI badge shows. All optional — most
    # spans/actions have no single key method.
    add_column :atomic_events, :key_method, :text
    add_column :atomic_events, :key_method_lang, :string

    add_column :atomic_actions, :key_method, :text
    add_column :atomic_actions, :key_method_lang, :string
    # A goal slug for the action ("list board tasks…"), outcome-free — spans
    # already carry reason_slug as their goal, so summary lives on actions only.
    add_column :atomic_actions, :summary, :string
  end
end
