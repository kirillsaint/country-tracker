# Country Counter

Личный трекер: в каких странах и городах я провожу время. iOS-приложение пишет точки
геолокации в фоне, бэкенд на TypeScript считает дни по странам, резидентство (183 дня)
и правило Шенгена 90/180.

```
backend/   Hono + MongoDB, Docker
ios/       SwiftUI, проект генерируется XcodeGen'ом
```

## Как это работает

Приложение **не** опрашивает GPS раз в час по таймеру — iOS такого не даёт. Вместо этого:

1. **Visit monitoring** — iOS сама сообщает «приехал в место / уехал». Почти не ест батарею.
2. **Significant location changes** — переезды на ~500 м+ / смена соты. Ловит смену города и страны.
3. **BGAppRefreshTask** раз в час (не гарантированно) — снимает одну точку как страховка.
4. При открытии приложения — точка, не чаще раза в 30 минут.

Точки копятся локально (`pending-points.json`) и уходят на сервер пачкой, когда есть сеть.
Сервер определяет страну по координатам оффлайн (`@rapideditor/country-coder`), город
приходит с устройства (`CLGeocoder`).

Статистика считается из сырых точек каждый раз заново. Точек мало (visit monitoring молчит,
пока стоишь на месте), поэтому дни между двумя соседними точками приписываются стране более
ранней точки. День с двумя странами засчитывается обеим — так работают правила резидентства.
Любой день можно поправить вручную (`PUT /api/days/:date`).

## Бэкенд

### Запуск через Docker

```bash
cp .env.example .env      # заполнить ALLOWED_EMAILS, при необходимости GOOGLE_CLIENT_IDS
docker compose up -d --build
curl localhost:3000/health
```

Данные Mongo живут в volume `mongo-data`. Порт API публикуется только на `127.0.0.1:3000` —
наружу смотрит nginx.

### Деплой: nginx + Cloudflare

Схема: iPhone → Cloudflare (HTTPS, сертификат Cloudflare) → nginx на сервере по HTTP →
Docker на `127.0.0.1:3000`.

```bash
# на сервере
git clone <repo> country-counter && cd country-counter
cp .env.example .env && nano .env            # ALLOWED_EMAILS, GOOGLE_CLIENT_IDS
docker compose up -d --build
curl localhost:3000/health                   # {"ok":true}

# nginx
sudo cp deploy/nginx/country-tracker.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/country-tracker.conf /etc/nginx/sites-enabled/
sudo sh deploy/nginx/update-cloudflare-ips.sh   # создаёт /etc/nginx/cloudflare-ips.conf и перезагружает nginx
```

В Cloudflare: A-запись `country-tracker` → IP сервера с включённым прокси (оранжевое облако);
SSL/TLS → Overview → **Flexible**. Проверка: `curl https://country-tracker.kirillsaint.ge/health`.

Обновление: `git pull && docker compose up -d --build`. Бэкап базы:
`docker compose exec mongo mongodump --archive --db country_counter > backup.archive`.

### Локально без Docker

```bash
cd backend
pnpm install
pnpm dev          # переменные берутся из ../.env, если он есть
```

### Переменные окружения

| Переменная | Что это |
|---|---|
| `APPLE_BUNDLE_ID` | bundle id приложения, проверяется как `aud` в Apple identity token |
| `GOOGLE_CLIENT_IDS` | iOS OAuth client id из Google Cloud Console. Пусто — вход через Google выключен |
| `ALLOWED_EMAILS` | кому можно регистрироваться. **Пусто — кому угодно**; для личного сервера впишите свой email |
| `MONGO_URL`, `PORT` | очевидно |

### API

Авторизация — `Authorization: Bearer <session token>`. Токен выдаётся при входе и живёт,
пока не сделать `/auth/logout`.

```
POST /auth/signin/apple      { identityToken, fullName?, device? }  -> { token, user, created, autoLinked }
POST /auth/signin/google     { identityToken, device? }
GET  /auth/me
POST /auth/logout
POST /auth/link/:provider    { identityToken }   привязать второй способ входа
POST /auth/unlink/:provider                      отвязать (нельзя отвязать последний)

POST /api/points             { points: [...] }   пачка точек, дубли по clientId пропускаются
GET  /api/points?from&to&limit
GET  /api/stats/countries?from&to&tz             дни по странам (по умолчанию — текущий год)
GET  /api/stats/cities?from&to&tz                дни по городам
GET  /api/stats/current?tz                       где я сейчас, сколько дней подряд
GET  /api/timeline?from&to&tz                    отрезки «страна: с — по»
GET  /api/days?from&to&tz                        календарь по дням
PUT  /api/days/:date         { countryCode, city?, note? }   ручная правка дня
DELETE /api/days/:date
GET  /api/overrides                              все ручные правки
PUT  /api/overrides/range    { from, to, countryCode, city?, note? }   «был в стране с … по …» (история до установки)
DELETE /api/overrides/range?from&to

GET  /api/rules                                  правила подсчёта (у нового пользователя — Шенген 90/180)
POST /api/rules              { name, type, countries, limitDays, windowDays?, startDate?, mode, countMode, warnRemainingDays?, notify, enabled }
PUT  /api/rules/:id
DELETE /api/rules/:id
GET  /api/stats/rules?tz                         результаты по включённым правилам

GET  /api/export                                 полный дамп
```

`tz` — смещение таймзоны пользователя в минутах; по нему сервер определяет «сегодня»
(без него берётся пояс последней точки).

### Правила подсчёта

Вместо зашитых «183 дня» и «90/180» — произвольные правила:

- `type`: `calendarYear` (1 января – 31 декабря), `rolling` (любые `windowDays` подряд, окно
  заканчивается сегодня), `fromDate` (с `startDate` на `windowDays` дней или бессрочно);
- `autoStart` (только `fromDate`): дата начала определяется по данным — первый день текущего
  непрерывного пребывания в странах правила. Выехал и вернулся — отсчёт с нуля. Так работает,
  например, безвиз Грузии для россиян (365 дней с въезда). Ответ содержит найденную `entryDate`;
- `mode`: `limit` — нельзя превышать (визы), `goal` — нужно набрать (резидентство);
- `countries`: список ISO-кодов, пусто — любая страна;
- `countMode`: `any` — день считается при любом заходе в страну, `primary` — только если это
  основная (последняя) страна дня;
- `warnRemainingDays` / `notify` — порог предупреждения и уведомления.

Для `limit`-правил сервер считает `canStayDays` — сколько дней подряд, начиная с завтра,
можно оставаться, не нарушив правило (для скользящего окна — с учётом того, какие дни из
окна выпадут). Уведомления локальные: приложение проверяет результаты после каждого
обновления статистики и после фоновой отправки точек.

Если вход через Google c тем же подтверждённым email, что и у существующего Apple-аккаунта,
провайдер привязывается к нему автоматически (`autoLinked: true`) — второй аккаунт не создаётся.
Apple «Скрыть e-mail» даёт relay-адрес, он не совпадёт — тогда привязка руками из настроек.

## iOS

### Что нужно один раз

1. **Xcode** из App Store (Command Line Tools недостаточно).
2. **XcodeGen**: `brew install xcodegen`.
3. **Платный Apple Developer Program** ($99/год). Без него нельзя включить capability
   «Sign in with Apple», и бесплатная подпись живёт 7 дней — для трекера, который должен
   работать месяцами, это не вариант.
4. `cp ios/Config.xcconfig.example ios/Config.xcconfig`, вписать `DEVELOPMENT_TEAM`.
5. Для Google: в [Google Cloud Console → Credentials](https://console.cloud.google.com/apis/credentials)
   создать OAuth client типа iOS с bundle id `ge.kirillsaint.countrycounter`; client id и
   reversed client id — в `Config.xcconfig`, client id — ещё и в `GOOGLE_CLIENT_IDS` на сервере.
   Пока не сделано — кнопка Google неактивна, Apple работает.

### Сборка

```bash
cd ios
xcodegen generate
open CountryCounter.xcodeproj
```

В Xcode: выбрать свой iPhone, Run. При первом запуске на устройстве — Settings → General →
VPN & Device Management → доверять разработчику.

### Первый запуск

1. Ввести адрес сервера, войти через Apple или Google.
2. Разрешить геолокацию. iOS сначала спросит «при использовании»; через некоторое время
   сама предложит «всегда» — нужно согласиться, иначе фоновые точки не пишутся.
   Проверить: Настройки → Геолокация → «всегда».
3. Настройки → «Записать точку сейчас» — убедиться, что точка доехала до сервера.

### Отладка фона

- Раздел «Последние события» в настройках показывает, что приходило от Core Location.
- BGAppRefreshTask в симуляторе не срабатывает по расписанию. На устройстве под отладчиком
  можно дёрнуть вручную: пауза в lldb и
  `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"ge.kirillsaint.countrycounter.refresh"]`
- Симулятор: Features → Location → City Run / Freeway Drive генерируют significant changes.

## Что дальше

- Виджет на домашний экран (текущая страна + дни) — нужен App Group для общего хранилища.
- Live Activity при пересечении границы.
- Push/локальные уведомления при приближении к 183 и 90 дням.
- Карта посещённых стран.
