# frozen_string_literal: true

namespace :tasks do
  # One-time correction: the cache_read token-inflation pinned nearly every task's
  # actual_size to XL. Now that #derive_actual_size buckets on ground-truth $cost,
  # recompute it for every task with measured cost. This DOES overwrite prior
  # (bug-corrupted, token-derived) auto-sizes — the point of the pass — so re-set
  # any intentionally-manual actual_size afterward if one existed.
  desc "Recompute actual_size from measured $cost (fixes the cache_read token-inflation)"
  task backfill_actual_size_from_cost: :environment do
    updated = 0
    Task.find_each do |task|
      size = task.derive_actual_size
      next if size.blank?           # no measured cost → can't size (leave blank)
      next if task.actual_size == size

      task.update_column(:actual_size, size) # rubocop:disable Rails/SkipsModelValidations
      updated += 1
    end
    puts "actual_size recomputed from cost for #{updated} task(s)"
  end
end
