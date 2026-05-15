import Component from "@glimmer/component";

const RESOURCE_ROOT_IDS = [10, 61];

export default class ResourceTopicBanner extends Component {
  get topic() {
    return this.args.model;
  }

  get category() {
    return this.topic?.category;
  }

  get isResourceTopic() {
    const cat = this.category;
    if (!cat) {
      return false;
    }
    let current = cat;
    while (current) {
      if (RESOURCE_ROOT_IDS.includes(current.id)) {
        return true;
      }
      current = current.parentCategory;
    }
    return false;
  }

  get categoryBreadcrumbs() {
    const crumbs = [];
    let current = this.category;
    while (current) {
      if (!RESOURCE_ROOT_IDS.includes(current.id)) {
        crumbs.unshift(current);
      }
      current = current.parentCategory;
    }
    return crumbs;
  }

  get topicTitle() {
    return this.topic?.title || "";
  }

  get backUrl() {
    let current = this.category;
    while (current) {
      if (RESOURCE_ROOT_IDS.includes(current.id)) {
        return `/c/${current.slug}/${current.id}`;
      }
      current = current.parentCategory;
    }
    return "/c/resources/resource-library/10";
  }

  get firstPostContent() {
    return this.topic?.postStream?.posts?.[0]?.cooked || "";
  }

  <template>
    {{#if this.isResourceTopic}}
      <div class="resource-topic-view">
        <a href={{this.backUrl}} class="resource-topic-view__back">
          &lsaquo; Back to Resource Library
        </a>

        <div class="resource-topic-view__banner">
          <div class="resource-topic-view__banner-content">
            <div class="resource-topic-view__tags">
              {{#each this.categoryBreadcrumbs as |cat|}}
                <span class="resource-topic-view__tag">{{cat.name}}</span>
              {{/each}}
            </div>
            <h1 class="resource-topic-view__title">{{this.topicTitle}}</h1>
          </div>
        </div>
      </div>
    {{/if}}
  </template>
}
