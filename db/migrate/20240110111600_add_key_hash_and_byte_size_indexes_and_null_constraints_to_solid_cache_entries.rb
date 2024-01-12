class AddKeyHashAndByteSizeIndexesAndNullConstraintsToSolidCacheEntries < ActiveRecord::Migration[7.1]
  def change
    change_table :solid_cache_entries do |t|
      t.change_null :key_hash, false
      t.change_null :byte_size, false
      t.index  :key_hash, unique: true
      t.index  [:key_hash, :byte_size]
      t.index  :byte_size
    end
  end
end