# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      module Vulns
        module Base
          include Output

        SEVERITY_ORDER = { "critical" => 0, "high" => 1, "medium" => 2, "low" => 3, nil => 4 }.freeze

        def compute_dependencies_at_commit(target_commit, repo)
          branch_name = @options[:branch] || repo.default_branch
          branch = Models::Branch.first(name: branch_name)
          return [] unless branch

          snapshot_commit = branch.commits_dataset
            .join(:dependency_snapshots, commit_id: :id)
            .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
            .order(Sequel.desc(Sequel[:commits][:committed_at]))
            .distinct
            .first

          deps = {}
          if snapshot_commit
            snapshot_commit.dependency_snapshots.each do |s|
              key = [s.manifest.path, s.name]
              deps[key] = {
                manifest_path: s.manifest.path,
                manifest_kind: s.manifest.kind,
                name: s.name,
                ecosystem: s.ecosystem,
                requirement: s.requirement,
                dependency_type: s.dependency_type
              }
            end
          end

          if snapshot_commit && snapshot_commit.id != target_commit.id
            commit_ids = branch.commits_dataset.select_map(Sequel[:commits][:id])
            changes = Models::DependencyChange
              .join(:commits, id: :commit_id)
              .where(Sequel[:commits][:id] => commit_ids)
              .where { Sequel[:commits][:committed_at] > snapshot_commit.committed_at }
              .where { Sequel[:commits][:committed_at] <= target_commit.committed_at }
              .order(Sequel[:commits][:committed_at])
              .eager(:manifest)
              .all

            changes.each do |change|
              key = [change.manifest.path, change.name]
              case change.change_type
              when "added", "modified"
                deps[key] = {
                  manifest_path: change.manifest.path,
                  manifest_kind: change.manifest.kind,
                  name: change.name,
                  ecosystem: change.ecosystem,
                  requirement: change.requirement,
                  dependency_type: change.dependency_type
                }
              when "removed"
                deps.delete(key)
              end
            end
          end

          deps.values
        end

        def scan_for_vulnerabilities(deps)
          vulns = []

          # Pair manifests with lockfiles by directory and ecosystem
          # Prefer lockfile versions over manifest constraints
          paired = Analyzer.pair_manifests_with_lockfiles(deps)

          # Deduplicate across directories by ecosystem+name
          deduped = {}
          paired.each do |dep|
            osv_ecosystem = Ecosystems.to_osv(dep[:ecosystem])
            next unless osv_ecosystem

            key = [osv_ecosystem, dep[:name]]
            existing = deduped[key]

            # Prefer more specific versions: actual version > constraint
            if existing.nil? || more_specific_version?(dep[:requirement], existing[:version])
              deduped[key] = {
                ecosystem: osv_ecosystem,
                name: dep[:name],
                version: dep[:requirement],
                original: dep
              }
            end
          end

          packages = deduped.values

          packages_needing_sync = packages.reject do |pkg|
            package_synced?(pkg[:ecosystem], pkg[:name])
          end

          sync_packages(packages_needing_sync) if packages_needing_sync.any?

          packages.each do |pkg|
            vuln_pkgs = Models::VulnerabilityPackage
              .for_package(pkg[:ecosystem], pkg[:name])
              .eager(:vulnerability)
              .all

            vuln_pkgs.each do |vp|
              next unless vp.affects_version?(pkg[:version])
              next if vp.vulnerability&.withdrawn?

              vulns << {
                id: vp.vulnerability_id,
                severity: vp.vulnerability&.severity,
                cvss_score: vp.vulnerability&.cvss_score,
                package_name: pkg[:name],
                package_version: pkg[:version],
                ecosystem: pkg[:original][:ecosystem],
                manifest_path: pkg[:original][:manifest_path],
                summary: vp.vulnerability&.summary,
                fixed_versions: vp.fixed_versions_list.first
              }
            end
          end

          vulns
        end

        def package_synced?(ecosystem, name)
          purl = Ecosystems.generate_purl(Ecosystems.from_osv(ecosystem), name)
          return false unless purl

          pkg = Models::Package.first(purl: purl)
          pkg && !pkg.needs_vuln_sync?
        end

        def sync_packages(packages)
          return if packages.empty?

          client = OsvClient.new
          results = begin
            client.query_batch(packages.map { |p| p.slice(:ecosystem, :name, :version) })
          rescue OsvClient::ApiError => e
            error "Failed to query OSV API: #{e.message}"
          end

          fetch_vulnerability_details(client, results)

          packages.each do |pkg|
            bib_ecosystem = Ecosystems.from_osv(pkg[:ecosystem])
            purl = Ecosystems.generate_purl(bib_ecosystem, pkg[:name])
            mark_package_synced(purl, bib_ecosystem, pkg[:name]) if purl
          end
        end

        def ensure_vulns_synced
          packages = Models::DependencyChange
            .select(:ecosystem, :name)
            .select_group(:ecosystem, :name)
            .all

          packages_to_sync = packages.select do |pkg|
            next false unless Ecosystems.supported?(pkg.ecosystem)

            purl = Ecosystems.generate_purl(pkg.ecosystem, pkg.name)
            next false unless purl

            db_pkg = Models::Package.first(purl: purl)
            !db_pkg || db_pkg.needs_vuln_sync?
          end

          return if packages_to_sync.empty?

          client = OsvClient.new
          packages_to_sync.each_slice(100) do |batch|
            queries = batch.map do |pkg|
              osv_ecosystem = Ecosystems.to_osv(pkg.ecosystem)
              next unless osv_ecosystem

              { ecosystem: osv_ecosystem, name: pkg.name }
            end.compact

            results = client.query_batch(queries)
            fetch_vulnerability_details(client, results)

            batch.each do |pkg|
              purl = Ecosystems.generate_purl(pkg.ecosystem, pkg.name)
              mark_package_synced(purl, pkg.ecosystem, pkg.name) if purl
            end
          end
        end

        def fetch_vulnerability_details(client, results)
          vuln_ids = results.flatten.map { |v| v["id"] }.uniq
          vuln_ids.each do |vuln_id|
            next if Models::Vulnerability.first(id: vuln_id)&.vulnerability_packages&.any?

            begin
              full_vuln = client.get_vulnerability(vuln_id)
              Models::Vulnerability.from_osv(full_vuln)
            rescue OsvClient::ApiError => e
              $stderr.puts "Warning: Failed to fetch vulnerability #{vuln_id}: #{e.message}" unless Git::Pkgs.quiet
            end
          end
        end

        def mark_package_synced(purl, ecosystem, name)
          Models::Package.update_or_create(
            { purl: purl },
            { ecosystem: ecosystem, name: name, vulns_synced_at: Time.now }
          )
        end

        def format_commit_info(commit)
          return nil unless commit

          {
            sha: commit.sha[0, 7],
            full_sha: commit.sha,
            date: commit.committed_at&.strftime("%Y-%m-%d"),
            author: best_author(commit),
            message: commit.message&.lines&.first&.strip&.slice(0, 50)
          }
        end

        def parse_date(date_str)
          Time.parse(date_str)
        rescue ArgumentError
          error "Invalid date format: #{date_str}"
        end

        def find_introducing_change(ecosystem, package_name, vuln_pkg, up_to_commit)
          changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[added modified])
            .where { Sequel[:commits][:committed_at] <= up_to_commit.committed_at }
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          changes.each do |change|
            next unless vuln_pkg.affects_version?(change.requirement)
            return change
          end

          nil
        end

        def find_fixing_change(ecosystem, package_name, vuln_pkg, up_to_commit, after_time)
          return nil unless after_time

          changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[modified removed])
            .where { Sequel[:commits][:committed_at] > after_time }
            .where { Sequel[:commits][:committed_at] <= up_to_commit.committed_at }
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          find_first_fixing_change(changes, vuln_pkg)
        end

        def find_first_fixing_change(changes, vuln_pkg)
          changes.each do |change|
            if change.change_type == "removed"
              return change
            elsif !vuln_pkg.affects_version?(change.requirement)
              return change
            end
          end
          nil
        end

        def find_vulnerability_window(ecosystem, package_name, vuln_pkg)
          introducing_changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[added modified])
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          introducing_change = introducing_changes.find { |c| vuln_pkg.affects_version?(c.requirement) }
          return nil unless introducing_change

          introduced_at = introducing_change.commit.committed_at

          fix_changes = Models::DependencyChange
            .join(:commits, id: :commit_id)
            .where(ecosystem: ecosystem, name: package_name)
            .where(change_type: %w[modified removed])
            .where { Sequel[:commits][:committed_at] > introduced_at }
            .order(Sequel[:commits][:committed_at])
            .eager(:commit)
            .all

          fixing_change = find_first_fixing_change(fix_changes, vuln_pkg)

          {
            introducing: introducing_change,
            fixing: fixing_change,
            status: fixing_change ? "fixed" : "ongoing"
          }
        end

        def get_dependencies_stateless(repo)
          ref = @options[:ref] || "HEAD"
          commit_sha = repo.rev_parse(ref)
          rugged_commit = repo.lookup(commit_sha)

          error "Could not resolve '#{ref}'. Check that the ref exists." unless rugged_commit

          analyzer = Analyzer.new(repo)
          analyzer.dependencies_at_commit(rugged_commit)
        end

        def get_dependencies_with_database(repo)
          ref = @options[:ref] || "HEAD"
          commit_sha = repo.rev_parse(ref)
          target_commit = Models::Commit.first(sha: commit_sha)

          # Fall back to stateless mode if commit not tracked
          return get_dependencies_stateless(repo) unless target_commit

          compute_dependencies_at_commit(target_commit, repo)
        end

        # Returns true if `new_version` is more specific than `old_version`.
        # Actual version numbers are preferred over loose constraints like ">= 0".
        def more_specific_version?(new_version, old_version)
          return false if new_version.nil? || new_version.empty?
          return true if old_version.nil? || old_version.empty?

          new_is_constraint = new_version.match?(/[<>=~^]/)
          old_is_constraint = old_version.match?(/[<>=~^]/)

          # Prefer actual versions over constraints
          return true if !new_is_constraint && old_is_constraint

          # If both are versions or both are constraints, prefer neither
          false
        end
        end
      end
    end
  end
end
