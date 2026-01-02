# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Hooks
        include Output

        HOOK_SCRIPT = <<~SCRIPT
          #!/bin/sh
          # git-pkgs auto-update hook
          git pkgs update 2>/dev/null || true
        SCRIPT

        HOOKS = %w[post-commit post-merge].freeze

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new

          if @options[:install]
            install_hooks(repo)
          elsif @options[:uninstall]
            uninstall_hooks(repo)
          else
            show_status(repo)
          end
        end

        def install_hooks(repo)
          hooks_dir = File.join(repo.git_dir, "hooks")

          HOOKS.each do |hook_name|
            hook_path = File.join(hooks_dir, hook_name)

            if File.exist?(hook_path)
              content = File.read(hook_path)
              if content.include?("git-pkgs")
                puts "Hook #{hook_name} already contains git-pkgs"
                next
              end

              File.open(hook_path, "a") do |f|
                f.puts "\n# git-pkgs auto-update"
                f.puts "git pkgs update 2>/dev/null || true"
              end
              puts "Appended git-pkgs to existing #{hook_name} hook"
            else
              File.write(hook_path, HOOK_SCRIPT)
              File.chmod(0o755, hook_path)
              puts "Created #{hook_name} hook"
            end
          end

          puts "Hooks installed successfully"
        end

        def uninstall_hooks(repo)
          hooks_dir = File.join(repo.git_dir, "hooks")

          HOOKS.each do |hook_name|
            hook_path = File.join(hooks_dir, hook_name)
            next unless File.exist?(hook_path)

            content = File.read(hook_path)

            if content.strip == HOOK_SCRIPT.strip
              File.delete(hook_path)
              puts "Removed #{hook_name} hook"
            elsif content.include?("git-pkgs")
              new_content = content.lines.reject { |line|
                line.include?("git-pkgs") || line.include?("git pkgs")
              }.join
              new_content = new_content.gsub(/\n# git-pkgs auto-update\n/, "\n")

              if new_content.strip.empty? || new_content.strip == "#!/bin/sh"
                File.delete(hook_path)
                puts "Removed #{hook_name} hook"
              else
                File.write(hook_path, new_content)
                puts "Removed git-pkgs from #{hook_name} hook"
              end
            end
          end

          puts "Hooks uninstalled successfully"
        end

        def show_status(repo)
          hooks_dir = File.join(repo.git_dir, "hooks")

          puts "Hook status:"
          HOOKS.each do |hook_name|
            hook_path = File.join(hooks_dir, hook_name)
            if File.exist?(hook_path) && File.read(hook_path).include?("git-pkgs")
              puts "  #{hook_name}: installed"
            else
              puts "  #{hook_name}: not installed"
            end
          end
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs hooks [options]"

            opts.on("-i", "--install", "Install git hooks for auto-updating") do
              options[:install] = true
            end

            opts.on("-u", "--uninstall", "Remove git hooks") do
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
