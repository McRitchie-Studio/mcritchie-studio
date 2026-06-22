# Copy of the engine reference migration: lets ImageCache hold app-global images
# (no owner) so Studio::EmailImage can store the managed email banners owner-less.
class AllowNullImageCacheOwner < ActiveRecord::Migration[7.2]
  def change
    change_column_null :image_caches, :owner_type, true
    change_column_null :image_caches, :owner_id, true
  end
end
