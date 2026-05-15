import Component from "@glimmer/component";
import ResourceLibrary from "../../components/resource-library";

export default class ResourceLibraryConnector extends Component {
  RESOURCE_CATEGORY_IDS = [10, 61];

  get shouldShow() {
    const category = this.args.outletArgs?.category;
    if (!category) {
      return false;
    }
    return this.RESOURCE_CATEGORY_IDS.includes(category.id);
  }

  get currentCategory() {
    return this.args.outletArgs?.category;
  }

  <template>
    {{#if this.shouldShow}}
      <ResourceLibrary @category={{this.currentCategory}} />
    {{/if}}
  </template>
}
