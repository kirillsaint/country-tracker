import { randomUUID } from "node:crypto";
import type { ObjectId } from "mongodb";
import { jobs } from "./db.js";

// Долгие запросы (нейросеть отвечает 15–60 с, а таймаут клиента 20 с) выполняются как задачи:
// POST сразу возвращает id, приложение опрашивает статус раз в пару секунд. Результат живёт час.

export type Job = {
  id: string;
  userId: ObjectId;
  kind: string;
  status: "queued" | "running" | "done" | "failed";
  result: unknown | null;
  error: string | null;
  createdAt: string;
  updatedAt: string;
  // TTL-индекс чистит старые задачи
  expiresAt: Date;
};

export async function startJob(userId: ObjectId, kind: string, run: () => Promise<unknown>): Promise<string> {
  const id = randomUUID();
  const now = new Date().toISOString();
  await jobs.insertOne({ id, userId, kind, status: "queued", result: null, error: null, createdAt: now, updatedAt: now, expiresAt: new Date(Date.now() + 3_600_000) });
  void (async () => {
    await jobs.updateOne({ id }, { $set: { status: "running", updatedAt: new Date().toISOString() } });
    try {
      const result = await run();
      await jobs.updateOne({ id }, { $set: { status: "done", result, updatedAt: new Date().toISOString() } });
    } catch (e) {
      await jobs.updateOne({ id }, { $set: { status: "failed", error: e instanceof Error ? e.message : String(e), updatedAt: new Date().toISOString() } });
    }
  })();
  return id;
}

export async function getJob(userId: ObjectId, id: string): Promise<Job | null> {
  return jobs.findOne({ userId, id });
}

/** При старте сервера задачи, оборванные перезапуском, помечаются проваленными — клиент переспросит */
export async function failOrphans(): Promise<void> {
  await jobs.updateMany({ status: { $in: ["queued", "running"] } }, { $set: { status: "failed", error: "server restarted", updatedAt: new Date().toISOString() } });
}
