require "test_helper"

# [component] the soul portraits the agent pages actually reference.
#
# public/agents was 105MB: 103MB of it seven portrait-NN.png folders that NOTHING
# read (no view, helper, seed, test, doc, sibling repo, or studio-engine), plus
# ten flat faces that DO render. public/ is copied into every worktree, so those
# folders cost ~100MB per desk and nothing rendered a pixel of them.
#
# This guards the state after the cleanup, and it guards the thing a literal grep
# CANNOT: Studio::AdminModels-style interpolation aside, an avatar path is stored
# as DATA (agents.avatar, seeded), so a renamed file breaks the page silently —
# _agent_avatar.html.erb carries onerror="this.remove()", which means a 404
# portrait degrades to the initials bubble with no error anywhere.
class AgentPortraitAssetsTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/02_agents.rb")
  AVATAR_PATHS = File.read(SEED).scan(%r{avatar:\s*"(/agents/[^"]+)"}).flatten.freeze

  test "[component] the seed names at least one portrait per soul" do
    assert_operator AVATAR_PATHS.length, :>=, 9,
                    "db/seeds/02_agents.rb should still seed a face per soul; found #{AVATAR_PATHS.length}"
  end

  test "[component] every seeded avatar path resolves to a file that exists" do
    missing = AVATAR_PATHS.reject { |p| Rails.public_path.join(p.delete_prefix("/")).exist? }

    assert_empty missing,
                 "seeded avatar(s) point at files that are not in public/: #{missing.join(', ')}. " \
                 "The avatar is DATA, so a missing file 404s and _agent_avatar's onerror silently " \
                 "drops the <img> — the page still renders, just with no face."
  end

  test "[component] every rendered portrait is under 200KB" do
    oversized = AVATAR_PATHS.filter_map do |p|
      file = Rails.public_path.join(p.delete_prefix("/"))
      next unless file.exist?

      kb = file.size / 1024
      "#{p} (#{kb}KB)" if kb > 200
    end

    assert_empty oversized,
                 "portrait(s) over the 200KB budget: #{oversized.join(', ')}. These are card-size " \
                 "images; re-encode rather than shipping the source render."
  end

  test "[component] no unreferenced portrait folders came back" do
    folders = Dir.children(Rails.public_path.join("agents")).select do |entry|
      Rails.public_path.join("agents", entry).directory?
    end

    assert_empty folders,
                 "public/agents/#{folders.join(', ')} holds portrait sets nothing renders. public/ is " \
                 "copied into EVERY worktree, so each folder costs its size on every desk. If a page " \
                 "needs these, reference them — and delete this assertion in the same diff."
  end
end
