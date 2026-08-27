# frozen_string_literal: true

# BootGemDiagnosis — turn a raw `Bundler::GemNotFound` at boot into the one
# sentence that actually fixes it.
#
# THE LOOP THIS EXPLAINS. `bin/release ship` publishes the gem and fast-forwards
# `main` by REF PUSH — deliberately, "no checkout, no working tree", which is what
# makes shipping safe to run from anywhere. The consequence is that no checkout on
# this machine has the newly published gem installed. The moment a primary's tree
# catches up to main, its Gemfile.lock pins a version that is not in the local gem
# home, and EVERY Rails-booting script there dies at config/boot.rb.
#
# WHY IT NEEDED A MESSAGE. The failure names no cause. It is a Bundler stack trace
# with no mention of a release, it surfaces in a command unrelated to deploys
# (measured: `bin/reviewer-select`, mid-review), and it reaches an agent who has no
# reason to connect it to a release another session ran minutes earlier. Two
# reviewers lost time to it on 2026-08-26 and NEITHER diagnosed the cause; both
# worked around it instead. One `bundle install` fixes it.
module BootGemDiagnosis
  MISSING = /Could not find ([A-Za-z0-9_.-]+?)-(\d[\w.]*) in locally installed gems/

  module_function

  # The gem and version Bundler could not find, or nil when the message is not
  # the shape we know. nil means "say the general thing", never "guess".
  def missing_gem(message)
    match = MISSING.match(message.to_s)
    return nil unless match

    { name: match[1], version: match[2] }
  end

  def explain(message, root: Dir.pwd)
    missing = missing_gem(message)
    subject = missing ? "#{missing[:name]} #{missing[:version]}" : "a gem this checkout pins"

    <<~TEXT
      ────────────────────────────────────────────────────────────────────────
      This looks like a RELEASE, not a broken checkout.

        missing: #{missing ? "#{missing[:name]}-#{missing[:version]}" : "(see the error below)"}

      `bin/release ship` publishes the gem and fast-forwards main by REF PUSH —
      it never installs anything into a local checkout. So once this tree caught
      up to main, its Gemfile.lock started pinning #{subject}, which is not in
      this machine's gem home. Every Rails-booting script here fails the same way
      until the bundle is installed, in commands that have nothing to do with
      deploys.

        fix:  (cd #{root} && bundle install)

      The original error follows.
      ────────────────────────────────────────────────────────────────────────
    TEXT
  end
end
