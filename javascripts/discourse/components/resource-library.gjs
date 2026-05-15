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

export default class ResourceLibrary extends Component {
  @service composer;
  @service router;
  @service site;
  @service currentUser;

  @tracked activeRootId = 10;
  @tracked categories = [];
  @tracked topicsMap = {};
  @tracked searchQuery = "";
  @tracked loading = true;

  ROOTS = [
    { id: 10, label: "All Resources" },
    { id: 61, label: "California Resources" },
  ];

  constructor() {
    super(...arguments);
    const category = this.args.category;
    if (category && category.id === 61) {
      this.activeRootId = 61;
    }
    this._initLoad();
  }

  async _initLoad() {
    await this.loadData();
    if (this.categories.length === 0 && this.site.categories?.length === 0) {
      setTimeout(() => this.loadData(), 1000);
    }
  }

  get dynamicTitle() {
    if (this.activeRootId === 61) {
      return "California Resource Library";
    }
    return "Resource Library";
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

  async loadData() {
    this.loading = true;
    this.topicsMap = {};
    this.categories = [];

    try {
      const allCategories = this.site.categories || [];
      const children = allCategories.filter(
        (c) => this.getParentId(c) === this.activeRootId
      );

      const tree = children.map((parent) => {
        const subs = allCategories.filter(
          (c) => this.getParentId(c) === parent.id
        );
        return {
          ...parent,
          subcategories: subs.map((sub) => {
            const subSubs = allCategories.filter(
              (c) => this.getParentId(c) === sub.id
            );
            return { ...sub, subcategories: subSubs };
          }),
        };
      });

      this.categories = tree;
      await this.loadAllTopics(tree);
    } catch (e) {
      // eslint-disable-next-line no-console
      console.error("ResourceLibrary: failed to load", e);
    } finally {
      this.loading = false;
    }
  }

  async loadAllTopics(tree) {
    const leafCategories = this.getLeafCategories(tree);
    const map = {};

    const batches = [];
    for (let i = 0; i < leafCategories.length; i += 5) {
      batches.push(leafCategories.slice(i, i + 5));
    }

    for (const batch of batches) {
      const results = await Promise.all(
        batch.map((cat) =>
          ajax(`/c/${cat.slug}/${cat.id}/l/latest.json?per_page=30`)
            .then((res) => ({ id: cat.id, topics: res.topic_list?.topics || [] }))
            .catch(() => ({ id: cat.id, topics: [] }))
        )
      );
      results.forEach((r) => {
        map[r.id] = r.topics.filter((t) => !this.isAboutTopic(t));
      });
    }

    this.topicsMap = map;
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
              @searchQuery={{this.searchQuery}}
              @maxTopics={{this.topicsPerCategory}}
              @isStaff={{this.isStaffUser}}
              @onDeleteTopic={{this.deleteTopic}}
            />
          {{/each}}
        {{else}}
          <div class="resource-library__empty">No resources found.</div>
        {{/if}}
      </div>
    </div>
  </template>
}
