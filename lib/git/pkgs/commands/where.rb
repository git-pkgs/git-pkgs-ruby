# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Where
        include Output

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          name = @args.first

          error "Usage: git pkgs where <package-name>" unless name

          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)

          workdir = File.dirname(repo.git_dir)
          branch = Models::Branch.find_by(name: @options[:branch] || repo.default_branch)

          unless branch
            error "Branch not found. Run 'git pkgs init' first."
          end

          snapshots = Models::DependencySnapshot.current_for_branch(branch)
          snapshots = snapshots.where(ecosystem: @options[:ecosystem]) if @options[:ecosystem]

          manifest_paths = snapshots.for_package(name).joins(:manifest).pluck("manifests.path").uniq

          if manifest_paths.empty?
            empty_result "Package '#{name}' not found in current dependencies"
            return
          end

          results = manifest_paths.flat_map do |path|
            find_in_manifest(name, File.join(workdir, path), path)
          end

          if results.empty?
            empty_result "Package '#{name}' tracked but not found in current files"
            return
          end

          if @options[:format] == "json"
            output_json(results)
          else
            paginate { output_text(results, name) }
          end
        end

        def find_in_manifest(name, full_path, display_path)
          return [] unless File.exist?(full_path)

          lines = File.readlines(full_path)
          matches = []

          lines.each_with_index do |line, idx|
            next unless line.include?(name)

            match = { path: display_path, line: idx + 1, content: line.rstrip }

            if context_lines > 0
              match[:before] = context_before(lines, idx)
              match[:after] = context_after(lines, idx)
            end

            matches << match
          end

          matches
        end

        def context_lines
          @options[:context] || 0
        end

        def context_before(lines, idx)
          start_idx = [0, idx - context_lines].max
          (start_idx...idx).map { |i| { line: i + 1, content: lines[i].rstrip } }
        end

        def context_after(lines, idx)
          end_idx = [lines.length - 1, idx + context_lines].min
          ((idx + 1)..end_idx).map { |i| { line: i + 1, content: lines[i].rstrip } }
        end

        def output_text(results, name)
          results.each_with_index do |result, i|
            puts "--" if i > 0 && context_lines > 0

            result[:before]&.each do |ctx|
              puts format_context_line(result[:path], ctx[:line], ctx[:content])
            end

            puts format_match_line(result[:path], result[:line], result[:content], name)

            result[:after]&.each do |ctx|
              puts format_context_line(result[:path], ctx[:line], ctx[:content])
            end
          end
        end

        def format_match_line(path, line_num, content, name)
          path_str = Color.magenta(path)
          line_str = Color.green(line_num.to_s)
          highlighted = content.gsub(name, Color.red(name))
          "#{path_str}:#{line_str}:#{highlighted}"
        end

        def format_context_line(path, line_num, content)
          path_str = Color.magenta(path)
          line_str = Color.green(line_num.to_s)
          content_str = Color.dim(content)
          "#{path_str}-#{line_str}-#{content_str}"
        end

        def output_json(results)
          require "json"
          puts JSON.pretty_generate(results)
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs where <package-name> [options]"

            opts.on("-b", "--branch=NAME", "Branch to search (default: current)") do |v|
              options[:branch] = v
            end

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-C", "--context=NUM", Integer, "Show NUM lines of context") do |v|
              options[:context] = v
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("--no-pager", "Do not pipe output into a pager") do
              options[:no_pager] = true
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
