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

  # BELT AND BRACES for the placeholder generator (repair-avatar-generator-and-docs).
  # script/generate_agent_avatars.rb writes public/agents/<slug>.png, and its
  # never-clobber guard went blind when the portraits moved to .webp — a run dropped
  # five placeholder bubbles in here beside the real faces. Nothing rendered them, so
  # no page test could see it.
  #
  # The guard above only inspects DIRECTORIES, so a stray FLAT file walks straight
  # past it. test/lib/response_payload_budget_test.rb does catch these by bytes and
  # pixels, but only because a 340x340 bubble happens to fit no rule it likes; a
  # placeholder that came in under budget would be invisible to every other guard.
  #
  # The invariant is not "no PNGs" — it is that public/ is copied into EVERY worktree,
  # so a file nobody names is pure cost on every desk. Referenced = named by the seed
  # (the avatar column is DATA) or hardcoded in a view.
  test "[component] nothing sits in public/agents that no seed or view names" do
    referenced = (AVATAR_PATHS + view_portrait_paths).map { |p| File.basename(p) }.uniq

    strays = Dir.children(Rails.public_path.join("agents")) - referenced

    assert_empty strays,
                 "public/agents holds #{strays.join(', ')}, which no seed avatar and no view " \
                 "references. Placeholder output from script/generate_agent_avatars.rb looks " \
                 "exactly like this. If a page needs these, reference them in the same diff."
  end

  private

  # Portraits hardcoded in markup rather than seeded — alex-photo.webp on the landing
  # page, alex.webp in the chat widget. Scanned, not listed, so adding one to a view
  # is enough to make it legitimate here.
  def view_portrait_paths
    Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |file|
      File.read(file).scan(%r{/agents/([A-Za-z0-9_.-]+\.[a-z0-9]+)}).flatten
    end
  end
end
