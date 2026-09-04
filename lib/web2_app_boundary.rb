# frozen_string_literal: true

# The web2/web3 app-template boundary, as an executable rule.
#
# THE ARCHITECTURE (docs/agents/system/app-templates.md, decided 2026-08-31).
# Every McRitchie app is built from the BASE template (studio-engine +
# mcritchie-studio). A Solana app bolts the WEB3 ADD template (solana-studio +
# turf-monster) on top. Most apps are web2; standing up web3 infrastructure to
# build a newsletter app is wrong, and the base template stays small so a new
# app is cheap.
#
# WHY THIS FILE EXISTS. That rule lived only in a doc, and a rule written only
# in a doc decays — this repo has the receipts (see
# test/lib/feature_shape_tiers_test.rb, where a tier nobody collected rotted to
# 18 red specs). The Gemfile dependency is already an exact, unambiguous,
# machine-checkable expression of which template an app follows. This turns the
# observation into enforcement.
#
# ── WHERE "THIS APP IS WEB2" IS DECLARED, AND WHY ──────────────────────────
#
# It is declared by `Studio.features` — specifically by the ABSENCE of :web3.
# This is a READ of an existing signal, not a new one:
#
#   * `Studio.features` already exists and already carries exactly this meaning.
#     It is the engine's coarse capability switch (studio-engine lib/studio.rb),
#     defaulting to [] — every capability OFF. Its real values are :web3,
#     :leveling and :age_gate. turf-monster declares %i[web3 leveling]; the hub
#     declares nothing at all.
#   * The engine's own comment beside that accessor names the case outright,
#     citing "McRitchie Studio, which ships neither". The signal already
#     classifies the exact app this check is about.
#   * It lives in config/initializers/studio.rb — the same file the architecture
#     decision already edited when `drop-hub-wallet-auth` cut auth_methods to
#     %i[magic_link google]. One file answers "what is this app".
#
# THE TWO ALTERNATIVES, AND WHY THEY LOST:
#
#   * A registry key in config/release_repos.yml. That registry's job is the
#     DEPLOY ladder — producer/consumer, gem vs app, prod_deploy adapters. Which
#     template an app follows is a different axis, and adding a key there would
#     be inventing a signal in a file with a clear single purpose. (It is also
#     where the incidental "solana" strings live that name the solana-studio
#     REPO; overloading that file is how those get confused for Solana logic.)
#   * The absence of the gem itself. This is circular and therefore useless: the
#     check would reduce to "the gem is absent when the gem is absent". A
#     declaration has to be an INDEPENDENT claim for the gem's presence to
#     contradict. Without one there is nothing to violate, and an app that adds
#     solana-studio tomorrow would define itself as web3 by the act of adding it.
#
# ── SCOPE — honest about its reach ────────────────────────────────────────
#
# This speaks for the repo it runs in. A lane is a per-repo capability and CI
# checks out no sibling repos, so a cross-repo sweep here would resolve against
# whatever happens to be on the developer's disk and pass vacuously in CI — the
# precise failure mode test/lib/feature_shape_tiers_test.rb was written to kill
# ("the catalog describes; only a runner runs"). Each app carries its own copy
# of this guard against its own Gemfile. Two of the four web2 apps
# (mcritchie-industries, rolio) already satisfy it today.
#
# ── THE INVARIANT IS POSITIVE ─────────────────────────────────────────────
#
# This does not enumerate the ways an app might smuggle web3 in. It asserts the
# property: a web2 app's declared dependencies do not include a web3-template
# gem. Anything that breaks that fails, including reasons nobody has thought of
# yet. Dependencies are read STRUCTURALLY (Bundler's own parse of the Gemfile),
# never by grepping source for "solana" — this repo is full of incidental
# mentions in comments and in the managed-app registry that names the
# solana-studio REPO, and a substring match would flag prose.
module Web2AppBoundary
  # The WEB3 ADD template's gem. An app declaring this is claiming to be a
  # Solana app; `Studio.features` must agree.
  WEB3_GEMS = %w[solana-studio].freeze

  # The capability that means "this app ships on-chain features".
  WEB3_FEATURE = :web3

  Violation = Struct.new(:kind, :app, :gem, :message, keyword_init: true) do
    def to_s = message
  end

  # ── The allowlist ────────────────────────────────────────────────────────
  #
  # A permanent silent exemption is exactly how this rule would rot, so an entry
  # here is not a mute. Each one is CHECKED, three ways, and any of them can go
  # red on its own:
  #
  #   1. It must still be needed — `justified_by` names the code that holds the
  #      gem here. When ALL of those are gone the exemption is STALE and this
  #      guard fails, telling you to drop the gem and the entry. The exemption
  #      self-destructs the moment the work that justified it lands; it cannot
  #      quietly outlive its reason.
  #   2. It must name its exit — a `clearing_task` slug, or an explicit
  #      `unfiled_reason` when no task exists yet. An exemption pointing at
  #      nothing is itself a violation.
  #   3. It must still describe a real violation — if the app no longer carries
  #      the gem at all, the entry is OBSOLETE and must go.
  #
  # Threshold note on (1): stale when NONE of the paths exist, not when any one
  # is missing. The exemption exists because the gem cannot be REMOVED yet, and
  # it cannot be removed while any consumer remains. A rename going red here is
  # a correct prompt to re-read the exemption, not noise.
  # EMPTY, and that is the point. mcritchie-studio held the only entry — for
  # solana-studio, justified by the admin signing console — and both retired on
  # 2026-09-04 (/tasks/retire-signing-console), when Mr. McRitchie ruled that
  # Turf Monster is the hub for ALL Solana/web3 logic. The hub now satisfies the
  # boundary structurally instead of by exemption, which is the state every
  # entry here is supposed to reach. Keep the machinery below: it is what makes
  # the NEXT exemption expire rather than rot.
  ALLOWLIST = {}.freeze

  class << self
    # Does this feature set declare an on-chain app?
    def web3?(features)
      Array(features).map(&:to_sym).include?(WEB3_FEATURE)
    end

    # The web3-template gems this app declares.
    def web3_dependencies(dependencies)
      Array(dependencies).map(&:to_s) & WEB3_GEMS
    end

    # Every way this app breaks the boundary. Empty array == clean.
    #
    # app          — the repo slug, the allowlist key (e.g. "mcritchie-studio")
    # features     — the app's Studio.features (runtime value, not parsed source)
    # dependencies — declared gem names, structurally (Bundler.definition.dependencies)
    # repo_root    — Pathname/String the justification paths resolve against
    def violations(app:, features:, dependencies:, repo_root:, allowlist: ALLOWLIST)
      root    = Pathname.new(repo_root.to_s)
      carried = web3_dependencies(dependencies)
      entry   = allowlist[app.to_s]
      found   = []

      # A web3 app may carry anything in WEB3_GEMS — that is the bolt-on doing
      # its job — and needs no allowlist entry.
      unless web3?(features)
        carried.each do |gem_name|
          next if entry && entry[:gem].to_s == gem_name

          found << Violation.new(
            kind: :undeclared_web3_gem, app: app.to_s, gem: gem_name,
            message: "#{app} does not declare Studio.features #{WEB3_FEATURE.inspect} " \
                     "but its Gemfile declares #{gem_name.inspect}. Either drop the gem " \
                     "(web2, the base template) or declare the feature (web3). " \
                     "See docs/agents/system/app-templates.md."
          )
        end
      end

      found.concat(exemption_violations(app: app.to_s, entry: entry, carried: carried, root: root))
      found
    end

    # An allowlist entry is itself subject to the rule. These fire whether or not
    # the app is web2 today, because a rotting exemption is the failure this
    # whole file exists to prevent.
    def exemption_violations(app:, entry:, carried:, root:)
      return [] if entry.nil?

      found = []
      gem_name = entry[:gem].to_s

      unless carried.include?(gem_name)
        found << Violation.new(
          kind: :obsolete_exemption, app: app, gem: gem_name,
          message: "#{app} is allowlisted for #{gem_name.inspect} but no longer declares it. " \
                   "The exemption describes a violation that no longer exists — delete the " \
                   "Web2AppBoundary::ALLOWLIST entry."
        )
      end

      paths = Array(entry[:justified_by])
      if paths.empty?
        found << Violation.new(
          kind: :unjustified_exemption, app: app, gem: gem_name,
          message: "#{app}'s allowlist entry names no justified_by paths, so nothing can " \
                   "ever retire it. An exemption that cannot expire is a permanent silent " \
                   "exemption."
        )
      elsif paths.none? { |path| root.join(path).exist? }
        found << Violation.new(
          kind: :stale_exemption, app: app, gem: gem_name,
          message: "#{app}'s exemption for #{gem_name.inspect} is STALE: none of its " \
                   "justified_by paths (#{paths.join(', ')}) still exist, so the code that " \
                   "held the gem here is gone. Drop #{gem_name.inspect} from the Gemfile and " \
                   "delete the ALLOWLIST entry."
        )
      end

      task    = entry[:clearing_task].to_s.strip
      unfiled = entry[:unfiled_reason].to_s.strip
      if task.empty? && unfiled.empty?
        found << Violation.new(
          kind: :nameless_exemption, app: app, gem: gem_name,
          message: "#{app}'s allowlist entry names neither a clearing_task nor an " \
                   "unfiled_reason. An exemption must say what clears it — pointing at " \
                   "nothing is how this rule rots."
        )
      end

      doc = entry[:doc].to_s
      if doc.empty? || !root.join(doc).exist?
        found << Violation.new(
          kind: :missing_doc_pointer, app: app, gem: gem_name,
          message: "#{app}'s allowlist entry points at doc #{doc.inspect}, which does not " \
                   "exist. The reasoning behind an exemption has to stay reachable."
        )
      end

      found
    end
  end
end
