# frozen_string_literal: true

module SolidCache
  class Entry < Record
    # This is all quite awkward but it achieves a couple of performance aims
    # 1. We skip the query cache
    # 2. We avoid the overhead of building queries and active record objects
    class << self
      def write(key, value)
        upsert_all_no_query_cache([ { key: key, value: value } ])
      end

      def write_multi(payloads)
        upsert_all_no_query_cache(payloads)
      end

      def read(key)
        result = select_all_no_query_cache(get_sql, lookup_value(key)).first
        result[1] if result&.first == key
      end

      def read_multi(keys)
        key_hashes = keys.map { |key| lookup_value(key) }
        results = select_all_no_query_cache(get_all_sql(key_hashes), key_hashes).to_h
        results.except!(results.keys - keys)
      end

      def delete_by_key(key)
        delete_no_query_cache(lookup_column, lookup_value(key))
      end

      def delete_multi(keys)
        serialized_keys = keys.map { |key| lookup_value(key) }
        delete_no_query_cache(lookup_column, serialized_keys)
      end

      def clear_truncate
        connection.truncate(table_name)
      end

      def clear_delete
        in_batches.delete_all
      end

      def increment(key, amount)
        transaction do
          uncached do
            result = lock.where(lookup_column => lookup_value(key)).pick(:key, :value)
            amount += result[1].to_i if result&.first == key
            write(key, amount)
            amount
          end
        end
      end

      def decrement(key, amount)
        increment(key, -amount)
      end

      def id_range
        uncached do
          pick(Arel.sql("max(id) - min(id) + 1")) || 0
        end
      end

      def expire(count, max_age:, max_entries:)
        if (ids = expiry_candidate_ids(count, max_age: max_age, max_entries: max_entries)).any?
          delete(ids)
        end
      end

      private
        def upsert_all_no_query_cache(payloads)
          insert_all = ActiveRecord::InsertAll.new(self, add_key_hash_and_byte_size(payloads), unique_by: upsert_unique_by, on_duplicate: :update, update_only: [ :value ])
          sql = connection.build_insert_sql(ActiveRecord::InsertAll::Builder.new(insert_all))

          message = +"#{self} "
          message << "Bulk " if payloads.many?
          message << "Upsert"
          # exec_query_method does not clear the query cache, exec_insert_all does
          connection.send exec_query_method, sql, message
        end

        def add_key_hash_and_byte_size(payloads)
          payloads.map do |payload|
            payload.dup.tap do |payload|
              if key_hash?
                payload[:key_hash] = key_hash_for(payload[:key])
                payload[:byte_size] = payload[:value].to_s.bytesize
              end
            end
          end
        end

        def key_hash?
          @key_hash ||= {}
          if @key_hash.key?(connection.object_id)
            @key_hash[connection.object_id]
          else
            @key_hash[connection.object_id] = connection.column_exists?(table_name, :key_hash)
          end
        end

        def key_hash_indexed?
          @key_hash_indexed ||= {}
          if @key_hash_indexed.key?(connection.object_id)
            @key_hash_indexed[connection.object_id]
          else
            @key_hash_indexed[connection.object_id] = connection.index_exists?(table_name, :key_hash)
          end
        end

        def lookup_column
          key_hash_indexed? ? :key_hash : :key
        end

        def lookup_value(key)
          key_hash_indexed? ? key_hash_for(key) : to_binary(key)
        end

        def lookup_placeholder
          key_hash_indexed? ? 1 : "placeholder"
        end

        def exec_query_method
          connection.respond_to?(:internal_exec_query) ? :internal_exec_query : :exec_query
        end

        def upsert_unique_by
          connection.supports_insert_conflict_target? ? lookup_column : nil
        end

        def get_sql
          @get_sql ||= {}
          @get_sql[lookup_column] ||= build_sql(where(lookup_column => lookup_placeholder).select(:key, :value))
        end

        def get_all_sql(key_hashes)
          if connection.prepared_statements?
            @get_all_sql_binds ||= {}
            @get_all_sql_binds[[key_hashes.count, lookup_column]] ||= build_sql(where(lookup_column => key_hashes).select(:key, :value))
          else
            @get_all_sql_no_binds ||= {}
            @get_all_sql_no_binds[lookup_column] ||= build_sql(where(lookup_column => [ lookup_placeholder, lookup_placeholder ]).select(:key, :value)).gsub("?, ?", "?")
          end
        end

        def build_sql(relation)
          collector = Arel::Collectors::Composite.new(
            Arel::Collectors::SQLString.new,
            Arel::Collectors::Bind.new,
          )

          connection.visitor.compile(relation.arel.ast, collector)[0]
        end

        def select_all_no_query_cache(query, values)
          uncached do
            if connection.prepared_statements?
              result = connection.select_all(sanitize_sql(query), "#{name} Load", Array(values), preparable: true)
            else
              result = connection.select_all(sanitize_sql([ query, values ]), "#{name} Load", Array(values), preparable: false)
            end

            result.cast_values(SolidCache::Entry.attribute_types)
          end
        end

        def delete_no_query_cache(attribute, values)
          uncached do
            relation = where(attribute => values)
            sql = connection.to_sql(relation.arel.compile_delete(relation.table[primary_key]))

            # exec_delete does not clear the query cache
            if connection.prepared_statements?
              connection.exec_delete(sql, "#{name} Delete All", Array(values)).nonzero?
            else
              connection.exec_delete(sql, "#{name} Delete All").nonzero?
            end
          end
        end

        def to_binary(key)
          ActiveModel::Type::Binary.new.serialize(key)
        end

        def expiry_candidate_ids(count, max_age:, max_entries:)
          cache_full = max_entries && max_entries < id_range
          return [] unless cache_full || max_age

          # In the case of multiple concurrent expiry operations, it is desirable to
          # reduce the overlap of entries being addressed by each. For that reason,
          # retrieve more ids than are being expired, and use random
          # sampling to reduce that number to the actual intended count.
          retrieve_count = count * 3

          uncached do
            candidates = order(:id).limit(retrieve_count)

            candidate_ids = if cache_full
              candidates.pluck(:id)
            else
              min_created_at = max_age.seconds.ago
              candidates.pluck(:id, :created_at)
                        .filter_map { |id, created_at| id if created_at < min_created_at }
            end

            candidate_ids.sample(count)
          end
        end

        def key_hash_for(key)
          # Need to unpack this as a signed integer - Postgresql and SQLite don't support unsigned integers
          Digest::SHA256.digest(key).unpack("q>").first
        end
    end
  end
end

ActiveSupport.run_load_hooks :solid_cache_entry, SolidCache::Entry
