-- Push notification subscriptions. Additive only: does not modify attendance,
-- authentication, student, staff, or ID-card data.
create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('web', 'android')),
  endpoint text,
  subscription jsonb,
  device_token text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint push_subscriptions_web_fields check (
    (platform = 'web' and endpoint is not null and subscription is not null and device_token is null)
    or
    (platform = 'android' and device_token is not null and endpoint is null and subscription is null)
  )
);
create unique index if not exists push_subscriptions_user_endpoint_uidx
  on public.push_subscriptions(user_id, endpoint);
create unique index if not exists push_subscriptions_user_token_uidx
  on public.push_subscriptions(user_id, device_token);
create index if not exists push_subscriptions_user_platform_idx
  on public.push_subscriptions(user_id, platform);
alter table public.push_subscriptions enable row level security;
revoke all on table public.push_subscriptions from anon, public;
grant select, insert, update, delete on table public.push_subscriptions to authenticated;
drop policy if exists "Users manage their own push subscriptions" on public.push_subscriptions;
create policy "Users manage their own push subscriptions"
  on public.push_subscriptions for all to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));
