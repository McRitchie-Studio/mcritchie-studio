# Split cache-read tokens out of the lumped input side.
#
# The live-capture hook USED to fold input + cache_creation + cache_read all into
# tokens_in, so a long session read as ~300K tokens/action (dominated by CACHE
# READS — the re-read context) and cost priced ALL of it at the full input rate,
# overstating cost ~10x. We now store the FRESH prompt-side spend in tokens_in
# (input + cache_creation) and the re-used context in its own column:
#
#   * cache_read_tokens — the turn's cache_read_input_tokens (context re-read from
#     the prompt cache). Kept OUT of the displayed token count (tokens_in/out are
#     the fresh spend); carried only so cost can price it at the cache-read tier
#     (10% of the base input rate). Nullable default 0 — a pre-usage / board /
#     harness row carries none, and a NULL reads as "no cache read".
class AddCacheReadTokensToAtomicActions < ActiveRecord::Migration[8.1]
  def change
    add_column :atomic_actions, :cache_read_tokens, :integer, default: 0
  end
end
