# The un-folded cache buckets the capture path needs to re-derive cost SERVER-side.
#
# tokens_in has always stored the FOLDED count (input + cache_creation), so without
# the cache_creation bucket the server cannot split it back out — it would price
# cache WRITES at 1x input instead of 2x, silently under-counting the tier that
# dominates the bill. task_events additionally never carried cache_read, so a
# re-derive there also lost the 0.10x read tier.
#
# Nullable ON PURPOSE: absence is meaningful. A historical row (or an older CLI that
# doesn't send these yet) leaves them NULL, and UsagePricing.cost_from_capture returns
# nil for such a row, so the caller keeps the cost the CLI computed rather than
# re-deriving it wrong. New captures fill them and get server-derived pricing — which
# is what lets an operator's saved rate override actually apply.
class AddCaptureCacheBuckets < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_activities, :cache_creation_tokens, :integer
    add_column :task_events, :cache_creation_tokens, :integer
    add_column :task_events, :cache_read_tokens, :integer
  end
end
