# Credential RECORDS — the census of what lives in which 1Password vault, joined
# to the client workspace each vault serves. No secret values, ever: every row
# here restates what docs/agents/modules/credential-inventory.md already
# publishes, and this repo is PUBLIC. When the inventory changes, change this.
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
    icon_scope: "commercial-welding", status: "reserved",
    purpose: "Reserved for the Commercial Welding initiative." }
]

vaults.each do |attrs|
  vault = CredentialVault.find_or_initialize_by(slug: attrs[:slug])
  vault.update!(attrs.reverse_merge(status: "active"))
end

records = [
  { vault: "studio-agents", title: "heroku.studio.agents", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "Agent sessions: deploys, config vars, logs",
    scope_summary: "identity, read-protected, write-protected. CANNOT transfer apps or manage billing." },
  { vault: "studio-agents-admin", title: "heroku.studio.admin", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "Admin lane provisioning acts",
    scope_summary: "Admin-lane Heroku authorization, filed 2026-09-02." },
  { vault: "studio-applications", title: "heroku.studio.applications", service: "heroku", category: "API Credential",
    url: "https://dashboard.heroku.com", used_by: "CI deploy workflows",
    scope_summary: "identity, read-protected, write-protected (same matrix as the agents lane)." },
  { vault: "studio-applications", title: "mcritchie-industries.aws", service: "aws", category: "API Credential",
    url: "https://console.aws.amazon.com", used_by: "mcritchie-industries Heroku app",
    scope_summary: "S3 knowledge-layer buckets; IAM under /mcr/. Grandfathered name." },
  { vault: "studio-agents", title: "github.mcritchie-agent", service: "github", category: "API Credential",
    url: "https://github.com/McRitchie-Studio", used_by: "Build and review lanes (default identity)",
    scope_summary: "Contents, pull requests, checks read, actions, workflows across the org." },
  { vault: "studio-agents-admin", title: "github.mcritchie-deployer", service: "github", category: "API Credential",
    url: "https://github.com/McRitchie-Studio", used_by: "Ship lane",
    scope_summary: "Contents, actions, checks read, secrets. CANNOT open or merge pull requests, by design." },
  { vault: "studio-agents", title: "higgsfield.studio.agents", service: "higgsfield", category: "API Credential",
    url: "https://higgsfield.ai", used_by: "Media generation",
    scope_summary: "Higgsfield media generation API, filed 2026-09-20." },
  { vault: "studio-agents", title: "slack.studio.agents", service: "slack", category: "API Credential",
    url: "https://slack.com", used_by: "Slack::Credentials in mcritchie-industries",
    scope_summary: "Read-only Slack token." },
  { vault: "studio-agents", title: "agent.aws.mcritchie-ses", service: "aws", category: "API Credential",
    url: "https://console.aws.amazon.com/ses", used_by: "App email delivery",
    scope_summary: "SES-scoped AWS API credentials, us-east-2. Grandfathered name." },
  { vault: "studio-agents", title: "Coinbase Developer Platform", service: "coinbase", category: "API Credential",
    url: "https://portal.cdp.coinbase.com", used_by: "Turf Monster CDP ramp",
    scope_summary: "CDP API key. Grandfathered name." },
  { vault: "studio-agents", title: "agent.higgesfield", service: "higgsfield", status: "retired",
    url: "https://higgsfield.ai", notes: "Retired 2026-09-20; superseded by higgsfield.studio.agents." },
  { vault: "industries-agents", title: "google.industries.agents", service: "google", category: "API Credential",
    status: "empty", url: "https://admin.google.com", used_by: "Workspace delegation for Industries",
    scope_summary: "Filed empty on 2026-09-18; the value is pasted by Mr. McRitchie." }
]

records.each do |attrs|
  attrs = attrs.dup
  vault_slug = attrs.delete(:vault)
  record = CredentialRecord.find_or_initialize_by(credential_vault_slug: vault_slug, title: attrs[:title])
  record.update!(attrs.reverse_merge(status: "filed"))
end

puts "  #{CredentialVault.count} vaults, #{CredentialRecord.count} records"
