-- Oye: recordings and files (kept in storage), and hold to talk.

-- Two more kinds of message: a camera message and a screen recording.
alter table public.oye_messages drop constraint oye_messages_kind_check;
alter table public.oye_messages add constraint oye_messages_kind_check
  check (kind in ('text', 'voice', 'file', 'video', 'screen'));

-- Sent files live in a private bucket, at <sender>/<recipient>/<file>. 100 MB each at most.
insert into storage.buckets (id, name, public, file_size_limit)
  values ('oye', 'oye', false, 104857600)
  on conflict (id) do nothing;

-- You can put a file in your own folder, for someone you're linked to.
create policy "oye send files to linked people" on storage.objects for insert to authenticated
  with check (
    bucket_id = 'oye'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and exists (
      select 1 from public.oye_links l
      where l.owner = (select auth.uid()) and l.friend::text = (storage.foldername(name))[2]));

-- A file is read by the person who sent it and the person it was sent to.
create policy "oye read files sent or received" on storage.objects for select to authenticated
  using (
    bucket_id = 'oye'
    and (select auth.uid())::text in ((storage.foldername(name))[1], (storage.foldername(name))[2]));

-- Do not disturb: nobody's voice comes out of your Mac while it's on.
alter table public.oye_people add column dnd boolean not null default false;

create function public.oye_set_dnd(do_not_disturb boolean) returns void
language sql security definer set search_path = '' as $$
  update public.oye_people set dnd = coalesce(do_not_disturb, false) where id = auth.uid();
$$;

-- Hold to talk. Holding someone's face writes one of these; their Oye sees it arrive and joins
-- the voice room the two of you share, to listen.
create table public.oye_talks (
  id uuid primary key default gen_random_uuid(),
  caller uuid not null references public.oye_people (id) on delete cascade,
  callee uuid not null references public.oye_people (id) on delete cascade,
  created_at timestamptz not null default now(),
  check (caller <> callee)
);
create index oye_talks_callee_idx on public.oye_talks (callee, created_at desc);

create function public.oye_stamp_talk() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  new.created_at := now();
  return new;
end $$;
create trigger oye_talks_stamp before insert on public.oye_talks
  for each row execute function public.oye_stamp_talk();

alter table public.oye_talks enable row level security;

create policy "oye read own talks" on public.oye_talks for select to authenticated
  using (caller = (select auth.uid()) or callee = (select auth.uid()));
create policy "oye talk to linked people" on public.oye_talks for insert to authenticated
  with check (caller = (select auth.uid()) and exists (
    select 1 from public.oye_links l where l.owner = (select auth.uid()) and l.friend = oye_talks.callee));

revoke all on function public.oye_set_dnd(boolean), public.oye_stamp_talk() from public, anon;
grant execute on function public.oye_set_dnd(boolean) to authenticated;

alter publication supabase_realtime add table public.oye_talks;
