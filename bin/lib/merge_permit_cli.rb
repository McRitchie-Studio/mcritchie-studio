# frozen_string_literal: true

require "json"
require "optparse"
require_relative "merge_permission"
require_relative "merge_command"

# MergePermitCli — the reads behind bin/merge-permit, and its three answers.
#
#   exit 0  PERMIT    the soul may run the printed, head-pinned merge
#   exit 2  REFUSED   the rule says no; the line names the rule and who merges
#   exit 1  NO PERMIT a read failed, so nothing was established
#
# A soul the rule does not limit is answered at once with no read at all, so the
# standing primary's merge sequence cannot pick up a new way to fail here.
#
# ORDER OF THE READS. The PR's head is read BEFORE and AFTER the file list: the
# files endpoint describes whatever the head is at that moment, so the list is
# only evidence about the validated head when both reads equal it.
#
# `board` and `github` are injected (bin/merge-permit wires the real ones):
#   board.task(slug)           -> [hash, nil] | [nil, reason]
#   board.scout_reports(slug)  -> [array, nil] | [nil, reason]
#   github.head(pr_url)        -> [sha, nil] | [nil, reason]
#   github.files(pr_url)       -> [array, nil] | [nil, reason]
#   github.commit_text(pr_url) -> [string, nil] | [nil, reason]
class MergePermitCli
  PERMIT = 0
  NO_PERMIT = 1
  REFUSED = 2

  USAGE = "usage: bin/merge-permit <task-slug> --agent <soul> --head <validated-sha> [--json]"

  SOUL_EMAIL = /([a-z0-9][a-z0-9-]*)@mcritchie\.studio/i

  def initialize(board:, github:, souls:, out: $stdout, err: $stderr)
    @board = board
    @github = github
    @souls = Array(souls).map { |soul| MergePermission.canonical(soul) }
    @out = out
    @err = err
  end

  def run(argv)
    options = parse(argv)
    return usage(options[:error]) if options[:error]

    slug, soul, head = options.values_at(:slug, :agent, :head)
    return usage("a task slug and --agent are required") if slug.to_s.empty? || soul.to_s.strip.empty?

    unless MergePermission.shape_limited?(soul)
      return answer(options, slug, MergePermission.decide(soul: soul, files: nil, authors: nil, verdict: nil,
                                                          head: head, live_head: nil), nil)
    end

    facts, failure = gather(slug)
    return no_permit(options, slug, failure) if failure

    result = MergePermission.decide(soul: soul, head: head, **facts.slice(:files, :authors, :verdict, :live_head))
    answer(options, slug, result, facts[:pr_url], head)
  rescue StandardError => e
    no_permit(options || {}, slug, "#{e.class}: #{e.message}")
  end

  private

  def parse(argv)
    options = {}
    rest = OptionParser.new do |opts|
      opts.on("--agent SOUL") { |value| options[:agent] = value }
      opts.on("--head SHA") { |value| options[:head] = value }
      opts.on("--json") { options[:json] = true }
    end.parse(argv)
    options.merge(slug: rest.first)
  rescue OptionParser::ParseError => e
    { error: e.message }
  end

  # Every fact the decision needs, or the first read that failed.
  def gather(slug)
    task, why = @board.task(slug)
    return [nil, "could not read task #{slug}: #{why}"] unless task

    pr_url = (task.dig("metadata", "devops") || {})["pr_url"].to_s.strip
    return [nil, "task #{slug} records no PR (devops.pr_url), so there is nothing to merge"] if pr_url.empty?

    commit_text, why = @github.commit_text(pr_url)
    return [nil, "could not read the PR's commits, so its authors are unknown: #{why}"] unless commit_text

    before, why = @github.head(pr_url)
    return [nil, "could not read the PR's head: #{why}"] unless before

    files, why = @github.files(pr_url)
    return [nil, "could not read the PR's file list: #{why}"] unless files

    after, why = @github.head(pr_url)
    return [nil, "could not re-read the PR's head: #{why}"] unless after

    reports, why = @board.scout_reports(slug)
    return [nil, "could not read the card's scout reports: #{why}"] unless reports

    [{ pr_url: pr_url, files: files, authors: authors(task, commit_text), verdict: latest_verdict(reports),
       live_head: before == after ? after : "#{before} then #{after}" }, nil]
  end

  # The author set: the card's stamps and the souls on the PR's commits (author,
  # committer, and any soul address in a message), kept to the roster.
  def authors(task, commit_text)
    devops = task.dig("metadata", "devops") || {}
    stamped = [devops["built_by"]] + Array(devops["builders"]) + Array(devops["fix_forward"])
    derived = commit_text.to_s.scan(SOUL_EMAIL).flatten
    (stamped + derived).map { |name| MergePermission.canonical(name) }.select { |name| @souls.include?(name) }.uniq
  end

  # The card's LATEST scout report, whatever it says. The reporter is the
  # activity's own agent_slug, which the board stamps from the session.
  def latest_verdict(reports)
    latest = Array(reports)
             .select { |row| row.is_a?(Hash) && row.dig("metadata", "kind").to_s == "scout_report" }
             .max_by { |row| [row["created_at"].to_s, row["id"].to_i] }
    return nil unless latest

    { "outcome" => latest.dig("metadata", "outcome"), "reporter" => latest["agent_slug"],
      "head" => latest.dig("metadata", "head") }
  end

  def answer(options, slug, result, pr_url, head = nil)
    merge = result.permitted? && pr_url ? "gh #{MergeCommand.args(pr_url, head).join(" ")}" : nil
    if options[:json]
      @out.puts(JSON.generate("task" => slug, "permitted" => result.permitted?, "code" => result.code.to_s,
                              "reason" => result.reason, "merge" => merge))
    elsif result.permitted?
      @out.puts("merge-permit: PERMIT #{slug}: #{result.reason}")
      @out.puts("  #{merge}") if merge
    else
      @err.puts("merge-permit: REFUSED #{slug}: #{result.reason}")
    end
    result.permitted? ? PERMIT : REFUSED
  end

  def no_permit(options, slug, reason)
    if options[:json]
      @out.puts(JSON.generate("task" => slug, "permitted" => false, "code" => "unread", "reason" => reason))
    else
      @err.puts("merge-permit: NO PERMIT#{slug ? " #{slug}" : ""}: #{reason}. Nothing was established, so do not merge")
    end
    NO_PERMIT
  end

  def usage(problem)
    @err.puts("merge-permit: #{problem}")
    @err.puts(USAGE)
    REFUSED
  end
end
