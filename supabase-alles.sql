-- Bagger Tycoon: ALLE Admin-/Zusatz-Funktionen in einem Durchgang. Mehrfach ausfuehrbar, nichts geht kaputt.
-- Supabase: SQL Editor > New query > alles einfuegen > Run

-- ===== supabase-admin.sql =====
create table if not exists public.admins(user_id uuid primary key references auth.users(id) on delete cascade);
alter table public.admins enable row level security;

create or replace function public.is_admin() returns boolean
language sql security definer stable set search_path=public as
$$ select exists(select 1 from public.admins where user_id=auth.uid()) $$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

create table if not exists public.flags(
  user_id uuid primary key references auth.users(id) on delete cascade,
  banned boolean not null default false,
  cmd_id bigint not null default 0,
  cmd_money numeric,
  updated_at timestamptz not null default now());
alter table public.flags enable row level security;
drop policy if exists flags_select on public.flags;
drop policy if exists flags_ins on public.flags;
drop policy if exists flags_upd on public.flags;
drop policy if exists flags_del on public.flags;
create policy flags_select on public.flags for select to authenticated using (user_id=(select auth.uid()) or public.is_admin());
create policy flags_ins on public.flags for insert to authenticated with check (public.is_admin());
create policy flags_upd on public.flags for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy flags_del on public.flags for delete to authenticated using (public.is_admin());

-- Selbstsperre: darf jeder Spieler fuer sich selbst setzen, aufheben nur der Admin
create or replace function public.self_ban() returns void language sql security definer set search_path=public as
$$ insert into public.flags(user_id,banned) values (auth.uid(),true)
   on conflict (user_id) do update set banned=true, updated_at=now() $$;
revoke all on function public.self_ban() from public, anon;
grant execute on function public.self_ban() to authenticated;

-- Admin-Konto: Friedi
insert into public.admins(user_id) values ('3e3fc2ad-d522-428e-a127-9c8726688269') on conflict do nothing;

-- ===== supabase-rollen.sql =====
-- Rollen sind nur ein Abzeichen im Profil und geben KEINE zusaetzlichen Rechte.
create table if not exists public.roles(
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('founder','supporter','helper')),
  updated_at timestamptz not null default now());
alter table public.roles enable row level security;
drop policy if exists roles_select on public.roles;
drop policy if exists roles_ins on public.roles;
drop policy if exists roles_upd on public.roles;
drop policy if exists roles_del on public.roles;
create policy roles_select on public.roles for select to authenticated using (true);
create policy roles_ins on public.roles for insert to authenticated with check (public.is_admin());
create policy roles_upd on public.roles for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy roles_del on public.roles for delete to authenticated using (public.is_admin());

-- ===== supabase-settings.sql =====
create table if not exists public.settings(
  key text primary key,
  value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now());
alter table public.settings enable row level security;
drop policy if exists settings_select on public.settings;
drop policy if exists settings_insert on public.settings;
drop policy if exists settings_update on public.settings;
create policy settings_select on public.settings for select to anon, authenticated using (true);
create policy settings_insert on public.settings for insert to authenticated with check (public.is_admin());
create policy settings_update on public.settings for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ===== supabase-online.sql =====
create table if not exists public.presence(
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_seen timestamptz not null default now(),
  last_login timestamptz);
alter table public.presence enable row level security;
drop policy if exists presence_select on public.presence;
create policy presence_select on public.presence for select to authenticated using (true);

create or replace function public.heartbeat(is_login boolean default false) returns void
language sql security definer set search_path=public as
$$ insert into public.presence(user_id,last_seen,last_login) values (auth.uid(), now(), case when is_login then now() else null end)
   on conflict (user_id) do update set last_seen=now(),
     last_login=case when is_login then now() else public.presence.last_login end $$;
revoke all on function public.heartbeat(boolean) from public, anon;
grant execute on function public.heartbeat(boolean) to authenticated;

-- ===== supabase-loeschen.sql =====
create or replace function public.admin_delete_user(uid uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'nicht erlaubt'; end if;
  if uid = auth.uid() then raise exception 'eigenen Account nicht loeschen'; end if;
  if exists(select 1 from public.admins where user_id = uid) then raise exception 'Admins koennen nicht geloescht werden'; end if;
  delete from auth.users where id = uid;
end $$;
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;

-- ===== supabase-woche.sql =====
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

-- ===== supabase-reset.sql =====
-- Setzt die Cloud-Staende und die Wochenwertung zurueck, damit die Ranglisten sofort bei 0 starten.
-- Voraussetzung: supabase-admin.sql (is_admin) und supabase-woche.sql wurden ausgefuehrt.
create or replace function public.admin_reset_all() returns void
language plpgsql security definer set search_path=public as
$$
begin
  if not public.is_admin() then raise exception 'nur Admin'; end if;
  update public.saves set life=0, rank=0, updated_at=now(),
    data=jsonb_build_object('m',0,'lic',0,'llic',0,'life',0,'tier',0,'top',0,'lm',0,
      'st',jsonb_build_object('jobs',0,'sold',0,'spins',0))
    where true;
  delete from public.weekly where true;
end
$$;
revoke all on function public.admin_reset_all() from public, anon;
grant execute on function public.admin_reset_all() to authenticated;

-- Einzelnen Spieler zuruecksetzen (Admin-Fenster, "Ganzen Spielstand loeschen")
create or replace function public.admin_reset_player(uid uuid) returns void
language plpgsql security definer set search_path=public as
$$
begin
  if not public.is_admin() then raise exception 'nur Admin'; end if;
  update public.saves set life=0, rank=0, updated_at=now(),
    data=jsonb_build_object('m',0,'lic',0,'llic',0,'life',0,'tier',0,'top',0,'lm',0,
      'st',jsonb_build_object('jobs',0,'sold',0,'spins',0))
    where user_id=uid;
  delete from public.weekly where user_id=uid;
end
$$;
revoke all on function public.admin_reset_player(uuid) from public, anon;
grant execute on function public.admin_reset_player(uuid) to authenticated;

-- ===== supabase-spieler.sql =====
alter table public.flags add column if not exists cmd_patch jsonb;
