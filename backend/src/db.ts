import { MongoClient, type Collection } from "mongodb";
import { config } from "./config.js";
import type { DayOverride, Entry, Point, Regime, RegimeCheck, Rule, Session, TravelDocument, User } from "./types.js";
import type { City } from "./cities.js";
import type { DiscoverLog, PlaceDismissal, PlaceRating, PlaceSave, TastePreferences, TasteProfile } from "./discover.js";
import type { Job } from "./jobs.js";

const client = new MongoClient(config.mongoUrl);

export let users: Collection<User>;
export let sessions: Collection<Session>;
export let points: Collection<Point>;
export let dayOverrides: Collection<DayOverride>;
export let rules: Collection<Rule>;
export let documents: Collection<TravelDocument>;
export let entries: Collection<Entry>;
export let regimes: Collection<Regime>;
export let regimeChecks: Collection<RegimeCheck>;
// справочник городов GeoNames (общий для всех пользователей)
export let cities: Collection<City>;
// «Чем заняться»: кэш ответов Google (сутки), оценки, сохранённые, «не интересно», профиль вкусов
export let placeCache: Collection<{ key: string; data: unknown; expiresAt: Date }>;
export let placeRatings: Collection<PlaceRating>;
export let placeSaves: Collection<PlaceSave>;
export let placeDismissals: Collection<PlaceDismissal>;
export let tasteProfiles: Collection<TasteProfile>;
export let tastePreferences: Collection<TastePreferences>;
export let discoverLog: Collection<DiscoverLog>;
export let jobs: Collection<Job>;
export let citiesMeta: Collection<{ _id: string; source: string; importedAt: string; count: number; i18n?: string[]; i18nAt?: string }>;

export async function connectDb() {
  await client.connect();
  const db = client.db();
  users = db.collection<User>("users");
  sessions = db.collection<Session>("sessions");
  points = db.collection<Point>("points");
  dayOverrides = db.collection<DayOverride>("day_overrides");
  rules = db.collection<Rule>("rules");
  documents = db.collection<TravelDocument>("documents");
  entries = db.collection<Entry>("entries");
  regimes = db.collection<Regime>("regimes");
  regimeChecks = db.collection<RegimeCheck>("regime_checks");
  cities = db.collection<City>("cities");
  citiesMeta = db.collection("cities_meta");
  placeCache = db.collection("place_cache");
  placeRatings = db.collection<PlaceRating>("place_ratings");
  placeSaves = db.collection<PlaceSave>("place_saves");
  placeDismissals = db.collection<PlaceDismissal>("place_dismissals");
  tasteProfiles = db.collection<TasteProfile>("taste_profiles");
  tastePreferences = db.collection<TastePreferences>("taste_preferences");
  discoverLog = db.collection<DiscoverLog>("discover_log");
  jobs = db.collection<Job>("jobs");

  await Promise.all([
    rules.createIndex({ userId: 1, id: 1 }, { unique: true }),
    rules.createIndex({ userId: 1, documentId: 1 }),
    documents.createIndex({ userId: 1, id: 1 }, { unique: true }),
    entries.createIndex({ userId: 1, id: 1 }, { unique: true }),
    entries.createIndex({ userId: 1, countryCode: 1, date: 1 }, { unique: true }),
    regimes.createIndex({ userId: 1, id: 1 }, { unique: true }),
    regimes.createIndex({ userId: 1, passportId: 1, countryCode: 1 }, { unique: true }),
    regimeChecks.createIndex({ id: 1 }, { unique: true }),
    regimeChecks.createIndex({ passportCode: 1, countryCode: 1, requestedAt: -1 }),
    rules.createIndex({ userId: 1, regimeId: 1 }),
    users.createIndex({ "apple.sub": 1 }, { unique: true, sparse: true }),
    users.createIndex({ "google.sub": 1 }, { unique: true, sparse: true }),
    users.createIndex({ email: 1 }, { sparse: true }),
    sessions.createIndex({ tokenHash: 1 }, { unique: true }),
    sessions.createIndex({ userId: 1 }),
    points.createIndex({ userId: 1, clientId: 1 }, { unique: true }),
    points.createIndex({ userId: 1, recordedAt: 1 }),
    points.createIndex({ userId: 1, localDate: 1 }),
    // раньше день был уникален сам по себе; теперь две страны могут делить день перелёта
    dayOverrides.dropIndex("userId_1_localDate_1").catch(() => {}),
    dayOverrides.createIndex({ userId: 1, localDate: 1, countryCode: 1 }, { unique: true }),
    cities.createIndex({ countryCode: 1, population: -1 }),
    cities.createIndex({ countryCode: 1, search: 1 }),
    placeCache.createIndex({ key: 1 }, { unique: true }),
    placeCache.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0 }),
    placeRatings.createIndex({ userId: 1, placeId: 1 }, { unique: true }),
    placeSaves.createIndex({ userId: 1, placeId: 1 }, { unique: true }),
    placeDismissals.createIndex({ userId: 1, placeId: 1 }, { unique: true }),
    tasteProfiles.createIndex({ userId: 1 }, { unique: true }),
    tastePreferences.createIndex({ userId: 1 }, { unique: true }),
    discoverLog.createIndex({ userId: 1, at: -1 }),
    jobs.createIndex({ id: 1 }, { unique: true }),
    jobs.createIndex({ expiresAt: 1 }, { expireAfterSeconds: 0 }),
  ]);

  console.log(`Mongo connected: ${db.databaseName}`);
}

export async function closeDb() {
  await client.close();
}
