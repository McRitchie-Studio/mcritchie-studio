class CreateModelRateOverrides < ActiveRecord::Migration[8.1]
  # Operator-tuned, PERSISTED per-model token rates. UsagePricing.rate_for merges
  # these OVER the static RATES roster (and the env override), so a saved row
  # re-prices FUTURE usage for that model. One row per canonical model id.
  def change
    create_table :model_rate_overrides do |t|
      t.string  :model, null: false                                   # canonical id, e.g. "claude-opus-4-8"
      t.decimal :input_rate,  precision: 12, scale: 4, null: false    # USD per 1M input tokens
      t.decimal :output_rate, precision: 12, scale: 4, null: false    # USD per 1M output tokens
      t.decimal :cache_read_rate,     precision: 12, scale: 4         # optional ABSOLUTE per-MTok override
      t.decimal :cache_creation_rate, precision: 12, scale: 4         # optional ABSOLUTE per-MTok override
      t.timestamps
    end
    add_index :model_rate_overrides, :model, unique: true
  end
end
