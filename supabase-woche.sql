-- Bagger Tycoon: Wochenwertung. Einmal im Supabase SQL Editor ausfuehren (New query, einfuegen, Run).
create table if not exists public.weekly(
  user_id uuid not null references auth.users(id) on delete cascade,
  week text not null,
  name text,
  gain numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, week));
alter table public.weekly enable row level security;
drop policy if exists weekly_select on public.weekly;
create policy weekly_select on public.weekly for select to authenticated using (true);

create or replace function public.weekly_submit(w text, g numeric, n text) returns void
language plpgsql security definer set search_path=public as
$$
begin
  if auth.uid() is null then return; end if;
  if g is null or g < 0 or g > 1e18 then return; end if;
  insert into public.weekly(user_id, week, name, gain, updated_at)
  values (auth.uid(), left(w, 12), left(coalesce(n, 'Spieler'), 20), g, now())
  on conflict (user_id, week) do update
    set gain = greatest(public.weekly.gain, excluded.gain),
        name = excluded.name,
        updated_at = now();
end
$$;
revoke all on function public.weekly_submit(text, numeric, text) from public, anon;
grant execute on function public.weekly_submit(text, numeric, text) to authenticated;
