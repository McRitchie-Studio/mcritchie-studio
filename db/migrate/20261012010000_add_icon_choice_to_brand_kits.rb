# frozen_string_literal: true

# THE KIT'S ICON (epic brand-studio, piece 7b; task kit-icon-atomic-unit): the icon is an atomic unit the brand's
# Navbar and Stacked Logos all draw, so the kit saves ONE icon choice of its own, in the same flat URL form as the
# other choices: {"colouring" => "original", "edits" => {"icon_colour" => "2D5E8E"}}. Nullable, nothing backfilled:
# a kit without one draws every logo as before. Adding a nullable column takes no rewrite and no long lock.
class AddIconChoiceToBrandKits < ActiveRecord::Migration[8.1]
  def change
    add_column :brand_kits, :icon_choice, :jsonb
  end
end
