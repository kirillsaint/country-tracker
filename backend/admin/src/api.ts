// Тонкая обёртка над fetch: cookie-сессия, JSON, единый формат ошибок
export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch(`/admin/api${path}`, { credentials: "same-origin", headers: { "content-type": "application/json", ...(init.headers ?? {}) }, ...init });
  const text = await res.text();
  let body: unknown = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = text; }
  if (!res.ok) throw new ApiError(res.status, (body as { error?: string })?.error ?? res.statusText);
  return body as T;
}

export const del = <T>(path: string) => api<T>(path, { method: "DELETE" });
export const post = <T>(path: string, body?: unknown) => api<T>(path, { method: "POST", body: body ? JSON.stringify(body) : undefined });

// MARK: типы ответов

export type AdminUser = { id: string; email: string | null; name: string | null; apple: boolean; google: boolean; createdAt: string };
export type UserRow = AdminUser & { points: number; lastPointAt: string | null; countries: number; documents: number; sessions: number; lastSeenAt: string | null; ratings: number };
export type Overview = {
  counts: Record<string, number>;
  pointsByDay: { day: string; n: number }[];
  sources: Record<string, number>;
  latestUsers: AdminUser[];
  latestPoints: Point[];
  runningJobs: number;
  features: { ai: boolean; places: boolean; selfStore: boolean; models: { main: string; fast: string } };
};
export type Point = {
  clientId: string; lat: number; lon: number; accuracy: number | null; recordedAt: string; tzOffsetMin: number; localDate: string;
  source: string; arrivalAt: string | null; departureAt: string | null; countryCode: string | null; countryName: string | null; city: string | null; region: string | null;
  userId?: string; userEmail?: string | null;
};
export type UserDetail = {
  user: AdminUser & { providers: { apple: unknown; google: unknown }; rulesSeeded: boolean };
  counts: Record<string, number>;
  countries: { countryCode: string | null; n: number; first: string; last: string; cities: string[] }[];
  sessions: { device: string | null; createdAt: string; lastUsedAt: string }[];
  taste: { preferences: Record<string, unknown> | null; profile: { text: string; ratingsCount: number; lang: string; updatedAt: string } | null };
};
export type CollectionInfo = { name: string; count: number; size: number | null; storageSize: number | null; indexSize: number | null; perUser: boolean };
export type AdminConfig = { enabled: boolean; googleClientId: string; googleMapsKey: string };

