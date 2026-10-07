// Run with: node --test "Extension/tests/*.test.mjs"
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const parse = require("../shared/tweet-parse.js");

const user = (handle, name, { schema = "new", verified = false } = {}) => ({
  result:
    schema === "new"
      ? {
          __typename: "User",
          rest_id: `u-${handle}`,
          is_blue_verified: verified,
          core: { name, screen_name: handle },
          avatar: { image_url: `https://pbs.twimg.com/profile_images/1/${handle}_normal.jpg` },
          legacy: {},
        }
      : {
          __typename: "User",
          rest_id: `u-${handle}`,
          legacy: { name, screen_name: handle, profile_image_url_https: `https://pbs.twimg.com/p/${handle}_normal.png`, verified },
        },
});

const quoted = {
  __typename: "Tweet",
  rest_id: "1700000000000000000",
  core: { user_results: user("quoter", "Quote Person") },
  legacy: { full_text: "The original thought", created_at: "Fri Sep 01 00:00:00 +0000 2023", entities: {} },
};

const photoPost = {
  __typename: "Tweet",
  rest_id: "1790000000000000001",
  core: { user_results: user("glasslab", "Glass Lab", { verified: true }) },
  views: { count: "12345", state: "EnabledWithCount" },
  legacy: {
    bookmark_count: 5,
    created_at: "Wed May 01 10:20:30 +0000 2024",
    conversation_id_str: "1790000000000000001",
    display_text_range: [0, 39],
    entities: {
      urls: [{ url: "https://t.co/abc", expanded_url: "https://glass.dev/post", display_url: "glass.dev/post" }],
      media: [{ url: "https://t.co/pic" }],
    },
    extended_entities: {
      media: [
        { type: "photo", url: "https://t.co/pic", media_url_https: "https://pbs.twimg.com/media/A.jpg", original_info: { width: 1600, height: 900 }, ext_alt_text: "A prism" },
        {
          type: "video",
          url: "https://t.co/pic",
          media_url_https: "https://pbs.twimg.com/ext_tw_video_thumb/B.jpg",
          video_info: {
            variants: [
              { content_type: "application/x-mpegURL", url: "https://video.twimg.com/x.m3u8" },
              { content_type: "video/mp4", bitrate: 256000, url: "https://video.twimg.com/low.mp4" },
              { content_type: "video/mp4", bitrate: 2176000, url: "https://video.twimg.com/high.mp4" },
            ],
          },
        },
      ],
    },
    favorite_count: 100,
    full_text: "Glass &amp; light: bending https://t.co/abc https://t.co/pic",
    lang: "en",
    quote_count: 2,
    reply_count: 3,
    retweet_count: 4,
  },
  quoted_status_result: { result: quoted },
};

const visibilityWrapped = {
  __typename: "TweetWithVisibilityResults",
  tweet: {
    rest_id: "1790000000000000002",
    core: { user_results: user("old", "Old Schema", { schema: "old", verified: true }) },
    legacy: { full_text: "@someone replying here", display_text_range: [9, 22], created_at: "Thu May 02 10:00:00 +0000 2024", entities: {} },
  },
};

const retweet = {
  __typename: "Tweet",
  rest_id: "1790000000000000003",
  core: { user_results: user("retweeter", "Retweeter") },
  legacy: {
    full_text: "RT @author: Original 👀 text",
    entities: {},
    retweeted_status_result: {
      result: {
        __typename: "Tweet",
        rest_id: "1600000000000000000",
        core: { user_results: user("author", "Author") },
        legacy: { full_text: "Original 👀 text", created_at: "Mon Jan 02 00:00:00 +0000 2023", entities: {} },
      },
    },
  },
};

const noteTweet = {
  __typename: "Tweet",
  rest_id: "1790000000000000004",
  core: { user_results: user("writer", "Long Writer") },
  note_tweet: {
    note_tweet_results: {
      result: { text: "A very long post that goes past 280 characters… see https://t.co/long", entity_set: { urls: [{ url: "https://t.co/long", expanded_url: "https://long.example/read" }] } },
    },
  },
  legacy: { full_text: "A very long post that goes past 280 char… https://t.co/trunc", entities: {} },
  card: {
    legacy: {
      url: "https://t.co/long",
      binding_values: [
        { key: "title", value: { string_value: "Long read" } },
        { key: "description", value: { string_value: "An article" } },
        { key: "thumbnail_image_large", value: { image_value: { url: "https://pbs.twimg.com/card.jpg" } } },
        { key: "vanity_url", value: { string_value: "long.example" } },
      ],
    },
  },
};

const entry = (id, result) => ({
  entryId: `tweet-${id}`,
  content: { entryType: "TimelineTimelineItem", itemContent: { itemType: "TimelineTweet", tweet_results: { result } } },
});

const bookmarksResponse = {
  data: {
    bookmark_timeline_v2: {
      timeline: {
        instructions: [
          {
            type: "TimelineAddEntries",
            entries: [
              entry("1", photoPost),
              entry("2", visibilityWrapped),
              entry("3", retweet),
              entry("4", noteTweet),
              entry("5", { __typename: "TweetTombstone", tombstone: {} }),
              { entryId: "cursor-bottom-1", content: { entryType: "TimelineTimelineCursor", value: "HBaAAA==", cursorType: "Bottom" } },
            ],
          },
        ],
      },
    },
  },
};

test("timelineTweets returns only the timeline entries", () => {
  const posts = parse.timelineTweets(bookmarksResponse);
  assert.deepEqual(
    posts.map((p) => p.id),
    ["1790000000000000001", "1790000000000000002", "1600000000000000000", "1790000000000000004"],
  );
});

test("collectTweets also finds quoted and retweeted posts", () => {
  const ids = parse.collectTweets(bookmarksResponse).map((p) => p.id);
  assert.ok(ids.includes("1700000000000000000"), "quoted post");
  assert.ok(ids.includes("1600000000000000000"), "retweeted original");
  assert.equal(new Set(ids).size, ids.length, "no duplicates");
});

test("normalizes text, author, media, metrics and quotes", () => {
  const post = parse.normalizeTweet(photoPost);
  assert.equal(post.text, "Glass & light: bending https://glass.dev/post");
  assert.equal(post.url, "https://x.com/glasslab/status/1790000000000000001");
  assert.deepEqual(post.author, { name: "Glass Lab", handle: "glasslab", avatar: "https://pbs.twimg.com/profile_images/1/glasslab_normal.jpg", verified: true });
  assert.equal(post.createdAt, "2024-05-01T10:20:30.000Z");
  assert.deepEqual(post.metrics, { likes: 100, retweets: 4, replies: 3, quotes: 2, bookmarks: 5, views: 12345 });
  assert.equal(post.media.length, 2);
  assert.deepEqual(post.media[0], { type: "photo", url: "https://pbs.twimg.com/media/A.jpg", width: 1600, height: 900, alt: "A prism", videoUrl: undefined });
  assert.equal(post.media[1].type, "video");
  assert.equal(post.media[1].videoUrl, "https://video.twimg.com/high.mp4");
  assert.equal(post.quoted.id, "1700000000000000000");
  assert.equal(post.quoted.text, "The original thought");
  assert.equal(post.quoted.author.handle, "quoter");
  assert.equal(post.quoted.quoted, undefined);
});

test("unwraps visibility results and the old user schema, trims reply mentions", () => {
  const post = parse.normalizeTweet(visibilityWrapped);
  assert.equal(post.id, "1790000000000000002");
  assert.equal(post.text, "replying here");
  assert.equal(post.author.handle, "old");
  assert.equal(post.author.avatar, "https://pbs.twimg.com/p/old_normal.png");
  assert.equal(post.author.verified, true);
});

test("retweets resolve to the original post", () => {
  const post = parse.normalizeTweet(retweet);
  assert.equal(post.id, "1600000000000000000");
  assert.equal(post.author.handle, "author");
  assert.equal(post.text, "Original 👀 text");
});

test("long posts use the full note text and cards are parsed", () => {
  const post = parse.normalizeTweet(noteTweet);
  assert.equal(post.text, "A very long post that goes past 280 characters… see https://long.example/read");
  assert.deepEqual(post.card, {
    url: "https://long.example/read",
    title: "Long read",
    description: "An article",
    image: "https://pbs.twimg.com/card.jpg",
    siteName: "long.example",
  });
});

test("display ranges count code points, not UTF-16 units", () => {
  assert.equal(parse.cleanText("👀👀 abc", { range: [3, 6] }), "abc");
  assert.equal(parse.cleanText("a &lt;b&gt; &#x1F600; &#39;q&#39;"), "a <b> 😀 'q'");
});

test("tombstones are skipped", () => {
  assert.equal(parse.normalizeTweet({ __typename: "TweetTombstone" }), null);
});

test("helpers: cursor and operation names", () => {
  assert.equal(parse.bottomCursor(bookmarksResponse), "HBaAAA==");
  assert.equal(parse.operationName("https://x.com/i/api/graphql/abc-123_x/Bookmarks?variables=%7B%7D"), "Bookmarks");
  assert.equal(parse.operationName("https://x.com/home"), null);
});
