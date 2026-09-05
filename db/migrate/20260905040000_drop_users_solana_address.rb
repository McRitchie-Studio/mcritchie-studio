# Part two of Mr. McRitchie's 2026-09-04 ruling that Turf Monster is the hub for
# ALL Solana/web3 logic (/tasks/drop-hub-wallet-column). Part one
# (/tasks/retire-signing-console) deleted the admin signing console, the
# solana-studio gem and the Web2AppBoundary allowlist entry; by the time this
# runs nothing in the app reads this column.
#
# WHAT THE DROP DESTROYS, written down because a dropped column takes its
# contents with it. The values themselves are NOT lost — every one is a vault
# signer recorded in turf-vault/docs/CURRENT_DEPLOYMENT.md and
# turf-vault/scripts/squad.json. What dies here is the MAPPING from a hub
# account to its key, which lived only in User::PARKED_IDENTITIES:
#
#   alex@mcritchie.studio   7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr  ("Alex signer")
#   team@mcritchie.studio   8K81w4e6UcB7TiANhM9N8sAgijJvTxxybRi8AENRaRYd  ("Alex Bot signer")
#   mason@mcritchie.studio  CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR  ("Mason signer")
#
# Read the pairing off THIS comment rather than re-deriving it: CURRENT_DEPLOYMENT.md
# names the three signers by ROLE, and "team@mcritchie.studio is the Alex Bot seat"
# is the one hop that document does not make for you.
#
# SINGLE-PHASE, matching this repo's Procfile (`release: bin/rails db:migrate`)
# and its prior column drops. The release phase migrates while the OLD dynos are
# still serving, so for the seconds between this statement and the new dynos
# taking traffic, code that reads solana_address raises. The blast radius is the
# admin user list and any user SAVE (assign_parked_identity ran on every one).
# Accepted deliberately: a five-account internal hub, no wallet auth route drawn
# since /tasks/retire-signing-console, and an expand/contract pair would ship the
# same outage split across two releases nobody is waiting on.
class DropUsersSolanaAddress < ActiveRecord::Migration[8.1]
  def up
    remove_index  :users, :solana_address, unique: true, if_exists: true
    remove_column :users, :solana_address
  end

  # Reversible in SHAPE, never in content — a rollback restores the column and its
  # index empty. Repopulate from the three pairs above if that is ever needed.
  def down
    add_column :users, :solana_address, :string
    add_index  :users, :solana_address, unique: true
  end
end
