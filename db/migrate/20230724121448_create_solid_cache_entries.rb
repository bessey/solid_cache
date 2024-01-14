class CreateSolidCacheEntries < ActiveRecord::Migration[7.0]
  def change
    create_table :solid_cache_entries do |t|
      t.binary   :key,        null: false,   limit: 1024
      t.binary   :value,      null: false,   limit: 512.megabytes
      t.boolean  :hand,       null: false,   default: false
      t.boolean  :visited,    null: false,   default: false
      t.datetime :created_at, null: false

      t.index    :key,        unique: true
      t.index    :hand
      t.index    :visited
    end
  end
end
