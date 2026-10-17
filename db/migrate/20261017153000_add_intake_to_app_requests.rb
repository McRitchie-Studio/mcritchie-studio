# Build with Xan (/build as a chat; .agents/epics/build-with-xan-design.md): the
# intake fields a visitor's taps write on their request, and the validated card
# an answer from Xan carries. Read by client-cto-from-intake (AppCto), so the
# names are fixed:
#
#   app_requests.cto_name     the CTO's name, as tapped (BuildIntake::Card::NAME)
#   app_requests.cto_avatar   a portrait key (BuildIntake::Portraits) or an upload ref
#   app_requests.palette      { "name", "light" => {primary, accent, surface, text},
#                               "dark" => {...} }, hex colours, contrast-checked
#   app_requests.answers      the sharpened idea: { "idea", "audience", "day_one" }
#   agent_messages.intake_card  the card Xan's answer offered, after code checked it
class AddIntakeToAppRequests < ActiveRecord::Migration[8.1]
  def change
    change_table :app_requests, bulk: true do |t|
      t.string :cto_name
      t.string :cto_avatar
      t.jsonb :palette, null: false, default: {}
      t.jsonb :answers, null: false, default: {}
    end
    add_column :agent_messages, :intake_card, :jsonb
  end
end
