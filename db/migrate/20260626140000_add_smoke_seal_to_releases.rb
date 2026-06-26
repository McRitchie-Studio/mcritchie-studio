class AddSmokeSealToReleases < ActiveRecord::Migration[8.1]
  # The post-ship production smoke SEAL — the verdict of the read-only @qa-readonly
  # suite (bin/prod-smoke) run against PROD after the ship's /up hard-gate. Stored
  # as one jsonb blob ({status, summary, checked_at}) so the verdict + when it was
  # taken travel together; Release#smoke_seal rehydrates it into a Release::SmokeSeal
  # value object. Defaults to {} (an unsealed release — old rows + active releases).
  def change
    add_column :releases, :smoke_seal, :jsonb, default: {}, null: false
  end
end
