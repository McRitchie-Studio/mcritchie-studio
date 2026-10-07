# frozen_string_literal: true

# [unit] config/release_repos.yml comments state the current rule in the present
# tense (release-repos-comments-present-tense): a dated line is history, and the
# history lives in the task and its PR. The lint names every comment line that
# carries a date or a dated attribution such as "(Alex, 2026".

require "minitest/autorun"

class ReleaseReposCommentsTest < Minitest::Test
  PATH = File.expand_path("../../config/release_repos.yml", __dir__)
  DATED = /\b20\d\d-\d\d(-\d\d)?\b|\(\w+, 20\d\d/

  def dated_comment_lines(text)
    text.each_line.with_index(1).filter_map do |line, number|
      comment = line[/#.*/]
      "#{number}: #{line.strip}" if comment&.match?(DATED)
    end
  end

  def test_no_comment_in_the_registry_is_dated
    offenders = dated_comment_lines(File.read(PATH))

    assert_empty offenders, "config/release_repos.yml comments must state the current rule, " \
                            "not dated history:\n#{offenders.join("\n")}"
  end

  def test_the_lint_names_a_dated_comment_and_spares_values
    fixture = <<~YAML
      apps:
        demo:
          # Registered 2026-09-25 after the sweep aborted.
          ladder: three-rung
          # Moved here (Alex, 2026) for cost.
          smoke_url: https://demo-2026-09.example.com
    YAML

    assert_equal ["3: # Registered 2026-09-25 after the sweep aborted.",
                  "5: # Moved here (Alex, 2026) for cost."],
                 dated_comment_lines(fixture)
  end
end
