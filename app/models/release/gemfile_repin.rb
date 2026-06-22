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
  # The two real consumer shapes this handles:
  #   gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"
  #   gem "studio-engine", "~> 0.8"   (already pinned — left untouched)
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

    # --- internals -----------------------------------------------------------

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
