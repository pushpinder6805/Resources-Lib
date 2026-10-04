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

export function flattenCategories(categories) {
  const result = new Map();
  const visit = (category, parentId) => {
    if (!category?.id) return;
    result.set(
      category.id,
      parentId && !category.parent_category_id
        ? { ...category, parent_category_id: parentId }
        : category,
    );
    (category.subcategory_list || []).forEach((child) =>
      visit(child, category.id),
    );
  };
  categories.forEach((category) => visit(category));
  return [...result.values()];
}

export function sortResourceTopics(topics, orderedIds = []) {
  const positions = new Map(
    (orderedIds || []).map((id, index) => [Number(id), index]),
  );
  return [...topics].sort((a, b) => {
    const aPosition = positions.get(Number(a.id));
    const bPosition = positions.get(Number(b.id));
    if (aPosition !== undefined && bPosition !== undefined)
      return aPosition - bPosition;
    if (aPosition !== undefined) return 1;
    if (bPosition !== undefined) return -1;
    const dateA = Date.parse(a.created_at) || 0;
    const dateB = Date.parse(b.created_at) || 0;
    return dateB - dateA || Number(b.id) - Number(a.id);
  });
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
    };
  }
}

function resourceTopics(topics, category) {
  const aboutId = Number(category.topic_url?.match(/\/(\d+)(?:\/\d+)?$/)?.[1]);
  return sortResourceTopics(
    [...topics.values()].filter(
      (topic) =>
        Number(topic.category_id) === Number(category.id) &&
        topic.id !== aboutId &&
        !topic.title?.toLowerCase().startsWith("about the"),
    ),
  );
}
