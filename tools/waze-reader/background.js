// Cada ciclo: pide al receptor que barra TomTom/Mapbox, luego lee Waze ruta
// por ruta en una pestaña de fondo y manda cada lectura al receptor.
const RECEIVER = "http://127.0.0.1:8791";
const PERIOD_MIN = 120;
const WAIT_MS = 7000;

chrome.runtime.onInstalled.addListener(() => chrome.alarms.create("cycle", { periodInMinutes: PERIOD_MIN }));
chrome.runtime.onStartup.addListener(() => chrome.alarms.create("cycle", { periodInMinutes: PERIOD_MIN }));
chrome.alarms.onAlarm.addListener(a => a.name === "cycle" && runCycle());
chrome.action.onClicked.addListener(() => runCycle());

let running = false;

async function runCycle() {
  if (running) return;
  running = true;
  let tab;
  try {
    const routes = await (await fetch(`${RECEIVER}/routes`)).json();
    await fetch(`${RECEIVER}/sweep`, { method: "POST" });
    const at = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    tab = await chrome.tabs.create({ url: "about:blank", active: false, pinned: true });
    for (const r of routes) {
      const url = `https://www.waze.com/es-419/live-map/directions?from=ll.${r.from}&to=ll.${r.to}`;
      await chrome.tabs.update(tab.id, { url });
      await sleep(WAIT_MS);
      const [{ result }] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: readFirstRoute });
      if (!result) { console.warn("sin lectura", r.name); continue; }
      await fetch(`${RECEIVER}/reading`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: r.name, at, seconds: result.seconds, km: result.km })
      });
    }
  } catch (e) {
    console.error("ciclo falló", e);
  } finally {
    if (tab) chrome.tabs.remove(tab.id).catch(() => {});
    running = false;
  }
}

// Corre dentro de la página de Waze. Primera opción de ruta: "1 1 h 5 min … 25.5 KM".
function readFirstRoute() {
  const item = document.querySelector(".wm-routes__list > *");
  if (!item) return null;
  const text = item.innerText.replace(/\s+/g, " ");
  const index = item.querySelector("[class*='__index']")?.innerText.trim() ?? "";
  const body = text.startsWith(index) ? text.slice(index.length) : text;
  const m = body.match(/(?:(\d+)\s*h)?\s*(?:(\d+)\s*min)?/i);
  const hours = Number(m?.[1] ?? 0), mins = Number(m?.[2] ?? 0);
  const seconds = (hours * 60 + mins) * 60;
  const kmText = item.querySelector("[class*='__footer']")?.innerText ?? "";
  const km = parseFloat(kmText.replace(",", ".")) || null;
  return seconds > 0 ? { seconds, km } : null;
}

const sleep = ms => new Promise(r => setTimeout(r, ms));
