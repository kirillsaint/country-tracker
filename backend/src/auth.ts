import { createHash, randomBytes } from "node:crypto";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { ObjectId } from "mongodb";
import type { Context, MiddlewareHandler } from "hono";
import { HTTPException } from "hono/http-exception";
import { config } from "./config.js";
import { sessions, users } from "./db.js";
import type { Provider, ProviderLink, User } from "./types.js";

// MARK: проверка identity token'ов провайдеров

const appleJWKS = createRemoteJWKSet(new URL(config.appleJwksUrl));
const googleJWKS = createRemoteJWKSet(new URL(config.googleJwksUrl));

export type Identity = {
  provider: Provider;
  sub: string;
  email: string | null;
  emailVerified: boolean;
  name: string | null;
};

export async function verifyIdentityToken(provider: Provider, token: string, name?: string | null): Promise<Identity> {
  try {
    if (provider === "apple") {
      const { payload } = await jwtVerify(token, appleJWKS, {
        issuer: "https://appleid.apple.com",
        audience: config.appleBundleId,
      });
      return {
        provider,
        sub: payload.sub!,
        email: typeof payload.email === "string" ? payload.email.toLowerCase() : null,
        // Apple присылает и boolean, и строку "true"
        emailVerified: payload.email_verified === true || payload.email_verified === "true",
        // Apple отдаёт имя только приложению и только при первом входе — приходит отдельным полем
        name: name ?? null,
      };
    }

    if (config.googleClientIds.length === 0) {
      throw new HTTPException(503, { message: "google sign-in is not configured on the server" });
    }
    const { payload } = await jwtVerify(token, googleJWKS, {
      issuer: ["https://accounts.google.com", "accounts.google.com"],
      audience: config.googleClientIds,
    });
    return {
      provider,
      sub: payload.sub!,
      email: typeof payload.email === "string" ? payload.email.toLowerCase() : null,
      emailVerified: payload.email_verified === true,
      name: typeof payload.name === "string" ? payload.name : (name ?? null),
    };
  } catch (e) {
    if (e instanceof HTTPException) throw e;
    throw new HTTPException(401, { message: `invalid ${provider} token: ${(e as Error).message}` });
  }
}

// MARK: сессии

function hashToken(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

export async function createSession(userId: ObjectId, device: string | null): Promise<string> {
  const token = randomBytes(32).toString("base64url");
  const now = new Date().toISOString();
  await sessions.insertOne({ tokenHash: hashToken(token), userId, device, createdAt: now, lastUsedAt: now });
  return token;
}

export async function revokeSession(token: string) {
  await sessions.deleteOne({ tokenHash: hashToken(token) });
}

export type AuthEnv = { Variables: { userId: ObjectId; sessionToken: string } };

// Проверяет Bearer-токен сессии и кладёт userId в контекст.
export const requireSession: MiddlewareHandler<AuthEnv> = async (c, next) => {
  const header = c.req.header("Authorization") ?? "";
  const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!token) throw new HTTPException(401, { message: "missing bearer token" });

  const session = await sessions.findOneAndUpdate(
    { tokenHash: hashToken(token) },
    { $set: { lastUsedAt: new Date().toISOString() } },
  );
  if (!session) throw new HTTPException(401, { message: "invalid or expired session" });

  c.set("userId", session.userId);
  c.set("sessionToken", token);
  await next();
};

// MARK: пользователи

function toLink(id: Identity): ProviderLink {
  return { sub: id.sub, email: id.email, linkedAt: new Date().toISOString() };
}

export function publicUser(u: User) {
  return {
    id: u._id.toHexString(),
    email: u.email,
    name: u.name,
    providers: { apple: !!u.apple, google: !!u.google },
    createdAt: u.createdAt,
  };
}

/**
 * Вход: находим пользователя по sub провайдера. Если такого нет, но есть пользователь с тем же
 * подтверждённым email — привязываем провайдера к нему (чтобы вход через Google после Apple не
 * плодил второй пустой аккаунт). Иначе создаём нового, если email в белом списке.
 */
export async function signIn(id: Identity): Promise<{ user: User; created: boolean; autoLinked: boolean }> {
  const bySub = await users.findOne({ [`${id.provider}.sub`]: id.sub });
  if (bySub) return { user: bySub, created: false, autoLinked: false };

  if (id.email && id.emailVerified) {
    const byEmail = await users.findOne({ email: id.email, [id.provider]: null });
    if (byEmail) {
      const updated = await users.findOneAndUpdate(
        { _id: byEmail._id },
        { $set: { [id.provider]: toLink(id), ...(byEmail.name ? {} : { name: id.name }) } },
        { returnDocument: "after" },
      );
      return { user: updated!, created: false, autoLinked: true };
    }
  }

  if (config.allowedEmails.size > 0 && !(id.email && config.allowedEmails.has(id.email))) {
    throw new HTTPException(403, { message: "this account is not allowed to register" });
  }

  const user: User = {
    _id: new ObjectId(),
    email: id.email,
    name: id.name,
    apple: id.provider === "apple" ? toLink(id) : null,
    google: id.provider === "google" ? toLink(id) : null,
    createdAt: new Date().toISOString(),
  };
  await users.insertOne(user);
  return { user, created: true, autoLinked: false };
}

// Привязать провайдера к текущему аккаунту. Если этот sub уже у другого пользователя — отказ.
export async function linkProvider(userId: ObjectId, id: Identity): Promise<User> {
  const owner = await users.findOne({ [`${id.provider}.sub`]: id.sub });
  if (owner && !owner._id.equals(userId)) {
    throw new HTTPException(409, { message: `this ${id.provider} account is already linked to another user` });
  }
  const updated = await users.findOneAndUpdate(
    { _id: userId },
    { $set: { [id.provider]: toLink(id) } },
    { returnDocument: "after" },
  );
  if (!updated) throw new HTTPException(404, { message: "user not found" });
  return updated;
}

// Отвязать можно только если остаётся хотя бы один способ войти.
export async function unlinkProvider(userId: ObjectId, provider: Provider): Promise<User> {
  const user = await users.findOne({ _id: userId });
  if (!user) throw new HTTPException(404, { message: "user not found" });
  const other: Provider = provider === "apple" ? "google" : "apple";
  if (!user[other]) throw new HTTPException(400, { message: `cannot unlink ${provider}: it is the only sign-in method` });
  const updated = await users.findOneAndUpdate({ _id: userId }, { $set: { [provider]: null } }, { returnDocument: "after" });
  return updated!;
}

export function userIdOf(c: Context<AuthEnv>): ObjectId {
  return c.get("userId");
}
