# frozen_string_literal: true

require "json"
require "set"
require "yaml"

require_relative "op_vaults"

# ChromeProfiles — the operator's Chrome avatar-menu roster, as data plus the
# resolver that lands it on a particular Mac.
#
# WHY THIS EXISTS. The roster (which Google accounts show in "Other Chrome
# Profiles", in what order, under what label) lived only in
# `~/Library/Application Support/Google/Chrome/Local State` and in a pair of
# hand-edited scripts in `~/Applications`. None of that is in a repo, so a house
# burn-down took the whole arrangement with it — including the three constraints
# below, each of which cost a measured experiment to find.
#
# ============================================================================
# THE INVARIANT THIS MODULE EXISTS FOR:
#
#     THE DESIRED STATE IS KEYED BY ACCOUNT EMAIL, AND THE PROFILE DIRECTORY IS
#     RESOLVED AGAINST THE MACHINE AT RUN TIME — NEVER RECORDED.
#
# The previous script keyed on the directory ("Profile 7", "Default"). Chrome
# hands those out in SIGN-IN ORDER, so they are an accident of history, they
# differ on a rebuilt machine, and they are not dense: signing into
# team@mcritchie.studio on 2026-09-04 produced `Profile 14` on a Mac holding
# eleven profiles. A directory-keyed roster restored onto a fresh Mac does not
# fail loudly — it renames the WRONG PROFILES. Email is stable, so email is the
# key.
# ============================================================================
#
# FOUR MEASURED CONSTRAINTS, all re-derived the hard way at least once. The SOP
# (docs/agents/agents/steffon/sops/chrome-profiles.md) carries the evidence, and
# constraint 4's lives in this file — Runtime.chrome_arch and install_wrapper!.
#
#   1. Chrome must be fully QUIT before `Local State` is edited. It holds the
#      file in memory and rewrites it on exit, silently discarding any edit made
#      while it was up. `Runtime.chrome_running?` gates every live write.
#   2. The custom order is IGNORED unless Chrome is launched with
#      `--enable-features=ProfilesReordering`. The chrome://flags route is pruned
#      at startup on Chrome 152, hence the wrapper app this module can generate.
#      Launched any other way, the menu silently reverts to alphabetical — the
#      order is not lost, just ignored.
#   3. The PARENTHESES cannot be removed. Chrome renders each row as
#      "<Google first name> (<profile name>)" and collapses to the name alone
#      only when the two match. Blanking the cached GAIA name works for about 75
#      seconds, until Chrome refreshes account info and restores it. So a label
#      must never REPEAT the word Chrome prepends, and `Plan` refuses one that
#      does rather than letting it be discovered in the menu.
#   4. The wrapper must force the NATIVE architecture. A .app whose executable is
#      a shell script does not reliably select the native slice of Chrome's
#      universal binary: measured 2026-09-04 on an M4 Pro, Chrome ran entirely as
#      x86_64 under Rosetta with six renderers near 100% CPU, while the menu was
#      correct and every other check read green. `install_wrapper!` emits
#      `arch -<host arch>` and `Runtime.chrome_translated?` asserts the result.
module ChromeProfiles
  DEFAULT_LOCAL_STATE = File.expand_path("~/Library/Application Support/Google/Chrome/Local State")

  # THE ROSTER IS NOT IN THIS REPO, AND THAT IS DELIBERATE.
  #
  # mcritchie-studio is PUBLIC — `gh api repos/McRitchie-Studio/mcritchie-studio`
  # returns visibility:public, and an unauthenticated GET of raw.githubusercontent
  # returns 200. The roster keys on account email, and two of those belong to
  # family members rather than to the business. Committing it published two
  # personal addresses that had never appeared in this repository before; caught
  # in review on 2026-09-04, and a public repo's history is scraped and mirrored
  # faster than a later commit can retract it.
  #
  # So the repo carries the CODE, the SOP and an EXAMPLE, and the real roster
  # lives in 1Password. That is also the honest answer to the burn-down question
  # this whole tool exists for: 1Password is already the thing a rebuilt Mac
  # restores from, and it survives the machine exactly the way the repo does.
  #
  # NOTHING FALLS BACK TO THE EXAMPLE. Resolving placeholder addresses against a
  # real machine would make every profile unlisted, and the roster's own guard
  # would then refuse — loudly, but for the wrong reason.
  EXAMPLE_CONFIG      = File.expand_path("../../config/chrome_profiles.yml.example", __dir__)
  OP_ITEM             = "chrome-profiles.mcritchie.agents"

  # THE VAULT NAME IS NOT A LITERAL HERE, and the first draft of this file got
  # that wrong twice — once as an `ENV.fetch(...)` with its own default beside
  # this line, and once as a reference spelled out in a header comment. CI caught
  # the second (test/lib/credential_isolation_claims_test.rb) and the first only
  # looked innocent: it is a SECOND SOURCE for the same value, which is precisely
  # the shape that broke eleven call sites at once when the vault was renamed on
  # 2026-08-28. bin/lib/op_vaults.rb owns it; read it from there, at call time,
  # so an env override is honoured rather than frozen at load.
  def self.op_vault = OpVaults.vault

  CHROME_APP     = "/Applications/Google Chrome.app"
  CHROME_BIN     = "#{CHROME_APP}/Contents/MacOS/Google Chrome"
  WRAPPER_APP    = File.expand_path("~/Applications/Chrome (Ordered Profiles).app")
  FEATURE_FLAG   = "ProfilesReordering"
  EMOJI_FONT     = "/System/Library/Fonts/Apple Color Emoji.ttc"

  # One row of the desired state: an account, and the text that goes inside the
  # parentheses. Nothing here names a profile directory — that is the point.
  Row = Struct.new(:account, :label, keyword_init: true)

  # One profile as it exists on THIS machine.
  Profile = Struct.new(:dir, :account, :name, :gaia, keyword_init: true) do
    # Chrome's ProfileAttributesEntry::GetNameForm, reproduced. The menu shows
    # the profile name alone when the cached GAIA name is empty or identical;
    # otherwise it prepends the GAIA name and parenthesises the profile name.
    def menu_row(label = name)
      return label.to_s if gaia.to_s.empty?
      return gaia.to_s if gaia.to_s == label.to_s

      "#{gaia} (#{label})"
    end
  end

  class Error < StandardError; end

  # ---------------------------------------------------------------------------
  # Desired state
  # ---------------------------------------------------------------------------
  class Roster
    attr_reader :rows, :path

    # The ONE seam that chooses a source, so no caller has to know there are two.
    # An explicit --config wins (that is what the tests and a dry run use);
    # otherwise the real roster comes from 1Password.
    def self.resolve(config: nil)
      config ? load(config) : from_op
    end

    # ONE `op` read per invocation, through the metered seam so it lands in the
    # op-reads log like every other credential read. The daily cap is
    # ACCOUNT-WIDE and shared with every other lane, so this must never be put
    # in a loop or a poll.
    def self.from_op(vault: ChromeProfiles.op_vault, item: OP_ITEM)
      require_relative "op_meter"
      out = OpMeter.popen({}, [ "op", "document", "get", item, "--vault", vault ],
                          via: "chrome_profiles", err: File::NULL)
      raise Error, op_remedy(vault, item) if out.to_s.strip.empty?

      parse(out, source: "op://#{vault}/#{item}")
    rescue Errno::ENOENT
      raise Error, "1Password CLI (`op`) is not installed, so the roster cannot be read.\n" \
                   "#{op_remedy(vault, item)}"
    end

    def self.op_remedy(vault, item)
      <<~TEXT.strip
        Could not read the roster from 1Password (op://#{vault}/#{item}).

        This does NOT fall back to #{File.basename(EXAMPLE_CONFIG)} on purpose — placeholder
        addresses would resolve against no profile on this Mac and the roster's own
        unlisted-profile guard would then refuse for the wrong reason.

        In order:
          op whoami                       # is the session live?
          op service-account ratelimit    # the daily cap is ACCOUNT-WIDE and shared
          op document get #{item.inspect} --vault #{vault}

        If the document does not exist yet, file it (needs the admin lane):
          source ~/.zprofile.admin
          export OP_SERVICE_ACCOUNT_TOKEN="$OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
          op document create <roster.yml> --title #{item.inspect} --vault #{vault} \\
            --file-name chrome_profiles.yml

        SOP: docs/agents/agents/steffon/sops/chrome-profiles.md
      TEXT
    end

    def self.load(path)
      raise Error, "no roster at #{path}" unless File.file?(path)

      parse(File.read(path), source: path)
    end

    def self.parse(text, source:)
      # A vault document is edited by hand and pasted back, so malformed YAML is
      # a NORMAL failure here, not an impossible one. Psych's own error is a
      # backtrace with a column number and no mention of where the text came
      # from — useless when the source is a 1Password document you cannot see.
      begin
        doc = YAML.safe_load(text) || {}
      rescue Psych::SyntaxError => e
        raise Error, "#{source} is not valid YAML: #{e.message}"
      end
      entries = doc["profiles"]
      raise Error, "#{source} has no `profiles:` list" unless entries.is_a?(Array)

      new(entries.each_with_index.map { |e, i|
        unless e.is_a?(Hash) && e["account"].to_s.strip != ""
          raise Error, "#{source}: entry #{i + 1} has no `account:`"
        end

        Row.new(account: e["account"].to_s.strip.downcase, label: e["label"].to_s)
      }, path: source)
    end

    def initialize(rows, path:)
      @rows = rows
      @path = path
    end

    def accounts = rows.map(&:account)
  end

  # ---------------------------------------------------------------------------
  # Machine state
  # ---------------------------------------------------------------------------
  class LocalState
    attr_reader :path, :data

    def self.load(path = DEFAULT_LOCAL_STATE)
      raise Error, "no Chrome Local State at #{path}" unless File.file?(path)

      new(path, JSON.parse(File.read(path)))
    end

    def initialize(path, data)
      @path = path
      @data = data
    end

    def live? = File.expand_path(path) == File.expand_path(DEFAULT_LOCAL_STATE)

    def info_cache = data.dig("profile", "info_cache") || {}

    def order = data.dig("profile", "profiles_order") || []

    # Every profile Chrome knows about, in whatever order it stores them.
    def profiles
      info_cache.map do |dir, entry|
        Profile.new(
          dir: dir,
          account: entry["user_name"].to_s.strip.downcase,
          name: entry["name"].to_s,
          gaia: (entry["gaia_given_name"].to_s.empty? ? entry["gaia_name"].to_s : entry["gaia_given_name"].to_s)
        )
      end
    end

    # The menu as it reads right now, in the order Chrome would show it.
    def current_menu
      by_dir = profiles.to_h { |p| [ p.dir, p ] }
      dirs = order.select { |d| by_dir.key?(d) } + (by_dir.keys - order)
      dirs.map { |d| [ d, by_dir[d].menu_row ] }
    end
  end

  # ---------------------------------------------------------------------------
  # Resolution — the desired roster landed on this machine's directories
  # ---------------------------------------------------------------------------
  #
  # Two conditions are treated ASYMMETRICALLY, on purpose:
  #
  #   * A profile on the machine that the roster does NOT list is a REFUSAL. We
  #     will not rename or reorder a profile nobody told us about, and we will
  #     not drop it from the order. This guard is what caught `Profile 14`
  #     (team@mcritchie.studio) minutes after it was created.
  #   * A roster account NOT on the machine is ALLOWED and reported loudly. That
  #     is the normal state halfway through a rebuild, when you have signed into
  #     four of twelve accounts. Refusing there would make the roster useless for
  #     the exact job it exists to do.
  class Plan
    attr_reader :roster, :state, :resolved, :missing, :unlisted, :refusals

    def initialize(roster:, state:)
      @roster = roster
      @state = state
      @resolved = []
      @missing = []
      @unlisted = []
      @refusals = []
      resolve!
    end

    def refuse? = !refusals.empty?

    # [[dir, label, "Alex (🪎 mcritchie.studio)"], ...] in menu order.
    def menu
      resolved.map { |dir, row, profile| [ dir, row.label, profile.menu_row(row.label) ] }
    end

    def order = resolved.map(&:first)

    private

    def resolve!
      by_account = {}
      state.profiles.each do |profile|
        if profile.account.empty?
          @unlisted << "#{profile.dir} is signed into no account, so the roster cannot key it"
          next
        end
        if by_account.key?(profile.account)
          @refusals << "two profiles share #{profile.account} (#{by_account[profile.account].dir}, #{profile.dir})"
        end
        by_account[profile.account] = profile
      end

      seen = Set.new
      roster.rows.each do |row|
        if seen.include?(row.account)
          @refusals << "#{roster.path} lists #{row.account} more than once"
          next
        end
        seen << row.account

        profile = by_account[row.account]
        if profile.nil?
          @missing << row.account
          next
        end

        check_label(row, profile)
        @resolved << [ profile.dir, row, profile ]
      end

      by_account.each do |account, profile|
        next if seen.include?(account)

        @unlisted << "#{profile.dir} (#{account}) is not in #{roster.path}"
      end

      @refusals.concat(@unlisted)
    end

    # Constraint 3, enforced instead of remembered. A label that opens with the
    # word Chrome already prepends renders as `Alex (Alex studio)`. A label
    # EQUAL to that word is the opposite case and is fine — that is how Margot
    # and Mason get a bare row with no parentheses at all.
    def check_label(row, profile)
      if row.label.strip.empty?
        @refusals << "#{row.account} has an empty label"
        return
      end

      first = profile.gaia.to_s.strip
      return if first.empty?
      return if row.label == first

      if row.label.downcase.start_with?("#{first.downcase} ")
        @refusals << "#{row.account}: label #{row.label.inspect} repeats the name Chrome prepends " \
                     "(#{first.inspect}); it would render as #{profile.menu_row(row.label).inspect}"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Writing
  # ---------------------------------------------------------------------------
  module Writer
    module_function

    # Back up, then set exactly three fields: the order, and each profile's
    # display name plus the flag that stops Chrome regenerating it. Accounts,
    # gaia_id and avatars are never touched.
    def apply!(state, plan, backup: true)
      raise Error, "refusing to write: #{plan.refusals.join('; ')}" if plan.refuse?

      backup_path = backup ? backup!(state.path) : nil

      data = JSON.parse(File.read(state.path))
      data["profile"] ||= {}
      data["profile"]["profiles_order"] = plan.order
      cache = data.dig("profile", "info_cache") || {}
      plan.resolved.each do |dir, row, _profile|
        next unless cache.key?(dir)

        cache[dir]["name"] = row.label
        cache[dir]["is_using_default_name"] = false
      end

      tmp = "#{state.path}.tmp"
      File.write(tmp, JSON.generate(data))
      File.rename(tmp, state.path)
      backup_path
    end

    def backup!(path)
      stamp = Time.now.strftime("%Y%m%d-%H%M%S")
      dest = "#{path}.backup-#{stamp}"
      File.write(dest, File.read(path))
      dest
    end
  end

  # ---------------------------------------------------------------------------
  # Emoji presence — "is this codepoint in the system font, or will it be tofu?"
  # ---------------------------------------------------------------------------
  #
  # PRESENCE IS NOT IDENTITY, and this only answers presence. Ruby's Unicode
  # tables on macOS 26 are too old to NAME an Emoji 16/17 addition, so the only
  # way to learn WHICH glyph a new codepoint draws is to render it and look. The
  # SOP carries that one-liner. What this catches is the other failure: a
  # codepoint that draws nothing at all and ships a tofu box into the menu.
  #
  # The font is 192 MB, so this seeks to the cmap rather than reading the file.
  module EmojiFont
    module_function

    def covers?(codepoint, path: EMOJI_FONT)
      ranges(path: path).any? { |r| r.cover?(codepoint) }
    end

    # Every codepoint of a label that is not ASCII, a ZWJ, or a variation
    # selector — i.e. the ones that could come back as tofu.
    def suspect_codepoints(label)
      label.codepoints.reject { |cp| cp < 0x2000 || cp == 0x200D || (0xFE00..0xFE0F).cover?(cp) }
    end

    def ranges(path: EMOJI_FONT)
      @ranges ||= {}
      @ranges[path] ||= parse(path)
    end

    def parse(path)
      return [] unless File.file?(path)

      File.open(path, "rb") do |io|
        font_offsets =
          if io.read(4) == "ttcf"
            io.seek(8)
            count = io.read(4).unpack1("N")
            io.read(4 * count).unpack("N*")
          else
            [ 0 ]
          end

        font_offsets.flat_map { |offset| cmap_ranges(io, offset) }
      end
    rescue StandardError
      []
    end

    def cmap_ranges(io, font_offset)
      io.seek(font_offset + 4)
      table_count = io.read(2).unpack1("n")
      cmap_offset = nil
      table_count.times do |i|
        io.seek(font_offset + 12 + (16 * i))
        tag = io.read(4)
        io.seek(4, IO::SEEK_CUR)
        offset = io.read(4).unpack1("N")
        cmap_offset = offset if tag == "cmap"
      end
      return [] unless cmap_offset

      io.seek(cmap_offset + 2)
      subtable_count = io.read(2).unpack1("n")
      offsets = subtable_count.times.map do |i|
        io.seek(cmap_offset + 4 + (8 * i) + 4)
        cmap_offset + io.read(4).unpack1("N")
      end

      offsets.flat_map { |offset| subtable_ranges(io, offset) }
    end

    def subtable_ranges(io, offset)
      io.seek(offset)
      case io.read(2).unpack1("n")
      when 12 then format12_ranges(io, offset)
      when 4  then format4_ranges(io, offset)
      else []
      end
    end

    def format12_ranges(io, offset)
      io.seek(offset + 12)
      groups = io.read(4).unpack1("N")
      raw = io.read(12 * groups).to_s
      groups.times.filter_map do |i|
        start, finish, = raw[12 * i, 12].unpack("N3")
        next if start.nil? || finish.nil? || finish < start
        # A span this wide is a misparse, not a font. Dropping it keeps a bad
        # read from answering "yes" to every codepoint you ask about.
        next if finish - start > 0x20000

        (start..finish)
      end
    end

    def format4_ranges(io, offset)
      io.seek(offset + 6)
      seg_count = io.read(2).unpack1("n") / 2
      io.seek(offset + 14)
      ends = io.read(2 * seg_count).unpack("n*")
      io.seek(offset + 16 + (2 * seg_count))
      starts = io.read(2 * seg_count).unpack("n*")
      starts.zip(ends).filter_map do |start, finish|
        next if start.nil? || finish.nil? || finish == 0xFFFF || finish < start

        (start..finish)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The machine around Chrome — quitting it, relaunching it, proving the flag
  # ---------------------------------------------------------------------------
  module Runtime
    module_function

    def chrome_running?
      system("pgrep", "-x", "Google Chrome", out: File::NULL, err: File::NULL)
    end

    # The authoritative answer to "is the custom order being honoured?" — the
    # flags on the RUNNING process. Chrome rewrites its ChromeFeatureState file
    # several seconds after launch, so reading that file right after a relaunch
    # reports the feature OFF while it is in fact on. Ask the process instead.
    def feature_active?
      out = `ps -Ao args= 2>/dev/null`
      out.lines.any? do |line|
        line.include?("#{CHROME_APP}/Contents/MacOS/Google Chrome") &&
          line.include?("--enable-features=") &&
          line.include?(FEATURE_FLAG)
      end
    end

    def wrapper_installed? = File.executable?(File.join(WRAPPER_APP, "Contents/MacOS/launch"))

    def chrome_pid = `pgrep -x "Google Chrome" 2>/dev/null`.lines.first&.strip

    # WHICH SLICE of Chrome's universal binary is running. This is not trivia:
    # a wrapper that exec's the binary from a shell script does not reliably pick
    # the native one, and a Chrome running x86_64 under Rosetta on Apple Silicon
    # is agonisingly slow while looking completely normal. Measured 2026-09-04 —
    # six renderers near 100% CPU, load average 11.6, the profile menu perfect.
    #
    # `sample` and `vmmap` both report it, and both take seconds; LaunchServices
    # answers instantly.
    def chrome_arch
      pid = chrome_pid
      return nil if pid.nil? || pid.empty?

      `lsappinfo info -only arch #{pid.to_i} 2>/dev/null`[/"LSArchitecture"\s*=\s*"([^"]+)"/, 1]
    end

    def host_arch = @host_arch ||= `uname -m`.strip

    # Compared against the HOST, so this stays correct on an Intel Mac, where
    # x86_64 is native rather than translated.
    def chrome_translated?
      arch = chrome_arch
      !arch.nil? && arch != host_arch
    end

    # Rebuild the launcher that carries the feature flag. Needed on every fresh
    # Mac: without it the menu sorts alphabetically no matter what is stored.
    def install_wrapper!(dest = WRAPPER_APP)
      require "fileutils"
      FileUtils.mkdir_p(File.join(dest, "Contents/MacOS"))
      FileUtils.mkdir_p(File.join(dest, "Contents/Resources"))

      File.write(File.join(dest, "Contents/Info.plist"), <<~PLIST)
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleName</key><string>Chrome (Ordered Profiles)</string>
          <key>CFBundleDisplayName</key><string>Chrome (Ordered Profiles)</string>
          <key>CFBundleExecutable</key><string>launch</string>
          <key>CFBundleIdentifier</key><string>studio.mcritchie.chrome-ordered</string>
          <key>CFBundleIconFile</key><string>app.icns</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>1.0</string>
          <key>LSMinimumSystemVersion</key><string>11.0</string>
          <key>LSArchitecturePriority</key><array><string>#{Runtime.host_arch}</string></array>
        </dict></plist>
      PLIST

      launch = File.join(dest, "Contents/MacOS/launch")
      File.write(launch, <<~SH)
        #!/bin/sh
        # Launches Google Chrome with #{FEATURE_FLAG} on, so "Other Chrome Profiles"
        # follows the custom order in Local State instead of sorting alphabetically.
        # Chrome 152 hides this flag in chrome://flags, so the wrapper is the only
        # route. Generated by bin/chrome-profiles install-wrapper.
        #
        # The `arch` switch IS LOAD-BEARING, not a flourish. Chrome ships a universal
        # binary, and exec'ing it from a shell script does NOT reliably select the
        # native slice — measured 2026-09-04 on an M4 Pro, a wrapper without this
        # ran the whole browser under Rosetta ("Code Type: X86-64 (translated)"),
        # with six renderers pinned near 100% CPU. The menu order was correct and
        # the browser was crawling. Verify after any edit here:
        #
        #   sample "$(pgrep -x 'Google Chrome' | head -1)" 1 -file /tmp/c.txt
        #   grep 'Code Type' /tmp/c.txt     # never "(translated)"
        #
        # The arch is taken from the HOST rather than hardcoded, so this matches
        # Runtime.chrome_translated?, which compares against `uname -m` for the
        # same reason: on an Intel Mac x86_64 IS native, and a hardcoded arm64
        # here would generate a launcher that cannot start Chrome at all.
        exec /usr/bin/arch -#{Runtime.host_arch} "#{CHROME_BIN}" \\
          --enable-features=#{FEATURE_FLAG} "$@"
      SH
      File.chmod(0o755, launch)

      icon = "#{CHROME_APP}/Contents/Resources/app.icns"
      FileUtils.cp(icon, File.join(dest, "Contents/Resources/app.icns")) if File.file?(icon)
      dest
    end
  end
  # ---------------------------------------------------------------------------
  # CLI surface — the dictionary bin/chrome-profiles hands CliArgGuard
  # ---------------------------------------------------------------------------
  #
  # Lives here rather than in the script so the guard call and the tests that
  # exercise it are the SAME call, with no second copy of the dictionary to
  # drift. Mirrors QaServerCli::COMMANDS.
  # The Dock tile is the launch path that decides this in practice. macOS keeps a
  # pinned app's identity in THREE places inside one tile, and they can disagree:
  # `file-data` (a URL), `bundle-identifier`, and `book` — an opaque BOOKMARK
  # blob. LaunchServices resolves `book` FIRST, so a tile edited by URL alone
  # snaps back to whatever the bookmark names.
  #
  # Measured 2026-09-04, after a reboot put the menu back in alphabetical order:
  # the stored order was intact and `ProfilesReordering` was simply absent from
  # the running process, because Chrome had been launched from the Dock's plain
  # `/Applications/Google Chrome.app` tile. Rewriting that tile's URL to the
  # wrapper changed the label and the bundle id and left the URL reverted — the
  # bookmark won. Deleting `book` is what makes the edit stick; the Dock rebuilds
  # it from the URL on the next write.
  module Dock
    PLIST_BUDDY  = "/usr/libexec/PlistBuddy"
    DOMAIN       = "com.apple.dock"
    BUNDLE_ID    = "studio.mcritchie.chrome-ordered"
    LABEL        = "Chrome (Ordered Profiles)"
    STALE_KEYS   = %w[book file-mod-date parent-mod-date].freeze

    module_function

    # file:///Applications/Google%20Chrome.app/ -> /Applications/Google Chrome.app/
    def decode(url)
      return nil if url.nil?

      url.sub(%r{\Afile://}, "").gsub(/%([0-9A-Fa-f]{2})/) { Regexp.last_match(1).hex.chr }
         .force_encoding(Encoding::UTF_8)
    end

    def encode(path)
      "file://#{path.b.gsub(%r{[^A-Za-z0-9\-._~/]}) { |c| format("%%%02X", c.ord) }}/"
    end

    # PlistBuddy prints a tile's `book` bookmark as RAW BYTES, so its output is
    # not valid UTF-8 and String#strip raises on it. Scrub before touching it.
    def buddy(plist, command)
      out = IO.popen([ PLIST_BUDDY, "-c", command, plist, { err: File::NULL } ], &:read)
      $?.success? ? out.force_encoding(Encoding::UTF_8).scrub("").strip : nil
    end

    def export(dest)
      ok = system("defaults", "export", DOMAIN, dest, out: File::NULL, err: File::NULL)
      ok && File.exist?(dest) ? dest : nil
    end

    # [index, decoded path] for the pinned tile that launches some Chrome —
    # either the stock app or the wrapper we may have already pointed it at.
    def chrome_tile(plist)
      index = 0
      while index < 200
        break if buddy(plist, "Print :persistent-apps:#{index}:tile-type").nil?

        path = decode(buddy(plist, "Print :persistent-apps:#{index}:tile-data:file-data:_CFURLString")).to_s
        bundle = buddy(plist, "Print :persistent-apps:#{index}:tile-data:bundle-identifier")
        return [ index, path ] if chrome_tile?(path, bundle)

        index += 1
      end
      nil
    end

    # Either the stock app, or the wrapper a previous run already pointed it at.
    def chrome_tile?(path, bundle)
      bundle == BUNDLE_ID ||
        path.chomp("/") == CHROME_APP ||
        path.chomp("/") == WRAPPER_APP
    end

    # What the Dock's Chrome tile launches today, or nil when none is pinned.
    def pinned
      with_export { |plist| chrome_tile(plist)&.last&.chomp("/") }
    end

    def pinned_wrapper? = pinned == WRAPPER_APP

    def pin_wrapper!(wrapper = WRAPPER_APP)
      raise "wrapper is not installed — run: bin/chrome-profiles install-wrapper" unless Runtime.wrapper_installed?

      with_export do |plist|
        index, = chrome_tile(plist)
        raise "no Chrome tile is pinned to the Dock, so there is nothing to repoint" if index.nil?

        STALE_KEYS.each { |key| buddy(plist, "Delete :persistent-apps:#{index}:tile-data:#{key}") }
        buddy(plist, "Set :persistent-apps:#{index}:tile-data:file-data:_CFURLString #{encode(wrapper)}")
        buddy(plist, "Set :persistent-apps:#{index}:tile-data:file-label #{LABEL}")
        buddy(plist, "Set :persistent-apps:#{index}:tile-data:bundle-identifier #{BUNDLE_ID}")

        raise "defaults import #{DOMAIN} failed" unless system("defaults", "import", DOMAIN, plist,
                                                               out: File::NULL, err: File::NULL)

        system("killall", "Dock", out: File::NULL, err: File::NULL)
        wrapper
      end
    end

    def with_export
      require "tmpdir"
      plist = File.join(Dir.tmpdir, "chrome-profiles-dock-#{Process.pid}.plist")
      return nil unless export(plist)

      yield plist
    ensure
      File.delete(plist) if plist && File.exist?(plist)
    end
  end

  module Cli
    # HELP MUST NOT EXIT 0. This script's exit 0 is a VERDICT — `status` returns
    # it only when the roster resolves cleanly against the machine, which is
    # what an SOP step gates on. Answering the universal safe probe with the
    # green light would be the same defect one meaning over.
    HELP_EXIT = 1

    USAGE = <<~TEXT
      usage: bin/chrome-profiles <command> [options]

        status            what the roster says vs what this Mac has (read-only)
        apply             quit Chrome, write the roster, relaunch, verify
        relaunch          menu went alphabetical? restart Chrome with the flag
        adopt             print a roster stanza from the CURRENT machine state
        emoji <char|U+..> is this codepoint in the system emoji font, or tofu?
        install-wrapper   (re)create the launcher that carries the feature flag
        pin-dock          point the Dock's Chrome tile at that launcher

      options
        --config PATH     read the roster from a FILE instead of 1Password
        --state PATH      Chrome Local State to read/write. A path that is NOT
                          the live one runs OFFLINE: no quit, no relaunch.
        --no-launch       apply only; do not relaunch Chrome afterwards

      SOP: docs/agents/agents/steffon/sops/chrome-profiles.md
    TEXT

    COMMANDS = {
      "status" => {
        synopsis: "bin/chrome-profiles status [--config PATH] [--state PATH]",
        consequence: "nothing was read into Chrome and no profile was renamed",
        bool: [], value: [ "--config", "--state" ], allow_positional: false
      },
      "apply" => {
        synopsis: "bin/chrome-profiles apply [--config PATH] [--state PATH] [--no-launch]",
        consequence: "Chrome was NOT quit and no profile was renamed or reordered",
        bool: [ "--no-launch" ], value: [ "--config", "--state" ], allow_positional: false
      },
      "relaunch" => {
        synopsis: "bin/chrome-profiles relaunch",
        consequence: "Chrome was NOT quit and is still running however it was launched",
        bool: [], value: [], allow_positional: false
      },
      "adopt" => {
        synopsis: "bin/chrome-profiles adopt [--state PATH]",
        consequence: "nothing was written and the roster on disk is unchanged",
        bool: [], value: [ "--state" ], allow_positional: false
      },
      "emoji" => {
        synopsis: "bin/chrome-profiles emoji <char-or-U+XXXX> [...]",
        consequence: "nothing was checked and no label was changed",
        bool: [], value: [], allow_positional: true
      },
      "install-wrapper" => {
        synopsis: "bin/chrome-profiles install-wrapper",
        consequence: "the launcher app was NOT created or modified",
        bool: [], value: [], allow_positional: false
      },
      "pin-dock" => {
        synopsis: "bin/chrome-profiles pin-dock",
        consequence: "the Dock is unchanged and still launches whatever it launched",
        bool: [], value: [], allow_positional: false
      }
    }.freeze

    module_function

    # nil when the token is not a subcommand at all (a bare `--help`, a typo, an
    # empty line) — the dispatcher's own `else` answers those with usage.
    def guard_args(command)
      spec = COMMANDS[command.to_s]
      return nil unless spec

      {
        program: "bin/chrome-profiles #{command}",
        usage: "usage: #{spec[:synopsis]}\n       NOT RUN — #{spec[:consequence]}.\n\n#{USAGE}",
        consequence: spec[:consequence],
        bool: spec[:bool],
        value: spec[:value],
        allow_positional: spec[:allow_positional],
        help_exit: HELP_EXIT
      }
    end
  end
end
