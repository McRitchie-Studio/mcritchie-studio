# A persisted, operator-tuned rate for one model, layered OVER the static
# UsagePricing::RATES roster. Saving a row here re-prices FUTURE usage for that
# model (historical costs, already stamped on their rows, are untouched). One row
# per canonical model id. Read back by UsagePricing.db_rates via .rates_hash.
class ModelRateOverride < ApplicationRecord
  validates :model, presence: true, uniqueness: true
  validates :input_rate, :output_rate,
            presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :cache_read_rate, :cache_creation_rate,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true

  # { "claude-opus-4-8" => { input: 4.5, output: 22.5 }, ... } in the shape
  # UsagePricing.rates merges. Optional absolute cache rates are included only
  # when set, mirroring the RATES / env override contract.
  def self.rates_hash
    all.each_with_object({}) do |override, acc|
      entry = { input: override.input_rate.to_f, output: override.output_rate.to_f }
      entry[:cache_read]     = override.cache_read_rate.to_f     if override.cache_read_rate
      entry[:cache_creation] = override.cache_creation_rate.to_f if override.cache_creation_rate
      acc[override.model] = entry
    end
  end
end
