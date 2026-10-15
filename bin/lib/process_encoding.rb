# frozen_string_literal: true

# A bare environment (launchd, cron) starts Ruby with no LANG, and Ruby then
# reads every file as US-ASCII: the first em dash in a doc raises "invalid byte
# sequence in US-ASCII" (2026-10-15: bin/dispatcher under launchd dead-lettered
# messages #67 and #68). A long-running entry point calls force_utf8! first,
# before it requires anything that reads a file. Readers that matter also pass
# `encoding: "UTF-8"` themselves, so either layer alone is enough.
module ProcessEncoding
  def self.force_utf8!
    Encoding.default_external = Encoding::UTF_8
    Encoding.default_internal = nil
  end
end
