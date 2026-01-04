# frozen_string_literal: true

module Git
  module Pkgs
    module Color
      CODES = {
        red: 31,
        green: 32,
        yellow: 33,
        blue: 34,
        magenta: 35,
        cyan: 36,
        bold: 1,
        dim: 2
      }.freeze

      def self.enabled?
        return @enabled if defined?(@enabled)

        @enabled = determine_color_support
      end

      def self.enabled=(value)
        @enabled = value
      end

      def self.reset!
        remove_instance_variable(:@enabled) if defined?(@enabled)
      end

      def self.determine_color_support
        # NO_COLOR takes precedence (https://no-color.org/)
        return false if ENV["NO_COLOR"] && !ENV["NO_COLOR"].empty?
        return false if ENV["TERM"] == "dumb"

        # Check git config: color.pkgs takes precedence over color.ui
        git_color = git_color_config
        case git_color
        when "always" then return true
        when "never" then return false
        # "auto" falls through to TTY check
        end

        $stdout.respond_to?(:tty?) && $stdout.tty?
      end

      def self.git_color_config
        # color.pkgs overrides color.ui for git-pkgs specific control
        pkgs_color = `git config --get color.pkgs 2>/dev/null`.chomp
        return normalize_color_value(pkgs_color) unless pkgs_color.empty?

        ui_color = `git config --get color.ui 2>/dev/null`.chomp
        return normalize_color_value(ui_color) unless ui_color.empty?

        "auto"
      end

      def self.normalize_color_value(value)
        case value.downcase
        when "true", "always" then "always"
        when "false", "never" then "never"
        else "auto"
        end
      end

      def self.colorize(text, *codes)
        return text unless enabled?

        code_str = codes.map { |c| CODES[c] || c }.join(";")
        "\e[#{code_str}m#{text}\e[0m"
      end

      def self.red(text)     = colorize(text, :red)
      def self.green(text)   = colorize(text, :green)
      def self.yellow(text)  = colorize(text, :yellow)
      def self.blue(text)    = colorize(text, :blue)
      def self.magenta(text) = colorize(text, :magenta)
      def self.cyan(text)    = colorize(text, :cyan)
      def self.bold(text)    = colorize(text, :bold)
      def self.dim(text)     = colorize(text, :dim)
    end
  end
end
