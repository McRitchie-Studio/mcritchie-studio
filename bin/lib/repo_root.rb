# frozen_string_literal: true

# RepoRoot — resolve the CODE root a gate should test / fingerprint / diff.
#
# The gate scripts (bin/full-suite-check, bin/dor-check) live in the hub
# (mcritchie-studio), but satellites (turf-monster, rolio, …) ship no gate
# scripts, so a satellite task runs the HUB's gate. If the gate rooted at the
# script's own repo it would run the suite + fingerprint the HUB — certifying a
# repo the task never touched (a false GREEN), or reading STALE. So the CODE root
# must follow the worktree the AGENT is working in — its cwd's git toplevel —
# while CONFIG (feature_shapes.yml, the token .env) stays anchored at the script's
# repo, and board calls stay on the hub's bin/task.
#
# For a mcritchie-studio worktree this changes nothing: the worktree ships its own
# bin/, so the script's repo and the cwd git toplevel are the SAME directory.
module RepoRoot
  module_function

  # The git working tree that contains `dir` (default cwd) — its `--show-toplevel`,
  # or nil when `dir` isn't inside a git work tree. Best-effort; never raises.
  def git_toplevel(dir = Dir.pwd)
    return nil unless dir && File.directory?(dir.to_s)

    out = IO.popen(["git", "-C", dir.to_s, "rev-parse", "--show-toplevel"],
                   err: File::NULL, &:read).to_s.strip
    out.empty? ? nil : out
  rescue StandardError
    nil
  end

  # The code root for a gate:
  #   1. an explicit `override` (the ENV test/CI seam) — expanded and always wins;
  #   2. else the cwd's git toplevel — so the gate roots at the worktree the agent
  #      runs from (a satellite task certifies the satellite);
  #   3. else `fallback` — the gate script's own repo, when cwd isn't in a git tree.
  # `dir` defaults to cwd; passed explicitly by tests.
  def code_root(override, fallback, dir = Dir.pwd)
    value = override.to_s.strip
    return File.expand_path(value) unless value.empty?

    git_toplevel(dir) || fallback
  end
end
