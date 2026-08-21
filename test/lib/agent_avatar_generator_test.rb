# frozen_string_literal: true

# Tests for script/generate_agent_avatars.rb — the manual placeholder generator
# and, specifically, the never-clobber guard that decides whether a soul already
# has a real face.
#
#   ruby -Itest test/lib/agent_avatar_generator_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE BUG (repair-avatar-generator-and-docs; found in review of PR #965). The guard
# asked `File.exist?("public/agents/<slug>.png")`. PR #965 re-encoded every portrait
# to .webp and deleted the .png originals, so that path stopped existing for EVERY
# soul, the guard could never fire again, and a run drew placeholder initial-bubbles
# over shannon, jasper, carl, avi and steffon — dropping five stray .png files into
# public/agents beside the real .webp and copying them over each persona's
# docs/agents/agents/<slug>/avatar.png. Measured on 2026-08-21 against a fixture
# root holding the ten real portrait NAMES: five placeholders written, zero skips.
#
# It could not break a render — the avatar column is DATA and db/seeds/02_agents.rb
# points at .webp — which is exactly why it needs a test rather than a page.
#
# WHY THE PREDICATE IS EXTRACTED. The lowest tier that reproduces this is a unit
# test on the decision itself, so the script defines AgentAvatarPlaceholders and
# only runs under `__FILE__ == $PROGRAM_NAME`. Requiring it here is inert.
require "minitest/autorun"
require "fileutils"
require "open3"
require "stringio"
require "tmpdir"

require File.expand_path("../../script/generate_agent_avatars", __dir__)

class AgentAvatarGeneratorTest < Minitest::Test
  SCRIPT   = File.expand_path("../../script/generate_agent_avatars.rb", __dir__)
  REAL_PUB = File.expand_path("../../public/agents", __dir__)
  SLUGS    = AgentAvatarPlaceholders::AGENTS.map { |a| a[:slug] }.freeze

  # ── [unit] the never-clobber predicate ──────────────────────────────────────

  # THE REGRESSION. Before the fix this returned nil for a real portrait, because
  # the only container it knew was the one the generator WRITES.
  def test_unit_a_webp_portrait_counts_as_an_existing_portrait
    in_pub_dir do |pub|
      FileUtils.touch(File.join(pub, "shannon.webp"))

      assert_equal File.join(pub, "shannon.webp"),
                   AgentAvatarPlaceholders.existing_portrait(pub, "shannon"),
                   "a real .webp portrait must block the placeholder; PR #965 moved every " \
                   "portrait to .webp, so a png-only check never fires again"
    end
  end

  # The .png era is not over on disk everywhere, and a guard that swapped one
  # hardcoded extension for another would just re-arm the same trap.
  def test_unit_a_png_portrait_still_counts_as_an_existing_portrait
    in_pub_dir do |pub|
      FileUtils.touch(File.join(pub, "carl.png"))

      assert_equal File.join(pub, "carl.png"),
                   AgentAvatarPlaceholders.existing_portrait(pub, "carl")
    end
  end

  def test_unit_no_portrait_at_all_returns_nil
    in_pub_dir do |pub|
      assert_nil AgentAvatarPlaceholders.existing_portrait(pub, "jasper"),
                 "a soul with no face must still get a placeholder — this is the case " \
                 "the whole script exists for"
    end
  end

  # A prefix match would read alex-photo.webp (the landing page's headshot) as
  # alex's portrait, so the one soul whose file is genuinely 340x340 would be the
  # one the guard got wrong.
  def test_unit_another_slugs_file_is_not_this_slugs_portrait
    in_pub_dir do |pub|
      FileUtils.touch(File.join(pub, "alex-photo.webp"))

      assert_nil AgentAvatarPlaceholders.existing_portrait(pub, "alex")
    end
  end

  # public/agents held portrait-NN.png DIRECTORIES until PR #965 deleted them
  # (test/views/agent_portrait_assets_test.rb guards their return). File.exist? is
  # true for a directory; a directory is not a portrait.
  def test_unit_a_directory_named_like_a_portrait_is_not_a_portrait
    in_pub_dir do |pub|
      FileUtils.mkdir_p(File.join(pub, "avi.webp"))

      assert_nil AgentAvatarPlaceholders.existing_portrait(pub, "avi")
    end
  end

  # The fixtures above are all synthetic, so they would pass just as happily if the
  # real portraits were renamed out from under the script tomorrow. This one asks
  # the actual repo, and it is the assertion that was FALSE on accepted.
  def test_unit_every_roster_slug_resolves_against_the_real_public_agents
    missing = SLUGS.reject { |slug| AgentAvatarPlaceholders.existing_portrait(REAL_PUB, slug) }

    assert_empty missing,
                 "the generator cannot see the committed portrait(s) for #{missing.join(', ')} in " \
                 "public/agents, so a run would draw a placeholder over each one"
  end

  # ── [integration] the whole script, end to end ──────────────────────────────

  # Drives the real CLI entrypoint as a subprocess against a fixture root, which is
  # the only thing that proves the guard is actually WIRED to the write path — a
  # correct predicate nobody calls fixes nothing. No ImageMagick needed: on a
  # complete roster the script must not draw at all.
  def test_integration_a_run_against_the_real_portrait_names_writes_nothing
    Dir.mktmpdir do |root|
      pub = File.join(root, "public", "agents")
      FileUtils.mkdir_p(pub)
      real_portrait_names.each { |name| FileUtils.touch(File.join(pub, name)) }
      before = tree(root)

      out, status = Open3.capture2e(RbConfig.ruby, SCRIPT, root)

      assert status.success?, "generator exited #{status.exitstatus}:\n#{out}"
      SLUGS.each do |slug|
        assert_match(/^#{slug}\s+— skip/, out, "#{slug} was not skipped:\n#{out}")
      end
      assert_equal before, tree(root),
                   "a complete roster must produce NO writes. Stray placeholders beside the real " \
                   "portraits are the defect this task exists for:\n#{out}"
    end
  end

  # THE CONTROL. Without it, "never generate anything" would pass every assertion
  # above — and the script would be broken in the opposite direction, silently.
  # In-process with a recording draw so the assertion holds on a box with no
  # ImageMagick.
  def test_integration_a_soul_with_no_portrait_is_still_generated
    Dir.mktmpdir do |root|
      pub = File.join(root, "public", "agents")
      FileUtils.mkdir_p(pub)
      (SLUGS - ["steffon"]).each { |slug| FileUtils.touch(File.join(pub, "#{slug}.webp")) }

      drawn, out = run_with_recorded_draw(root)

      assert_equal ["steffon"], drawn,
                   "only the faceless soul should be drawn; got #{drawn.inspect}\n#{out}"
      assert_path_exists File.join(pub, "steffon.png")
      assert_path_exists File.join(root, "docs", "agents", "agents", "steffon", "avatar.png")
    end
  end

  # FORCE is the documented escape hatch, and post-#965 it writes a file the app
  # does not read: the placeholder lands at <slug>.png while the seed still points
  # at <slug>.webp. It must still draw, and it must say so.
  def test_integration_force_draws_but_warns_that_the_real_webp_stays
    Dir.mktmpdir do |root|
      pub = File.join(root, "public", "agents")
      FileUtils.mkdir_p(pub)
      SLUGS.each { |slug| FileUtils.touch(File.join(pub, "#{slug}.webp")) }

      drawn, out = run_with_recorded_draw(root, force: true)

      assert_equal SLUGS, drawn, "FORCE must still regenerate every placeholder"
      assert_match(/steffon\s+— WARNING: steffon\.webp stays/, out,
                   "FORCE must name the real portrait it did not replace:\n#{out}")
    end
  end

  private

  def in_pub_dir
    Dir.mktmpdir { |dir| yield dir }
  end

  # The portrait names actually committed in public/agents, so the fixture root is
  # a rename away from the real one rather than a remembered list.
  def real_portrait_names
    names = Dir.children(REAL_PUB).select { |n| File.file?(File.join(REAL_PUB, n)) }
    assert names.any?, "public/agents is empty — this fixture would be vacuous"
    names
  end

  def run_with_recorded_draw(root, force: false)
    drawn = []
    out   = StringIO.new
    draw  = lambda do |agent, out_pub|
      drawn << agent[:slug]
      File.binwrite(out_pub, "placeholder")
    end

    AgentAvatarPlaceholders.run(root: root, force: force, out: out, draw: draw)
    [drawn, out.string]
  end

  # Every path under `root` with its size, so "wrote nothing" is measured rather
  # than asserted one filename at a time.
  def tree(root)
    Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH)
       .reject { |p| File.basename(p).start_with?(".") }
       .sort
       .map { |p| [p.delete_prefix(root), File.directory?(p) ? :dir : File.size(p)] }
  end
end
