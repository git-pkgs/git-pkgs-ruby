# frozen_string_literal: true

module Git
  module Pkgs
    module Commands
      class Schema
        include Output

        FORMATS = %w[text sql json markdown].freeze

        def initialize(args)
          @args = args
          @options = parse_options
        end

        def run
          repo = Repository.new
          require_database(repo)

          Database.connect(repo.git_dir)
          tables = fetch_schema

          case @options[:format]
          when "sql"
            output_sql(tables)
          when "json"
            output_json(tables)
          when "markdown"
            output_markdown(tables)
          else
            output_text(tables)
          end
        end

        def fetch_schema
          db = Database.db
          tables = {}

          db.tables.sort.each do |table_name|
            columns = db.schema(table_name).map do |name, col_info|
              {
                name: name.to_s,
                type: col_info[:type],
                sql_type: col_info[:db_type],
                null: col_info[:allow_null],
                default: col_info[:default]
              }
            end

            indexes = db.indexes(table_name).map do |name, idx_info|
              {
                name: name.to_s,
                columns: idx_info[:columns].map(&:to_s),
                unique: idx_info[:unique]
              }
            end

            tables[table_name.to_s] = { columns: columns, indexes: indexes }
          end

          tables
        end

        def output_text(tables)
          tables.each do |table_name, info|
            puts "#{table_name}"
            puts "-" * table_name.length

            info[:columns].each do |col|
              nullable = col[:null] ? "NULL" : "NOT NULL"
              default = col[:default] ? " DEFAULT #{col[:default]}" : ""
              puts "  #{col[:name].ljust(25)} #{col[:sql_type].to_s.ljust(15)} #{nullable}#{default}"
            end

            if info[:indexes].any?
              puts
              puts "  Indexes:"
              info[:indexes].each do |idx|
                unique = idx[:unique] ? "UNIQUE " : ""
                puts "    #{unique}#{idx[:name]} (#{idx[:columns].join(', ')})"
              end
            end

            puts
          end
        end

        def output_sql(tables)
          db = Database.db

          tables.each do |table_name, info|
            sql = db.fetch("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", table_name).first
            puts sql[:sql] + ";" if sql
            puts

            info[:indexes].each do |idx|
              idx_sql = db.fetch("SELECT sql FROM sqlite_master WHERE type='index' AND name=?", idx[:name]).first
              puts idx_sql[:sql] + ";" if idx_sql && idx_sql[:sql]
            end

            puts if info[:indexes].any?
          end
        end

        def output_json(tables)
          require "json"
          puts JSON.pretty_generate(tables)
        end

        def output_markdown(tables)
          tables.each do |table_name, info|
            puts "## #{table_name}"
            puts
            puts "| Column | Type | Nullable | Default |"
            puts "|--------|------|----------|---------|"

            info[:columns].each do |col|
              nullable = col[:null] ? "Yes" : "No"
              default = col[:default] || ""
              puts "| #{col[:name]} | #{col[:sql_type]} | #{nullable} | #{default} |"
            end

            if info[:indexes].any?
              puts
              puts "**Indexes:**"
              info[:indexes].each do |idx|
                unique = idx[:unique] ? " (unique)" : ""
                puts "- `#{idx[:name]}`#{unique}: #{idx[:columns].join(', ')}"
              end
            end

            puts
          end
        end

        def parse_options
          options = { format: "text" }

          parser = OptionParser.new do |opts|
            opts.banner = "Usage: git pkgs schema [options]"

            opts.on("--format=FORMAT", FORMATS, "Output format: #{FORMATS.join(', ')} (default: text)") do |v|
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
      end
    end
  end
end
