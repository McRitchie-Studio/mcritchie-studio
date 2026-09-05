# Core users. Each can authenticate via email (magic-link) / Google AND, where a
# wallet is set, via Solana (Phantom) — all resolving to the SAME user. Keep the
# durable operator list on User::PARKED_IDENTITIES so login, seeds, and future
# app bootstrap workflows share the same identity contract.

# An identity that CHANGED ADDRESS has to be carried over before anything is
# created, or the seed simply makes a second account and leaves the first one
# behind — still holding whatever role it had when the roster last listed it.
# Deployed rows are moved by the RenameTurfHouseIdentity migration instead (the
# release phase is db:migrate alone); this is the same move for the databases a
# re-seed owns: local, test, and a QA reset.
User::RETIRED_EMAILS.each do |old_email, new_email|
  stale = User.find_by(email: old_email)
  next if stale.nil?

  if User.where(email: new_email).where.not(id: stale.id).exists?
    # BOTH rows exist — someone signed in at the new address first. Merging two
    # accounts is the operator's call (wallets, sessions and slugs on both sides),
    # but the stale row does not get to sit on admin while they make it. Same move
    # as RenameTurfHouseIdentity, which is the point: the two carriers must not
    # disagree about what a half-moved identity is allowed to keep.
    parked = User.parked_identity_for(email: new_email)
    stale.update_column(:role, parked[:role]) if parked && stale.role != parked[:role]
    puts "  ! #{new_email} already exists; left #{old_email} as #{stale.role} for a manual merge"
    next
  end

  # update_column, not update!: Sluggable rebuilds the slug on every save, so a
  # full save here would quietly re-point the URL this account answers on.
  stale.update_column(:email, new_email)
  puts "  ↪ moved #{old_email} to #{new_email}"
end

# A NAME the roster planted and has since changed is the other thing the roster
# cannot fix by itself: `assign_parked_identity` fills a blank name and never
# overwrites one, and the enforcement below covers role and wallet but not name.
# So rewrite exactly the value the roster put there, and leave any other name
# alone — it belongs to whoever typed it. Deployed rows are carried by
# RenameTurfHouseIdentity; this is the same move for the databases a re-seed owns.
User::RETIRED_NAMES.each do |email, old_name|
  identity = User.parked_identity_for(email: email)
  row = identity && User.find_by(email: email)
  next if row.nil? || row.name != old_name

  # update_column for the same reason as the address move above: Sluggable builds
  # the slug from the NAME, so a full save would re-point the URL this account
  # answers on as a side effect of a rename nobody asked to be a redirect.
  row.update_column(:name, identity[:name])
  puts "  ↪ renamed #{email} from #{old_name.inspect} to #{identity[:name].inspect}"
end

users_data = User::PARKED_IDENTITIES.map do |identity|
  identity.merge(solana_address: identity[:wallet])
end

users_data.each do |data|
  user = User.find_or_create_by!(email: data[:email]) do |u|
    u.name = data[:name]
    # Login is passwordless (magic-link/Google/wallet); the password exists only
    # as a dev/e2e convenience. NEVER plant the weak literal on prod — a random
    # digest there means a prod re-seed can't introduce a guessable credential.
    u.password = Rails.env.production? ? SecureRandom.hex(24) : "password"
    u.role = data[:role]
  end

  # find_or_create_by!'s block only runs on CREATE, so a pre-existing row keeps
  # its current role on a re-seed. Enforce the seed's role idempotently — the
  # seed is the durable source of truth for who is an admin. (alex@mcritchie.studio
  # was created as the default "viewer" by first login before being seeded; without
  # this, a re-seed would never promote it.)
  user.update!(role: data[:role]) if user.role != data[:role]

  # Link the wallet idempotently — also backfills an existing row so the account
  # can auth via Solana OR email. Re-runs are no-ops.
  if data[:solana_address].present? && user.solana_address != data[:solana_address]
    other = User.where.not(id: user.id).find_by(solana_address: data[:solana_address])
    if other.nil?
      user.update!(solana_address: data[:solana_address])
    elsif other.email.blank? && !other.google_connected?
      # Thin wallet-only orphan: a Solana login created a fresh account before the
      # wallet was associated with this person. Transfer the wallet to the
      # canonical user + remove the orphan (mirrors turf's account-merge on overlap).
      other.destroy!
      user.update!(solana_address: data[:solana_address])
      puts "  ↪ merged orphan wallet-only user ##{other.id} into #{user.email}"
    else
      puts "  ! #{data[:solana_address][0, 6]}… already on real account ##{other.id} (#{other.email}); leaving #{user.email} unlinked"
    end
  end

  wallet = user.solana_address ? " wallet=#{user.solana_address[0, 4]}…#{user.solana_address[-4, 4]}" : ""
  puts "User: #{user.email} (#{user.role})#{wallet}"
end
