# Credential RECORDS — the census of what lives in which 1Password vault, joined
# to the client each credential serves. No secret values, ever: every row here
# restates what docs/agents/modules/credential-inventory.md already publishes
# (its Known Items table and its "Also present" list), and this repo is PUBLIC.
# When the inventory changes, change this.
#
# `entity` is set only where the client served differs from the vault's own —
# the Turf Monster keys live in the Studio agent vault. `service` must be a
# software key in config/workspace_icons.yml, which is what gives each row its
# icon.
#
# Left out on purpose: `dont.use.agent.aws`, which the inventory lists as a
# decoy to ignore.
#
# Idempotent: re-running updates rows in place and never deletes one.
puts "\n--- Credential vaults and records ---"

vaults = [
  { slug: "studio-agents", name: "Studio agents", entity: "studio", lane: "agents", icon_scope: "studio",
    workspace_domain: "mcritchie.studio",
    purpose: "The agent vault: every build, review and QA lane reads it through the agent service account." },
  { slug: "studio-agents-admin", name: "Studio agents admin", entity: "studio", lane: "admin", icon_scope: "studio",
    workspace_domain: "mcritchie.studio",
    purpose: "Ship-lane and break-glass credentials, read only by the separate admin service account." },
  { slug: "studio-applications", name: "Studio applications", entity: "studio", lane: "applications", icon_scope: "studio",
    workspace_domain: "mcritchie.studio",
    purpose: "Deterministic runtime and CI credentials: durable copies of Heroku config vars and Actions secrets." },
  { slug: "industries-agents", name: "Industries agents", entity: "industries", lane: "agents", icon_scope: "industries",
    workspace_domain: "mcritchie.industries",
    purpose: "Industries-brand agent credentials." },
  { slug: "family-agents", name: "Family agents", entity: "family", lane: "agents", icon_scope: "family",
    purpose: "Family-brand agent credentials." },
  { slug: "Commercial Welding", name: "Commercial Welding", entity: "commercial-welding", lane: "agents",
    icon_scope: "commercial-welding", workspace_domain: "commercialwelding.llc", status: "reserved",
    purpose: "Reserved for the Commercial Welding initiative." }
]

vaults.each do |attrs|
  vault = CredentialVault.find_or_initialize_by(slug: attrs[:slug])
  vault.update!(attrs.reverse_merge(status: "active"))
end

UNDESCRIBED = "Listed in studio-agents on 2026-08-29; not yet described in the inventory.".freeze

records = [
  # --- studio-agents: the agent lane ---
  { vault: "studio-agents", title: "heroku.studio.agents", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "Agent sessions: deploys, config vars, logs",
    scope_summary: "identity, read-protected, write-protected. CANNOT transfer apps or manage billing." },
  { vault: "studio-agents", title: "github.mcritchie-agent", service: "github", category: "API Credential",
    url: "https://github.com/McRitchie-Studio", used_by: "Build and review lanes (default identity)",
    scope_summary: "GitHub App: contents, pull requests, checks read, actions, workflows across the org." },
  { vault: "studio-agents", title: "agent.github", service: "github", status: "retired",
    notes: "Deleted from 1Password on 2026-08-29 after both GitHub App identities were proven." },
  { vault: "studio-agents", title: "Agent API Secret", service: "mcritchie-studio", category: "API Credential",
    url: "https://mcritchie.studio", used_by: "The agent task API (AGENT_API_SECRET)",
    scope_summary: "Task-board API secret." },
  { vault: "studio-agents", title: "agent.solana", service: "solana", category: "Crypto Wallet",
    scope_summary: "Legacy Xan wallet; off both live signer sets since the 2026-06-02 key rotation." },
  { vault: "studio-agents", title: "agent.mason.solana", service: "solana", category: "Crypto Wallet",
    scope_summary: "Mason's vault signer; no longer a Squads member." },
  { vault: "studio-agents", title: "agent.mack.solana", service: "solana", category: "Crypto Wallet",
    scope_summary: "Mack's agent wallet; not a Squads member or vault signer." },
  { vault: "studio-agents", title: "solana.turf.admin", service: "solana", entity: "turf-monster", category: "Crypto Wallet",
    scope_summary: "The agent governance identity." },
  { vault: "studio-agents", title: "solana.turf.system", service: "solana", entity: "turf-monster", category: "Crypto Wallet",
    scope_summary: "Server operational key, mainnet." },
  { vault: "studio-agents", title: "solana.turf.system.devnet", service: "solana", entity: "turf-monster", category: "Crypto Wallet",
    scope_summary: "Server operational key, devnet and QA." },
  { vault: "studio-agents", title: "agent.turf.solana", service: "solana", entity: "turf-monster", status: "retired",
    notes: "Two items share this title; both superseded and awaiting deletion (verified 2026-09-15)." },
  { vault: "studio-agents", title: "turf_vault-mainnet-keypair", service: "solana", entity: "turf-monster", category: "Document",
    scope_summary: "The turf-vault program's mainnet keypair (a document item)." },
  { vault: "studio-agents", title: "turf.squad", service: "squads", entity: "turf-monster", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.managed_wallet", service: "turf-monster", entity: "turf-monster",
    scope_summary: "Managed wallet encryption key for Turf Monster's managed-wallet flows." },
  { vault: "studio-agents", title: "agent.helius", service: "helius", scope_summary: "Devnet and mainnet Helius RPC URLs for the Solana apps." },
  { vault: "studio-agents", title: "agent.aws.mcritchie-ses", service: "aws", category: "API Credential",
    url: "https://console.aws.amazon.com/ses", used_by: "App email delivery",
    scope_summary: "SES-scoped AWS API credentials, us-east-2." },
  { vault: "studio-agents", title: "agent.aws", service: "aws", category: "API Credential",
    url: "https://console.aws.amazon.com", scope_summary: "General AWS API credentials: S3 read and write, us-east-2." },
  { vault: "studio-agents", title: "Coinbase Developer Platform", service: "coinbase", entity: "turf-monster", category: "API Credential",
    url: "https://portal.cdp.coinbase.com", used_by: "Turf Monster CDP ramp", scope_summary: "CDP API key." },
  { vault: "studio-agents", title: "higgsfield.studio.agents", service: "higgsfield", category: "API Credential",
    url: "https://higgsfield.ai", used_by: "Media generation", scope_summary: "Higgsfield media generation API, filed 2026-09-20." },
  { vault: "studio-agents", title: "agent.higgesfield", service: "higgsfield", status: "retired",
    notes: "Retired 2026-09-20; superseded by higgsfield.studio.agents." },
  { vault: "studio-agents", title: "agent.turf.x", service: "x", entity: "turf-monster", category: "Login",
    scope_summary: "The live X/Twitter credentials." },
  { vault: "studio-agents", title: "x.api", service: "x", status: "missing",
    notes: "Named by .env.example; absent from the vault on 2026-08-29. agent.turf.x is the live one." },
  { vault: "studio-agents", title: "anthropic", service: "anthropic", status: "missing",
    notes: "Named by .env.example; not located in any readable vault on 2026-09-22." },
  { vault: "studio-agents", title: "TikTok", service: "tiktok", status: "missing",
    notes: "Named by .env.example; not located in any readable vault on 2026-09-22." },
  { vault: "studio-agents", title: "slack.studio.agents", service: "slack", category: "API Credential",
    url: "https://slack.com", used_by: "Slack::Credentials in mcritchie-industries", scope_summary: "Read-only Slack token." },
  { vault: "studio-agents", title: "gmail.studio.agents", service: "google", category: "API Credential",
    url: "https://console.cloud.google.com/apis/credentials", used_by: "Gmail::Credentials (mailbox ingest)",
    scope_summary: "Gmail OAuth client id, secret and refresh token, as one JSON field.",
    notes: "Gmail::Credentials says the item was filed empty until real values exist; whether it is filled now is unverified." },
  { vault: "studio-agents", title: "agent.1password", service: "1password",
    scope_summary: "Holds the service-account token install recipe." },
  { vault: "studio-agents", title: "agent.rails_master_key", service: "rails", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.resend", service: "resend", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.google", service: "google", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "Google | McRitchie Studio", service: "google", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.gmail", service: "google", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.rubygems", service: "rubygems", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agents.cloudflare", service: "cloudflare", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.ipinfo.io", service: "ipinfo", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.coinflow", service: "coinflow", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.stripe", service: "stripe", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "agent.stripe.sandbox", service: "stripe", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "turf.stripe", service: "stripe", entity: "turf-monster", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "Moonpay", service: "moonpay", notes: UNDESCRIBED },
  { vault: "studio-agents", title: "discord.webhooks", service: "discord", notes: UNDESCRIBED },

  # --- studio-agents-admin: ship lane and break-glass ---
  { vault: "studio-agents-admin", title: "Heroku", service: "heroku", category: "Login", url: "https://dashboard.heroku.com",
    scope_summary: "The master account login: password, TOTP, recovery codes. Break-glass only." },
  { vault: "studio-agents-admin", title: "heroku.studio.admin", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "Admin lane provisioning acts",
    scope_summary: "Admin-lane Heroku authorization, filed 2026-09-02." },
  { vault: "studio-agents-admin", title: "github.mcritchie-admin", service: "github", category: "API Credential",
    url: "https://github.com/McRitchie-Studio", used_by: "Ship and admin lanes",
    scope_summary: "GitHub App: contents, actions, checks read, secrets, environments. CANNOT open or merge pull requests, by design." },
  { vault: "studio-agents-admin", title: "github.mcritchie-deployer", service: "github", category: "API Credential",
    url: "https://github.com/McRitchie-Studio", used_by: "Legacy name during the transition",
    scope_summary: "Legacy copy of github.mcritchie-admin (the App was renamed 2026-09-26). Retire once no shell exports it." },
  { vault: "studio-agents-admin", title: "agent.xan.solana", service: "solana", category: "Crypto Wallet",
    scope_summary: "The Xan signer; the rotated replacement for agent.solana." },
  { vault: "studio-agents-admin", title: "AWS", service: "aws", category: "API Credential", url: "https://console.aws.amazon.com",
    scope_summary: "IAM user studio-agents-admin, created 2026-09-01, us-east-2." },

  # --- studio-applications: runtime and CI ---
  { vault: "studio-applications", title: "heroku.studio.applications", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "CI deploy workflows",
    scope_summary: "identity, read-protected, write-protected (same matrix as the agents lane)." },
  { vault: "studio-applications", title: "mcritchie-industries.aws", service: "aws", entity: "industries", category: "API Credential",
    url: "https://console.aws.amazon.com", used_by: "mcritchie-industries Heroku app",
    scope_summary: "S3 knowledge-layer buckets; IAM under /mcr/." },

  # --- industries-agents ---
  # ONE key for every client workspace: Workspace::Credentials impersonates the
  # team@ subject of each ACTIVE WorkspaceAccount with it, so a new client's
  # Google access is a delegation grant on their domain, not a new item.
  { vault: "industries-agents", title: "google.industries.agents", service: "google", category: "API Credential",
    status: "empty", url: "https://admin.google.com", used_by: "Workspace::Credentials (Drive walk, drafting)",
    scope_summary: "Service-account key with domain-wide delegation, used for every registered workspace. " \
                   "Filed empty on 2026-09-18; the value is pasted by Mr. McRitchie." }
]

records.each do |attrs|
  attrs = attrs.dup
  vault_slug = attrs.delete(:vault)
  record = CredentialRecord.find_or_initialize_by(credential_vault_slug: vault_slug, title: attrs[:title])
  record.update!(attrs.reverse_merge(status: "filed", entity: nil))
end

puts "  #{CredentialVault.count} vaults, #{CredentialRecord.count} records"
