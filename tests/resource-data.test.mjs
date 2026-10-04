import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {
  fetchCategoryTopics,
  flattenCategories,
  requestJson,
  sortResourceTopics,
} from "../javascripts/discourse/lib/resource-data.js";

const topic = (id, extra = {}) => ({
  id,
  category_id: 11,
  title: `Resource ${id}`,
  ...extra,
});
const ids = (topics) => topics.map((t) => t.id);

test("new resources precede saved order; existing manual order stays intact", () => {
  const topics = [topic(1), topic(2), topic(10), topic(11)];
  assert.deepEqual(ids(sortResourceTopics(topics, [2, 1])), [11, 10, 2, 1]);
  assert.deepEqual(ids(topics), [1, 2, 10, 11]);
});

test("creation date wins over activity, pins, and server order", () => {
  assert.deepEqual(
    ids(
      sortResourceTopics([
        topic(9, {
          created_at: "2020-01-01",
          bumped_at: "2030-01-01",
          pinned: true,
        }),
        topic(8, { created_at: "2026-10-04" }),
        topic(7, { created_at: "2026-10-04" }),
      ]),
    ),
    [8, 7, 9],
  );
});

test("nested category responses are flattened without bootstrap categories", () => {
  const cats = flattenCategories([
    { id: 10, subcategory_list: [{ id: 11, subcategory_list: [{ id: 12 }] }] },
  ]);
  assert.deepEqual(
    cats.map((c) => [c.id, c.parent_category_id]),
    [
      [10, undefined],
      [11, 10],
      [12, 11],
    ],
  );
});

test("loads every page, deduplicates pins, excludes other categories and about topics", async () => {
  const calls = [];
  const result = await fetchCategoryTopics({ id: 11 }, async (url) => {
    calls.push(url);
    return calls.length === 1
      ? {
          topic_list: {
            topics: Array.from({ length: 100 }, (_, i) => topic(i + 1)),
            more_topics_url: "/next",
          },
        }
      : {
          topic_list: {
            topics: [
              topic(1),
              topic(101),
              topic(102, { category_id: 12 }),
              topic(103, { title: "About the category" }),
            ],
          },
        };
  });
  assert.equal(result.error, false);
  assert.equal(result.topics.length, 101);
  assert.equal(result.topics[0].id, 101);
  assert.match(calls[0], /order=created&ascending=false&no_subcategories=true/);
  assert.match(calls[1], /page=1$/);
});

test("later page failure preserves resources and reports incomplete results", async () => {
  let calls = 0;
  const result = await fetchCategoryTopics({ id: 11 }, async () => {
    if (calls++) throw new Error("offline");
    return { topic_list: { topics: [topic(1)], more_topics_url: "/next" } };
  });
  assert.equal(result.error, true);
  assert.deepEqual(ids(result.topics), [1]);
});

test("malformed response is an error, not an empty library", async () => {
  assert.equal(
    (await fetchCategoryTopics({ id: 11 }, async () => ({}))).error,
    true,
  );
});

test("non-advancing pagination stops and reports incomplete results", async () => {
  let calls = 0;
  const result = await fetchCategoryTopics({ id: 11 }, async () => {
    calls++;
    return { topic_list: { topics: [topic(1)], more_topics_url: "/next" } };
  });
  assert.equal(calls, 2);
  assert.equal(result.error, true);
});

test("aborted loads do not issue category requests", async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    fetchCategoryTopics(
      { id: 11 },
      () => assert.fail("unexpected request"),
      controller.signal,
    ),
    { name: "AbortError" },
  );
});

test("transient requests recover automatically; forbidden requests are not retried", async (t) => {
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => {
    calls++;
    return calls === 1
      ? new Response("busy", { status: 503 })
      : Response.json({ ok: true });
  });
  assert.deepEqual(await requestJson("/test"), { ok: true });
  assert.equal(calls, 2);
  t.mock.method(globalThis, "fetch", async () => {
    calls++;
    return new Response("forbidden", { status: 403 });
  });
  await assert.rejects(requestJson("/private"), /403/);
  assert.equal(calls, 3);
});

test("rate-limit backoff is cancellable", async (t) => {
  const controller = new AbortController();
  t.mock.method(
    globalThis,
    "fetch",
    async () =>
      new Response("busy", { status: 429, headers: { "Retry-After": "60" } }),
  );
  const pending = requestJson("/test", controller.signal);
  setTimeout(() => controller.abort(), 20);
  await assert.rejects(pending, { name: "AbortError" });
});

// Exercise the actual component orchestration without a Discourse installation.
// Only framework imports, decorators, and the template are removed; this is not
// a substitute for rendering the component in Discourse.
const source =
  (
    await readFile(
      new URL(
        "../javascripts/discourse/components/resource-library.gjs",
        import.meta.url,
      ),
      "utf8",
    )
  )
    .replace(/^import .*?;\n/gm, "")
    .replace(/@service (\w+);/g, "$1;")
    .replace(/@tracked /g, "")
    .replace(/  @action\n/g, "")
    .replace("export default class", "class")
    .split("  <template>")[0] + "}\nResourceLibrary";
const ResourceLibrary = vm.runInNewContext(source, {
  Component: class {},
  AbortController,
  clearTimeout,
  console,
  fetchCategoryTopics,
  flattenCategories,
});
const library = () =>
  Object.assign(Object.create(ResourceLibrary.prototype), {
    _loadRequestId: 0,
    site: { categories: [] },
    activeRootId: 10,
  });

test("a newer root load wins over a slow stale category response", async () => {
  const lib = library();
  let finishOld;
  lib.getAvailableCategories = () =>
    new Promise((resolve) => {
      finishOld = resolve;
    });
  lib.loadAllTopics = async () => {};
  const old = lib.loadData();
  const oldSignal = lib._loadController.signal;
  lib.activeRootId = 197;
  lib.getAvailableCategories = async () => [
    { id: 198, slug: "state", parent_category_id: 197 },
  ];
  await lib.loadData();
  finishOld([{ id: 11, slug: "main", parent_category_id: 10 }]);
  await old;
  assert.equal(oldSignal.aborted, true);
  assert.equal(lib.categories[0].id, 198);
  assert.equal(lib.loading, false);
});

test("unknown/zero topic counts still load, concurrency is bounded, failures stay visible", async () => {
  const lib = library();
  lib._loadRequestId = 1;
  lib.topicsMap = {};
  let active = 0,
    peak = 0;
  lib.requestJson = async (url) => {
    active++;
    peak = Math.max(peak, active);
    await new Promise((resolve) => setTimeout(resolve, 5));
    active--;
    if (url.includes("/c/12/")) throw new Error("offline");
    const catId = Number(url.match(/\/c\/(\d+)/)[1]);
    return { topic_list: { topics: [topic(catId, { category_id: catId })] } };
  };
  const tree = Array.from({ length: 8 }, (_, i) => ({
    id: i + 11,
    slug: "category",
    topic_count: 0,
  }));
  await lib.loadAllTopics(tree, 1, new AbortController().signal);
  assert.equal(peak, 3);
  assert.equal(Object.keys(lib.topicsMap).length, 8);
  assert.equal(lib.loadError, true);
  assert.equal(lib.topicsMap[11][0].id, 11);
});
