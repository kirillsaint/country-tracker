import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router";
import { api, del } from "../api";
import { DangerButton, DataTable, ErrorBox, Json, Loading, Time } from "../components/ui";

type Job = { id: string; userId: string; userEmail: string | null; kind: string; status: string; result: unknown; error: string | null; createdAt: string; updatedAt: string };

/** Фоновые задачи (подборки, маршруты) и кнопки чистки кэшей */
export default function Jobs() {
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ["jobs"], queryFn: () => api<{ rows: Job[] }>("/jobs"), refetchInterval: 10_000 });
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <h1 className="text-2xl font-semibold">Задачи</h1>
        <div className="ml-auto flex gap-2">
          <DangerButton label="Удалить завершённые" confirm="Удалить все завершённые и проваленные задачи?" onClick={() => del("/jobs")} done={() => qc.invalidateQueries({ queryKey: ["jobs"] })} />
          <DangerButton label="Очистить кэши Google и подборок" confirm="Стереть кэш ответов Google Places и готовых подборок? Следующие запросы пойдут в Google и нейросеть заново." onClick={() => del("/cache")} done={() => qc.invalidateQueries({ queryKey: ["overview"] })} />
        </div>
      </div>
      <DataTable
        rows={q.data.rows}
        rowKey={(j) => j.id}
        columns={[
          { key: "createdAt", title: "Создана", render: (j) => <Time value={j.createdAt} /> },
          { key: "kind", title: "Тип" },
          { key: "status", title: "Статус", render: (j) => <span className={j.status === "failed" ? "text-red-600" : j.status === "done" ? "text-green-600" : "text-amber-600"}>{j.status}</span> },
          { key: "userEmail", title: "Кто", render: (j) => <Link className="underline" to={`/users/${j.userId}`}>{j.userEmail ?? j.userId}</Link> },
          { key: "duration", title: "Длилась", render: (j) => `${Math.round((new Date(j.updatedAt).getTime() - new Date(j.createdAt).getTime()) / 1000)} с` },
          { key: "error", title: "Ошибка", render: (j) => j.error ? <span className="text-red-600">{j.error}</span> : <span className="muted">—</span> },
          { key: "result", title: "Результат", render: (j) => j.result ? <Json value={j.result} /> : <span className="muted">—</span> },
        ]}
      />
    </div>
  );
}
