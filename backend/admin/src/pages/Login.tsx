import { useQuery } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";
import { api, post, type AdminConfig } from "../api";

declare global {
  interface Window { google?: { accounts: { id: { initialize: (o: unknown) => void; renderButton: (el: HTMLElement, o: unknown) => void } } } }
}

/** Вход только через Google Identity Services: кнопка Google отдаёт id_token, сервер проверяет его и email */
export default function Login({ onSignedIn }: { onSignedIn: () => void }) {
  const cfg = useQuery({ queryKey: ["config"], queryFn: () => api<AdminConfig>("/config") });
  const slot = useRef<HTMLDivElement>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!cfg.data?.enabled || !slot.current) return;
    const render = () => {
      window.google!.accounts.id.initialize({
        client_id: cfg.data.googleClientId,
        callback: async (r: { credential: string }) => {
          try {
            await post("/login", { credential: r.credential });
            onSignedIn();
          } catch (e) {
            setError((e as Error).message);
          }
        },
      });
      window.google!.accounts.id.renderButton(slot.current!, { theme: matchMedia("(prefers-color-scheme: dark)").matches ? "filled_black" : "outline", size: "large", width: 280, text: "signin_with" });
    };
    if (window.google) render();
    else {
      const s = document.createElement("script");
      s.src = "https://accounts.google.com/gsi/client";
      s.async = true;
      s.onload = render;
      document.head.appendChild(s);
    }
  }, [cfg.data, onSignedIn]);

  return (
    <div className="flex min-h-screen items-center justify-center p-6">
      <div className="card w-full max-w-sm text-center">
        <div className="text-4xl">🌍</div>
        <h1 className="mt-2 text-xl font-semibold">Stamps · админка</h1>
        <p className="mt-1 text-sm muted">Вход только для администраторов через Google.</p>
        <div className="mt-6 flex justify-center">
          {cfg.isPending && <span className="muted">…</span>}
          {cfg.data && !cfg.data.enabled && <span className="text-sm text-red-600">Админка не настроена: задайте ADMIN_EMAILS и ADMIN_GOOGLE_CLIENT_ID на сервере.</span>}
          <div ref={slot} />
        </div>
        {error && <p className="mt-4 text-sm text-red-600">{error}</p>}
      </div>
    </div>
  );
}
