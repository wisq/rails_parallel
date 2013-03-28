require 'rails_parallel/forks'

module RailsParallel
  class Schema
    include Forks

    def initialize(file)
      @file = file
    end

    def load_main_db
      if load_db(1)
        failed = 0
        ObjectSpace.each_object(Class) do |klass|
          next unless klass < ActiveRecord::Base
          next if klass.abstract_class

          klass.reset_column_information
          begin
            klass.columns
          rescue StandardError => e
            failed += 1
            raise e if failed > 3
          end
        end
      end
    end

    def load_db(number)
      update_db_config(number)
      return false if schema_loaded?

      #schema_load(database, schema)
      schema_load(@dbconfig['database'], @file)

      #could add another key to the db config, pointing to the schema sql..

      # do the same for all the shards
      #@shard_entries.each do |shard_name|
        #schema_load(shard_name, shard_schema)
      #end
      
      true
    end

    private

    def reconnect(override = {})
      ActiveRecord::Base.clear_active_connections!
      ActiveRecord::Base.establish_connection(@dbconfig.merge(override))
      ActiveRecord::Base.connection
    end

    def update_db_config(number)
      config = ActiveRecord::Base.configurations[Rails.env]

      # once per worker on init

      config['database'] += "_#{number}" unless number == 1
      
      # also add entries for all the shards
      @shard_entries = config.keys.grep(/shard/)
      
      shard_entries.each do |shard_name|
        config[shard_name]['database'] += "_#{number}" unless number == 1
      end
      # shopify_dev_6
      # shopify_dev_shard_a_6
      # shopify_dev_shard_b_6

      @dbconfig = config.with_indifferent_access
    end

    def schema_load(dbname, schema)
      mysql_args = ['-u', 'root']

      connection = reconnect(:database => nil)
      connection.drop_database(dbname) rescue nil
      connection.create_database(dbname)

      File.open(schema) do |fh|
        pid = fork do
          STDIN.reopen(fh)
          exec(*['mysql', mysql_args, dbname].flatten)
        end
        wait_for(pid)
      end

      reconnect
      sm_table = ActiveRecord::Migrator.schema_migrations_table_name
      ActiveRecord::Base.connection.execute("INSERT INTO #{sm_table} (version) VALUES ('#{schema}')")
    end

    def schema_loaded?
      reconnect

      sm_table = ActiveRecord::Migrator.schema_migrations_table_name
      migrated = ActiveRecord::Base.connection.select_values("SELECT version FROM #{sm_table}")
      migrated.include?(@file)
    rescue
      return false
    end
  end
end
