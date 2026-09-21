import { APIProvider, InfoWindow, Map, Marker, useApiIsLoaded, useMap } from "@vis.gl/react-google-maps";
import { useEffect, useMemo, useState } from "react";
import type { Point } from "../api";
import { SOURCE_COLORS } from "./PointsMap";

/** Точки на Google Maps: тот же цвет по источнику и линия по времени, что и в версии на OpenStreetMap */
export function GooglePointsMap({ points, apiKey }: { points: Point[]; apiKey: string }) {
  const ordered = useMemo(() => points.slice().sort((a, b) => a.recordedAt.localeCompare(b.recordedAt)), [points]);
  return (
    <div className="card overflow-hidden p-0">
      <APIProvider apiKey={apiKey}>
        <Map className="h-[520px] w-full" defaultCenter={{ lat: 30, lng: 30 }} defaultZoom={2} gestureHandling="greedy" colorScheme={matchMedia("(prefers-color-scheme: dark)").matches ? "DARK" : "LIGHT"}>
          <Layers pts={ordered} />
        </Map>
      </APIProvider>
      <div className="flex flex-wrap gap-3 px-3 py-2 text-xs muted">
        {Object.entries(SOURCE_COLORS).map(([k, c]) => <span key={k}><span className="inline-block h-2.5 w-2.5 rounded-full align-middle" style={{ background: c }} /> {k}</span>)}
      </div>
    </div>
  );
}

/** Маркеры, линия и подпись. Рисуются только когда скрипт карт загружен: до этого объекта google ещё нет */
function Layers({ pts }: { pts: Point[] }) {
  const loaded = useApiIsLoaded();
  const [selected, setSelected] = useState<Point | null>(null);
  if (!loaded) return null;
  return (
    <>
      <Fit pts={pts} />
      <Track pts={pts} />
      {pts.map((p) => (
        <Marker
          key={p.clientId}
          position={{ lat: p.lat, lng: p.lon }}
          title={`${p.city ?? ""} ${new Date(p.recordedAt).toLocaleString("ru-RU")}`}
          icon={{ path: google.maps.SymbolPath.CIRCLE, scale: 6, fillColor: SOURCE_COLORS[p.source] ?? "#334155", fillOpacity: 0.85, strokeColor: "#ffffff", strokeWeight: 1 }}
          onClick={() => setSelected(p)}
        />
      ))}
      {selected && (
        <InfoWindow position={{ lat: selected.lat, lng: selected.lon }} onCloseClick={() => setSelected(null)} pixelOffset={[0, -8]}>
          <div className="text-xs text-zinc-900">
            <div><b>{selected.city ?? "—"}</b> {selected.countryCode ?? ""}</div>
            <div>{new Date(selected.recordedAt).toLocaleString("ru-RU")}</div>
            <div>{selected.source} · ±{selected.accuracy ?? "?"} м</div>
            <div className="font-mono">{selected.lat.toFixed(5)}, {selected.lon.toFixed(5)}</div>
          </div>
        </InfoWindow>
      )}
    </>
  );
}

function Fit({ pts }: { pts: Point[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || pts.length === 0) return;
    const b = new google.maps.LatLngBounds();
    for (const p of pts) b.extend({ lat: p.lat, lng: p.lon });
    map.fitBounds(b, 32);
    // одна точка — не приближать до дома
    const l = google.maps.event.addListenerOnce(map, "idle", () => { if ((map.getZoom() ?? 0) > 14) map.setZoom(14); });
    return () => google.maps.event.removeListener(l);
  }, [map, pts]);
  return null;
}

/** Линия по времени: у обёртки нет компонента Polyline, рисуем напрямую */
function Track({ pts }: { pts: Point[] }) {
  const map = useMap();
  useEffect(() => {
    if (!map || pts.length < 2) return;
    const line = new google.maps.Polyline({ map, path: pts.map((p) => ({ lat: p.lat, lng: p.lon })), strokeColor: "#64748b", strokeOpacity: 0.6, strokeWeight: 1.5 });
    return () => line.setMap(null);
  }, [map, pts]);
  return null;
}
