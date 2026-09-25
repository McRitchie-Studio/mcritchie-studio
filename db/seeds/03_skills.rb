skills_data = [
  { name: "Web Scraping",        category: "data",           description: "Extract data from websites and APIs" },
  { name: "Data Processing",     category: "data",           description: "Transform, clean, and analyze datasets" },
  { name: "Rails Development",   category: "development",    description: "Build and maintain Ruby on Rails applications" },
  { name: "API Integration",     category: "development",    description: "Connect to and consume external APIs" },
  { name: "API Design",          category: "development",    description: "Design REST/JSON APIs, contracts, and versioning" },
  { name: "UI Development",      category: "development",    description: "Build frontend views, components, and interactions" },
  { name: "Tailwind CSS",        category: "development",    description: "Build with Tailwind utility classes and design tokens" },
  { name: "Alpine.js",           category: "development",    description: "Reactive UI behavior with Alpine.js" },
  { name: "Rails Views (ERB)",   category: "development",    description: "Author ERB views, partials, and layouts" },
  { name: "Design Systems",      category: "development",    description: "Maintain reusable design primitives and theme tokens" },
  { name: "Background Jobs",     category: "development",    description: "Author Sidekiq jobs with retries and idempotency" },
  { name: "Ruby Gem Authoring",  category: "development",    description: "Build and maintain shared Ruby gems" },
  { name: "ActiveRecord & Postgres", category: "development", description: "Model design, query tuning, migrations" },
  { name: "Solana Development",  category: "blockchain",     description: "Solana program and client integration" },
  { name: "Anchor / Rust",       category: "blockchain",     description: "Anchor program authoring in Rust" },
  { name: "Ruby Solana Client",  category: "blockchain",     description: "solana-studio gem: RPC, borsh, transactions" },
  { name: "Wallet Integration",  category: "blockchain",     description: "Phantom + managed wallets, ed25519, signing flows" },
  { name: "Smart Contract Security", category: "blockchain", description: "Authority checks, signer rotation, IDL pinning" },
  { name: "Database Management", category: "infrastructure", description: "PostgreSQL administration, migrations, backups" },
  { name: "Deployment",          category: "infrastructure", description: "Deploy applications to production environments" },
  { name: "DevOps",              category: "infrastructure", description: "Operate the production runtime end-to-end" },
  { name: "Heroku Administration", category: "infrastructure", description: "Heroku apps, addons, env vars, releases" },
  { name: "CI / CD",             category: "infrastructure", description: "Pre-commit hooks, deploy guards, automated tests" },
  { name: "Monitoring",          category: "system",         description: "System health checks, alerting, and observability" },
  { name: "Task Orchestration",  category: "system",         description: "Coordinate multi-agent workflows and task pipelines" },
  { name: "PR Review",           category: "product",        description: "Review pull requests for correctness, scope, and tests" },
  { name: "Product Strategy",    category: "product",        description: "Prioritize features by user value vs cost" },
  { name: "Release Management",  category: "product",        description: "Sign off on release candidates and coordinate launches" },
  { name: "QA",                  category: "product",        description: "Verify features end-to-end before release" },
  { name: "Brand & Voice",       category: "marketing",      description: "Maintain consistent brand voice across surfaces" },
  { name: "Social Media",        category: "marketing",      description: "Operate X, TikTok, and other social channels" },
  { name: "Copywriting",         category: "marketing",      description: "Author marketing, transactional, and product copy" },
  { name: "Content Strategy",    category: "marketing",      description: "Plan launches, narratives, and content calendars" },
  { name: "Funnel Analytics",    category: "marketing",      description: "Measure landing-page conversion and referral attribution" },
  { name: "Sports Analytics",    category: "domain",         description: "Sports data analysis, odds, and prop generation" }
]

skills_data.each do |data|
  skill = Skill.find_or_create_by!(slug: data[:name].parameterize) do |s|
    s.name = data[:name]
    s.category = data[:category]
    s.description = data[:description]
  end
  puts "Skill: #{skill.name} (#{skill.category})"
end

assignments = {
  "xan"          => ["task-orchestration", "rails-development", "api-integration", "monitoring"],
  "avi"          => ["pr-review", "product-strategy", "release-management", "qa", "rails-development"],
  "carl"         => ["rails-development", "activerecord-postgres", "background-jobs", "api-design", "ruby-gem-authoring"],
  "shannon"      => ["ui-development", "tailwind-css", "alpine-js", "rails-views-erb", "design-systems"],
  "jasper"       => ["solana-development", "anchor-rust", "ruby-solana-client", "wallet-integration", "smart-contract-security"],
  "steffon"      => ["deployment", "devops", "heroku-administration", "ci-cd", "monitoring"],
  "turf-monster" => ["sports-analytics", "data-processing", "rails-development"],
  "mack"         => ["web-scraping", "data-processing", "api-integration", "database-management"],
  "mason"        => ["brand-voice", "social-media", "copywriting", "content-strategy", "funnel-analytics"]
}

assignments.each do |agent_slug, skill_slugs|
  desired = skill_slugs.to_set
  SkillAssignment.where(agent_slug: agent_slug).where.not(skill_slug: desired.to_a).destroy_all
  skill_slugs.each do |skill_slug|
    SkillAssignment.find_or_create_by!(agent_slug: agent_slug, skill_slug: skill_slug)
  end
end
puts "Skill assignments synced"
