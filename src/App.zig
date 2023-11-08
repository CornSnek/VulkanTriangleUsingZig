const std=@import("std");
const VkSetup=@import("VkSetup.zig");
const c=@import("c_imports.zig").c;
const c_cast=std.zig.c_translation.cast;
allocator:std.mem.Allocator,
window:*c.SDL_Window,
vk:VkSetup,
fn read_bytes(userdata:*const anyopaque,userdata_size:usize) void{
    var char_ptr:[*]u8=@alignCast(@constCast(@ptrCast(userdata)));
    for(0..userdata_size)|i|{
        std.debug.print("{x} ",.{char_ptr[i]});
    }
    std.debug.print("\n",.{});
}
pub fn create(self:*@This(),allocator:std.mem.Allocator) !void {
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_TIMER | c.SDL_INIT_EVENTS) != 0) {
        std.log.err("Unable to initialiize SDL", .{});
        return error.SDLInitError;
    }
    c.SDL_LogSetAllPriority(c.SDL_LOG_PRIORITY_VERBOSE);
    self.allocator=allocator;
    self.window=c.SDL_CreateWindow("Vulkan Triangle Using Zig",c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED, 1024, 768, c.SDL_WINDOW_VULKAN)
        orelse return error.SDLInitWindowError;
    try self.vk.create(allocator,self.window);
}
pub fn main_loop(self:*@This()) !void {
    main_loop: while (true) {
        var ev:c.SDL_Event=undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => break :main_loop,
                c.SDL_KEYDOWN => {
                    switch(ev.key.keysym.sym) {
                        c.SDLK_ESCAPE => break :main_loop,
                        else => {},
                    }
                },
                else => {},
            }
        }
        //Draw frame
        _ = c.vkWaitForFences(self.vk.logical_device,1,&self.vk.in_flight_fence,c.VK_TRUE,std.math.maxInt(u64));
        _ = c.vkResetFences(self.vk.logical_device,1,&self.vk.in_flight_fence);
        var image_index:u32=undefined;
        _ = c.vkAcquireNextImageKHR(self.vk.logical_device,self.vk.swap_chain.khr,std.math.maxInt(u64),self.vk.sem_image_available,null,&image_index);
        _ = c.vkResetCommandBuffer(self.vk.command_buffer,0);
        try self.vk.record_command_buffer(image_index);
        var signal_semaphores=[_]c.VkSemaphore{self.vk.sem_render_finished};
        var submit_info=c.VkSubmitInfo{
            .sType=c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext=null,
            .waitSemaphoreCount=1,
            .pWaitSemaphores=&[_]c.VkSemaphore{self.vk.sem_image_available},
            .pWaitDstStageMask=&[_]c.VkPipelineStageFlags{
                @intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT)
            },
            .commandBufferCount=1,
            .pCommandBuffers=&self.vk.command_buffer,
            .signalSemaphoreCount=1,
            .pSignalSemaphores=&signal_semaphores,
        };
        if(c.vkQueueSubmit(self.vk.graphics_q,1,&submit_info,self.vk.in_flight_fence)!=c.VK_SUCCESS)
            return error.FailedToDrawCommandBuffer;
        //Presentation
        var present_info=c.VkPresentInfoKHR{
            .sType=c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext=null,
            .waitSemaphoreCount=1,
            .pWaitSemaphores=&signal_semaphores,
            .swapchainCount=1,
            .pSwapchains=&self.vk.swap_chain.khr,
            .pImageIndices=&image_index,
            .pResults=null,
        };
        _ = c.vkQueuePresentKHR(self.vk.present_q,&present_info);
    }
    _ = c.vkDeviceWaitIdle(self.vk.logical_device);
}
pub fn deinit(self:*@This()) void {
    self.vk.deinit();
    c.SDL_DestroyWindow(self.window);
    c.SDL_Quit();
}