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
  # `bin/release finalize <release>` re-asks once the read works. "Unreadable" means
  # neither read answered: a PR GitHub will not show the ship's token falls back to
  # git (fallback_shas, member_shas) before it is held.
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
    #   fallback_shas — optional ->(repo, member) { [sha, ...] }: the member's SHAs
    #                read from GIT (the PR's refs/pull/<n>/head) when code_shas
    #                could not read GitHub. See member_shas.
    #
    # A repo with no main SHA is skipped: that is Release::MemberEvidence's case
    # (no landed record at all), and it already holds the member for it.
    def holds(groups:, main_shas:, code_shas:, contains:, fallback_shas: nil)
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
                             code_shas: code_shas, contains: contains, fallback_shas: fallback_shas)
          notes[slug] << note if note
        end
      end
      notes.transform_values { |list| list.join(" ") }
    end

    # nil when the member's code is in `main_sha`; otherwise the sentence naming
    # the missing commit.
    def member_note(repo:, main_sha:, member:, code_shas:, contains:, fallback_shas: nil)
      slug = member["slug"].to_s
      shas, why_unread = member_shas(repo, member, code_shas, fallback_shas)
      return unknown_note(slug, repo, main_sha, why_unread) if shas.empty?

      verdicts = shas.map { |sha| contains.call(repo, sha, main_sha) }
      return nil if verdicts.include?(:affirmed)
      return refuted_note(slug, repo, main_sha, shas.first) if verdicts.all?(:refuted)

      unknown_note(slug, repo, main_sha, "git could not read #{shas.map { |s| short(s) }.join(' / ')} against it")
    end

    # [shas, why] — the member's candidate SHAs, and the reason when there are none.
    #
    # WHY A GIT FALLBACK — rel-20261029-00560a. The ship runs under the DEPLOYER
    # App's token, and on voicebox and alex-build that App may push `main` but may
    # not read pull requests: `gh pr view` answered "Resource not accessible by
    # integration" for four members whose merge commits WERE in the main just
    # pushed, and all four were held at `assembled`. "GitHub would not answer" is
    # not "the code is missing", so when the PR read fails the SHAs are read from
    # git instead (the same credential that just pushed `main`). Every PR merges
    # with `--merge`, so a merged PR's head is an ancestor of the main it landed
    # in: a git-read head that is NOT one is a genuine refutation and still holds.
    def member_shas(repo, member, code_shas, fallback_shas)
      shas = []
      why = nil
      begin
        shas = clean(code_shas.call(repo, member))
        why = "no merge commit or PR head was found for it" if shas.empty?
      rescue StandardError => e
        why = "the PR read failed (#{e.message.to_s[0, 120]})"
      end
      return [ shas, nil ] unless shas.empty?
      return [ [], why ] unless fallback_shas

      fallback = begin
        clean(fallback_shas.call(repo, member))
      rescue StandardError => e
        return [ [], "#{why}, and the git fallback failed too (#{e.message.to_s[0, 80]})" ]
      end
      return [ fallback, nil ] unless fallback.empty?

      [ [], "#{why}, and git found no PR head or branch for it either" ]
    end

    # The PR number in a GitHub pull-request URL, or nil.
    def pr_number(url)
      url.to_s[%r{/pull/(\d+)\b}, 1]
    end

    # The git half of the fallback: the member's PR head (refs/pull/<n>/head, which
    # GitHub keeps for every PR, merged or not, after its branch is deleted), read by
    # `git ls-remote` in the clone at `path`. [] without a recorded PR URL: a bare
    # branch tip proves nothing (a branch pushed at a commit main already holds is an
    # ancestor with no code), and GitHub's path asked for a MERGED PR. Bounded like
    # git_verdict; a killed call reads as [].
    def git_fallback_shas(path:, member:, repo:, deadline: DEFAULT_DEADLINE, runner: nil)
      runner ||= ->(dir, *args) { git(dir, *args, deadline: deadline) }
      number = pr_number(member.dig("pr_urls", repo))
      return [] unless number

      ref = "refs/pull/#{number}/head"
      out, status = runner.call(path, "ls-remote", "origin", ref)
      return [] unless status.zero?

      clean(out.to_s.lines.filter_map { |line| sha, name = line.split(/\s+/); sha if name == ref && sha =~ /\A\h{40}\z/ })
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
