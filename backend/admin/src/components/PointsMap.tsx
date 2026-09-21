import { useEffect, useMemo } from "react";
import { CircleMarker, MapContainer, Polyline, Popup, TileLayer, useMap } from "react-leaflet";
import type { Point } from "../api";

const COLORS: Record<string, string> = { visit: "#2563eb", significant: "#16a34a", hourly: "#f59e0b", foreground: "#9333ea", manual: "#dc2626" };

function FitBounds({ pts }: { pts: Point[] }) {
  const map = useMap();
  useEffect(() => {
    if (pts.length === 0) return;
    const lats = pts.map((p) => p.lat);
    const lons = pts.map((p) => p.lon);
    map.fitBounds([[Math.min(...lats), Math.min(...lons)], [Math.max(...lats), Math.max(...lons)]], { padding: [24, 24], maxZoom: 14 });
  }, [map, pts]);
  return null;
}

/** Точки пользователя на OpenStreetMap: цвет — источник, линия — порядок по времени */
export function PointsMap({ points }: { points: Point[] }) {
  // с сервера приходят новые первыми — для линии нужен хронологический порядок
  const ordered = useMemo(() => points.slice().sort((a, b) => a.recordedAt.localeCompare(b.recordedAt)), [points]);
  return (
    <div className="card overflow-hidden p-0">
      <MapContainer center={[30, 30]} zoom={2} className="h-[520px] w-full" scrollWheelZoom>
        <TileLayer attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>' url="https://tile.openstreetmap.org/{z}/{x}/{y}.png" />
        <FitBounds pts={ordered} />
        {ordered.length > 1 && <Polyline positions={ordered.map((p) => [p.lat, p.lon])} pathOptions={{ color: "#64748b", weight: 1.5, opacity: 0.6 }} />}
        {ordered.map((p) => (
          <CircleMarker key={p.clientId} center={[p.lat, p.lon]} radius={5} pathOptions={{ color: COLORS[p.source] ?? "#334155", fillOpacity: 0.8, weight: 1 }}>
            <Popup>
              <div className="text-xs">
                <div><b>{p.city ?? "—"}</b> {p.countryCode ?? ""}</div>
                <div>{new Date(p.recordedAt).toLocaleString("ru-RU")}</div>
                <div>{p.source} · ±{p.accuracy ?? "?"} м</div>
                <div className="font-mono">{p.lat.toFixed(5)}, {p.lon.toFixed(5)}</div>
              </div>
            </Popup>
          </CircleMarker>
        ))}
      </MapContainer>
      <div className="flex flex-wrap gap-3 px-3 py-2 text-xs muted">
        {Object.entries(COLORS).map(([k, c]) => <span key={k}><span className="inline-block h-2.5 w-2.5 rounded-full align-middle" style={{ background: c }} /> {k}</span>)}
      </div>
    </div>
  );
}
