# Resource Library

Discourse theme component for the main, California, and all-states resource libraries.

## Loading and ordering

- Fetch nested categories explicitly, including categories whose cached topic counts are missing or zero.
- Load all topic pages with three concurrent category workers. Render completed categories while remaining requests finish.
- Retry network failures, HTTP 429, and server errors up to twice, with backoff, `Retry-After` support, and a 15-second timeout per attempt.
- Cancel outdated loads when switching libraries or leaving the page. Recreate the library when navigation changes the root category.
- Preserve successfully loaded topics if another page/category fails and show a Retry button for incomplete results.
- Request topics by creation date, newest first, excluding subcategory topics from parent lists. Resources absent from a saved staff order appear first, newest first; previously ordered resources retain their saved relative order.
- Hide the default discovery list only while the resource component is present.

## Regression checks

Requires Node.js 22.7 or later; no dependencies are needed:

```sh
node --test tests/resource-data.test.mjs
```

The tests cover data loading, ordering, request recovery/cancellation, and component orchestration with framework bindings removed. They do not render Ember components or replace testing on a Discourse instance.

Before deploying, preview this branch on Discourse and check direct loads and navigation across all three libraries as an anonymous visitor (if allowed), member, and staff user. Check a category with more than 100 topics, create a resource in a manually ordered category, switch tabs during loading, and simulate a failed request. Confirm newest resources appear first and existing staff ordering is preserved.
