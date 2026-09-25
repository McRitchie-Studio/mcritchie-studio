# frozen_string_literal: true

require "tmpdir"

# TreeFingerprint — a content-addressed hash of a git tree.
#
# The one fingerprint-bound record left on a task is the `test-only` shape's
# executed control, `[control@<fp>]` (bin/control-check writes it, bin/dor-check
# grades it). A git tree hash is purely content-addressed, so the working-tree
# hash the builder stamped before committing equals the branch's committed
# `^{tree}` after the push — which is what lets a reviewer grade the stamp from a
# checkout that is not on the branch.
#
# Until DevOps v3 phase 2b this lived in bin/lib/full_suite_gate.rb beside the
# cert evidence it fingerprinted; the certs retired, the hash did not.
module TreeFingerprint
  module_function

  # Content-addressed fingerprint of the CURRENT code at `root` — tracked edits AND
  # untracked-but-not-ignored files — stable across the pre-commit→commit boundary.
  # Returns a git tree hash, or nil when git cannot read the tree (no repo / missing
  # identity); the caller treats nil as "cannot be graded".
  #
  # Stages everything into a THROWAWAY index (GIT_INDEX_FILE, never the real one)
  # with `git add -A` — which honours .gitignore and DOES include new files — then
  # `git write-tree`. (`git stash create` drops untracked files, so an added file
  # fingerprinted differently before and after its commit.)
  def working_tree(root)
    index = File.join(Dir.tmpdir, "tree-fp-index-#{Process.pid}-#{rand(1 << 32)}")
    env = { "GIT_INDEX_FILE" => index }
    return nil unless run(["git", "-C", root.to_s, "add", "-A"], env: env)

    tree = capture(["git", "-C", root.to_s, "write-tree"], env: env).strip
    tree.empty? ? nil : tree
  ensure
    File.delete(index) if index && File.exist?(index)
  end

  # Tree hash of a COMMITTED ref (e.g. origin/feat/<slug>) within `root`, or nil
  # when the ref cannot be resolved (unfetched branch / bad ref). `--verify --quiet`
  # emits nothing on a bad ref and exits non-zero, so capture → "".
  def of_ref(root, ref)
    return nil if ref.to_s.strip.empty?

    tree = capture(["git", "-C", root.to_s, "rev-parse", "--verify", "--quiet", ref_expression(ref)]).strip
    tree.empty? ? nil : tree
  end

  # The exact ref expression #of_ref resolves — the string an agent can paste into
  # `git -C <repo> rev-parse …` and get the SAME hash back. One definition, so what
  # is announced and what is hashed cannot drift apart.
  def ref_expression(ref)
    "#{ref}^{tree}"
  end

  # The fingerprint of the first of `refs` that resolves, WITH the ref that produced
  # it: { fingerprint:, ref:, root: } — or nil when none resolve. The hash and its
  # provenance leave together, so a caller cannot hold a fingerprint from ref A while
  # reporting ref B.
  def of_first_ref(root, *refs)
    refs.flatten.compact.each do |ref|
      fp = of_ref(root, ref)
      return { fingerprint: fp, ref: ref_expression(ref), root: root.to_s } if fp
    end
    nil
  end

  def capture(argv, env: {})
    IO.popen([env, *argv], err: File::NULL, &:read).to_s
  rescue SystemCallError
    ""
  end

  # Run a command for its exit status only; true on a clean exit.
  def run(argv, env: {})
    system(env, *argv, out: File::NULL, err: File::NULL)
  rescue SystemCallError
    false
  end
end
