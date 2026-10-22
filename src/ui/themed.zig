//! Themed: gives the widgets below it a theme of its own, in place of the
//! app's (or that of a `Themed` further up), along with the menus,
//! tooltips and drags they make. To change a colour or two of the theme
//! the widgets would be in:
//!
//!     var t = cx.theme().*;
//!     if (t.brightness == .dark) t.@"error" = .rgb(0xff5449);
//!     return cx.make(Themed{ .theme = t, .child = ... });

const widget = @import("widget.zig");
const Theme = @import("theme.zig").Theme;
const SizedBox = @import("sized_box.zig").SizedBox;

const Widget = widget.Widget;
const Context = widget.BuildContext;

/// Gives the widgets below it a theme of their own (a changed `cx.theme()`, say).
///
/// ![The Themed example](images/Themed.png)
///
/// ```zig
/// return cx.make(kete.Themed{ .theme = .dark, .child = cx.make(kete.Card{
///     .child = cx.make(kete.Row{ .fill = false, .spacing = 12, .children = cx.makeAll(.{
///         kete.Text{ .text = "Dark inside", .wrap = false },
///         kete.FilledButton{ .label = "Go", .on_press = .of(state, State.save) },
///     }) }),
/// }) });
/// ```
pub const Themed = struct {
    /// The theme the widgets below it are in.
    theme: Theme,
    /// The widget in it.
    child: ?Widget = null,

    pub const State = struct {
        /// Its theme, kept where the nodes below can point to it.
        theme: Theme = .dark,
    };

    pub fn build(self: *const Themed, cx: *Context, state: *State) Widget {
        state.theme = self.theme;
        // Its node's, for the nodes below to take.
        if (cx.node) |n| n.theme_ptr = &state.theme;
        cx.theme_ptr = &state.theme;
        return self.child orelse cx.make(SizedBox.empty);
    }
};
