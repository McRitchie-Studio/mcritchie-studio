seed_note = "Seed candidate only. Public GitHub activity placeholder; verify cohort, repos, and relevance before using in analysis."

builders = [
  {
    github_login: "hwchase17",
    display_name: "Seed candidate: Harrison Chase",
    cohort: "ai_builder",
    category: "agent_framework",
    notes: seed_note,
    repos: ["langchain-ai/langchain"]
  },
  {
    github_login: "ggerganov",
    display_name: "Seed candidate: Georgi Gerganov",
    cohort: "ai_builder",
    category: "local_ai_runtime",
    notes: seed_note,
    repos: ["ggml-org/llama.cpp"]
  },
  {
    github_login: "comfyanonymous",
    display_name: "Seed candidate: ComfyUI maintainer",
    cohort: "ai_builder",
    category: "ai_workflow_tooling",
    notes: seed_note,
    repos: ["Comfy-Org/ComfyUI"]
  },
  {
    github_login: "yoheinakajima",
    display_name: "Seed candidate: Yohei Nakajima",
    cohort: "ai_builder",
    category: "agent_experiment",
    notes: seed_note,
    repos: ["yoheinakajima/babyagi"]
  },
  {
    github_login: "jlowin",
    display_name: "Seed candidate: Jonathan Lowin",
    cohort: "ai_builder",
    category: "agent_tooling",
    notes: seed_note,
    repos: ["PrefectHQ/fastmcp"]
  },
  {
    github_login: "amcritchie",
    display_name: "Monitor account: amcritchie",
    cohort: "ai_builder",
    category: "studio_operator",
    notes: "Owner-requested monitor account. Public GitHub activity only; review whether to include in cohort analysis before publishing.",
    repos: []
  },
  {
    github_login: "dhh",
    display_name: "Seed candidate: David Heinemeier Hansson",
    cohort: "control_builder",
    category: "framework",
    notes: seed_note,
    repos: ["rails/rails"]
  },
  {
    github_login: "tenderlove",
    display_name: "Seed candidate: Aaron Patterson",
    cohort: "control_builder",
    category: "framework",
    notes: seed_note,
    repos: ["rails/rails", "ruby/ruby"]
  },
  {
    github_login: "sindresorhus",
    display_name: "Seed candidate: Sindre Sorhus",
    cohort: "control_builder",
    category: "developer_tooling",
    notes: seed_note,
    repos: ["sindresorhus/awesome", "sindresorhus/type-fest"]
  },
  {
    github_login: "isaacs",
    display_name: "Seed candidate: Isaac Z. Schlueter",
    cohort: "control_builder",
    category: "developer_tooling",
    notes: seed_note,
    repos: ["npm/cli", "isaacs/node-glob"]
  },
  {
    github_login: "antfu",
    display_name: "Seed candidate: Anthony Fu",
    cohort: "control_builder",
    category: "frontend_tooling",
    notes: seed_note,
    repos: ["vitejs/vite", "unocss/unocss"]
  }
]

builders.each do |data|
  builder = TrackedGithubBuilder.find_or_initialize_by(github_login: data[:github_login])
  builder.assign_attributes(
    display_name: data[:display_name],
    cohort: data[:cohort],
    category: data[:category],
    notes: data[:notes],
    active: true
  )
  builder.save!

  data.fetch(:repos, []).each do |repo_full_name|
    builder.tracked_github_builder_repos.find_or_create_by!(repo_full_name: repo_full_name) do |repo|
      repo.repo_category = data[:category]
      repo.active = true
    end
  end
end

puts "AI Builder Multiple seed candidates: #{builders.size} builders"
