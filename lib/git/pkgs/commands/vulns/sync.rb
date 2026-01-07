# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        class Sync
          include Base

        def initialize(args)
          @args = args.dup
          @options = parse_options
        end

        def parse_options
          options = {}

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs vulns sync [options]"
            opts.separator ""
            opts.separator "Sync vulnerability data from OSV."
            opts.separator ""
            opts.separator "Options:"

            opts.on("--refresh", "Force refresh even if cache is recent") do
              options[:refresh] = true
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
            error "No database found. Run 'git pkgs init' first or use --stateless."
          end

          Database.connect(repo.git_dir)

          packages = Models::Package.all
          if packages.empty?
            info "No packages to sync. Run 'git pkgs vulns' first to populate packages."
            return
          end

          stale_packages = packages.select(&:needs_vuln_sync?)

          if stale_packages.empty? && !@options[:refresh]
            info "All packages up to date. Use --refresh to force update."
            return
          end

          packages_to_sync = @options[:refresh] ? packages : stale_packages

          info "Syncing vulnerabilities for #{packages_to_sync.count} packages..."

          client = OsvClient.new
          synced = 0
          vuln_count = 0

          packages_to_sync.each_slice(100) do |batch|
            queries = batch.map do |pkg|
              osv_ecosystem = Ecosystems.to_osv(pkg.ecosystem)
              next unless osv_ecosystem

              { ecosystem: osv_ecosystem, name: pkg.name }
            end.compact

            results = client.query_batch(queries)

            # Collect all unique vuln IDs from this batch to fetch full details
            vuln_ids = results.flatten.map { |v| v["id"] }.uniq

            # Fetch full vulnerability details and create records
            vuln_ids.each do |vuln_id|
              existing = Models::Vulnerability.first(id: vuln_id)
              next if existing&.vulnerability_packages&.any? && !@options[:refresh]

              begin
                full_vuln = client.get_vulnerability(vuln_id)
                Models::Vulnerability.from_osv(full_vuln)
                vuln_count += 1
              rescue OsvClient::ApiError
                # Skip vulnerabilities we can't fetch
              end
            end

            batch.each do |pkg|
              pkg.mark_vulns_synced
              synced += 1
            end
          end

          info "Synced #{synced} packages, found #{vuln_count} vulnerability records."
        end
        end
      end
    end
  end
end
