const ploof = @import("ploof_compile").ploof;

comptime {
    _ = ploof.Html.TrustedHtml(1).literal("<b></b>");
}
