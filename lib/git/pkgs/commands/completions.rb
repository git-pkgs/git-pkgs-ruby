# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Completions
        COMMANDS = CLI::COMMANDS
        SUBCOMMAND_OPTIONS = {
          "hooks" => %w[--install --uninstall],
          "branch" => %w[--add --remove --list],
          "diff" => %w[--format],
          "list" => %w[--format --type],
          "tree" => %w[--format],
          "history" => %w[--format --limit],
          "search" => %w[--format --limit],
          "blame" => %w[--format],
          "stale" => %w[--days --format],
          "stats" => %w[--format],
          "log" => %w[--limit --format],
          "show" => %w[--format],
          "where" => %w[--format],
          "why" => %w[--format]
        }.freeze

        BASH_SCRIPT = <<~'BASH'
          _git_pkgs() {
            local cur prev commands
            COMPREPLY=()
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"

            commands="init update hooks info list tree history search where why blame stale stats diff branch show log upgrade schema completions"

            if [[ ${COMP_CWORD} -eq 2 && ${COMP_WORDS[1]} == "pkgs" ]]; then
              COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
              return 0
            fi

            if [[ ${COMP_CWORD} -eq 1 ]]; then
              COMPREPLY=( $(compgen -W "${commands}" -- ${cur}) )
              return 0
            fi

            case "${prev}" in
              hooks)
                COMPREPLY=( $(compgen -W "--install --uninstall --help" -- ${cur}) )
                ;;
              branch)
                COMPREPLY=( $(compgen -W "--add --remove --list --help" -- ${cur}) )
                ;;
              completions)
                COMPREPLY=( $(compgen -W "bash zsh install --help" -- ${cur}) )
                ;;
              diff|list|tree|history|search|blame|stale|stats|log|show|where|why)
                COMPREPLY=( $(compgen -W "--format --help" -- ${cur}) )
                ;;
            esac

            return 0
          }

          # Support both 'git pkgs' and 'git-pkgs' invocations
          complete -F _git_pkgs git-pkgs

          # For 'git pkgs' subcommand completion
          if declare -F _git >/dev/null 2>&1; then
            _git_pkgs_git_wrapper() {
              if [[ ${COMP_WORDS[1]} == "pkgs" ]]; then
                _git_pkgs
              fi
            }
          fi
        BASH

        ZSH_SCRIPT = <<~'ZSH'
          #compdef git-pkgs

          _git-pkgs() {
            local -a commands
            commands=(
              'init:Initialize the package database'
              'update:Update the database with new commits'
              'hooks:Manage git hooks for auto-updating'
              'info:Show database size and row counts'
              'branch:Manage tracked branches'
              'list:List dependencies at a commit'
              'tree:Show dependency tree grouped by type'
              'history:Show the history of a package'
              'search:Find a dependency across all history'
              'where:Show where a package appears in manifest files'
              'why:Explain why a dependency exists'
              'blame:Show who added each dependency'
              'stale:Show dependencies that have not been updated'
              'stats:Show dependency statistics'
              'diff:Show dependency changes between commits'
              'show:Show dependency changes in a commit'
              'log:List commits with dependency changes'
              'upgrade:Upgrade database after git-pkgs update'
              'schema:Show database schema'
              'completions:Generate shell completions'
            )

            _arguments -C \
              '1: :->command' \
              '*:: :->args'

            case $state in
              command)
                _describe -t commands 'git-pkgs commands' commands
                ;;
              args)
                case $words[1] in
                  hooks)
                    _arguments \
                      '--install[Install git hooks]' \
                      '--uninstall[Remove git hooks]' \
                      '--help[Show help]'
                    ;;
                  branch)
                    _arguments \
                      '--add[Add a branch to track]' \
                      '--remove[Remove a tracked branch]' \
                      '--list[List tracked branches]' \
                      '--help[Show help]'
                    ;;
                  completions)
                    _arguments '1:shell:(bash zsh install)'
                    ;;
                  diff|list|tree|history|search|blame|stale|stats|log|show|where|why)
                    _arguments \
                      '--format[Output format]:format:(table json csv)' \
                      '--help[Show help]'
                    ;;
                esac
                ;;
            esac
          }

          _git-pkgs "$@"
        ZSH

        def initialize(args)
          @args = args
        end

        def run
          shell = @args.first

          case shell
          when "bash"
            puts BASH_SCRIPT
          when "zsh"
            puts ZSH_SCRIPT
          when "install"
            install_completions
          when "-h", "--help", nil
            print_help
          else
            $stderr.puts "Unknown shell: #{shell}"
            $stderr.puts "Supported: bash, zsh, install"
            exit 1
          end
        end

        def install_completions
          shell = detect_shell

          case shell
          when "zsh"
            install_zsh_completions
          when "bash"
            install_bash_completions
          else
            $stderr.puts "Could not detect shell. Please run one of:"
            $stderr.puts "  eval \"$(git pkgs completions bash)\""
            $stderr.puts "  eval \"$(git pkgs completions zsh)\""
            exit 1
          end
        end

        def detect_shell
          shell_env = ENV["SHELL"] || ""
          if shell_env.include?("zsh")
            "zsh"
          elsif shell_env.include?("bash")
            "bash"
          end
        end

        def install_bash_completions
          dir = File.expand_path("~/.local/share/bash-completion/completions")
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "git-pkgs")
          File.write(path, BASH_SCRIPT)
          puts "Installed bash completions to #{path}"
          puts "Restart your shell or run: source #{path}"
        end

        def install_zsh_completions
          dir = File.expand_path("~/.zsh/completions")
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "_git-pkgs")
          File.write(path, ZSH_SCRIPT)
          puts "Installed zsh completions to #{path}"
          puts ""
          puts "Add to your ~/.zshrc if not already present:"
          puts "  fpath=(~/.zsh/completions $fpath)"
          puts "  autoload -Uz compinit && compinit"
          puts ""
          puts "Then restart your shell or run: source ~/.zshrc"
        end

        def print_help
          puts <<~HELP
            Usage: git pkgs completions <shell>

            Generate shell completion scripts.

            Shells:
              bash      Output bash completion script
              zsh       Output zsh completion script
              install   Auto-install completions for your shell

            Examples:
              git pkgs completions bash > ~/.local/share/bash-completion/completions/git-pkgs
              git pkgs completions zsh > ~/.zsh/completions/_git-pkgs
              eval "$(git pkgs completions bash)"
              git pkgs completions install
          HELP
        end
      end
    end
  end
end
