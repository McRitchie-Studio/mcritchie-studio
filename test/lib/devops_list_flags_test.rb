# frozen_string_literal: true

# [unit] lib/devops_list_flags.rb is the one key map behind bin/task's comma
# refusal and Task's comma split. The refusing flags are DERIVED from the
# identifier keys, so these cases pin the derivation and its two ends.
#
#   ruby -Itest test/lib/devops_list_flags_test.rb

require "minitest/autorun"
require_relative "../../lib/devops_list_flags"

class DevopsListFlagsTest < Minitest::Test
  def test_unit_the_refusing_flags_are_the_flags_that_write_an_identifier_key
    assert_equal %w[--repo --risk], DevopsListFlags::COMMA_FREE_FLAGS
    DevopsListFlags::COMMA_FREE_FLAGS.each do |flag|
      assert_includes DevopsListFlags::IDENTIFIER_KEYS, DevopsListFlags::FLAGS.fetch(flag)
    end
  end

  def test_unit_a_prose_flag_never_refuses_a_comma
    prose = DevopsListFlags::FLAGS.reject { |_flag, key| DevopsListFlags::IDENTIFIER_KEYS.include?(key) }.keys

    assert_equal %w[--accept --test --checks], prose
    assert_empty prose & DevopsListFlags::COMMA_FREE_FLAGS
  end

  def test_unit_every_identifier_key_is_written_by_a_flag
    assert_empty DevopsListFlags::IDENTIFIER_KEYS - DevopsListFlags::FLAGS.values,
                 "an identifier key no flag writes would split on the server and be refused nowhere"
  end

  def test_unit_bin_task_reads_the_map_rather_than_a_copy
    source = File.read(File.expand_path("../../bin/task", __dir__))

    assert_match(/^LIST_FLAGS = DevopsListFlags::FLAGS$/, source)
    assert_match(/^COMMA_FREE_LIST_FLAGS = DevopsListFlags::COMMA_FREE_FLAGS$/, source)
  end
end
