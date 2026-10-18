import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import vm from "node:vm";
import {
  fetchCategoryTopics,
  fetchResourceCategories,
  requestJson,
} from "../javascripts/discourse/lib/resource-data.js";

const topic = (id, extra = {}) => ({
  id,
  category_id: 11,
  title: `Resource ${id}`,
  ...extra,
});
const ids = (topics) => topics.map((t) => t.id);

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
  assert.ok(result.topics.some((topic) => topic.id === 101));
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
  fetchResourceCategories,
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

test("lazy category discovery reads all pages and descendants without bootstrap data", async () => {
  const calls = [];
  const categories = await fetchResourceCategories(197, async (url) => {
    calls.push(url);
    const params = new URL(url, "https://example.test").searchParams;
    const parent = Number(params.get("parent_category_id"));
    const page = Number(params.get("page"));
    let rows = [];
    if (parent === 197 && page === 1) {
      rows = Array.from({ length: 20 }, (_, i) => ({
        id: 200 + i, slug: `state-${i}`, subcategory_ids: i === 0 ? [300] : [],
      }));
    } else if (parent === 197 && page === 2) {
      rows = [{ id: 220, slug: "last-state", subcategory_ids: [] }];
    } else if (parent === 200 && page === 1) {
      rows = [{ id: 300, slug: "child", subcategory_ids: [400] }];
    } else if (parent === 300 && page === 1) {
      rows = [{ id: 400, slug: "grandchild", subcategory_ids: [] }];
    }
    return { category_list: { categories: rows } };
  });
  assert.equal(categories.length, 23);
  assert.equal(categories.find((cat) => cat.id === 400).parent_category_id, 300);
  assert.equal(categories.find((cat) => cat.id === 220).parent_category_id, 197);
  assert.equal(calls.length, 7);
});

test("failed category discovery is not treated as an empty library", async () => {
  await assert.rejects(fetchResourceCategories(10, async () => ({})), /Invalid category/);
  await assert.rejects(fetchResourceCategories(10, async () => {
    throw new Error("offline");
  }), /offline/);
});

test("repeated category pages fail explicitly instead of looping", async () => {
  let calls = 0;
  await assert.rejects(fetchResourceCategories(10, async () => {
    calls++;
    return { category_list: { categories: [{ id: 11, subcategory_ids: [] }] } };
  }), /pagination did not advance/);
  assert.equal(calls, 2);
});

test("category discovery cancellation stops requests", async () => {
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(fetchResourceCategories(10, () => assert.fail("unexpected request"), controller.signal), { name: "AbortError" });
});

test("HTTP 429 honors Retry-After and recovers", async (t) => {
  let calls = 0;
  const start = Date.now();
  t.mock.method(globalThis, "fetch", async () => ++calls === 1
    ? new Response("busy", { status: 429, headers: { "Retry-After": "2" } })
    : Response.json({ ok: true }));
  assert.deepEqual(await requestJson("/limited"), { ok: true });
  assert.equal(calls, 2);
  assert.ok(Date.now() - start >= 1900);
});
