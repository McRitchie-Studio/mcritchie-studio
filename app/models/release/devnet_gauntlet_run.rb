# frozen_string_literal: true

require "json"

class Release
  # THE DEVNET GAUNTLET, RUN BY PREPARE. Release::DevnetGauntlet says what `ship`
  # demands (a completed `devnet_gauntlet` event on a Turf release); this runs the
  # thing that earns it, so the rehearsal is no longer a manual step after prepare.
  # On 2026-10-28 `bin/release ship` refused rel-20261028-6b946d for want of one and
  # an agent ran the rehearsal by hand.
  #
  # It is the unattended run of Turf Monster's contest-rehearsal
  # (docs/agents/agents/turf_monster/sops/contest-rehearsal.md, "Unattended"): every
  # step of turf-monster's `bin/qa-contest-rehearsal` in order, the check each
  # `── STOP ──` block names made here instead of by a person, then the payout
  # arithmetic from the settle transaction's own token balances.
  #
  # IO-free and Rails-free, like Release::DevnetGauntlet: bin/release requires this
  # file directly, and every effect comes in as a callable, so the tests drive it
  # with a fake driver and never touch QA or devnet.
  #
  #   driver.call(argv, budget) -> [output, ok]  one `bin/qa-contest-rehearsal` step;
  #                                              budget is the seconds the overall
  #                                              deadline leaves (nil: no overall bound)
  #   manifest.call             -> Hash          the driver's tmp/qa-rehearsal/current.json
  #   transaction.call(sig)     -> Hash | nil    devnet getTransaction's `result`
  #   say.call(line)
  class DevnetGauntletRun
    # [label, argv]. The order and the flags are the SOP's unattended run: step 3 a
    # bare `play` (no --pace), step 4 co-signed by the seated devnet agent key.
    STEPS = [
      ["seed", %w[seed]],
      ["create", %w[create]],
      ["enter", %w[enter]],
      ["play", %w[play]],
      ["conclude", %w[conclude --cosign agent]],
      ["close", %w[close]]
    ].freeze

    # The rehearsal's tier funds a $500 pool (contest-rehearsal.md, step 1).
    EXPECTED_POOL = "$500"

    Result = Struct.new(:ok, :step, :reason, :metadata, keyword_init: true) do
      def ok? = ok
    end

    class Red < StandardError
      attr_reader :step

      def initialize(step, reason)
        @step = step
        super(reason)
      end
    end

    # `deadline` bounds the WHOLE run in seconds (nil: unbounded), on top of each
    # step's own bound: six steps at a 1200s step bound could otherwise hold prepare
    # for two hours. `deadline_env` is the name that sets it, for the red's reason.
    # `clock` answers monotonic seconds (a fake in the tests).
    def initialize(driver:, manifest:, transaction:, say: ->(_line) { }, deadline: nil, deadline_env: nil,
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @driver = driver
      @manifest = manifest
      @transaction = transaction
      @say = say
      @deadline = deadline
      @deadline_env = deadline_env
      @clock = clock
      @facts = { "steps" => {} }
    end

    # Runs every step, stopping at the first red one. Never raises: the Result
    # names the step that went red and why, and carries what was learned so far.
    def call
      @started = @clock.call
      STEPS.each do |label, argv|
        @current = label
        budget = remaining
        raise Red.new(label, out_of_time("before step `#{label}` started")) if budget && budget <= 0

        @say.call("  gauntlet #{label}: bin/qa-contest-rehearsal #{argv.join(' ')}")
        output, ok = @driver.call(argv, budget)
        output = output.to_s
        @facts["steps"][label] = { "elapsed" => elapsed(output) }.compact
        # A step the overall bound cut short is the deadline's red, not the step's.
        raise Red.new(label, out_of_time("during step `#{label}`")) if !ok && remaining&.<=(0)

        check!(label, output, ok)
      end
      @current = "arithmetic"
      raise Red.new("arithmetic", out_of_time("before step `arithmetic` started")) if remaining&.<=(0)

      check_arithmetic!
      Result.new(ok: true, step: nil, reason: nil, metadata: @facts)
    rescue Red => e
      red(e.step, e.message)
    rescue StandardError => e
      red(@current, "#{e.class}: #{e.message}")
    end

    private

    # Seconds the overall deadline leaves, or nil when there is none.
    def remaining = @deadline && (@deadline - (@clock.call - @started))

    def out_of_time(moment)
      setter = @deadline_env ? " (#{@deadline_env} sets it)" : ""
      "the gauntlet's overall deadline of #{@deadline.round}s ran out #{moment}#{setter}"
    end

    def red(step, reason)
      Result.new(ok: false, step: step, reason: reason, metadata: @facts.merge("failed_step" => step, "reason" => reason))
    end

    def check!(label, output, ok)
      stopped = output[/^\s*STOPPED — .*$/]
      raise Red.new(label, stopped.strip) if stopped
      raise Red.new(label, "exited non-zero#{last_line(output)}") unless ok

      send(:"check_#{label}!", output)
    end

    def check_seed!(output)
      raise Red.new("seed", "no `roster:` line naming the parked usernames") unless output.match?(/^\s*roster:\s+\S/)
    end

    def check_create!(output)
      slug = output[/^\s*contest:\s+(\S+)/, 1]
      raise Red.new("create", "no `contest:` line naming the rehearsal contest") unless slug
      unless output.match?(/on-chain:\s+yes\s+·\s+pool\s+#{Regexp.escape(EXPECTED_POOL)}\b/)
        raise Red.new("create", "expected `on-chain: yes · pool #{EXPECTED_POOL}`#{line_with(output, 'on-chain:')}")
      end

      @facts["contest"] = slug
    end

    def check_enter!(output)
      return if output.match?(/^\s*all \d+ entered\s*$/)

      raise Red.new("enter", "not every cast member entered#{line_with(output, 'FAILED')}")
    end

    def check_play!(output)
      failed = output[/^\s*replay: CATCH-UP FAILED — .*$/]
      raise Red.new("play", failed.strip) if failed
      raise Red.new("play", "no `replay: caught up — …` line") unless output.match?(/^\s*replay: caught up — /)
    end

    def check_conclude!(output)
      line = output[/^\s*confirmed: .*$/]
      raise Red.new("conclude", "no `confirmed:` line: the settle was not confirmed") unless line
      raise Red.new("conclude", "the settle did not read onchain_settled true: #{line.strip}") unless line.match?(/"onchain_settled"\s*=>\s*true/)

      signature = line[/"tx_signature"\s*=>\s*"([^"]+)"/, 1]
      raise Red.new("conclude", "the `confirmed:` line carries no tx_signature: #{line.strip}") unless signature

      @facts["settle_signature"] = signature
    end

    def check_close!(output)
      line = output[/^\s*closed: .*$/]
      signature = line && line[/"signature"\s*=>\s*"([^"]+)"/, 1]
      raise Red.new("close", "no `closed:` line with a signature#{line ? ": #{line.strip}" : ''}") unless signature

      @facts["close_signature"] = signature
    end

    # The proof the payout landed (contest-rehearsal.md, step 4): from the settle
    # transaction's own pre/post token balances, the prize escrow falls by exactly
    # the sum paid and each winner's balance rises by exactly its rank's payout.
    def check_arithmetic!
      winners = Array(read_manifest["winners"])
      raise Red.new("arithmetic", "the rehearsal manifest names no winners") if winners.empty?

      tx = fetch_transaction
      meta = tx.is_a?(Hash) ? tx["meta"] : nil
      raise Red.new("arithmetic", "getTransaction(#{@facts['settle_signature']}) returned no meta") unless meta.is_a?(Hash)
      raise Red.new("arithmetic", "the settle transaction failed on chain: #{meta['err'].inspect}") if meta["err"]

      deltas, decimals = owner_deltas(meta)
      unit = 10**(decimals - 2) # token base units per cent

      owed = Hash.new(0)
      winners.each { |w| owed[w["wallet"].to_s] += Integer(w["payout_cents"]) }
      owed.each do |wallet, cents|
        got = deltas.fetch(wallet, 0)
        next if got == cents * unit

        raise Red.new("arithmetic", "winner #{wallet} rose by #{got} base units; its payout is #{cents} cents " \
                                    "(#{cents * unit} base units)")
      end

      paid = owed.values.sum
      escrow, fell = deltas.reject { |owner, _| owed.key?(owner) }.min_by { |_, delta| delta }
      unless escrow && fell == -(paid * unit)
        raise Red.new("arithmetic", "the prize escrow fell by #{fell ? -fell : 0} base units; the sum paid is " \
                                    "#{paid} cents (#{paid * unit} base units)")
      end

      @facts["arithmetic"] = { "paid_cents" => paid, "escrow_owner" => escrow, "winners" => owed.size }
      @say.call("  gauntlet arithmetic: escrow #{escrow[0, 8]}… fell #{paid} cents; " \
                "#{owed.size} winner(s) rose by their rank payouts")
    end

    def read_manifest
      data = @manifest.call
      data.is_a?(Hash) ? data : {}
    rescue StandardError => e
      raise Red.new("arithmetic", "could not read the rehearsal manifest: #{e.message}")
    end

    def fetch_transaction
      @transaction.call(@facts.fetch("settle_signature"))
    rescue StandardError => e
      raise Red.new("arithmetic", "getTransaction failed: #{e.message}")
    end

    # { owner => post - pre } in base units, for the one mint the transaction moved,
    # and that mint's decimals. An account created by the transaction has no pre row.
    def owner_deltas(meta)
      pre = Array(meta["preTokenBalances"])
      post = Array(meta["postTokenBalances"])
      mints = (pre + post).map { |b| b["mint"] }.uniq
      raise Red.new("arithmetic", "the settle moved #{mints.size} mints; expected one") unless mints.size == 1

      deltas = Hash.new(0)
      decimals = nil
      [[post, 1], [pre, -1]].each do |rows, sign|
        rows.each do |row|
          amount = row.dig("uiTokenAmount", "amount")
          decimals ||= row.dig("uiTokenAmount", "decimals")
          deltas[row["owner"].to_s] += sign * Integer(amount)
        end
      end
      raise Red.new("arithmetic", "token balances carry no decimals") unless decimals.is_a?(Integer) && decimals >= 2

      [deltas, decimals]
    end

    def elapsed(output) = output[/^\s*elapsed: (\d+)s/, 1]&.to_i

    # The driver's own last word, never its trailing `elapsed:` line (it prints that
    # in an ensure, after the error that ended the step).
    def last_line(output)
      line = output.lines.map(&:strip).reject { |l| l.empty? || l.match?(/\Aelapsed: \d+s/) }.last
      line ? ": #{line}" : ""
    end

    def line_with(output, needle)
      line = output.lines.find { |l| l.include?(needle) }
      line ? ": #{line.strip}" : ""
    end
  end
end
