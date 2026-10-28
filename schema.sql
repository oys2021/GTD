-- ═══════════════════════════════════════════════════════════════════
-- Getting Things Done — database schema for Supabase
--
-- How to run: Supabase dashboard → SQL Editor → New query →
-- paste this whole file → Run. Safe to run more than once.
--
-- Every table has a user_id that defaults to the signed-in user, and
-- Row Level Security so each account can only see and change its own rows.
-- ═══════════════════════════════════════════════════════════════════

-- tasks: everything that's still open (inbox, next actions, calendar, …)
create table if not exists public.tasks (
  user_id        uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  id             text        not null,
  title          text        not null,
  next_action    text,
  status         text        not null default 'inbox'
                 check (status in ('inbox', 'next', 'calendar', 'waiting', 'someday', 'reference')),
  context        text,
  priority       text        check (priority in ('urgent', 'high', 'normal', 'low')),
  duration_min   integer,
  due            text,
  notes          text,
  subtasks       jsonb       not null default '[]',   -- [{ "text": "…", "done": false }]
  time_box       jsonb,                                -- { "date": "2026-10-28", "start": "14:00", "minutes": 45 }
  time_spent_sec integer     not null default 0,
  extra          jsonb       not null default '{}',   -- who / when / origin / source / remind / scheduleId
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (user_id, id)
);

-- task_history: one row per task ever captured, kept after it's done or deleted
create table if not exists public.task_history (
  user_id      uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  id           text        not null,
  title        text        not null default '',
  added_at     timestamptz not null,
  completed_at timestamptz,
  deleted_at   timestamptz,
  snapshot     jsonb,                                  -- copy of the task when it was finished
  updated_at   timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists task_history_added_idx     on public.task_history (user_id, added_at);
create index if not exists task_history_completed_idx on public.task_history (user_id, completed_at);

-- schedules: repeating routines that add a time-boxed task on chosen weekdays
create table if not exists public.schedules (
  user_id      uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  id           text        not null,
  title        text        not null,
  days         smallint[]  not null default '{}',     -- 0 = Sunday … 6 = Saturday
  start_time   text        not null,                   -- 'HH:MM'
  minutes      integer     not null,
  context      text,
  remind_min   integer,                                -- minutes before; null = no reminder
  active       boolean     not null default true,
  last_created date,
  updated_at   timestamptz not null default now(),
  primary key (user_id, id)
);

-- focus_sessions: Deep Work Zone check-ins
create table if not exists public.focus_sessions (
  user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  id          text        not null,
  task_id     text,
  title       text,
  started_at  timestamptz not null,
  ended_at    timestamptz,
  planned_min integer,
  focused_sec integer     not null default 0,
  rating      text        check (rating in ('deep', 'steady', 'scattered')),
  intention   text,
  completed   boolean     not null default false,
  parked      integer     not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (user_id, id)
);
create index if not exists focus_sessions_started_idx on public.focus_sessions (user_id, started_at);

-- focus_log: seconds focused per day (focus timer + Deep Work Zone)
create table if not exists public.focus_log (
  user_id    uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  day        date        not null,
  seconds    integer     not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, day)
);

-- user_settings: contexts and preferences (sound, Deep Work Zone, notifications)
create table if not exists public.user_settings (
  user_id    uuid        primary key default auth.uid() references auth.users (id) on delete cascade,
  contexts   text[]      not null default '{}',
  prefs      jsonb       not null default '{}',
  updated_at timestamptz not null default now()
);

-- keep updated_at current on every change
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- privacy: each signed-in user can only read and write their own rows
do $$
declare t text;
begin
  foreach t in array array['tasks', 'task_history', 'schedules', 'focus_sessions', 'focus_log', 'user_settings'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "own rows" on public.%I', t);
    execute format('create policy "own rows" on public.%I for all to authenticated
                    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('drop trigger if exists set_updated_at on public.%I', t);
    execute format('create trigger set_updated_at before update on public.%I
                    for each row execute function public.set_updated_at()', t);
  end loop;
end $$;

