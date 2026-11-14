-- Khojlo schema (Supabase / Postgres). Run in SQL editor once the project is writable.
create table public.categories (id serial primary key, slug text unique not null, name text not null, kind text not null check (kind in ('tutor','service','job','consultancy')));
create table public.providers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid unique references auth.users(id) on delete cascade,
  category_id int references public.categories(id),
  name text not null, phone text not null, headline text, bio text,
  subjects text[] default '{}', levels text[] default '{}',
  area text, city text not null default 'Delhi',
  mode text default 'both' check (mode in ('home','online','both')),
  rate_per_hour int check (rate_per_hour between 0 and 100000),
  experience_years int, verified boolean not null default false,
  status text not null default 'pending' check (status in ('pending','active','suspended')),
  plan text not null default 'free' check (plan in ('free','pro')),
  plan_expires_at timestamptz, free_leads_left int not null default 3,
  rating_avg numeric(2,1) default 0, rating_count int default 0,
  created_at timestamptz not null default now());
create index on public.providers (category_id, status);
create index on public.providers using gin (subjects);
create table public.enquiries (id uuid primary key default gen_random_uuid(), category_id int references public.categories(id), name text not null, phone text not null, requirement text not null, area text, city text not null default 'Delhi', budget int, created_at timestamptz not null default now());
create table public.leads (id uuid primary key default gen_random_uuid(), enquiry_id uuid not null references public.enquiries(id) on delete cascade, provider_id uuid not null references public.providers(id) on delete cascade, unlocked boolean not null default false, created_at timestamptz not null default now(), unique (enquiry_id, provider_id));
create table public.reviews (id uuid primary key default gen_random_uuid(), provider_id uuid not null references public.providers(id) on delete cascade, reviewer_name text not null, rating int not null check (rating between 1 and 5), comment text, created_at timestamptz not null default now());
create table public.jobs (id uuid primary key default gen_random_uuid(), category_id int references public.categories(id), title text not null, description text, area text, city text not null default 'Delhi', pay_text text, contact_phone text not null, status text not null default 'open' check (status in ('open','closed')), created_at timestamptz not null default now());

alter table public.categories enable row level security;
alter table public.providers enable row level security;
alter table public.enquiries enable row level security;
alter table public.leads enable row level security;
alter table public.reviews enable row level security;
alter table public.jobs enable row level security;

create policy "categories readable" on public.categories for select using (true);
create policy "reviews readable" on public.reviews for select using (true);
create policy "reviews insert" on public.reviews for insert with check (char_length(reviewer_name) between 1 and 80);
create policy "open jobs readable" on public.jobs for select using (status = 'open');
create policy "jobs insert" on public.jobs for insert with check (status = 'open');
create policy "enquiries insert" on public.enquiries for insert with check (true);
create policy "provider self select" on public.providers for select to authenticated using (user_id = auth.uid());
create policy "provider self insert" on public.providers for insert to authenticated with check (user_id = auth.uid() and status = 'pending' and verified = false and plan = 'free');
create policy "provider self update" on public.providers for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "provider sees own leads" on public.leads for select to authenticated using (provider_id in (select id from public.providers where user_id = auth.uid()));

-- Public directory WITHOUT phone numbers (phones are released only via unlocked leads)
create view public.provider_directory as
  select id, category_id, name, headline, bio, subjects, levels, area, city, mode, rate_per_hour, experience_years, verified, plan, rating_avg, rating_count
  from public.providers where status = 'active';
grant select on public.provider_directory to anon, authenticated;

insert into public.categories (slug, name, kind) values
 ('tutor','Home & Online Tutors','tutor'),('admission-consultant','Admission Consultants','consultancy'),
 ('assignment-help','Assignment & Project Help','service'),('repair','Repair & Maintenance','service'),('hawker','Hawker / Delivery Jobs','job');

-- TODO server-side (edge function): match enquiry -> leads, unlock logic, Razorpay webhook sets plan='pro', plan_expires_at.
