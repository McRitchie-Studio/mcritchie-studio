# frozen_string_literal: true

# `class Release`, not `module` — Release is an ActiveRecord model, and reopening
# it as a module raises TypeError before a single test runs.
class Release
  # Installing a published ENGINE's migrations into each consumer, during the
  # sweep, in the same commit that bumps that consumer's lock.
  #
  # WHY THE SWEEP DOES THIS AT ALL. `<engine>:install:migrations` is a MANUAL step
  # Rails hands the consuming app, and every consumer asserts it was taken
  # (EnginePinContractTest). The sweep publishes the gem to RubyGems —
  # irreversible — and commits the lock bump BEFORE the pre-QA gate runs those
  # suites, so an engine release that adds a migration reddens every consumer
  # after the point of no return. Measured on studio-engine PR 169: that assertion
  # fired in all three consumer lanes, five commits running.
  #
  # THIS FILE IS THE DECISIONS; bin/release.rb runs the commands. That split is
  # not tidiness — it is the review finding that produced it. The first cut put
  # the whole thing in the shell, and its probe was FAIL-OPEN: any non-zero
  # `bin/rails -T` read as "this gem is not an engine", so a workspace whose
  # bundle was not installed skipped the step silently, printing nothing, while
  # the SOP told the operator migrations were handled. Two reviewers reproduced
  # it. Every branch below is now a value a test can hold.
  module EngineMigrationInstall
    module_function

    # Rails' own convention for an engine's railtie namespace — `studio-engine`
    # installs with `studio_engine:install:migrations`. Whether that task EXISTS
    # is asked, never assumed: most published gems are not engines.
    def install_task(gem_name)
      return nil if gem_name.to_s.strip.empty?

      "#{gem_name.to_s.tr('-', '_')}:install:migrations"
    end

    # What `bin/rails -T <task>` just told us. THE DISTINCTION THIS EXISTS FOR:
    #
    #   * exit 0, task listed        -> :present     install it
    #   * exit 0, nothing listed     -> :absent      not an engine; skip, silently
    #   * NON-ZERO                   -> :unbootable  the app did not boot at all
    #
    # The third case is the one that shipped wrong. `bundle lock` resolves without
    # INSTALLING, and nothing else in the sweep installs the version it just
    # pushed, so `require "bundler/setup"` raises Bundler::GemNotFound and rails
    # exits 1 — indistinguishable, to a fail-open probe, from a gem that simply
    # ships no migrations. A missing master.key and a broken bundle land here too.
    # The caller ABORTS on :unbootable: in a function whose whole design is
    # fail-closed, "I could not tell" must never read as "nothing to do".
    def probe_verdict(ok:, output:, task:)
      return :unbootable unless ok
      return :absent if task.to_s.empty?

      output.to_s.include?(task) ? :present : :absent
    end

    # The database the schema dump may use, derived from the one the gate would
    # use for this repo.
    #
    # Postgres apps get a THROWAWAY database of their own — named for the repo and
    # this process, so two sweeps (or a sweep and a developer) can never collide,
    # and never the shared `<app>_test`. A SQLITE app (rolio) gets nil, which
    # leaves DATABASE_URL unset so the app's own database.yml points at a file
    # inside the workspace — private by construction. Handing a postgres:// URL to
    # a SQLite app is a live trap this repo already warns about elsewhere, which
    # is why the base URL comes from gate_database_url rather than being built by
    # hand.
    def throwaway_database_url(base_url:, repo:, pid:)
      return nil if base_url.to_s.strip.empty?

      uri = URI.parse(base_url)
      uri.path = "/#{repo.to_s.tr('-', '_')}_release_schema_#{pid}"
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    # Is this `db/schema.rb` diff one the sweep may commit unreviewed?
    #
    # Installing a migration should ADD a table and move the version stamp.
    # Anything else — a dropped table, a changed column, a rewritten index — means
    # the consumer's committed schema was already out of step with its own
    # migrations, and the sweep would be smuggling that drift into a release
    # commit labelled "bump gem for QA". Fail closed and let a person look.
    #
    # The version line is the one deletion that is always expected, since the
    # dumper rewrites `define(version: ...)` in place.
    #
    # THE ONE OTHER TOLERATED DELETION: a `t.check_constraint` line that Postgres
    # re-prints after `db:schema:load`. Postgres stores a check constraint as a
    # parsed tree and dumps it by DEPARSING that tree, so the text it gives back can
    # differ from the text it was given while the meaning is identical. Measured on
    # turf-monster `users_role_known` (2026-11-08), a varchar `role IN (...)`:
    #
    #   ARRAY['viewer'::character varying, 'admin'::character varying]::text[]
    #   ARRAY['viewer'::character varying::text, 'admin'::character varying::text]
    #
    # Such a line passes only when ALL of these hold, and each one fails closed:
    #   * an added `t.check_constraint` line carries the SAME name and the SAME
    #     options (only the expression text moved);
    #   * that name is unique among the removed lines, the added lines, and each
    #     side's schema, and both sides put it on the SAME table;
    #   * the `equivalent:` callable says Postgres reads both expressions to the
    #     same text (see check_equivalence_statements). No callable, no tolerance.
    #
    # `equivalent:` receives (table:, old_expr:, new_expr:) and returns true only on
    # proof; bin/release.rb hands it a psql run against the throwaway database the
    # dump just migrated.
    def schema_dump_safe?(diff_text, old_schema: nil, new_schema: nil, equivalent: nil)
      unsafe_removals(diff_text, old_schema: old_schema, new_schema: new_schema, equivalent: equivalent).empty?
    end

    # The removed lines schema_dump_safe? refuses, in diff order, each with its
    # leading "-". Empty means the diff is safe.
    def unsafe_removals(diff_text, old_schema: nil, new_schema: nil, equivalent: nil)
      lines = diff_text.to_s.lines
      removals = lines.select { |line| removal?(line) }
      additions = lines.select { |line| addition?(line) }

      removed_checks = removals.filter_map { |line| parse_check_constraint(line.delete_prefix("-")) }
      added_checks = additions.filter_map { |line| parse_check_constraint(line.delete_prefix("+")) }

      removals.reject do |line|
        version_line?(line) ||
          tolerated_check_rewrite?(line, removed_checks, added_checks, old_schema, new_schema, equivalent)
      end
    end

    def removal?(line) = line.start_with?("-") && !line.start_with?("---")
    def addition?(line) = line.start_with?("+") && !line.start_with?("+++")

    # The evidence for a refusal: every unsafe removed line, and beside it the
    # lines its hunk added (what the line was rewritten AS), in diff order. A
    # hunk with no unsafe removal is left out, so an added table never buries the
    # cause. The version line is left out too.
    def unsafe_change_lines(diff_text, old_schema: nil, new_schema: nil, equivalent: nil)
      unsafe = unsafe_removals(diff_text, old_schema: old_schema, new_schema: new_schema, equivalent: equivalent)
      return [] if unsafe.empty?

      diff_hunks(diff_text).flat_map do |hunk|
        next [] unless hunk.any? { |line| unsafe.include?(line) }

        hunk.select { |line| unsafe.include?(line) || (addition?(line) && !version_line?(line)) }
            .map(&:chomp)
      end
    end

    # A unified diff's changed lines, grouped by `@@` hunk.
    def diff_hunks(diff_text)
      diff_text.to_s.lines.slice_before { |line| line.start_with?("@@") }
               .map { |hunk| hunk.select { |line| removal?(line) || addition?(line) } }
               .reject(&:empty?)
    end

    # --- naming the cause ----------------------------------------------------
    #
    # The 2026-11-08 sweep refused engine 0.138.0's NOT NULL migrations in six
    # consumers, and its message said only "this repo's committed schema was
    # already behind its own migrations" -- wrong on the cause, and silent on which
    # migration and which lines. So the dump runs in STAGES: first the consumer's
    # own migrations on top of its committed schema, then each newly installed
    # engine migration alone, dumping after each. Every stage's diff is judged on
    # its own, so a refused line is charged to the stage that produced it.

    # The migration version a db/migrate path or porcelain line names, or nil.
    def migration_version(path)
      File.basename(path.to_s.strip.split.last.to_s)[/\A(\d+)_/, 1]
    end

    # The stages the dump runs, in order. Each is { engine_migration:, tasks:,
    # version: }: run `bin/rails *tasks` with VERSION=version (nil: no VERSION).
    #
    #   * stage one loads the committed schema and migrates to the consumer's own
    #     newest migration (engine_migration nil). With no consumer migration at
    #     all it only re-dumps the loaded schema; `VERSION=0` would migrate DOWN.
    #   * then one stage per newly installed engine migration, oldest first.
    #
    # FAIL CLOSED to one unattributed stage (the pre-2026-11-09 behaviour, every
    # pending migration at once) when the staging cannot be trusted: no engine
    # file, or an engine version not above every consumer version (then
    # VERSION=<consumer newest> would skip or reorder it).
    def dump_stages(migration_files:, engine_files:)
      engine = engine_files.map { |path| File.basename(path.to_s.strip.split.last.to_s) }
                           .select { |name| migration_version(name) }.uniq
                           .sort_by { |name| migration_version(name).to_i }
      engine_versions = engine.map { |name| migration_version(name) }
      consumer = migration_files.filter_map { |path| migration_version(path) }.uniq - engine_versions
      newest = consumer.max_by(&:to_i)

      load_tasks = %w[db:create db:schema:load]
      if engine.empty? || (newest && engine_versions.any? { |version| version.to_i <= newest.to_i })
        return [{ engine_migration: nil, tasks: load_tasks + %w[db:migrate], version: nil, unattributed: true }]
      end

      first = if newest
                { engine_migration: nil, tasks: load_tasks + %w[db:migrate], version: newest }
              else
                { engine_migration: nil, tasks: load_tasks + %w[db:schema:dump], version: nil }
              end
      [first] + engine.map { |name| { engine_migration: name, tasks: %w[db:migrate], version: migration_version(name) } }
    end

    # The abort message for a dump the guard refuses, or nil when every stage is
    # safe. `stages` are dump_stages entries, each merged with the diff it
    # produced and the schema text on each side of it (diff:, old_schema:,
    # new_schema:). The message names the cause per stage: a stale committed
    # schema, or the engine migration that altered an existing table.
    def schema_refusal(repo, stages, equivalent: nil)
      refused = stages.filter_map do |stage|
        lines = unsafe_change_lines(stage[:diff], old_schema: stage[:old_schema], new_schema: stage[:new_schema],
                                                  equivalent: equivalent)
        [stage, lines] unless lines.empty?
      end
      return nil if refused.empty?

      parts = ["#{repo}: refreshing db/schema.rb removed or rewrote existing schema, not just new tables. " \
               "The sweep stops here; nothing was committed."]
      refused.each { |stage, lines| parts << refusal_section(stage, lines) }
      parts.join("\n\n")
    end

    def refusal_section(stage, lines)
      evidence = lines.map { |line| "      #{line}" }.join("\n")
      if stage[:unattributed]
        "  The consumer's own pending migrations and the new engine migrations ran together (they could not be " \
          "staged), so this cannot say which one changed these db/schema.rb lines:\n#{evidence}\n" \
          "  Read db/migrate for the change, fix it, then re-run `bin/release prepare`."
      elsif stage[:engine_migration]
        "  Engine migration #{stage[:engine_migration]} changed existing db/schema.rb lines:\n#{evidence}\n" \
          "  An engine migration that alters an existing table cannot ride the sweep's unreviewed bump commit. " \
          "The gem is already published, and a rollback runs the previous release's code against the altered " \
          "table (a new NOT NULL breaks every old insert that leaves the column empty). Make the engine " \
          "migration additive (nullable, backfilled), tighten it in a later release, then re-run " \
          "`bin/release prepare`."
      else
        "  Before any engine migration ran, this repo's committed db/schema.rb was behind its own migrations. " \
          "Loading it and running this repo's migrations changed these lines:\n#{evidence}\n" \
          "  Commit the schema this repo's migrations produce, then re-run `bin/release prepare`."
      end
    end

    def version_line?(line)
      line.include?("ActiveRecord::Schema") && line.include?("define(version:")
    end

    def tolerated_check_rewrite?(line, removed_checks, added_checks, old_schema, new_schema, equivalent)
      return false unless equivalent

      old = parse_check_constraint(line.delete_prefix("-"))
      return false unless old

      same_name_removed = removed_checks.select { |check| check[:name] == old[:name] }
      same_name_added = added_checks.select { |check| check[:name] == old[:name] }
      return false unless same_name_removed.length == 1 && same_name_added.length == 1

      new = same_name_added.first
      return false unless new[:options] == old[:options]

      table = check_constraint_table(old_schema, old[:name])
      return false if table.nil? || table != check_constraint_table(new_schema, old[:name])

      equivalent.call(table: table, old_expr: old[:expr], new_expr: new[:expr]) == true
    rescue StandardError
      false
    end

    CHECK_CONSTRAINT_LINE = /\A\s*t\.check_constraint\s+("(?:[^"\\]|\\.)*")(.*)\z/m
    NAME_OPTION = /\bname:\s*("(?:[^"\\]|\\.)*")/

    # `t.check_constraint "<expr>", name: "<name>"[, validate: false]` -> its parts,
    # or nil for any other line. The dumper writes both strings with #inspect, so
    # #undump reads them back exactly; a string it cannot read is not a match.
    def parse_check_constraint(line)
      match = CHECK_CONSTRAINT_LINE.match(line.to_s.chomp)
      return nil unless match

      options = match[2].strip
      name = NAME_OPTION.match(options)
      return nil unless name

      { expr: match[1].undump, name: name[1].undump, options: options }
    rescue RuntimeError
      nil
    end

    # The table whose `create_table` block holds the check constraint `name`, or nil
    # when the schema has none or more than one (a name Postgres scopes per table
    # can repeat across tables, and a guess there would be fail-open).
    def check_constraint_table(schema_text, name)
      table = nil
      found = []
      schema_text.to_s.each_line do |line|
        if (create = /\A\s*create_table\s+("(?:[^"\\]|\\.)*")/.match(line))
          table = create[1].undump
        elsif (check = parse_check_constraint(line)) && check[:name] == name
          found << table
        end
      end
      found.length == 1 ? found.first : nil
    rescue RuntimeError
      nil
    end

    # SQL that asks Postgres whether two check expressions on `table` mean the same
    # thing. Run it, in order, inside a transaction that is rolled back, against a
    # database that already holds `table`; the LAST statement selects one boolean.
    #
    # THE METHOD. A scratch temp table copies `table`'s columns (LIKE), and each
    # expression is added to it as a CHECK and read back with pg_get_constraintdef.
    # That read-back is re-added and read again until the text stops changing (at
    # most four passes), because one pass is not always a fixed point: measured on
    # Postgres 14, `role IN ('viewer','admin')` reads back as the `::text[]` form,
    # which reads back as the per-element `::text` form, which is stable.
    # Deparse-then-parse is the round trip pg_dump relies on to preserve meaning, so
    # two expressions that settle on the same text are the same expression; a
    # changed meaning ('owner' added) settles on different text and is refused.
    #
    # The expressions are the consumer's own committed schema text, run on a
    # throwaway database the sweep created and drops; they are passed into the DO
    # block as SQL string literals, never spliced into its body.
    DO_TAG = "$release_schema_eq$"

    def check_equivalence_statements(table:, old_expr:, new_expr:)
      # The one text that could close the DO block's dollar quote. It never occurs
      # in a real schema; refuse rather than escape.
      if [old_expr, new_expr].any? { |expr| expr.to_s.include?(DO_TAG) }
        raise ArgumentError, "check expression contains #{DO_TAG}"
      end

      [
        "SET LOCAL standard_conforming_strings = on",
        "CREATE TEMP TABLE release_schema_eq_scratch (LIKE #{quote_ident(table)}) ON COMMIT DROP",
        "CREATE TEMP TABLE release_schema_eq_result (side text PRIMARY KEY, def text NOT NULL) ON COMMIT DROP",
        <<~SQL.strip,
          DO #{DO_TAG}
          DECLARE
            sides text[] := ARRAY['old', 'new'];
            exprs text[] := ARRAY[#{quote_literal(old_expr)}, #{quote_literal(new_expr)}];
            current_def text;
            next_def text;
            constraint_name text;
          BEGIN
            FOR side_index IN 1..2 LOOP
              current_def := 'CHECK (' || exprs[side_index] || ')';
              FOR pass IN 1..4 LOOP
                constraint_name := 'release_schema_eq_' || sides[side_index] || '_' || pass;
                EXECUTE format('ALTER TABLE release_schema_eq_scratch ADD CONSTRAINT %I %s', constraint_name, current_def);
                SELECT pg_get_constraintdef(oid) INTO next_def FROM pg_constraint
                  WHERE conrelid = 'release_schema_eq_scratch'::regclass AND conname = constraint_name;
                EXIT WHEN next_def = current_def;
                current_def := next_def;
              END LOOP;
              INSERT INTO release_schema_eq_result VALUES (sides[side_index], current_def);
            END LOOP;
          END
          #{DO_TAG}
        SQL
        "SELECT (SELECT def FROM release_schema_eq_result WHERE side = 'old') = " \
        "(SELECT def FROM release_schema_eq_result WHERE side = 'new') AS equivalent"
      ]
    end

    # The whole check as one psql script: the statements above between BEGIN and
    # ROLLBACK, so nothing it creates outlives the run.
    def check_equivalence_script(**kwargs)
      (["BEGIN"] + check_equivalence_statements(**kwargs) + ["ROLLBACK"]).map { |sql| "#{sql};\n" }.join
    end

    # What `psql -At` printed for that script: only a clean exit whose answer is
    # the boolean true counts as proof.
    def equivalence_verdict(ok:, output:)
      ok && output.to_s.lines.map(&:strip).reject(&:empty?).last == "t"
    end

    def quote_ident(name)
      %("#{name.to_s.gsub('"', '""')}")
    end

    def quote_literal(text)
      "'#{text.to_s.gsub("'", "''")}'"
    end
  end
end
