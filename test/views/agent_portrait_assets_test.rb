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

  # The byte budget and the pixel floor/ceiling live in
  # test/lib/response_payload_budget_test.rb, which already owns them and reasons about the
  # card-hero draw size. Duplicating the number here would just give it two homes to drift
  # between.

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
