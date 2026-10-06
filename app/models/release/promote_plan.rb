class Release
  # The pure decisions behind the `accepted → release` promote and the commits
  # `bin/release prepare` lands around it. IO-free like Release::SweepPlan: it takes
  # SHAs that bin/release read from git and returns a symbol; bin/release owns the
  # fetch, the push and the PR. It loads standalone (no Rails).
  #
  # The invariant all three decisions serve: `release` never carries a commit that
  # `accepted` lacks. While that holds, the promote is a fast-forward, so `accepted`,
  # `release` and `main` share one commit id after a ship, and the CI verdict on the
  # `accepted` head is the verdict on the SHA that QA and production run.
  module PromotePlan
    module_function

    # How to land `accepted` on `release` in one repo.
    #
    #   :level        `accepted` adds nothing (`ahead` is zero): no push, no PR.
    #   :fast_forward `release` is contained in the `accepted` head (their merge base
    #                 IS the `release` tip): push that head to `release` by ref.
    #   :batch_pr     `release` carries a commit `accepted` lacks (a hotfix on
    #                 `release` or `main` not yet merged forward), or the containment
    #                 could not be read: open and merge the batch PR, which mints a
    #                 merge commit.
    #
    # An empty SHA is an unreadable answer and never proves containment, so a failed
    # read degrades to the batch PR, the path that needs no containment.
    def promote(ahead:, release_sha:, merge_base:)
      return :level if ahead.to_i.zero?

      contained?(release_sha, merge_base) ? :fast_forward : :batch_pr
    end

    # Whether `accepted` can be carried onto `release` after a commit landed on
    # `release` first: the batch PR's merge commit, or the merge-forward of `main`.
    #
    #   :level        the two already point at one commit.
    #   :fast_forward `accepted` is contained in `release`: push the `release` tip to
    #                 `accepted` by ref, and the next promote is a fast-forward.
    #   :diverged     `accepted` gained a commit meanwhile (a review merge mid-sweep):
    #                 leave it; the next promote takes the batch PR and tries again.
    #   :unreadable   a SHA did not resolve.
    def carry_back(release_sha:, accepted_sha:, merge_base:)
      return :unreadable if blank?(release_sha) || blank?(accepted_sha)
      return :level if release_sha == accepted_sha

      contained?(accepted_sha, merge_base) ? :fast_forward : :diverged
    end

    # Which branch a consumer lock bump commits onto. `:accepted` when the two
    # branches point at one commit: the bump lands on `accepted` first and
    # `release` fast-forwards to it. `:release` otherwise, which is the diverged
    # path: the bump lands on `release` alone and the next promote's batch PR
    # carries it back.
    def bump_rung(release_sha:, accepted_sha:)
      return :release if blank?(release_sha) || blank?(accepted_sha)

      release_sha == accepted_sha ? :accepted : :release
    end

    # `base_sha` is contained in the other side when it IS their merge base.
    def contained?(base_sha, merge_base)
      !blank?(base_sha) && base_sha == merge_base.to_s.strip
    end

    def blank?(sha) = sha.to_s.strip.empty?
  end
end
