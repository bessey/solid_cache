# SolidCache with SIEVE eviction

Translating the [SIEVE algorithm](https://yazhuozhang.com/assets/pdf/nsdi24-sieve.pdf) to SQL was a bit confusing to my
brain at least, because the paper's pseudo-code algorithm treats where inserts happen as the head. I.e.:

```
    tail (oldest)            head (newest)
ID:  1     2      3     4     5

```

The algorithm progresses from tail to head, before resetting back to the tail when it runs out of newer entries.

The algorithm needs to store state across runs; a pointer to a record in the cache table. We achieve this by storing
that as an Entry which will never expire or be evicted.

## The SIEVE algorithm in SolidCache

```ruby

POINTER_KEY = "rails:sieve-eviction-pointer"

Entry.transaction do
  pointer = Entry.find_by!(key: POINTER_KEY)
  start = Entry.find_by(id: pointer.value) || Entry.order(:id).first
  count_to_evict = 100

  evictions = eviction_scope(pointer.id).where(id: start.id..).first(count_to_evict)

  if evictions.any?
    clear_visited_status(start.id..evictions.last.id)
  else
    # All newer Entry records were visited, so we need to start again from the very oldest
    # Before we do that, mark all passed over visited Entrys as unvisited
    clear_visited_status(start.id..)

    # Now, we will definitely find unvisited Entrys, since we just set a bunch to unvisited
    evictions = eviction_scope(pointer.id).first(count_to_evict)
    # Again, mark all passed over visited Entrys as unvisited
    clear_visited_status(..evictions.last.id)
  end

  # Set the pointer to the first Entry we have not processed yet
  pointer.update(value: Entry.where(id: evictions.last.id..).order(:id).first.id)

  # Evict our found candidates!
  evictions.delete_all
end

def eviction_scope(pointer_id)
  # Ensure the pointer is never considered for eviction as its a special cache entry we rely on
  Entry.where(visited: false).where.not(id: pointer_id).order(:id)
end

def clear_visited_status(id_range)
  Entry.where(visited: true, id: id_range).update_all(visited: false)
end
```

## When to trigger the expiration algorithm

Since this algorithm will regularly delete items from the middle of the table, we do actually need to count the table
entries to know when an eviction is needed.

We can still use `SolidCache::Cluster::Expiry` to probabilistically run batched evictions less frequently though.

```ruby
count = Entry.count
if count >= max_entries
  expire(count - max_entries)
end
```

## Reducing Overhead

### Maintaining the "visited" state

The SIEVE algorithm can require writing during reads, however for popular Entries the common case is that the Entry is
already marked "visited" and therefore no write is needed.

Updating this state is of no interest to the reader, so this seems like a good fit for an `async { }` call.

In addition, this seems like a good fit for `SKIP LOCKED`. If a cache read is attempting to set `visited` to `true`
but a lock prevents it, it can only mean a couple of things:

1. Another cache reader is marking it as `visited`, meaning we have nothing to do
2. An eviction cycle is passing over this entry, which means it is unlikely to be considered for eviction again for some
   time, reducing the impact of us failing to mark it as `visited`
