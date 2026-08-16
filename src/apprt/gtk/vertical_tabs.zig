const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const i18n = @import("../../os/main.zig").i18n;
const ext = @import("ext.zig");
const gtk_version = @import("gtk_version.zig");
const Tab = @import("class/tab.zig").Tab;

// GTK dispatches all DND callbacks on the main thread, so this transient state
// does not need locking. The page remains owned by its AdwTabView during DND.
var active_drag_page: ?*adw.TabPage = null;
var active_drag_root: ?*gtk.Widget = null;
var active_gap: ?*gtk.Revealer = null;
var active_drop_page: ?*adw.TabPage = null;
var active_drop_after: bool = false;

const list_item_data_key = "ghostty-vertical-tab-list-item";
const transition_duration_ms = 180;

const RowParts = struct {
    root: *gtk.Box,
    before: *gtk.Revealer,
    content: *gtk.Revealer,
    row: *gtk.Box,
    after: *gtk.Revealer,
};

pub fn enabled(location: configpkg.Config.GtkTabsLocation) bool {
    return switch (location) {
        .left, .right => true,
        .top, .bottom => false,
    };
}

pub fn initialVisibility(
    policy: configpkg.Config.WindowShowTabBar,
    tab_count: c_int,
) bool {
    return switch (policy) {
        .always => true,
        .auto => tab_count > 1,
        .never => false,
    };
}

pub fn setup(list: *gtk.ListView) void {
    const factory = gtk.SignalListItemFactory.new();
    defer factory.unref();

    _ = gtk.SignalListItemFactory.signals.setup.connect(
        factory,
        ?*anyopaque,
        factorySetup,
        null,
        .{},
    );
    _ = gtk.SignalListItemFactory.signals.bind.connect(
        factory,
        ?*anyopaque,
        factoryBind,
        null,
        .{},
    );
    _ = gtk.SignalListItemFactory.signals.unbind.connect(
        factory,
        ?*anyopaque,
        factoryUnbind,
        null,
        .{},
    );
    list.setFactory(factory.as(gtk.ListItemFactory));

    // Keep one target on the list. A target on every row makes GTK render the
    // hovered tab as a container that can accept another tab.
    const drop_target = gtk.DropTarget.new(
        adw.TabPage.getGObjectType(),
        .{ .move = true },
    );
    _ = gtk.DropTarget.signals.drop.connect(
        drop_target,
        *gtk.ListView,
        drop,
        list,
        .{},
    );
    list.as(gtk.Widget).addController(drop_target.as(gtk.EventController));

    const drop_motion = gtk.DropControllerMotion.new();
    _ = gtk.DropControllerMotion.signals.motion.connect(
        drop_motion,
        *gtk.ListView,
        dropMotion,
        list,
        .{},
    );
    _ = gtk.DropControllerMotion.signals.leave.connect(
        drop_motion,
        ?*anyopaque,
        dropLeave,
        null,
        .{},
    );
    list.as(gtk.Widget).addController(drop_motion.as(gtk.EventController));
}

fn factorySetup(
    _: *gtk.SignalListItemFactory,
    object: *gobject.Object,
    _: ?*anyopaque,
) callconv(.c) void {
    const list_item = gobject.ext.cast(gtk.ListItem, object) orelse return;
    const root = gtk.Box.new(.vertical, 0);
    root.as(gtk.Widget).addCssClass("vertical-tab-container");
    root.as(gobject.Object).setData(list_item_data_key, list_item);

    const before = createGap();
    root.append(before.as(gtk.Widget));

    const content = gtk.Revealer.new();
    content.setTransitionType(.slide_up);
    content.setTransitionDuration(transition_duration_ms);
    content.setRevealChild(@intFromBool(true));

    const box = gtk.Box.new(.horizontal, 8);
    box.as(gtk.Widget).addCssClass("vertical-tab-row");

    const label = gtk.Label.new(null);
    label.setEllipsize(.end);
    label.setSingleLineMode(@intFromBool(true));
    label.setXalign(0);
    label.as(gtk.Widget).setHexpand(@intFromBool(true));
    box.append(label.as(gtk.Widget));

    const attention = gtk.Image.newFromIconName("dialog-information-symbolic");
    attention.as(gtk.Widget).addCssClass("vertical-tab-attention");
    box.append(attention.as(gtk.Widget));

    const close_button = gtk.Button.newFromIconName("window-close-symbolic");
    close_button.as(gtk.Widget).addCssClass("flat");
    close_button.as(gtk.Widget).addCssClass("vertical-tab-close");
    close_button.as(gtk.Widget).setTooltipText(i18n._("Close Tab"));
    close_button.as(gtk.Widget).setCanFocus(@intFromBool(false));
    _ = gtk.Button.signals.clicked.connect(
        close_button,
        *gtk.ListItem,
        closeClicked,
        list_item,
        .{},
    );
    box.append(close_button.as(gtk.Widget));

    const primary_click = gtk.GestureClick.new();
    primary_click.as(gtk.GestureSingle).setButton(1);
    _ = gtk.GestureClick.signals.released.connect(
        primary_click,
        *gtk.ListItem,
        primaryClickReleased,
        list_item,
        .{},
    );
    box.as(gtk.Widget).addController(primary_click.as(gtk.EventController));

    const middle_click = gtk.GestureClick.new();
    middle_click.as(gtk.GestureSingle).setButton(2);
    _ = gtk.GestureClick.signals.released.connect(
        middle_click,
        *gtk.ListItem,
        middleClickReleased,
        list_item,
        .{},
    );
    box.as(gtk.Widget).addController(middle_click.as(gtk.EventController));

    const secondary_click = gtk.GestureClick.new();
    secondary_click.as(gtk.GestureSingle).setButton(3);
    _ = gtk.GestureClick.signals.pressed.connect(
        secondary_click,
        *gtk.ListItem,
        secondaryClickPressed,
        list_item,
        .{},
    );
    box.as(gtk.Widget).addController(secondary_click.as(gtk.EventController));

    const pointer_motion = gtk.EventControllerMotion.new();
    _ = gtk.EventControllerMotion.signals.enter.connect(
        pointer_motion,
        *gtk.ListItem,
        pointerEntered,
        list_item,
        .{},
    );
    _ = gtk.EventControllerMotion.signals.leave.connect(
        pointer_motion,
        *gtk.ListItem,
        pointerLeft,
        list_item,
        .{},
    );
    box.as(gtk.Widget).addController(pointer_motion.as(gtk.EventController));

    const drag_source = gtk.DragSource.new();
    drag_source.setActions(.{ .move = true });
    _ = gtk.DragSource.signals.prepare.connect(
        drag_source,
        *gtk.ListItem,
        dragPrepare,
        list_item,
        .{},
    );
    _ = gtk.DragSource.signals.drag_begin.connect(
        drag_source,
        *gtk.ListItem,
        dragBegin,
        list_item,
        .{},
    );
    _ = gtk.DragSource.signals.drag_end.connect(
        drag_source,
        ?*anyopaque,
        dragEnd,
        null,
        .{},
    );
    box.as(gtk.Widget).addController(drag_source.as(gtk.EventController));

    content.setChild(box.as(gtk.Widget));
    root.append(content.as(gtk.Widget));

    const after = createGap();
    root.append(after.as(gtk.Widget));

    list_item.setChild(root.as(gtk.Widget));
}

fn createGap() *gtk.Revealer {
    const gap = gtk.Revealer.new();
    gap.setTransitionType(.slide_down);
    gap.setTransitionDuration(transition_duration_ms);
    const spacer = gtk.Box.new(.vertical, 0);
    spacer.as(gtk.Widget).addCssClass("vertical-tab-placeholder");
    gap.setChild(spacer.as(gtk.Widget));
    return gap;
}

fn factoryBind(
    _: *gtk.SignalListItemFactory,
    object: *gobject.Object,
    _: ?*anyopaque,
) callconv(.c) void {
    const list_item = gobject.ext.cast(gtk.ListItem, object) orelse return;
    const page = getPage(list_item) orelse return;

    inline for (&.{ "title", "tooltip", "needs-attention", "selected" }) |detail| {
        _ = gobject.Object.signals.notify.connect(
            page,
            *gtk.ListItem,
            pageNotify,
            list_item,
            .{ .detail = detail },
        );
    }
    update(list_item);
}

fn factoryUnbind(
    _: *gtk.SignalListItemFactory,
    object: *gobject.Object,
    _: ?*anyopaque,
) callconv(.c) void {
    const list_item = gobject.ext.cast(gtk.ListItem, object) orelse return;
    const page = getPage(list_item) orelse return;
    _ = gobject.signalHandlersDisconnectMatched(
        page.as(gobject.Object),
        .{ .data = true },
        0,
        0,
        null,
        null,
        list_item,
    );
}

fn pageNotify(
    _: *adw.TabPage,
    _: *gobject.ParamSpec,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    update(list_item);
}

fn update(list_item: *gtk.ListItem) void {
    const page = getPage(list_item) orelse return;
    const parts = getRowParts(list_item) orelse return;
    const box = parts.row;
    const label = gobject.ext.cast(
        gtk.Label,
        box.as(gtk.Widget).getFirstChild() orelse return,
    ) orelse return;
    const attention = label.as(gtk.Widget).getNextSibling() orelse return;
    const close_button = attention.getNextSibling() orelse return;

    const title = page.getTitle();
    const tooltip = if (page.getTooltip()) |value|
        if (value[0] == 0) title else value
    else
        title;
    label.setLabel(title);
    box.as(gtk.Widget).setTooltipText(tooltip);
    attention.setVisible(page.getNeedsAttention());
    close_button.setVisible(@intFromBool(
        page.getSelected() != 0 or
            box.as(gtk.Widget).hasCssClass("vertical-tab-hover") != 0,
    ));
    if (comptime gtk_version.atLeast(4, 12, 0)) {
        list_item.setAccessibleLabel(title);
    }
}

fn closeClicked(_: *gtk.Button, list_item: *gtk.ListItem) callconv(.c) void {
    closePage(list_item);
}

fn primaryClickReleased(
    gesture: *gtk.GestureClick,
    _: c_int,
    x: f64,
    y: f64,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    if (!clickIsInside(gesture, list_item, x, y)) return;
    const page = getPage(list_item) orelse return;
    const tab_view = getView(page) orelse return;
    tab_view.setSelectedPage(page);

    const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;
    if (tab.getActiveSurface()) |surface| {
        _ = surface.as(gtk.Widget).grabFocus();
    }
}

fn middleClickReleased(
    gesture: *gtk.GestureClick,
    _: c_int,
    x: f64,
    y: f64,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    if (!clickIsInside(gesture, list_item, x, y)) return;
    closePage(list_item);
}

fn secondaryClickPressed(
    _: *gtk.GestureClick,
    _: c_int,
    x: f64,
    y: f64,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    const page = getPage(list_item) orelse return;
    const tab_view = getView(page) orelse return;
    tab_view.setSelectedPage(page);
    const row = getRowParts(list_item) orelse return;

    const menu = gio.Menu.new();
    defer menu.unref();
    menu.append(i18n._("Change Tab Title…"), "win.prompt-tab-title");

    const popover_menu = gtk.PopoverMenu.newFromModel(menu.as(gio.MenuModel));
    const popover = popover_menu.as(gtk.Popover);
    popover.setHasArrow(@intFromBool(false));
    popover.as(gtk.Widget).setParent(row.row.as(gtk.Widget));
    _ = gtk.Popover.signals.closed.connect(
        popover,
        ?*anyopaque,
        popoverClosed,
        null,
        .{},
    );

    const rect: gdk.Rectangle = .{
        .f_x = @intFromFloat(x),
        .f_y = @intFromFloat(y),
        .f_width = 1,
        .f_height = 1,
    };
    popover.setPointingTo(&rect);
    popover.popup();
}

fn pointerEntered(
    _: *gtk.EventControllerMotion,
    _: f64,
    _: f64,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    const row = getRowParts(list_item) orelse return;
    row.row.as(gtk.Widget).addCssClass("vertical-tab-hover");
    update(list_item);
}

fn pointerLeft(
    _: *gtk.EventControllerMotion,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    const row = getRowParts(list_item) orelse return;
    row.row.as(gtk.Widget).removeCssClass("vertical-tab-hover");
    update(list_item);
}

fn popoverClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
    popover.as(gtk.Widget).unparent();
}

fn clickIsInside(
    gesture: *gtk.GestureClick,
    list_item: *gtk.ListItem,
    x: f64,
    y: f64,
) bool {
    if (gesture.as(gtk.Gesture).isRecognized() == 0) return false;
    const row = list_item.getChild() orelse return false;
    return x >= 0 and y >= 0 and
        x < @as(f64, @floatFromInt(row.getWidth())) and
        y < @as(f64, @floatFromInt(row.getHeight()));
}

fn closePage(list_item: *gtk.ListItem) void {
    const page = getPage(list_item) orelse return;
    const tab_view = getView(page) orelse return;
    tab_view.closePage(page);
}

fn dragPrepare(
    _: *gtk.DragSource,
    _: f64,
    _: f64,
    list_item: *gtk.ListItem,
) callconv(.c) ?*gdk.ContentProvider {
    const page = getPage(list_item) orelse return null;

    var value: gobject.Value = std.mem.zeroes(gobject.Value);
    _ = value.init(adw.TabPage.getGObjectType());
    defer value.unset();
    value.setObject(page.as(gobject.Object));
    return gdk.ContentProvider.newForValue(&value);
}

fn dragBegin(
    _: *gtk.DragSource,
    drag: *gdk.Drag,
    list_item: *gtk.ListItem,
) callconv(.c) void {
    const page = getPage(list_item) orelse return;
    active_drag_page = page;
    const parts = getRowParts(list_item) orelse return;
    active_drag_root = parts.root.as(gtk.Widget);
    if (parts.root.as(gtk.Widget).getParent()) |row| {
        row.addCssClass("vertical-tab-drag-origin");
    }

    // The drag icon is the only visible copy of the source tab while its slot
    // remains in the list.
    const icon_box = gtk.Box.new(.horizontal, 8);
    icon_box.as(gtk.Widget).addCssClass("vertical-tab-drag-icon");
    icon_box.as(gtk.Widget).setSizeRequest(parts.row.as(gtk.Widget).getWidth(), -1);
    const label = gtk.Label.new(page.getTitle());
    label.setEllipsize(.end);
    label.setSingleLineMode(@intFromBool(true));
    label.setXalign(0);
    label.as(gtk.Widget).setHexpand(@intFromBool(true));
    icon_box.append(label.as(gtk.Widget));
    const close = gtk.Image.newFromIconName("window-close-symbolic");
    icon_box.append(close.as(gtk.Widget));
    gtk.DragIcon.getForDrag(drag).setChild(icon_box.as(gtk.Widget));
}

fn dragEnd(
    _: *gtk.DragSource,
    _: *gdk.Drag,
    _: c_int,
    _: ?*anyopaque,
) callconv(.c) void {
    resetDragVisuals();
}

fn dropMotion(
    motion: *gtk.DropControllerMotion,
    x: f64,
    y: f64,
    list: *gtk.ListView,
) callconv(.c) void {
    if (motion.getDrop() == null) return;
    const source_page = active_drag_page orelse return;
    const list_item = getListItemAt(list, x, y) orelse return;
    const target_page = getPage(list_item) orelse return;
    if (source_page == target_page) {
        setGap(null, null, false);
        return;
    }

    const parts = getRowParts(list_item) orelse return;
    const after = pointerIsAfter(list, parts.row.as(gtk.Widget), x, y);
    setGap(parts, target_page, after);
}

fn dropLeave(
    _: *gtk.DropControllerMotion,
    _: ?*anyopaque,
) callconv(.c) void {
    setGap(null, null, false);
}

fn setGap(parts: ?RowParts, page: ?*adw.TabPage, after: bool) void {
    const next = if (parts) |value|
        if (after) value.after else value.before
    else
        null;
    if (active_gap == next) return;

    if (active_gap) |gap| gap.setRevealChild(@intFromBool(false));
    active_gap = next;
    active_drop_page = page;
    active_drop_after = after;

    if (active_drag_root) |root| {
        const source_parts = getRowPartsFromRoot(root) orelse return;
        source_parts.content.setRevealChild(@intFromBool(next == null));
    }
    if (next) |gap| gap.setRevealChild(@intFromBool(true));
}

fn resetDragVisuals() void {
    if (active_gap) |gap| {
        gap.setTransitionDuration(0);
        gap.setRevealChild(@intFromBool(false));
        gap.setTransitionDuration(transition_duration_ms);
    }
    if (active_drag_root) |root| {
        if (getRowPartsFromRoot(root)) |parts| {
            parts.content.setTransitionDuration(0);
            parts.content.setRevealChild(@intFromBool(true));
            parts.content.setTransitionDuration(transition_duration_ms);
        }
        if (root.getParent()) |row| {
            row.removeCssClass("vertical-tab-drag-origin");
        }
    }

    active_drag_page = null;
    active_drag_root = null;
    active_gap = null;
    active_drop_page = null;
    active_drop_after = false;
}

fn drop(
    _: *gtk.DropTarget,
    value: *gobject.Value,
    x: f64,
    y: f64,
    list: *gtk.ListView,
) callconv(.c) c_int {
    const source_page = gobject.ext.cast(
        adw.TabPage,
        value.getObject() orelse return 0,
    ) orelse return 0;
    const list_item = getListItemAt(list, x, y) orelse return 0;
    const target_page = getPage(list_item) orelse return 0;
    if (source_page == target_page) {
        resetDragVisuals();
        return 1;
    }

    const source_view = getView(source_page) orelse return 0;
    const target_view = getView(target_page) orelse return 0;

    var position = target_view.getPagePosition(target_page);
    const after = if (active_drop_page == target_page)
        active_drop_after
    else blk: {
        const parts = getRowParts(list_item) orelse return 0;
        break :blk pointerIsAfter(list, parts.row.as(gtk.Widget), x, y);
    };
    if (after) position += 1;

    resetDragVisuals();

    if (source_view == target_view) {
        const source_position = source_view.getPagePosition(source_page);
        if (source_position < position) position -= 1;
        position = @min(position, source_view.getNPages() - 1);
        _ = source_view.reorderPage(source_page, position);
    } else {
        source_view.transferPage(source_page, target_view, position);
        target_view.setSelectedPage(source_page);
    }

    return 1;
}

fn getListItemAt(list: *gtk.ListView, x: f64, y: f64) ?*gtk.ListItem {
    var current = list.as(gtk.Widget).pick(x, y, .{
        .insensitive = true,
        .non_targetable = true,
    });
    while (current) |widget| : (current = widget.getParent()) {
        if (widget.hasCssClass("vertical-tab-container") != 0) {
            const data = widget.as(gobject.Object).getData(list_item_data_key) orelse
                return null;
            return @ptrCast(@alignCast(data));
        }
        if (widget == list.as(gtk.Widget)) return null;
    }
    return null;
}

fn pointerIsAfter(
    list: *gtk.ListView,
    row: *gtk.Widget,
    x: f64,
    y: f64,
) bool {
    var translated_y: f64 = 0;
    if (list.as(gtk.Widget).translateCoordinates(
        row,
        x,
        y,
        null,
        &translated_y,
    ) == 0) {
        return false;
    }
    return translated_y >= @as(f64, @floatFromInt(row.getHeight())) / 2;
}

fn getRowParts(list_item: *gtk.ListItem) ?RowParts {
    return getRowPartsFromRoot(list_item.getChild() orelse return null);
}

fn getRowPartsFromRoot(widget: *gtk.Widget) ?RowParts {
    const root = gobject.ext.cast(gtk.Box, widget) orelse return null;
    const before = gobject.ext.cast(
        gtk.Revealer,
        root.as(gtk.Widget).getFirstChild() orelse return null,
    ) orelse return null;
    const content = gobject.ext.cast(
        gtk.Revealer,
        before.as(gtk.Widget).getNextSibling() orelse return null,
    ) orelse return null;
    const row = gobject.ext.cast(
        gtk.Box,
        content.getChild() orelse return null,
    ) orelse return null;
    const after = gobject.ext.cast(
        gtk.Revealer,
        content.as(gtk.Widget).getNextSibling() orelse return null,
    ) orelse return null;
    return .{
        .root = root,
        .before = before,
        .content = content,
        .row = row,
        .after = after,
    };
}

fn getPage(list_item: *gtk.ListItem) ?*adw.TabPage {
    return gobject.ext.cast(
        adw.TabPage,
        list_item.getItem() orelse return null,
    );
}

fn getView(page: *adw.TabPage) ?*adw.TabView {
    return ext.getAncestor(
        adw.TabView,
        page.getChild().as(gtk.Widget),
    );
}

test "vertical tab policy" {
    try std.testing.expect(enabled(.left));
    try std.testing.expect(enabled(.right));
    try std.testing.expect(!enabled(.top));
    try std.testing.expect(!enabled(.bottom));

    try std.testing.expect(initialVisibility(.always, 1));
    try std.testing.expect(!initialVisibility(.auto, 1));
    try std.testing.expect(initialVisibility(.auto, 2));
    try std.testing.expect(!initialVisibility(.never, 2));
}
