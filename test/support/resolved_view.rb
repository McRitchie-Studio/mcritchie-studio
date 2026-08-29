# frozen_string_literal: true

# ResolvedView — answer "which FILE does this app actually render?" and
# "is that file a local shadow?", in one place.
#
# WHY THIS EXISTS AT ALL. studio-engine is a NON-ISOLATED Rails engine and does
# not prepend_view_path, so an app view at the SAME PATH silently WINS the
# lookup. Nothing warns. The app keeps rendering its own copy, gem bumps deliver
# nothing to that path, and the divergence is invisible to every test that reads
# a file by name — because reading Rails.root.join(...) asserts the fork is
# CORRECT rather than noticing it is THERE. That is how this app's modal-host
# fork survived months of engine fixes.
#
# So: resolve first, then assert. `resolve` returns the identifier Rails itself
# picked, which is the only honest answer to "what does this page render".
module ResolvedView
  module_function

  # The absolute path of the template this app resolves for `prefix/name`.
  # Same call the acceptance proof uses, so the test and the proof cannot drift.
  def resolve(name, prefix)
    ApplicationController.new.lookup_context.find(name, [ prefix ], true).identifier
  end

  # Is this identifier free of a local shadow?
  #
  # DELIBERATELY NOT "is it under /gems/". That question names an INSTALL MODE,
  # not the defect. studio-engine's own consumer-CI lane bundles the engine as a
  # PATH CHECKOUT and resolves the same correct partial from
  # /home/runner/work/studio-engine/studio-engine/studio/... — an assertion on
  # "/gems/" is green here and IMPOSSIBLE there, so it goes red on the release
  # tip a gem publish pushes. A consumer assertion then red-seals the PRODUCER's
  # release. That happened for real on 2026-08-28
  # (/tasks/fix-picker-gem-path-assertion).
  #
  # Both install modes are legitimate. A local fork is not. Name that.
  def shadow_free?(identifier)
    !identifier.to_s.start_with?(Rails.root.join("app/views").to_s)
  end

  # The source of whatever template actually renders — a fork if one is
  # shadowing, the gem otherwise. Every assertion about host BEHAVIOUR reads
  # through this, so it describes the file on the page rather than a file that
  # happens to sit at a path.
  def source(name, prefix)
    Pathname(resolve(name, prefix)).read
  end
end
