-- Café Orders · Supabase setup
-- Everything lives in its own schema called "cafe", so it never touches your other tables (Potato Scan uses "potato").
-- The tables are not exposed to the internet. Websites and teammates can only call the functions at the bottom
-- (public.cafe_api, cafe_orders, cafe_order, cafe_usage, cafe_menu), and every call needs an API key from cafe.api_keys.
--
-- Run it: Supabase → SQL Editor → New query → paste this whole file → Run.
-- Safe to run again: it never deletes data.
-- Then load your menu, recipes, materials and keys with the separate seed file (kept out of GitHub).
-- To see the data: Table Editor → choose the "cafe" schema at the top.

create extension if not exists pgcrypto with schema extensions;
create schema if not exists cafe;
revoke all on schema cafe from public, anon, authenticated;

/* ───────────── tables ───────────── */

-- One row of shop settings
create table if not exists cafe.settings (
  id          integer primary key default 1 check (id = 1),
  shop_name   text   not null default 'Café Orders',
  currency    text   not null default '$',
  order_types text[] not null default array['Dine-in','Takeout','Pickup'],
  time_zone   text   not null default 'America/Indiana/Indianapolis'   -- used for "today", dates in filters and order IDs
);
insert into cafe.settings (id) values (1) on conflict (id) do nothing;

-- What can be ordered. Price is optional; totals show once every item on an order has one.
create table if not exists cafe.menu_items (
  item      text primary key,
  category  text    not null default '',
  price     numeric(10,2),
  available boolean not null default true,
  sort      integer not null default 0
);

-- Raw materials (from the inventory framework)
create table if not exists cafe.materials (
  material_id    text primary key,
  name           text not null,
  category       text not null default '',
  pack_size      text not null default '',
  pack_qty       numeric,
  base_unit      text not null default '',
  supplier       text not null default '',
  shelf_life     text not null default '',
  lead_time_days numeric,
  policy         text not null default '',
  rationale      text not null default ''
);

-- How much of each material one menu item uses
create table if not exists cafe.recipe_bom (
  id           bigint generated always as identity primary key,
  item         text not null references cafe.menu_items (item) on update cascade on delete cascade,
  material_id  text not null,
  material     text not null default '',
  usage_amount numeric not null,
  unit         text not null default '',
  notes        text not null default ''
);
create index if not exists recipe_bom_item_idx on cafe.recipe_bom (lower(item));

-- Every change to an order (new order, status change) gets a new, higher version number.
-- Other apps read "everything after version N" and keep the highest version they saw, so nothing is counted twice.
create sequence if not exists cafe.order_version;

create table if not exists cafe.orders (
  id         text primary key,                      -- ORD-YYMMDD-NNN
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  version    bigint not null default nextval('cafe.order_version'),
  customer   text not null default '',
  order_type text not null default '',
  summary    text not null default '',
  item_count integer not null default 0,
  total      numeric(10,2),
  status     text not null default 'New' check (status in ('New','Preparing','Ready','Completed','Cancelled')),
  notes      text not null default '',
  source     text not null default 'Website',
  client_ref text unique                             -- sender's own id, so a retry never creates a second order
);
create index if not exists orders_created_idx on cafe.orders (created_at desc);
create index if not exists orders_version_idx on cafe.orders (version);

create table if not exists cafe.order_items (
  order_id   text    not null references cafe.orders (id) on delete cascade,
  line       integer not null,
  category   text    not null default '',
  item       text    not null,
  qty        integer not null check (qty between 1 and 999),
  unit_price numeric(10,2),
  line_total numeric(10,2),
  note       text not null default '',
  primary key (order_id, line)
);

-- Ingredients used by each order: qty × recipe amount, saved when the order is placed
create table if not exists cafe.order_constituents (
  id             bigint generated always as identity primary key,
  order_id       text not null references cafe.orders (id) on delete cascade,
  item           text not null,
  item_qty       integer not null,
  material_id    text not null,
  material       text not null default '',
  usage_per_item numeric not null,
  total_usage    numeric not null,
  unit           text not null default ''
);
create index if not exists order_constituents_order_idx on cafe.order_constituents (order_id);

create table if not exists cafe.order_counters (
  day date primary key,
  n   integer not null
);

-- API keys. Only a hash of each key is stored.
create table if not exists cafe.api_keys (
  key_hash   text primary key,
  key_prefix text not null default '',
  name       text not null default '',
  scope      text not null default 'read' check (scope in ('read','write')),
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  last_used  timestamptz
);

-- Tables are only reachable through the functions below
alter table cafe.settings enable row level security;
alter table cafe.menu_items enable row level security;
alter table cafe.materials enable row level security;
alter table cafe.recipe_bom enable row level security;
alter table cafe.orders enable row level security;
alter table cafe.order_items enable row level security;
alter table cafe.order_constituents enable row level security;
alter table cafe.order_counters enable row level security;
alter table cafe.api_keys enable row level security;

create or replace function cafe.touch_order() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.version := nextval('cafe.order_version');
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists orders_touch on cafe.orders;
create trigger orders_touch before update on cafe.orders for each row execute function cafe.touch_order();

/* ───────────── helpers ───────────── */

create or replace function cafe.err(msg text) returns jsonb
language sql immutable as $$ select jsonb_build_object('ok', false, 'error', msg) $$;

create or replace function cafe.hash_key(k text) returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(k, ''), 'sha256'), 'hex')
$$;

-- Add a key: select cafe.add_key('ck_r_…', 'Inventory project', 'read');
create or replace function cafe.add_key(k text, key_name text, key_scope text) returns void
language sql set search_path = '' as $$
  insert into cafe.api_keys (key_hash, key_prefix, name, scope)
  values (cafe.hash_key(k), left(k, 9), key_name, key_scope)
  on conflict (key_hash) do update set name = excluded.name, scope = excluded.scope, active = true
$$;

create or replace function cafe.key_scope(k text) returns text
language sql stable set search_path = '' as $$
  select scope from cafe.api_keys where key_hash = cafe.hash_key(k) and active
$$;

create or replace function cafe.tz() returns text
language sql stable set search_path = '' as $$
  select coalesce((select time_zone from cafe.settings where id = 1), 'UTC')
$$;

-- 'YYYY-MM-DD' = that day in the shop's time zone (an end date includes the whole day); anything else is read as an ISO time
create or replace function cafe.bound(t text, is_end boolean) returns timestamptz
language plpgsql stable set search_path = '' as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  if btrim(t) ~ '^\d{4}-\d{2}-\d{2}$' then
    return ((btrim(t)::date + case when is_end then 1 else 0 end)::timestamp) at time zone cafe.tz();
  end if;
  return btrim(t)::timestamptz + case when is_end then interval '1 microsecond' else interval '0' end;
exception when others then
  raise exception 'Can''t read the date "%". Use YYYY-MM-DD or an ISO time like 2026-11-16T14:30:00-05:00', t;
end $$;

create or replace function cafe.today_start() returns timestamptz
language sql stable set search_path = '' as $$
  select ((now() at time zone cafe.tz())::date)::timestamp at time zone cafe.tz()
$$;

create or replace function cafe.order_json(o cafe.orders, detail boolean) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
      'id', o.id, 'createdAt', o.created_at, 'updatedAt', o.updated_at, 'version', o.version,
      'customer', o.customer, 'type', o.order_type, 'summary', o.summary, 'itemCount', o.item_count,
      'total', o.total, 'status', o.status, 'notes', o.notes, 'source', o.source, 'ref', o.client_ref)
    || case when detail then jsonb_build_object(
      'items', coalesce((select jsonb_agg(jsonb_build_object(
          'line', i.line, 'category', i.category, 'item', i.item, 'qty', i.qty,
          'unitPrice', i.unit_price, 'lineTotal', i.line_total, 'note', i.note) order by i.line)
        from cafe.order_items i where i.order_id = o.id), '[]'::jsonb),
      'constituents', coalesce((select jsonb_agg(jsonb_build_object(
          'item', c.item, 'itemQty', c.item_qty, 'materialId', c.material_id, 'material', c.material,
          'perItem', c.usage_per_item, 'total', c.total_usage, 'unit', c.unit) order by c.id)
        from cafe.order_constituents c where c.order_id = o.id), '[]'::jsonb))
    else '{}'::jsonb end
$$;

/* ───────────── reading ───────────── */

create or replace function cafe.menu(p_all boolean, p_recipes boolean) returns jsonb
language plpgsql stable set search_path = '' as $$
declare s cafe.settings;
begin
  select * into s from cafe.settings where id = 1;
  return jsonb_build_object(
    'ok', true, 'shop', s.shop_name, 'currency', s.currency, 'timeZone', s.time_zone,
    'orderTypes', to_jsonb(s.order_types),
    'statuses', to_jsonb(array['New','Preparing','Ready','Completed','Cancelled']),
    'items', coalesce((select jsonb_agg(
        jsonb_build_object('category', m.category, 'item', m.item, 'price', m.price, 'available', m.available,
          'hasRecipe', exists (select 1 from cafe.recipe_bom b where lower(b.item) = lower(m.item)))
        || case when coalesce(p_recipes, false) then jsonb_build_object('recipe', coalesce((select jsonb_agg(jsonb_build_object(
              'materialId', b.material_id, 'material', b.material, 'amount', b.usage_amount, 'unit', b.unit) order by b.id)
            from cafe.recipe_bom b where lower(b.item) = lower(m.item)), '[]'::jsonb)) else '{}'::jsonb end
        order by m.sort, m.category, m.item)
      from cafe.menu_items m where m.available or coalesce(p_all, false)), '[]'::jsonb));
end $$;

-- Two ways to read orders:
--  • after = N  → every order created OR changed after version N, oldest change first, plus "nextAfter" to use next time.
--                 Save orders by id (replace, don't add) and nothing is ever counted twice.
--  • no after   → newest orders first, optionally between two dates / times.
create or replace function cafe.list_orders(p_after bigint, p_from text, p_to text, p_status text, p_max integer, p_detail boolean)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  f timestamptz := cafe.bound(p_from, false);
  t timestamptz := cafe.bound(p_to, true);
  n integer := least(greatest(coalesce(p_max, 100), 1), 1000);
  d boolean := coalesce(p_detail, false);
  sts text[];
  res jsonb; cnt integer; mx bigint; latest bigint;
begin
  if nullif(btrim(p_status), '') is not null then
    select array_agg(initcap(btrim(x))) into sts from unnest(string_to_array(p_status, ',')) x where btrim(x) <> '';
    if exists (select 1 from unnest(sts) x where x not in ('New','Preparing','Ready','Completed','Cancelled')) then
      return cafe.err('status must be New, Preparing, Ready, Completed or Cancelled (comma-separated for several)');
    end if;
  end if;
  select coalesce(max(version), 0) into latest from cafe.orders;

  if p_after is not null then
    select coalesce(jsonb_agg(cafe.order_json(s.o, d) order by (s.o).version), '[]'::jsonb), count(*), max((s.o).version)
      into res, cnt, mx
      from (select o from cafe.orders o
            where o.version > p_after
              and (f is null or o.created_at >= f) and (t is null or o.created_at < t)
              and (sts is null or o.status = any (sts))
            order by o.version limit n) s;
    return jsonb_build_object('ok', true, 'count', cnt, 'orders', res,
      'nextAfter', coalesce(mx, greatest(p_after, case when cnt = 0 then latest else p_after end)),
      'more', cnt = n, 'latestVersion', latest);
  end if;

  select coalesce(jsonb_agg(cafe.order_json(s.o, d) order by (s.o).created_at desc), '[]'::jsonb), count(*)
    into res, cnt
    from (select o from cafe.orders o
          where (f is null or o.created_at >= f) and (t is null or o.created_at < t)
            and (sts is null or o.status = any (sts))
          order by o.created_at desc limit n) s;
  return jsonb_build_object('ok', true, 'count', cnt, 'orders', res, 'more', cnt = n, 'latestVersion', latest);
exception when others then
  return cafe.err(sqlerrm);
end $$;

create or replace function cafe.get_order(p_id text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare o cafe.orders;
begin
  select * into o from cafe.orders where id = upper(btrim(coalesce(p_id, '')));
  if not found then return cafe.err('No order with id ' || coalesce(p_id, '')); end if;
  return jsonb_build_object('ok', true, 'order', cafe.order_json(o, true));
end $$;

-- Ingredient totals for a period (default: today). Cancelled orders are left out.
create or replace function cafe.usage(p_from text, p_to text) returns jsonb
language plpgsql stable set search_path = '' as $$
declare
  f timestamptz := coalesce(cafe.bound(p_from, false), cafe.today_start());
  t timestamptz := coalesce(cafe.bound(p_to, true), case when p_from is null or btrim(p_from) = '' then cafe.today_start() + interval '1 day' else now() + interval '1 day' end);
begin
  return jsonb_build_object('ok', true, 'from', f, 'to', t,
    'orders', (select count(*) from cafe.orders o where o.created_at >= f and o.created_at < t and o.status <> 'Cancelled'),
    'items', coalesce((select jsonb_agg(jsonb_build_object('item', x.item, 'category', x.category, 'qty', x.qty) order by x.qty desc, x.item)
      from (select i.item, max(i.category) category, sum(i.qty) qty
            from cafe.order_items i join cafe.orders o on o.id = i.order_id
            where o.created_at >= f and o.created_at < t and o.status <> 'Cancelled'
            group by i.item) x), '[]'::jsonb),
    'materials', coalesce((select jsonb_agg(jsonb_build_object('materialId', x.material_id, 'material', x.material,
          'category', x.category, 'unit', x.unit, 'total', x.total, 'orders', x.orders) order by x.category, x.material)
      from (select c.material_id, max(c.material) material, coalesce(max(m.category), '') category, c.unit,
                   round(sum(c.total_usage), 4) total, count(distinct c.order_id) orders
            from cafe.order_constituents c join cafe.orders o on o.id = c.order_id
            left join cafe.materials m on m.material_id = c.material_id
            where o.created_at >= f and o.created_at < t and o.status <> 'Cancelled'
            group by c.material_id, c.unit) x), '[]'::jsonb));
exception when others then
  return cafe.err(sqlerrm);
end $$;

/* ───────────── changing ───────────── */

create or replace function cafe.create_order(p jsonb, p_source text) returns jsonb
language plpgsql set search_path = '' as $$
declare
  s cafe.settings; m cafe.menu_items; o cafe.orders;
  it jsonb; v_name text; v_qty numeric; v_type text; v_ref text; v_day date; k integer; v_id text;
  lines jsonb := '[]'::jsonb; missing text[];
begin
  select * into s from cafe.settings where id = 1;
  if jsonb_typeof(p -> 'items') is distinct from 'array' or jsonb_array_length(p -> 'items') = 0 then
    return cafe.err('Add at least one item');
  end if;
  if jsonb_array_length(p -> 'items') > 100 then return cafe.err('Too many lines on one order (max 100)'); end if;

  v_ref := nullif(left(btrim(coalesce(p ->> 'ref', '')), 100), '');
  if v_ref is not null then
    select * into o from cafe.orders where client_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'duplicate', true, 'order', cafe.order_json(o, true)); end if;
  end if;

  v_type := nullif(btrim(coalesce(p ->> 'type', '')), '');
  if v_type is null then v_type := s.order_types[1];
  else
    select x into v_type from unnest(s.order_types) x where lower(x) = lower(v_type);
    if not found then return cafe.err('type must be one of: ' || array_to_string(s.order_types, ', ')); end if;
  end if;

  for it in select value from jsonb_array_elements(p -> 'items') loop
    v_name := btrim(coalesce(it ->> 'item', ''));
    if v_name = '' then return cafe.err('Each item needs a name'); end if;
    begin v_qty := coalesce((it ->> 'qty')::numeric, 1);
    exception when others then return cafe.err('Quantity for ' || v_name || ' must be a whole number from 1 to 999'); end;
    if v_qty <> trunc(v_qty) or v_qty < 1 or v_qty > 999 then
      return cafe.err('Quantity for ' || v_name || ' must be a whole number from 1 to 999');
    end if;
    select * into m from cafe.menu_items where lower(item) = lower(v_name);
    if not found then return cafe.err('Not on the menu: ' || v_name); end if;
    if not m.available then return cafe.err(m.item || ' isn''t available right now'); end if;
    lines := lines || jsonb_build_object('item', m.item, 'category', m.category, 'qty', v_qty::integer,
                        'price', m.price, 'note', left(btrim(coalesce(it ->> 'note', '')), 200));
  end loop;

  v_day := (now() at time zone s.time_zone)::date;
  insert into cafe.order_counters as c (day, n) values (v_day, 1)
    on conflict (day) do update set n = c.n + 1 returning c.n into k;
  v_id := 'ORD-' || to_char(v_day, 'YYMMDD') || '-' || lpad(k::text, 3, '0');

  begin
    insert into cafe.orders (id, customer, order_type, summary, item_count, total, notes, source, client_ref)
    select v_id, left(btrim(coalesce(p ->> 'customer', '')), 80), v_type,
           string_agg((l ->> 'qty') || '× ' || (l ->> 'item'), ', ' order by n),
           sum((l ->> 'qty')::integer),
           case when bool_and(l -> 'price' <> 'null'::jsonb) then sum((l ->> 'qty')::integer * (l ->> 'price')::numeric) end,
           left(btrim(coalesce(p ->> 'notes', '')), 500), p_source, v_ref
    from jsonb_array_elements(lines) with ordinality as x(l, n);
  exception when unique_violation then
    select * into o from cafe.orders where client_ref = v_ref;
    if found then return jsonb_build_object('ok', true, 'duplicate', true, 'order', cafe.order_json(o, true)); end if;
    raise;
  end;

  insert into cafe.order_items (order_id, line, category, item, qty, unit_price, line_total, note)
  select v_id, n, l ->> 'category', l ->> 'item', (l ->> 'qty')::integer, (l ->> 'price')::numeric,
         (l ->> 'qty')::integer * (l ->> 'price')::numeric, l ->> 'note'
  from jsonb_array_elements(lines) with ordinality as x(l, n);

  insert into cafe.order_constituents (order_id, item, item_qty, material_id, material, usage_per_item, total_usage, unit)
  select v_id, l ->> 'item', (l ->> 'qty')::integer, b.material_id, b.material, b.usage_amount,
         round((l ->> 'qty')::integer * b.usage_amount, 4), b.unit
  from jsonb_array_elements(lines) with ordinality as x(l, n)
  join cafe.recipe_bom b on lower(b.item) = lower(l ->> 'item')
  order by n, b.id;

  select array_agg(distinct l ->> 'item') into missing
  from jsonb_array_elements(lines) l
  where not exists (select 1 from cafe.recipe_bom b where lower(b.item) = lower(l ->> 'item'));

  select * into o from cafe.orders where id = v_id;
  return jsonb_build_object('ok', true, 'order', cafe.order_json(o, true))
    || case when missing is not null then jsonb_build_object('warning',
         'No recipe yet for ' || array_to_string(missing, ', ') || ', so no ingredients were recorded for it.') else '{}'::jsonb end;
end $$;

create or replace function cafe.update_status(p_id text, p_status text) returns jsonb
language plpgsql set search_path = '' as $$
declare o cafe.orders; st text := initcap(btrim(coalesce(p_status, '')));
begin
  if st not in ('New','Preparing','Ready','Completed','Cancelled') then
    return cafe.err('status must be New, Preparing, Ready, Completed or Cancelled');
  end if;
  update cafe.orders set status = st where id = upper(btrim(coalesce(p_id, ''))) returning * into o;
  if not found then return cafe.err('No order with id ' || coalesce(p_id, '')); end if;
  return jsonb_build_object('ok', true, 'order', cafe.order_json(o, true));
end $$;

/* ───────────── what the internet can call ───────────── */

-- POST /rest/v1/rpc/cafe_api   body: {"payload": {"key": "…", "action": "…", …}}
-- Used by the order website, and by any app that places orders or changes status.
create or replace function public.cafe_api(payload jsonb) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare
  k cafe.api_keys; a text := coalesce(payload ->> 'action', '');
  h text := cafe.hash_key(payload ->> 'key');
begin
  select * into k from cafe.api_keys where key_hash = h and active;
  if not found then return cafe.err('Missing or wrong API key'); end if;
  update cafe.api_keys set last_used = now() where key_hash = h and (last_used is null or last_used < now() - interval '1 minute');
  if a in ('createOrder','updateStatus') and k.scope <> 'write' then return cafe.err('This key is read-only'); end if;
  return case a
    when 'menu' then cafe.menu((payload ->> 'all')::boolean, (payload ->> 'recipes')::boolean)
    when 'orders' then cafe.list_orders((payload ->> 'after')::bigint, coalesce(payload ->> 'from', payload ->> 'date'),
         coalesce(payload ->> 'to', payload ->> 'date'), payload ->> 'status', (payload ->> 'limit')::integer, (payload ->> 'detail')::boolean)
    when 'order' then cafe.get_order(payload ->> 'id')
    when 'usage' then cafe.usage(coalesce(payload ->> 'from', payload ->> 'date'), coalesce(payload ->> 'to', payload ->> 'date'))
    when 'createOrder' then cafe.create_order(payload,
         case when payload ->> 'via' = 'website' then 'Website' else 'API · ' || k.name end)
    when 'updateStatus' then cafe.update_status(payload ->> 'id', payload ->> 'status')
    else cafe.err('Unknown action "' || a || '". Use menu, orders, order, usage, createOrder or updateStatus')
  end;
exception when others then
  return cafe.err(sqlerrm);
end $$;

-- GET versions for reading, so a link works in a browser:
-- /rest/v1/rpc/cafe_orders?apikey=<publishable key>&key=<API key>&after=0
create or replace function public.cafe_orders(key text, after bigint default null, date_from text default null,
  date_to text default null, status text default null, max_rows integer default 100, detail boolean default false)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when cafe.key_scope($1) is null then cafe.err('Missing or wrong API key')
              else cafe.list_orders($2, $3, $4, $5, $6, $7) end
$$;

create or replace function public.cafe_order(key text, id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when cafe.key_scope($1) is null then cafe.err('Missing or wrong API key') else cafe.get_order($2) end
$$;

create or replace function public.cafe_usage(key text, date_from text default null, date_to text default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when cafe.key_scope($1) is null then cafe.err('Missing or wrong API key') else cafe.usage($2, $3) end
$$;

create or replace function public.cafe_menu(key text, recipes boolean default false, show_all boolean default false)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case when cafe.key_scope($1) is null then cafe.err('Missing or wrong API key') else cafe.menu($3, $2) end
$$;

-- Only the five functions above are callable from outside
revoke all on all functions in schema cafe from public, anon, authenticated;
revoke all on function public.cafe_api(jsonb) from public;
revoke all on function public.cafe_orders(text, bigint, text, text, text, integer, boolean) from public;
revoke all on function public.cafe_order(text, text) from public;
revoke all on function public.cafe_usage(text, text, text) from public;
revoke all on function public.cafe_menu(text, boolean, boolean) from public;
grant execute on function public.cafe_api(jsonb) to anon, authenticated;
grant execute on function public.cafe_orders(text, bigint, text, text, text, integer, boolean) to anon, authenticated;
grant execute on function public.cafe_order(text, text) to anon, authenticated;
grant execute on function public.cafe_usage(text, text, text) to anon, authenticated;
grant execute on function public.cafe_menu(text, boolean, boolean) to anon, authenticated;

notify pgrst, 'reload schema';
