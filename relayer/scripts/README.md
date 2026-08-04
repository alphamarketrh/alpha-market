# One-off migrations

These filled in data for markets that were already registered before the
relayer started keeping it. They are not part of running the service: a fresh
deployment never needs them, because discovery keeps everything from the start.

  backfill-tags.mjs     categories, from the event each market belongs to
  backfill-events.mjs   event title, image and the short row label

Run from the relayer directory:

    node scripts/backfill-tags.mjs

Each is safe to run twice: they skip markets that already carry the field.
