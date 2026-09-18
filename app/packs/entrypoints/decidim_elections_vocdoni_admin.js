// Admin pack.
//
// The election list is server-rendered and needs nothing from here.
// The Questions tab delegates to upstream's createEditableForm() from
// decidim-forms, which wires html5sortable and DynamicFieldsComponent.
// The census page has its own row-clone behaviour and a live security meter.
// The monitoring page has a refresh control, and the publication page
// locks its button until both confirmations are given. The Security tab
// keeps its cards and summary in step with unsaved choices.
import "stylesheets/decidim/elections/vocdoni/admin/editor.scss";
import "stylesheets/decidim/elections/vocdoni/admin/security.scss";
import "src/decidim/elections/vocdoni/admin/questions_editor";
import "src/decidim/elections/vocdoni/admin/census";
import "src/decidim/elections/vocdoni/admin/public_link";
import "src/decidim/elections/vocdoni/admin/monitor";
import "src/decidim/elections/vocdoni/admin/setup";
import "src/decidim/elections/vocdoni/admin/security";
