// Normalizes posts from X's web GraphQL responses (and from the page DOM) into the
// shape the Snipper app expects. Runs in the page's main world and in Node tests.
(function (root) {
  "use strict";

  const ENTITY_MAP = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", "#39": "'" };

  function decodeEntities(text) {
    return String(text).replace(/&(#x[0-9a-f]+|#\d+|[a-z]+|#39);/gi, (match, name) => {
      const lower = name.toLowerCase();
      if (ENTITY_MAP[lower]) return ENTITY_MAP[lower];
      if (lower.startsWith("#x")) return String.fromCodePoint(parseInt(lower.slice(2), 16));
      if (lower.startsWith("#")) return String.fromCodePoint(parseInt(lower.slice(1), 10));
      return match;
    });
  }

  /**
   * Applies X's display range (in code points), expands t.co links and drops media links.
   * The text arrives HTML-escaped but its indices count the unescaped text, so decode first.
   */
  function cleanText(text, { range = null, urls = [], mediaUrls = [] } = {}) {
    let s = decodeEntities(String(text ?? ""));
    if (Array.isArray(range) && range.length === 2) {
      const chars = Array.from(s);
      s = chars.slice(Math.max(0, range[0]), Math.min(chars.length, range[1])).join("");
    }
    for (const u of urls) {
      if (u && u.url && u.expanded_url) s = s.split(u.url).join(u.expanded_url);
    }
    for (const m of mediaUrls) {
      if (m) s = s.split(m).join("");
    }
    return s.replace(/[ \t]+\n/g, "\n").trim();
  }

  /** Unwraps visibility/limited-action wrappers around a tweet result. */
  function unwrap(result) {
    if (!result || typeof result !== "object") return null;
    if (result.__typename === "TweetWithVisibilityResults" && result.tweet) return result.tweet;
    if (result.__typename === "TweetTombstone" || result.__typename === "TweetUnavailable") return null;
    if (!result.legacy && result.tweet && result.tweet.legacy) return result.tweet;
    return result;
  }

  function userFrom(userResults) {
    const u = userResults?.result;
    if (!u) return null;
    const legacy = u.legacy || {};
    const core = u.core || {};
    const handle = core.screen_name ?? legacy.screen_name;
    if (!handle) return null;
    return {
      name: core.name ?? legacy.name ?? handle,
      handle,
      avatar: u.avatar?.image_url ?? legacy.profile_image_url_https ?? null,
      verified: Boolean(u.is_blue_verified || legacy.verified || u.verification?.verified),
    };
  }

  function bestVideo(variants) {
    if (!Array.isArray(variants)) return undefined;
    const mp4 = variants.filter((v) => v && v.content_type === "video/mp4" && v.url);
    mp4.sort((a, b) => (b.bitrate || 0) - (a.bitrate || 0));
    return mp4[0]?.url;
  }

  function mediaFrom(list) {
    if (!Array.isArray(list)) return [];
    return list
      .filter((m) => m && m.media_url_https)
      .map((m) => ({
        type: m.type === "photo" ? "photo" : m.type === "animated_gif" ? "gif" : "video",
        url: m.media_url_https,
        width: m.original_info?.width,
        height: m.original_info?.height,
        alt: m.ext_alt_text || undefined,
        videoUrl: bestVideo(m.video_info?.variants),
      }));
  }

  function cardFrom(card, urls) {
    const legacy = card?.legacy;
    if (!legacy || !Array.isArray(legacy.binding_values)) return undefined;
    const values = {};
    for (const entry of legacy.binding_values) {
      if (entry && entry.key) values[entry.key] = entry.value;
    }
    const str = (k) => values[k]?.string_value;
    const img = (k) => values[k]?.image_value?.url;
    const shortUrl = legacy.url || str("card_url");
    const expanded = (urls || []).find((u) => u.url === shortUrl)?.expanded_url;
    const result = {
      url: expanded || shortUrl,
      title: str("title"),
      description: str("description"),
      image: img("thumbnail_image_large") || img("summary_photo_image_large") || img("photo_image_full_size_large") || img("thumbnail_image"),
      siteName: str("vanity_url") || str("domain"),
    };
    return result.title || result.description || result.image ? result : undefined;
  }

  function isoDate(value) {
    if (!value) return undefined;
    const d = new Date(value);
    return Number.isNaN(d.getTime()) ? undefined : d.toISOString();
  }

  /** Converts one GraphQL tweet result to a normalized post (retweets resolve to the original). */
  function normalizeTweet(raw, depth = 0) {
    const t = unwrap(raw);
    if (!t || !t.legacy || !t.rest_id) return null;
    const legacy = t.legacy;

    const retweeted = legacy.retweeted_status_result?.result;
    if (retweeted && depth === 0) {
      const original = normalizeTweet(retweeted, 0);
      if (original) return original;
    }

    const author = userFrom(t.core?.user_results);
    const media = legacy.extended_entities?.media || legacy.entities?.media || [];
    const note = t.note_tweet?.note_tweet_results?.result;
    const text = note?.text
      ? cleanText(note.text, { urls: note.entity_set?.urls || [] })
      : cleanText(legacy.full_text, {
          range: legacy.display_text_range,
          urls: legacy.entities?.urls || [],
          mediaUrls: media.map((m) => m.url),
        });

    const post = {
      id: t.rest_id,
      url: author ? `https://x.com/${author.handle}/status/${t.rest_id}` : `https://x.com/i/web/status/${t.rest_id}`,
      text,
      createdAt: isoDate(legacy.created_at),
      lang: legacy.lang,
      conversationId: legacy.conversation_id_str,
      author: author || undefined,
      metrics: {
        likes: legacy.favorite_count,
        retweets: legacy.retweet_count,
        replies: legacy.reply_count,
        quotes: legacy.quote_count,
        bookmarks: legacy.bookmark_count,
        views: t.views?.count != null ? Number(t.views.count) || undefined : undefined,
      },
      media: mediaFrom(media),
      card: cardFrom(t.card, [...(legacy.entities?.urls || []), ...(note?.entity_set?.urls || [])]),
    };

    const quotedRaw = t.quoted_status_result?.result;
    if (quotedRaw && depth === 0) {
      const q = normalizeTweet(quotedRaw, 1);
      if (q) post.quoted = { id: q.id, url: q.url, text: q.text, createdAt: q.createdAt, author: q.author, media: q.media };
    }
    return post;
  }

  /** Every tweet anywhere in a response, including quoted ones (for the click cache). */
  function collectTweets(json) {
    const found = new Map();
    const seen = new Set();
    const walk = (node) => {
      if (!node || typeof node !== "object" || seen.has(node)) return;
      seen.add(node);
      if (Array.isArray(node)) {
        for (const item of node) walk(item);
        return;
      }
      if (node.rest_id && node.legacy && (node.__typename === "Tweet" || node.core)) {
        const post = normalizeTweet(node);
        if (post && !found.has(post.id)) found.set(post.id, post);
      }
      for (const key in node) {
        const value = node[key];
        if (value && typeof value === "object") walk(value);
      }
    };
    walk(json);
    return [...found.values()];
  }

  /** Only the posts that are timeline entries (e.g. the bookmarks themselves, not posts they quote). */
  function timelineTweets(json) {
    const out = [];
    const ids = new Set();
    const pushResult = (result) => {
      const post = normalizeTweet(result);
      if (post && !ids.has(post.id)) {
        ids.add(post.id);
        out.push(post);
      }
    };
    const visitInstructions = (instructions) => {
      for (const ins of instructions || []) {
        const entries = ins.entries || (ins.entry ? [ins.entry] : []);
        for (const entry of entries) {
          const content = entry?.content;
          if (!content) continue;
          const direct = content.itemContent?.tweet_results?.result;
          if (direct) pushResult(direct);
          for (const item of content.items || []) {
            const nested = item?.item?.itemContent?.tweet_results?.result;
            if (nested) pushResult(nested);
          }
        }
      }
    };
    const seen = new Set();
    const walk = (node) => {
      if (!node || typeof node !== "object" || seen.has(node)) return;
      seen.add(node);
      if (Array.isArray(node.instructions)) visitInstructions(node.instructions);
      for (const key in node) {
        const value = node[key];
        if (value && typeof value === "object") walk(value);
      }
    };
    walk(json);
    return out;
  }

  /** The bottom cursor of a timeline response, if any (more pages exist). */
  function bottomCursor(json) {
    let cursor = null;
    const seen = new Set();
    const walk = (node) => {
      if (cursor || !node || typeof node !== "object" || seen.has(node)) return;
      seen.add(node);
      if (node.cursorType === "Bottom" && typeof node.value === "string") {
        cursor = node.value;
        return;
      }
      for (const key in node) {
        const value = node[key];
        if (value && typeof value === "object") walk(value);
      }
    };
    walk(json);
    return cursor;
  }

  /** The GraphQL operation name from a request URL, e.g. "Bookmarks". */
  function operationName(url) {
    const match = /\/graphql\/[A-Za-z0-9_-]+\/([A-Za-z0-9_]+)/.exec(String(url));
    return match ? match[1] : null;
  }

  const api = { decodeEntities, cleanText, normalizeTweet, collectTweets, timelineTweets, bottomCursor, operationName };
  root.__snipperTweetParse = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
