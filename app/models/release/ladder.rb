class Release
  # Which registered repos the release conductor may sweep, and what branch
  # shape each one is expected to have.
  #
  # The conductor's rungs are **accepted → release → main**. A repo it sweeps
  # needs BOTH persistent branches: feature PRs land on `accepted`, the sweep
  # promotes `accepted` onto `release`, and the ship fast-forwards `release`
  # onto `main`. A repo missing either rung cannot ride that pipeline — which is
  # not a hypothetical: moms-app was created with `main` alone, so every change
  # to it reopened the question of where its PR should go, and `bin/release
  # init` (which built only `release`, never `accepted`) could not have fixed it.
  #
  # So the shape is DECLARED, per repo, in config/release_repos.yml, and the
  # declaration is checked rather than trusted (test/models/release/repos_test.rb):
  #
  #   three-rung  the normal state — `accepted` and `release` both exist
  #   planned     the repo does not exist yet; the guard asserts there is still
  #               no checkout, so the exemption EXPIRES the day the repo lands
  #               instead of quietly becoming permanent
  #   dormant     registered for history, deliberately not shipped
  #   blocked     the repo exists and is wanted, but the automation cannot reach
  #               it — no org ownership, or the GitHub App is not installed on
  #               it. Kept SEPARATE from `dormant` on purpose: dormant is a
  #               decision, blocked is unfinished work, and collapsing the two
  #               would hide the second behind the first.
  #
  # Every value but three-rung is excluded from the sweep. That exclusion — not
  # the label — is what keeps a repo the conductor cannot reach from failing a
  # fetch in the middle of an unrelated command.
  #
  # Deliberately IO-free (no git, no network, no Rails) so both readers can load
  # it: `bin/release` require_relative's it, and the Rails suite autoloads it.
  # It takes the parsed registry hash in and returns names out.
  module Ladder
    module_function

    THREE_RUNG = "three-rung"
    PLANNED    = "planned"
    DORMANT    = "dormant"
    BLOCKED    = "blocked"
    LADDERS    = [THREE_RUNG, PLANNED, DORMANT, BLOCKED].freeze

    # Both rungs the conductor walks. `main` is not listed: every repo has one,
    # and no repo is onboarded by creating it.
    RUNGS = %w[accepted release].freeze

    # Every repo in the registry, gems and apps alike, in declaration order.
    def all(config)
      config.fetch("gems", {}).keys + config.fetch("apps", {}).keys
    end

    # The declared shape, or nil when the entry omits it. nil is a FAILURE for
    # the guard, never a default — silence is how moms-app's missing ladder went
    # unnoticed, and defaulting here would rebuild that silence in code.
    def ladder(config, repo)
      meta = config.dig("gems", repo.to_s) || config.dig("apps", repo.to_s)
      return nil unless meta.is_a?(Hash)

      value = meta["ladder"]
      value.nil? ? nil : value.to_s
    end

    def valid?(value)
      LADDERS.include?(value.to_s)
    end

    # The repos the conductor may touch: three-rung only. `planned` has no repo
    # behind it yet and `dormant` is deliberately parked, so reaching for either
    # is how a fetch against a repo that no longer resolves ends up in the middle
    # of an unrelated `bin/release status`.
    def sweepable(config)
      all(config).select { |repo| ladder(config, repo) == THREE_RUNG }
    end

    # Registered but NOT swept, with the reason — for reporting, so a skipped
    # repo is visible rather than merely absent.
    def parked(config)
      all(config).reject { |repo| ladder(config, repo) == THREE_RUNG }
                 .to_h { |repo| [repo, ladder(config, repo)] }
    end
  end
end
