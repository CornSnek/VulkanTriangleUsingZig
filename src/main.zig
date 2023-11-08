const std = @import("std");
const App = @import("App.zig");
pub fn main() !void {
    var gpa=std.heap.GeneralPurposeAllocator(.{}){};
    const allocator=gpa.allocator();
    defer if(gpa.deinit()==.leak) std.log.debug("GPA detected leak",.{});
    var app:App=undefined;
    try app.create(allocator);
    defer app.deinit();
    try app.main_loop();
}