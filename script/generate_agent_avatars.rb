#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Generate 340x340 placeholder PNGs for agents that don't have a real
# portrait yet. Drops files at:
#   - public/agents/<slug>.png            (used by the Agent model's avatar column)
#   - docs/agents/agents/<slug>/avatar.png (referenced by each persona's role.md)
#
# Style: solid brand-color background + white initial(s) centered. Sized to
# match the existing alex.png (340x340) so the agent grid renders evenly.
#
# Run from repo root:  ruby script/generate_agent_avatars.rb
# Requires ImageMagick 7 (`brew install imagemagick`).
#
# Two-letter initials picked for Shannon/Steffon since they share an "S".

require "fileutils"
require "shellwords"

ROOT      = File.expand_path("..", __dir__)
PUB_DIR   = File.join(ROOT, "public",   "agents")
DOCS_DIR  = File.join(ROOT, "docs", "agents", "agents")

AGENTS = [
  { slug: "shannon",   initials: "Sh", bg: "#06D6A0", fg: "#FFFFFF", note: "UI / mint" },
  { slug: "jasper",    initials: "J",  bg: "#8E82FE", fg: "#FFFFFF", note: "Blockchain / violet" },
  { slug: "carl",      initials: "C",  bg: "#4BAF50", fg: "#FFFFFF", note: "Backend / primary green" },
  { slug: "avi",       initials: "A",  bg: "#FF7C47", fg: "#FFFFFF", note: "Product Owner / orange" },
  { slug: "steffon",   initials: "St", bg: "#475569", fg: "#FFFFFF", note: "Platform Engineer / slate" },
  { slug: "alex-docs", initials: "AD", bg: "#0EA5E9", fg: "#FFFFFF", note: "Documentation reviewer / sky" }
].freeze

SIZE       = 340
# macOS ships Arial Bold at this path; IMv7's font discovery doesn't find
# system fonts by name on this machine, so point at the TTF directly.
FONT       = "/System/Library/Fonts/Supplemental/Arial Bold.ttf"
POINTSIZE  = 180

def magick(*args)
  cmd = ["magick", *args].map(&:to_s)
  unless system(*cmd)
    abort "magick failed: #{cmd.shelljoin}"
  end
end

# Safety: these are PLACEHOLDERS. Several agents already have real portraits
# committed at public/agents/<slug>.png — never clobber them. Only generate
# where the portrait is missing. Pass FORCE=1 to regenerate every placeholder.
FORCE = ENV["FORCE"] == "1"

FileUtils.mkdir_p(PUB_DIR)

AGENTS.each do |a|
  out_pub  = File.join(PUB_DIR,  "#{a[:slug]}.png")
  agent_doc_dir = File.join(DOCS_DIR, a[:slug])
  out_docs = File.join(agent_doc_dir, "avatar.png")

  if File.exist?(out_pub) && !FORCE
    puts "#{a[:slug].ljust(10)} — skip (portrait exists; FORCE=1 to overwrite)"
    next
  end

  FileUtils.mkdir_p(agent_doc_dir)

  magick(
    "-size",        "#{SIZE}x#{SIZE}",
    "xc:#{a[:bg]}",
    "-gravity",     "center",
    "-fill",        a[:fg],
    "-font",        FONT,
    "-pointsize",   POINTSIZE,
    "-annotate",    "0",       a[:initials],
    out_pub
  )

  FileUtils.cp(out_pub, out_docs)

  pub_size  = File.size(out_pub)
  docs_size = File.size(out_docs)
  puts "#{a[:slug].ljust(10)} #{a[:initials].ljust(2)}  #{a[:bg]}  → #{out_pub} (#{pub_size}b) + #{out_docs} (#{docs_size}b)"
end

puts "\nDone. Overwrite these files with real portraits when ready."
