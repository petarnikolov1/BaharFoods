-- Bahar Foods — daily menu & delivery — database setup (migration 001).
-- Applied through the Supabase connector. Safe to run again: every statement checks before it creates.
--
-- What it makes:
--   profiles     everyone who can sign in; role = 'admin' for staff
--   admin_emails staff emails that get the admin role (kept only in the database, never in the public repo)
--   dishes       every dish the kitchen makes; "available" = on today's menu (the tick boxes in the admin)
--   settings     one row: restaurant name, phone, order cut-off, delivery slots, cars… and the date the menu is for
--   orders       office deliveries, with status, car and delivery details
--   order_items  the dishes in each order, with the price at the moment of ordering
--   place_order  the only way in for orders: checks the menu date, the cut-off and the REAL prices in the database
--   track_order  lets a customer see the status of their own order (by its secret id)

create extension if not exists pgcrypto;

-- ───────────────────────── 1. Admins ─────────────────────────
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text,
  role       text not null default 'customer',
  created_at timestamptz not null default now()
);

-- Staff who get the admin role. Add or remove an email here and the role follows, whether or not
-- the person has signed up yet. No policies, so the website can never read this list.
create table if not exists public.admin_emails (email text primary key, added_at timestamptz not null default now());
alter table public.admin_emails enable row level security;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name, role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''),
          case when exists (select 1 from public.admin_emails a where lower(a.email) = lower(new.email)) then 'admin' else 'customer' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
insert into public.profiles (id, email) select id, email from auth.users on conflict (id) do nothing;   -- users made before this script

create or replace function public.sync_admins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles p
     set role = case when exists (select 1 from admin_emails a where lower(a.email) = lower(p.email)) then 'admin' else 'customer' end
   where p.role in ('admin', 'customer');
  return null;
end $$;
drop trigger if exists admin_emails_changed on public.admin_emails;
create trigger admin_emails_changed after insert or update or delete on public.admin_emails
  for each statement execute function public.sync_admins();

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'admin');
$$;

alter table public.profiles enable row level security;
drop policy if exists "own profile" on public.profiles;
create policy "own profile" on public.profiles for select using (id = auth.uid() or public.is_admin());

-- ───────────────────────── 2. Dishes ─────────────────────────
create table if not exists public.dishes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  category    text not null default 'Основни',
  description text,
  portion     text,                                   -- e.g. "350 г" or "300 мл"
  price       numeric(10,2) not null default 0 check (price >= 0),
  available   boolean not null default false,         -- on today's menu
  sort        integer not null default 0,
  created_at  timestamptz not null default now()
);
alter table public.dishes enable row level security;
drop policy if exists "dishes are public" on public.dishes;
create policy "dishes are public" on public.dishes for select using (true);
drop policy if exists "admins edit dishes" on public.dishes;
create policy "admins edit dishes" on public.dishes for all using (public.is_admin()) with check (public.is_admin());

-- ───────────────────────── 3. Settings (one row) ─────────────────────────
create table if not exists public.settings (
  id         integer primary key default 1 check (id = 1),
  data       jsonb not null default '{}'::jsonb,
  menu_date  date,                                    -- the day the ticked dishes are for (today or tomorrow)
  updated_at timestamptz not null default now()
);
insert into public.settings (id, data) values (1, '{
  "name": "Bahar Foods",
  "tagline": "Храна с душа!",
  "phone": "0896 687878",
  "address": "бул. Прага 6",
  "shop_hours": "11:00–19:00",
  "delivery_days": "Понеделник – петък 11:00–15:00ч.",
  "slogan": "Твоят вкусен обяд\nза дома и офиса!",
  "logo": "",
  "photo": "",
  "viber": "",
  "website": "",
  "area": "Доставяме до дома и офиса",
  "order_until": "14:30",
  "slots": ["Възможно най-скоро", "11:00 – 11:30", "11:30 – 12:00", "12:00 – 12:30", "12:30 – 13:00", "13:00 – 13:30", "13:30 – 14:00", "14:00 – 14:30", "14:30 – 15:00"],
  "delivery_fee": 0,
  "free_from": 0,
  "min_order": 0,
  "ordering_on": true,
  "cars": ["Кола 1", "Кола 2", "Кола 3", "Кола 4"],
  "categories": ["Супи", "Салати", "Основни", "Добавки", "Аламинути", "Десерти"]
}'::jsonb) on conflict (id) do nothing;
alter table public.settings enable row level security;
drop policy if exists "settings are public" on public.settings;
create policy "settings are public" on public.settings for select using (true);
drop policy if exists "admins edit settings" on public.settings;
create policy "admins edit settings" on public.settings for all using (public.is_admin()) with check (public.is_admin());

-- ───────────────────────── 4. Orders ─────────────────────────
create table if not exists public.orders (
  id               uuid primary key default gen_random_uuid(),
  no               bigint generated by default as identity,       -- the short number people say on the phone
  created_at       timestamptz not null default now(),
  for_date         date not null,
  status           text not null default 'new' check (status in ('new', 'cooking', 'on_way', 'delivered', 'cancelled')),
  source           text not null default 'web',                    -- 'web' or 'phone' (typed in by the admin)
  customer_name    text not null,
  customer_phone   text not null,
  customer_email   text,
  company          text,
  delivery_address text not null,
  delivery_time    text,
  delivery_note    text,
  invoice          boolean not null default false,
  eik              text,
  payment_method   text not null default 'cash',
  subtotal         numeric(10,2) not null default 0,
  delivery_fee     numeric(10,2) not null default 0,
  total            numeric(10,2) not null default 0,
  car              text,
  cancel_reason    text,
  cancelled_at     timestamptz
);
create index if not exists orders_for_date on public.orders (for_date, created_at desc);

create table if not exists public.order_items (
  id       uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  dish_id  uuid,
  name     text not null,
  price    numeric(10,2) not null,
  qty      integer not null check (qty > 0)
);
create index if not exists order_items_order on public.order_items (order_id);

-- Only admins can see or change orders. New orders come in only through place_order below.
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
drop policy if exists "admins manage orders" on public.orders;
create policy "admins manage orders" on public.orders for all using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admins manage order items" on public.order_items;
create policy "admins manage order items" on public.order_items for all using (public.is_admin()) with check (public.is_admin());

-- ───────────────────────── 5. Optional: every new order on your phone through Telegram ─────────────────────────
-- Claude fills the bot token and chat id with execute_sql when the owner wants alerts; never in a file
-- (the website can never read this table).
create table if not exists public.private_config (key text primary key, value text);
alter table public.private_config enable row level security;
do $$ begin
  create extension if not exists pg_net with schema extensions;
exception when others then raise notice 'pg_net not available — Telegram alerts stay off';
end $$;

create or replace function public.telegram_order(p_order uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  tok text; chat text; o record; msg text;
begin
  select value into tok  from private_config where key = 'telegram_bot_token';
  select value into chat from private_config where key = 'telegram_chat_id';
  if coalesce(tok, '') = '' or coalesce(chat, '') = '' then return; end if;
  select * into o from orders where id = p_order;
  msg := '🍲 Нова поръчка №' || o.no || ' — ' || to_char(o.total, 'FM999990.00') || ' €' || chr(10)
      || coalesce((select string_agg('• ' || name || ' × ' || qty, chr(10)) from order_items where order_id = p_order), '') || chr(10) || chr(10)
      || '👤 ' || o.customer_name || coalesce(' · ' || nullif(o.company, ''), '') || chr(10)
      || '📞 ' || o.customer_phone || chr(10)
      || '📍 ' || o.delivery_address || chr(10)
      || '🕐 ' || coalesce(nullif(o.delivery_time, ''), 'Възможно най-скоро')
      || coalesce(chr(10) || '📝 ' || nullif(o.delivery_note, ''), '')
      || case when o.invoice then chr(10) || '🧾 Фактура' || coalesce(' — ЕИК ' || nullif(o.eik, ''), '') else '' end;
  perform net.http_post(
    url  := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', msg));
exception when others then
  raise notice 'telegram: %', sqlerrm;   -- an alert that fails never stops the order
end $$;

-- ───────────────────────── 6. Placing an order ─────────────────────────
create or replace function public.place_order(payload jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s        record;
  cfg      jsonb;
  admin    boolean := public.is_admin();
  today    date := (now() at time zone 'Europe/Sofia')::date;
  now_t    time := (now() at time zone 'Europe/Sofia')::time;
  c        jsonb := coalesce(payload->'customer', '{}'::jsonb);
  v_name   text := left(btrim(coalesce(c->>'name', '')), 120);
  v_phone  text := left(btrim(coalesce(c->>'phone', '')), 40);
  v_addr   text := left(btrim(coalesce(c->>'address', '')), 300);
  v_pay    text := case when payload->>'payment' = 'card' then 'card' else 'cash' end;
  item     jsonb;
  d        record;
  q        integer;
  sub      numeric := 0;
  fee      numeric := 0;
  n_lines  integer := 0;
  missing  integer := 0;
  o_id     uuid;
  o_no     bigint;
begin
  select * into s from settings where id = 1;
  cfg := coalesce(s.data, '{}'::jsonb);

  if s.menu_date is null or s.menu_date < today then raise exception 'menu_closed'; end if;
  if not admin then
    if coalesce((cfg->>'ordering_on')::boolean, true) = false then raise exception 'ordering_off'; end if;
    if s.menu_date = today and coalesce(cfg->>'order_until', '') ~ '^\d{1,2}:\d{2}$' and now_t > (cfg->>'order_until')::time then
      raise exception 'too_late';
    end if;
    if (select count(*) from orders where customer_phone = v_phone and created_at > now() - interval '10 minutes') >= 5 then
      raise exception 'too_many';
    end if;
  end if;
  if v_name = '' or v_addr = '' or length(regexp_replace(v_phone, '\D', '', 'g')) < 6 then raise exception 'missing_fields'; end if;

  insert into orders (for_date, source, customer_name, customer_phone, customer_email, company, delivery_address,
                      delivery_time, delivery_note, invoice, eik, payment_method)
  values (s.menu_date,
          case when admin and payload->>'source' = 'phone' then 'phone' else 'web' end,
          v_name, v_phone,
          nullif(left(btrim(coalesce(c->>'email', '')), 160), ''),
          nullif(left(btrim(coalesce(c->>'company', '')), 160), ''),
          v_addr,
          nullif(left(btrim(coalesce(c->>'time', '')), 60), ''),
          nullif(left(btrim(coalesce(c->>'note', '')), 500), ''),
          coalesce((c->>'invoice')::boolean, false),
          nullif(left(btrim(coalesce(c->>'eik', '')), 20), ''),
          v_pay)
  returning id, no into o_id, o_no;

  -- real prices, and only dishes that are on the menu right now — never what the browser says.
  -- A dish switched off after the customer opened the page stops the whole order ("unavailable"),
  -- so the website can tell them instead of quietly leaving it out.
  for item in select * from jsonb_array_elements(coalesce(payload->'items', '[]'::jsonb)) loop
    if coalesce(item->>'id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
      missing := missing + 1; continue;
    end if;
    select * into d from dishes where id = (item->>'id')::uuid and available;
    if not found then missing := missing + 1; continue; end if;
    q := greatest(1, least(50, coalesce(nullif(item->>'qty', '')::numeric::integer, 1)));
    insert into order_items (order_id, dish_id, name, price, qty) values (o_id, d.id, d.name, d.price, q);
    sub := sub + d.price * q;
    n_lines := n_lines + 1;
  end loop;
  if missing > 0 then raise exception 'unavailable'; end if;                   -- (each of these undoes the order above)
  if n_lines = 0 then raise exception 'empty'; end if;
  if not admin and sub < coalesce((cfg->>'min_order')::numeric, 0) then raise exception 'min_order'; end if;

  fee := coalesce((cfg->>'delivery_fee')::numeric, 0);
  if coalesce((cfg->>'free_from')::numeric, 0) > 0 and sub >= (cfg->>'free_from')::numeric then fee := 0; end if;
  update orders set subtotal = sub, delivery_fee = fee, total = sub + fee where id = o_id;

  perform public.telegram_order(o_id);
  return jsonb_build_object('id', o_id, 'no', o_no, 'total', sub + fee, 'for_date', s.menu_date);
end $$;
grant execute on function public.place_order(jsonb) to anon, authenticated;

-- A customer checks their own order (the id is a long secret they got back when ordering).
create or replace function public.track_order(order_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('no', no, 'status', status, 'for_date', for_date, 'total', total,
                            'delivery_time', delivery_time, 'cancel_reason', cancel_reason)
  from orders where id = order_id;
$$;
grant execute on function public.track_order(uuid) to anon, authenticated;
revoke execute on function public.telegram_order(uuid) from public, anon, authenticated;

-- ───────────────────────── 6b. Website access (row level security above still decides which rows) ─────────────────────────
grant usage on schema public to anon, authenticated;
grant select on public.dishes, public.settings to anon, authenticated;
grant insert, update, delete on public.dishes, public.settings to authenticated;
grant select, insert, update, delete on public.orders, public.order_items to authenticated;
grant select on public.profiles to authenticated;
revoke all on public.private_config, public.admin_emails from anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.sync_admins() from public, anon, authenticated;

-- ───────────────────────── 7. Bahar Foods dishes (from the daily menus 12.10–30.10.2026; only if the list is empty) ─────────────────────────
-- "available" = the 30.10 menu. Switch dishes on and off in the admin; add new ones there too.
insert into public.dishes (name, category, portion, price, available, sort)
select * from (values
  ('Картофена крем супа', 'Супи', '300мл.', 1.95, true, 1),
  ('Пилешка супа', 'Супи', '300мл.', 2.30, true, 2),
  ('Таратор', 'Супи', '300мл.', 1.80, false, 3),
  ('Крем супа от тиквички', 'Супи', '300мл.', 1.95, false, 4),
  ('Крем супа от моркови', 'Супи', '300мл.', 1.95, false, 5),
  ('Зеленчукова крем супа', 'Супи', '300мл.', 1.95, false, 6),
  ('Крем супа от броколи', 'Супи', '300мл.', 1.95, false, 7),
  ('Спаначена крем супа', 'Супи', '300мл.', 1.95, false, 8),
  ('Крем супа от тиква', 'Супи', '300мл.', 1.95, false, 9),
  ('Супа топчета', 'Супи', '300мл.', 2.30, false, 10),
  ('Бистра пилешка супа', 'Супи', '300мл.', 2.30, false, 11),
  ('Супа от пуешко месо', 'Супи', '300мл.', 2.30, false, 12),
  ('Супа от свинско месо', 'Супи', '300мл.', 2.30, false, 13),
  ('Агнешка курбан чорба', 'Супи', '300мл.', 3.50, false, 14),
  ('Агнешка дроб чорба', 'Супи', '300мл.', 3.50, false, 15),
  ('Супа от телешко месо', 'Супи', '300мл.', 3.50, false, 16),
  ('Постни лозови сърми', 'Салати', '200гр.', 2.50, true, 1),
  ('Картофена салата', 'Салати', '200гр.', 2.50, true, 2),
  ('Зеле и моркови', 'Салати', '200гр.', 2.50, true, 3),
  ('Нахут с печен патладжан и печена червена чушка', 'Салати', '200гр.', 2.50, true, 4),
  ('Салата “Снежанка”', 'Салати', '200гр.', 2.50, true, 5),
  ('Мариновани печени чушки', 'Салати', '300гр.', 3.00, true, 6),
  ('Домашна туршия', 'Салати', '200гр.', 3.00, true, 7),
  ('Шопска салата', 'Салати', '200гр.', 2.50, false, 8),
  ('Млечна салата', 'Салати', '200гр.', 2.50, false, 9),
  ('Салата от моркови и сусам', 'Салати', '200гр.', 2.50, false, 10),
  ('Салата от моркови и цвекло', 'Салати', '200гр.', 2.50, false, 11),
  ('Печено цвекло с розмарин', 'Салати', '200гр.', 2.50, false, 12),
  ('Печени зеленчуци', 'Салати', '200гр.', 2.50, false, 13),
  ('Зелен фасул с печени картофки яхния', 'Основни', '350гр.', 3.50, true, 1),
  ('Ориз с кисело зеле', 'Основни', '350гр.', 3.50, true, 2),
  ('Кюфтенца с дом. сос', 'Основни', '350гр.', 4.60, true, 3),
  ('Пилешко бутче с ориз', 'Основни', '350гр.', 4.80, true, 4),
  ('Пиле “Жулиен”, гарнирано с картофено пюре', 'Основни', '350гр.', 5.60, true, 5),
  ('Свинско по Родопски', 'Основни', '350гр.', 5.60, true, 6),
  ('Зеленчуков огретен', 'Основни', '350гр.', 3.50, false, 7),
  ('Ориз с праз и маслини', 'Основни', '350гр.', 3.50, false, 8),
  ('Постен зелен фасул с картофи', 'Основни', '350гр.', 3.50, false, 9),
  ('Ориз с чушки и гъби', 'Основни', '350гр.', 3.50, false, 10),
  ('Спанак с ориз', 'Основни', '350гр.', 3.50, false, 11),
  ('Боб яхния', 'Основни', '350гр.', 3.50, false, 12),
  ('Ориз с праз и домати', 'Основни', '350гр.', 3.50, false, 13),
  ('Ориз със зеленчуци', 'Основни', '350гр.', 3.50, false, 14),
  ('Зелен фасул плакия', 'Основни', '350гр.', 3.50, false, 15),
  ('Яхния от грах и картофки', 'Основни', '350гр.', 3.50, false, 16),
  ('Ориз с горски гъби', 'Основни', '350гр.', 3.50, false, 17),
  ('Пиле с ориз', 'Основни', '350гр.', 3.80, false, 18),
  ('Паста със зеленчуци', 'Основни', '350гр.', 3.80, false, 19),
  ('Яйца по Северняшки', 'Основни', '350гр.', 3.80, false, 20),
  ('Миш-маш', 'Основни', '350гр.', 3.80, false, 21),
  ('Чушки с дом. сос и плочка сиренце', 'Основни', '350гр.', 3.80, false, 22),
  ('Патладжан в дом. сос', 'Основни', '350гр.', 3.80, false, 23),
  ('Патладжан с дом. сос и моцарела', 'Основни', '350гр.', 4.10, false, 24),
  ('Картофена запеканка с бекон и сметана', 'Основни', '350гр.', 4.10, false, 25),
  ('Огретен от карфиол', 'Основни', '350гр.', 4.10, false, 26),
  ('Спаначено суфле', 'Основни', '350гр.', 4.10, false, 27),
  ('Яйца по Панагюрски', 'Основни', '350гр.', 4.10, false, 28),
  ('Юнашко кюфте с гарнитура пухкаво картофено пюре', 'Основни', '350гр.', 4.60, false, 29),
  ('Пилешки дробчета', 'Основни', '350гр.', 4.60, false, 30),
  ('Пълнен патладжан с мляно месо', 'Основни', '350гр.', 4.60, false, 31),
  ('Лазаня “Болонезе”', 'Основни', '350гр.', 4.60, false, 32),
  ('Руло “Мозайка”, гарнирано с пухкаво картофено пюре', 'Основни', '350гр.', 4.60, false, 33),
  ('Овчарски пай', 'Основни', '350гр.', 4.60, false, 34),
  ('Пълнени чушки с мляно месо и ориз', 'Основни', '350гр.', 4.60, false, 35),
  ('Зелеви сърми с мляно месо и ориз', 'Основни', '350гр.', 4.60, false, 36),
  ('Домашна мусака', 'Основни', '350гр.', 4.60, false, 37),
  ('Талиатели Карбонара', 'Основни', '350гр.', 4.60, false, 38),
  ('Кюфтета по Чирпански', 'Основни', '350гр.', 4.60, false, 39),
  ('Унгарско кюфте с пухкаво картофено пюре', 'Основни', '350гр.', 4.60, false, 40),
  ('Агнешка дроб сърма', 'Основни', '350гр.', 4.80, false, 41),
  ('Пиле “Тика масала” с гарнитура', 'Основни', '350гр.', 5.60, false, 42),
  ('Традиционна свинска кавърма', 'Основни', '350гр.', 5.60, false, 43),
  ('Пиле с броколи и сметана', 'Основни', '350гр.', 5.60, false, 44),
  ('Печено свинско със сос и пухкаво картофено пюре', 'Основни', '350гр.', 5.60, false, 45),
  ('Свински късчета с грах и картофи', 'Основни', '350гр.', 5.60, false, 46),
  ('Пиле “Лютика”, гарнирано с ориз Басмати', 'Основни', '350гр.', 5.60, false, 47),
  ('Свинско по Странджански с гарнитура', 'Основни', '350гр.', 5.60, false, 48),
  ('Свинско с ориз по ловджийски', 'Основни', '350гр.', 5.60, false, 49),
  ('Пилешко филе с гъби и сметана, гарнирано с билков ориз', 'Основни', '350гр.', 5.60, false, 50),
  ('Свинско със спанак', 'Основни', '350гр.', 5.60, false, 51),
  ('Пиле в сладко-кисел сос', 'Основни', '350гр.', 5.60, false, 52),
  ('Свинско с гъбен сос и пухкаво картофено пюре', 'Основни', '350гр.', 5.60, false, 53),
  ('Тортила с крехко свинско и зеленчуци', 'Основни', '350гр.', 5.60, false, 54),
  ('Пиле “Султан кебап”', 'Основни', '350гр.', 5.60, false, 55),
  ('Тортила “Чили кон карне”', 'Основни', '350гр.', 5.60, false, 56),
  ('Свински печен джолан с пухкаво картофено пюре', 'Основни', '350гр.', 5.60, false, 57),
  ('Свински жулиени с нудли и зеленчуци в азиатски стил', 'Основни', '350гр.', 5.60, false, 58),
  ('Пиле “4 сирена”, гарнирано с ориз Басмати', 'Основни', '350гр.', 5.60, false, 59),
  ('Свински винен кебап с бял ориз', 'Основни', '350гр.', 5.60, false, 60),
  ('Пилешко филе с плънка от горски гъби и ориз Басмати', 'Основни', '350гр.', 5.60, false, 61),
  ('Свинско с печени картофки', 'Основни', '350гр.', 5.60, false, 62),
  ('Свинско с кисело зеле', 'Основни', '350гр.', 5.60, false, 63),
  ('Тортила с пилешко филе и зеленчуци', 'Основни', '350гр.', 5.60, false, 64),
  ('Пилешко филе на грил с гарнитура', 'Основни', '350гр.', 5.90, false, 65),
  ('Скумрия по Гръцки в доматен сос', 'Основни', '350гр.', 6.90, false, 66),
  ('Крехко пуешко с прясно зеле', 'Основни', '350гр.', 6.90, false, 67),
  ('Сочно пуешко със сос и задушени зеленчуци', 'Основни', '350гр.', 6.90, false, 68),
  ('Банска капама', 'Основни', '350гр.', 6.90, false, 69),
  ('Крехко телешко, гарнирано с пухкаво картофено пюре', 'Основни', '350гр.', 6.90, false, 70),
  ('Пуешко филе със задушени зеленчуци', 'Основни', '350гр.', 6.90, false, 71),
  ('Агнешко по Гергьовски', 'Основни', '350гр.', 7.50, false, 72),
  ('Агнешко със спанак и горски гъби', 'Основни', '350гр.', 7.90, false, 73),
  ('Питка с квас', 'Добавки', '1бр.', 0.80, true, 1),
  ('Порция мариновани люти чушки', 'Добавки', '150гр.', 1.00, true, 2),
  ('Картофено кюфте', 'Аламинути', '1бр.', 1.30, true, 1),
  ('Спаначено кюфте', 'Аламинути', '1бр.', 1.30, true, 2),
  ('Кашкавал пане', 'Аламинути', '1бр.', 2.80, true, 3),
  ('Шницел от мляно месо', 'Аламинути', '1бр.', 2.50, true, 4),
  ('Домашно пържено кюфте', 'Аламинути', '1бр.', 1.30, true, 5),
  ('Хрупкава риба “Тилапия”', 'Аламинути', '1бр.', 3.90, true, 6),
  ('Мляко с ориз', 'Десерти', null, 1.30, true, 1),
  ('Млечна баница', 'Десерти', null, 2.50, true, 2),
  ('Макарони на фурна', 'Десерти', null, 2.50, true, 3),
  ('Грис халва', 'Десерти', null, 1.30, false, 4),
  ('Сладък салам', 'Десерти', null, 2.00, false, 5),
  ('Домашен ябълков щрудел', 'Десерти', null, 2.50, false, 6),
  ('Домашен кекс с ябълки', 'Десерти', null, 2.50, false, 7),
  ('Домашен еклер', 'Десерти', null, 2.50, false, 8),
  ('Домашна бисквитена торта', 'Десерти', null, 2.50, false, 9),
  ('Крем карамел с тиква', 'Десерти', null, 2.50, false, 10),
  ('Печена тиква', 'Десерти', null, 2.50, false, 11),
  ('Крем с профитероли', 'Десерти', null, 3.50, false, 12)
) as v(name, category, portion, price, available, sort)
where not exists (select 1 from public.dishes);

-- ───────────────────────── 8. Staff ─────────────────────────
-- Not part of this file (the repo is public). Claude adds staff with:
--   insert into public.admin_emails (email) values ('name@example.com') on conflict do nothing;
-- and the person creates their login in Supabase › Authentication › Users › Add user (tick "Auto Confirm User").
