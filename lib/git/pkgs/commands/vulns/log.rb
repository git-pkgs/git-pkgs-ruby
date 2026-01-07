# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Log
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns log [options]"
            opts.separator ""
            opts.separator "Show commits that introduced or fixed vulnerabilities."
            opts.separator ""
            opts.separator "Options:"

            opts.on("-e", "--ecosystem=NAME", "Filter by ecosystem") do |v|
              options[:ecosystem] = v
            end

            opts.on("-s", "--severity=LEVEL", "Minimum severity (critical, high, medium, low)") do |v|
              options[:severity] = v
            end

            opts.on("-b", "--branch=NAME", "Branch to analyze") do |v|
              options[:branch] = v
            end

            opts.on("--since=DATE", "Show commits after date") do |v|
              options[:since] = v
            end

            opts.on("--until=DATE", "Show commits before date") do |v|
              options[:until] = v
            end

            opts.on("--author=NAME", "Filter by author") do |v|
              options[:author] = v
            end

            opts.on("--introduced", "Show only commits that introduced vulnerabilities") do
              options[:introduced] = true
            end

            opts.on("--fixed", "Show only commits that fixed vulnerabilities") do
              options[:fixed] = true
            end

            opts.on("-f", "--format=FORMAT", "Output format (text, json)") do |v|
              options[:format] = v
            end

            opts.on("-h", "--help", "Show this help") do
              puts opts
              exit
            end
          end

          parser.parse!(@args)
          options
        end

        def run
          repo = Repository.new

          unless Database.exists?(repo.git_dir)
            error "No database found. Run 'git pkgs init' first. Log requires commit history."
          end

          Database.connect(repo.git_dir)

          commits_with_vulns = find_commits_with_vuln_changes(repo)

          if commits_with_vulns.empty?
            puts "No commits with vulnerability changes found"
            return
          end

          if @options[:format] == "json"
            require "json"
            puts JSON.pretty_generate(commits_with_vulns)
          else
            output_vuln_log(commits_with_vulns)
          end
        end

        def find_commits_with_vuln_changes(repo)
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)
          return [] unless branch

          commits_query = Models::Commit
            .join(:branch_commits, commit_id: :id)
            .where(Sequel[:branch_commits][:branch_id] => branch.id)
            .where(has_dependency_changes: true)
            .order(Sequel.desc(Sequel[:commits][:committed_at]))

          if @options[:since]
            since_time = parse_date(@options[:since])
            commits_query = commits_query.where { Sequel[:commits][:committed_at] >= since_time }
          end

          if @options[:until]
            until_time = parse_date(@options[:until])
            commits_query = commits_query.where { Sequel[:commits][:committed_at] <= until_time }
          end

          if @options[:author]
            commits_query = commits_query.where(Sequel.ilike(:author_name, "%#{@options[:author]}%"))
          end

          commits = commits_query.all
          results = []

          ensure_vulns_synced

          commits.each do |commit|
            changes = commit.dependency_changes.to_a
            vuln_changes = []

            changes.each do |change|
              next unless Ecosystems.supported?(change.ecosystem)

              osv_ecosystem = Ecosystems.to_osv(change.ecosystem)
              next unless osv_ecosystem

              vuln_pkgs = Models::VulnerabilityPackage
                .where(ecosystem: osv_ecosystem, package_name: change.name)
                .eager(:vulnerability)
                .all

              vuln_pkgs.each do |vp|
                next if vp.vulnerability&.withdrawn?

                current_affected = change.requirement && vp.affects_version?(change.requirement)
                previous_affected = change.previous_requirement && vp.affects_version?(change.previous_requirement)

                case change.change_type
                when "added"
                  if current_affected
                    vuln_changes << { type: :introduced, vuln_id: vp.vulnerability_id, severity: vp.vulnerability&.severity }
                  end
                when "modified"
                  if current_affected && !previous_affected
                    vuln_changes << { type: :introduced, vuln_id: vp.vulnerability_id, severity: vp.vulnerability&.severity }
                  elsif !current_affected && previous_affected
                    vuln_changes << { type: :fixed, vuln_id: vp.vulnerability_id, severity: vp.vulnerability&.severity }
                  end
                when "removed"
                  if previous_affected
                    vuln_changes << { type: :fixed, vuln_id: vp.vulnerability_id, severity: vp.vulnerability&.severity }
                  end
                end
              end
            end

            next if vuln_changes.empty?

            if @options[:introduced]
              vuln_changes = vuln_changes.select { |vc| vc[:type] == :introduced }
            elsif @options[:fixed]
              vuln_changes = vuln_changes.select { |vc| vc[:type] == :fixed }
            end

            next if vuln_changes.empty?

            results << {
              sha: commit.sha[0, 7],
              full_sha: commit.sha,
              date: commit.committed_at&.strftime("%Y-%m-%d"),
              author: commit.author_name,
              message: commit.message&.lines&.first&.strip&.slice(0, 40),
              vuln_changes: vuln_changes
            }
          end

          results
        end

        def output_vuln_log(results)
          results.each do |result|
            sha = result[:sha]
            date = result[:date]
            author = result[:author]
            message = result[:message]

            vuln_summary = result[:vuln_changes].map do |vc|
              prefix = vc[:type] == :introduced ? "+" : "-"
              "#{prefix}#{vc[:vuln_id]}"
            end.join(" ")

            introduced_count = result[:vuln_changes].count { |vc| vc[:type] == :introduced }
            fixed_count = result[:vuln_changes].count { |vc| vc[:type] == :fixed }

            line = "#{sha}  #{date}  #{author.to_s.ljust(15)[0, 15]}  \"#{message}\"  #{vuln_summary}"
            colored_line = if introduced_count > fixed_count
                             Color.red(line)
                           elsif fixed_count > introduced_count
                             Color.green(line)
                           else
                             line
                           end
            puts colored_line
          end
        end
        end
      end
    end
  end
end
