// Admin pack.
//
// The election list is server-rendered and needs nothing from here.
// The Questions tab delegates to upstream's createEditableForm() from
// decidim-forms, which wires html5sortable and DynamicFieldsComponent.
// The census page has its own row-clone behaviour and a live security meter.
// The monitoring page has a refresh control, and the publication page
// locks its button until both confirmations are given.
import "stylesheets/decidim/secure_elections/admin/editor.scss";
import "src/decidim/secure_elections/admin/questions_editor";
import "src/decidim/secure_elections/admin/census";
import "src/decidim/secure_elections/admin/public_link";
import "src/decidim/secure_elections/admin/monitor";
import "src/decidim/secure_elections/admin/setup";
