# Background Eviction Algorithm

```
    tail (oldest)            head (newest)
    >> loop progression / "previous" >>
ID:  1     2      3     4     5

```

Maybe we can batch simply by setting the LIMIT higher?

```ruby

start = Entry.where(hand: true).lock.first

if start
  # Clear pointer, it will be set on the next entry later
  start.update(hand: false)
else
  # First ever eviction fallback
  start = Entry.order(:id).first
end

evictable = if start.unvisited?
    start
  else
    # Find the next oldest unvisited Entry
    Entry.where(visited: false, id: start.id..).order(:id).first
  end

if evictable != start
  if evictable
    clear_visited_status(start.id..evictable.id)
  else
    # All newer Entry records were visited, so we need to start again from the very oldest
    # Before we do that, mark all passed over visited Entrys as unvisited
    clear_visited_status(start.id..)

    # Now, we will definitely find an unvisited entry, since we just set a bunch to unvisited
    evictable = Entry.where(visited: false).order(:id).first!
    # Again, mark all passed over visited Entrys as unvisited
    clear_visited_status(..evictable.id)
  end

  # Set the pointer to the first Entry we have not processed yet
  Entry.where(id: evictable.id..).limit(1).order(:id).update_all(hand: true)
end

# Evict our found candidate!
evictable.delete


def clear_visited_status(id_range)
  Entry.where(visited: true, id: id_range).update_all(visited: false)
end

```
