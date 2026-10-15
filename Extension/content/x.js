// Snipper on x.com: a Snip button on every post, saved-state sync, and bookmark import.
(function () {
  "use strict";
  if (window.__snipperContent) return;
  window.__snipperContent = true;

  const cache = new Map(); // post id → normalized post from GraphQL
  const bookmarkIds = new Set(); // ids that appeared in Bookmarks responses
  const saved = new Set();
  const checked = new Set();
  const MAX_CACHE = 6000;

  // ---------------------------------------------------------------------------
  // Messaging

  function send(message) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage(message, (response) => {
          if (chrome.runtime.lastError) resolve({ ok: false, error: chrome.runtime.lastError.message });
          else resolve(response || { ok: false, error: "No response" });
        });
      } catch (error) {
        // The extension was reloaded; this page's script is orphaned.
        resolve({ ok: false, error: "Reload the page to reconnect Stash." });
      }
    });
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.origin !== window.location.origin) return;
    const data = event.data;
    if (data?.__snipper === "bookmark" && typeof data.id === "string") {
      saveBookmark(data.id);
      return;
    }
    if (!data || data.__snipper !== "graphql" || !Array.isArray(data.tweets)) return;
    for (const post of data.tweets) {
      if (post && post.id) cache.set(post.id, post);
    }
    for (const id of data.timelineIds || []) {
      bookmarkIds.add(id);
      importer.offer(cache.get(id));
    }
    if (cache.size > MAX_CACHE) {
      const drop = cache.size - MAX_CACHE;
      let i = 0;
      for (const key of cache.keys()) {
        if (i++ >= drop) break;
        cache.delete(key);
      }
    }
  });

  // Ask the page hook for responses it saw before this script started.
  window.postMessage({ __snipper: "replay" }, window.location.origin);

  // ---------------------------------------------------------------------------
  // Reading posts from the page

  function statusLink(article) {
    const times = [...article.querySelectorAll('a[href*="/status/"] time')];
    // Skip timestamps inside a quoted post.
    const own = times.find((t) => !t.closest('div[role="link"]')) || times[0];
    return own ? own.closest("a") : article.querySelector('a[href*="/status/"]');
  }

  function postIdOf(article) {
    const href = statusLink(article)?.getAttribute("href") || "";
    const match = /\/status\/(\d+)/.exec(href);
    return match ? match[1] : null;
  }

  function upgradePhoto(src) {
    try {
      const url = new URL(src);
      if (url.hostname === "pbs.twimg.com") url.searchParams.set("name", "large");
      return url.href;
    } catch {
      return src;
    }
  }

  /** Builds a post from the rendered DOM when GraphQL data isn't available. */
  function postFromDOM(article, id) {
    const textNode = [...article.querySelectorAll('[data-testid="tweetText"]')].find((n) => !n.closest('div[role="link"]'));
    const nameBlock = article.querySelector('[data-testid="User-Name"]');
    let name;
    let handle;
    if (nameBlock) {
      const parts = [...nameBlock.querySelectorAll("span")].map((s) => s.textContent.trim()).filter(Boolean);
      handle = parts.find((s) => s.startsWith("@"))?.slice(1);
      name = parts.find((s) => !s.startsWith("@") && s !== "·");
    }
    if (!handle) {
      const href = statusLink(article)?.getAttribute("href") || "";
      handle = href.split("/").filter(Boolean)[0];
    }
    const avatar = article.querySelector('[data-testid="Tweet-User-Avatar"] img')?.src;
    const time = statusLink(article)?.querySelector("time")?.getAttribute("datetime");
    const media = [];
    for (const img of article.querySelectorAll('[data-testid="tweetPhoto"] img')) {
      if (img.closest('div[role="link"]')) continue;
      media.push({ type: "photo", url: upgradePhoto(img.src), alt: img.alt && img.alt !== "Image" ? img.alt : undefined });
    }
    const video = article.querySelector("video");
    if (video && video.poster && !video.closest('div[role="link"]')) media.push({ type: "video", url: video.poster });

    return {
      id,
      url: handle ? `https://x.com/${handle}/status/${id}` : `https://x.com/i/web/status/${id}`,
      text: textNode ? textNode.innerText.trim() : "",
      createdAt: time || undefined,
      author: handle ? { name: name || handle, handle, avatar } : undefined,
      media,
    };
  }

  function postFor(article) {
    const id = postIdOf(article);
    if (!id) return null;
    return cache.get(id) || postFromDOM(article, id);
  }

  // ---------------------------------------------------------------------------
  // Snip buttons

  const ICON = `<svg viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M20 4 8.12 15.88"/><path d="M14.47 14.48 20 20"/><path d="M8.12 8.12 12 12"/></svg>`;

  function decorate(article) {
    if (article.dataset.snipper) return;
    const groups = article.querySelectorAll('[role="group"]');
    const bar = groups[groups.length - 1];
    const id = postIdOf(article);
    if (!bar || !id) return;
    article.dataset.snipper = id;

    const wrap = document.createElement("div");
    wrap.className = "snipper-action";
    const button = document.createElement("button");
    button.type = "button";
    button.className = "snipper-btn";
    button.dataset.snipperId = id;
    button.setAttribute("aria-label", "Save to Stash");
    button.title = "Save to Stash";
    button.innerHTML = `<span class="snipper-btn-circle">${ICON}</span>`;
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      toggle(article, button);
    });
    wrap.appendChild(button);

    const last = bar.lastElementChild;
    if (last && /share/i.test(last.querySelector("[aria-label]")?.getAttribute("aria-label") || "")) {
      bar.insertBefore(wrap, last);
    } else {
      bar.appendChild(wrap);
    }
    markSaved(button, saved.has(id));
    if (!checked.has(id)) queueCheck(id);
  }

  function markSaved(button, isSaved) {
    button.dataset.saved = isSaved ? "true" : "false";
    button.title = isSaved ? "Saved in Stash — click to remove" : "Save to Stash";
    button.setAttribute("aria-label", button.title);
  }

  function buttonsFor(id) {
    return document.querySelectorAll(`.snipper-btn[data-snipper-id="${CSS.escape(id)}"]`);
  }

  async function toggle(article, button) {
    const id = button.dataset.snipperId;
    if (button.dataset.busy) return;
    button.dataset.busy = "true";
    try {
      if (saved.has(id)) {
        const result = await send({ type: "remove", ids: [id] });
        if (!result.ok) throw result;
        saved.delete(id);
        buttonsFor(id).forEach((b) => markSaved(b, false));
        toast("Removed from Stash");
      } else {
        const post = postFor(article);
        if (!post) throw { error: "Couldn't read this post." };
        const result = await send({ type: "save", source: "x-button", items: [{ type: "tweet", tweet: post }], queueIfOffline: true });
        if (!result.ok && !result.queued) throw result;
        saved.add(id);
        buttonsFor(id).forEach((b) => {
          markSaved(b, true);
          b.classList.remove("snipper-pop");
          void b.offsetWidth;
          b.classList.add("snipper-pop");
        });
        const who = post.author?.handle ? ` by @${post.author.handle}` : "";
        toast(result.queued ? "Stash isn't running — saved for later" : `Saved post${who}`, result.queued ? "warn" : "ok");
      }
    } catch (failure) {
      toast(failure?.error || "Couldn't reach Stash", "error");
    } finally {
      delete button.dataset.busy;
    }
  }

  /** Saves a post the user just bookmarked on X. */
  async function saveBookmark(id) {
    const article = document.querySelector(`article[data-snipper="${CSS.escape(id)}"]`);
    const post = cache.get(id) || (article && postFromDOM(article, id));
    if (!post) return;
    const result = await send({ type: "save", source: "x-bookmarks", items: [{ type: "tweet", tweet: post }], queueIfOffline: true });
    if (!result.ok && !result.queued) {
      toast(result.error || "Couldn't reach Stash", "error");
      return;
    }
    saved.add(id);
    buttonsFor(id).forEach((b) => markSaved(b, true));
    toast(result.queued ? "Stash isn't running — saved for later" : "Bookmark saved to Stash", result.queued ? "warn" : "ok");
  }

  // Ask the app which visible posts are already saved, in batches.
  let pendingIds = new Set();
  let checkTimer = null;
  function queueCheck(id) {
    pendingIds.add(id);
    clearTimeout(checkTimer);
    checkTimer = setTimeout(async () => {
      const ids = [...pendingIds];
      pendingIds = new Set();
      ids.forEach((i) => checked.add(i));
      const result = await send({ type: "exists", ids });
      if (!result.ok) return;
      for (const savedId of result.saved || []) {
        saved.add(savedId);
        buttonsFor(savedId).forEach((b) => markSaved(b, true));
      }
    }, 450);
  }

  function scan(root = document) {
    root.querySelectorAll('article[data-testid="tweet"]:not([data-snipper])').forEach(decorate);
  }

  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType !== 1) continue;
        if (node.matches?.('article[data-testid="tweet"]')) decorate(node);
        else if (node.querySelector?.('article[data-testid="tweet"]')) scan(node);
      }
    }
    importer.watchRoute();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();

  // ---------------------------------------------------------------------------
  // Toasts

  let toastHost = null;
  let toastTimer = null;
  function toast(text, kind = "ok", action = null) {
    if (!toastHost) {
      toastHost = document.createElement("div");
      toastHost.className = "snipper-toast-host";
      document.documentElement.appendChild(toastHost);
    }
    toastHost.innerHTML = "";
    const el = document.createElement("div");
    el.className = `snipper-toast snipper-toast-${kind}`;
    const icon = document.createElement("span");
    icon.className = "snipper-toast-icon";
    icon.innerHTML = ICON;
    const label = document.createElement("span");
    label.textContent = text;
    el.append(icon, label);
    if (action) {
      const b = document.createElement("button");
      b.textContent = action.label;
      b.addEventListener("click", action.run);
      el.appendChild(b);
    }
    toastHost.appendChild(el);
    requestAnimationFrame(() => el.classList.add("snipper-toast-in"));
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      el.classList.remove("snipper-toast-in");
      setTimeout(() => el.remove(), 300);
    }, kind === "error" ? 4200 : 2600);
  }

  // ---------------------------------------------------------------------------
  // Bookmark import

  // Bookmarks list newest first, so after one full scan an import can stop at this many known posts in a row.
  const KNOWN_STREAK = 30;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const escapeHTML = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

  const importer = {
    panel: null,
    state: "idle", // idle | running | done | error
    collected: new Map(),
    domOnly: new Map(),
    sent: new Set(),
    added: 0,
    updated: 0,
    message: "",
    onBookmarks: false,
    scanned: false, // a full scan reached the end once
    incremental: false,
    knownStreak: 0,

    isBookmarksPage() {
      // X redirects /i/bookmarks to /i/history, whose default tab is Bookmarks.
      return /^\/i\/(bookmarks(\/|$)|history\/?$)/.test(location.pathname);
    },

    watchRoute() {
      const here = this.isBookmarksPage();
      if (here === this.onBookmarks) return;
      this.onBookmarks = here;
      if (here) {
        this.showPanel();
        // x-main.js keeps the request in sessionStorage because X's redirect drops the hash.
        const requested = location.hash === "#snipper-import" || sessionStorage.getItem("snipper-import");
        sessionStorage.removeItem("snipper-import");
        if (requested) {
          if (location.hash) history.replaceState(null, "", location.pathname + location.search);
          setTimeout(() => this.start(), 1200);
        }
      } else if (this.state !== "running") {
        this.hidePanel();
      }
    },

    offer(post) {
      if (this.state === "running" && post && post.id) this.collected.set(post.id, post);
    },

    async start(full = false) {
      if (this.state === "running") return;
      if (!this.isBookmarksPage()) {
        location.href = "https://x.com/i/bookmarks#snipper-import";
        return;
      }
      const status = await send({ type: "status" });
      if (!status.ok) {
        this.state = "error";
        this.message = "Stash isn't running. Open the app, then try again.";
        this.render();
        return;
      }
      this.state = "running";
      this.collected = new Map();
      this.domOnly = new Map();
      this.sent = new Set();
      this.added = 0;
      this.updated = 0;
      this.incremental = this.scanned && !full;
      this.knownStreak = 0;
      // Bookmarks the page already loaded before we started.
      for (const id of bookmarkIds) if (cache.has(id)) this.collected.set(id, cache.get(id));
      this.render();
      this.run();
    },

    stop() {
      if (this.state === "running") this.state = "stopping";
    },

    scrapeDOM() {
      for (const article of document.querySelectorAll('article[data-testid="tweet"]')) {
        const id = postIdOf(article);
        if (!id) continue;
        if (cache.has(id)) this.collected.set(id, cache.get(id));
        else if (!this.collected.has(id)) this.domOnly.set(id, postFromDOM(article, id));
      }
    },

    async flush(final = false) {
      const pending = [...this.collected.values()].filter((p) => !this.sent.has(p.id));
      if (final) {
        for (const [id, post] of this.domOnly) if (!this.collected.has(id) && !this.sent.has(id)) pending.push(post);
      }
      for (let i = 0; i < pending.length; i += 40) {
        const batch = pending.slice(i, i + 40);
        if (this.incremental) {
          const known = new Set((await send({ type: "exists", ids: batch.map((p) => p.id) })).saved || []);
          for (const p of batch) this.knownStreak = known.has(p.id) ? this.knownStreak + 1 : 0;
        }
        const result = await send({ type: "save", source: "x-bookmarks", items: batch.map((tweet) => ({ type: "tweet", tweet })) });
        if (!result.ok) throw new Error(result.error || "Couldn't reach Stash");
        batch.forEach((p) => {
          this.sent.add(p.id);
          saved.add(p.id);
          buttonsFor(p.id).forEach((b) => markSaved(b, true));
        });
        this.added += result.added || 0;
        this.updated += (result.updated || 0) + (result.unchanged || 0);
      }
      this.render();
    },

    async run() {
      let idleRounds = 0;
      let lastSize = -1;
      let lastReport = 0;
      let reachedEnd = false;
      try {
        window.scrollTo({ top: 0 });
        await sleep(900);
        while (this.state === "running") {
          this.scrapeDOM();
          await this.flush();
          const size = this.collected.size + this.domOnly.size;
          idleRounds = size === lastSize ? idleRounds + 1 : 0;
          lastSize = size;
          if (Date.now() - lastReport > 2500) {
            lastReport = Date.now();
            send({ type: "progress", count: this.sent.size });
          }
          if (this.incremental && this.knownStreak >= KNOWN_STREAK) break;
          const atBottom = window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 300;
          if (idleRounds >= (atBottom ? 7 : 16)) {
            reachedEnd = atBottom;
            break;
          }
          window.scrollBy({ top: Math.round(window.innerHeight * 0.85), behavior: "instant" });
          await sleep(650 + Math.random() * 450);
        }
        this.scrapeDOM();
        await this.flush(true);
        if (reachedEnd && this.state === "running" && !this.scanned) {
          this.scanned = true;
          chrome.storage.local.set({ bookmarksScanned: true });
        }
        this.state = "done";
        this.message = `Saved ${this.sent.size.toLocaleString()} bookmarks${this.added ? ` · ${this.added.toLocaleString()} new` : ""}.`;
        send({ type: "progress", done: true, count: this.sent.size });
      } catch (error) {
        this.state = "error";
        this.message = `${error.message || error}. ${this.sent.size} bookmarks were saved before it stopped.`;
      }
      this.render();
    },

    showPanel() {
      if (this.panel) return;
      this.panel = document.createElement("div");
      this.panel.className = "snipper-panel";
      document.documentElement.appendChild(this.panel);
      this.render();
      requestAnimationFrame(() => this.panel?.classList.add("snipper-panel-in"));
    },

    hidePanel() {
      this.panel?.remove();
      this.panel = null;
    },

    render() {
      if (!this.panel) {
        if (this.state === "running" || this.state === "done" || this.state === "error") this.showPanel();
        if (!this.panel) return;
      }
      const count = this.sent.size;
      const found = this.collected.size + this.domOnly.size;
      let body = "";
      let actions = "";
      if (this.state === "idle" && this.scanned) {
        body = `<p>Save bookmarks added since the last import. Stash stops when it reaches posts it already has.</p>`;
        actions = `<button class="snipper-primary" data-act="start">Import new bookmarks</button><button data-act="full">Rescan all</button>`;
      } else if (this.state === "idle") {
        body = `<p>Save every bookmark to Stash on your Mac, with full text and images, ready for semantic search.</p>`;
        actions = `<button class="snipper-primary" data-act="start">Import all bookmarks</button>`;
      } else if (this.state === "running" || this.state === "stopping") {
        body = `<p class="snipper-count"><strong>${count.toLocaleString()}</strong> saved <span>· ${found.toLocaleString()} found · scrolling…</span></p><div class="snipper-bar"><i></i></div>`;
        actions = `<button data-act="stop">${this.state === "stopping" ? "Stopping…" : "Stop"}</button>`;
      } else if (this.state === "done") {
        body = `<p>${escapeHTML(this.message)}</p>`;
        actions = `<button class="snipper-primary" data-act="open">Open Stash</button><button data-act="start">Run again</button>`;
      } else {
        body = `<p class="snipper-error">${escapeHTML(this.message)}</p>`;
        actions = `<button class="snipper-primary" data-act="start">Try again</button><button data-act="launch">Open Stash</button>`;
      }
      this.panel.innerHTML = `
        <div class="snipper-panel-head">
          <span class="snipper-logo">${ICON}</span>
          <div><strong>Stash</strong><small>Bookmarks import</small></div>
          <button class="snipper-close" data-act="close" aria-label="Close">×</button>
        </div>
        ${body}
        <div class="snipper-actions">${actions}</div>`;
      this.panel.querySelectorAll("[data-act]").forEach((el) =>
        el.addEventListener("click", () => {
          const act = el.dataset.act;
          if (act === "start") this.start();
          else if (act === "full") this.start(true);
          else if (act === "stop") this.stop();
          else if (act === "close") {
            if (this.state === "running") this.stop();
            this.hidePanel();
          } else if (act === "open") send({ type: "open", query: "" });
          else if (act === "launch") send({ type: "launch" });
        }),
      );
    },
  };

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "start-import") {
      importer.start();
      sendResponse({ ok: true });
    } else if (message?.type === "toast") {
      toast(message.text, message.kind);
      sendResponse({ ok: true });
    }
  });

  importer.watchRoute();
  chrome.storage.local.get({ bookmarksScanned: false }).then(({ bookmarksScanned }) => {
    importer.scanned = bookmarksScanned;
    importer.render();
  });
})();
