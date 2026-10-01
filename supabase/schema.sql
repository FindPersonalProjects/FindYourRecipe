-- FindYourRecipe database schema for Supabase.
-- Paste this whole file into Supabase -> SQL Editor -> New query, and click Run.
-- Safe to re-run.

-- ------------------------------------------------------------------ tables

create table if not exists public.profiles (
  user_id      uuid primary key references auth.users on delete cascade,
  display_name text not null default 'Home Cook',
  created_at   timestamptz not null default now()
);

-- Every recipe a user has drawn from the pot. Inserted only through draw_recipe().
create table if not exists public.draws (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references auth.users on delete cascade,
  recipe_id  text not null,
  draw_day   date not null,
  created_at timestamptz not null default now()
);
create index if not exists draws_user_day on public.draws (user_id, draw_day);

create table if not exists public.saved_recipes (
  user_id    uuid not null references auth.users on delete cascade default auth.uid(),
  recipe_id  text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, recipe_id)
);

-- Ratings are written only through rate_recipe(), and only for recipes the user drew.
create table if not exists public.ratings (
  user_id    uuid not null references auth.users on delete cascade,
  recipe_id  text not null,
  stars      int  not null check (stars between 1 and 5),
  note       text check (char_length(note) <= 500),
  created_at timestamptz not null default now(),
  primary key (user_id, recipe_id)
);
create index if not exists ratings_recipe on public.ratings (recipe_id);

-- ------------------------------------------------------------------ row level security

alter table public.profiles      enable row level security;
alter table public.draws         enable row level security;
alter table public.saved_recipes enable row level security;
alter table public.ratings       enable row level security;

drop policy if exists "own profile read"   on public.profiles;
drop policy if exists "own profile write"  on public.profiles;
drop policy if exists "own profile update" on public.profiles;
create policy "own profile read"   on public.profiles for select using (user_id = auth.uid());
create policy "own profile write"  on public.profiles for insert with check (user_id = auth.uid());
create policy "own profile update" on public.profiles for update using (user_id = auth.uid());

drop policy if exists "own draws read" on public.draws;
create policy "own draws read" on public.draws for select using (user_id = auth.uid());

drop policy if exists "own saves" on public.saved_recipes;
create policy "own saves" on public.saved_recipes for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Users can read only their own ratings; everyone else's stay hidden until reveal.
drop policy if exists "own ratings read" on public.ratings;
create policy "own ratings read" on public.ratings for select using (user_id = auth.uid());

-- ------------------------------------------------------------------ helpers

create or replace function public.fyr_today(tz text)
returns date language plpgsql stable as $$
begin
  return (now() at time zone coalesce(nullif(tz, ''), 'UTC'))::date;
exception when others then
  return (now() at time zone 'UTC')::date;
end $$;

-- ------------------------------------------------------------------ API

-- How many draws the caller has used today.
create or replace function public.draw_status(tz text default 'UTC')
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from draws
  where user_id = auth.uid() and draw_day = fyr_today(tz);
$$;

-- Draws one recipe at random (server side) from the filtered candidates.
-- Enforces the 3-per-day limit.
create or replace function public.draw_recipe(candidates text[], tz text default 'UTC')
returns table (recipe_id text, used_today int)
language plpgsql volatile security definer set search_path = public as $$
declare
  v_uid  uuid := auth.uid();
  v_day  date := fyr_today(tz);
  v_used int;
  v_pick text;
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN'; end if;
  if candidates is null or coalesce(array_length(candidates, 1), 0) = 0 then
    raise exception 'NO_CANDIDATES';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_uid::text));
  select count(*) into v_used from draws d where d.user_id = v_uid and d.draw_day = v_day;
  if v_used >= 3 then raise exception 'DAILY_LIMIT'; end if;

  v_pick := candidates[1 + floor(random() * array_length(candidates, 1))::int];
  insert into draws (user_id, recipe_id, draw_day) values (v_uid, v_pick, v_day);
  return query select v_pick, v_used + 1;
end $$;

-- Saves the caller's rating and reveals the community rating for that recipe.
create or replace function public.rate_recipe(p_recipe_id text, p_stars int, p_note text default null)
returns table (avg_stars numeric, rating_count int)
language plpgsql volatile security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'NOT_SIGNED_IN'; end if;
  if p_stars is null or p_stars not between 1 and 5 then raise exception 'BAD_STARS'; end if;
  if not exists (select 1 from draws d where d.user_id = v_uid and d.recipe_id = p_recipe_id) then
    raise exception 'NOT_DRAWN';
  end if;

  insert into ratings (user_id, recipe_id, stars, note)
  values (v_uid, p_recipe_id, p_stars, nullif(trim(p_note), ''))
  on conflict (user_id, recipe_id)
  do update set stars = excluded.stars, note = excluded.note, created_at = now();

  return query
    select round(avg(r.stars)::numeric, 2), count(*)::int
    from ratings r where r.recipe_id = p_recipe_id;
end $$;

-- Community ratings, but only for recipes the caller has already rated.
create or replace function public.revealed_ratings(p_recipe_ids text[])
returns table (recipe_id text, avg_stars numeric, rating_count int)
language sql stable security definer set search_path = public as $$
  select r.recipe_id, round(avg(r.stars)::numeric, 2), count(*)::int
  from ratings r
  where r.recipe_id = any(p_recipe_ids)
    and exists (select 1 from ratings mine
                where mine.user_id = auth.uid() and mine.recipe_id = r.recipe_id)
  group by r.recipe_id;
$$;

revoke all on function public.draw_recipe(text[], text)         from public, anon;
revoke all on function public.rate_recipe(text, int, text)       from public, anon;
revoke all on function public.revealed_ratings(text[])           from public, anon;
revoke all on function public.draw_status(text)                  from public, anon;
grant execute on function public.draw_recipe(text[], text)       to authenticated;
grant execute on function public.rate_recipe(text, int, text)    to authenticated;
grant execute on function public.revealed_ratings(text[])        to authenticated;
grant execute on function public.draw_status(text)               to authenticated;
