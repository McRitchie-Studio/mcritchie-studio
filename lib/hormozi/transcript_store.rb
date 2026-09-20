# frozen_string_literal: true

require "fileutils"

module Hormozi
  # Writes the cleaned transcripts, and decides whether one already on disk may
  # be REUSED instead of re-cleaned.
  #
  # WHY COMPLETENESS AND NOT EXISTENCE. bin/hormozi-prep skips a caption whose
  # transcript is already there, which is what turns a resumed 516-file run from
  # minutes into seconds. It used to ask File.exist? — existence — and the write
  # it paired that with was a plain File.write, which is not atomic. A prep
  # interrupted mid-write (^C, a full disk, a harness that killed the command)
  # therefore left a truncated or zero-byte .txt that satisfied that check
  # FOREVER: every later run reused it, counted it as "reused" in a cheerful
  # summary at exit 0, and the extraction wave read an empty transcript for a
  # tier-1 episode. Silent, permanent, and invisible in the output.
  #
  # Two halves, both load-bearing: a transcript is reusable only when it has
  # BYTES, and a write lands by rename so an interrupted one cannot be mistaken
  # for a finished one.
  module TranscriptStore
    # The destination never holds a prefix of the text; a crash leaves this behind
    # instead, under a name no reuse check and no *.txt glob will accept.
    SUFFIX = ".incomplete"

    # A caption whose clean yields nothing at all — no speech in the file — is
    # re-cleaned on every run rather than skipped. That is deliberate: nothing on
    # disk distinguishes "genuinely empty" from "truncated to zero", and paying a
    # few milliseconds per empty caption is the cheap side of that trade.
    def self.reusable?(path)
      !File.size?(path).nil?
    end

    # Writes `text` to `path` atomically and returns it. rename(2) inside one
    # directory is atomic, so a reader — or the next run — sees either the
    # previous transcript or the whole new one.
    def self.write(path, text)
      staging = "#{path}#{SUFFIX}"
      begin
        File.write(staging, text)
        File.rename(staging, path)
      ensure
        FileUtils.rm_f(staging)
      end
      text
    end
  end
end
