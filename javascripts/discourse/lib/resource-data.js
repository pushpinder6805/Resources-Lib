const RETRIES = 2;
const TIMEOUT_MS = 15000;

export function abortError() {
  return new DOMException("Resource loading cancelled", "AbortError");
}

function wait(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) return reject(abortError());
    const cancel = () => {
      clearTimeout(timer);
      reject(abortError());
    };
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", cancel);
      resolve();
    }, ms);
    signal?.addEventListener("abort", cancel, { once: true });
  });
}

export async function requestJson(url, signal) {
  for (let attempt = 0; ; attempt++) {
    if (signal?.aborted) throw abortError();
    const controller = new AbortController();
    const cancel = () => controller.abort();
    signal?.addEventListener("abort", cancel, { once: true });
    const timer = setTimeout(cancel, TIMEOUT_MS);
    let retryDelay = 1000 * 2 ** attempt;
    try {
      const response = await fetch(url, {
        credentials: "same-origin",
        headers: { accept: "application/json" },
        signal: controller.signal,
      });
      if (!response.ok) {
        const error = new Error(`Resource request failed: ${response.status}`);
        error.status = response.status;
        error.url = url;
        error.retryable = response.status === 429 || response.status >= 500;
        const retryAfter = response.headers.get("Retry-After");
        if (retryAfter) {
          const seconds = Number(retryAfter);
          retryDelay = Math.max(
            retryDelay,
            Number.isFinite(seconds)
              ? seconds * 1000
              : Date.parse(retryAfter) - Date.now() || 0,
          );
        }
        throw error;
      }
      return await response.json();
    } catch (error) {
      if (signal?.aborted) throw abortError();
      if (error.retryable === false || attempt >= RETRIES) throw error;
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", cancel);
    }
    await wait(retryDelay, signal);
  }
}

// Fetch the selected subtree explicitly: /categories.json and site.categories
// can contain only a preview when Discourse lazy-loads categories.
export async function fetchResourceCategories(rootId, request, signal, maxDepth = 3) {
  const categories = new Map();
  const queue = [{ id: rootId, depth: 0 }];
  const visited = new Set();
  while (queue.length) {
    if (signal?.aborted) throw abortError();
    const parent = queue.shift();
    if (visited.has(parent.id)) continue;
    visited.add(parent.id);
    const seenChildren = new Set();
    for (let page = 1; ; page++) {
      const result = await request(
        `/categories.json?parent_category_id=${parent.id}&include_subcategories=true&page=${page}`,
        signal,
      );
      const list = result.category_list?.categories;
      if (!Array.isArray(list)) throw new Error("Invalid category response");
      if (!list.length) break;
      const children = list.filter((cat) =>
        !cat.parent_category_id || Number(cat.parent_category_id) === Number(parent.id)
      );
      let added = 0;
      for (const child of children) {
        if (!child.id) throw new Error("Invalid category response");
        if (!seenChildren.has(child.id)) added++;
        seenChildren.add(child.id);
        categories.set(child.id, { ...child, parent_category_id: parent.id });
        if (parent.depth + 1 < maxDepth && child.subcategory_ids?.length !== 0) {
          queue.push({ id: child.id, depth: parent.depth + 1 });
        }
      }
      if (!added) throw new Error("Category pagination did not advance");
    }
  }
  return [...categories.values()];
}

export async function fetchCategoryTopics(category, request, signal) {
  const topics = new Map();
  try {
    for (let page = 0; ; page++) {
      if (signal?.aborted) throw abortError();
      // Use an explicit sort before pagination, independent of category defaults.
      const result = await request(
        `/c/${category.id}/l/latest.json?order=created&ascending=false&no_subcategories=true&per_page=100&page=${page}`,
        signal,
      );
      const list = result.topic_list;
      if (!Array.isArray(list?.topics))
        throw new Error("Invalid resource list response");
      let added = 0;
      for (const topic of list.topics) {
        if (!topics.has(topic.id)) added++;
        topics.set(topic.id, topic);
      }
      if (!list.more_topics_url || list.topics.length === 0) break;
      if (!added) throw new Error("Resource pagination did not advance");
    }
    return {
      id: category.id,
      topics: resourceTopics(topics, category),
      error: false,
    };
  } catch (error) {
    if (signal?.aborted) throw abortError();
    return {
      id: category.id,
      topics: resourceTopics(topics, category),
      error: true,
      cause: error,
    };
  }
}

function resourceTopics(topics, category) {
  const aboutId = Number(category.topic_url?.match(/\/(\d+)(?:\/\d+)?$/)?.[1]);
  return [...topics.values()].filter(
    (topic) =>
      Number(topic.category_id) === Number(category.id) &&
      topic.id !== aboutId &&
      !topic.title?.toLowerCase().startsWith("about the"),
  );
}
