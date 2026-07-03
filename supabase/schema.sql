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
  label        text,                           -- ПОМЕТКА ДЛЯ ТЕБЯ: кто это («Рома и Лиза — с универа», «Мама и Папа мои»). Гостю не показывается.
  greeting     text,                           -- переопределение приветствия («Дорогая семья Ивановых»)
  ticket_names text,                           -- имена для билета; если пусто — соберутся из персон
  address      text check (address in ('ты','вы')),  -- обращение; если пусто — по числу персон
  show_stay    boolean not null default true,  -- показывать ли пункт «Проживание»
  created_at   timestamptz not null default now()
);

-- Если таблица уже создана раньше — create table её не тронет, поэтому
-- добавляем колонку отдельно (безопасно запускать повторно).
alter table guests add column if not exists label text;

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
-- security_invoker = on: view выполняется от имени вызывающего, а не владельца,
-- поэтому RLS применяется к нему (закрывает предупреждение линтера Supabase).
-- drop перед create: create or replace не умеет менять порядок колонок,
-- поэтому при изменении набора колонок витрину пересоздаём с нуля.
drop view if exists answers_overview;
create view answers_overview
  with (security_invoker = on)
as
  select g.token,
         g.label,
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
--  КАК ЗАВОДИТЬ ГОСТЕЙ
--  Демо-данные убраны намеренно: реальные гости заводятся отдельным
--  скриптом в SQL Editor, а этот файл — только структура базы. Так повторный
--  прогон схемы не плодит тестовых гостей.
--  ВАЖНО: token всегда СЛУЧАЙНЫЙ (не имя!). Генерится сам через gen_random_bytes.
--
--  Образец нового приглашения (раскомментируй и поправь):
--
--  -- пара
--  with g as (
--    insert into guests (token, label, ticket_names, show_stay)
--    values (encode(gen_random_bytes(4),'hex'), 'Кто это (пометка для меня)', 'Имена на билет', true)
--    returning id
--  )
--  insert into guest_persons (guest_id, name, gender, sort_order)
--  select id, x.name, x.gender, x.ord
--  from g, (values ('Имя1','m',1), ('Имя2','f',2)) as x(name, gender, ord);
--
--  -- один гость
--  with g as (
--    insert into guests (token, label)
--    values (encode(gen_random_bytes(4),'hex'), 'Кто это (пометка для меня)')
--    returning id
--  )
--  insert into guest_persons (guest_id, name, gender, sort_order)
--  select id, 'Имя', 'f', 1 from g;
-- ═══════════════════════════════════════════════════════════════════════
