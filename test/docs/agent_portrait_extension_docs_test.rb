# frozen_string_literal: true

require "test_helper"

# GUARD (repair-avatar-generator-and-docs, 2026-08-21): every portrait path a doc,
# a config comment, a seed or a view WRITES DOWN must still name a file that is
# actually in public/agents.
#
# shrink-agent-portrait-assets (PR #965) re-encoded the portraits to WebP and
# deleted the .png originals. The pixels were the point and the pixels were right —
# but four places went on describing the old container, and each one is load-bearing
# in a different way:
#
#   · docs/topics/deployment.md   — the Public Assets inventory an operator reads.
#   · docs/topics/seeds.md        — "Avatar PNGs ... all 9 are present."
#   · docs/topics/data-model.md   — the example value of Agent#avatar.
#   · config/environments/production.rb — the reasoning for the one-week TTL, which
#     is stated ABOUT a glob (/agents/*.png) that matched nothing after the rename.
#
# None of it broke a page, because the avatar column is DATA and the seed was
# updated. That is exactly the drift a human review does not catch twice.
#
# THE INVARIANT IS THE FILESYSTEM, NOT A SPELLING. A test that banned the string
# ".png" would be wrong the day a portrait legitimately ships as PNG. So a literal
# name must resolve to a file, and a `<slug>`-style placeholder must name a
# container that some real portrait uses.
#
# NOT SCANNED — script/generate_agent_avatars.rb. It is the one file that names a
# container on purpose without one existing: it WRITES public/agents/<slug>.png for
# a soul that has no face yet. Its own guard is test/lib/agent_avatar_generator_test.rb.
class AgentPortraitExtensionDocsTest < ActiveSupport::TestCase
  # The two spellings that denote a file served out of public/agents. The lookbehind
  # keeps `docs/agents/…` and `app/views/agents/…` out — those are source trees that
  # happen to end in the same word, not URLs.
  REFERENCE = %r{(?:public/agents/|(?<![\w-])/agents/)([A-Za-z0-9_<>-]+)\.([A-Za-z0-9]+)}

  SCANNED = %w[
    docs/topics/*.md
    config/environments/*.rb
    db/seeds/*.rb
    app/views/**/*.erb
  ].freeze

  test "[unit] every written-down portrait path names a file that is really there" do
    dangling = references.reject { |_file, name, ext| placeholder?(name) }
                         .reject { |_file, name, ext| portrait_dir.join("#{name}.#{ext}").file? }

    assert_empty dangling.map { |file, name, ext| "#{file} names /agents/#{name}.#{ext}" },
                 "a portrait path is written down that public/agents does not hold. The avatar " \
                 "is DATA and _agent_avatar carries onerror=\"this.remove()\", so a wrong path " \
                 "degrades to an initials bubble with no error anywhere."
  end

  test "[unit] every <slug> placeholder names a container the portraits actually use" do
    live  = live_extensions
    stale = references.select { |_file, name, _ext| placeholder?(name) }
                      .reject { |_file, _name, ext| live.include?(ext) }

    assert_empty stale.map { |file, name, ext| "#{file} still says #{name}.#{ext}" },
                 "the portraits ship as #{live.join(', ')} — a doc promising another container " \
                 "sends the next reader (or the next generator run) at a path that is not there."
  end

  test "[unit] the scan is not vacuous" do
    assert_operator references.length, :>=, 5,
                     "this guard found almost no portrait references, which means the patterns " \
                     "stopped matching — not that the docs got clean"
    assert_includes references.map(&:first), "docs/topics/deployment.md",
                    "the Public Assets inventory is the doc that drifted worst, so it has to be " \
                    "IN scope. Write its portrait paths in full (public/agents/<slug>.webp) — a " \
                    "bare `<slug>.webp` beside a `public/agents/` heading reads fine and matches " \
                    "nothing"
  end

  private

  def portrait_dir
    Rails.public_path.join("agents")
  end

  # Containers a REAL portrait uses today, read off disk rather than listed, so this
  # follows the next re-encode instead of pinning the current one.
  def live_extensions
    portrait_dir.children.select(&:file?).map { |p| p.extname.delete_prefix(".") }.uniq.sort
  end

  def placeholder?(name)
    name.include?("<")
  end

  # [[relative file, name, ext], ...] for every portrait path written down in SCANNED.
  def references
    @references ||= SCANNED.flat_map { |glob| Dir[Rails.root.join(glob)] }.flat_map do |path|
      relative = Pathname(path).relative_path_from(Rails.root).to_s
      File.read(path).scan(REFERENCE).map { |name, ext| [relative, name, ext] }
    end.uniq
  end
end
