class Release
  # Pure text transforms for re-pinning a consumer app's Gemfile from a
  # source-tracking gem line (a feature branch / git / path checkout) back to a
  # published, pessimistic version pin after the gem ships.
  #
  # Deliberately IO-free: no git, no bundle, no File. It takes Gemfile text in
  # and returns Gemfile text (or a boolean/string) out, so the shell wiring that
  # actually reads/writes the file + runs `bundle lock` lives elsewhere and this
  # stays trivially unit-testable.
  #
  # The real consumer shapes this handles:
  #   gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"
  #     — a source ref; `rewrite` re-pins it to the published version.
  #   gem "studio-engine", "~> 0.8"
  #     — a plain version pin. `rewrite` leaves it untouched; the prepare-side
  #       consumer bump reads it (`version_requirements` + `constraint_allows?`)
  #       and `rewrite_pin`s it ONLY when the newly published version escapes
  #       the constraint (a lock-file bump suffices otherwise).
  module GemfileRepin
    module_function

    # "0.9.3" => "~> 0.9" — a major.minor pessimistic constraint (the standard
    # consumer pin: take patch+ updates, hold the minor).
    def pessimistic_constraint(version)
      major, minor = version.to_s.split(".")
      minor ? "~> #{major}.#{minor}" : "~> #{major}"
    end

    # True when the gem's line points at a SOURCE (github:/git:/path:) or a
    # branch:, i.e. it's tracking unpublished code rather than a released
    # version. False when the line is a plain version pin (or the gem is absent).
    def references_branch?(gemfile_text, gem_name)
      line = gem_line_for(gemfile_text, gem_name)
      return false unless line

      source_ref?(line)
    end

    # Replace the gem's source-tracking line with a plain pessimistic pin:
    #   gem "<name>", "~> x.y"
    # Idempotent: a line that's already a plain version/`~>` pin is left exactly
    # as-is (so the whole text returns unchanged). Leading indentation and any
    # trailing comment on the rewritten line are preserved.
    def rewrite(gemfile_text, gem_name, version)
      gemfile_text.to_s.each_line.map do |line|
        if gem_declaration?(line, gem_name) && source_ref?(line)
          rewrite_line(line, gem_name, version)
        else
          line
        end
      end.join
    end

    # The version-requirement strings on the gem's declaration line —
    # `gem "x", "~> 0.10"` → ["~> 0.10"], `gem "x", ">= 1.0", "< 2"` → both.
    # [] for a source-ref line (github:/git:/path:/branch: — no published
    # requirement to read), a bare `gem "x"` line, or an absent gem.
    def version_requirements(gemfile_text, gem_name)
      line = gem_line_for(gemfile_text, gem_name)
      return [] unless line && !source_ref?(line)

      line_args(line, gem_name).filter_map do |arg|
        arg[REQUIREMENT_STRING, 2]
      end
    end

    # Does `version` satisfy the given requirement strings (Gem::Requirement
    # semantics)? An EMPTY requirements list allows anything — a bare `gem "x"`
    # line accepts every version, so a lock-only bump suffices there.
    def constraint_allows?(requirements, version)
      reqs = Array(requirements).map(&:to_s).reject(&:empty?)
      return true if reqs.empty?

      Gem::Requirement.new(*reqs).satisfied_by?(Gem::Version.new(version.to_s))
    rescue ArgumentError
      # A malformed requirement/version can't prove the pin allows the new
      # version — report the escape so the caller rewrites to a known-good pin.
      false
    end

    # Does `version` escape the pin UPWARD — strictly newer than every version the pin
    # names? Only an upward escape may rewrite the pin: a version BELOW the pin's floor is
    # a DOWNGRADE (a backward publish the upstream strictly-newer guard should have blocked),
    # and rewriting the pin down to it is exactly the silent-downgrade bug this exists to
    # refuse. Empty requirements (a bare `gem "x"`) never reach here (constraint_allows? is
    # already true). A malformed requirement/version → false: an unproven escape is never
    # rewritten, so the pin is left as-is rather than risk a downgrade.
    def escapes_upward?(requirements, version)
      reqs = Array(requirements).map(&:to_s).reject(&:empty?)
      return false if reqs.empty?

      new_version = Gem::Version.new(version.to_s.strip)
      pinned = Gem::Requirement.new(*reqs).requirements.map { |(_op, gem_version)| gem_version }
      pinned.any? && new_version > pinned.max
    rescue ArgumentError
      false
    end

    # Replace a plain version-pin line's requirement strings with the pessimistic
    # constraint for `version`, KEEPING every non-requirement option (e.g.
    # `require: false`) plus indentation and any trailing comment:
    #   gem "x", "~> 0.10", require: false  →  gem "x", "~> 0.11", require: false
    # The escape-hatch half of the consumer bump: used only when the published
    # version escapes the existing constraint (see ShipSequence
    # .consumer_bump_action). Source-ref lines are `rewrite`'s job and are left
    # untouched here; idempotent when the pin already reads the target constraint.
    def rewrite_pin(gemfile_text, gem_name, version)
      gemfile_text.to_s.each_line.map do |line|
        if gem_declaration?(line, gem_name) && !source_ref?(line)
          rewrite_pin_line(line, gem_name, version)
        else
          line
        end
      end.join
    end

    # --- the release candidate ----------------------------------------------------
    #
    # Bundler resolves a prerelease only when a requirement names one, and then
    # KEEPS it in the lock for as long as the Gemfile's own requirement admits it.
    # So a candidate enters a consumer's lock through an exact requirement that is
    # on the line only while `bundle lock` resolves (pin_candidate, then
    # drop_candidate), and the committed Gemfile is the one the final would get.
    #
    # One case needs the committed line to change: the final escapes the pin
    # (`1.0.0` over `"~> 0.95"`) or the line is a source ref. The pin the final
    # would get, `"~> 1.0"`, EXCLUDES `1.0.0.rc1`, because a prerelease sorts below
    # its final. There the line carries the same range with the candidate as its
    # floor (candidate_range), and the ship rewrites it to `"~> 1.0"`.

    # `"~> A.B"` for `final`, opened downward to admit `candidate`.
    def candidate_range(candidate)
      final = candidate.to_s.sub(/\.rc\d+\z/, "")
      upper = Gem::Version.new(pessimistic_constraint(final).delete_prefix("~> ")).bump
      [">= #{candidate}", "< #{upper}"]
    end

    # Rewrite the gem's line (a plain pin or a source ref) to candidate_range,
    # keeping a plain pin's options, the indentation and any trailing comment.
    def rewrite_candidate_range(gemfile_text, gem_name, candidate)
      range = candidate_range(candidate).map { |r| "\"#{r}\"" }
      gemfile_text.to_s.each_line.map do |line|
        next line unless gem_declaration?(line, gem_name)

        body    = line.chomp
        keep    = source_ref?(line) ? [] : line_args(line, gem_name).reject { |arg| arg.match?(REQUIREMENT_STRING) }
        "#{body[/\A[ \t]*/]}gem #{["\"#{gem_name}\"", *range, *keep].join(', ')}#{body[/\s*#.*\z/]}#{line[/\r?\n\z/]}"
      end.join
    end

    # The first prerelease version a requirement on the gem's line names, or nil.
    def prerelease_requirement(gemfile_text, gem_name)
      version_requirements(gemfile_text, gem_name)
        .map { |r| r[/\d[\w.\-]*\z/].to_s }
        .find { |v| Gem::Version.correct?(v) && Gem::Version.new(v).prerelease? }
    end

    # A quoted exact candidate requirement, with the comma that leads it.
    CANDIDATE_ARG = /\s*,\s*(['"])=?\s*(\d+\.\d+\.\d+\.rc\d+)\1/

    # The candidate version pinned on the gem's line, or nil.
    def candidate_pin(gemfile_text, gem_name)
      line = gem_line_for(gemfile_text, gem_name)
      line && strip_comment(line)[CANDIDATE_ARG, 2]
    end

    # Add the exact `candidate` to the gem's line, replacing one already there, for
    # the resolve only. It goes after the line's own requirement strings and before
    # its options. A source-ref line is left alone: give it a version line first.
    def pin_candidate(gemfile_text, gem_name, candidate)
      edit_gem_line(gemfile_text, gem_name) do |head, rest|
        rest = rest.sub(CANDIDATE_ARG, "")
        requirements = rest[/\A(?:\s*,\s*(['"])[^'"]*\1)*/]
        "#{head}#{requirements}, \"#{candidate}\"#{rest.delete_prefix(requirements)}"
      end
    end

    # Remove the candidate requirement from the gem's line. Idempotent.
    def drop_candidate(gemfile_text, gem_name)
      edit_gem_line(gemfile_text, gem_name) { |head, rest| "#{head}#{rest.sub(CANDIDATE_ARG, '')}" }
    end

    # Yield (`gem "<name>"`, the code after it) for the gem's plain-pin line and put
    # the block's answer back with the line's comment and ending.
    def edit_gem_line(gemfile_text, gem_name)
      gemfile_text.to_s.each_line.map do |line|
        next line unless gem_declaration?(line, gem_name) && !source_ref?(line)

        code    = strip_comment(line)
        head    = code[/\A[ \t]*gem\s+(['"])#{Regexp.escape(gem_name.to_s)}\1/]
        comment = line.chomp.delete_prefix(code)
        "#{yield(head, code.delete_prefix(head))}#{comment}#{line[/\r?\n\z/]}"
      end.join
    end

    # --- internals -----------------------------------------------------------

    # A quoted version-requirement argument: "~> 0.10", ">= 1.0", "0.8.0".
    # Capture 2 is the requirement text without its quotes.
    REQUIREMENT_STRING = /\A(['"])((?:~>|>=|<=|<|>|!=|=)?\s*\d[\w.\-]*)\1\z/

    # The comma-split arguments AFTER `gem "<name>"` on a declaration line,
    # comments stripped. Good for the plain-pin shapes this module handles
    # (requirement strings + simple `key: value` options); source-ref lines
    # never reach the callers that split.
    def line_args(line, gem_name)
      code = strip_comment(line)
      head = code[/\A[ \t]*gem\s+(['"])#{Regexp.escape(gem_name.to_s)}\1/]
      return [] unless head

      code.delete_prefix(head).split(",").map(&:strip).reject(&:empty?)
    end

    def rewrite_pin_line(line, gem_name, version)
      body    = line.chomp
      indent  = body[/\A[ \t]*/]
      comment = body[/\s*#.*\z/].to_s
      newline = line[/\r?\n\z/].to_s
      keep    = line_args(line, gem_name).reject { |arg| arg.match?(REQUIREMENT_STRING) }
      args    = ["\"#{gem_name}\"", "\"#{pessimistic_constraint(version)}\"", *keep]
      "#{indent}gem #{args.join(', ')}#{comment}#{newline}"
    end

    # The first line that declares `gem "<name>"` (matching quote style), or nil.
    def gem_line_for(gemfile_text, gem_name)
      gemfile_text.to_s.each_line.find { |line| gem_declaration?(line, gem_name) }
    end

    # Does this line declare exactly `gem "<name>"` (not a longer name, not a
    # comment)? The backreference makes the closing quote match the opening one.
    def gem_declaration?(line, gem_name)
      line.match?(/\A[ \t]*gem\s+(['"])#{Regexp.escape(gem_name.to_s)}\1/)
    end

    # Does the line's code (comments stripped) carry a github:/git:/path:/branch:
    # key? `git:` won't false-match inside `github:` — the trailing `:` differs.
    def source_ref?(line)
      strip_comment(line).match?(/\b(?:github|git|path|branch):/)
    end

    def rewrite_line(line, gem_name, version)
      body    = line.chomp
      indent  = body[/\A[ \t]*/]
      comment = body[/\s*#.*\z/].to_s         # trailing comment + its leading space, or ""
      newline = line[/\r?\n\z/].to_s
      "#{indent}gem \"#{gem_name}\", \"#{pessimistic_constraint(version)}\"#{comment}#{newline}"
    end

    # Drop a trailing `# ...` comment (and the whitespace before it) plus the
    # line ending, leaving just the code.
    def strip_comment(line)
      line.chomp.sub(/\s*#.*\z/, "")
    end
  end
end
