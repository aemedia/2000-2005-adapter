require 'active_record'
require 'active_record/connection_adapters/abstract_adapter'
require 'active_record/connection_adapters/sqlserver_adapter/core_ext/active_record'
require 'active_record/connection_adapters/sqlserver/database_limits'
require 'active_record/connection_adapters/sqlserver/database_statements'
require 'active_record/connection_adapters/sqlserver/schema_statements'
require 'active_record/connection_adapters/sqlserver/quoting'
require 'active_support/core_ext/kernel/requires'
require 'base64'

module ActiveRecord
  
  class Base
    
    def self.sqlserver_connection(config) #:nodoc:
      config = config.dup.symbolize_keys!
      config.reverse_merge! :mode => :odbc, :host => 'localhost', :username => 'sa', :password => ''
      mode = config[:mode].to_s.downcase.underscore.to_sym
      case mode
      when :odbc
        require_library_or_gem 'odbc' unless defined?(ODBC)
        require 'active_record/connection_adapters/sqlserver_adapter/core_ext/odbc'
        raise ArgumentError, 'Missing :dsn configuration.' unless config.has_key?(:dsn)
      when :adonet
        require 'System.Data'
        raise ArgumentError, 'Missing :database configuration.' unless config.has_key?(:database)
      when :ado
        raise NotImplementedError, 'Please use version 2.3.1 of the adapter for ADO connections. Future versions may support ADO.NET.'
        raise ArgumentError, 'Missing :database configuration.' unless config.has_key?(:database)
      else
        raise ArgumentError, "Unknown connection mode in #{config.inspect}."
      end
      ConnectionAdapters::SQLServerAdapter.new(logger,config.merge(:mode=>mode))
    end
    
    protected
    
    def self.did_retry_sqlserver_connection(connection,count)
      logger.info "CONNECTION RETRY: #{connection.class.name} retry ##{count}."
    end
    
    def self.did_lose_sqlserver_connection(connection)
      logger.info "CONNECTION LOST: #{connection.class.name}"
    end
    
  end
  
  module ConnectionAdapters
    
    class SQLServerColumn < Column
            
      def initialize(name, default, sql_type = nil, null = true, sqlserver_options = {})
        @sqlserver_options = sqlserver_options
        super(name, default, sql_type, null)
      end
      
      class << self
        
        def string_to_utf8_encoding(value)
          value.force_encoding('UTF-8') rescue value
        end
        
        def string_to_binary(value)
          value = value.dup.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
         "0x#{value.unpack("H*")[0]}"
        end
        
        def binary_to_string(value)
          value = value.dup.force_encoding(Encoding::BINARY) if value.respond_to?(:force_encoding)
          value =~ /[^[:xdigit:]]/ ? value : [value].pack('H*')
        end
        
      end
      
      def type_cast(value)
        if value && type == :string && is_utf8?
          self.class.string_to_utf8_encoding(value)
        else
          super
        end
      end
      
      def type_cast_code(var_name)
        if type == :string && is_utf8?
          "#{self.class.name}.string_to_utf8_encoding(#{var_name})"
        else
          super
        end
      end
      
      def is_identity?
        @sqlserver_options[:is_identity]
      end
      
      def is_utf8?
        sql_type =~ /nvarchar|ntext|nchar/i
      end
      
      def table_name
        @sqlserver_options[:table_name]
      end
      
      def table_klass
        @table_klass ||= begin
          table_name.classify.constantize
        rescue StandardError, NameError, LoadError
          nil
        end
        (@table_klass && @table_klass < ActiveRecord::Base) ? @table_klass : nil
      end
      
      def database_year
        @sqlserver_options[:database_year]
      end
      
      
      private
      
      def extract_limit(sql_type)
        case sql_type
        when /^smallint/i
          2
        when /^int/i
          4
        when /^bigint/i
          8
        when /\(max\)/, /decimal/, /numeric/
          nil
        else
          super
        end
      end
      
      def simplified_type(field_type)
        case field_type
          when /real/i              then :float
          when /money/i             then :decimal
          when /image/i             then :binary
          when /bit/i               then :boolean
          when /uniqueidentifier/i  then :string
          when /datetime/i          then simplified_datetime
          when /varchar\(max\)/     then :text
          else super
        end
      end
      
      def simplified_datetime
        if database_year >= 2008
          :datetime
        elsif table_klass && table_klass.coerced_sqlserver_date_columns.include?(name)
          :date
        elsif table_klass && table_klass.coerced_sqlserver_time_columns.include?(name)
          :time
        else
          :datetime
        end
      end
      
    end #class SQLServerColumn
    
    class SQLServerAdapter < AbstractAdapter
      
      include Sqlserver::Quoting
      include Sqlserver::DatabaseStatements
      include Sqlserver::SchemaStatements
      include Sqlserver::DatabaseLimits
      
      ADAPTER_NAME                = 'SQLServer'.freeze
      VERSION                     = '3.0.0.beta1'.freeze
      DATABASE_VERSION_REGEXP     = /Microsoft SQL Server\s+(\d{4})/
      SUPPORTED_VERSIONS          = [2000,2005,2008].freeze
      LOST_CONNECTION_EXCEPTIONS  = {
        :odbc   => ['ODBC::Error'],
        :adonet => ['TypeError','System::Data::SqlClient::SqlException']
      }
      LOST_CONNECTION_MESSAGES    = {
        :odbc   => [/link failure/, /server failed/, /connection was already closed/, /invalid handle/i],
        :adonet => [/current state is closed/, /network-related/]
      }
      
      cattr_accessor :native_text_database_type, :native_binary_database_type, :native_string_database_type,
                     :log_info_schema_queries, :enable_default_unicode_types, :auto_connect
      
      def initialize(logger,config)
        @connection_options = config
        connect
        super(raw_connection, logger)
        initialize_sqlserver_caches
        use_database
        unless SUPPORTED_VERSIONS.include?(database_year)
          raise NotImplementedError, "Currently, only #{SUPPORTED_VERSIONS.to_sentence} are supported."
        end
      end
      
      # ABSTRACT ADAPTER =========================================#
      
      def adapter_name
        ADAPTER_NAME
      end
      
      def supports_migrations?
        true
      end
      
      def supports_primary_key?
        true
      end
      
      def supports_ddl_transactions?
        true
      end
      
      def supports_savepoints?
        true
      end
      
      def database_version
        @database_version ||= info_schema_query { select_value('SELECT @@version') }
      end
      
      def database_year
        DATABASE_VERSION_REGEXP.match(database_version)[1].to_i
      end
      
      def sqlserver?
        true
      end
      
      def sqlserver_2000?
        database_year == 2000
      end
      
      def sqlserver_2005?
        database_year == 2005
      end
      
      def sqlserver_2008?
        database_year == 2008
      end
      
      def version
        self.class::VERSION
      end
      
      def inspect
        "#<#{self.class} version: #{version}, year: #{database_year}, connection_options: #{@connection_options.inspect}>"
      end
      
      def auto_connect
        @@auto_connect.is_a?(FalseClass) ? false : true
      end
      
      def native_string_database_type
        @@native_string_database_type || (enable_default_unicode_types ? 'nvarchar' : 'varchar') 
      end
      
      def native_text_database_type
        @@native_text_database_type || 
        if sqlserver_2005? || sqlserver_2008?
          enable_default_unicode_types ? 'nvarchar(max)' : 'varchar(max)'
        else
          enable_default_unicode_types ? 'ntext' : 'text'
        end
      end
      
      def native_time_database_type
        sqlserver_2008? ? 'time' : 'datetime'
      end
      
      def native_date_database_type
        sqlserver_2008? ? 'date' : 'datetime'
      end
      
      def native_binary_database_type
        @@native_binary_database_type || ((sqlserver_2005? || sqlserver_2008?) ? 'varbinary(max)' : 'image')
      end
      
      # REFERENTIAL INTEGRITY ====================================#
      
      def disable_referential_integrity
        do_execute "EXEC sp_MSforeachtable 'ALTER TABLE ? NOCHECK CONSTRAINT ALL'"
        yield
      ensure
        do_execute "EXEC sp_MSforeachtable 'ALTER TABLE ? CHECK CONSTRAINT ALL'"
      end
      
      # CONNECTION MANAGEMENT ====================================#
      
      def active?
        raw_connection_do("SELECT 1")
        true
      rescue *lost_connection_exceptions
        false
      end

      def reconnect!
        disconnect!
        connect
        active?
      end

      def disconnect!
        case connection_mode
        when :odbc
          raw_connection.disconnect rescue nil
        else :adonet
          raw_connection.close rescue nil
        end
      end
      
      # RAKE UTILITY METHODS =====================================#
      
      def recreate_database
        remove_database_connections_and_rollback do
          do_execute "EXEC sp_MSforeachtable 'DROP TABLE ?'"
        end
      end
      
      def recreate_database!(database=nil)
        current_db = current_database
        database ||= current_db
        this_db = database.to_s == current_db
        do_execute 'USE master' if this_db
        drop_database(database)
        create_database(database)
      ensure
        use_database(current_db) if this_db
      end
      
      # Remove existing connections and rollback any transactions if we received the message
      # 'Cannot drop the database 'test' because it is currently in use'
      def drop_database(database)
        retry_count = 0
        max_retries = 1
        begin
          do_execute "DROP DATABASE #{quote_table_name(database)}"
        rescue ActiveRecord::StatementInvalid => err
          if err.message =~ /because it is currently in use/i
            raise if retry_count >= max_retries
            retry_count += 1
            remove_database_connections_and_rollback(database)
            retry
          else
            raise
          end
        end
      end

      def create_database(database)
        do_execute "CREATE DATABASE #{quote_table_name(database)}"
      end
      
      def current_database
        select_value 'SELECT DB_NAME()'
      end
      
      def charset
        select_value "SELECT SERVERPROPERTY('SqlCharSetName')"
      end
      
      # This should disconnect all other users and rollback any transactions for SQL 2000 and 2005
      # http://sqlserver2000.databases.aspfaq.com/how-do-i-drop-a-sql-server-database.html
      def remove_database_connections_and_rollback(database=nil)
        database ||= current_database
        do_execute "ALTER DATABASE #{quote_table_name(database)} SET SINGLE_USER WITH ROLLBACK IMMEDIATE"
        begin
          yield
        ensure
          do_execute "ALTER DATABASE #{quote_table_name(database)} SET MULTI_USER"
        end if block_given?
      end
      
      
      
      protected
      
      # CONNECTION MANAGEMENT ====================================#
      
      def connect
        config = @connection_options
        @connection = case connection_mode
                      when :odbc
                        ODBC.connect config[:dsn], config[:username], config[:password]
                      when :adonet
                        System::Data::SqlClient::SqlConnection.new.tap do |connection|
                          connection.connection_string = System::Data::SqlClient::SqlConnectionStringBuilder.new.tap do |cs|
                            if config[:integrated_security]
                              cs.integrated_security = true
                            else
                              cs.user_i_d = config[:username]
                              cs.password = config[:password]
                            end
                            cs.add 'Server', config[:host].to_clr_string
                            cs.initial_catalog = config[:database]
                            cs.multiple_active_result_sets = false
                            cs.pooling = false
                          end.to_s
                          connection.open
                        end
                      end
      rescue
        raise unless @auto_connecting
      end
      
      def connection_mode
        @connection_options[:mode]
      end
      
      def lost_connection_exceptions
        exceptions = LOST_CONNECTION_EXCEPTIONS[connection_mode]
        @lost_connection_exceptions ||= exceptions ? exceptions.map(&:constantize) : []
      end
      
      def lost_connection_messages
        LOST_CONNECTION_MESSAGES[connection_mode]
      end
      
      def with_auto_reconnect
        begin
          yield
        rescue *lost_connection_exceptions => e
          if lost_connection_messages.any? { |lcm| e.message =~ lcm }
            retry if auto_reconnected?
          end
          raise
        end
      end
      
      def auto_reconnected?
        return false unless auto_connect
        @auto_connecting = true
        count = 0
        while count <= 5
          sleep 2** count
          ActiveRecord::Base.did_retry_sqlserver_connection(self,count)
          return true if reconnect!
          count += 1
        end
        ActiveRecord::Base.did_lose_sqlserver_connection(self)
        false
      ensure
        @auto_connecting = false
      end
      
      def raw_connection_run(sql)
        with_auto_reconnect do
          case connection_mode
          when :odbc
            block_given? ? raw_connection.run_block(sql) { |handle| yield(handle) } : raw_connection.run(sql)
          else :adonet
            raw_connection.create_command.tap{ |cmd| cmd.command_text = sql }.execute_reader
          end
        end
      end
      
      def raw_connection_do(sql)
        case connection_mode
        when :odbc
          raw_connection.do(sql)
        else :adonet
          raw_connection.create_command.tap{ |cmd| cmd.command_text = sql }.execute_non_query
        end
      end
      
      def finish_statement_handle(handle)
        case connection_mode
        when :odbc
          handle.drop if handle && handle.respond_to?(:drop) && !handle.finished?
        when :adonet
          handle.close if handle && handle.respond_to?(:close) && !handle.is_closed
          handle.dispose if handle && handle.respond_to?(:dispose)
        end
        handle
      end
            
    end #class SQLServerAdapter < AbstractAdapter
    
  end #module ConnectionAdapters
  
end #module ActiveRecord

