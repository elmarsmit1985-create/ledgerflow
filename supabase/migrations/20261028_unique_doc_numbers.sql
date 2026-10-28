-- Apply AFTER the app version that handles "records_doc_no_uniq" is live.
-- Stops two documents of the same kind in one business from sharing a number.
-- Deleted rows and documents without a number (drafts) are ignored.
create unique index if not exists records_doc_no_uniq
  on public.records (business_id, (data->>'kind'), (data->>'no'))
  where coll = 'docs' and not deleted and coalesce(data->>'no', '') <> '';
