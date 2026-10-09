# frozen_string_literal: true

require_relative "code_diff"
require_relative "test_only_diff"

# MergePermission — may this soul merge this PR into `accepted`?
#
# THE RULE. The documentation seat (Xan) merges a PR only when its diff measures
# `docs`: prose, inert media and docs-guard tests, with at least one prose file.
# Any other diff is merged by the standing primary (Carl). Every other soul is
# untouched by this rule, so what Carl may merge does not change.
#
# THE SHAPE IS MEASURED, NEVER DECLARED. #diff_shape reads the PR's own file list
# through CodeDiff and TestOnlyDiff, the classifiers bin/dor-check gates on. The
# card's `shape` field is something an author sets, so it is not an input here.
# A comment-only Ruby edit measures as code: telling it from a code change needs
# both trees, and the strict answer costs one Carl merge.
#
# IT IS MEASURED AT THE MERGE. The caller hands in the head the verdict judged
# and the PR's live head; they must be equal, and the merge that follows pins the
# same sha (`gh pr merge --match-head-commit`). A PR that was prose at review and
# gained a code file before the merge has a new head, so it is refused here.
#
# Pure: no gh, no board. bin/lib/merge_permit_cli.rb does the reads.
module MergePermission
  # The shape-limited seats: soul => the one diff shape that seat may merge.
  SHAPE_LIMITED = { "xan" => "docs" }.freeze

  # Who merges what a shape-limited seat may not.
  STANDING_PRIMARY = "carl"

  # Retired slugs that still resolve (Task::SOUL_ALIASES; this file runs without Rails).
  SOUL_ALIASES = { "alex" => "xan" }.freeze

  # The souls whose merge-ready verdict can authorise a merge: the review pool
  # (ReviewerSelector::POOL, pinned by test/lib/merge_permission_test.rb).
  REVIEWERS = %w[shannon carl jasper steffon xan].freeze

  AUTHORISING_VERDICT = "merge-ready"

  # Every value #diff_shape can return.
  DIFF_SHAPES = %w[docs test-only code mixed unread].freeze

  Result = Struct.new(:permitted, :code, :reason, keyword_init: true) do
    def permitted? = permitted ? true : false
  end

  module_function

  def canonical(soul)
    slug = soul.to_s.strip.downcase
    SOUL_ALIASES.fetch(slug, slug)
  end

  def shape_limited?(soul)
    SHAPE_LIMITED.key?(canonical(soul))
  end

  # The diff's shape, from its file list (both sides of every rename).
  #   unread     nothing was observed; never read as "nothing but prose"
  #   docs       CodeDiff.docs_with_guards?: prose with any guard tests riding along
  #   test-only  TestOnlyDiff.test_only?: test code and nothing else
  #   code       no prose at all
  #   mixed      prose beside a behavioral file that is not a guard test
  def diff_shape(files)
    list = clean(files)
    return "unread" if list.empty?
    return "docs" if CodeDiff.docs_with_guards?(list)
    return "test-only" if TestOnlyDiff.test_only?(list)
    return "code" if CodeDiff.code_files(list).size == list.size

    "mixed"
  end

  # The files that keep a diff from measuring `docs`, for the refusal to name.
  def offenders(files)
    CodeDiff.non_guard_code_files(clean(files))
  end

  # May `soul` merge the PR whose diff is `files`?
  #   authors    the PR's author set (stamped and derived from its commits); nil
  #              or empty means it could not be established
  #   verdict    the card's LATEST scout report: { "outcome", "reporter", "head" }
  #   head       the head the reviewer validated, the one the merge will pin
  #   live_head  the PR's head as read around the file list
  def decide(soul:, files:, authors:, verdict:, head:, live_head:)
    seat = canonical(soul)
    return refuse(:no_soul, "no soul was named; pass --agent <soul>") if seat.empty?
    unless SHAPE_LIMITED.key?(seat)
      return permit(:unrestricted, "#{seat} is not a shape-limited seat; this rule adds nothing to the merge sequence")
    end

    allowed = SHAPE_LIMITED.fetch(seat)
    set = clean(authors).map { |name| canonical(name) }.uniq
    if set.empty?
      return refuse(:authors_unread, "the PR's author set could not be established, so no-self-review cannot be " \
                                     "shown. #{who_merges(set)}")
    end
    if set.include?(seat)
      return refuse(:self_review, "#{seat} is one of this PR's authors (#{set.join(", ")}); a soul never merges " \
                                  "its own work. #{who_merges(set)}")
    end

    pinned = head.to_s.strip.downcase
    live = live_head.to_s.strip.downcase
    return refuse(:no_head, "no validated head was named; pass --head <sha>") if pinned.empty?
    if live != pinned
      return refuse(:head_moved, "the PR's head is #{short(live)}, not the validated #{short(pinned)}; the verdict " \
                                 "describes a different tree. Review the new head, then ask again")
    end

    verdict_refusal = verdict_refusal(verdict, pinned, set)
    return verdict_refusal if verdict_refusal

    shape = diff_shape(files)
    return permit(:docs_seat, "#{seat} may merge: the diff measures #{allowed} at #{short(pinned)}") if shape == allowed

    refuse(:"shape_#{shape.tr("-", "_")}", shape_refusal(seat, allowed, shape, files, pinned, set))
  end

  def verdict_refusal(verdict, pinned, authors)
    report = verdict.is_a?(Hash) ? verdict : {}
    outcome = report["outcome"].to_s.strip
    if outcome != AUTHORISING_VERDICT
      standing = outcome.empty? ? "no scout report" : "a #{outcome} report"
      return refuse(:no_verdict, "the card's latest verdict is #{standing}, not #{AUTHORISING_VERDICT}; record the " \
                                 "review verdict before merging")
    end

    reporter = canonical(report["reporter"])
    unless REVIEWERS.include?(reporter)
      return refuse(:verdict_not_reviewer, "the #{AUTHORISING_VERDICT} verdict is from " \
                                           "#{reporter.empty? ? "an unnamed agent" : reporter}, who holds no review seat " \
                                           "(#{REVIEWERS.join(", ")})")
    end
    if authors.include?(reporter)
      return refuse(:verdict_from_author, "the #{AUTHORISING_VERDICT} verdict is from #{reporter}, one of this PR's " \
                                          "authors; a verdict on one's own work authorises nothing")
    end

    judged = report["head"].to_s.strip.downcase
    if judged.empty?
      return refuse(:verdict_names_no_head, "the #{AUTHORISING_VERDICT} verdict names no head; record it again with " \
                                            "--head #{short(pinned)} so it is bound to the tree it judged")
    end
    return nil if judged == pinned

    refuse(:verdict_other_head, "the #{AUTHORISING_VERDICT} verdict judged #{short(judged)}, not #{short(pinned)}; " \
                                "review the head being merged and record the verdict for it")
  end

  def shape_refusal(seat, allowed, shape, files, pinned, authors)
    named = offenders(files)
    sample = named.first(3).join(", ") + (named.size > 3 ? ", and #{named.size - 3} more" : "")
    detail =
      case shape
      when "unread" then "its file list could not be read, and an unread diff is never read as prose"
      when "test-only" then "it is test code with no prose"
      else "it ships #{sample}"
      end
    "the documentation seat (#{seat}) merges #{allowed}-shape PRs only: prose, inert media and docs-guard tests, " \
      "measured from the diff at the head being merged. This diff measures #{shape} at #{short(pinned)}: #{detail}. " \
      "#{who_merges(authors)}"
  end

  # Who can merge instead: the standing primary, unless he is an author too.
  def who_merges(authors)
    if authors.include?(STANDING_PRIMARY)
      "#{STANDING_PRIMARY.capitalize} is an author here, so a primary outside the author set merges it " \
        "(bin/reviewer-select names one)"
    else
      "#{STANDING_PRIMARY.capitalize}, the standing primary, merges it"
    end
  end

  def permit(code, reason) = Result.new(permitted: true, code: code, reason: reason)

  def refuse(code, reason) = Result.new(permitted: false, code: code, reason: reason)

  def clean(list) = Array(list).map { |item| item.to_s.strip }.reject(&:empty?)

  def short(sha) = sha.to_s.empty? ? "an unknown head" : sha.to_s[0, 7]
end
