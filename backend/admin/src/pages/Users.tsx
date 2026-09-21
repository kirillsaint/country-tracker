import { useQuery } from "@tanstack/react-query";
import { useState } from "react";
import { Link } from "react-router";
import { api, type UserRow } from "../api";
import { DataTable, ErrorBox, Loading, Time } from "../components/ui";

export default function Users() {
  const q = useQuery({ queryKey: ["users"], queryFn: () => api<{ users: UserRow[] }>("/users") });
  const [filter, setFilter] = useState("");
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  const rows = q.data.users.filter((u) => !filter || (u.email ?? "").includes(filter) || (u.name ?? "").toLowerCase().includes(filter.toLowerCase()));
  return (
    <div className="space-y-4">
      <div className="flex items-center gap-3">
        <h1 className="text-2xl font-semibold">Пользователи</h1>
        <span className="muted">{q.data.users.length}</span>
        <input className="input ml-auto" placeholder="Поиск по email или имени" value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>
      <DataTable
        rows={rows}
        rowKey={(u) => u.id}
        columns={[
          { key: "email", title: "Email", render: (u) => <Link className="underline" to={`/users/${u.id}`}>{u.email ?? <span className="mono">{u.id}</span>}</Link> },
          { key: "name", title: "Имя" },
          { key: "providers", title: "Вход", render: (u) => [u.apple && "Apple", u.google && "Google"].filter(Boolean).join(", ") || "—" },
          { key: "points", title: "Точек", className: "tabular-nums" },
          { key: "countries", title: "Стран", className: "tabular-nums" },
          { key: "documents", title: "Документов", className: "tabular-nums" },
          { key: "ratings", title: "Оценок", className: "tabular-nums" },
          { key: "sessions", title: "Сессий", className: "tabular-nums" },
          { key: "lastPointAt", title: "Последняя точка", render: (u) => <Time value={u.lastPointAt} /> },
          { key: "lastSeenAt", title: "Был в сети", render: (u) => <Time value={u.lastSeenAt} /> },
          { key: "createdAt", title: "Создан", render: (u) => <Time value={u.createdAt} /> },
        ]}
      />
    </div>
  );
}
