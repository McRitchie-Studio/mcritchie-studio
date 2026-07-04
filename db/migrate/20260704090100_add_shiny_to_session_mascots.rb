# Whether this session's mascot came up SHINY — rolled once at draw time
# (Pokemon.roll_shiny?: 1-in-100 on prod, 1-in-10 on dev/QA) and adopted by the
# session's board tasks as devops.mascot_shiny.
class AddShinyToSessionMascots < ActiveRecord::Migration[8.1]
  def change
    add_column :session_mascots, :shiny, :boolean, default: false, null: false
  end
end
