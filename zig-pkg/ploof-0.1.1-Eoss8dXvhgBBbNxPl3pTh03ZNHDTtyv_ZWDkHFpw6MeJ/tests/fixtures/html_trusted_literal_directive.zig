const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.Html.TrustedHtml(64).literal("{{ view.title }}");
}
