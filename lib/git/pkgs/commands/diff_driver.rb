# frozen_string_literal: true

require "bibliothecary"

module Git
  module Pkgs
    module Commands
      class DiffDriver
        include Output

        # Only lockfiles - manifests are human-readable and diff fine normally
        LOCKFILE_PATTERNS = %w[
          Brewfile.lock.json
          Cargo.lock
          Cartfile.resolved
          Gemfile.lock
          Gopkg.lock
          Package.resolved
          Pipfile.lock
          Podfile.lock
          Project.lock.json
          bun.lock
          composer.lock
          gems.locked
          glide.lock
          go.mod
          mix.lock
          npm-shrinkwrap.json
          package-lock.json
          packages.lock.json
          paket.lock
          pnpm-lock.yaml
          poetry.lock
          project.assets.json
          pubspec.lock
          pylock.toml
          shard.lock
          uv.lock
          yarn.lock
        ].freeze

        def initialize(args)
          @args = args
          @options = parse_options
          Config.configure_bibliothecary
        end

        def run
          if @options[:install]
            install_driver
            return
          end

          if @options[:uninstall]
            uninstall_driver
            return
          end

          # textconv mode: single file argument, output dependency list
          if @args.length == 1
            output_textconv(@args[0])
            return
          end

          error "Usage: git pkgs diff-driver <file>"
        end

        def output_textconv(file_path)
          content = read_file(file_path)
          deps = parse_deps(file_path, content)

          # Output sorted dependency list for git to diff
          deps.keys.sort.each do |name|
            dep = deps[name]
            # Only show type if it's not runtime (the default)
            type_suffix = dep[:type] && dep[:type] != "runtime" ? " [#{dep[:type]}]" : ""
            puts "#{name} #{dep[:requirement]}#{type_suffix}"
          end
        end

        def install_driver
          # Set up git config for textconv
          git_config("diff.pkgs.textconv", "git-pkgs diff-driver")

          # Add to .gitattributes
          gitattributes_path = File.join(work_tree, ".gitattributes")
          existing = File.exist?(gitattributes_path) ? File.read(gitattributes_path) : ""

          new_entries = []
          LOCKFILE_PATTERNS.each do |pattern|
            entry = "#{pattern} diff=pkgs"
            new_entries << entry unless existing.include?(entry)
          end

          if new_entries.any?
            File.open(gitattributes_path, "a") do |f|
              f.puts unless existing.end_with?("\n") || existing.empty?
              f.puts "# git-pkgs textconv for lockfiles"
              new_entries.each { |entry| f.puts entry }
            end
          end

          info "Installed textconv driver for lockfiles."
          info "  git config: diff.pkgs.textconv = git-pkgs diff-driver"
          info "  .gitattributes: #{new_entries.count} lockfile patterns added"
          info ""
          info "Now 'git diff' on lockfiles shows dependency changes."
          info "Use 'git diff --no-textconv' to see raw diff."
        end

        def uninstall_driver
          git_config_unset("diff.pkgs.textconv")

          gitattributes_path = File.join(work_tree, ".gitattributes")
          if File.exist?(gitattributes_path)
            lines = File.readlines(gitattributes_path)
            lines.reject! { |line| line.include?("diff=pkgs") || line.include?("# git-pkgs") }
            File.write(gitattributes_path, lines.join)
          end

          info "Uninstalled diff driver."
        end

        def read_file(path)
          return "" if path == "/dev/null"
          return "" unless File.exist?(path)

          File.read(path)
        end

        def parse_deps(path, content)
          return {} if content.empty?

          result = Bibliothecary.analyse_file(path, content).first
          return {} unless result
          return {} if Config.filter_ecosystem?(result[:platform])

          result[:dependencies].map { |d| [d[:name], d] }.to_h
        rescue StandardError
          {}
        end

        def work_tree
          Git::Pkgs.work_tree || Dir.pwd
        end

        def git_cmd
          if Git::Pkgs.git_dir
            ["git", "-C", work_tree]
          else
            ["git"]
          end
        end

        def git_config(key, value)
          system(*git_cmd, "config", key, value)
        end

        def git_config_unset(key)
          system(*git_cmd, "config", "--unset", key)
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs diff-driver <file>"
            opts.separator ""
            opts.separator "Outputs dependency list for git textconv diffing."

            opts.on("--install", "Install textconv driver for lockfiles") do
              options[:install] = true
            end

            opts.on("--uninstall", "Uninstall textconv driver") do
              options[:uninstall] = true
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options
        end
      end
    end
  end
end
