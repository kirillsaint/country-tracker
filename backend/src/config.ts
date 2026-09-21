function list(name: string): string[] {
  return (process.env[name] ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
}

export const config = {
  port: Number(process.env.PORT ?? 3000),
  mongoUrl: process.env.MONGO_URL ?? "mongodb://localhost:27017/country_counter",

  // Sign in with Apple: aud в identity token = bundle id приложения
  appleBundleId: process.env.APPLE_BUNDLE_ID ?? "ge.kirillsaint.stamps",
  // Google: aud = OAuth client id (iOS-клиент). Можно несколько через запятую.
  googleClientIds: list("GOOGLE_CLIENT_IDS"),
  // Откуда брать публичные ключи для проверки identity token'ов. Менять только для тестов.
  appleJwksUrl: process.env.APPLE_JWKS_URL ?? "https://appleid.apple.com/auth/keys",
  googleJwksUrl: process.env.GOOGLE_JWKS_URL ?? "https://www.googleapis.com/oauth2/v3/certs",
  // Кому вообще можно регистрироваться. Пусто = кому угодно. Для личного сервера —
  // впишите свои email'ы, иначе любой, кто найдёт адрес, заведёт себе аккаунт.
  allowedEmails: new Set(list("ALLOWED_EMAILS").map((e) => e.toLowerCase())),

  // OpenRouter — нейросеть с веб-поиском для «Заполнить автоматически». Пусто = только ручной ввод.
  openRouterApiKey: process.env.OPENROUTER_API_KEY ?? "",
  openRouterModel: process.env.OPENROUTER_MODEL ?? "openai/gpt-5.6-sol",
  // быстрая модель для рекомендаций и маршрутов: там нужен подбор из готового списка, а не исследование
  openRouterFastModel: process.env.OPENROUTER_FAST_MODEL ?? "openai/gpt-5.6-luna",
  openRouterBaseUrl: process.env.OPENROUTER_BASE_URL ?? "https://openrouter.ai/api/v1",
  // Google Places API (New) — факты о местах для раздела «Чем заняться». Пусто = раздел выключен.
  googlePlacesApiKey: process.env.GOOGLE_PLACES_API_KEY ?? "",
  // публичный адрес сервера для подписанных ссылок на фото; пусто — берётся из запроса (dev: localhost)
  publicBaseUrl: process.env.PUBLIC_BASE_URL ?? "",
  // сколько дней результат проверки режима считается свежим (кэш + порог «перепроверить при въезде»)
  regimeFreshDays: Number(process.env.REGIME_FRESH_DAYS ?? 30),
  // Self Store — откуда приложение узнаёт о новой версии: адрес магазина и id приложения Stamps в нём.
  // Пусто — проверка обновлений выключена.
  selfStoreUrl: (process.env.SELF_STORE_URL ?? "").replace(/\/$/, ""),
  selfStoreAppId: process.env.SELF_STORE_APP_ID ?? "",
  // Админка в браузере (/admin): кто может войти (email из Google) и web-клиент Google OAuth для кнопки входа.
  // Пусто — админка выключена.
  adminEmails: new Set(list("ADMIN_EMAILS").map((e) => e.toLowerCase())),
  adminGoogleClientId: process.env.ADMIN_GOOGLE_CLIENT_ID ?? "",
  // ключ Maps JavaScript API для карты точек в админке (браузерный, ограничить по referrer). Пусто — OpenStreetMap
  adminGoogleMapsKey: process.env.ADMIN_GOOGLE_MAPS_KEY ?? "",
  // куда собран React админки (в докере — /app/admin, при разработке — admin/dist)
  adminDistDir: process.env.ADMIN_DIST ?? "admin/dist",
};

if (config.googleClientIds.length === 0) {
  console.warn("GOOGLE_CLIENT_IDS is empty: Google sign-in is disabled until you set it");
}
