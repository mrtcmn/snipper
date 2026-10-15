// Snipper extension service worker: talks to the Snipper app on 127.0.0.1 and handles
// context menus, keyboard commands and an offline queue for saves made while the app is closed.

const DEFAULT_PORT = 47615;
const OUTBOX_LIMIT = 500;

class AppOfflineError extends Error {
  constructor() {
    super("Stash isn't running. Open the Stash app on your Mac.");
    this.name = "AppOfflineError";
  }
}

async function port() {
  const { port } = await chrome.storage.local.get({ port: DEFAULT_PORT });
  return Number(port) || DEFAULT_PORT;
}

/** Calls the app's local API. */
async function callApp(path, body, { method = body ? "POST" : "GET", timeout = 20000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  let response;
  try {
    response = await fetch(`http://127.0.0.1:${await port()}${path}`, {
      method,
      headers: { "Content-Type": "application/json", "X-Snipper-Client": "extension" },
      body: body ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
  } catch {
    throw new AppOfflineError();
  } finally {
    clearTimeout(timer);
  }
  const json = await response.json().catch(() => ({}));
  if (!response.ok || json.ok === false) throw new Error(json.error || `Stash answered ${response.status}`);
  return json;
}

// ---------------------------------------------------------------------------
// Offline queue

async function enqueue(items, source) {
  const { outbox = [] } = await chrome.storage.local.get("outbox");
  for (const item of items) outbox.push({ item, source, at: Date.now() });
  await chrome.storage.local.set({ outbox: outbox.slice(-OUTBOX_LIMIT) });
  await updateBadge();
}

async function flushOutbox() {
  const { outbox = [] } = await chrome.storage.local.get("outbox");
  if (!outbox.length) return 0;
  const bySource = new Map();
  for (const entry of outbox) {
    if (!bySource.has(entry.source)) bySource.set(entry.source, []);
    bySource.get(entry.source).push(entry.item);
  }
  for (const [source, items] of bySource) {
    for (let i = 0; i < items.length; i += 40) {
      await callApp("/api/snips", { source, items: items.slice(i, i + 40) });
    }
  }
  await chrome.storage.local.set({ outbox: [] });
  await updateBadge();
  return outbox.length;
}

async function updateBadge() {
  const { outbox = [] } = await chrome.storage.local.get("outbox");
  await chrome.action.setBadgeBackgroundColor({ color: "#48484A" });
  await chrome.action.setBadgeText({ text: outbox.length ? String(Math.min(outbox.length, 999)) : "" });
}

// ---------------------------------------------------------------------------
// Saving

async function save(items, source, { queueIfOffline = false } = {}) {
  try {
    const result = await callApp("/api/snips", { source, items });
    flushOutbox().catch(() => {});
    return result;
  } catch (error) {
    if (error instanceof AppOfflineError && queueIfOffline) {
      await enqueue(items, source);
      return { ok: false, queued: true };
    }
    throw error;
  }
}

/** Reads title, description, preview image and selection from a tab. */
async function pageItem(tab) {
  let meta = {};
  try {
    const [injection] = await chrome.scripting.executeScript({ target: { tabId: tab.id }, func: collectPageMeta });
    meta = injection?.result || {};
  } catch {
    // Pages like the Web Store don't allow scripts; fall back to the tab's basics.
  }
  return {
    type: "page",
    url: meta.url || tab.url,
    title: meta.title || tab.title,
    description: meta.description,
    image: meta.image,
    siteName: meta.siteName,
    favicon: meta.favicon || tab.favIconUrl,
    selection: meta.selection,
  };
}

// Runs inside the page.
function collectPageMeta() {
  const meta = (selector) => document.querySelector(selector)?.getAttribute("content") || undefined;
  const absolute = (value) => {
    try {
      return value ? new URL(value, location.href).href : undefined;
    } catch {
      return undefined;
    }
  };
  const icon = document.querySelector('link[rel="apple-touch-icon"], link[rel~="icon"]')?.getAttribute("href");
  return {
    url: location.href,
    title: meta('meta[property="og:title"]') || document.title,
    description: meta('meta[property="og:description"]') || meta('meta[name="description"]'),
    image: absolute(meta('meta[property="og:image"]') || meta('meta[name="twitter:image"]')),
    siteName: meta('meta[property="og:site_name"]'),
    favicon: absolute(icon) || absolute("/favicon.ico"),
    selection: String(window.getSelection ? window.getSelection() : "").trim() || undefined,
  };
}

async function selectionItem(tab, fallbackText) {
  const page = await pageItem(tab);
  const text = page.selection || fallbackText;
  if (!text) return null;
  return { type: "selection", text, url: page.url, title: page.title, siteName: page.siteName, favicon: page.favicon };
}

function base64FromBuffer(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

/** Fetches an image so pages behind logins still save; the app downloads it otherwise. */
async function imageDataURL(src) {
  if (!src || src.startsWith("data:")) return src || undefined;
  try {
    const response = await fetch(src, { credentials: "include" });
    if (!response.ok) return undefined;
    const blob = await response.blob();
    if (blob.size > 15 * 1024 * 1024 || !blob.type.startsWith("image/")) return undefined;
    return `data:${blob.type};base64,${base64FromBuffer(await blob.arrayBuffer())}`;
  } catch {
    return undefined;
  }
}

async function screenshotItem(tab) {
  const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: "png" });
  return { type: "screenshot", dataUrl, url: tab.url, title: tab.title };
}

// ---------------------------------------------------------------------------
// Feedback in the page

async function notify(tabId, text, kind = "ok") {
  if (tabId == null) return;
  try {
    // x.com has our content script with its own toasts.
    await chrome.tabs.sendMessage(tabId, { type: "toast", text, kind });
    return;
  } catch {}
  try {
    await chrome.scripting.executeScript({ target: { tabId }, func: showToast, args: [text, kind] });
  } catch {
    // Restricted page: use the badge instead.
    await chrome.action.setBadgeText({ text: kind === "error" ? "!" : "✓", tabId });
    setTimeout(() => chrome.action.setBadgeText({ text: "", tabId }).catch(() => {}), 2500);
  }
}

// Runs inside the page: a small glass toast in a shadow root.
function showToast(text, kind) {
  const id = "snipper-toast-root";
  document.getElementById(id)?.remove();
  const host = document.createElement("div");
  host.id = id;
  host.style.cssText = "position:fixed;left:50%;bottom:32px;transform:translateX(-50%);z-index:2147483647;";
  const shadow = host.attachShadow({ mode: "closed" });
  const colors = { ok: "#e4e4e4", warn: "#ffd68a", error: "#ff9ba7" };
  shadow.innerHTML = `
    <style>
      div{display:flex;align-items:center;gap:10px;padding:11px 16px 11px 12px;border-radius:16px;color:#f2f2f2;
        font:500 14px/1.3 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;letter-spacing:-.01em;white-space:nowrap;
        background:linear-gradient(145deg,rgba(255,255,255,.07),rgba(255,255,255,.01)),rgba(21,21,21,.8);
        border:1px solid rgba(255,255,255,.16);border-top-color:rgba(255,255,255,.26);
        box-shadow:inset 0 1px rgba(255,255,255,.06),0 14px 40px rgba(0,0,0,.35);
        -webkit-backdrop-filter:blur(24px) saturate(1.4);backdrop-filter:blur(24px) saturate(1.4);
        opacity:0;transform:translateY(10px);transition:opacity .22s ease,transform .28s cubic-bezier(.2,.8,.2,1)}
      div.in{opacity:1;transform:none}
      i{width:10px;height:10px;border-radius:50%;background:${colors[kind] || colors.ok};box-shadow:0 0 12px ${colors[kind] || colors.ok}}
    </style>
    <div><i></i><span></span></div>`;
  shadow.querySelector("span").textContent = text;
  document.documentElement.appendChild(host);
  const box = shadow.querySelector("div");
  requestAnimationFrame(() => box.classList.add("in"));
  setTimeout(() => {
    box.classList.remove("in");
    setTimeout(() => host.remove(), 300);
  }, kind === "error" ? 4000 : 2400);
}

function describe(result, noun = "Saved to Stash") {
  if (result?.queued) return ["Stash isn't running — saved for later", "warn"];
  if (result?.added === 0 && (result?.updated || result?.unchanged)) return ["Already in Stash — updated", "ok"];
  return [noun, "ok"];
}

// ---------------------------------------------------------------------------
// Context menus and commands

const MENUS = [
  { id: "snipper-selection", title: "Save selection to Stash", contexts: ["selection"] },
  { id: "snipper-link", title: "Save link to Stash", contexts: ["link"] },
  { id: "snipper-image", title: "Save image to Stash", contexts: ["image"] },
  { id: "snipper-page", title: "Save page to Stash", contexts: ["page"] },
  { id: "snipper-screenshot", title: "Screenshot visible area to Stash", contexts: ["page"] },
];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    for (const menu of MENUS) chrome.contextMenus.create(menu);
  });
  chrome.alarms.create("snipper-outbox", { periodInMinutes: 1 });
  updateBadge().catch(() => {});
});

chrome.runtime.onStartup.addListener(() => {
  chrome.alarms.create("snipper-outbox", { periodInMinutes: 1 });
});

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "snipper-outbox") flushOutbox().catch(() => {});
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const tabId = tab?.id;
  try {
    let item = null;
    let label = "Saved to Stash";
    switch (info.menuItemId) {
      case "snipper-selection":
        item = await selectionItem(tab, info.selectionText);
        label = "Selection saved to Stash";
        break;
      case "snipper-link":
        item = { type: "link", url: info.linkUrl, title: info.linkText || info.selectionText || undefined };
        label = "Link saved to Stash";
        break;
      case "snipper-image":
        item = { type: "image", srcUrl: info.srcUrl, dataUrl: await imageDataURL(info.srcUrl), url: info.pageUrl, title: tab?.title };
        label = "Image saved to Stash";
        break;
      case "snipper-page":
        item = await pageItem(tab);
        label = "Page saved to Stash";
        break;
      case "snipper-screenshot":
        item = await screenshotItem(tab);
        label = "Screenshot saved to Stash";
        break;
    }
    if (!item) return;
    const result = await save([item], "context-menu", { queueIfOffline: item.type !== "screenshot" });
    const [text, kind] = describe(result, label);
    await notify(tabId, text, kind);
  } catch (error) {
    await notify(tabId, error.message || String(error), "error");
  }
});

chrome.commands.onCommand.addListener(async (command, tab) => {
  tab = tab || (await chrome.tabs.query({ active: true, currentWindow: true }))[0];
  if (!tab) return;
  try {
    if (command === "save-page") {
      const page = await pageItem(tab);
      const item = page.selection ? { type: "selection", text: page.selection, url: page.url, title: page.title, siteName: page.siteName, favicon: page.favicon } : page;
      const result = await save([item], "shortcut", { queueIfOffline: true });
      const [text, kind] = describe(result, page.selection ? "Selection saved to Stash" : "Page saved to Stash");
      await notify(tab.id, text, kind);
    } else if (command === "screenshot-tab") {
      const result = await save([await screenshotItem(tab)], "shortcut");
      const [text, kind] = describe(result, "Screenshot saved to Stash");
      await notify(tab.id, text, kind);
    }
  } catch (error) {
    await notify(tab.id, error.message || String(error), "error");
  }
});

// ---------------------------------------------------------------------------
// Messages from content scripts and the popup

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function openBookmarksImport() {
  const tabs = await chrome.tabs.query({ url: ["https://x.com/i/bookmarks*", "https://twitter.com/i/bookmarks*", "https://x.com/i/history"] });
  if (tabs[0]) {
    await chrome.tabs.update(tabs[0].id, { active: true });
    await chrome.windows.update(tabs[0].windowId, { focused: true });
    await chrome.tabs.sendMessage(tabs[0].id, { type: "start-import" }).catch(async () => {
      await chrome.tabs.update(tabs[0].id, { url: "https://x.com/i/bookmarks#snipper-import" });
    });
  } else {
    await chrome.tabs.create({ url: "https://x.com/i/bookmarks#snipper-import" });
  }
}

async function handle(message, sender) {
  switch (message?.type) {
    case "status": {
      const status = await callApp("/api/status");
      flushOutbox().catch(() => {});
      const { outbox = [] } = await chrome.storage.local.get("outbox");
      return { ...status, queued: outbox.length };
    }
    case "save":
      return save(message.items || [], message.source || "extension", { queueIfOffline: Boolean(message.queueIfOffline) });
    case "exists":
      return callApp("/api/exists", { ids: message.ids || [] });
    case "remove":
      return callApp("/api/remove", { tweetIds: message.ids || [] });
    case "progress":
      return callApp("/api/import-progress", { count: message.count || 0, done: Boolean(message.done) });
    case "open":
      return callApp("/api/open", { query: message.query ?? undefined }).catch(() => openApp());
    case "launch":
      return openApp();
    case "save-active-page": {
      const tab = await activeTab();
      const result = await save([await pageItem(tab)], "popup", { queueIfOffline: true });
      const [text, kind] = describe(result, "Page saved to Stash");
      await notify(tab.id, text, kind);
      return result;
    }
    case "save-active-selection": {
      const tab = await activeTab();
      const item = await selectionItem(tab);
      if (!item) throw new Error("Select some text on the page first.");
      const result = await save([item], "popup", { queueIfOffline: true });
      const [text, kind] = describe(result, "Selection saved to Stash");
      await notify(tab.id, text, kind);
      return result;
    }
    case "screenshot-active": {
      const tab = await activeTab();
      const result = await save([await screenshotItem(tab)], "popup");
      const [text, kind] = describe(result, "Screenshot saved to Stash");
      await notify(tab.id, text, kind);
      return result;
    }
    case "import-bookmarks":
      await openBookmarksImport();
      return { ok: true };
    default:
      throw new Error(`Unknown message ${message?.type}`);
  }
}

async function openApp() {
  // Opening the custom URL scheme launches Snipper (the browser asks once).
  await chrome.tabs.create({ url: "snipper://open", active: true });
  return { ok: true };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  handle(message, sender)
    .then((result) => sendResponse({ ok: true, ...result }))
    .catch((error) =>
      sendResponse({ ok: false, error: error.message || String(error), offline: error instanceof AppOfflineError, queued: false }),
    );
  return true; // keep the channel open for the async reply
});
