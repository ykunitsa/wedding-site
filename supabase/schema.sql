-- ═══════════════════════════════════════════════════════════════════════
--  СХЕМА БАЗЫ ДЛЯ САЙТА-ПРИГЛАШЕНИЯ
--  Запусти этот файл целиком в Supabase: SQL Editor → New query → вставь → Run.
--  Повторный запуск безопасен: таблицы/функции пересоздаются аккуратно.
-- ═══════════════════════════════════════════════════════════════════════

-- ─── ТАБЛИЦЫ ───────────────────────────────────────────────────────────

-- один ряд = одно приглашение (одна персональная ссылка)
create table if not exists guests (
  id           bigint generated always as identity primary key,
  token        text unique not null,          -- случайный код из ссылки ?g=...
  greeting     text,                           -- переопределение приветствия («Дорогая семья Ивановых»)
  ticket_names text,                           -- имена для билета; если пусто — соберутся из персон
  address      text check (address in ('ты','вы')),  -- обращение; если пусто — по числу персон
  show_stay    boolean not null default true,  -- показывать ли пункт «Проживание»
  created_at   timestamptz not null default now()
);

-- один ряд = один приглашённый человек внутри приглашения
create table if not exists guest_persons (
  id           bigint generated always as identity primary key,
  guest_id     bigint not null references guests(id) on delete cascade,
  name         text not null,
  gender       text check (gender in ('m','f')),
  sort_order   int not null default 0,
  attending    boolean,                        -- null = ещё не ответил; true/false — ответ
  responded_at timestamptz
);

-- один ряд = общий ответ по приглашению (трансфер/проживание/меню)
create table if not exists responses (
  guest_id   bigint primary key references guests(id) on delete cascade,
  transfer   text,
  stay       text,
  menu       text,
  updated_at timestamptz not null default now()
);

-- ─── БЕЗОПАСНОСТЬ ──────────────────────────────────────────────────────
-- Включаем RLS и НЕ создаём политик: значит, с публичным anon-ключом
-- напрямую читать/писать таблицы НЕЛЬЗЯ. Доступ только через две функции
-- ниже (security definer) — они требуют токен и отдают лишь своего гостя.
alter table guests        enable row level security;
alter table guest_persons enable row level security;
alter table responses     enable row level security;

-- ─── ФУНКЦИЯ ЧТЕНИЯ: get_guest(token) ─────────────────────────────────
-- Возвращает JSON с данными гостя, его персонами и прошлым ответом.
-- Если токен не найден — возвращает NULL (фронт покажет демо).
create or replace function get_guest(p_token text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'token',       g.token,
    'greeting',    g.greeting,
    'ticketNames', g.ticket_names,
    'address',     g.address,
    'showStay',    g.show_stay,
    'persons', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', p.id, 'name', p.name, 'gender', p.gender, 'attending', p.attending
             ) order by p.sort_order, p.id)
      from guest_persons p where p.guest_id = g.id
    ), '[]'::jsonb),
    'response', (
      select jsonb_build_object(
               'transfer', r.transfer, 'stay', r.stay,
               'menu', r.menu, 'updatedAt', r.updated_at)
      from responses r where r.guest_id = g.id
    )
  )
  from guests g
  where g.token = p_token;
$$;

-- ─── ФУНКЦИЯ ЗАПИСИ: submit_rsvp(...) ─────────────────────────────────
-- Сохраняет присутствие по каждому человеку и общий ответ.
-- p_attendance — массив [{ "id": <person_id>, "attending": true/false }, ...]
create or replace function submit_rsvp(
  p_token      text,
  p_transfer   text,
  p_stay       text,
  p_menu       text,
  p_attendance jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_guest_id bigint;
begin
  select id into v_guest_id from guests where token = p_token;
  if v_guest_id is null then
    raise exception 'unknown token';
  end if;

  -- присутствие по каждому человеку (только внутри этого приглашения)
  update guest_persons p
     set attending    = (a->>'attending')::boolean,
         responded_at = now()
    from jsonb_array_elements(p_attendance) a
   where p.id = (a->>'id')::bigint
     and p.guest_id = v_guest_id;

  -- общий ответ: создаём или обновляем
  insert into responses (guest_id, transfer, stay, menu, updated_at)
  values (v_guest_id, p_transfer, p_stay, p_menu, now())
  on conflict (guest_id) do update
    set transfer   = excluded.transfer,
        stay       = excluded.stay,
        menu       = excluded.menu,
        updated_at = now();
end;
$$;

-- Разрешаем вызывать эти две функции публичному ключу (anon).
-- Больше anon ничего не может: остальные таблицы закрыты RLS.
grant execute on function get_guest(text)                              to anon, authenticated;
grant execute on function submit_rsvp(text, text, text, text, jsonb)   to anon, authenticated;

-- ─── УДОБНЫЙ ПРОСМОТР ОТВЕТОВ (для дашборда) ──────────────────────────
-- Показывает по строке на каждого человека: кто идёт + общий ответ.
-- Смотреть в Table Editor. Гостям недоступно (грантов нет).
create or replace view answers_overview as
  select g.token,
         coalesce(g.ticket_names, string_agg(p.name, ', ')) as invite,
         p.name,
         p.attending,
         r.transfer, r.stay, r.menu, r.updated_at
  from guests g
  join guest_persons p on p.guest_id = g.id
  left join responses  r on r.guest_id = g.id
  group by g.id, p.id, r.guest_id
  order by g.id, p.sort_order, p.id;


-- ═══════════════════════════════════════════════════════════════════════
--  ПРИМЕР: как заводить гостей
--  Ниже — те же 4 демо-ссылки, что были на фронте. Можно запустить как есть
--  для проверки, а потом добавлять своих по этому образцу.
--  ВАЖНО: для реальных гостей ставь СЛУЧАЙНЫЙ token (не имя!), напр.
--         сгенерировать: select encode(gen_random_bytes(6), 'hex');
-- ═══════════════════════════════════════════════════════════════════════

-- пара, оба на «ты», проживание показываем
with g as (
  insert into guests (token, show_stay) values ('k7f3q9x2', true)
  on conflict (token) do nothing returning id
)
insert into guest_persons (guest_id, name, gender, sort_order)
select id, x.name, x.gender, x.ord
from g, (values ('Рома','m',1), ('Лиза','f',2)) as x(name, gender, ord);

-- родители — обращение на «вы», проживание не нужно
with g as (
  insert into guests (token, greeting, ticket_names, address, show_stay)
  values ('m2p8v5x1', 'Дорогие Мама и Папа', 'Мама и Папа', 'вы', false)
  on conflict (token) do nothing returning id
)
insert into guest_persons (guest_id, name, gender, sort_order)
select id, x.name, x.gender, x.ord
from g, (values ('Мама','f',1), ('Папа','m',2)) as x(name, gender, ord);

-- один гость
with g as (
  insert into guests (token, show_stay) values ('s0lo1122', false)
  on conflict (token) do nothing returning id
)
insert into guest_persons (guest_id, name, gender, sort_order)
select id, 'Анна', 'f', 1 from g;

-- семья — своё приветствие, но в анкете каждый отмечается сам
with g as (
  insert into guests (token, greeting, ticket_names, show_stay)
  values ('fam77xyz', 'Дорогая семья Ивановых', 'Семья Ивановых', true)
  on conflict (token) do nothing returning id
)
insert into guest_persons (guest_id, name, gender, sort_order)
select id, x.name, x.gender, x.ord
from g, (values ('Игорь','m',1), ('Оля','f',2), ('Мия','f',3)) as x(name, gender, ord);
