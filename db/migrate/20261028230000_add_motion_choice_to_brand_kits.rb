# frozen_string_literal: true

# THE KIT'S MOTION CHOICE (task logo-motion-presets; epic logo-motion, phase 1): which motion preset the brand's logo
# plays and on which logo it plays it, {"preset" => "pop_slide", "logo" => "stacked"} (Logos::MotionPreset). Null is
# no motion saved. Nullable jsonb beside icon_choice, navbar_choice and stacked_choice; no backfill, no default.
class AddMotionChoiceToBrandKits < ActiveRecord::Migration[8.1]
  def change
    add_column :brand_kits, :motion_choice, :jsonb
  end
end
