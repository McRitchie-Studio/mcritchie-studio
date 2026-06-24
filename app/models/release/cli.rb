class Release
  # Pure ARGV-parsing helpers for the `bin/release` CLI. Like Release::GemfileRepin
  # and Release::ShipSequence this is deliberately IO-free and Rails-free: it takes
  # an args array in, mutates it (deleting the consumed flags), and returns the
  # parsed value out — so the flag-consumption logic lives in ONE unit-tested place
  # instead of being mirrored as a handful of top-level `def`s in the shell script.
  # (bin/release `require_relative`s this file directly, so it must load standalone
  # with no Rails dependency.)
  #
  # All three helpers MUTATE `args` (deleting what they consume), mirroring the old
  # in-place ARGV.delete / ARGV.delete_at parsing exactly — so a later subcommand
  # parser never re-sees a flag the dispatcher already handled.
  module Cli
    module_function

    # A boolean flag: delete `flag` from `args`, return whether it was present.
    # Replaces the `ARGV.delete("--x") ? true : false` idiom.
    def take_flag(args, flag)
      !args.delete(flag).nil?
    end

    # A single-value option: delete the FIRST `flag` and the token after it,
    # returning that value (nil if the flag is absent). Mirrors the old opt_value.
    def opt_value(args, flag)
      return nil unless (i = args.index(flag))

      args.delete_at(i)        # drop the flag
      args.delete_at(i)        # drop + return its value (now at the same index)
    end

    # A repeatable option: delete EVERY `flag` + value pair, returning the
    # collected values (nils compacted out). Mirrors the old opt_values.
    def opt_values(args, flag)
      vals = []
      while (i = args.index(flag))
        args.delete_at(i)
        vals << args.delete_at(i)
      end
      vals.compact
    end

    # The positional (non-flag) tokens — the one-or-more task slugs `bin/release
    # merge` accepts. NON-mutating (unlike the flag parsers above): `merge` reads
    # nothing else from args afterward, so there's no consumed-flag to hide from a
    # later parser. Any `-`-prefixed token is treated as a flag and excluded, so a
    # stray flag never lands in the slug list.
    def positional_slugs(args)
      Array(args).reject { |a| a.to_s.start_with?("-") }
    end
  end
end
