require File.expand_path("../../../bin/lib/bounded_command", __dir__)

class Release
  # COMMIT-LEVEL ship evidence for a release member: is the member's own code an
  # ANCESTOR of the SHA this release actually pushed to `main` in each repo it
  # names? Only then may it be stamped `shipped`.
  #
  # WHY IT EXISTS — 2026-10-28. `moms-app-mail-from-team` (merge d80098f, on moms-app
  # `accepted` and `release`) was a member of rel-20261028-4dcb39 when a concurrent
  # ship ran. That ship pushed moms-app `main` to eb7655f, which did NOT contain
  # d80098f, recorded shipped_shas["moms-app"] = eb7655f, and Release#ship! stamped
  # the member `shipped` + `merged: "main"`. Production kept sending from
  # from@example.com. Release::MemberEvidence could not see it: that guard asks
  # "did this release land ANYTHING on the repo's main?", and it had. It never asked
  # whether the member's commit was in what landed.
  #
  # This module asks that question. The git read is the CLI's (the record side runs
  # on a prod dyno with no clone); the decision is here, IO-free apart from the one
  # optional #git_verdict helper, so the rule is unit-tested in one place.
  #
  # Verdicts are TRI-STATE, like bin/release's ancestor_signal: :affirmed,
  # :refuted, :unknown. Only :affirmed lets a member through. "I could not look" is
  # not "it is there": an unreadable member is held too, with its own note, and
  # `bin/release finalize <release>` re-asks once the read works.
  module MemberContainment
    module_function

    # { slug => note } for every member that must NOT be stamped `shipped`.
    #
    #   groups     — repo_plan-shaped app groups: [{ "repo" =>, "members" => [{ "slug" => }] }]
    #   main_shas  — { repo => sha } this run pushed (or proved live) on `main`
    #   code_shas  — ->(repo, member) { [sha, ...] } the member's merge commit and PR
    #                head in that repo (either one contained is enough), or raises/
    #                returns [] when unreadable
    #   contains   — ->(repo, sha, main_sha) { :affirmed | :refuted | :unknown }
    #
    # A repo with no main SHA is skipped: that is Release::MemberEvidence's case
    # (no landed record at all), and it already holds the member for it.
    def holds(groups:, main_shas:, code_shas:, contains:)
      notes = Hash.new { |hash, key| hash[key] = [] }
      Array(groups).each do |group|
        repo = group["repo"].to_s
        main_sha = main_shas.to_h[repo].to_s.strip
        next if repo.empty? || main_sha.empty?

        Array(group["members"]).each do |member|
          slug = member["slug"].to_s
          # A gem member publishes by version and has no PR in an app repo; asking
          # would hold it as unknown on every run.
          next if slug.empty? || member["kind"].to_s == "gem"

          note = member_note(repo: repo, main_sha: main_sha, member: member,
                             code_shas: code_shas, contains: contains)
          notes[slug] << note if note
        end
      end
      notes.transform_values { |list| list.join(" ") }
    end

    # nil when the member's code is in `main_sha`; otherwise the sentence naming
    # the missing commit.
    def member_note(repo:, main_sha:, member:, code_shas:, contains:)
      slug = member["slug"].to_s
      shas = begin
        clean(code_shas.call(repo, member))
      rescue StandardError => e
        return unknown_note(slug, repo, main_sha, "the PR read failed (#{e.message.to_s[0, 120]})")
      end
      return unknown_note(slug, repo, main_sha, "no merge commit or PR head was found for it") if shas.empty?

      verdicts = shas.map { |sha| contains.call(repo, sha, main_sha) }
      return nil if verdicts.include?(:affirmed)
      return refuted_note(slug, repo, main_sha, shas.first) if verdicts.all?(:refuted)

      unknown_note(slug, repo, main_sha, "git could not read #{shas.map { |s| short(s) }.join(' / ')} against it")
    end

    def refuted_note(slug, repo, main_sha, sha)
      "#{slug}: its #{repo} commit #{short(sha)} is NOT an ancestor of the #{repo} main this release " \
        "shipped (#{short(main_sha)}) — its code missed production, so it keeps its stage and is not " \
        "stamped shipped. Ship it on a release whose #{repo} main contains #{short(sha)}."
    end

    # The fail-closed note for a member the ship never gave a verdict: it joined the
    # release (Release#add reopens an assembled one) after the CLI read its plan.
    def unchecked_note(slug, release_slug)
      "#{slug}: joined #{release_slug} after the ship's containment check read its members, so no " \
        "verdict says its code is in the main this release shipped. Left unstamped; re-run " \
        "`bin/release finalize #{release_slug}`, which re-reads the members and checks it."
    end

    def unknown_note(slug, repo, main_sha, why)
      "#{slug}: could not prove its #{repo} code is in the #{repo} main this release shipped " \
        "(#{short(main_sha)}) — #{why}. Left unstamped; re-run `bin/release finalize` once it reads."
    end

    # The member's candidate SHAs from a `gh pr view --json mergeCommit,headRefOid`
    # payload: the merge commit first (the name the note uses), then the PR head.
    def shas_from_pr(json)
      return [] unless json.is_a?(Hash)

      merge = json["mergeCommit"].is_a?(Hash) ? json["mergeCommit"]["oid"] : nil
      clean([ merge, json["headRefOid"] ])
    end

    # The git half, for the CLI: is `sha` an ancestor of `main_sha` in the clone at
    # `path`? `merge-base --is-ancestor` exits 1 for "no" and 128 for a fault, so
    # both refs are resolved first and only a clean 1 answers :refuted. A sha the
    # clone lacks is fetched once by id before giving up.
    #
    # BOUNDED. This runs AFTER production is deployed, and the fetch goes through the
    # 1Password-backed credential helper, which has hung ~15 minutes. Every call is
    # killed at `deadline` seconds (the CLI passes its read deadline), and a killed
    # call answers :unknown — a hold with a note, never a wedged ship.
    def git_verdict(path:, sha:, main_sha:, deadline: DEFAULT_DEADLINE, runner: nil)
      runner ||= ->(dir, *args) { git(dir, *args, deadline: deadline) }
      return :unknown unless readable?(path, main_sha, runner)
      unless readable?(path, sha, runner)
        runner.call(path, "fetch", "--quiet", "origin", sha)
        return :unknown unless readable?(path, sha, runner)
      end

      _out, status = runner.call(path, "merge-base", "--is-ancestor", sha, main_sha)
      case status
      when 0 then :affirmed
      when 1 then :refuted
      else :unknown
      end
    end

    def readable?(path, ref, runner)
      _out, status = runner.call(path, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      status.zero?
    end

    DEFAULT_DEADLINE = 60

    # [stdout+stderr, exitstatus]; -1 for a killed (timed out) or unspawnable call,
    # which every caller reads as a fault. GIT_TERMINAL_PROMPT=0 so a credential
    # prompt fails instead of waiting for a keyboard nobody is at.
    def git(path, *args, deadline: DEFAULT_DEADLINE)
      out, result = BoundedCommand.capture2e({ "GIT_TERMINAL_PROMPT" => "0" }, "git", "-C", path.to_s, *args,
                                             deadline: deadline)
      return [ out, -1 ] if result.timed_out?

      [ out, result.exitstatus || -1 ]
    rescue SystemCallError => e
      [ e.message, -1 ]
    end

    def clean(values)
      Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
    end

    def short(sha)
      sha.to_s[0, 7]
    end
  end
end
