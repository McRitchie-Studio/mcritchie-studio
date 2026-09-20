# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../../lib/hormozi/transcript_store"

# [unit] AN INTERRUPTED PREP MUST NOT LEAVE A TRANSCRIPT THAT LOOKS FINISHED.
#
# THE SHAPE OF THE DEFECT. Reuse asked File.exist? — existence, not completeness
# — and the write it paired that with was a plain File.write, which is not
# atomic. A prep interrupted mid-write during a 516-file clean therefore left a
# truncated or zero-byte .txt that satisfied that check FOREVER: every later run
# reused it, counted it as "reused" in a cheerful summary, exited 0, and the
# extraction wave read an empty transcript for a tier-1 episode.
#
# WHAT MAKES IT EXPENSIVE. Nothing is loud. The manifest reports 0 words for a
# real episode, which reads like a short video rather than a failure, and no
# later run ever re-cleans it because the file is right there.
#
# BOTH HALVES OF THE FIX ARE PINNED HERE, because either alone still loses:
# completeness-based reuse without an atomic write re-cleans the same truncated
# file forever, and an atomic write without completeness-based reuse still trusts
# whatever the pre-fix runs already stranded on disk.
class TranscriptStoreTest < Minitest::Test
  def test_a_zero_byte_transcript_is_not_reusable
    with_transcript("") do |path|
      refute Hormozi::TranscriptStore.reusable?(path), "THE BUG: existence was mistaken for completeness"
    end
  end

  def test_a_transcript_with_content_is_reusable
    with_transcript("your offer is the business") do |path|
      assert Hormozi::TranscriptStore.reusable?(path)
    end
  end

  def test_a_missing_transcript_is_not_reusable
    Dir.mktmpdir do |dir|
      refute Hormozi::TranscriptStore.reusable?(File.join(dir, "never-cleaned.txt"))
    end
  end

  def test_write_lands_the_text_and_returns_it
    Dir.mktmpdir do |dir|
      path = File.join(dir, "v1.txt")

      assert_equal "the whole transcript", Hormozi::TranscriptStore.write(path, "the whole transcript")
      assert_equal "the whole transcript", File.read(path)
      assert Hormozi::TranscriptStore.reusable?(path)
    end
  end

  def test_write_leaves_no_staging_file_behind
    Dir.mktmpdir do |dir|
      Hormozi::TranscriptStore.write(File.join(dir, "v1.txt"), "the whole transcript")

      assert_equal [ "v1.txt" ], Dir.children(dir), "a staging file left in transcripts/ is the next run's confusion"
    end
  end

  # Interruption is the trigger, so it is the case the write has to survive: the
  # destination holds either the previous transcript or the whole new one, never a
  # prefix of it.
  def test_an_interrupted_write_leaves_the_previous_transcript_intact
    Dir.mktmpdir do |dir|
      path = File.join(dir, "v1.txt")
      File.write(path, "the transcript a finished run wrote")

      interrupting_the_rename do
        assert_raises(Interrupt) { Hormozi::TranscriptStore.write(path, "half a tra") }
      end

      assert_equal "the transcript a finished run wrote", File.read(path)
      assert_equal [ "v1.txt" ], Dir.children(dir), "the staging file must be cleaned up even when the write dies"
    end
  end

  # The pre-fix runs already stranded truncated files on the live corpus, so a
  # crash that happens to land on one must not leave it looking finished either.
  def test_an_interrupted_write_over_a_truncated_transcript_leaves_it_unreusable
    with_transcript("") do |path|
      interrupting_the_rename do
        assert_raises(Interrupt) { Hormozi::TranscriptStore.write(path, "half a tra") }
      end

      refute Hormozi::TranscriptStore.reusable?(path), "it must still be re-cleaned on the next run"
    end
  end

  def with_transcript(content)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "v1.txt")
      File.write(path, content)
      yield path
    end
  end

  # minitest 6 dropped minitest/mock, so the interruption is staged by hand. The
  # rename is the only step that creates the destination, so making it die is what
  # asks the question the defect asked: what is on disk when a run stops mid-write?
  def interrupting_the_rename
    singleton = File.singleton_class
    original = singleton.instance_method(:rename)
    singleton.define_method(:rename) { |*| raise Interrupt }
    yield
  ensure
    singleton.define_method(:rename, original)
  end
end
