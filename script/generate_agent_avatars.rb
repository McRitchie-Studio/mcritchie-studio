#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generate 340x340 placeholder portraits for agents that do not have a real one
# yet. Drops files at:
#   - public/agents/<slug>.png             (a PLACEHOLDER container; the real
#                                           portraits ship as .webp — see below)
#   - docs/agents/agents/<slug>/avatar.png (referenced by each persona's role.md)
#
# Style: solid brand-color background + white initial(s) centered. Sized to match
# alex.webp (340x340) so the agent grid renders evenly.
#
# Run from repo root:  ruby script/generate_agent_avatars.rb
# Against a fixture root (this is how the test suite drives it):
#                       ruby script/generate_agent_avatars.rb /tmp/fixture-root
# Requires ImageMagick 7 (`brew install imagemagick`).
#
# Two-letter initials picked for Shannon/Steffon since they share an "S".
#
# ── THE REAL PORTRAITS ARE WebP, NOT PNG ────────────────────────────────────────
# shrink-agent-portrait-assets (PR #965) re-encoded every portrait to
# public/agents/<slug>.webp and deleted the .png originals. That silently killed
# the never-clobber guard below, which asked `File.exist?("<slug>.png")`: the path
# it named stopped existing for EVERY soul, so the guard could never fire again and
# a run drew placeholder bubbles over all five real faces. Nothing rendered them
# (db/seeds/02_agents.rb points at .webp), which is why the break was invisible.
#
# The guard now looks for the portrait in ANY container it ships in, listed in
# PORTRAIT_EXTENSIONS. Add a container there the day one appears, not a second
# `File.exist?`.
require "fileutils"
require "shellwords"

module AgentAvatarPlaceholders
  AGENTS = [
    { slug: "shannon",   initials: "Sh", bg: "#06D6A0", fg: "#FFFFFF", note: "UI / mint" },
    { slug: "jasper",    initials: "J",  bg: "#8E82FE", fg: "#FFFFFF", note: "Blockchain / violet" },
    { slug: "carl",      initials: "C",  bg: "#4BAF50", fg: "#FFFFFF", note: "Backend / primary green" },
    { slug: "avi",       initials: "A",  bg: "#FF7C47", fg: "#FFFFFF", note: "Product Owner / orange" },
    { slug: "steffon",   initials: "St", bg: "#475569", fg: "#FFFFFF", note: "Platform Engineer / slate" }
  ].freeze

  # Every container a real portrait ships in today. The generator only ever WRITES
  # png; this list is what it READS when deciding whether a real face is already
  # there, so it has to name the containers on disk, not the one it emits.
  PORTRAIT_EXTENSIONS = %w[webp png].freeze

  SIZE       = 340
  # macOS ships Arial Bold at this path; IMv7's font discovery doesn't find
  # system fonts by name on this machine, so point at the TTF directly.
  FONT       = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
  POINTSIZE  = 180

  module_function

  # The real portrait for `slug`, in whatever container it ships in, or nil when
  # the soul genuinely has no face yet.
  #
  # File.file?, not File.exist?: public/agents once held portrait-NN.png DIRECTORIES
  # (deleted in PR #965, guarded by test/views/agent_portrait_assets_test.rb), and a
  # directory named like a portrait is not a portrait.
  def existing_portrait(pub_dir, slug)
    PORTRAIT_EXTENSIONS
      .map { |ext| File.join(pub_dir, "#{slug}.#{ext}") }
      .find { |path| File.file?(path) }
  end

  # Safety: these are PLACEHOLDERS. Several agents already have real portraits
  # committed under public/agents — never clobber them. Only generate where the
  # portrait is missing. FORCE=1 regenerates every placeholder.
  def run(root:, force: false, out: $stdout, draw: nil)
    draw    ||= method(:magick)
    pub_dir   = File.join(root, "public", "agents")
    docs_dir  = File.join(root, "docs", "agents", "agents")

    FileUtils.mkdir_p(pub_dir)

    AGENTS.each do |agent|
      slug     = agent[:slug]
      portrait = existing_portrait(pub_dir, slug)

      if portrait && !force
        out.puts "#{slug.ljust(10)} — skip (#{File.basename(portrait)} exists; FORCE=1 to overwrite)"
        next
      end

      # FORCE against a non-png portrait writes a file the app does not read: the
      # placeholder lands at <slug>.png while the seeded avatar column still points
      # at <slug>.webp. Say so, rather than letting the operator wonder why the page
      # is unchanged.
      if portrait && File.extname(portrait) != ".png"
        out.puts "#{slug.ljust(10)} — WARNING: #{File.basename(portrait)} stays; " \
                 "db/seeds/02_agents.rb reads that file, so this .png placeholder renders nowhere"
      end

      agent_doc_dir = File.join(docs_dir, slug)
      out_pub       = File.join(pub_dir, "#{slug}.png")
      out_docs      = File.join(agent_doc_dir, "avatar.png")

      FileUtils.mkdir_p(agent_doc_dir)
      draw.call(agent, out_pub)
      FileUtils.cp(out_pub, out_docs)

      pub_size  = File.size(out_pub)
      docs_size = File.size(out_docs)
      out.puts "#{slug.ljust(10)} #{agent[:initials].ljust(2)}  #{agent[:bg]}  " \
               "→ #{out_pub} (#{pub_size}b) + #{out_docs} (#{docs_size}b)"
    end

    out.puts "\nDone. Overwrite these files with real portraits when ready."
  end

  def magick(agent, out_pub)
    cmd = [
      "magick",
      "-size",      "#{SIZE}x#{SIZE}",
      "xc:#{agent[:bg]}",
      "-gravity",   "center",
      "-fill",      agent[:fg],
      "-font",      FONT,
      "-pointsize", POINTSIZE.to_s,
      "-annotate",  "0", agent[:initials],
      out_pub
    ]

    abort "magick failed: #{cmd.shelljoin}" unless system(*cmd)
  end
end

if __FILE__ == $PROGRAM_NAME
  AgentAvatarPlaceholders.run(
    root:  ARGV[0] ? File.expand_path(ARGV[0]) : File.expand_path("..", __dir__),
    force: ENV["FORCE"] == "1"
  )
end
