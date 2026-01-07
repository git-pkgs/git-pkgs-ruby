# frozen_string_literal: true

require_relative "vulns/base"
require_relative "vulns/scan"
require_relative "vulns/sync"
require_relative "vulns/blame"
require_relative "vulns/praise"
require_relative "vulns/exposure"
require_relative "vulns/diff"
require_relative "vulns/log"
require_relative "vulns/history"
require_relative "vulns/show"

module Git
  module Pkgs
    module Commands
      class VulnsCommand
        SUBCOMMANDS = %w[sync blame praise exposure diff log history show].freeze

        def initialize(args)
          @args = args.dup
          @subcommand = detect_subcommand
        end

        def detect_subcommand
          return nil if @args.empty?
          return nil unless SUBCOMMANDS.include?(@args.first)

          @args.shift
        end

        def run
          handler_class = case @subcommand
                          when "sync" then Vulns::Sync
                          when "blame" then Vulns::Blame
                          when "praise" then Vulns::Praise
                          when "exposure" then Vulns::Exposure
                          when "diff" then Vulns::Diff
                          when "log" then Vulns::Log
                          when "history" then Vulns::History
                          when "show" then Vulns::Show
                          else Vulns::Scan
                          end

          handler_class.new(@args).run
        end
      end
    end
  end
end
