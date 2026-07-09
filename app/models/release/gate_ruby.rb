class Release
  # Pins the ruby the LOCAL pre-QA / ship test gates spawn their suite under to
  # the SAME ruby CI runs (mise 3.3.11), so a gate host whose shell `ruby` is
  # brew's ruby@3.3 doesn't diverge from CI.
  #
  # ROOT CAUSE it closes (verified — rel-38f895, 2026-07-09): the gates spawn
  # `bin/rails test`; that suite's deploy-tooling meta-tests spawn bin/release /
  # bin/dor-check subprocesses whose `#!/usr/bin/env ruby` shebang resolves `ruby`
  # off PATH. On the McRitchie gate host PATH's `ruby` is brew's (the app ruby, by
  # design), whose gem home DIVERGES from mise's → `already initialized constant
  # Gem::Platform::JAVA` at subprocess boot → nonzero exit → the meta-tests
  # false-fail (count varies 3-6 run-to-run). CI runs mise 3.3.11 and is green.
  #
  # THE PIN: run every gate subprocess with mise's ruby bin dir prepended to PATH
  # (an env overlay, NOT an argv wrap — see the note below), so the suite's
  # `#!/usr/bin/env ruby` shebang AND every child it spawns resolve to mise's
  # ruby. `env ruby == mise ruby == CI's ruby`, so the brew/mise gem-home split
  # can't happen. Verified end-to-end (a `bin/rails` boot under the prepend runs
  # under mise's ruby with its gems resolving; a grandchild `command -v ruby` also
  # lands on mise).
  #
  # WHY the env overlay, not `mise exec ruby@#{RUBY_PIN} -- <argv>`: prefixing the
  # argv would change what bin/release's gate spawns, and the deploy-tooling
  # meta-tests key their `sh` stubs on argv[0] (`"bin/rails"` / `"bin/bundle"` /
  # `"ruby"`). Prepending PATH leaves argv untouched (mise's ruby just leads the
  # lookup) — same resolution, no test churn. bin/release's own entrypoint wrapper
  # (bin/release → `mise x ruby@<.ruby-version> -- ruby release.rb`) already pins
  # the conductor; this pins the gate's spawned SUITE too, so it holds even when
  # release.rb is invoked without the wrapper.
  #
  # IO-light (like Release::Repos): pure env/path helpers a caller unit-tests, plus
  # a filesystem probe (resolve_ruby_bin_dir) that degrades to nil (→ the gate
  # falls back to the shell ruby, with a loud note) when the pinned ruby isn't
  # installed — so a mise-less box (e.g. a fresh Mac mid-bringup) never has a
  # release blocked on the pin. Rails-free so bin/release can require it standalone.
  module GateRuby
    module_function

    # The ruby CI provisions via mise — keep in lockstep with `.ruby-version` (the
    # bin/release wrapper's source of truth; a drift is caught by the model spec).
    RUBY_PIN = "3.3.11".freeze

    # PURE. The env overlay that pins a spawned gate subprocess (and every child it
    # spawns) to the mise ruby: prepend `ruby_bin_dir` to PATH so `env ruby`
    # resolves there. Returns {} when `ruby_bin_dir` is blank (the pinned ruby
    # isn't installed) → the caller passes no env and falls back to the shell ruby.
    def env(ruby_bin_dir:, path_env: ENV["PATH"].to_s)
      ruby_bin_dir = ruby_bin_dir.to_s
      return {} if ruby_bin_dir.strip.empty?

      parts = [ruby_bin_dir, path_env.to_s].reject { |p| p.strip.empty? }
      { "PATH" => parts.join(File::PATH_SEPARATOR) }
    end

    # PURE. Where mise installs the pinned ruby — the dir whose presence proves the
    # version is available.
    def install_dir(home: Dir.home)
      File.join(home.to_s, ".local", "share", "mise", "installs", "ruby", RUBY_PIN)
    end

    # PURE. The pinned ruby's bin dir — what must lead PATH so `env ruby` (the
    # `#!/usr/bin/env ruby` shebang path) resolves to mise's ruby.
    def ruby_bin_dir(home: Dir.home)
      File.join(install_dir(home: home), "bin")
    end

    # IO. The mise ruby bin dir to pin the gate to, or nil when the pinned ruby
    # isn't installed on this host (→ the caller warns loudly and falls back to
    # the shell ruby, never blocking a release on a mise-less box).
    def resolve_ruby_bin_dir(home: Dir.home)
      dir = ruby_bin_dir(home: home)
      File.executable?(File.join(dir, "ruby")) ? dir : nil
    end
  end
end
