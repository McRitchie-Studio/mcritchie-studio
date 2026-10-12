# frozen_string_literal: true

require "json"
require_relative "../checks"
require_relative "../../program_drift"
require_relative "../../task_pr_set"
require_relative "../../ci_status"

# PROGRAM UPGRADE CARDS — a program version bump does not merge without its upgrade
# cards on the board.
#
# WHY. turf-vault v0.26 merged to main on 2026-10-11 and no card existed to upgrade
# either cluster: the release lane ships apps, never on-chain programs, so the bump
# reached main and stopped there. This check makes the bump itself file the work.
# When a PR changes a configured program's version (config/onchain_programs.yml),
# every cluster's upgrade card (the program's `card_slug`, e.g. devnet-v026-upgrade
# and mainnet-v026-upgrade) must exist and not be archived, or the gate refuses.
#
# WHERE IT RUNS. A merge-phase check, so it runs in BOTH dor-check roles: the
# builder's at bin/submit (the move to `submitted`) and the reviewer's gate-zero
# (`bin/dor-check <slug> --gate-role review`, pr-review-primary.md step 3), which
# every PR passes before a merge into `accepted` and the move to `reviewed`. A
# turf-vault PR is graded from its own PR file list, wherever the gate stands.
#
# FAIL CLOSED. A version change it cannot read, or a board it cannot ask, is an error,
# never a pass.
module Dor
  module Checks
    class ProgramUpgradeCards < Base
      # DOR_CHECK_PROGRAM_VERSIONS is the test seam: a JSON object of program name ->
      # [base_version, head_version], standing in for the GitHub reads below.
      SEAM = "DOR_CHECK_PROGRAM_VERSIONS"

      def self.phase
        :merge
      end

      def call(context)
        @context = context
        ProgramDrift.programs.each do |program|
          next unless context.changed_files.include?(program.version_file)

          from, to = version_change(program)
          next if to && from && Gem::Version.new(to) <= Gem::Version.new(from)

          refuse_without_cards(program, from, to)
        end
      end

      private

      attr_reader :context

      def refuse_without_cards(program, from, to)
        unless to
          context.error("program version bump: #{program.name}'s #{program.version_file} changed, but its new " \
                        "version could not be read (#{@read_error || 'no reading'}). Without it this gate cannot " \
                        "name the upgrade cards the bump owes, so it refuses rather than pass it")
          return
        end

        slugs = program.clusters.map { |c| ProgramDrift.card_slug(program, c.name, to) }
        missing = slugs.reject { |slug| open_card?(slug) }
        return if missing.empty?

        context.error("program version bump: #{program.name} #{from ? "v#{from}" : '(new)'} → v#{to} needs an " \
                      "upgrade card per cluster on the board before it merges; missing: #{missing.join(', ')}. " \
                      "File each with `bin/task begin --title \"#{title_for(missing.first)}\" --repo " \
                      "#{program.github.split('/').last} --kind chore …` (#{ProgramDrift::SOP})")
      end

      def open_card?(slug)
        card = context.board_task(slug)
        card.is_a?(Hash) && card["stage"].to_s != "archived"
      end

      def title_for(slug)
        slug.split("-").map(&:capitalize).join(" ")
      end

      # [base_version, head_version] of the program's version file in this change.
      # head nil means unreadable (with @read_error saying why); base nil is a new file.
      def version_change(program)
        if (seam = ENV[SEAM])
          return Array(JSON.parse(seam)[program.name])
        end

        target = TaskPrSet.targets(context.devops).find do |t|
          t[:readable] && t[:repo].to_s.casecmp?(program.github.split("/").last)
        end
        return pr_versions(program, target[:url]) if target

        @read_error = "no #{program.github} pull request is recorded on this task"
        [nil, nil]
      end

      def pr_versions(program, url)
        owner, repo, number = url.match(TaskPrSet::PR_URL).captures
        refs, ok = CiStatus.gh_read_status("api", "repos/#{owner}/#{repo}/pulls/#{number}",
                                           "--jq", '.base.sha + " " + .head.sha')
        base_sha, head_sha = refs.to_s.split
        unless ok && head_sha
          @read_error = "could not read #{url}'s base and head"
          return [nil, nil]
        end

        github = "#{owner}/#{repo}"
        head_text, head_err = ProgramDrift.github_file(github, program.version_file, head_sha, gh: gh)
        base_text, = ProgramDrift.github_file(github, program.version_file, base_sha, gh: gh)
        head = head_text && ProgramDrift.parse_version(head_text)
        @read_error = head_err || "no [package] version line at #{head_sha[0, 12]}" unless head
        [base_text && ProgramDrift.parse_version(base_text), head]
      end

      def gh
        ->(*args) { CiStatus.gh_read_status(*args) }
      end
    end
  end
end
