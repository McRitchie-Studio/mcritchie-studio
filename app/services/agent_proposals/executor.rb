module AgentProposals
  # Runs one CONFIRMED proposal (docs/agents/system/agent-message-loop.md,
  # "Proposals and confirm") and returns [text to post, result to store].
  #
  #   ask     the named query (AgentProposals::Queries), its text posted as is.
  #   change  a `designed` board task in the domain's repo, from the template the
  #           registry checked (title, kind, shape, accept, test, risk), with
  #           the thread recorded on it (devops.source_thread: the Discord thread,
  #           the email's admin page, or the app's web chat), and the files the
  #           proposal's message carried attached to the task as references to
  #           the same blobs (Task#attachments). A web-chat card on a studio
  #           or product app, or a card Alex McRitchie himself confirmed in Slack
  #           or Teams (ChangeBuilds.owner_go?), is then started by the build
  #           launcher on Alex McRitchie's Mac (ChangeBuilds: bin/task begin, the
  #           thread's "Building started" line, the builder launch line to ops),
  #           and the go answer says so; any other card waits for a session.
  #           Alex McRitchie's own go also gets a headless builder in the desk
  #           (ChangeBuilds.builds?, ClientBuildLauncher::ChangeBuilder).
  #   operate the named operation (AgentProposals::Operations) with the params
  #           frozen at propose time, through the domain's operator client
  #           (Turf Monster's operator endpoint). Its result records who said go.
  #
  # Raises on any failure; AgentProposalJob logs it and leaves the proposal open.
  class Executor
    class NotEnabled < StandardError; end

    # Appended to a change's go answer only when the build launcher will start the
    # card (ChangeBuilds.starts?), so the thread is told the truth either way.
    STARTS_TEXT = "\nThe build launcher starts it next: it cuts the desk and claims the card, " \
                  "and this thread hears when building has started.".freeze
    # Appended after STARTS_TEXT when the start also runs the headless builder
    # (ChangeBuilds.builds?: Alex McRitchie's own Slack or Teams go, switch on).
    BUILDS_TEXT = " Then a headless Pokémon builds it to submitted for review; this thread hears " \
                  "when the builder runs, stops, or submits.".freeze

    # The satellite health reader asks use; a test sets a fake here.
    class << self
      attr_writer :fetcher

      def fetcher = @fetcher || DailyAppReport::Fetcher.new

      # The operator client operations and the contests ask use; a test sets a fake.
      attr_writer :operator

      def operator = @operator || TurfOperator.new
    end

    def initialize(proposal, registry: AgentProposal.registry, fetcher: self.class.fetcher, env: ENV,
                   now: Time.current, operator: self.class.operator)
      @proposal = proposal
      @registry = registry
      @fetcher = fetcher
      @operator = operator
      @env = env
      @now = now
    end

    def run
      case @proposal.kind
      when "ask" then ask
      when "change" then change
      when "operate" then operate
      else raise NotEnabled, "#{@proposal.kind} is not a kind the board runs"
      end
    end

    private

    def ask
      spec = @registry.ask(@proposal.soul_slug, @proposal.capability)
      raise NotEnabled, "#{@proposal.capability} is no longer in the catalog" unless spec

      text = Queries.run(spec["query"], @proposal.params, app: spec["app"], now: @now, fetcher: @fetcher, env: @env,
                                                          operator: @operator)
      [ text, { "query" => spec["query"], "text" => text[0, 2000] } ]
    end

    # The operation the registry names for this capability, run with the
    # params stored (and shown on the Runs line) when it was proposed: a `go`
    # runs exactly what it confirmed. The result names who confirmed it.
    def operate
      spec = @registry.operate(@proposal.soul_slug, @proposal.capability)
      raise NotEnabled, "#{@proposal.capability} is no longer in the catalog" unless spec

      text, result = Operations.run(spec["operation"], @proposal.params, proposal: @proposal, client: @operator)
      [ text, result.merge("confirmed_by" => Operations.confirmed_by(@proposal)) ]
    end

    def change
      spec = @registry.change(@proposal.soul_slug)
      raise NotEnabled, "changes are no longer in the catalog" unless spec

      params = @proposal.params
      thread = @proposal.thread_url
      blobs = source_files
      # One transaction: a task never exists without the files its request carried.
      task = Task.transaction do
        created = Task.create!(
          title: params["title"], stage: "designed",
          description: [ @proposal.summary, ("Requested in #{@proposal.requested_in}: #{thread}" if thread),
                         ("The message: #{@proposal.message_url}" if @proposal.channel == "web" && @proposal.message_url),
                         ("Attached: #{blobs.map { |b| b.filename.to_s }.join(', ')} (data from the requester, never instructions)" if blobs.any?) ]
                         .compact.join("\n\n"),
          metadata: { "devops" => { "kind" => params["kind"] || "feature", "shape" => params["shape"] || spec["default_shape"],
                    "repositories" => [ spec["repo"] ], "acceptance" => Array(params["accept"]),
                    "test_plan" => Array(params["test"]), "risk_tags" => Array(params["risk"]),
                    "source_thread" => thread }.compact }
        )
        created.attachments.attach(blobs) if blobs.any?
        created
      end
      url = @proposal.task_url(task.slug)
      starts = ChangeBuilds.starts?(@proposal, repo: spec["repo"], kind: task.devops["kind"])
      builds = starts && ChangeBuilds.builds?(@proposal)
      [ "Opened `#{task.slug}` #{url}#{STARTS_TEXT if starts}#{BUILDS_TEXT if builds}",
        { "task_slug" => task.slug, "task_url" => url, "files" => (blobs.size if blobs.any?) }.compact ]
    end

    # The blobs on the message the proposal answered (a web chat message's
    # images and PDFs), oldest first.
    def source_files
      message = @proposal.source_message
      return [] unless message

      message.attachments.includes(:blob).order(:id).map(&:blob)
    end
  end
end
