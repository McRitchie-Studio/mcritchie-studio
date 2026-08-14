# frozen_string_literal: true

# MigrationCollision — "does some OTHER branch already carry the migration I am
# installing, under a different filename?"
#
# THE DEFECT, MEASURED THREE TIMES IN ONE DAY (2026-08-13/14):
#   * turf-monster #312 + #313 — both installed engine migration
#     AddStandardUserProfileColumns (studio_engine original 20260813220000) under
#     DIFFERENT host timestamps. Cost a full review cycle.
#   * mcritchie-studio #853 + #848 — the same shape, caught by hand pre-merge.
#   * turf #312 again, this time against turf's ALREADY-MERGED copy.
#
# WHY GIT DOES NOT SAVE YOU. The two migration FILES have different names, so
# three-way merge sees two unrelated additions and takes both, cleanly. The only
# textual conflict is db/schema.rb — and a careless resolution of THAT leaves the
# repo holding two migrations that share one class name.
#
# WHY THAT IS FATAL AND NOT UNTIDY. Rails groups migrations by CLASS NAME, never by
# filename: `migrations.group_by(&:name).find { |_, v| v.length > 1 }` then
# `raise DuplicateMigrationNameError` (activerecord-8.1.3.1/lib/active_record/
# migration.rb:1567). Validate runs from `pending_migrations`, which db:migrate,
# db:prepare AND the boot guard all call — so both copies landing raises on EVERY
# migrate, INCLUDING the Heroku release phase. It breaks the production deploy, not
# just somebody's laptop.
#
# THE TWO KEYS, and why there are two:
#
#   1. CLASS KEY — parsed from the filename with Rails' OWN regexp
#      (MigrationFilenameRegexp, migration.rb:637): `<version>_<name>.<scope>.rb`.
#      The class Rails groups on is `name.camelize`, so this key IS the failure
#      condition, exactly. It needs no file content, which is what makes the check
#      affordable: `gh pr list --json files` hands over other PRs' PATHS and nothing
#      else, and that is already enough.
#
#   2. ORIGIN KEY — the provenance header `rails <engine>:install:migrations` writes
#      as the copy's FIRST line: `# This migration comes from studio_engine
#      (originally 20260813220000)`. Verified byte-identical across all three
#      incidents' copies. It is the stronger signal where content is readable (my own
#      worktree, and the base ref via `git show`), and it catches the one case the
#      class key misses: an install someone RENAMED, which raises no
#      DuplicateMigrationNameError but still applies one schema change twice.
#
# THE INVARIANT: a collision is two DIFFERENT paths sharing one key. Same path is
# never a collision — that is an edit, and git conflicts on it honestly.
#
# WHY THIS ONE BLOCKS WHERE bin/lib/pr_overlap.rb ADVISES. Same-file overlap is
# normal in a parallel shop and usually harmless, so it warns. A duplicate migration
# class is never harmless and never intended: there is no state of the world where
# shipping two copies is correct. The cure is always available and always the same —
# the task that OWNS the migration keeps it, the other drops its copy — which is how
# all three incidents were actually resolved. And a stale finding self-heals by the
# right action too: an abandoned sibling PR stops matching the moment it is closed,
# because only `--state open` is scanned.
#
# PURE BY CONSTRUCTION: the caller supplies paths and (optionally) first lines, so
# every rule here is unit-testable with no network, no gh, and no git.
module MigrationCollision
  module_function

  # Rails' own filename grammar (activerecord migration.rb:637), so this parser and
  # the raise it predicts can never disagree about what a migration is called.
  FILENAME = /\A([0-9]+)_([_a-z0-9]*)\.?([_a-z0-9]*)?\.rb\z/

  # The first line every install-copied engine migration carries.
  PROVENANCE = /\A#\s*This migration comes from\s+(\S+)\s+\(originally\s+([0-9]+)\)/

  MIGRATION_DIR = "db/migrate"

  # Every path under db/migrate/ that parses as a migration. Anything else in the
  # diff is ignored.
  def migration_paths(paths)
    Array(paths).map(&:to_s).reject(&:empty?).uniq.select { |path|
      dir, base = File.split(path)
      dir.end_with?(MIGRATION_DIR) && FILENAME.match?(base)
    }.sort
  end

  # One migration's identity. `head` is the file's first line when the caller could
  # read it (own worktree, base ref); nil when it could not (another PR's file, where
  # only the path is on offer) — in which case the class key still stands alone.
  #
  # Returns nil for a path that is not a migration, so callers can filter_map.
  def identity(path, head = nil)
    dir, base = File.split(path.to_s)
    return nil unless dir.end_with?(MIGRATION_DIR)

    match = FILENAME.match(base)
    return nil unless match

    version, name, scope = match.captures
    provenance = PROVENANCE.match(head.to_s)
    {
      "path" => path.to_s,
      "version" => version,
      "name" => name,
      "scope" => scope.to_s.empty? ? nil : scope,
      # Rails groups on `name.camelize`; downcased name is the same equivalence class
      # and survives a caller that hands us odd casing.
      "class_key" => name.to_s.downcase,
      "class_name" => camelize(name),
      "engine" => provenance && provenance[1],
      "origin_version" => provenance && provenance[2],
      "origin_key" => provenance && "#{provenance[1]}:#{provenance[2]}"
    }
  end

  def camelize(name)
    name.to_s.split("_").reject(&:empty?).map { |part| part[0].to_s.upcase + part[1..].to_s }.join
  end

  # THE RULE.
  #
  # mine:   [identity, ...] — the migrations this branch ADDS (its diff against base).
  # others: [{ "label" => "the accepted branch", "kind" => "branch"|"pr",
  #            "number" =>, "url" =>, "installs" => [identity, ...] }, ...]
  #
  # Returns one item per colliding pair, class-key matches first (those are the ones
  # that raise), then origin-key matches.
  def report(mine, others)
    ours = Array(mine).compact
    return [] if ours.empty?

    items = []
    Array(others).each do |source|
      Array(source["installs"]).compact.each do |theirs|
        ours.each do |own|
          # Same path is an EDIT, not a duplicate install — and git conflicts on it
          # honestly, so it needs no help from us.
          next if own["path"] == theirs["path"]

          key = matched_key(own, theirs)
          next unless key

          items << {
            "key" => key,
            "mine" => own,
            "theirs" => theirs,
            "label" => source["label"].to_s,
            "kind" => source["kind"].to_s,
            "number" => source["number"],
            "url" => source["url"].to_s
          }
        end
      end
    end
    # The pair is sorted, not ordered, so a WITHIN-branch collision (where both files
    # are on both sides of the comparison) reports once as A↔B rather than twice as
    # A→B and B→A.
    items.uniq { |item| [item["key"], item["label"], [item["mine"]["path"], item["theirs"]["path"]].sort] }
         .sort_by { |item| item["key"] == "class" ? 0 : 1 }
  end

  # "class" when both resolve to one Rails migration class (the condition that
  # raises), "origin" when both were copied from one engine migration (the condition
  # that applies one schema change twice), nil when they are unrelated.
  def matched_key(own, theirs)
    return "class" if present?(own["class_key"]) && own["class_key"] == theirs["class_key"]
    return "origin" if present?(own["origin_key"]) && own["origin_key"] == theirs["origin_key"]

    nil
  end

  def present?(value)
    !value.nil? && value.to_s.strip != ""
  end

  # The operator-facing block. It must answer three questions or it is not
  # actionable: WHICH two files collide, WHICH PR carries the other one, and WHAT to
  # do about it. All three incidents were resolved the same way, so the remedy is
  # stated as the remedy, not as a menu.
  def lines(items)
    return [] if items.empty?

    out = ["DUPLICATE MIGRATION INSTALL — #{items.size} collision(s). This BLOCKS: both copies on one",
           "branch raise ActiveRecord::DuplicateMigrationNameError from EVERY db:migrate, including the",
           "Heroku release phase, so it breaks the production deploy and not just a local run."]
    items.each do |item|
      out << "  #{describe_source(item)}"
      out << "    mine:   #{item["mine"]["path"]}"
      out << "    theirs: #{item["theirs"]["path"]}"
      out << "    #{describe_key(item)}"
    end
    out << "  FIX: the task that OWNS this migration keeps its copy; the other DROPS it"
    out << "  (git rm the file, and revert its db/schema.rb hunk). Do NOT resolve the schema.rb"
    out << "  conflict by keeping both sides — that is exactly how all three 2026-08-13 incidents"
    out << "  happened. If the other PR is abandoned, close it and re-run — only open PRs count."
    out
  end

  def describe_source(item)
    case item["kind"]
    when "pr" then "PR ##{item["number"]}#{item["url"].empty? ? "" : " #{item["url"]}"}"
    when "self" then "WITHIN this branch"
    else item["label"].empty? ? "elsewhere" : item["label"]
    end
  end

  def describe_key(item)
    if item["key"] == "class"
      "same migration CLASS #{item["mine"]["class_name"]} — Rails groups by class name, not filename"
    else
      "same engine migration #{item["mine"]["engine"]} (originally #{item["mine"]["origin_version"]}) " \
        "— one schema change installed twice"
    end
  end

  # A finding is never advisory: every item here is a real duplicate. Kept as a
  # predicate so callers read as intent rather than as `items.any?`.
  def blocking?(items)
    !Array(items).empty?
  end

  # --- gathering (parsers only; the caller owns the subprocesses) --------------
  #
  # Both call sites already have their own shell helper, so the lib takes the OUTPUT
  # rather than running git itself. That keeps every line below testable with a
  # string, and keeps one grammar for parsing git in one place instead of two copies
  # drifting in bin/ship and bin/session-preflight.

  # `git ls-tree -r --name-only <ref> -- db/migrate`
  def parse_ls_tree(output)
    migration_paths(output.to_s.split("\n").map(&:strip))
  end

  # `git grep -z -n -F "This migration comes from" <ref> -- db/migrate`
  # → "<ref>:<path>\0<lineno>\0<text>" per hit. Returns { path => first line }.
  # -z is deliberate: the un-NUL'd form is colon-joined, and a path is free to
  # contain a colon while a NUL never is.
  def parse_grep(output, ref)
    headers = {}
    output.to_s.split("\n").each do |line|
      located, lineno, text = line.split(%(\0), 3)
      next unless lineno.to_s == "1"

      path = located.to_s.delete_prefix("#{ref}:")
      next if path.empty? || headers.key?(path)
      next unless PROVENANCE.match?(text.to_s)

      headers[path] = text
    end
    headers
  end

  # Identities for a set of paths, given whatever headers the caller could read.
  # A path with no header still yields an identity — the class key stands alone,
  # and it is the key that predicts the raise.
  def installs(paths, headers = {})
    migration_paths(paths).filter_map { |path| identity(path, headers[path]) }
  end

  # Every migration on a git REF, with provenance, in two calls. `runner` takes an
  # argv array (git's, minus the `git -C <root>` prefix) and returns stdout — empty
  # on failure, which `git grep` also returns for "no matches". Injected rather than
  # shelled here so this module stays testable without a repo, and so bin/ship and
  # bin/session-preflight cannot drift into two spellings of one query.
  def ref_installs(ref, &runner)
    return [] if ref.to_s.strip.empty?

    tree = runner.call(["ls-tree", "-r", "--name-only", ref, "--", MIGRATION_DIR])
    grep = runner.call(["grep", "-z", "-n", "-F", PROVENANCE_NEEDLE, ref, "--", MIGRATION_DIR])
    installs(parse_ls_tree(tree), parse_grep(grep, ref))
  end

  PROVENANCE_NEEDLE = "This migration comes from"

  # Identities for the migrations a working tree ADDS. `reader` takes a repo-relative
  # path and returns its first line, or nil when the file is not there — a deleted
  # migration is not an install, and reading it as one would invent a collision.
  def local_installs(paths, &reader)
    headers = {}
    present = migration_paths(paths).select { |path|
      head = reader.call(path)
      headers[path] = head.to_s
      !head.nil?
    }
    installs(present, headers)
  end
end
