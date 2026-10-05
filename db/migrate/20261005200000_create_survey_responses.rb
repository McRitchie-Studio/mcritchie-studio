# Answers to a feedback survey (task first-game-feedback-survey). The survey
# itself is code-defined (Survey), so a response names it by slug. A response
# that arrived through an email's link carries that delivery and its contact;
# one with neither is anonymous. One response per delivery per survey: a reader
# who comes back edits theirs.
class CreateSurveyResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :survey_responses do |t|
      t.string :survey_slug, null: false
      t.references :contact, foreign_key: { on_delete: :nullify }
      t.references :broadcast_delivery, foreign_key: { on_delete: :nullify }
      t.jsonb :answers, null: false, default: {}
      t.timestamps
    end
    add_index :survey_responses, %i[survey_slug created_at]
    add_index :survey_responses, %i[survey_slug broadcast_delivery_id], unique: true,
              where: "broadcast_delivery_id IS NOT NULL", name: "index_survey_responses_one_per_delivery"
  end
end
