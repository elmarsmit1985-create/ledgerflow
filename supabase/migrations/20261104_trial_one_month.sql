-- Free trial is one month instead of 14 days.
alter table public.businesses alter column trial_ends set default (now() + interval '1 month');
update public.businesses set trial_ends = greatest(trial_ends, created_at + interval '1 month', now() + interval '1 month');
