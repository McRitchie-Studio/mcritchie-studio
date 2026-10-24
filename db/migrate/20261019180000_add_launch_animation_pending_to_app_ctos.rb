# The app's initial load (task build-sign-in-modal, Alex 2026-10-19): a newly
# launched app plays the long launch animation (build/_launch: Building Brand
# Sheet, Hatching CTO, Setting Up Domain) on its owner's FIRST visit to the
# CTO's chat, however they arrived (the signed-in press, the magic link, Google).
# AppLaunch sets it; CtoChatsController#show clears it, atomically, when it
# renders the animation for the owner. Existing apps have been visited already,
# so the default is false.
class AddLaunchAnimationPendingToAppCtos < ActiveRecord::Migration[8.1]
  def change
    add_column :app_ctos, :launch_animation_pending, :boolean, null: false, default: false
  end
end
