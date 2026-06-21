module ApplicationHelper
  def qa_environment?
    ENV["QA_ENV"].to_s.strip.downcase == "true"
  end

  def show_environment_banner?(qa_environment: qa_environment?, rails_env: Rails.env)
    !rails_env.production? || qa_environment
  end

  def environment_banner_message(qa_environment: qa_environment?, rails_env: Rails.env)
    return "QA Environment · Non-production" if qa_environment

    "#{rails_env.to_s.capitalize} Environment"
  end

  def stage_scheme(stage)
    case stage.to_s
    when "designed"                          then "info"
    when "submitted"                         then "warning"
    when "building", "reviewed", "assembled", "shipped" then "success"
    when "blocked"                           then "danger"
    else "neutral"
    end
  end

  def task_stage_count_classes(stage)
    case stage.to_s
    when "designed"  then "bg-blue-900/50 text-blue-300"
    when "building"  then "bg-mint-900/50 text-mint-300"
    when "submitted" then "bg-orange-900/50 text-orange-300"
    when "reviewed"  then "bg-cyan-900/50 text-cyan-300"
    when "assembled" then "bg-violet-900/50 text-violet-300"
    when "shipped"   then "bg-green-900/50 text-green-300"
    when "blocked"   then "bg-red-900/50 text-red-300"
    when "archived"  then "bg-surface-alt text-muted"
    else "bg-surface-alt text-muted"
    end
  end

  def release_state_classes(state)
    case state.to_s
    when "assembling" then "bg-blue-900/50 text-blue-300"
    when "assembled"  then "bg-amber-900/50 text-amber-300"
    when "shipped"    then "bg-green-900/50 text-green-300"
    when "abandoned"  then "bg-surface-alt text-muted"
    else "bg-surface-alt text-muted"
    end
  end

  # Canonical app/repo slug → emoji map for the compact app indicators on task
  # cards and current-release member pills. Mirrors the glyphs in
  # ReleaseNotes::Formatter::APP_GROUPS (kept independent so views don't reach
  # into the service); keep the two in sync if an app is added or its glyph
  # changes.
  APP_EMOJIS = {
    "mcritchie-studio" => "🧰",
    "turf-monster"     => "🐊",
    "studio-engine"    => "💎",
    "turf-vault"       => "🏛️",
    "vault"            => "🏛️",
    "solana-studio"    => "🧱",
    "chain-ops"        => "⛓️"
  }.freeze

  # Emoji for a single repo/app slug, or nil when the slug is unmapped/blank.
  def app_emoji(repo)
    APP_EMOJIS[repo.to_s.strip.downcase]
  end

  # Order-preserving, de-duplicated emoji list for a set of repo slugs. Two
  # aliases that share a glyph (turf-vault/vault) collapse to one.
  def app_emojis(repos)
    Array(repos).filter_map { |repo| app_emoji(repo) }.uniq
  end

  # Inline emoji cluster (one glyph per mapped repo) for a set of repo slugs,
  # titled with the repo list — or nil when nothing maps. Centralizes the markup
  # shared by the task card's slug row and the current-release member pills;
  # callers pass layout classes via +css+.
  def app_emoji_badge(repos, css: "leading-none")
    emojis = app_emojis(repos)
    return if emojis.none?

    tag.span(emojis.join(" "), class: css, title: Array(repos).join(", "))
  end

  # Canonical copy-paste kickoff commands for the DevOps (Deploy) lane — the
  # single source of truth shared by the /deployments column headers and the
  # /stages cards. Keyed by stage; the feature-agent lane has none.
  def devops_kickoffs
    {
      "submitted" => "Review submitted PRs",
      "reviewed"  => "Prepare release",
      "assembled" => "Run Deployment",
      "shipped"   => "Cleanup worktrees"
    }
  end

  # The two-workflow stage guide rendered on /stages (vertical swimlanes). One
  # entry per stage: what it means, who's responsible, and what moves it next.
  # `submitted` is the shared seam, so it appears in both lanes.
  def devops_stage_guide
    {
      "Build" => [
        { stage: "designed",
          what: "Spec complete — acceptance criteria, change shape, test plan, and affected repos are all set. No code yet.",
          who: "Author / operator", nxt: "An agent claims it (passes dor-check --gate build) → building" },
        { stage: "building",
          what: "An agent owns the task in an isolated worktree, writing the code and its tests together as the work takes shape.",
          who: "Feature agent", nxt: "Open a PR, pass dor-check --gate merge → submitted" },
        { stage: "blocked",
          what: "Off the pipeline — waiting on an environment fix, QA rework, or a dependency. Records where it stalled (blocked_from) and why (block_kind).",
          who: "Whoever can unblock it (agent for rework, operator for environment)", nxt: "Once cleared, it resumes → back to building or submitted" },
        { stage: "submitted",
          what: "The PR is open and the feature agent's part is done — the seam where Build hands off to DevOps.",
          who: "Feature agent → DevOps", nxt: "DevOps picks it up for review → reviewed" }
      ],
      "Deploy" => [
        { stage: "submitted", kick: devops_kickoffs["submitted"],
          what: "The intake queue — submitted PRs waiting for review.",
          who: "DevOps → Avi", nxt: "Avi reviews acceptance / diff / tests → reviewed, or sends it back blocked for rework" },
        { stage: "reviewed",  kick: devops_kickoffs["reviewed"],
          what: "Approved and off the bench, waiting to ride the next release.",
          who: "Avi → conductor", nxt: "The conductor cuts a release/<slug> branch and merges tasks in dependency order → assembled" },
        { stage: "assembled", kick: devops_kickoffs["assembled"],
          what: "Every member PR is merged and its tests pass; the release candidate is built and deployed to QA for review.",
          who: "Steffon (QA)", nxt: "The operator runs the deployment — the one human gate. Run Deployment ships to prod, tags, and posts release notes → shipped" },
        { stage: "shipped",   kick: devops_kickoffs["shipped"],
          what: "Live in production and shown as the current release; release notes are posted as part of Run Deployment.",
          who: "Mr. McRitchie → conductor", nxt: "Terminal — just clean up the deployed feature worktrees." }
      ]
    }
  end

  # Render a stage-guide "Next →" line, turning any stage word into its colored
  # badge (so "→ assembled" shows the same pill as the column). Escapes first,
  # then injects badge markup for whole-word stage matches only.
  def devops_next_html(text)
    stages = Task::STAGE_LABELS.keys
    pattern = /\b(#{stages.join('|')})\b/
    ERB::Util.html_escape(text).to_str.gsub(pattern) do |word|
      tag.span(Task::STAGE_LABELS.fetch(word),
               class: "inline-block px-1.5 py-0.5 rounded text-[11px] font-bold align-baseline #{task_stage_count_classes(word)}")
    end.html_safe
  end

  def news_stage_scheme(stage)
    case stage.to_s
    when "new"        then "stage-fresh"
    when "reviewed"   then "stage-shaping"
    when "processed"  then "stage-structured"
    when "refined"    then "stage-refined"
    when "concluded"  then "stage-cohered"
    when "archived"   then "stage-closed"
    else "neutral"
    end
  end
end
