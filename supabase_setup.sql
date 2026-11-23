-- =====================================================================
-- حصن | supabase_setup.sql
-- شغّل هذا الملف كاملاً مرة واحدة في: Supabase > SQL Editor > New query
-- الملف آمن لإعادة التشغيل (idempotent) ما عدا أنه يعيد ضبط بيانات الفرق العشرة.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1) الجداول
-- ---------------------------------------------------------------------
create table if not exists public.teams (
  id          text primary key,
  side        text not null check (side in ('red','blue')),
  name_en     text not null,
  name_ar     text not null,
  description text,
  sort        int  not null default 0,
  max_members int  not null default 6 check (max_members between 1 and 6)
);

create table if not exists public.participants (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (char_length(btrim(name)) between 2 and 30),
  team_id    text not null references public.teams(id) on update cascade,
  token      uuid not null default gen_random_uuid(),   -- سرّي: يحتفظ به متصفح المتسابق فقط
  joined_at  timestamptz not null default now()
);
-- منع تكرار الاسم (بغض النظر عن حالة الأحرف والمسافات)
create unique index if not exists participants_name_uq
  on public.participants (lower(btrim(name)));
create index if not exists participants_team_idx on public.participants(team_id);

create table if not exists public.scores (
  id             bigint generated always as identity primary key,
  participant_id uuid not null references public.participants(id) on delete cascade,
  track          text not null,
  ref            text not null default '',
  points         int  not null check (points between -1000 and 1000),
  source         text not null default 'client' check (source in ('client','admin')),
  created_at     timestamptz not null default now(),
  unique (participant_id, track, ref)          -- يمنع احتساب نفس التحدي مرتين
);
create index if not exists scores_participant_idx on public.scores(participant_id);

create table if not exists public.progress (
  participant_id uuid not null references public.participants(id) on delete cascade,
  track          text not null,
  visited_at     timestamptz not null default now(),
  primary key (participant_id, track)
);

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

-- ---------------------------------------------------------------------
-- 2) بيانات الفرق العشرة (5 حمراء + 5 زرقاء)
-- ---------------------------------------------------------------------
insert into public.teams (id, side, name_en, name_ar, description, sort) values
  ('red-vipers',      'red',  'Red Vipers',      'الأفاعي الحمراء',      'أفاعي حمراء – السرعة والذكاء', 1),
  ('cyber-phoenix',   'red',  'Cyber Phoenix',   'العنقاء السيبرانية',   'القوة والتجدد', 2),
  ('shadow-hackers',  'red',  'Shadow Hackers',  'قراصنة الظل',          'التخفي والاحتراف', 3),
  ('red-wolves',      'red',  'Red Wolves',      'الذئاب الحمراء',       'العمل الجماعي', 4),
  ('zeroday',         'red',  'ZeroDay',         'يوم الصفر',            'اكتشاف الثغرات', 5),
  ('blue-guardians',  'blue', 'Blue Guardians',  'حراس الأمن السيبراني', 'حراس الأمن السيبراني', 1),
  ('cyber-defenders', 'blue', 'Cyber Defenders', 'المدافعون السيبرانيون','المدافعون السيبرانيون', 2),
  ('blue-sentinels',  'blue', 'Blue Sentinels',  'الحراس والمراقبون',    'الحراس والمراقبون', 3),
  ('cyber-eagles',    'blue', 'Cyber Eagles',    'النسور السيبرانية',    'الرؤية والدقة', 4),
  ('digital-fortress','blue', 'Digital Fortress','الحصن الرقمي',         'التحصين والدفاع المتين', 5)
on conflict (id) do update set
  side = excluded.side, name_en = excluded.name_en, name_ar = excluded.name_ar,
  description = excluded.description, sort = excluded.sort;

-- ---------------------------------------------------------------------
-- 3) دوال مساعدة
-- ---------------------------------------------------------------------
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- حد أقصى لكل فريق: يُفرض داخل قاعدة البيانات نفسها (لا يمكن تجاوزه من المتصفح)
-- security definer لأن المتسابق (anon) لا يملك صلاحية قراءة جدول المشاركين.
create or replace function public.enforce_team_capacity()
returns trigger language plpgsql security definer set search_path = public as $$
declare cap int; cnt int;
begin
  -- قفل صف الفريق لمنع تسجيل متزامن يتجاوز الحد
  select max_members into cap from public.teams where id = new.team_id for update;
  select count(*) into cnt from public.participants
   where team_id = new.team_id and id <> new.id;
  if cnt >= cap then
    raise exception 'TEAM_FULL';
  end if;
  return new;
end $$;

drop trigger if exists trg_team_capacity on public.participants;
create trigger trg_team_capacity
  before insert or update of team_id on public.participants
  for each row execute function public.enforce_team_capacity();

-- ---------------------------------------------------------------------
-- 4) دوال المتسابق (تعمل للزوار بدون حساب)
-- ---------------------------------------------------------------------
create or replace function public.register_participant(p_name text, p_team text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_name text := btrim(coalesce(p_name,'')); v_id uuid; v_token uuid;
begin
  if char_length(v_name) < 2 or char_length(v_name) > 30 then
    raise exception 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.teams where id = p_team) then
    raise exception 'INVALID_TEAM';
  end if;
  begin
    insert into public.participants (name, team_id)
    values (v_name, p_team)
    returning id, token into v_id, v_token;
  exception when unique_violation then
    raise exception 'NAME_TAKEN';
  end;
  return jsonb_build_object('id', v_id, 'token', v_token, 'name', v_name, 'team_id', p_team);
end $$;

create or replace function public.save_progress(p_participant uuid, p_token uuid, p_track text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_track not in ('flag','team','kids','ir','support','hunt','siem') then return; end if;
  if not exists (select 1 from public.participants where id = p_participant and token = p_token) then
    raise exception 'INVALID_SESSION';
  end if;
  insert into public.progress (participant_id, track) values (p_participant, p_track)
  on conflict do nothing;
end $$;

-- تسجيل نقاط من صفحة المسابقة (حتى 100 نقطة لكل عملية، ومرة واحدة لكل ref)
create or replace function public.add_score(p_participant uuid, p_token uuid, p_track text, p_points int, p_ref text default '')
returns int language plpgsql security definer set search_path = public as $$
begin
  if p_track not in ('flag','team','kids','ir','support','hunt','siem') then
    raise exception 'INVALID_DATA';
  end if;
  if p_points is null or p_points < 0 or p_points > 100 then
    raise exception 'INVALID_DATA';
  end if;
  if not exists (select 1 from public.participants where id = p_participant and token = p_token) then
    raise exception 'INVALID_SESSION';
  end if;
  insert into public.scores (participant_id, track, ref, points)
  values (p_participant, p_track, coalesce(left(p_ref, 80), ''), p_points)
  on conflict do nothing;
  return (select coalesce(sum(points),0)::int from public.scores where participant_id = p_participant);
end $$;

-- لوحة النتائج العامة: نقاط كل فريق + المشتركون بوقت التسجيل (بدون الرمز السري)
create or replace function public.leaderboard()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id', tm.id, 'side', tm.side, 'name_en', tm.name_en, 'name_ar', tm.name_ar,
      'description', tm.description, 'max', tm.max_members,
      'points', coalesce((select sum(s.points) from public.scores s
                           join public.participants p on p.id = s.participant_id
                          where p.team_id = tm.id), 0),
      'members', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', p.id, 'name', p.name, 'joined_at', p.joined_at,
                 'points', coalesce((select sum(s.points) from public.scores s where s.participant_id = p.id), 0))
               order by p.joined_at)
          from public.participants p where p.team_id = tm.id), '[]'::jsonb)
    ) order by tm.side desc, tm.sort), '[]'::jsonb)
  from public.teams tm;
$$;

-- ملخص الجهتين لشاشة المنافسة: النقاط + عدد التحديات المختلفة المحلولة + عدد المشتركين
create or replace function public.side_stats()
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select tm.side, p.id as pid, sc.points, sc.track, sc.ref, sc.source
      from public.teams tm
      join public.participants p on p.team_id = tm.id
      left join public.scores sc on sc.participant_id = p.id
  )
  select jsonb_build_object(
    'red',  jsonb_build_object(
      'points',  coalesce((select sum(points) from s where side = 'red'), 0),
      'solved',  (select count(distinct track || ':' || ref) from s where side = 'red' and source = 'client'),
      'members', (select count(distinct pid) from s where side = 'red')),
    'blue', jsonb_build_object(
      'points',  coalesce((select sum(points) from s where side = 'blue'), 0),
      'solved',  (select count(distinct track || ':' || ref) from s where side = 'blue' and source = 'client'),
      'members', (select count(distinct pid) from s where side = 'blue'))
  );
$$;

-- ---------------------------------------------------------------------
-- 5) دوال المشرف (تتحقق من is_admin() داخلياً)
-- ---------------------------------------------------------------------
create or replace function public.admin_add_score(p_participant uuid, p_points int, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_points is null or p_points = 0 or p_points not between -1000 and 1000 then
    raise exception 'INVALID_DATA';
  end if;
  insert into public.scores (participant_id, track, ref, points, source)
  values (p_participant, 'admin', 'admin-' || gen_random_uuid()::text || coalesce(left(p_note,40),''), p_points, 'admin');
end $$;

create or replace function public.admin_remove_participant(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  delete from public.participants where id = p_id;
end $$;

-- p_scope: 'scores' = مسح النقاط والتقدم فقط | 'all' = مسح المشاركين والنقاط والتقدم
create or replace function public.admin_clear(p_scope text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_scope = 'all' then
    delete from public.participants where true;      -- يحذف النقاط والتقدم بالتتابع
  elsif p_scope = 'scores' then
    delete from public.scores where true;
    delete from public.progress where true;
  else
    raise exception 'INVALID_DATA';
  end if;
end $$;

create or replace function public.admin_export()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return jsonb_build_object(
    'app', 'hisn', 'version', 1, 'exported_at', now(),
    'teams',        (select coalesce(jsonb_agg(to_jsonb(t) order by t.side desc, t.sort), '[]') from public.teams t),
    'participants', (select coalesce(jsonb_agg(to_jsonb(p) order by p.joined_at), '[]') from public.participants p),
    'scores',       (select coalesce(jsonb_agg(to_jsonb(s) - 'id' order by s.id), '[]') from public.scores s),
    'progress',     (select coalesce(jsonb_agg(to_jsonb(g)), '[]') from public.progress g)
  );
end $$;

-- p_mode: 'replace' = استبدال كامل | 'merge' = دمج (يتجاهل المكرر)
-- العملية كلها في معاملة واحدة: إذا تجاوز أي فريق 6 مشاركين تُلغى بالكامل.
create or replace function public.admin_import(p_data jsonb, p_mode text default 'replace')
returns jsonb language plpgsql security definer set search_path = public as $$
declare np int; ns int; ng int;
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  if p_data is null or jsonb_typeof(p_data->'participants') is distinct from 'array' then
    raise exception 'INVALID_DATA';
  end if;
  if p_mode = 'replace' then
    delete from public.participants where true;
  end if;

  insert into public.participants (id, name, team_id, token, joined_at)
  select coalesce(x.id, gen_random_uuid()), btrim(x.name), x.team_id,
         coalesce(x.token, gen_random_uuid()), coalesce(x.joined_at, now())
    from jsonb_to_recordset(p_data->'participants')
         as x(id uuid, name text, team_id text, token uuid, joined_at timestamptz)
   where exists (select 1 from public.teams t where t.id = x.team_id)
  on conflict do nothing;
  get diagnostics np = row_count;

  insert into public.scores (participant_id, track, ref, points, source, created_at)
  select x.participant_id, x.track, coalesce(x.ref,''), x.points, coalesce(x.source,'client'), coalesce(x.created_at, now())
    from jsonb_to_recordset(coalesce(p_data->'scores','[]'::jsonb))
         as x(participant_id uuid, track text, ref text, points int, source text, created_at timestamptz)
   where exists (select 1 from public.participants p where p.id = x.participant_id)
  on conflict do nothing;
  get diagnostics ns = row_count;

  insert into public.progress (participant_id, track, visited_at)
  select x.participant_id, x.track, coalesce(x.visited_at, now())
    from jsonb_to_recordset(coalesce(p_data->'progress','[]'::jsonb))
         as x(participant_id uuid, track text, visited_at timestamptz)
   where exists (select 1 from public.participants p where p.id = x.participant_id)
  on conflict do nothing;
  get diagnostics ng = row_count;

  return jsonb_build_object('participants', np, 'scores', ns, 'progress', ng);
end $$;

-- فحص التزامن وسلامة البيانات
create or replace function public.admin_integrity()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;
  return jsonb_build_object(
    'teams',        (select count(*) from public.teams),
    'participants', (select count(*) from public.participants),
    'scores',       (select count(*) from public.scores),
    'over_capacity', coalesce((
        select jsonb_agg(jsonb_build_object('team', q.team_id, 'count', q.c, 'max', q.m))
          from (select pp.team_id, count(*) c, t.max_members m
                  from public.participants pp join public.teams t on t.id = pp.team_id
                 group by pp.team_id, t.max_members
                having count(*) > t.max_members) q), '[]'::jsonb),
    'duplicate_names', (select count(*) from (
        select 1 from public.participants group by lower(btrim(name)) having count(*) > 1) d),
    'orphan_scores', (select count(*) from public.scores s
                       where not exists (select 1 from public.participants p where p.id = s.participant_id)),
    'checked_at', now()
  );
end $$;

-- ---------------------------------------------------------------------
-- 6) الحماية: RLS + الصلاحيات
-- ---------------------------------------------------------------------
alter table public.teams        enable row level security;
alter table public.participants enable row level security;
alter table public.scores       enable row level security;
alter table public.progress     enable row level security;
alter table public.admins       enable row level security;

revoke all on public.teams, public.participants, public.scores, public.progress, public.admins from anon, authenticated;
grant select on public.teams to anon, authenticated;
grant select on public.participants, public.scores, public.progress to authenticated;  -- المشرف فقط عبر السياسات

drop policy if exists teams_read          on public.teams;
drop policy if exists participants_admin  on public.participants;
drop policy if exists scores_admin        on public.scores;
drop policy if exists progress_admin      on public.progress;
create policy teams_read         on public.teams        for select using (true);
create policy participants_admin on public.participants for select to authenticated using (public.is_admin());
create policy scores_admin       on public.scores       for select to authenticated using (public.is_admin());
create policy progress_admin     on public.progress     for select to authenticated using (public.is_admin());
-- جدول admins بلا سياسات: لا أحد يقرؤه مباشرة (is_admin() تقرؤه كـ security definer)

-- الدوال العامة: متاحة للزوار
revoke all on function public.register_participant(text,text)                    from public;
revoke all on function public.save_progress(uuid,uuid,text)                      from public;
revoke all on function public.add_score(uuid,uuid,text,int,text)                 from public;
revoke all on function public.leaderboard()                                      from public;
revoke all on function public.side_stats()                                       from public;
grant execute on function public.side_stats()                                    to anon, authenticated;
revoke all on function public.is_admin()                                         from public;
grant execute on function public.register_participant(text,text)                 to anon, authenticated;
grant execute on function public.save_progress(uuid,uuid,text)                   to anon, authenticated;
grant execute on function public.add_score(uuid,uuid,text,int,text)             to anon, authenticated;
grant execute on function public.leaderboard()                                   to anon, authenticated;
grant execute on function public.is_admin()                                      to anon, authenticated;

-- دوال المشرف: للمسجّلين فقط (والتحقق من is_admin() داخلها)
revoke all on function public.admin_add_score(uuid,int,text)       from public, anon;
revoke all on function public.admin_remove_participant(uuid)       from public, anon;
revoke all on function public.admin_clear(text)                    from public, anon;
revoke all on function public.admin_export()                       from public, anon;
revoke all on function public.admin_import(jsonb,text)             from public, anon;
revoke all on function public.admin_integrity()                    from public, anon;
grant execute on function public.admin_add_score(uuid,int,text)    to authenticated;
grant execute on function public.admin_remove_participant(uuid)    to authenticated;
grant execute on function public.admin_clear(text)                 to authenticated;
grant execute on function public.admin_export()                    to authenticated;
grant execute on function public.admin_import(jsonb,text)          to authenticated;
grant execute on function public.admin_integrity()                 to authenticated;

-- ---------------------------------------------------------------------
-- 7) التحديث اللحظي للوحة المشرف (Realtime)
-- ---------------------------------------------------------------------
do $$ begin alter publication supabase_realtime add table public.participants; exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table public.scores;       exception when others then null; end $$;
do $$ begin alter publication supabase_realtime add table public.progress;     exception when others then null; end $$;

-- ---------------------------------------------------------------------
-- 8) إنشاء حساب المشرف (خطوة يدوية)
--   أ) Authentication > Users > Add user  (بريد + كلمة مرور قوية)
--   ب) ثم شغّل السطر التالي بعد تعديل البريد:
-- ---------------------------------------------------------------------
-- insert into public.admins (user_id)
-- select id from auth.users where email = 'admin@example.com'
-- on conflict do nothing;
