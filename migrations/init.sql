-- Run this in Supabase SQL editor. Creates tables and adds fields for reaction behavior & notifications

create table if not exists bots (
  id serial primary key,
  token text not null,
  owner text not null,
  title text,
  enabled boolean default true,
  force_join_channel text,
  notify_new_user boolean default false,
  reaction_enabled boolean default true,
  reaction_emoji text default '❤️',
  created_at timestamptz default now()
);

create table if not exists bot_users (
  id serial primary key,
  bot_id integer not null references bots (id) on delete cascade,
  telegram_id text not null,
  username text,
  first_name text,
  last_name text,
  started_at timestamptz default now(),
  unique(bot_id, telegram_id)
);

create table if not exists broadcasts (
  id serial primary key,
  bot_id integer not null references bots (id) on delete cascade,
  message text,
  created_at timestamptz default now()
);

create table if not exists notifications (
  id serial primary key,
  bot_id integer not null references bots (id) on delete cascade,
  telegram_id text,
  username text,
  created_at timestamptz default now(),
  seen boolean default false
);

create index if not exists idx_bot_users_botid on bot_users (bot_id);
create index if not exists idx_broadcasts_botid on broadcasts (bot_id);
create index if not exists idx_notifications_botid on notifications (bot_id);
