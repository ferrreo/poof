# Use one typed body slot for layouts

A layout template is a comptime-known complete HTML document with its own
concrete `LayoutView`. It contains exactly one unconditional body slot in
normal HTML data context inside `body`. A route fills that slot with one
comptime-known body template having its own `BodyView`, and the handler supplies
both values explicitly.

The compiler composes the layout, body, and partial DAG into one graph and
validates its fields, parser contexts, assets, and output bounds together. The
body slot is typed template composition, not `TrustedHtml`, and it cannot occur
inside a conditional or loop where it could disappear or repeat.

Version one has no runtime layout selection, ambient shared view, nested layout
inheritance, or arbitrary named slots. Per-page title, metadata, and asset
selection use explicit `LayoutView` fields or another static layout. A body
template can also render directly when a fragment response is required.

This covers the common page-shell workflow without adding an inheritance
language or cross-template scope rules. Applications needing several structural
slots trade some layout variants or typed layout data for a closed graph and
locally provable escaping.
