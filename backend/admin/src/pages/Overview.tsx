import { useQuery } from "@tanstack/react-query";
import { Link } from "react-router";
import { api, type Overview as OverviewT } from "../api";
import { DataTable, ErrorBox, Flag, Loading, Stat, Time } from "../components/ui";

const LABELS: Record<string, string> = {
  users: "Пользователи", sessions: "Сессии", points: "Гео-точки", day_overrides: "Ручные дни", rules: "Правила", documents: "Документы", entries: "Основания въезда",
  regimes: "Режимы въезда", regime_checks: "Проверки режимов", place_ratings: "Оценки мест", place_saves: "Сохранённые", place_dismissals: "Не интересно",
  taste_preferences: "Тест вкусов", taste_profiles: "Профили вкусов", discover_log: "Журнал подборок", discover_ai_cache: "Кэш подборок", place_cache: "Кэш Google",
  jobs: "Задачи", cities: "Города", cities_meta: "Мета городов", admin_sessions: "Сессии админки",
};

export default function Overview() {
  const q = useQuery({ queryKey: ["overview"], queryFn: () => api<OverviewT>("/overview"), refetchInterval: 30_000 });
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  const d = q.data;
  const max = Math.max(1, ...d.pointsByDay.map((x) => x.n));
  return (
    <div className="space-y-6">
      <h1 className="text-2xl font-semibold">Обзор</h1>
      <div className="grid grid-cols-[repeat(auto-fill,minmax(150px,1fr))] gap-3">
        {Object.entries(d.counts).map(([k, v]) => (
          <Link key={k} to={`/raw/${k}`}><Stat label={LABELS[k] ?? k} value={v.toLocaleString("ru-RU")} /></Link>
        ))}
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <div className="card">
          <div className="mb-2 font-medium">Точки за 30 дней</div>
          <div className="flex h-32 items-end gap-0.5">
            {d.pointsByDay.map((x) => (
              <div key={x.day} className="flex-1 rounded-t bg-blue-500/80" style={{ height: `${(x.n / max) * 100}%` }} title={`${x.day}: ${x.n}`} />
            ))}
          </div>
          <div className="mt-2 flex flex-wrap gap-3 text-xs muted">
            {Object.entries(d.sources).map(([s, n]) => <span key={s}>{s}: {n}</span>)}
          </div>
        </div>
        <div className="card">
          <div className="mb-2 font-medium">Сервер</div>
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            <dt className="muted">Нейросеть</dt><dd>{d.features.ai ? `да · ${d.features.models.main} / ${d.features.models.fast}` : "выключена"}</dd>
            <dt className="muted">Google Places</dt><dd>{d.features.places ? "да" : "выключен"}</dd>
            <dt className="muted">Self Store</dt><dd>{d.features.selfStore ? "настроен" : "не настроен"}</dd>
            <dt className="muted">Задач в работе</dt><dd>{d.runningJobs}</dd>
          </dl>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-2">
        <section>
          <h2 className="mb-2 font-medium">Новые пользователи</h2>
          <DataTable
            rows={d.latestUsers}
            rowKey={(u) => u.id}
            columns={[
              { key: "email", title: "Email", render: (u) => <Link className="underline" to={`/users/${u.id}`}>{u.email ?? u.id}</Link> },
              { key: "name", title: "Имя" },
              { key: "createdAt", title: "Создан", render: (u) => <Time value={u.createdAt} /> },
            ]}
          />
        </section>
        <section>
          <h2 className="mb-2 font-medium">Последние точки</h2>
          <DataTable
            rows={d.latestPoints}
            rowKey={(p) => p.clientId}
            columns={[
              { key: "userEmail", title: "Кто", render: (p) => <Link className="underline" to={`/users/${p.userId}`}>{p.userEmail ?? p.userId}</Link> },
              { key: "countryCode", title: "Страна", render: (p) => <Flag code={p.countryCode} /> },
              { key: "city", title: "Город" },
              { key: "source", title: "Источник" },
              { key: "recordedAt", title: "Когда", render: (p) => <Time value={p.recordedAt} /> },
            ]}
          />
        </section>
      </div>
    </div>
  );
}
