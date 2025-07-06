# frozen_string_literal: true

require "activerecord_bulk_postgresql_adapter/version"
require "active_record/connection_adapters/postgresql_adapter"
require "active_record/connection_adapters/postgresql/schema_definitions"
require "active_record/connection_adapters/postgresql/schema_statements"

module ActiverecordBulkPostgresqlAdapter
  class Adaptor < ActiveRecord::ConnectionAdapters::PostgreSQLAdapter
    ADAPTER_NAME = "ActiverecordBulkPostgresql".freeze

    def initialize(...)
      super
      preload(tables)
    end

    CACHEABLE_METHODS = {
      column_definitions: [],
      primary_keys: [],
      indexes: [],
      foreign_keys: [],
      check_constraints: [],
      exclusion_constraints: [],
      unique_constraints: [],
      table_options: [
        :table_comment,
        :inherited_table_names,
        :table_partition_definition
      ],
      table_comment: [],
      inherited_table_names: [],
      table_partition_definition: []
    }.freeze

    CACHEABLE_METHODS.each do |method_name, _|
      define_method(method_name) do |table_name|
        get_cached_or_compute(method_name, table_name) { super(table_name) }
      end
    end

    private

    def preload(table_names)
      @__preload = {}
      CACHEABLE_METHODS.each do |method_name, children|
        children&.each do |child|
          send("preload_#{child}", table_names)
        end
        send("preload_#{method_name}", table_names)
      end
    end

    def preload_column_definitions(table_names)
      table_name_map = (
        query(<<~SQL, "SCHEMA")
          SELECT (a.attrelid::regclass)::text, a.attnum, a.attname, format_type(a.atttypid, a.atttypmod),
                 pg_get_expr(d.adbin, d.adrelid), a.attnotnull, a.atttypid, a.atttypmod,
                 c.collname, col_description(a.attrelid, a.attnum) AS comment,
                 #{supports_identity_columns? ? 'attidentity' : quote('')} AS identity,
                 #{supports_virtual_columns? ? 'attgenerated' : quote('')} as attgenerated
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
            LEFT JOIN pg_type t ON a.atttypid = t.oid
            LEFT JOIN pg_collation c ON a.attcollation = c.oid AND a.attcollation <> t.typcollation
           WHERE a.attnum > 0 AND NOT a.attisdropped
        SQL
      ).group_by(&:first)
       .transform_values do |rows|
        rows
          .sort_by { |r| r[1] } # ORDER BY a.attnum
          .reject { |r| r[1] <= 0 }
          .map { |columns| columns[2..] } # Ignore `(a.attrelid::regclass)::text`, a.attnum
      end

      @__preload[:column_definitions] = table_names.map do |table_name|
        [
          table_name,
          table_name_map[table_name] || [],
        ]
      end.to_h
    end

    def preload_primary_keys(table_names)
      table_name_map = (
        query(<<~SQL, "SCHEMA")
          SELECT (a.attrelid::regclass)::text, i.idx, a.attname
            FROM (
                   SELECT indrelid, indkey, generate_subscripts(indkey, 1) idx
                     FROM pg_index
                    WHERE indisprimary
                 ) i
            JOIN pg_attribute a
              ON a.attrelid = i.indrelid
             AND a.attnum = i.indkey[i.idx]
        SQL
      ).group_by(&:first)
       .transform_values do |rows|
        rows
          .sort_by { |r| r[1] } # ORDER BY i.idx
          .map { |columns| columns[2] } # a.attname only
      end
      @__preload[:primary_keys] = table_names.map do |table_name|
        [
          table_name,
          table_name_map[table_name] || [],
        ]
      end.to_h
    end

    def preload_table_options(table_names)
      @__preload[:table_options] ||= table_names.map do |table_name|
        options = {}

        comment = table_comment(table_name)

        options[:comment] = comment if comment

        inherited_table_names = inherited_table_names(table_name).presence

        options[:options] = "INHERITS (#{inherited_table_names.join(", ")})" if inherited_table_names

        if !options[:options] && supports_native_partitioning?
          partition_definition = table_partition_definition(table_name)

          options[:options] = "PARTITION BY #{partition_definition}" if partition_definition
        end

        [
          table_name,
          options || {},
        ]
      end.to_h
    end

    def preload_indexes(table_names)
      scope_map = (
        query(<<~SQL, "SCHEMA")
          SELECT distinct t.relname, n.nspname, i.relname, d.indisunique, d.indkey, pg_get_indexdef(d.indexrelid),
                          pg_catalog.obj_description(i.oid, 'pg_class') AS comment, d.indisvalid,
                          ARRAY(
                            SELECT pg_get_indexdef(d.indexrelid, k + 1, true)
                            FROM generate_subscripts(d.indkey, 1) AS k
                            ORDER BY k
                          ) AS columns
          FROM pg_class t
          INNER JOIN pg_index d ON t.oid = d.indrelid
          INNER JOIN pg_class i ON d.indexrelid = i.oid
          LEFT JOIN pg_namespace n ON n.oid = t.relnamespace
          WHERE i.relkind IN ('i', 'I')
            AND n.nspname = ANY (current_schemas(false))
            AND d.indisprimary = 'f'
        SQL
      ).group_by { |row| quote(row[0]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row[1] }
          .transform_values do |rows|
          rows.sort_by { |r| r[2] } # ORDER BY i.relname
              .map { |r| r[2..] } # a.attname only
        end
      end

      @__preload[:indexes] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)

        scope_result = find_by_scope(scope_map, scope)

        indexes = scope_result.map do |row|
          index_name = row[0]
          unique = row[1]
          indkey = row[2].split(" ").map(&:to_i)
          inddef = row[3]
          comment = row[4]
          valid = row[5]
          columns = decode_string_array(row[6]).map { |c| ActiveRecord::ConnectionAdapters::ostgreSQL::Utils.unquote_identifier(c.strip.gsub('""', '"')) }

          using, expressions, include, nulls_not_distinct, where = inddef.scan(/ USING (\w+?) \((.+?)\)(?: INCLUDE \((.+?)\))?( NULLS NOT DISTINCT)?(?: WHERE (.+))?\z/m).flatten

          orders = {}
          opclasses = {}
          include_columns = include ? include.split(",").map { |c| ActiveRecord::ConnectionAdapters::PostgreSQL::Utils.unquote_identifier(c.strip.gsub('""', '"')) } : []

          if indkey.include?(0)
            columns = expressions
          else
            # prevent INCLUDE columns from being matched
            columns.reject! { |c| include_columns.include?(c) }

            # add info on sort order (only desc order is explicitly specified, asc is the default)
            # and non-default opclasses
            expressions.scan(/(?<column>\w+)"?\s?(?<opclass>\w+_ops(_\w+)?)?\s?(?<desc>DESC)?\s?(?<nulls>NULLS (?:FIRST|LAST))?/).each do |column, opclass, desc, nulls|
              opclasses[column] = opclass.to_sym if opclass
              if nulls
                orders[column] = [desc, nulls].compact.join(" ")
              else
                orders[column] = :desc if desc
              end
            end
          end

          IndexDefinition.new(
            table_name,
            index_name,
            unique,
            columns,
            orders: orders,
            opclasses: opclasses,
            where: where,
            using: using.to_sym,
            include: include_columns.presence,
            nulls_not_distinct: nulls_not_distinct.present?,
            comment: comment.presence,
            valid: valid
          )
        end

        [
          table_name,
          indexes || [],
        ]
      end.to_h
    end

    def preload_foreign_keys(table_names)
      scope_map = (internal_exec_query(<<~SQL, "SCHEMA", allow_retry: true, materialize_transactions: false)
        SELECT t1.relname AS relname, n.nspname AS nspname, c.conname AS conname, t2.oid::regclass::text AS to_table, c.conname AS name, c.confupdtype AS on_update, c.confdeltype AS on_delete, c.convalidated AS valid, c.condeferrable AS deferrable, c.condeferred AS deferred, c.conrelid, c.confrelid,
          (
            SELECT array_agg(a.attname ORDER BY idx)
            FROM (
              SELECT idx, c.conkey[idx] AS conkey_elem
              FROM generate_subscripts(c.conkey, 1) AS idx
            ) indexed_conkeys
            JOIN pg_attribute a ON a.attrelid = t1.oid
            AND a.attnum = indexed_conkeys.conkey_elem
          ) AS conkey_names,
          (
            SELECT array_agg(a.attname ORDER BY idx)
            FROM (
              SELECT idx, c.confkey[idx] AS confkey_elem
              FROM generate_subscripts(c.confkey, 1) AS idx
            ) indexed_confkeys
            JOIN pg_attribute a ON a.attrelid = t2.oid
            AND a.attnum = indexed_confkeys.confkey_elem
          ) AS confkey_names
        FROM pg_constraint c
        JOIN pg_class t1 ON c.conrelid = t1.oid
        JOIN pg_class t2 ON c.confrelid = t2.oid
        JOIN pg_namespace n ON c.connamespace = n.oid
        WHERE c.contype = 'f'
          AND n.nspname = ANY (current_schemas(false))

        ORDER BY c.conname
      SQL
      ).group_by { |row| quote(row["relname"]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row["nspname"] }
          .transform_values do |rows|
          rows.sort_by { |r| r["conname"] }
        end
      end

      @__preload[:foreign_keys] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)
        fk_info = find_by_scope(scope_map, scope)

        [
          table_name,
          fk_info.map do |row|
            to_table = ActiveRecord::ConnectionAdapters::PostgreSQL::Utils.unquote_identifier(row["to_table"])

            column = decode_string_array(row["conkey_names"])
            primary_key = decode_string_array(row["confkey_names"])

            options = {
              column: column.size == 1 ? column.first : column,
              name: row["name"],
              primary_key: primary_key.size == 1 ? primary_key.first : primary_key
            }

            options[:on_delete] = extract_foreign_key_action(row["on_delete"])
            options[:on_update] = extract_foreign_key_action(row["on_update"])
            options[:deferrable] = extract_constraint_deferrable(row["deferrable"], row["deferred"])

            options[:validate] = row["valid"]

            ForeignKeyDefinition.new(table_name, to_table, options)
          end
        ]
      end.to_h
    end

    def preload_check_constraints(table_names)
      scope_map = (internal_exec_query(<<-SQL, "SCHEMA", allow_retry: true, materialize_transactions: false)
            SELECT t.relname AS relname, n.nspname AS nspname, conname, pg_get_constraintdef(c.oid, true) AS constraintdef, c.convalidated AS valid
            FROM pg_constraint c
            JOIN pg_class t ON c.conrelid = t.oid
            JOIN pg_namespace n ON n.oid = c.connamespace
            WHERE c.contype = 'c'
              AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row["relname"]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row["nspname"] }
          .transform_values do |rows|
          rows.sort_by { |r| r["conname"] }
        end
      end

      @__preload[:check_constraints] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)

        check_info = find_by_scope(scope_map, scope)

        [
          table_name,
          check_info.map do |row|
            options = {
              name: row["conname"],
              validate: row["valid"]
            }
            expression = row["constraintdef"][/CHECK \((.+)\)/m, 1]

            CheckConstraintDefinition.new(table_name, expression, options)
          end
        ]
      end.to_h
    end

    def preload_exclusion_constraints(table_names)
      scope_map = (internal_exec_query(<<-SQL, "SCHEMA")
            SELECT t.relname, n.nspname, conname, pg_get_constraintdef(c.oid) AS constraintdef, c.condeferrable, c.condeferred
            FROM pg_constraint c
            JOIN pg_class t ON c.conrelid = t.oid
            JOIN pg_namespace n ON n.oid = c.connamespace
            WHERE c.contype = 'x'
              AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row["relname"]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row["nspname"] }
      end

      @__preload[:exclusion_constraints] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)

        exclusion_info = find_by_scope(scope_map, scope)
        [
          table_name,
          exclusion_info.map do |row|
            method_and_elements, predicate = row["constraintdef"].split(" WHERE ")
            method_and_elements_parts = method_and_elements.match(/EXCLUDE(?: USING (?<using>\S+))? \((?<expression>.+)\)/)
            predicate.remove!(/ DEFERRABLE(?: INITIALLY (?:IMMEDIATE|DEFERRED))?/) if predicate
            predicate = predicate.from(2).to(-3) if predicate # strip 2 opening and closing parentheses

            deferrable = extract_constraint_deferrable(row["condeferrable"], row["condeferred"])

            options = {
              name: row["conname"],
              using: method_and_elements_parts["using"].to_sym,
              where: predicate,
              deferrable: deferrable
            }

            ActiveRecord::ConnectionAdapters::PostgreSQL::ExclusionConstraintDefinition.new(table_name, method_and_elements_parts["expression"], options)
          end
        ]
      end.to_h
    end

    def preload_unique_constraints(table_names)
      scope_map = (internal_exec_query(<<~SQL, "SCHEMA", allow_retry: true, materialize_transactions: false)
        SELECT t.relname AS relname, n.nspname AS nspname, c.conname, c.conrelid, c.condeferrable, c.condeferred, pg_get_constraintdef(c.oid) AS constraintdef,
        (
          SELECT array_agg(a.attname ORDER BY idx)
          FROM (
            SELECT idx, c.conkey[idx] AS conkey_elem
            FROM generate_subscripts(c.conkey, 1) AS idx
          ) indexed_conkeys
          JOIN pg_attribute a ON a.attrelid = t.oid
          AND a.attnum = indexed_conkeys.conkey_elem
        ) AS conkey_names
        FROM pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE c.contype = 'u'
          AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row["relname"]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row["nspname"] }
          .transform_values do |rows|
          rows.sort_by { |r| r["conname"] }
        end
      end

      @__preload[:unique_constraints] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name)

        unique_info = find_by_scope(scope_map, scope)

        [
          table_name,
          unique_info.map do |row|
            columns = decode_string_array(row["conkey_names"])

            nulls_not_distinct = row["constraintdef"].start_with?("UNIQUE NULLS NOT DISTINCT")
            deferrable = extract_constraint_deferrable(row["condeferrable"], row["condeferred"])

            options = {
              name: row["conname"],
              nulls_not_distinct: nulls_not_distinct,
              deferrable: deferrable
            }

            ActiveRecord::ConnectionAdapters::PostgreSQL::UniqueConstraintDefinition.new(table_name, columns, options)
          end
        ]
      end.to_h
    end

    def preload_table_comment(table_names)
      scope_map = (query(<<~SQL, "SCHEMA")
        SELECT c.relname AS relname, n.nspname AS nspname, pg_catalog.obj_description(c.oid, 'pg_class') AS comment
        FROM pg_catalog.pg_class c
          LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row[0]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row[1] }
          .transform_values do |rows|
          rows.first[2] # Get the comment from the first row
        end
      end

      @__preload[:table_comment] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name, type: "BASE TABLE")
        [
          table_name,
          if scope[:name]
            find_by_scope(scope_map, scope)
          end
        ]
      end.to_h
    end

    def preload_inherited_table_names(table_names)
      scope_map = (query(<<~SQL, "SCHEMA")
        SELECT child.relname AS relname, n.nspname AS nspname, parent.relname AS parent_relname
        FROM pg_catalog.pg_inherits i
          JOIN pg_catalog.pg_class child ON i.inhrelid = child.oid
          JOIN pg_catalog.pg_class parent ON i.inhparent = parent.oid
          LEFT JOIN pg_namespace n ON n.oid = child.relnamespace
        WHERE child.relkind IN ('r', 'p')
          AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row[0]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row[1] }
          .transform_values do |rows|
          rows.map { |r| r[2] } # Get parent table names
        end
      end

      @__preload[:inherited_table_names] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name, type: "BASE TABLE")

        [
          table_name,
          find_by_scope(scope_map, scope) || []
        ]
      end.to_h
    end

    def preload_table_partition_definition(table_names)
      scope_map = (query(<<~SQL, "SCHEMA")
        SELECT c.relname AS relname, n.nspname AS nspname, pg_catalog.pg_get_partkeydef(c.oid) AS partition_def
        FROM pg_catalog.pg_class c
          LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p')
          AND n.nspname = ANY (current_schemas(false))
      SQL
      ).group_by { |row| quote(row[0]) }
       .transform_values do |rows|
        rows
          .group_by { |row| row[1] }
          .transform_values do |rows|
          rows.first[2] # Get the partition definition from the first row
        end
      end

      @__preload[:table_partition_definition] ||= table_names.map do |table_name|
        scope = quoted_scope(table_name, type: "BASE TABLE")

        [
          table_name,
          find_by_scope(scope_map, scope) || [],
        ]
      end.to_h
    end

    def get_cached_or_compute(cache_key, table_name)
      @__preload&.dig(cache_key, table_name) || yield
    end

    def find_by_scope(scope_map, scope)
      result = scope_map[scope[:name]]
      if result.nil?
        nil
      else
        if (result.key?(scope[:schema]))
          result[scope[:schema]]
        else
          if scope[:schema] == "ANY (current_schemas(false))"
            result.values.flatten(1)
          end
        end
      end || []
    end
  end
end

ActiveSupport.on_load(:active_record) do
  ActiveRecord::ConnectionAdapters.register(
    "activerecord_bulk_postgresql",
    "ActiverecordBulkPostgresqlAdapter::Adaptor",
    "activerecord_bulk_postgresql_adapter"
  )
end
