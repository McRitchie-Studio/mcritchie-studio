# frozen_string_literal: true

module Devops
  # THE DEVOPS READS, ONCE: everything the /deployments DevOps summary card and its
  # sidebar render, read in one place so the page load (TasksController#deployments)
  # and the live push (DeploymentsBroadcaster.devops_card) can never read them
  # differently.
  #
  # Before this object the controller and the broadcaster each carried their own copy
  # of the same five reads, and the broadcaster pushed only the card. So a release
  # changing phase re-rendered the card from its copy while the open sidebar kept the
  # page-load numbers: the card and the sidebar could disagree mid-release. Now one
  # snapshot feeds both slots, on the page and on the wire.
  #
  #   flow            Release::Flow over the recent shipped releases (the medians)
  #   estimate        the in-flight release's Release::Flow::Estimate, or nil
  #   wip_count       open tasks, pipeline-wide (never the board's filtered view)
  #   wip_by_stage    the same count split by stage, in board order
  #   stage_averages  the six legacy stage averages (tasks/_release_duration_card)
  #
  # The locals helpers name the partials' own locals, so a caller hands them over
  # whole rather than re-spelling the mapping.
  class Snapshot
    attr_reader :current_release, :flow, :estimate, :wip_count, :wip_by_stage, :stage_averages

    # `current_release` defaults to the singleton; the controller passes the one it
    # already read, so the page does not look it up twice.
    def self.build(current_release: Release.current)
      flow = Release::Flow.recent
      new(current_release: current_release,
          flow: flow,
          estimate: Release::Flow.estimate_for(current_release, default: flow),
          wip_count: Task.wip_count,
          wip_by_stage: Task.wip_by_stage,
          stage_averages: Release.deployment_stage_averages)
    end

    def initialize(current_release:, flow:, estimate:, wip_count:, wip_by_stage:, stage_averages:)
      @current_release = current_release
      @flow = flow
      @estimate = estimate
      @wip_count = wip_count
      @wip_by_stage = wip_by_stage
      @stage_averages = stage_averages
    end

    # tasks/_devops_summary_card
    def card_locals
      { flow: flow, estimate: estimate, wip_count: wip_count, wip_by_stage: wip_by_stage }
    end

    # tasks/_devops_sidebar_detail
    def sidebar_locals
      { flow: flow, wip_count: wip_count, wip_by_stage: wip_by_stage, dashboard: stage_averages }
    end
  end
end
