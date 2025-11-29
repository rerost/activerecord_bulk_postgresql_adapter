require "spec_helper"
require "ridgepole"

RSpec.describe "Schema Dump Comparison" do
  let(:schema_files) { Dir[File.join(__dir__, "fixtures/schemas/*.rb")] }
  def database_config
    {
      adapter: "postgresql",
      encoding: "unicode",
      database: "activerecord_bulk_postgresql_adapter_test",
      host: "localhost",
      username: ENV["POSTGRES_USER"] || "postgres",
      password: ENV["POSTGRES_PASSWORD"] || "",
    }
  end

  before(:all) do
    # Ensure database exists
    begin
      ActiveRecord::Base.establish_connection(
        adapter: "postgresql",
        encoding: "unicode",
        database: ENV["PGDATABASE"] || "postgres",
        host: "localhost",
        username: ENV["POSTGRES_USER"] || "postgres",
        password: ENV["POSTGRES_PASSWORD"] || ""
      )
      ActiveRecord::Base.connection.create_database("activerecord_bulk_postgresql_adapter_test")
      
      # Enable extensions for testing
      ActiveRecord::Base.establish_connection(database_config)
      %w[hstore uuid-ossp citext ltree pgcrypto btree_gist].each do |ext|
        ActiveRecord::Base.connection.enable_extension(ext)
      end
    rescue ActiveRecord::DatabaseAlreadyExists
      # Ignore
    rescue => e
      puts "Failed to create database: #{e.message}"
      puts "Please ensure PostgreSQL is running and the credentials are correct."
      exit 1
    end
  end

  after(:all) do
    ActiveRecord::Base.establish_connection(
      adapter: "postgresql",
      encoding: "unicode",
      database: ENV["PGDATABASE"] || "postgres",
      host: "localhost",
      username: ENV["POSTGRES_USER"] || "postgres",
      password: ENV["POSTGRES_PASSWORD"] || ""
    )
    ActiveRecord::Base.connection.drop_database("activerecord_bulk_postgresql_adapter_test")
  end

  it "produces the same schema dump as the standard adapter" do
    schema_files.each do |schema_file|
      puts "Testing with schema: #{File.basename(schema_file)}"

      # 1. Apply schema using standard adapter
      apply_schema(schema_file, adapter: "postgresql")

      # 2. Dump schema using standard adapter
      expected_schema = dump_schema(adapter: "postgresql")

      # 3. Dump schema using bulk adapter
      actual_schema = dump_schema(adapter: "bulk-postgresql")

      # 4. Compare
      expect(actual_schema).to eq(expected_schema), "Schema mismatch for #{File.basename(schema_file)}"
    end
  end

  def apply_schema(schema_file, adapter:)
    config = database_config.merge(adapter: adapter)
    client = Ridgepole::Client.new(config, {})
    client.diff(File.read(schema_file)).migrate
  end

  def dump_schema(adapter:)
    config = database_config.merge(adapter: adapter)
    client = Ridgepole::Client.new(config, {})
    client.dump
  end
end
