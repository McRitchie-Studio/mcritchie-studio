# A client app's CTO as DATA (.agents/epics/build-with-xan-design.md, "Client CTOs
# are data, not files"): one row per client app, filled from the /build intake
# when Build my app launches it (AppLaunch). The one `client_cto` soul answers
# every client app; this row picks its voice. Our own CTOs (Avi, Turf, Tyrion)
# stay souls on disk with no row here.
#
# apps.theme_colors is the chosen palette recorded as the APP's theme, the one
# place the launch/template step (bin/launch-app, new-app-onboarding § theme)
# reads it from, so the first QA build already wears the client's colours.
class CreateAppCtos < ActiveRecord::Migration[8.1]
  def change
    create_table :app_ctos do |t|
      t.string :app_slug, null: false
      t.string :name, null: false
      # The intake's cto_avatar: a default portrait key, or "upload:<ref>".
      t.string :portrait
      # { "light" => { primary, accent, surface, text }, "dark" => { … } }, hex.
      t.jsonb :palette, null: false, default: {}
      # The plan the CTO restates: the sharpened idea and day-one goal.
      t.text :plan
      # The app's facts the persona template reads: prompt, audience, answers.
      t.jsonb :facts, null: false, default: {}
      t.string :app_request_token
      t.timestamps
    end
    add_index :app_ctos, :app_slug, unique: true
    add_foreign_key :app_ctos, :apps, column: :app_slug, primary_key: :slug, on_update: :cascade, on_delete: :cascade

    add_column :apps, :theme_colors, :jsonb
  end
end
