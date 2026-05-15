import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";

export default class CategoryNode extends Component {
  get topics() {
    const map = this.args.topicsMap || {};
    return map[this.args.category.id] || [];
  }

  get visibleTopics() {
    let topics = this.topics;
    const query = this.args.searchQuery?.toLowerCase();
    if (query) {
      topics = topics.filter((t) => t.title.toLowerCase().includes(query));
      return topics;
    }
    const max = this.args.maxTopics || 5;
    return topics.slice(0, max);
  }

  get subcategories() {
    return this.args.category.subcategories || [];
  }

  get categoryUrl() {
    const cat = this.args.category;
    return `/c/${cat.slug}/${cat.id}`;
  }

  <template>
    <div class="category-node">
      <div class="category-node__header">
        <span class="category-node__color" style="background-color: #{{@category.color}};"></span>
        <h2 class="category-node__name">{{@category.name}}</h2>
      </div>

      {{#if this.subcategories.length}}
        <div class="category-node__children">
          {{#each this.subcategories as |subCat|}}
            <CategoryNode
              @category={{subCat}}
              @topicsMap={{@topicsMap}}
              @searchQuery={{@searchQuery}}
              @maxTopics={{@maxTopics}}
              @isStaff={{@isStaff}}
              @onDeleteTopic={{@onDeleteTopic}}
            />
          {{/each}}
        </div>
      {{else}}
        {{#if this.visibleTopics.length}}
          <ul class="category-node__topics">
            {{#each this.visibleTopics as |topic|}}
              <li class="category-node__topic">
                <a href="/t/{{topic.slug}}/{{topic.id}}" class="category-node__topic-link">
                  {{topic.title}}
                </a>
                {{#if @isStaff}}
                  <button
                    class="category-node__delete-btn"
                    type="button"
                    title="Permanently delete this topic"
                    {{on "click" (fn @onDeleteTopic topic)}}
                  >
                    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 448 512" width="12" height="12">
                      <path fill="currentColor" d="M135.2 17.7L128 32H32C14.3 32 0 46.3 0 64S14.3 96 32 96H416c17.7 0 32-14.3 32-32s-14.3-32-32-32H320l-7.2-14.3C307.4 6.8 296.3 0 284.2 0H163.8c-12.1 0-23.2 6.8-28.6 17.7zM416 128H32L53.2 467c1.6 25.3 22.6 45 47.9 45H346.9c25.3 0 46.3-19.7 47.9-45L416 128z"/>
                    </svg>
                  </button>
                {{/if}}
              </li>
            {{/each}}
          </ul>
        {{/if}}
      {{/if}}
    </div>
  </template>
}
