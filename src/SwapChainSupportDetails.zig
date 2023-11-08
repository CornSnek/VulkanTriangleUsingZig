const std=@import("std");
const c=@import("c_imports.zig").c;
capabilities:c.VkSurfaceCapabilitiesKHR,
formats:[]c.VkSurfaceFormatKHR,
present_mode:[]c.VkPresentModeKHR,
pub fn init(ph_device:c.VkPhysicalDevice,vk_surface:c.VkSurfaceKHR,allocator:std.mem.Allocator) !@This(){
    var self:@This()=undefined;
    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ph_device,vk_surface,&self.capabilities);
    var format_count:u32=undefined;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(ph_device,vk_surface,&format_count,null);
    self.formats=try allocator.alloc(c.VkSurfaceFormatKHR,format_count);
    errdefer allocator.free(self.formats);
    if(format_count!=0)
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(ph_device,vk_surface,&format_count,self.formats.ptr);
    var present_mode_count:u32=undefined;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ph_device,vk_surface,&present_mode_count,null);
    self.present_mode=try allocator.alloc(c.VkPresentModeKHR,present_mode_count);
    if(present_mode_count!=0)
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(ph_device,vk_surface,&present_mode_count,self.present_mode.ptr);
    return self;
}
pub fn deinit(self:*@This(),allocator:std.mem.Allocator) void{
    allocator.free(self.present_mode);
    allocator.free(self.formats);
}