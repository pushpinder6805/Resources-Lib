import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import Composer from "discourse/models/composer";
import CategoryNode from "./category-node";

const TOPIC_FETCH_CONCURRENCY = 12;
const TOPIC_FETCH_RETRIES = 2;
const CATEGORY_TREE_DEPTH = 3;

export default class ResourceLibrary extends Component {
  @service composer;
  @service router;
  @service site;
  @service store;
  @service currentUser;

  @tracked activeRootId = 10;
  @tracked categories = [];
  @tracked topicsMap = {};
  @tracked _orderOverride = null;
  @tracked searchQuery = "";
  @tracked loading = true;

  _categoriesPromise = null;
  _loadRequestId = 0;

  get ROOTS() {
    return [
      { id: 10, label: "All Resources", title: "Resource Library" },
      { id: 61, label: "California Resources", title: "California Resource Library" },
      { id: 197, label: "All States Resources", title: "All States Resource Library" },
    ];
  }

  constructor() {
    super(...arguments);
    const category = this.args.category;
    if (category && this.ROOTS.some((root) => root.id === category.id)) {
      this.activeRootId = category.id;
    }
    this._initLoad();
  }

  async _initLoad() {
    await this.loadData();
    if (this.categories.length === 0) {
      setTimeout(() => this.loadData(), 1000);
    }
  }

  get dynamicTitle() {
    return (
      this.ROOTS.find((root) => root.id === this.activeRootId)?.title ||
      "Resource Library"
    );
  }

  get isStaffUser() {
    return this.currentUser?.staff || this.currentUser?.admin || this.currentUser?.moderator;
  }

  get topicsPerCategory() {
    return settings?.topics_per_category || 5;
  }

  getParentId(category) {
    return category.parent_category_id ?? category.parentCategory?.id ?? null;
  }

  delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async fetchAllCategories() {
    if (!this._categoriesPromise) {
      this._categoriesPromise = ajax("/categories.json")
        .then((result) => result?.category_list?.categories || [])
        .catch(() => {
          this._categoriesPromise = null;
          return [];
        });
    }
    return this._categoriesPromise;
  }

  async getAvailableCategories() {
    const siteCategories = this.site.categories || [];
    const fetchedCategories = await this.fetchAllCategories();
    const orderedCategories = [];
    const seenCategoryIds = new Set();

    const addCategory = (category) => {
      if (!category?.id || seenCategoryIds.has(category.id)) {
        return;
      }
      seenCategoryIds.add(category.id);
      orderedCategories.push(category);
    };

    const primaryCategories = fetchedCategories.length > 0 ? fetchedCategories : siteCategories;
    const fallbackCategories = fetchedCategories.length > 0 ? siteCategories : fetchedCategories;
    primaryCategories.forEach(addCategory);
    fallbackCategories.forEach(addCategory);

    return orderedCategories;
  }

  getCategoryPosition(category) {
    const position = Number(category?.position);
    return Number.isFinite(position) ? position : null;
  }

  compareCategoriesByDiscourseOrder(categoryOrder, a, b) {
    const positionA = this.getCategoryPosition(a);
    const positionB = this.getCategoryPosition(b);

    if (positionA !== null && positionB !== null && positionA !== positionB) {
      return positionA - positionB;
    }

    if (positionA !== null && positionB === null) {
      return -1;
    }

    if (positionA === null && positionB !== null) {
      return 1;
    }

    return (categoryOrder.get(a.id) ?? 0) - (categoryOrder.get(b.id) ?? 0);
  }

  buildCategoryTree(rootId, allCategories) {
    const categoriesById = new Map();
    const categoryOrder = new Map();
    const childrenByParentId = {};

    allCategories.forEach((category, index) => {
      if (!category?.id) {
        return;
      }

      categoriesById.set(category.id, category);
      categoryOrder.set(category.id, index);
      const parentId = this.getParentId(category);
      if (parentId) {
        if (!childrenByParentId[parentId]) {
          childrenByParentId[parentId] = [];
        }
        childrenByParentId[parentId].push(category);
      }
    });

    const wrap = (cat) => {
      const parentId = this.getParentId(cat);
      const parent = parentId ? categoriesById.get(parentId) : null;
      return {
        id: cat.id,
        name: cat.name,
        slug: cat.slug,
        color: cat.color,
        text_color: cat.text_color,
        description: cat.description,
        topic_count: cat.topic_count,
        parent_category_id: parentId,
        parent_slug: parent?.slug,
      };
    };

    const buildChildren = (parentId, depth = 1) => {
      return [...(childrenByParentId[parentId] || [])]
        .sort((a, b) => this.compareCategoriesByDiscourseOrder(categoryOrder, a, b))
        .map((category) => ({
          ...wrap(category),
          subcategories:
            depth < CATEGORY_TREE_DEPTH ? buildChildren(category.id, depth + 1) : [],
        }));
    };

    return buildChildren(rootId);
  }

  async loadData() {
    const requestId = ++this._loadRequestId;
    this.loading = true;
    this.topicsMap = {};
    this.categories = [];

    try {
      const allCategories = await this.getAvailableCategories();
      if (requestId !== this._loadRequestId) {
        return;
      }

      const tree = this.buildCategoryTree(this.activeRootId, allCategories);

      this.categories = tree;
      await this.loadAllTopics(tree, requestId);
    } catch (e) {
      console.error("ResourceLibrary: failed to load", e);
    } finally {
      if (requestId === this._loadRequestId) {
        this.loading = false;
      }
    }
  }

  get orderConfigMap() {
    if (this._orderOverride) return this._orderOverride;
    try {
      const raw = settings?.resource_topic_order || "{}";
      const parsed = JSON.parse(raw);
      const result = {};
      Object.keys(parsed).forEach((catId) => {
        const ids = parsed[catId];
        if (Array.isArray(ids) && ids.length > 0) {
          result[catId] = { orderedIds: ids };
        }
      });
      return result;
    } catch (e) {
      return {};
    }
  }

  getCategoryTopicUrls(cat) {
    const baseUrls = [`/c/${cat.slug}/${cat.id}`];
    if (cat.parent_slug) {
      baseUrls.push(`/c/${cat.parent_slug}/${cat.slug}/${cat.id}`);
    }

    return [...new Set(baseUrls)].flatMap((categoryUrl) => [
      `${categoryUrl}.json?per_page=30`,
      `${categoryUrl}/l/latest.json?per_page=30`,
    ]);
  }

  async fetchCategoryTopics(cat) {
    for (const topicUrl of this.getCategoryTopicUrls(cat)) {
      for (let attempt = 0; attempt <= TOPIC_FETCH_RETRIES; attempt++) {
        try {
          const res = await ajax(topicUrl);
          return {
            id: cat.id,
            topics: (res.topic_list?.topics || []).filter(
              (topic) => !this.isAboutTopic(topic)
            ),
          };
        } catch (e) {
          if (attempt < TOPIC_FETCH_RETRIES) {
            await this.delay(250 * (attempt + 1));
          }
        }
      }
    }

    return { id: cat.id, topics: [] };
  }

  async loadAllTopics(tree, requestId) {
    const leafCategories = this.getLeafCategories(tree).filter((c) => c.slug && c.id);
    const map = {};
    const queue = [...leafCategories];
    const workerCount = Math.min(TOPIC_FETCH_CONCURRENCY, queue.length);

    await Promise.all(
      Array.from({ length: workerCount }, async () => {
        while (queue.length > 0) {
          const cat = queue.shift();
          const result = await this.fetchCategoryTopics(cat).catch(() => ({
            id: cat.id,
            topics: [],
          }));
          map[result.id] = result.topics;

          if (requestId === this._loadRequestId) {
            this.topicsMap = { ...this.topicsMap, [result.id]: result.topics };
          }
        }
      })
    );

    if (requestId === this._loadRequestId) {
      this.topicsMap = map;
    }
  }

  isAboutTopic(topic) {
    return topic.title && topic.title.toLowerCase().startsWith("about the");
  }

  getLeafCategories(tree) {
    const leaves = [];
    const walk = (nodes) => {
      nodes.forEach((n) => {
        if (n.subcategories && n.subcategories.length > 0) {
          walk(n.subcategories);
        } else {
          leaves.push(n);
        }
      });
    };
    walk(tree);
    return leaves;
  }

  @action
  switchRoot(root) {
    this.activeRootId = root.id;
    this.searchQuery = "";
    this.loadData();
  }

  @action
  onSearchInput(e) {
    this.searchQuery = e.target.value;
  }

  get allowedCategoryIds() {
    const allCategories = this.site.categories || [];
    const allowed = [];
    const collectDescendants = (parentId) => {
      const children = allCategories.filter(
        (c) => this.getParentId(c) === parentId
      );
      children.forEach((child) => {
        allowed.push(child.id);
        collectDescendants(child.id);
      });
    };
    this.ROOTS.forEach((root) => collectDescendants(root.id));
    return allowed;
  }

  @action
  openNewResource() {
    const allowedIds = this.allowedCategoryIds;
    const styleId = "resource-library-composer-filter";
    let styleEl = document.getElementById(styleId);
    if (!styleEl) {
      styleEl = document.createElement("style");
      styleEl.id = styleId;
      document.head.appendChild(styleEl);
    }

    if (allowedIds.length > 0) {
      const allowSelectors = allowedIds
        .map((id) => `.category-chooser .category-row[data-value="${id}"]`)
        .join(",\n");
      styleEl.textContent = `.category-chooser .category-row { display: none !important; }\n${allowSelectors} { display: flex !important; }`;
    } else {
      styleEl.textContent = "";
    }

    this.composer.open({
      action: Composer.CREATE_TOPIC,
      draftKey: Composer.CREATE_TOPIC,
      draftSequence: 0,
    });

    this._watchComposerClose();
  }

  _watchComposerClose() {
    const styleId = "resource-library-composer-filter";
    const check = () => {
      const composerEl = document.getElementById("reply-control");
      const isClosed =
        !composerEl || composerEl.classList.contains("closed");
      if (isClosed) {
        const el = document.getElementById(styleId);
        if (el) el.remove();
      } else {
        requestAnimationFrame(check);
      }
    };
    requestAnimationFrame(check);
  }

  get filteredCategories() {
    if (!this.searchQuery.trim()) {
      return this.categories;
    }
    const q = this.searchQuery.toLowerCase();
    return this.filterTree(this.categories, q);
  }

  filterTree(cats, query) {
    return cats
      .map((cat) => {
        const filteredSubs = cat.subcategories
          ? this.filterTree(cat.subcategories, query)
          : [];

        const catTopics = this.topicsMap[cat.id] || [];
        const matchingTopics = catTopics.filter((t) =>
          t.title.toLowerCase().includes(query)
        );

        if (filteredSubs.length > 0 || matchingTopics.length > 0) {
          return { ...cat, subcategories: filteredSubs, _filteredTopics: matchingTopics };
        }
        return null;
      })
      .filter(Boolean);
  }

  @action
  async editTopic(topic) {
    try {
      const result = await ajax(`/t/${topic.id}.json`);
      const post = result.post_stream?.posts?.[0];
      if (!post) {
        alert("Could not load topic content.");
        return;
      }

      this.composer.open({
        action: Composer.EDIT,
        topic: this.store.createRecord("topic", result),
        post: this.store.createRecord("post", post),
        draftKey: `topic_${topic.id}`,
        draftSequence: 0,
      });
    } catch (e) {
      console.error("Failed to open topic for editing", e);
      alert("Failed to open topic for editing. Please try again.");
    }
  }

  @action
  async deleteTopic(topic) {
    if (!confirm(`Are you sure you want to permanently delete "${topic.title}"?`)) {
      return;
    }

    try {
      await ajax(`/t/${topic.id}`, { type: "DELETE" });
      const newMap = { ...this.topicsMap };
      Object.keys(newMap).forEach((catId) => {
        newMap[catId] = newMap[catId].filter((t) => t.id !== topic.id);
      });
      this.topicsMap = newMap;
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("Failed to delete topic", e);
      alert("Failed to delete topic. Please try again.");
    }
  }

  @action
  updateOrderConfig(categoryId, orderedIds) {
    const current = this.orderConfigMap;
    const newMap = { ...current };
    newMap[categoryId] = { orderedIds };
    this._orderOverride = newMap;
  }

  @action
  openNewCategory() {
    this.router.transitionTo("newCategory");
  }



  <template>
    <div class="resource-library">
      <div class="resource-library__header">
        <h1 class="resource-library__title">{{this.dynamicTitle}}</h1>
        <p class="resource-library__description">
          Check back here regularly for new resources and if there's something you think would be helpful to include, please let us know (send it to <a href="mailto:MASH@healthlaw.org">MASH@healthlaw.org</a>)!
        </p>
      </div>

      <div class="resource-library__controls">
        <div class="resource-library__tabs">
          {{#each this.ROOTS as |root|}}
            <button
              class="resource-library__tab {{if (eq root.id this.activeRootId) 'resource-library__tab--active'}}"
              type="button"
              {{on "click" (fn this.switchRoot root)}}
            >
              {{root.label}}
            </button>
          {{/each}}
        </div>

        <div class="resource-library__actions">
          <div class="resource-library__search">
            <input
              type="text"
              class="resource-library__search-input"
              placeholder="Search resources..."
              value={{this.searchQuery}}
              {{on "input" this.onSearchInput}}
            />
          </div>

          {{#if this.isStaffUser}}
            <button
              class="resource-library__manage-btn btn btn-icon btn-default"
              type="button"
              title="New Category"
              {{on "click" this.openNewCategory}}
            >
              <svg class="fa d-icon d-icon-wrench svg-icon" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="14" height="14"><path fill="currentColor" d="M352 320c88.4 0 160-71.6 160-160c0-15.3-2.2-30.1-6.2-44.2c-3.1-10.8-16.4-13.2-24.3-5.3l-76.8 76.8c-3 3-7.1 4.7-11.3 4.7H336c-8.8 0-16-7.2-16-16V118.6c0-4.2 1.7-8.3 4.7-11.3l76.8-76.8c7.9-7.9 5.4-21.2-5.3-24.3C382.1 2.2 367.3 0 352 0C263.6 0 192 71.6 192 160c0 19.1 3.4 37.5 9.5 54.5L19.9 396.1C7.2 408.8 0 426.1 0 444.1C0 481.6 30.4 512 67.9 512c18 0 35.3-7.2 48-19.9l181.6-181.6c17 6.2 35.4 9.5 54.5 9.5zM80 456c-13.3 0-24-10.7-24-24s10.7-24 24-24s24 10.7 24 24s-10.7 24-24 24z"/></svg>
            </button>
          {{/if}}

          <button
            class="resource-library__new-btn"
            type="button"
            {{on "click" this.openNewResource}}
          >
            + New Resource
          </button>
        </div>
      </div>

      <div class="resource-library__content">
        {{#if this.loading}}
          <div class="resource-library__loading">Loading resources...</div>
        {{else if this.filteredCategories.length}}
          {{#each this.filteredCategories as |cat|}}
            <CategoryNode
              @category={{cat}}
              @topicsMap={{this.topicsMap}}
              @orderConfigMap={{this.orderConfigMap}}
              @searchQuery={{this.searchQuery}}
              @maxTopics={{this.topicsPerCategory}}
              @isStaff={{this.isStaffUser}}
              @onDeleteTopic={{this.deleteTopic}}
              @onEditTopic={{this.editTopic}}
              @onOrderSaved={{this.updateOrderConfig}}
            />
          {{/each}}
        {{else}}
          <div class="resource-library__empty">No resources found.</div>
        {{/if}}
      </div>
    </div>
  </template>
}
