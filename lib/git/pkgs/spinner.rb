# frozen_string_literal: true

module Git
  module Pkgs
    class Spinner
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
      INTERVAL = 0.08

      def initialize(message)
        @message = message
        @running = false
        @thread = nil
      end

      def start
        return unless $stdout.tty? && !Git::Pkgs.quiet

        @running = true
        @frame_index = 0
        @thread = Thread.new do
          while @running
            print "\r#{FRAMES[@frame_index]} #{@message}"
            @frame_index = (@frame_index + 1) % FRAMES.length
            sleep INTERVAL
          end
        end
      end

      def stop
        return unless @thread

        @running = false
        @thread.join
        print "\r#{" " * (@message.length + 3)}\r"
      end

      def self.with_spinner(message)
        spinner = new(message)
        spinner.start
        yield
      ensure
        spinner.stop
      end
    end
  end
end
