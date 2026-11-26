-- Oye: people, who is linked to whom, invites, and the messages between two linked people.
-- Lives in the same Supabase project as Talkie. Every table and function here starts with oye_,
-- and nothing of Talkie's is touched. Everyone signs in anonymously from the app.

create table public.oye_people (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 32),
  -- Where their face photo lives in storage, once they pick one.
  photo text,
  -- Set every 30 seconds while Oye is open, cleared on quit.
  last_seen timestamptz,
  created_at timestamptz not null default now()
);

-- A link is kept as two rows, one each way, so "my people" is a plain lookup by owner.
create table public.oye_links (
  owner uuid not null references public.oye_people (id) on delete cascade,
  friend uuid not null references public.oye_people (id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (owner, friend),
  check (owner <> friend)
);
create index oye_links_friend_idx on public.oye_links (friend);

-- An invite code. Anyone who opens it within a week becomes linked to its owner.
create table public.oye_invites (
  code text primary key check (code ~ '^[A-Z2-9]{8}$'),
  owner uuid not null references public.oye_people (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index oye_invites_owner_idx on public.oye_invites (owner);

create table public.oye_messages (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references public.oye_people (id) on delete cascade,
  recipient uuid not null references public.oye_people (id) on delete cascade,
  kind text not null default 'text' check (kind in ('text', 'voice', 'file')),
  body text not null default '' check (char_length(body) <= 4000),
  -- For voice notes and files: where it is in storage, what it was called, how big, how long.
  path text,
  file_name text check (file_name is null or char_length(file_name) <= 255),
  bytes bigint check (bytes is null or bytes >= 0),
  seconds real check (seconds is null or seconds >= 0),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  check (sender <> recipient)
);
create index oye_messages_recipient_idx on public.oye_messages (recipient, created_at desc);
create index oye_messages_sender_idx on public.oye_messages (sender, created_at desc);

-- The time on a message is the server's, and nobody can send one already read.
create function public.oye_stamp_message() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  new.read_at := null;
  return new;
end $$;
create trigger oye_messages_stamp before insert on public.oye_messages
  for each row execute function public.oye_stamp_message();

alter table public.oye_people enable row level security;
alter table public.oye_links enable row level security;
alter table public.oye_invites enable row level security;
alter table public.oye_messages enable row level security;

-- You can read yourself and the people you're linked to.
create policy "oye read self and linked people" on public.oye_people for select to authenticated
  using (id = (select auth.uid()) or exists (
    select 1 from public.oye_links l where l.owner = (select auth.uid()) and l.friend = oye_people.id));

-- Your links are yours to read. They're made and removed through the functions below.
create policy "oye read own links" on public.oye_links for select to authenticated
  using (owner = (select auth.uid()));

-- Invites have no policies: only the functions below touch them.

-- A message is seen by the two people in it. You can only write to someone you're linked to.
create policy "oye read own messages" on public.oye_messages for select to authenticated
  using (sender = (select auth.uid()) or recipient = (select auth.uid()));
create policy "oye write to linked people" on public.oye_messages for insert to authenticated
  with check (sender = (select auth.uid()) and exists (
    select 1 from public.oye_links l where l.owner = (select auth.uid()) and l.friend = oye_messages.recipient));

-- First launch makes you; later launches can change your name.
create function public.oye_ensure_person(display_name text) returns public.oye_people
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  p public.oye_people;
  clean text := nullif(left(btrim(coalesce(display_name, '')), 32), '');
begin
  if me is null then raise exception 'not signed in'; end if;
  insert into public.oye_people (id, name, last_seen) values (me, coalesce(clean, 'Someone'), now())
  on conflict (id) do update set name = coalesce(clean, public.oye_people.name), last_seen = now()
  returning * into p;
  return p;
end $$;

create function public.oye_check_in() returns void
language sql security definer set search_path = '' as $$
  update public.oye_people set last_seen = now() where id = auth.uid();
$$;

create function public.oye_sign_off() returns void
language sql security definer set search_path = '' as $$
  update public.oye_people set last_seen = null where id = auth.uid();
$$;

-- A fresh invite code. Old ones are cleared out, and you can hold twenty at a time.
create function public.oye_new_invite() returns text
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  c text;
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if me is null or not exists (select 1 from public.oye_people where id = me) then
    raise exception 'not signed in';
  end if;
  delete from public.oye_invites where owner = me and expires_at < now();
  if (select count(*) from public.oye_invites where owner = me) >= 20 then
    raise exception 'too many invites';
  end if;
  loop
    c := '';
    for i in 1..8 loop
      c := c || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    begin
      insert into public.oye_invites (code, owner) values (c, me);
      return c;
    exception when unique_violation then
      -- Taken: roll another.
    end;
  end loop;
end $$;

-- Opening an invite links you and its owner, both ways. Returns who you're now linked to.
create function public.oye_accept_invite(invite_code text) returns table (id uuid, name text)
language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  host uuid;
begin
  if me is null or not exists (select 1 from public.oye_people p where p.id = me) then
    raise exception 'not signed in';
  end if;
  select i.owner into host from public.oye_invites i
    where i.code = upper(btrim(invite_code)) and i.expires_at > now();
  if host is null then raise exception 'wrong or expired invite'; end if;
  if host = me then raise exception 'that is your own invite'; end if;
  if (select count(*) from public.oye_links l where l.owner = me) >= 50
     or (select count(*) from public.oye_links l where l.owner = host) >= 50 then
    raise exception 'too many people';
  end if;
  insert into public.oye_links (owner, friend) values (me, host), (host, me) on conflict do nothing;
  return query select p.id, p.name from public.oye_people p where p.id = host;
end $$;

-- Removing someone removes the link both ways.
create function public.oye_unlink(friend_id uuid) returns void
language sql security definer set search_path = '' as $$
  delete from public.oye_links
  where (owner = auth.uid() and friend = friend_id) or (owner = friend_id and friend = auth.uid());
$$;

-- You opened someone's thread: everything they sent you is read.
create function public.oye_mark_read(friend_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.oye_messages set read_at = now()
  where recipient = auth.uid() and sender = friend_id and read_at is null;
$$;

revoke all on function public.oye_stamp_message(), public.oye_ensure_person(text), public.oye_check_in(),
  public.oye_sign_off(), public.oye_new_invite(), public.oye_accept_invite(text), public.oye_unlink(uuid),
  public.oye_mark_read(uuid) from public, anon;
grant execute on function public.oye_ensure_person(text), public.oye_check_in(), public.oye_sign_off(),
  public.oye_new_invite(), public.oye_accept_invite(text), public.oye_unlink(uuid), public.oye_mark_read(uuid)
  to authenticated;

-- Messages, new links and check-ins arrive live.
alter publication supabase_realtime add table public.oye_messages;
alter publication supabase_realtime add table public.oye_links;
alter publication supabase_realtime add table public.oye_people;
