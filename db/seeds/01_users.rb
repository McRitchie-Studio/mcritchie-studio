# Core users. Each can authenticate via email (magic-link) / Google AND, where a
# wallet is set, via Solana (Phantom) — all resolving to the SAME user, since
# the User row carries email + provider/uid + solana_address together.
users_data = [
  { name: "Alex McRitchie",  email: "alex@mcritchie.studio",  role: "admin",
    solana_address: "7ZDJp7FUHhuceAqcW9CHe81hCiaMTjgWAXfprBM59Tcr" }, # Mr. McRitchie's Phantom
  { name: "Mason McRitchie", email: "mason@mcritchie.studio", role: "admin",
    solana_address: "CytJS23p1zCM2wvUUngiDePtbMB484ebD7bK4nDqWjrR" }, # Mason's Phantom
  { name: "Mack McRitchie",  email: "mack@mcritchie.studio",  role: "admin" },
  { name: "Turf Monster",    email: "turf@mcritchie.studio",  role: "admin" }
]

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
