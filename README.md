# ledgerflow

Kontivo accounting app. The repository, Supabase project and browser storage keep the older internal name `ledgerflow`.

- **Website:** `index.html`, served by GitHub Pages at https://elmarsmit1985-create.github.io/ledgerflow/
- **Backend:** Supabase project `ledgerflow` (accounts, users, invites and all data)
- **Database setup:** `supabase/schema.sql` (full setup), `supabase/migrations/` (changes applied over time)

## Trials and subscriptions

Every new business gets a one-month free trial (`businesses.trial_ends`). After that it stays open only while `businesses.paid_until` is in the future. When both have passed, the database blocks every record, user profile and invite for that business, and the app shows a locked screen and clears the copy of the books stored on the device. Nothing is deleted; it all opens again once the business is paid up.

Run these in the Supabase SQL editor (customers cannot change these columns themselves):

```sql
-- Payment received: open the business for another month
update businesses set paid_until = greatest(coalesce(paid_until, now()), now()) + interval '1 month' where name = 'Customer name';

-- Never lock a business (ECS Africa is set this way)
update businesses set always_on = true where name = 'ECS Africa';

-- See every business and its status
select name, always_on, trial_ends, paid_until from businesses order by created_at;
```

See `supabase/migrations/20261104_subscription_lock.sql`.
