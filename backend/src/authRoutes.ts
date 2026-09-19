import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";
import { z } from "zod";
import {
  type AuthEnv,
  createSession,
  linkProvider,
  publicUser,
  requireSession,
  revokeSession,
  signIn,
  unlinkProvider,
  verifyIdentityToken,
} from "./auth.js";
import { users } from "./db.js";
import { HTTPException } from "hono/http-exception";

export const auth = new Hono<AuthEnv>();

const providerParam = z.object({ provider: z.enum(["apple", "google"]) });
const signInBody = z.object({
  identityToken: z.string().min(20),
  // Apple отдаёт имя только при первом входе, и только приложению
  fullName: z.string().max(200).nullable().optional(),
  device: z.string().max(100).nullable().optional(),
});

// POST /auth/signin/apple | /auth/signin/google
auth.post("/signin/:provider", zValidator("param", providerParam), zValidator("json", signInBody), async (c) => {
  const { provider } = c.req.valid("param");
  const body = c.req.valid("json");
  const identity = await verifyIdentityToken(provider, body.identityToken, body.fullName);
  const { user, created, autoLinked } = await signIn(identity);
  const token = await createSession(user._id, body.device ?? null);
  return c.json({ token, user: publicUser(user), created, autoLinked }, created ? 201 : 200);
});

auth.use("/me", requireSession);
auth.use("/logout", requireSession);
auth.use("/link/*", requireSession);
auth.use("/unlink/*", requireSession);

auth.get("/me", async (c) => {
  const user = await users.findOne({ _id: c.get("userId") });
  if (!user) throw new HTTPException(401, { message: "user no longer exists" });
  return c.json({ user: publicUser(user) });
});

auth.post("/logout", async (c) => {
  await revokeSession(c.get("sessionToken"));
  return c.json({ ok: true });
});

// Привязать второго провайдера к текущему аккаунту
auth.post("/link/:provider", zValidator("param", providerParam), zValidator("json", signInBody), async (c) => {
  const { provider } = c.req.valid("param");
  const body = c.req.valid("json");
  const identity = await verifyIdentityToken(provider, body.identityToken, body.fullName);
  const user = await linkProvider(c.get("userId"), identity);
  return c.json({ user: publicUser(user) });
});

auth.post("/unlink/:provider", zValidator("param", providerParam), async (c) => {
  const { provider } = c.req.valid("param");
  const user = await unlinkProvider(c.get("userId"), provider);
  return c.json({ user: publicUser(user) });
});
