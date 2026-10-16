# Alex's dream rulings given in chat (docs/agents/modules/dream.md, Act 3, "In chat").
#
# A ruling recorded through POST /api/v1/dream_rulings carries his verbatim words
# and the session that heard them, the way `bin/release ship --mode cleared
# --clearance` carries a production clearance:
#
#   via         "click" (his own /dreams click, every row before this) or "chat"
#   clearance   his exact words, quoted; blank on a click
#   session_id  the session that recorded the chat ruling; blank on a click
#
# dream_retirements also gains `ruling`: "retire" takes an approved dream out of
# its layer; "drop" discards a proposed one. Both end the same way:
# `bin/dream apply-approvals` deletes the file.
class AddChatClearanceToDreamRulings < ActiveRecord::Migration[8.1]
  def change
    change_table :dream_approvals, bulk: true do |t|
      t.string :via, null: false, default: "click"
      t.text :clearance
      t.string :session_id
    end

    change_table :dream_retirements, bulk: true do |t|
      t.string :via, null: false, default: "click"
      t.text :clearance
      t.string :session_id
      t.string :ruling, null: false, default: "retire"
    end

    add_check_constraint :dream_approvals, "via IN ('click', 'chat')", name: "dream_approvals_via"
    add_check_constraint :dream_retirements, "via IN ('click', 'chat')", name: "dream_retirements_via"
    add_check_constraint :dream_retirements, "ruling IN ('retire', 'drop')", name: "dream_retirements_ruling"
  end
end
