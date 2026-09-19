import { MongoClient, type Collection } from "mongodb";
import { config } from "./config.js";
import type { DayOverride, Point, Rule, Session, User } from "./types.js";

const client = new MongoClient(config.mongoUrl);

export let users: Collection<User>;
export let sessions: Collection<Session>;
export let points: Collection<Point>;
export let dayOverrides: Collection<DayOverride>;
export let rules: Collection<Rule>;

export async function connectDb() {
  await client.connect();
  const db = client.db();
  users = db.collection<User>("users");
  sessions = db.collection<Session>("sessions");
  points = db.collection<Point>("points");
  dayOverrides = db.collection<DayOverride>("day_overrides");
  rules = db.collection<Rule>("rules");

  await Promise.all([
    rules.createIndex({ userId: 1, id: 1 }, { unique: true }),
    users.createIndex({ "apple.sub": 1 }, { unique: true, sparse: true }),
    users.createIndex({ "google.sub": 1 }, { unique: true, sparse: true }),
    users.createIndex({ email: 1 }, { sparse: true }),
    sessions.createIndex({ tokenHash: 1 }, { unique: true }),
    sessions.createIndex({ userId: 1 }),
    points.createIndex({ userId: 1, clientId: 1 }, { unique: true }),
    points.createIndex({ userId: 1, recordedAt: 1 }),
    points.createIndex({ userId: 1, localDate: 1 }),
    dayOverrides.createIndex({ userId: 1, localDate: 1 }, { unique: true }),
  ]);

  console.log(`Mongo connected: ${db.databaseName}`);
}

export async function closeDb() {
  await client.close();
}
