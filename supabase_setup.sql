-- برای پروژه تازه اجرا شود. اگر SQL قدیمی اجرا شده، بهتر است این نسخه را در پروژه جدید اجرا کنی.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.kalameh_players (
  username text primary key check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name text not null,
  password_hash text not null,
  created_at timestamptz not null default now(),
  games integer not null default 0,
  wins integer not null default 0,
  losses integer not null default 0,
  best_attempts integer,
  total_guesses integer not null default 0
);

create table if not exists public.kalameh_history (
  id bigint generated always as identity primary key,
  username text not null references public.kalameh_players(username) on delete cascade,
  won boolean not null,
  attempts integer not null check (attempts between 1 and 6),
  answer text not null,
  guesses jsonb not null,
  played_at timestamptz not null default now()
);
create index if not exists kalameh_history_played_at_idx on public.kalameh_history(played_at desc);

alter table public.kalameh_players enable row level security;
alter table public.kalameh_history enable row level security;
revoke all on public.kalameh_players, public.kalameh_history from anon, authenticated;

create or replace function public.register_kalameh_player(p_username text,p_password text)
returns table(username text) language plpgsql security definer set search_path=public,extensions as $$
begin
  if lower(trim(p_username)) !~ '^[a-z0-9_]{3,24}$' then raise exception 'Username must be 3-24 characters: a-z, 0-9, underscore'; end if;
  if length(p_password)<8 then raise exception 'Password must be at least 8 characters'; end if;
  insert into public.kalameh_players(username,display_name,password_hash) values(lower(trim(p_username)),lower(trim(p_username)),crypt(p_password,gen_salt('bf')));
  return query select lower(trim(p_username));
exception when unique_violation then raise exception 'این نام کاربری قبلاً انتخاب شده است.'; end;
$$;

create or replace function public.login_kalameh_player(p_username text,p_password text)
returns table(username text) language sql security definer set search_path=public,extensions as $$
  select p.username from public.kalameh_players p
  where p.username=lower(trim(p_username)) and p.password_hash=crypt(p_password,p.password_hash);
$$;

create or replace function public.record_kalameh_result(p_username text,p_password text,p_won boolean,p_attempts integer,p_answer text,p_guesses jsonb)
returns boolean language plpgsql security definer set search_path=public,extensions as $$
begin
  if p_attempts<1 or p_attempts>6 then raise exception 'Invalid attempt count'; end if;
  if jsonb_typeof(p_guesses)<>'array' then raise exception 'Invalid guesses'; end if;
  if not exists(select 1 from public.kalameh_players p where p.username=lower(trim(p_username)) and p.password_hash=crypt(p_password,p.password_hash)) then raise exception 'Invalid account'; end if;
  insert into public.kalameh_history(username,won,attempts,answer,guesses) values(lower(trim(p_username)),p_won,p_attempts,p_answer,p_guesses);
  update public.kalameh_players set games=games+1,wins=wins+(case when p_won then 1 else 0 end),losses=losses+(case when p_won then 0 else 1 end),total_guesses=total_guesses+p_attempts,
    best_attempts=case when p_won and (best_attempts is null or p_attempts<best_attempts) then p_attempts else best_attempts end
  where username=lower(trim(p_username));
  return true;
end;
$$;

create or replace function public.get_kalameh_profile(p_username text,p_password text)
returns table(username text,games integer,wins integer,best_attempts integer)
language sql security definer set search_path=public,extensions as $$
  select p.username,p.games,p.wins,p.best_attempts from public.kalameh_players p
  where p.username=lower(trim(p_username)) and p.password_hash=crypt(p_password,p.password_hash);
$$;

create or replace function public.get_kalameh_leaderboard()
returns table(username text,wins integer,games integer,best_attempts integer)
language sql security definer set search_path=public as $$
  select p.username,p.wins,p.games,p.best_attempts from public.kalameh_players p where p.games>0
  order by p.wins desc,p.best_attempts asc nulls last,p.games desc limit 50;
$$;

revoke all on function public.register_kalameh_player(text,text) from public;
revoke all on function public.login_kalameh_player(text,text) from public;
revoke all on function public.record_kalameh_result(text,text,boolean,integer,text,jsonb) from public;
revoke all on function public.get_kalameh_profile(text,text) from public;
revoke all on function public.get_kalameh_leaderboard() from public;
grant execute on function public.register_kalameh_player(text,text) to anon,authenticated;
grant execute on function public.login_kalameh_player(text,text) to anon,authenticated;
grant execute on function public.record_kalameh_result(text,text,boolean,integer,text,jsonb) to anon,authenticated;
grant execute on function public.get_kalameh_profile(text,text) to anon,authenticated;
grant execute on function public.get_kalameh_leaderboard() to anon,authenticated;

-- تاریخچه امن بازی‌ها: فقط صاحب حساب می‌تواند تاریخچه خودش را بخواند
create or replace function public.get_kalameh_history(p_username text,p_password text) returns table(won boolean,attempts integer,played_at timestamptz) language sql security definer set search_path=public,extensions as $$ select h.won,h.attempts,h.played_at from public.kalameh_history h join public.kalameh_players p on p.username=h.username where p.username=lower(trim(p_username)) and p.password_hash=crypt(p_password,p.password_hash) order by h.played_at desc limit 50; $$;
revoke all on function public.get_kalameh_history(text,text) from public; grant execute on function public.get_kalameh_history(text,text) to anon,authenticated;


-- جدول مسابقات هفتگی مستقل از جدول برترین‌های کلی
-- هفته از دوشنبه 00:00 UTC تا دوشنبه بعدی محاسبه می‌شود.
create or replace function public.get_kalameh_weekly_tournament()
returns table(username text,wins integer,games integer,best_attempts integer)
language sql security definer set search_path=public as $$
  with week_bounds as (
    select date_trunc('week', now() at time zone 'UTC') at time zone 'UTC' as week_start,
           (date_trunc('week', now() at time zone 'UTC') + interval '1 week') at time zone 'UTC' as week_end
  )
  select h.username,
         count(*) filter (where h.won)::integer as wins,
         count(*)::integer as games,
         min(h.attempts) filter (where h.won)::integer as best_attempts
  from public.kalameh_history h cross join week_bounds w
  where h.played_at >= w.week_start and h.played_at < w.week_end
  group by h.username
  order by wins desc, best_attempts asc nulls last, games desc, h.username asc
  limit 100;
$$;
revoke all on function public.get_kalameh_weekly_tournament() from public;
grant execute on function public.get_kalameh_weekly_tournament() to anon,authenticated;
