const std = @import("std");
const dvui = @import("../dvui.zig");

const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;

const ReorderWidget = @This();

var currentReorderWidget: ?*ReorderWidget = null;

wd: WidgetData = undefined,
id_reorderable: ?u32 = null,
drag_point: ?dvui.Point = null,
reorderable_size: Size = .{},
found_slot: bool = false,

pub fn init(src: std.builtin.SourceLocation, opts: Options) ReorderWidget {
    var self = ReorderWidget{};
    const defaults = Options{ .name = "Reorder" };
    // we are always going to be the same size as our parent's content rect,
    // and not participate in normal widget layout
    const parentSize = dvui.parentGet().data().contentRect().size();
    self.wd = WidgetData.init(src, .{}, defaults.override(opts).override(.{ .rect = parentSize.rect() }));
    self.id_reorderable = dvui.dataGet(null, self.wd.id, "_id_reorderable", u32) orelse null;
    self.drag_point = dvui.dataGet(null, self.wd.id, "_drag_point", dvui.Point) orelse null;
    self.reorderable_size = dvui.dataGet(null, self.wd.id, "_reorderable_size", dvui.Size) orelse dvui.Size{};
    return self;
}

pub fn install(self: *ReorderWidget) !void {
    try self.wd.register();

    dvui.parentSet(self.widget());
    currentReorderWidget = self;
}

pub fn needFinalSlot(self: *ReorderWidget) bool {
    return self.drag_point != null and !self.found_slot;
}

pub fn widget(self: *ReorderWidget) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild, processEvent);
}

pub fn data(self: *ReorderWidget) *WidgetData {
    return &self.wd;
}

pub fn rectFor(self: *ReorderWidget, id: u32, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    return self.wd.parent.rectFor(id, min_size, e, g);
}

pub fn screenRectScale(self: *ReorderWidget, rect: Rect) RectScale {
    return self.wd.parent.screenRectScale(rect);
}

pub fn minSizeForChild(self: *ReorderWidget, s: Size) void {
    self.wd.parent.minSizeForChild(s);
}

pub fn matchEvent(self: *ReorderWidget, e: *dvui.Event) bool {
    return dvui.eventMatch(e, .{ .id = self.wd.id, .r = self.wd.borderRectScale().r });
}

pub fn processEvents(self: *ReorderWidget) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e, false);
    }
}

pub fn processEvent(self: *ReorderWidget, e: *dvui.Event, bubbling: bool) void {
    _ = bubbling;

    if (dvui.captured(self.wd.id)) {
        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .release and me.button.pointer()) {
                    dvui.captureMouse(null);
                    self.id_reorderable = null;
                    self.drag_point = null;
                } else if (me.action == .motion) {
                    self.drag_point = me.p;
                }
            },
            else => {},
        }
    }

    if (e.bubbleable()) {
        self.wd.parent.processEvent(e, true);
    }
}

pub fn deinit(self: *ReorderWidget) void {
    // we aren't participating in normal widget layout, so don't do these
    //self.wd.minSizeSetAndRefresh();
    //self.wd.minSizeReportToParent();

    if (self.id_reorderable) |idr| {
        dvui.dataSet(null, self.wd.id, "_id_reorderable", idr);
    } else {
        dvui.dataRemove(null, self.wd.id, "_id_reorderable");
    }

    if (self.drag_point) |dp| {
        dvui.dataSet(null, self.wd.id, "_drag_point", dp);
    } else {
        dvui.dataRemove(null, self.wd.id, "_drag_point");
    }

    dvui.dataSet(null, self.wd.id, "_reorderable_size", self.reorderable_size);

    dvui.parentReset(self.wd.id, self.wd.parent);
    currentReorderWidget = null;
}

pub fn startDrag(self: *ReorderWidget, id_reorderable: u32, p: dvui.Point) void {
    self.id_reorderable = id_reorderable;
    self.drag_point = p;
    self.found_slot = true;
    dvui.captureMouse(self.wd.id);
}

pub fn draggable(src: std.builtin.SourceLocation, reo: *Reorderable, opts: dvui.Options) !void {
    var iw = try dvui.IconWidget.init(src, "reorder_drag_icon", dvui.entypo.menu, opts);
    try iw.install();
    for (dvui.events()) |*e| {
        if (!iw.matchEvent(e))
            continue;

        switch (e.evt) {
            .mouse => |me| {
                if (me.action == .press and me.button.pointer()) {
                    e.handled = true;
                    dvui.captureMouse(iw.wd.id);
                    dvui.dragPreStart(me.p, null, reo.wd.rectScale().r.topLeft().diff(me.p));
                } else if (me.action == .motion) {
                    if (dvui.captured(iw.wd.id)) {
                        e.handled = true;
                        if (dvui.dragging(me.p)) |_| {
                            if (currentReorderWidget) |crw| {
                                // ReorderWidget will capture mouse from here
                                crw.startDrag(reo.wd.id, me.p);
                            } else {
                                dvui.log.err("ReorderWidget.draggable got a drag but currentReorderWidget was null", .{});
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }
    try iw.draw();
    iw.deinit();
}

pub fn reorderable(_: *ReorderWidget, src: std.builtin.SourceLocation, init_opts: Reorderable.InitOptions, opts: Options) !*Reorderable {
    const ret = try dvui.currentWindow().arena.create(Reorderable);
    ret.* = Reorderable.init(src, init_opts, opts);
    try ret.install();
    return ret;
}

pub const Reorderable = struct {
    pub const InitOptions = struct {
        last_slot: bool = false,
    };

    wd: WidgetData = undefined,
    init_options: InitOptions = undefined,
    options: Options = undefined,
    floating_widget: ?dvui.FloatingWidget = null,
    target_rs: ?dvui.RectScale = null,

    pub fn init(src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) Reorderable {
        var self = Reorderable{};
        const defaults = Options{ .name = "Reorderable" };
        self.init_options = init_opts;
        self.options = defaults.override(opts);
        self.wd = WidgetData.init(src, .{}, self.options.override(.{ .rect = .{} }));

        return self;
    }

    // can call this after init before install
    pub fn floating(self: *Reorderable) bool {
        if (currentReorderWidget) |crw| {
            if (crw.drag_point != null and crw.id_reorderable.? == self.wd.id) {
                return true;
            }
        } else {
            dvui.log.err("Reorderable.floating(): must be a child of ReorderWidget", .{});
        }

        return false;
    }

    pub fn install(self: *Reorderable) !void {
        if (currentReorderWidget) |crw| {
            if (crw.drag_point) |dp| {
                if (crw.id_reorderable.? == self.wd.id) {
                    // we are being dragged - put in floating widget
                    try self.wd.register();
                    dvui.parentSet(self.widget());

                    const topleft = dp.plus(dvui.dragOffset()).scale(1 / dvui.windowNaturalScale());
                    self.floating_widget = dvui.FloatingWidget.init(@src(), .{ .rect = Rect.fromPoint(topleft), .min_size_content = crw.reorderable_size });
                    try self.floating_widget.?.install();
                } else {
                    if (self.init_options.last_slot) {
                        self.wd = WidgetData.init(self.wd.src, .{}, self.options.override(.{ .min_size_content = crw.reorderable_size }));
                    } else {
                        self.wd = WidgetData.init(self.wd.src, .{}, self.options);
                    }
                    const rs = self.wd.rectScale();
                    if (rs.r.contains(dp)) {
                        self.target_rs = rs;
                        crw.found_slot = true;
                    }

                    if (self.target_rs == null or self.init_options.last_slot) {
                        try self.wd.register();
                        dvui.parentSet(self.widget());
                    }
                }
            } else {
                self.wd = WidgetData.init(self.wd.src, .{}, self.options);
                crw.reorderable_size = self.wd.rect.size();

                try self.wd.register();
                dvui.parentSet(self.widget());
            }
        } else {
            dvui.log.err("Reorderable.install() must be a child of ReorderWidget", .{});
        }
    }

    pub fn targetRectScale(self: *Reorderable) ?dvui.RectScale {
        return self.target_rs;
    }

    pub fn reinstall(self: *Reorderable) !void {
        // send our target rect to the parent for sizing
        self.wd.minSizeMax(self.wd.rect.size());
        self.wd.minSizeReportToParent();

        // reinstall ourselves getting the next rect from parent
        self.wd = WidgetData.init(self.wd.src, .{}, self.options);
        try self.wd.register();
        dvui.parentSet(self.widget());
    }

    pub fn widget(self: *Reorderable) Widget {
        return Widget.init(self, Reorderable.data, Reorderable.rectFor, Reorderable.screenRectScale, Reorderable.minSizeForChild, Reorderable.processEvent);
    }

    pub fn data(self: *Reorderable) *WidgetData {
        return &self.wd;
    }

    pub fn rectFor(self: *Reorderable, id: u32, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
        return dvui.placeIn(self.wd.contentRect().justSize(), dvui.minSize(id, min_size), e, g);
    }

    pub fn screenRectScale(self: *Reorderable, rect: Rect) RectScale {
        return self.wd.contentRectScale().rectToRectScale(rect);
    }

    pub fn minSizeForChild(self: *Reorderable, s: Size) void {
        self.wd.minSizeMax(self.wd.padSize(s));
    }

    pub fn processEvent(self: *Reorderable, e: *dvui.Event, bubbling: bool) void {
        _ = bubbling;

        if (e.bubbleable()) {
            self.wd.parent.processEvent(e, true);
        }
    }

    pub fn deinit(self: *Reorderable) void {
        if (self.floating_widget) |*fw| {
            self.wd.minSizeMax(fw.wd.min_size);
            fw.deinit();
        }

        self.wd.minSizeSetAndRefresh();
        self.wd.minSizeReportToParent();

        dvui.parentReset(self.wd.id, self.wd.parent);
    }
};