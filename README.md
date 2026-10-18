# Resource Library

Discourse theme component for the main, California, and all-states resource libraries.

## Loading fix

Based on `agent/new-resources-first` (e4bb13c). Retains its topic ordering and existing layout.

- Fetch the selected category subtree explicitly, including every category page, without depending on categories already loaded in the browser. Load categories even when their cached topic count is missing or zero.
- Fetch every topic page with three concurrent category workers instead of twelve. Request the explicit latest list, newest created first, with subcategory topics excluded from parent lists.
- Retry network failures, HTTP 429, and server errors twice with backoff, Retry-After support, and a 15-second timeout per attempt. Do not retry permission errors.
- Cancel outdated requests when switching libraries or leaving the page. Recreate the library when navigation changes its root category.
- Preserve successful topic pages when a later page fails. Display an incomplete-results message with Retry, and log the failed category and request error for diagnosis.

## Regression checks

Requires Node.js 22.7 or later; no dependencies are needed:

```sh
node --test tests/resource-data.test.mjs
```

These checks exercise loading helpers and component orchestration with framework bindings removed. They do not compile/render Ember or replace a Discourse integration test.

## Deployment verification

Update the theme component from `agent/new-resources-first` in Discourse. Verify fresh member login, direct navigation, all three libraries, a category with over 100 topics, switching during loading, and simulated failed requests. Admin visibility alone is not proof of member correctness.

The old code demonstrably skips missing/zero counts, ignores pagination, and turns exhausted requests into empty successful lists. Production throttling, category lazy loading, and account permissions remain possible triggers until actual responses are inspected; no production server was accessed for this fix.
