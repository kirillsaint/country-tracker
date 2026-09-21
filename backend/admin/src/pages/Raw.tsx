import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link, useParams } from "react-router";
import { api, type CollectionInfo } from "../api";
import { AutoTable, DataTable, ErrorBox, Loading } from "../components/ui";

const fmtBytes = (n: number | null) => n == null ? "—" : n < 1024 ? `${n} Б` : n < 1024 ** 2 ? `${(n / 1024).toFixed(1)} КБ` : `${(n / 1024 ** 2).toFixed(1)} МБ`;

/** Любая коллекция как есть: список с размерами, постранично документы, фильтр — JSON запроса Mongo */
export default function Raw() {
  const { name } = useParams();
  const list = useQuery({ queryKey: ["collections"], queryFn: () => api<{ collections: CollectionInfo[] }>("/collections") });
  if (!name) {
    if (list.isPending) return <Loading />;
    if (list.isError) return <ErrorBox error={list.error} />;
    return (
      <div className="space-y-4">
        <h1 className="text-2xl font-semibold">Данные</h1>
        <DataTable
          rows={list.data.collections}
          rowKey={(c) => c.name}
          columns={[
            { key: "name", title: "Коллекция", render: (c) => <Link className="underline" to={`/raw/${c.name}`}>{c.name}</Link> },
            { key: "count", title: "Документов", render: (c) => c.count.toLocaleString("ru-RU"), className: "tabular-nums" },
            { key: "size", title: "Данные", render: (c) => fmtBytes(c.size) },
            { key: "storageSize", title: "На диске", render: (c) => fmtBytes(c.storageSize) },
            { key: "indexSize", title: "Индексы", render: (c) => fmtBytes(c.indexSize) },
            { key: "perUser", title: "По пользователю", render: (c) => c.perUser ? "да" : "" },
          ]}
        />
      </div>
    );
  }
  return <Browser name={name} />;
}

function Browser({ name }: { name: string }) {
  const [page, setPage] = useState(0);
  const [filter, setFilter] = useState("");
  const [applied, setApplied] = useState("");
  const limit = 50;
  const q = useQuery({
    queryKey: ["collection", name, page, applied],
    queryFn: () => api<{ total: number; rows: Record<string, unknown>[] }>(`/collections/${name}?${new URLSearchParams({ skip: String(page * limit), limit: String(limit), ...(applied ? { filter: applied } : {}) })}`),
  });
  const pages = q.data ? Math.max(1, Math.ceil(q.data.total / limit)) : 1;
  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center gap-3">
        <Link to="/raw" className="muted">← Данные</Link>
        <h1 className="text-2xl font-semibold">{name}</h1>
        {q.data && <span className="muted">{q.data.total.toLocaleString("ru-RU")} документов</span>}
      </div>
      <form className="flex gap-2" onSubmit={(e) => { e.preventDefault(); setPage(0); setApplied(filter.trim()); }}>
        <input className="input mono flex-1" placeholder='Фильтр Mongo, например {"countryCode":"AE"}' value={filter} onChange={(e) => setFilter(e.target.value)} />
        <button className="btn" type="submit">Применить</button>
      </form>
      {q.isPending && <Loading />}
      {q.isError && <ErrorBox error={q.error} />}
      {q.data && <AutoTable rows={q.data.rows} />}
      <div className="flex items-center gap-2 text-sm">
        <button className="btn" disabled={page === 0} onClick={() => setPage(page - 1)}>← Назад</button>
        <span className="muted">{page + 1} / {pages}</span>
        <button className="btn" disabled={page + 1 >= pages} onClick={() => setPage(page + 1)}>Вперёд →</button>
      </div>
    </div>
  );
}
