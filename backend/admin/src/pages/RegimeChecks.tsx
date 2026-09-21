import { useQuery } from "@tanstack/react-query";
import { api } from "../api";
import { DataTable, ErrorBox, Flag, Json, Loading, Time } from "../components/ui";

type Check = { id: string; passportCode: string; countryCode: string; lang: string; status: string; model: string; requestedAt: string; finishedAt: string | null; draft: unknown; error: string | null; raw: string | null };

/** Что нейросеть отвечала про условия въезда: по паре паспорт → страна, с черновиком и сырым ответом */
export default function RegimeChecks() {
  const q = useQuery({ queryKey: ["regime-checks"], queryFn: () => api<{ rows: Check[] }>("/regime-checks") });
  if (q.isPending) return <Loading />;
  if (q.isError) return <ErrorBox error={q.error} />;
  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-semibold">Проверки режимов въезда</h1>
      <DataTable
        rows={q.data.rows}
        rowKey={(r) => r.id}
        columns={[
          { key: "pair", title: "Паспорт → страна", render: (r) => <><Flag code={r.passportCode} /> → <Flag code={r.countryCode} /></> },
          { key: "status", title: "Статус", render: (r) => <span className={r.status === "failed" ? "text-red-600" : r.status === "done" ? "text-green-600" : ""}>{r.status}</span> },
          { key: "model", title: "Модель" },
          { key: "requestedAt", title: "Запрошено", render: (r) => <Time value={r.requestedAt} /> },
          { key: "finishedAt", title: "Готово", render: (r) => <Time value={r.finishedAt} /> },
          { key: "draft", title: "Черновик", render: (r) => r.draft ? <Json value={r.draft} /> : <span className="muted">—</span> },
          { key: "error", title: "Ошибка", render: (r) => r.error ? <span className="text-red-600">{r.error}</span> : <span className="muted">—</span> },
          { key: "raw", title: "Сырой ответ", render: (r) => r.raw ? <Json value={r.raw} /> : <span className="muted">—</span> },
        ]}
      />
    </div>
  );
}
