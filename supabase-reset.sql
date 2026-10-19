-- Bagger Tycoon: "Neue Woche starten" (alle Spieler zuruecksetzen). Einmal im Supabase SQL Editor ausfuehren.
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
