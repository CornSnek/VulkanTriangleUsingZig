const std=@import("std");
const c=@import("c_imports.zig").c;
graphics:?u32=null,
present:?u32=null,
pub fn init(ph_d:c.VkPhysicalDevice,vk_surface:c.VkSurfaceKHR,allocator:std.mem.Allocator) !@This(){
    var self=@This(){};
    var queue_family_count:u32=undefined;
    c.vkGetPhysicalDeviceQueueFamilyProperties(ph_d,&queue_family_count,null);
    var queue_families:[]c.VkQueueFamilyProperties=try allocator.alloc(c.VkQueueFamilyProperties,queue_family_count);
    defer allocator.free(queue_families);
    c.vkGetPhysicalDeviceQueueFamilyProperties(ph_d,&queue_family_count,queue_families.ptr);
    for(0..queue_family_count) |i| {
        if(queue_families[i].queueFlags&c.VK_QUEUE_GRAPHICS_BIT!=0) self.graphics=@truncate(i);
        var has_present:c.VkBool32=undefined;
        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(ph_d,@truncate(i),vk_surface,&has_present);
        if(has_present==@as(c.VkBool32,@intCast(c.VK_TRUE))) self.present=@truncate(i);
        if(self.is_complete()) break;
    }
    return self;
}
pub fn is_complete(self:@This()) bool {
    return inline for(comptime std.meta.fieldNames(@This())) |name| {
        if(@field(self,name)==null) return false;
    } else true;
}