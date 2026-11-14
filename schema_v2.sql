-- Khojlo schema v2. Run AFTER schema.sql, in the Supabase SQL editor. Safe to re-run.

-- 1) SECURITY: providers must not be able to set plan/status/verified/rating/free_leads_left themselves
revoke insert, update on public.providers from anon, authenticated;
grant insert (user_id, category_id, name, phone, headline, bio, subjects, levels, area, city, mode, rate_per_hour, experience_years)
  on public.providers to authenticated;
grant update (category_id, name, phone, headline, bio, subjects, levels, area, mode, rate_per_hour, experience_years)
  on public.providers to authenticated;

drop policy if exists "provider self insert" on public.providers;
create policy "provider self insert" on public.providers for insert to authenticated
  with check (user_id = auth.uid());

-- Force safe defaults on rows created by app users (SQL-editor seeds, where auth.uid() is null, keep their values)
create or replace function public.providers_defaults() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null then
    new.status := 'active'; new.verified := false; new.plan := 'free';
    new.plan_expires_at := null; new.free_leads_left := 3;
    new.rating_avg := 0; new.rating_count := 0;
  end if;
  return new;
end $$;
drop trigger if exists trg_providers_defaults on public.providers;
create trigger trg_providers_defaults before insert on public.providers
  for each row execute function public.providers_defaults();

-- 2) Tighten public write policies (spam control). Reviews get a proper flow later.
drop policy if exists "reviews insert" on public.reviews;
drop policy if exists "enquiries insert" on public.enquiries;
drop policy if exists "jobs insert" on public.jobs;
create policy "jobs insert" on public.jobs for insert
  with check (status = 'open' and char_length(title) between 3 and 120 and char_length(contact_phone) = 10);

-- 3) Lead matching: runs automatically when an enquiry is created
create or replace function public.match_enquiry() returns trigger
language plpgsql security definer set search_path = public as $$
declare p record; unl boolean;
begin
  for p in
    select id, plan, plan_expires_at, free_leads_left
    from public.providers
    where status = 'active' and category_id = new.category_id
    order by
      (case when new.area is not null and lower(area) = lower(new.area) then 3 else 0 end)
      + 2 * (select count(*) from unnest(subjects) s where new.requirement ilike '%' || s || '%')
      + (case when verified then 1 else 0 end)
      + coalesce(rating_avg, 0) / 5.0 desc
    limit 5
  loop
    unl := false;
    if p.plan = 'pro' and (p.plan_expires_at is null or p.plan_expires_at > now()) then
      unl := true;
    elsif p.free_leads_left > 0 then
      unl := true;
      update public.providers set free_leads_left = free_leads_left - 1 where id = p.id;
    end if;
    insert into public.leads (enquiry_id, provider_id, unlocked) values (new.id, p.id, unl)
      on conflict do nothing;
  end loop;
  return new;
end $$;
drop trigger if exists trg_match_enquiry on public.enquiries;
create trigger trg_match_enquiry after insert on public.enquiries
  for each row execute function public.match_enquiry();

-- 4) Public RPC to submit an enquiry. Returns who it was sent to (names/areas only, never phones)
create or replace function public.submit_enquiry(p_category int, p_name text, p_phone text,
  p_requirement text, p_area text, p_budget int)
returns jsonb language plpgsql security definer set search_path = public as $$
declare eid uuid; res jsonb;
begin
  if char_length(trim(coalesce(p_name,''))) < 2 or char_length(trim(coalesce(p_name,''))) > 80 then raise exception 'invalid name'; end if;
  if p_phone !~ '^[0-9]{10}$' then raise exception 'invalid phone'; end if;
  if char_length(trim(coalesce(p_requirement,''))) < 5 or char_length(p_requirement) > 500 then raise exception 'invalid requirement'; end if;
  insert into public.enquiries (category_id, name, phone, requirement, area, budget)
    values (p_category, trim(p_name), p_phone, trim(p_requirement), nullif(trim(coalesce(p_area,'')),''), p_budget)
    returning id into eid;
  select coalesce(jsonb_agg(jsonb_build_object('name', pr.name, 'area', pr.area)), '[]'::jsonb) into res
    from public.leads l join public.providers pr on pr.id = l.provider_id where l.enquiry_id = eid;
  return jsonb_build_object('matched', res);
end $$;
grant execute on function public.submit_enquiry(int,text,text,text,text,int) to anon, authenticated;

-- 5) Provider's own leads; customer phone only visible when unlocked
create or replace function public.my_leads()
returns table (lead_id uuid, requirement text, category_id int, area text, budget int,
               created_at timestamptz, unlocked boolean, customer_name text, customer_phone text)
language sql stable security definer set search_path = public as $$
  select l.id, e.requirement, e.category_id, e.area, e.budget, l.created_at, l.unlocked,
         case when l.unlocked then e.name end, case when l.unlocked then e.phone end
  from public.leads l
  join public.enquiries e on e.id = l.enquiry_id
  join public.providers p on p.id = l.provider_id
  where p.user_id = auth.uid()
  order by l.created_at desc
$$;
grant execute on function public.my_leads() to authenticated;
revoke execute on function public.my_leads() from anon;

-- 6) Demo seed (user_id is null). Remove later with:
--    delete from public.providers where user_id is null and phone like '0000%';
insert into public.providers (category_id, name, phone, headline, subjects, area, mode, rate_per_hour, experience_years, verified, status, plan, rating_avg, rating_count)
select * from (values
 (1,'Rohit Sharma (demo)','0000000001','Maths & Physics, Class 9-12 (CBSE)',array['maths','physics'],'Dwarka','both',600,8,true,'active','free',4.8,32),
 (1,'Anita Verma (demo)','0000000002','English & Hindi, Class 6-10',array['english','hindi'],'Rohini','home',400,5,true,'active','free',4.6,18),
 (1,'Sandeep Kumar (demo)','0000000003','JEE/NEET Chemistry',array['chemistry','jee','neet'],'Laxmi Nagar','online',800,10,true,'active','free',4.9,51),
 (2,'Neha Gupta (demo)','0000000004','DU & IPU admission guidance',array['du','ipu','cuet'],'Karol Bagh','both',0,6,true,'active','free',4.7,22),
 (3,'Arjun Mehta (demo)','0000000005','Assignments, PPTs, lab reports',array['assignment','ppt','report'],'Janakpuri','online',0,4,false,'active','free',4.4,12),
 (4,'Imran Electricals (demo)','0000000006','AC, fridge, washing machine repair',array['ac','fridge','washing machine'],'Dwarka','home',0,12,true,'active','free',4.5,40)
) as v(category_id,name,phone,headline,subjects,area,mode,rate_per_hour,experience_years,verified,status,plan,rating_avg,rating_count)
where not exists (select 1 from public.providers where phone like '0000%');

insert into public.jobs (category_id, title, description, area, pay_text, contact_phone)
select * from (values
 (5,'Newspaper hawker - morning route','3 hours, 5 days/week','Dwarka','Rs 9,000/mo','9820000001'),
 (5,'Delivery partner (bike required)','Local grocery delivery','Rohini','Rs 15,000-20,000/mo','9820000002'),
 (4,'AC technician helper','Training provided','Janakpuri','Rs 12,000/mo','9820000003')
) as v(category_id,title,description,area,pay_text,contact_phone)
where not exists (select 1 from public.jobs);

-- Manual upgrade until payments are wired (replace phone):
-- update public.providers set plan='pro', plan_expires_at = now() + interval '30 days' where phone = '98xxxxxxxx';
-- update public.leads set unlocked = true where provider_id = (select id from public.providers where phone = '98xxxxxxxx');
