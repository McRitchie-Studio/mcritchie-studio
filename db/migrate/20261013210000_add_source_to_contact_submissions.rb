# Where a /contact submission came from: the page, the item and the intent a
# card link carried (e.g. {page: "integrations", item: "github", intent:
# "connect", ref: "/integrations"}). Additive, defaulted, so every existing row
# reads as {} (no source).
class AddSourceToContactSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :contact_submissions, :source, :jsonb, default: {}, null: false
  end
end
