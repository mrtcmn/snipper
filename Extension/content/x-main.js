// Runs in x.com's own JavaScript world. Watches the web app's GraphQL responses (the same
// data X renders from) and hands normalized posts to the extension's content script, so a
// snip gets the full text of long posts, every image and accurate metrics.
(function () {
  "use strict";
  if (window.__snipperHooked) return;
  window.__snipperHooked = true;

  // Runs before X's redirect from /i/bookmarks to /i/history drops the hash; x.js reads this.
  if (location.hash === "#snipper-import") sessionStorage.setItem("snipper-import", "1");

  const parse = window.__snipperTweetParse;
  if (!parse) return;

  const GRAPHQL = /\/graphql\/[A-Za-z0-9_-]+\/[A-Za-z0-9_]+/;

  // The content script starts later than this hook (at document_idle), so keep recent
  // messages and replay them when it asks.
  const recent = [];
  function emit(message) {
    recent.push(message);
    if (recent.length > 40) recent.shift();
    window.postMessage(message, window.location.origin);
  }
  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.__snipper !== "replay") return;
    for (const message of recent) window.postMessage(message, window.location.origin);
  });

  function publish(url, json) {
    try {
      const operation = parse.operationName(url);
      const tweets = parse.collectTweets(json);
      const timeline = /Bookmark/i.test(operation || "") ? parse.timelineTweets(json) : [];
      if (!tweets.length && !timeline.length) return;
      emit({
        __snipper: "graphql",
        operation,
        tweets,
        timelineIds: timeline.map((t) => t.id),
        cursor: timeline.length ? parse.bottomCursor(json) : null,
      });
    } catch {
      // Never interfere with the page.
    }
  }

  // X sends this mutation from the bookmark button, the share menu and the keyboard alike.
  // Not kept for replay, so a reload doesn't save the post again.
  function bookmarkCreated(url, body) {
    if (parse.operationName(url) !== "CreateBookmark" || typeof body !== "string") return;
    try {
      const id = JSON.parse(body)?.variables?.tweet_id;
      if (id) window.postMessage({ __snipper: "bookmark", id: String(id) }, window.location.origin);
    } catch {}
  }

  // XMLHttpRequest: X's web app loads its timelines this way.
  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    try {
      this.__snipperURL = typeof url === "string" ? url : String(url);
    } catch {}
    return xhrOpen.call(this, method, url, ...rest);
  };
  XMLHttpRequest.prototype.send = function (...args) {
    const url = this.__snipperURL;
    if (url && GRAPHQL.test(url)) {
      this.addEventListener("load", () => {
        try {
          if (this.status < 200 || this.status >= 300) return;
          bookmarkCreated(url, args[0]);
          let json = null;
          if (this.responseType === "" || this.responseType === "text") json = JSON.parse(this.responseText);
          else if (this.responseType === "json") json = this.response;
          if (json) publish(url, json);
        } catch {}
      });
    }
    return xhrSend.apply(this, args);
  };

  // fetch: used by some newer parts of the app.
  const originalFetch = window.fetch;
  window.fetch = async function (input, init) {
    const response = await originalFetch.call(this, input, init);
    try {
      const url = typeof input === "string" ? input : input?.url ?? String(input);
      if (GRAPHQL.test(url) && response.ok) {
        // ponytail: reads init.body only; a Request object's body is not read.
        bookmarkCreated(url, init?.body);
        response.clone().json().then((json) => publish(url, json)).catch(() => {});
      }
    } catch {}
    return response;
  };
})();
