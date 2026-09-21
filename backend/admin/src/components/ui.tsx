import { useState, type ReactNode } from "react";

/** Дата в локальном формате + относительно «сейчас» в подсказке */
export function Time({ value }: { value: string | null | undefined }) {
  if (!value) return <span className="muted">—</span>;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return <span className="mono">{value}</span>;
  const diff = (Date.now() - d.getTime()) / 1000;
  const rel = diff < 60 ? "только что" : diff < 3600 ? `${Math.round(diff / 60)} мин назад` : diff < 86400 ? `${Math.round(diff / 3600)} ч назад` : `${Math.round(diff / 86400)} дн назад`;
  return <span title={rel} className="whitespace-nowrap tabular-nums">{d.toLocaleString("ru-RU", { dateStyle: "short", timeStyle: "short" })}</span>;
}

export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className="card min-w-0">
      <div className="truncate text-xs uppercase tracking-wide muted" title={label}>{label}</div>
      <div className="mt-1 text-2xl font-semibold tabular-nums">{value}</div>
      {hint && <div className="mt-1 text-xs muted">{hint}</div>}
    </div>
  );
}

/** Пустой JSON-просмотрщик: раскрывается по клику, длинные значения не ломают таблицу */
export function Json({ value, open = false }: { value: unknown; open?: boolean }) {
  const [expanded, setExpanded] = useState(open);
  const text = JSON.stringify(value, null, 2);
  if (!expanded) {
    const short = JSON.stringify(value);
    return (
      <button className="mono max-w-md truncate text-left text-zinc-600 hover:text-zinc-900 dark:text-zinc-400 dark:hover:text-zinc-100" onClick={() => setExpanded(true)} title="Развернуть">
        {short.length > 120 ? short.slice(0, 120) + "…" : short}
      </button>
    );
  }
  return (
    <pre className="mono max-h-96 max-w-3xl overflow-auto rounded-lg bg-zinc-100 p-2 dark:bg-zinc-800" onDoubleClick={() => setExpanded(false)}>{text}</pre>
  );
}

export function Flag({ code }: { code: string | null | undefined }) {
  if (!code || code.length !== 2) return <span className="muted">—</span>;
  const flag = [...code.toUpperCase()].map((ch) => String.fromCodePoint(0x1f1e6 + ch.charCodeAt(0) - 65)).join("");
  return <span title={code}>{flag} {code}</span>;
}

/** Кнопка с подтверждением и состоянием выполнения — для удалений */
export function DangerButton({ label, confirm, onClick, done }: { label: string; confirm: string; onClick: () => Promise<unknown>; done?: (r: unknown) => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <span className="inline-flex items-center gap-2">
      <button
        className="btn btn-danger"
        disabled={busy}
        onClick={async () => {
          if (!window.confirm(confirm)) return;
          setBusy(true);
          setError(null);
          try { done?.(await onClick()); } catch (e) { setError((e as Error).message); } finally { setBusy(false); }
        }}
      >
        {busy ? "…" : label}
      </button>
      {error && <span className="text-xs text-red-600">{error}</span>}
    </span>
  );
}

export function Empty({ children = "Пусто" }: { children?: ReactNode }) {
  return <div className="py-8 text-center muted">{children}</div>;
}

export function Loading() {
  return <div className="py-8 text-center muted">Загрузка…</div>;
}

export function ErrorBox({ error }: { error: unknown }) {
  return <div className="rounded-lg border border-red-300 bg-red-50 p-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200">{(error as Error)?.message ?? String(error)}</div>;
}

/** Таблица по описанию колонок; строки — любые объекты */
export type Column<T> = { key: string; title: string; render?: (row: T) => ReactNode; className?: string };
export function DataTable<T>({ rows, columns, rowKey }: { rows: T[]; columns: Column<T>[]; rowKey: (row: T, i: number) => string }) {
  if (rows.length === 0) return <Empty />;
  return (
    <div className="card overflow-auto p-0">
      <table className="data">
        <thead>
          <tr>{columns.map((c) => <th key={c.key}>{c.title}</th>)}</tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={rowKey(r, i)}>
              {columns.map((c) => <td key={c.key} className={c.className}>{c.render ? c.render(r) : cell((r as Record<string, unknown>)[c.key])}</td>)}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** Значение произвольного поля: даты — как время, объекты — JSON, остальное — текстом */
export function cell(v: unknown): ReactNode {
  if (v === null || v === undefined) return <span className="muted">—</span>;
  if (typeof v === "boolean") return v ? "да" : "нет";
  if (typeof v === "number") return <span className="tabular-nums">{v}</span>;
  if (typeof v === "string") {
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(v)) return <Time value={v} />;
    return v.length > 160 ? <span title={v}>{v.slice(0, 160)}…</span> : v;
  }
  return <Json value={v} />;
}

/** Таблица из произвольных документов: колонки — объединение ключей */
export function AutoTable({ rows, hide = [] }: { rows: Record<string, unknown>[]; hide?: string[] }) {
  const keys = Array.from(new Set(rows.flatMap((r) => Object.keys(r)))).filter((k) => !hide.includes(k));
  return <DataTable rows={rows} columns={keys.map((k) => ({ key: k, title: k }))} rowKey={(r, i) => String((r as { id?: string; _id?: string; clientId?: string }).id ?? (r as { _id?: string })._id ?? (r as { clientId?: string }).clientId ?? i)} />;
}
