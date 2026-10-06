# frozen_string_literal: true

require "json"
require "open3"
require "set"
require_relative "gh_identity"
require_relative "gh_auth_retry"

# BranchPrune — the merged-branch pruner `bin/release archive` drives.
#
# The hub remote keeps every feat/* branch it was ever pushed, merged or not, and
# nothing deleted one. This deletes a remote branch only when ALL of these hold:
#
#   * it is a feat/* branch (main, release, accepted and every other name are
#     never candidates);
#   * its tip is contained in origin/main (`git branch -r --merged origin/main`);
#   * its task is shipped or archived on the board (feat/<slug>, or the branch a
#     task record names);
#   * no open PR has it as its head;
#   * no desk on this machine has it checked out (`git worktree list`).
#
# FAIL CLOSED: if the open-PR list or the board cannot be read, the plan refuses
# and nothing is deleted. The delete itself pushes with a lease on the tip the plan
# saw, so a branch that moved after planning is refused by the remote.
#
# Every GitHub call runs as the agent App (GH_APP_ITEM and a token from bin/gh-token
# --identity agent), whatever lane the calling shell is in.
module BranchPrune
  PREFIX = "feat/"
  PROTECTED = %w[main master release accepted HEAD].freeze
  DONE_STAGES = %w[shipped archived].freeze
  SAMPLE_SIZE = 20
  BATCH = 50
  SUMMARY_TAG = "BRANCH_PRUNE_SUMMARY"

  Plan = Struct.new(:prune, :skipped, :refusal, keyword_init: true) do
    # prune: [{name:, sha:}]; skipped: {reason => count}
    def names = prune.map { |b| b[:name] }
  end

  module_function

  # PURE. +remote+ is {branch name => tip sha} for origin; the rest are sets of
  # branch names (or task slugs for +done_slugs+).
  def plan(remote:, merged:, open_pr_heads:, desk_branches:, done_slugs:, done_branches:)
    skipped = Hash.new(0)
    prune = []
    remote.keys.sort.each do |name|
      next if PROTECTED.include?(name) || !name.start_with?(PREFIX)

      reason =
        if !merged.include?(name) then "not merged into main"
        elsif open_pr_heads.include?(name) then "open PR"
        elsif desk_branches.include?(name) then "bound to a desk"
        elsif !(done_slugs.include?(name.delete_prefix(PREFIX)) || done_branches.include?(name))
          "task not shipped or archived"
        end
      if reason
        skipped[reason] += 1
      else
        prune << { name: name, sha: remote[name] }
      end
    end
    Plan.new(prune: prune, skipped: skipped.to_h, refusal: nil)
  end

  # --- reads -------------------------------------------------------------------

  def git(repo, *args, env: {})
    Open3.capture3(env, "git", "-C", repo.to_s, *args)
  end

  # Refresh origin's refs (local ref bookkeeping only; nothing on the remote moves).
  def fetch!(repo, env: {})
    _out, err, status = git(repo, "fetch", "--prune", "--quiet", "origin", env: env)
    status.success? ? nil : "git fetch origin failed: #{err.strip}"
  end

  def remote_branches(repo)
    out, _err, status = git(repo, "for-each-ref", "--format=%(refname:lstrip=3) %(objectname)", "refs/remotes/origin")
    return {} unless status.success?

    out.lines.each_with_object({}) do |line, h|
      name, sha = line.split
      h[name] = sha if name && sha && name != "HEAD"
    end
  end

  def merged_into_main(repo)
    out, _err, status = git(repo, "branch", "-r", "--merged", "origin/main", "--format=%(refname:lstrip=3)")
    status.success? ? Set.new(out.lines.map(&:strip).reject(&:empty?)) : Set.new
  end

  def desk_branches(repo)
    out, _err, status = git(repo, "worktree", "list", "--porcelain")
    return Set.new unless status.success?

    Set.new(out.lines.filter_map { |l| l[%r{\Abranch refs/heads/(.+)\Z}, 1] })
  end

  # owner/name from origin's URL, or nil when it is not a GitHub remote.
  def github_slug(repo)
    out, _err, status = git(repo, "remote", "get-url", "origin")
    status.success? ? out.strip[%r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?\z}, 1] : nil
  end

  # The env every GitHub call carries: the agent App, with a token from the broker.
  # Returns [env, refusal].
  def agent_env(env: ENV)
    item = GhIdentity.item_for("agent")
    out, err, status = Open3.capture3(env.to_h.merge("GH_APP_ITEM" => item), GhAuthRetry.token_bin(env: env),
                                      "--identity", "agent")
    token = out.to_s.strip
    return [nil, "no agent GitHub token (bin/gh-token --identity agent: #{err.strip})"] unless status.success? && !token.empty?

    [{ "GH_APP_ITEM" => item, "GH_TOKEN" => token }, nil]
  rescue SystemCallError => e
    [nil, "no agent GitHub token (#{e.message})"]
  end

  # Head branch names of every open PR. Returns [set, refusal].
  def open_pr_heads(repo, env:)
    slug = github_slug(repo)
    cmd = ["gh", "pr", "list", "--state", "open", "--limit", "1000", "--json", "headRefName"]
    cmd += ["--repo", slug] if slug
    out, err, status = Open3.capture3(env, *cmd, chdir: repo.to_s)
    return [nil, "open PRs could not be read (gh: #{err.strip})"] unless status.success?

    [Set.new(JSON.parse(out).map { |pr| pr["headRefName"].to_s }), nil]
  rescue JSON::ParserError, SystemCallError => e
    [nil, "open PRs could not be read (#{e.class}: #{e.message})"]
  end

  # Slugs and branch names of every shipped or archived task. Returns [slugs, branches, refusal].
  def done_tasks(task_bin:, env: ENV)
    slugs = Set.new
    branches = Set.new
    DONE_STAGES.each do |stage|
      out, err, status = Open3.capture3(env.to_h, task_bin, "list", "--stage", stage, "--json")
      return [nil, nil, "the board could not be read (bin/task list --stage #{stage}: #{err.strip})"] unless status.success?

      JSON.parse(out).each do |t|
        slugs << t["slug"].to_s unless t["slug"].to_s.empty?
        branches << t["branch"].to_s unless t["branch"].to_s.empty?
      end
    end
    [slugs, branches, nil]
  rescue JSON::ParserError, SystemCallError => e
    [nil, nil, "the board could not be read (#{e.class}: #{e.message})"]
  end

  # --- the delete ----------------------------------------------------------------

  # Delete the planned branches from origin, each leased on the tip the plan saw.
  # Returns the names the remote reports deleted.
  def apply!(plan, repo, env:)
    plan.prune.each_slice(BATCH).flat_map do |batch|
      leases = batch.map { |b| "--force-with-lease=refs/heads/#{b[:name]}:#{b[:sha]}" }
      refspecs = batch.map { |b| ":refs/heads/#{b[:name]}" }
      out, _err, _status = git(repo, "push", "--porcelain", *leases, "origin", *refspecs, env: env)
      out.lines.filter_map { |l| l[%r{\A-\t:refs/heads/(\S+)\t\[deleted\]}, 1] }
    end
  end

  def summary(plan, applied:, removed: nil)
    {
      pruner: "branches",
      applied: applied,
      count: applied ? removed.to_a.size : plan.prune.size,
      skipped: plan.skipped,
      sample: (applied ? removed.to_a : plan.names).first(SAMPLE_SIZE),
      refusal: plan.refusal
    }
  end

  def summary_line(summary) = "#{SUMMARY_TAG} #{JSON.generate(summary)}"

  def parse_summary(output)
    line = output.to_s.lines.reverse.find { |l| l.start_with?("#{SUMMARY_TAG} ") }
    line && JSON.parse(line.delete_prefix("#{SUMMARY_TAG} "), symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
