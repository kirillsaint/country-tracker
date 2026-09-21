import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useState } from "react";
import { Link, useNavigate, useParams, useSearchParams } from "react-router";
import { api, del, type AdminConfig, type Point, type UserDetail } from "../api";
import { GooglePointsMap } from "../components/GoogleMap";
import { PointsMap } from "../components/PointsMap";
import { AutoTable, DangerButton, DataTable, Empty, ErrorBox, Flag, Json, Loading, Stat, Time } from "../components/ui";

// вкладки: ключ = коллекция на сервере (кроме points, у которых своя ручка с картой)
const TABS: { key: string; label: string }[] = [
  { key: "summary", label: "Сводка" },
  { key: "points", label: "Точки и карта" },
  { key: "day_overrides", label: "Ручные дни" },
  { key: "documents", label: "Документы" },
  { key: "entries", label: "Основания" },
  { key: "rules", label: "Правила" },
  { key: "regimes", label: "Режимы" },
  { key: "place_ratings", label: "Оценки" },
  { key: "place_saves", label: "Сохранённые" },
  { key: "place_dismissals", label: "Не интересно" },
  { key: "discover_log", label: "Подборки" },
  { key: "jobs", label: "Задачи" },
  { key: "sessions", label: "Сессии" },
];

export default function User() {
  const { id = "" } = useParams();
  const [sp, setSp] = useSearchParams();
  const tab = sp.get("tab") ?? "summary";
  const qc = useQueryClient();
  const navigate = useNavigate();
  const q = useQuery({ queryKey: ["user", id], queryFn: () => api<UserDetail>(`/users/${id}`) });
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  const d = q.data;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <Link to="/users" className="muted">← Пользователи</Link>
        <h1 className="text-2xl font-semibold">{d.user.email ?? d.user.id}</h1>
        {d.user.name && <span className="muted">{d.user.name}</span>}
        <span className="mono muted">{d.user.id}</span>
        <div className="ml-auto flex gap-2">
          <DangerButton label="Разлогинить везде" confirm="Отозвать все сессии приложения у этого пользователя?" onClick={() => del(`/users/${id}/sessions`)} done={() => qc.invalidateQueries({ queryKey: ["user", id] })} />
          <DangerButton label="Удалить пользователя" confirm={`Удалить ${d.user.email ?? d.user.id} со ВСЕМИ данными (точки, документы, оценки…)? Это необратимо.`} onClick={() => del(`/users/${id}`)} done={() => { qc.invalidateQueries({ queryKey: ["users"] }); navigate("/users"); }} />
        </div>
      </div>
      <nav className="flex flex-wrap gap-1">
        {TABS.map((t) => (
          <button key={t.key} className={`tab ${tab === t.key ? "tab-active" : ""}`} onClick={() => setSp({ tab: t.key })}>
            {t.label}{t.key !== "summary" && d.counts[t.key] !== undefined && <span className="ml-1 opacity-60">{d.counts[t.key]}</span>}
          </button>
        ))}
      </nav>
      {tab === "summary" && <Summary d={d} />}
      {tab === "points" && <Points id={id} />}
      {tab !== "summary" && tab !== "points" && <Collection id={id} name={tab} />}
    </div>
  );
}

function Summary({ d }: { d: UserDetail }) {
  return (
    <div className="space-y-4">
      <div className="grid grid-cols-[repeat(auto-fill,minmax(150px,1fr))] gap-3">
        <Stat label="Точек" value={d.counts.points} />
        <Stat label="Стран" value={d.countries.filter((c) => c.countryCode).length} />
        <Stat label="Документов" value={d.counts.documents} />
        <Stat label="Оценок мест" value={d.counts.place_ratings} />
      </div>
      <div className="grid gap-4 lg:grid-cols-2">
        <section>
          <h2 className="mb-2 font-medium">Страны по точкам</h2>
          <DataTable
            rows={d.countries}
            rowKey={(c) => c.countryCode ?? "none"}
            columns={[
              { key: "countryCode", title: "Страна", render: (c) => <Flag code={c.countryCode} /> },
              { key: "n", title: "Точек", className: "tabular-nums" },
              { key: "cities", title: "Города", render: (c) => c.cities.slice(0, 8).join(", ") + (c.cities.length > 8 ? ` +${c.cities.length - 8}` : "") },
              { key: "first", title: "Первая", render: (c) => <Time value={c.first} /> },
              { key: "last", title: "Последняя", render: (c) => <Time value={c.last} /> },
            ]}
          />
        </section>
        <section className="space-y-4">
          <div className="card">
            <h2 className="mb-2 font-medium">Аккаунт</h2>
            <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
              <dt className="muted">Создан</dt><dd><Time value={d.user.createdAt} /></dd>
              <dt className="muted">Apple</dt><dd>{d.user.providers.apple ? <Json value={d.user.providers.apple} /> : "—"}</dd>
              <dt className="muted">Google</dt><dd>{d.user.providers.google ? <Json value={d.user.providers.google} /> : "—"}</dd>
              <dt className="muted">Сессий</dt><dd>{d.sessions.length}</dd>
            </dl>
          </div>
          <div className="card">
            <h2 className="mb-2 font-medium">Вкусы</h2>
            {d.taste.preferences ? <Json value={d.taste.preferences} open /> : <span className="muted">Тест не пройден</span>}
            {d.taste.profile && (
              <div className="mt-3 text-sm">
                <div className="muted">Профиль по {d.taste.profile.ratingsCount} оценкам, <Time value={d.taste.profile.updatedAt} /></div>
                <p className="mt-1 whitespace-pre-wrap">{d.taste.profile.text}</p>
              </div>
            )}
          </div>
        </section>
      </div>
    </div>
  );
}

function Points({ id }: { id: string }) {
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [view, setView] = useState<"map" | "table">("map");
  // ключ Google Maps приходит с сервера; без него карта на OpenStreetMap
  const cfg = useQuery({ queryKey: ["config"], queryFn: () => api<AdminConfig>("/config"), staleTime: Infinity });
  const q = useQuery({
    queryKey: ["points", id, from, to],
    queryFn: () => api<{ total: number; points: Point[] }>(`/users/${id}/points?${new URLSearchParams({ ...(from ? { from } : {}), ...(to ? { to } : {}) })}`),
  });
  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <label className="text-sm muted">С</label>
        <input type="date" className="input" value={from} onChange={(e) => setFrom(e.target.value)} />
        <label className="text-sm muted">по</label>
        <input type="date" className="input" value={to} onChange={(e) => setTo(e.target.value)} />
        <button className="btn" onClick={() => { setFrom(""); setTo(""); }}>Сбросить</button>
        <div className="ml-auto flex gap-1">
          <button className={`tab ${view === "map" ? "tab-active" : ""}`} onClick={() => setView("map")}>Карта</button>
          <button className={`tab ${view === "table" ? "tab-active" : ""}`} onClick={() => setView("table")}>Таблица</button>
        </div>
      </div>
      {q.isPending && <Loading />}
      {q.isError && <ErrorBox error={q.error} />}
      {q.data && (
        <>
          <div className="text-sm muted">Показано {q.data.points.length} из {q.data.total}{q.data.total > q.data.points.length ? " (сузьте даты, чтобы увидеть остальные)" : ""}</div>
          {q.data.points.length === 0 ? <Empty /> : view === "map" ? (cfg.data?.googleMapsKey ? <GooglePointsMap points={q.data.points} apiKey={cfg.data.googleMapsKey} /> : <PointsMap points={q.data.points} />) : (
            <DataTable
              rows={q.data.points}
              rowKey={(p) => p.clientId}
              columns={[
                { key: "recordedAt", title: "Когда (UTC)", render: (p) => <Time value={p.recordedAt} /> },
                { key: "localDate", title: "Местная дата" },
                { key: "countryCode", title: "Страна", render: (p) => <Flag code={p.countryCode} /> },
                { key: "city", title: "Город" },
                { key: "region", title: "Регион" },
                { key: "source", title: "Источник" },
                { key: "coords", title: "Координаты", render: (p) => <span className="mono">{p.lat.toFixed(5)}, {p.lon.toFixed(5)} ±{p.accuracy ?? "?"}</span> },
                { key: "arrivalAt", title: "Приезд", render: (p) => <Time value={p.arrivalAt} /> },
                { key: "departureAt", title: "Отъезд", render: (p) => <Time value={p.departureAt} /> },
              ]}
            />
          )}
        </>
      )}
    </div>
  );
}

function Collection({ id, name }: { id: string; name: string }) {
  const q = useQuery({ queryKey: ["userdata", id, name], queryFn: () => api<{ rows: Record<string, unknown>[] }>(`/users/${id}/data/${name}`) });
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  return <AutoTable rows={q.data.rows} />;
}
