import { useQuery, useQueryClient } from "@tanstack/react-query";
import { NavLink, Navigate, Route, Routes, useNavigate } from "react-router";
import { ApiError, api, post } from "./api";
import { Loading } from "./components/ui";
import Jobs from "./pages/Jobs";
import Login from "./pages/Login";
import Overview from "./pages/Overview";
import Raw from "./pages/Raw";
import RegimeChecks from "./pages/RegimeChecks";
import User from "./pages/User";
import Users from "./pages/Users";

type Me = { email: string; name: string | null };

export default function App() {
  const me = useQuery({ queryKey: ["me"], queryFn: () => api<Me>("/me"), retry: false });
  if (me.isPending) return <Loading />;
  if (me.isError && (me.error as ApiError).status === 401) return <Login onSignedIn={() => me.refetch()} />;
  if (me.isError) return <div className="p-6 text-red-600">{me.error.message}</div>;
  return <Shell me={me.data} />;
}

const NAV = [
  { to: "/", label: "Обзор", end: true },
  { to: "/users", label: "Пользователи" },
  { to: "/regime-checks", label: "Проверки режимов" },
  { to: "/jobs", label: "Задачи" },
  { to: "/raw", label: "Данные" },
];

function Shell({ me }: { me: Me }) {
  const qc = useQueryClient();
  const navigate = useNavigate();
  return (
    <div className="flex min-h-screen flex-col md:flex-row">
      {/* на узком экране меню становится горизонтальной полосой сверху */}
      <aside className="flex shrink-0 items-center gap-2 overflow-x-auto border-b border-zinc-200 bg-white p-3 md:w-56 md:flex-col md:items-stretch md:border-r md:border-b-0 dark:border-zinc-800 dark:bg-zinc-900">
        <div className="px-2 text-lg font-semibold md:mb-4">🌍 Stamps</div>
        <nav className="flex gap-0.5 md:flex-col">
          {NAV.map((n) => (
            <NavLink key={n.to} to={n.to} end={n.end} className={({ isActive }) => `tab whitespace-nowrap ${isActive ? "tab-active" : ""}`}>{n.label}</NavLink>
          ))}
        </nav>
        <div className="ml-auto px-2 text-xs muted md:mt-auto md:ml-0">
          <div className="hidden truncate md:block" title={me.email}>{me.name ?? me.email}</div>
          <button className="underline md:mt-1" onClick={async () => { await post("/logout"); qc.clear(); navigate("/"); }}>Выйти</button>
        </div>
      </aside>
      <main className="min-w-0 flex-1 p-4 md:p-6">
        <Routes>
          <Route path="/" element={<Overview />} />
          <Route path="/users" element={<Users />} />
          <Route path="/users/:id" element={<User />} />
          <Route path="/regime-checks" element={<RegimeChecks />} />
          <Route path="/jobs" element={<Jobs />} />
          <Route path="/raw" element={<Raw />} />
          <Route path="/raw/:name" element={<Raw />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </main>
    </div>
  );
}
