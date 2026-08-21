# frozen_string_literal: true

# RepoCheckout — resolve the DIRECTORY an ecosystem repo is checked out in,
# rather than assuming the directory is named after the repo.
#
# The registry (config/release_repos.yml) names repos the way GitHub does:
# hyphenated — `mcritchie-studio`, `turf-monster`. In the projects-root layout the
# checkout directory carries that same name, so "the repo name" and "the directory
# name" were one thing, and bin/release simply joined the name onto the projects
# root.
#
# THEY ARE NOT ONE THING IN THE CONSUMER LANE. studio-engine's consumer-ci.yml
# checks each consumer out at `path: ${{ matrix.consumer }}`, and that matrix value
# is the UNDERSCORED, ruby-ish label — `mcritchie_studio` for repo
# `mcritchie-studio`, `turf_monster` for `turf-monster`. So the hub sits beside the
# engine under a name the registry never uses. Joining the registry name produced
# `<workspace>/mcritchie-studio`, which does not exist; bin/release handed that to
# `bin/archive-docs --repo=`, and `git -C` died with "cannot change to … No such
# file or directory" (DocsArchive::CommandFailed). Three archive tests went red in
# `mcritchie_studio suite vs this engine`, the gem publish preflight failed with
# them, and a checkpoint release carrying six tasks stopped.
#
# THE BREAK WAS NOT NEW — PR #984 REVEALED IT. bin/release.rb's two `sweep_docs`
# call sites used to take `.first` of `[out, status.success?]` and discard the exit
# code, so the docs step had ALREADY been failing in the consumer lane with the
# failure swallowed. #984 made the caller honour the refusal — that was its entire
# purpose — and a pre-existing breakage surfaced. The repair therefore belongs HERE,
# in the path resolution. Making the caller ignore the exit code again, in any
# spelling, would restore the silent failure #984 removed.
#
# LOOK, DON'T GUESS — and look in a fixed order:
#
#   * the CANONICAL (registry) spelling is tried FIRST, so the projects-root layout
#     resolves byte-for-byte as it always did and the alternate spelling can never
#     shadow a real sibling;
#   * the alternate spelling is consulted only when the canonical directory is not
#     on disk;
#   * when NEITHER is on disk the canonical name is returned unchanged, so a
#     genuinely absent sibling still produces today's path and today's error.
#
# That last rule is the load-bearing one. "The sibling is not here" and "the sibling
# is here" have to stay different answers: collapsing them — by skipping the sweep,
# or by returning something that merely happens not to raise — is how a caller stops
# being able to tell a missing checkout from a real refusal, which is the silent
# failure this whole family of bugs is made of.
module RepoCheckout
  module_function

  # The directory names a repo may be checked out under, CANONICAL FIRST.
  #
  # Both directions are generated on purpose. Hyphen→underscore is the consumer
  # lane's transform (`mcritchie-studio` → `mcritchie_studio`); underscore→hyphen
  # covers a caller that already holds the ruby-ish label and wants the ordinary
  # checkout. `uniq` keeps a name with neither separator a single candidate.
  def spellings(repo)
    name = repo.to_s
    [name, name.tr("-", "_"), name.tr("_", "-")].uniq
  end

  # The checkout directory for `repo` under `root`: the first spelling that IS a
  # directory, else the canonical name (absent siblings keep their current path).
  def resolve(root, repo)
    found = spellings(repo).find { |dir| File.directory?(File.join(root, dir)) }
    File.join(root, found || repo.to_s)
  end
end
