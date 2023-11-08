const std=@import("std");
const builtin=@import("builtin");
const c=@import("c_imports.zig").c;
const DoDebugValidationLayers:bool=(builtin.mode==.Debug);
const c_cast=std.zig.c_translation.cast;
const spirv_files=@import("spirv_files.zig");
const ValidationLayersToEnable=[_][*c]const u8 {
    "VK_LAYER_KHRONOS_validation",
};
const DeviceExtensionsToEnable=[_][*c]const u8 {
    c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
};
pub const QueueFamilyIndices=@import("QueueFamilyIndices.zig");
pub const SwapChainSupportDetails=@import("SwapChainSupportDetails.zig");
pub const SwapChainStruct=struct {
    khr:c.VkSwapchainKHR,
    count:u32,
    format:c.VkFormat,
    extent:c.VkExtent2D,
    images:[]c.VkImage,
    image_views:[]c.VkImageView,
    frame_buffers:[]c.VkFramebuffer,
};
allocator:std.mem.Allocator,
window:*c.SDL_Window,
vk_instance:c.VkInstance,
debug_messenger:c.VkDebugUtilsMessengerEXT,
physical_device:c.VkPhysicalDevice,
qfi:QueueFamilyIndices,
logical_device:c.VkDevice,
vk_surface:c.VkSurfaceKHR,
graphics_q:c.VkQueue,
present_q:c.VkQueue,
swap_chain:SwapChainStruct,
render_pass:c.VkRenderPass,
pipeline_layout:c.VkPipelineLayout,
graphics_pipeline:c.VkPipeline,
command_pool:c.VkCommandPool,
command_buffer:c.VkCommandBuffer,
sem_image_available:c.VkSemaphore,
sem_render_finished:c.VkSemaphore,
in_flight_fence:c.VkFence,
pub fn create(self:*@This(),allocator:std.mem.Allocator,window:*c.SDL_Window) !void {
    self.allocator=allocator;
    self.window=window;
    try self.create_vk_instance();
    errdefer c.vkDestroyInstance(self.vk_instance,null);
    if(c.SDL_Vulkan_CreateSurface(window,self.vk_instance,&self.vk_surface) == c_cast(c.SDL_bool,c.SDL_FALSE))
        return error.UnableToCreateSDLVulkanSurface;
    errdefer c.vkDestroySurfaceKHR(self.vk_instance,self.vk_surface,null);
    if(DoDebugValidationLayers) try self.setup_debug_messenger();
    errdefer if(DoDebugValidationLayers) AsVkInstancePFN("vkDestroyDebugUtilsMessengerEXT",self.vk_instance)(self.vk_instance,self.debug_messenger,null);
    try self.pick_vk_physical_device();
    try self.create_logical_device();
    errdefer c.vkDestroyDevice(self.logical_device,null);
    try self.create_swap_chain();
    errdefer {
        c.vkDestroySwapchainKHR(self.logical_device,self.swap_chain.khr,null);
        self.allocator.free(self.swap_chain.images);
    }
    try self.create_image_views();
    errdefer self.allocator.free(self.swap_chain.image_views);
    errdefer for(0..self.swap_chain.count) |i| c.vkDestroyImageView(self.logical_device,self.swap_chain.image_views[i],null);
    try self.create_render_pass();
    errdefer c.vkDestroyRenderPass(self.logical_device,self.render_pass,null);
    try self.create_graphics_pipeline();
    errdefer c.vkDestroyPipelineLayout(self.logical_device,self.pipeline_layout,null);
    errdefer c.vkDestroyPipeline(self.logical_device,self.graphics_pipeline,null);
    try self.create_frame_buffers();
    errdefer self.allocator.free(self.swap_chain.frame_buffers);
    errdefer for(0..self.swap_chain.count) |i| c.vkDestroyFramebuffer(self.logical_device,self.swap_chain.frame_buffers[i],null);
    try self.create_command_pool();
    errdefer c.vkDestroyCommandPool(self.logical_device,self.command_pool,null);
    try self.create_command_buffer();
    try self.create_sync_objects();
}
pub fn deinit(self:*@This()) void {
    c.vkDestroyFence(self.logical_device,self.in_flight_fence,null);
    c.vkDestroySemaphore(self.logical_device,self.sem_render_finished,null);
    c.vkDestroySemaphore(self.logical_device,self.sem_image_available,null);
    c.vkDestroyCommandPool(self.logical_device,self.command_pool,null);
    for(0..self.swap_chain.count) |i| c.vkDestroyFramebuffer(self.logical_device,self.swap_chain.frame_buffers[i],null);
    self.allocator.free(self.swap_chain.frame_buffers);
    c.vkDestroyPipeline(self.logical_device,self.graphics_pipeline,null);
    c.vkDestroyPipelineLayout(self.logical_device,self.pipeline_layout,null);
    c.vkDestroyRenderPass(self.logical_device,self.render_pass,null);
    for(0..self.swap_chain.count) |i| c.vkDestroyImageView(self.logical_device,self.swap_chain.image_views[i],null);
    self.allocator.free(self.swap_chain.image_views);
    self.allocator.free(self.swap_chain.images);
    c.vkDestroySwapchainKHR(self.logical_device,self.swap_chain.khr,null);
    c.vkDestroyDevice(self.logical_device,null);
    if(DoDebugValidationLayers)
        AsVkInstancePFN("vkDestroyDebugUtilsMessengerEXT",self.vk_instance)(self.vk_instance,self.debug_messenger,null);
    c.vkDestroySurfaceKHR(self.vk_instance,self.vk_surface,null);
    c.vkDestroyInstance(self.vk_instance,null);
}
pub fn record_command_buffer(self:*@This(),image_index:u32) !void {
    var begin_info=c.VkCommandBufferBeginInfo{
        .sType=c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext=null,
        .flags=0,
        .pInheritanceInfo=null,
    };
    if(c.vkBeginCommandBuffer(self.command_buffer,&begin_info)!=c.VK_SUCCESS) return error.FailedToBeginRecordingCommandBuffer;
    var render_pass_info=c.VkRenderPassBeginInfo{
        .sType=c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext=null,
        .renderPass=self.render_pass,
        .framebuffer=self.swap_chain.frame_buffers[image_index],
        .renderArea=c.VkRect2D{
            .offset=c.VkOffset2D{.x=0,.y=0},
            .extent=self.swap_chain.extent,
        },
        .clearValueCount=1,
        .pClearValues=&c.VkClearValue{
            .color=c.VkClearColorValue{.float32=[4]f32{0,0,0,0}},
        },
    };
    c.vkCmdBeginRenderPass(self.command_buffer,&render_pass_info
        ,c_cast(c.VkSubpassContents,c.VK_SUBPASS_CONTENTS_INLINE)
    );
    c.vkCmdBindPipeline(self.command_buffer,c.VK_PIPELINE_BIND_POINT_GRAPHICS,self.graphics_pipeline);
    var viewport=c.VkViewport{
        .x=0,
        .y=0,
        .width=@floatFromInt(self.swap_chain.extent.width),
        .height=@floatFromInt(self.swap_chain.extent.height),
        .minDepth=0,
        .maxDepth=1,
    };
    c.vkCmdSetViewport(self.command_buffer,0,1,&viewport);
    var scissor=c.VkRect2D{
        .offset=c.VkOffset2D{
            .x=0,
            .y=0,
        },
        .extent=self.swap_chain.extent,
    };
    c.vkCmdSetScissor(self.command_buffer,0,1,&scissor);
    c.vkCmdDraw(self.command_buffer,3,1,0,0);
    c.vkCmdEndRenderPass(self.command_buffer);
    if(c.vkEndCommandBuffer(self.command_buffer)!=c.VK_SUCCESS) return error.FailedToRecordCommandBuffer;
}
fn get_vl(self:@This()) ![]c.VkLayerProperties {
    var layer_count:u32=undefined;
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count,null);
    var available_validation_layers=try self.allocator.alloc(c.VkLayerProperties,layer_count);
    _ = c.vkEnumerateInstanceLayerProperties(&layer_count,available_validation_layers.ptr);
    return available_validation_layers;
}
fn get_required_extensions(self:@This()) ![][*c]const u8 {
    var sdl_extension_count:c_uint=undefined;
    _ = c.SDL_Vulkan_GetInstanceExtensions(self.window,&sdl_extension_count,null);
    var sdl_extensions=try self.allocator.alloc([*c]const u8,sdl_extension_count);
    errdefer self.allocator.free(sdl_extensions);
    _ = c.SDL_Vulkan_GetInstanceExtensions(self.window,&sdl_extension_count,sdl_extensions.ptr);
    if(DoDebugValidationLayers){
        sdl_extensions=try self.allocator.realloc(sdl_extensions,sdl_extension_count+1);
        sdl_extensions[sdl_extension_count]=c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    }
    return sdl_extensions;
}
fn create_vk_instance(self:*@This()) !void {
    const available_validation_layers=try self.get_vl();
    defer self.allocator.free(available_validation_layers);
    const sdl_extensions=try self.get_required_extensions();
    defer self.allocator.free(sdl_extensions);
    if(DoDebugValidationLayers){
        for(ValidationLayersToEnable) |vl_cstr| {
            const vl_slice=std.mem.sliceTo(vl_cstr,0);
            if(!try VulkanHasVLSupport(available_validation_layers,vl_slice)){
                std.debug.print("Layer Property '{s}' not supported.\n",.{vl_slice});
                return error.VKInstanceCreateFailed;
            }
        }
    }
    var app_info=c.VkApplicationInfo {
        .sType=c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext=null,
        .pApplicationName="A triangle",
        .applicationVersion=c.VK_MAKE_VERSION(1,0,0),
        .pEngineName="No Engine",
        .engineVersion=c.VK_MAKE_VERSION(1,0,0),
        .apiVersion=c.VK_API_VERSION_1_2,
    };
    var debug_create_info=if(DoDebugValidationLayers)
        @as(c.VkDebugUtilsMessengerCreateInfoEXT,DebugUtilsMessengerCreateInfo_new())
        else {};
    var create_info=c.VkInstanceCreateInfo {
        .sType=c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext=if(DoDebugValidationLayers) &debug_create_info else null,
        .flags=0,
        .pApplicationInfo=&app_info,
        .enabledLayerCount=if(DoDebugValidationLayers)
            @truncate(ValidationLayersToEnable.len) else 0,
        .ppEnabledLayerNames=if(DoDebugValidationLayers)
            @ptrCast(&ValidationLayersToEnable) else null,
        .enabledExtensionCount=@truncate(sdl_extensions.len),
        .ppEnabledExtensionNames=@ptrCast(sdl_extensions.ptr),
    };
    if(c.vkCreateInstance(&create_info,null,&self.vk_instance)!=c.VK_SUCCESS)
        return error.FailedToCreateInstance;
}
fn setup_debug_messenger(self:*@This()) !void {
    var create_info=DebugUtilsMessengerCreateInfo_new();
    if(AsVkInstancePFN("vkCreateDebugUtilsMessengerEXT",self.vk_instance)
        (self.vk_instance,&create_info,null,&self.debug_messenger)!=c.VK_SUCCESS)
        return error.FailedToSetUpDebugMessenger;
}
fn pick_vk_physical_device(self:*@This()) !void {
    var device_count:u32=undefined;
    _ = c.vkEnumeratePhysicalDevices(self.vk_instance,&device_count,null);
    if(device_count==0) return error.NoDevicesWithGPUVulkanSupport;
    const devices_arr:[]c.VkPhysicalDevice=try self.allocator.alloc(c.VkPhysicalDevice,device_count);
    defer self.allocator.free(devices_arr);
    _ = c.vkEnumeratePhysicalDevices(self.vk_instance,&device_count,devices_arr.ptr);
    for(devices_arr) |device| {
        if(try self.is_device_suitable(device)){
            self.physical_device=device;
            return;
        }
    }
    return error.NoDevicesWithGPUVulkanSupport;
}
fn is_device_suitable(self:*@This(),ph_device:c.VkPhysicalDevice) !bool {
    if(ph_device==null) return false;
    self.qfi = try QueueFamilyIndices.init(ph_device,self.vk_surface,self.allocator);
    if(!self.qfi.is_complete()) return false;
    if(!try has_device_extension_support(ph_device,self.allocator)) return false;
    var swap_chain_support=try SwapChainSupportDetails.init(ph_device,self.vk_surface,self.allocator);
    defer swap_chain_support.deinit(self.allocator);
    return swap_chain_support.formats.len!=0 and swap_chain_support.present_mode.len!=0;
}
fn has_device_extension_support(ph_device:c.VkPhysicalDevice,allocator:std.mem.Allocator) !bool {
    var extension_count:u32=undefined;
    _ = c.vkEnumerateDeviceExtensionProperties(ph_device,null,&extension_count,null);
    var extensions=try allocator.alloc(c.VkExtensionProperties,extension_count);
    defer allocator.free(extensions);
    var required_extensions=try allocator.dupe([*c]const u8,&DeviceExtensionsToEnable);
    defer allocator.free(required_extensions);
    _ = c.vkEnumerateDeviceExtensionProperties(ph_device,null,&extension_count,extensions.ptr);
    var extensions_left:usize=DeviceExtensionsToEnable.len;
    for(extensions) |ext| {
        const extension_name=std.mem.sliceTo(&ext.extensionName,0);
        for(0..extensions_left) |index| {
            const required_extension_name=std.mem.sliceTo(required_extensions[index],0);
            if(std.mem.eql(u8,required_extension_name,extension_name)){
                extensions_left-=1;
                if(extensions_left==0) return true;
                required_extensions[index]=required_extensions[extensions_left]; //Erase index with last index.
            }
        }
    }
    return false;
}
fn create_logical_device(self:*@This()) !void {
    inline for(comptime std.meta.fieldNames(QueueFamilyIndices)) |name|
        @field(self,name++"_q")=null;
    var device_features=std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    var queue_create_infos=try self.get_queue_create_infos();
    defer self.allocator.free(queue_create_infos);
    var create_info:c.VkDeviceCreateInfo=.{
        .sType=c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .flags=0,
        .pNext=null,
        .pQueueCreateInfos=queue_create_infos.ptr,
        .queueCreateInfoCount=@truncate(queue_create_infos.len),
        .pEnabledFeatures=&device_features,
        .enabledLayerCount=if(DoDebugValidationLayers)
            @truncate(ValidationLayersToEnable.len) else 0,
        .ppEnabledLayerNames=if(DoDebugValidationLayers)
            @ptrCast(&ValidationLayersToEnable) else null,
        .enabledExtensionCount=@truncate(DeviceExtensionsToEnable.len),
        .ppEnabledExtensionNames=&DeviceExtensionsToEnable,
    };
    if(c.vkCreateDevice(self.physical_device,&create_info,null,&self.logical_device)!=c.VK_SUCCESS)
        return error.UnableToCreateLogicalDevice;
    inline for(comptime std.meta.fieldNames(QueueFamilyIndices)) |name| {
        c.vkGetDeviceQueue(self.logical_device,@field(self.qfi,name).?,0,&@field(self,name++"_q"));
        if(@field(self,name++"_q")==null)
            return error.UnableToGetAllDeviceQueues;
    }
}
fn get_queue_create_infos(self:@This()) ![]c.VkDeviceQueueCreateInfo {
    var unique_qf:std.AutoHashMap(u32,void)=std.AutoHashMap(u32,void).init(self.allocator);
    defer unique_qf.deinit();
    inline for(comptime std.meta.fieldNames(QueueFamilyIndices)) |name|
        try unique_qf.put(@field(self.qfi,name).?,{});
    var queue_create_infos=try self.allocator.alloc(c.VkDeviceQueueCreateInfo,unique_qf.count());
    errdefer self.allocator.free(queue_create_infos);
    var unique_qf_it=unique_qf.keyIterator();
    const queue_p:f32=1.0;
    var arr_i:usize=0;
    while(unique_qf_it.next()) |qf_p| {
        var queue_create_info:c.VkDeviceQueueCreateInfo=.{
            .sType=c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .flags=0,
            .pNext=null,
            .pQueuePriorities=&queue_p,
            .queueFamilyIndex=qf_p.*,
            .queueCount=1,
        };
        queue_create_infos[arr_i]=queue_create_info;
        arr_i+=1;
    }
    return queue_create_infos;
}
fn create_swap_chain(self:*@This()) !void {
    var swap_chain_support=try SwapChainSupportDetails.init(self.physical_device,self.vk_surface,self.allocator);
    defer swap_chain_support.deinit(self.allocator);
    const chosen_format:c.VkSurfaceFormatKHR=
        for(swap_chain_support.formats) |f| {
            if(f.format==c.VK_FORMAT_B8G8R8A8_SRGB and f.colorSpace==c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
                break f;
        } else swap_chain_support.formats[0];
    const chosen_present_mode=
        for(swap_chain_support.present_mode) |pm| {
            if(pm==c.VK_PRESENT_MODE_MAILBOX_KHR) break pm;
        } else c.VK_PRESENT_MODE_FIFO_KHR;
    const chosen_swap_extent=self.choose_swap_extent(swap_chain_support.capabilities);
    const chosen_image_count=@min(swap_chain_support.capabilities.minImageCount+1
        ,swap_chain_support.capabilities.maxImageCount);
    const same_indices=self.qfi.graphics==self.qfi.present;
    const qfi_order=[2]u32 {self.qfi.graphics.?,self.qfi.present.?};
    var create_info=c.VkSwapchainCreateInfoKHR {
        .sType=c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext=null,
        .flags=0,
        .surface=self.vk_surface,
        .minImageCount=chosen_image_count,
        .imageFormat=chosen_format.format,
        .imageColorSpace=chosen_format.colorSpace,
        .imageExtent=chosen_swap_extent,
        .imageArrayLayers=1,
        .imageUsage=c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode=c_cast(c.VkSharingMode, if(same_indices) c.VK_SHARING_MODE_EXCLUSIVE else c.VK_SHARING_MODE_CONCURRENT),
        .queueFamilyIndexCount=if(same_indices) 0 else 2,
        .pQueueFamilyIndices=if(same_indices) null else @ptrCast(&qfi_order),
        .preTransform=swap_chain_support.capabilities.currentTransform,
        .compositeAlpha=c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode=chosen_present_mode,
        .clipped=@truncate(c.VK_TRUE),
        .oldSwapchain=null,
    };
    if(c.vkCreateSwapchainKHR(self.logical_device,&create_info,null,&self.swap_chain.khr)!=c.VK_SUCCESS)
        return error.FailedToCreateSwapChain;
    errdefer c.vkDestroySwapchainKHR(self.logical_device,self.swap_chain.khr,null);
    _ = c.vkGetSwapchainImagesKHR(self.logical_device,self.swap_chain.khr,&self.swap_chain.count,null);
    self.swap_chain.images=try self.allocator.alloc(c.VkImage,self.swap_chain.count);
    _ = c.vkGetSwapchainImagesKHR(self.logical_device,self.swap_chain.khr,&self.swap_chain.count,self.swap_chain.images.ptr);
    self.swap_chain.format=chosen_format.format;
    self.swap_chain.extent=chosen_swap_extent;
}
fn choose_swap_extent(self:*@This(),capabilities:c.VkSurfaceCapabilitiesKHR) c.VkExtent2D {
    if(capabilities.currentExtent.width!=std.math.floatMax(f32))
        return capabilities.currentExtent;
    var w:c_int=undefined;
    var h:c_int=undefined;
    c.SDL_GetWindowSizeInPixels(self.window,&w,&h);
    var actual_extent=c.VkExtent2D {
        .width=@intCast(w),
        .height=@intCast(h),
    };
    actual_extent.width=std.math.clamp(actual_extent.width
        ,capabilities.minImageExtent.width,capabilities.maxImageExtent.width);
    actual_extent.height=std.math.clamp(actual_extent.height
        ,capabilities.minImageExtent.height,capabilities.maxImageExtent.height);
    return actual_extent;
}
fn create_image_views(self:*@This()) !void {
    self.swap_chain.image_views=try self.allocator.alloc(c.VkImageView,self.swap_chain.count);
    errdefer self.allocator.free(self.swap_chain.image_views);
    for(0..self.swap_chain.count) |i| {
        var create_info=c.VkImageViewCreateInfo{
            .sType=c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext=null,
            .flags=0,
            .image=self.swap_chain.images[i],
            .viewType=c.VK_IMAGE_VIEW_TYPE_2D,
            .format=self.swap_chain.format,
            .components=c.VkComponentMapping{
                .r=c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g=c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b=c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a=c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange=c.VkImageSubresourceRange{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        errdefer for(0..i) |@"i2"| c.vkDestroyImageView(self.logical_device,self.swap_chain.image_views[@"i2"],null);
        if(c.vkCreateImageView(self.logical_device,&create_info,null,&self.swap_chain.image_views[i])!=c.VK_SUCCESS) {
            return error.FailedToCreateImageViews;
        }
    }
}
fn create_render_pass(self:*@This()) !void {
    var color_attachment=c.VkAttachmentDescription{
        .format=self.swap_chain.format,
        .flags=0,
        .samples=@intCast(c.VK_SAMPLE_COUNT_1_BIT),
        .loadOp=@intCast(c.VK_ATTACHMENT_LOAD_OP_CLEAR),
        .storeOp=@intCast(c.VK_ATTACHMENT_STORE_OP_STORE),
        .stencilLoadOp=@intCast(c.VK_ATTACHMENT_LOAD_OP_DONT_CARE),
        .stencilStoreOp=@intCast(c.VK_ATTACHMENT_STORE_OP_DONT_CARE),
        .initialLayout=@intCast(c.VK_IMAGE_LAYOUT_UNDEFINED),
        .finalLayout=@intCast(c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR),
    };
    var color_attachment_ref=c.VkAttachmentReference{
        .attachment=0,
        .layout=@intCast(c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL),
    };
    var subpass=std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint=@intCast(c.VK_PIPELINE_BIND_POINT_GRAPHICS);
    subpass.colorAttachmentCount=1;
    subpass.pColorAttachments=&color_attachment_ref;
    var render_pass_info=std.mem.zeroes(c.VkRenderPassCreateInfo);
        render_pass_info.sType=c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount=1;
        render_pass_info.pAttachments=&color_attachment;
        render_pass_info.subpassCount=1;
        render_pass_info.pSubpasses=&subpass;
        render_pass_info.dependencyCount=1;
        render_pass_info.pDependencies=&c.VkSubpassDependency{
            .dependencyFlags=0,
            .srcSubpass=c.VK_SUBPASS_EXTERNAL,
            .dstSubpass=0,
            .srcStageMask=@intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT),
            .srcAccessMask=0,
            .dstStageMask=@intCast(c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT),
            .dstAccessMask=@intCast(c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT),
        };
    if(c.vkCreateRenderPass(self.logical_device,&render_pass_info,null,&self.render_pass)!=c.VK_SUCCESS)
        return error.FailedToCreateRenderPass;
}
fn create_graphics_pipeline(self:*@This()) !void {
    var vert_shader_module=try self.create_shader_module(spirv_files.VertShader);
    defer c.vkDestroyShaderModule(self.logical_device,vert_shader_module,null);
    var frag_shader_module=try self.create_shader_module(spirv_files.FragShader);
    defer c.vkDestroyShaderModule(self.logical_device,frag_shader_module,null);
    var vert_shader_stage_info=c.VkPipelineShaderStageCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .stage=c.VK_SHADER_STAGE_VERTEX_BIT,
        .module=vert_shader_module,
        .pName="main",
        .pSpecializationInfo=null,
    };
    var frag_shader_stage_info=c.VkPipelineShaderStageCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .stage=c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module=frag_shader_module,
        .pName="main",
        .pSpecializationInfo=null,
    };
    var shader_stages=[_]c.VkPipelineShaderStageCreateInfo{vert_shader_stage_info,frag_shader_stage_info};
    var vertex_input_info=c.VkPipelineVertexInputStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .vertexBindingDescriptionCount=0,
        .pVertexBindingDescriptions=null,
        .vertexAttributeDescriptionCount=0,
        .pVertexAttributeDescriptions=null,
    };
    var input_assembly=c.VkPipelineInputAssemblyStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .topology=c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable=c.VK_FALSE,
    };
    var viewport_state=c.VkPipelineViewportStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .viewportCount=1,
        .pViewports=null,
        .scissorCount=1,
        .pScissors=null,
    };
    var rasterizer=c.VkPipelineRasterizationStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .depthClampEnable=@truncate(c.VK_FALSE),
        .rasterizerDiscardEnable=@truncate(c.VK_FALSE),
        .polygonMode=c.VK_POLYGON_MODE_FILL,
        .lineWidth=1.0,
        .cullMode=c.VK_CULL_MODE_BACK_BIT,
        .frontFace=c.VK_FRONT_FACE_CLOCKWISE,
        .depthBiasEnable=@truncate(c.VK_FALSE),
        .depthBiasSlopeFactor=0.0,
        .depthBiasClamp=0.0,
        .depthBiasConstantFactor=0.0,
    };
    var multisampling=c.VkPipelineMultisampleStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .sampleShadingEnable=@truncate(c.VK_FALSE),
        .rasterizationSamples=@intCast(c.VK_SAMPLE_COUNT_1_BIT),
        .alphaToCoverageEnable=@truncate(c.VK_FALSE),
        .alphaToOneEnable=@truncate(c.VK_FALSE),
        .minSampleShading=0.0,
        .pSampleMask=null,
    };
    var color_blend_attachment=std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
    color_blend_attachment.colorWriteMask=c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT
        | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    color_blend_attachment.blendEnable=@truncate(c.VK_FALSE);
    var color_blending=c.VkPipelineColorBlendStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .logicOpEnable=@truncate(c.VK_FALSE),
        .logicOp=@intCast(c.VK_LOGIC_OP_COPY),
        .attachmentCount=1,
        .pAttachments=&color_blend_attachment,
        .blendConstants=[1]f32{0}**4,
    };
    var dynamic_states=[_]c.VkDynamicState{
        @intCast(c.VK_DYNAMIC_STATE_VIEWPORT),
        @intCast(c.VK_DYNAMIC_STATE_SCISSOR),
    };
    var dynamic_state=c.VkPipelineDynamicStateCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .dynamicStateCount=@truncate(dynamic_states.len),
        .pDynamicStates=&dynamic_states,
    };
    var pipeline_layout_info=c.VkPipelineLayoutCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .setLayoutCount=0,
        .pSetLayouts=null,
        .pushConstantRangeCount=0,
        .pPushConstantRanges=null,
    };
    if(c.vkCreatePipelineLayout(self.logical_device,&pipeline_layout_info,null,&self.pipeline_layout)!=c.VK_SUCCESS)
        return error.FailedToCreatePipelineLayout;
    errdefer c.vkDestroyPipelineLayout(self.logical_device,self.pipeline_layout,null);
    var pipeline_info=c.VkGraphicsPipelineCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .stageCount=2,
        .pStages=&shader_stages,
        .pVertexInputState=&vertex_input_info,
        .pInputAssemblyState=&input_assembly,
        .pViewportState=&viewport_state,
        .pRasterizationState=&rasterizer,
        .pMultisampleState=&multisampling,
        .pDepthStencilState=null,
        .pColorBlendState=&color_blending,
        .pDynamicState=&dynamic_state,
        .layout=self.pipeline_layout,
        .renderPass=self.render_pass,
        .subpass=0,
        .basePipelineHandle=null,
        .basePipelineIndex=-1,
        .pTessellationState=null,
    };
    if(c.vkCreateGraphicsPipelines(self.logical_device,null,1,&pipeline_info,null,&self.graphics_pipeline)!=c.VK_SUCCESS)
        return error.FailedToCreateGraphicsPipeline;
}
fn create_shader_module(self:@This(),file_bytes:[]const u8)!c.VkShaderModule {
    var create_info=c.VkShaderModuleCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext=null,
        .flags=0,
        .codeSize=file_bytes.len,
        .pCode=@alignCast(@ptrCast(file_bytes)),
    };
    var shader_module:c.VkShaderModule=undefined;
    if(c.vkCreateShaderModule(self.logical_device,&create_info,null,&shader_module)!=c.VK_SUCCESS)
        return error.FailedToCreateShaderModule;
    return shader_module;
}
fn create_frame_buffers(self:*@This()) !void {
    self.swap_chain.frame_buffers=try self.allocator.alloc(c.VkFramebuffer,self.swap_chain.count);
    errdefer self.allocator.free(self.swap_chain.frame_buffers);
    for(0..self.swap_chain.count) |i| {
        var frame_buffer_info=c.VkFramebufferCreateInfo{
            .sType=c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext=null,
            .flags=0,
            .renderPass=self.render_pass,
            .attachmentCount=1,
            .pAttachments=self.swap_chain.image_views.ptr+i,
            .width=self.swap_chain.extent.width,
            .height=self.swap_chain.extent.height,
            .layers=1,
        };
        errdefer for(0..i) |@"i2"| c.vkDestroyFramebuffer(self.logical_device,self.swap_chain.frame_buffers[@"i2"],null);
        if(c.vkCreateFramebuffer(self.logical_device,&frame_buffer_info,null,&self.swap_chain.frame_buffers[i])!=c.VK_SUCCESS)
            return error.FailedToCreateFramebuffer;
    }
}
fn create_command_pool(self:*@This()) !void {
    var pool_info=c.VkCommandPoolCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext=null,
        .flags=c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex=self.qfi.graphics.?,
    };
    if(c.vkCreateCommandPool(self.logical_device,&pool_info,null,&self.command_pool)!=c.VK_SUCCESS) return error.FailedToCreateCommandPool;
}
fn create_command_buffer(self:*@This()) !void {
    var alloc_info=c.VkCommandBufferAllocateInfo{
        .sType=c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext=null,
        .commandPool=self.command_pool,
        .level=c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount=1,
    };
    if(c.vkAllocateCommandBuffers(self.logical_device,&alloc_info,&self.command_buffer)!=c.VK_SUCCESS) return error.FailedToAllocateCommandBuffers;
}
fn create_sync_objects(self:*@This()) !void {
    var semaphore_info=c.VkSemaphoreCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext=null,
        .flags=0,
    };
    var fence_info=c.VkFenceCreateInfo{
        .sType=c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext=null,
        .flags=c.VK_FENCE_CREATE_SIGNALED_BIT,
    };
    var results:[3]c.VkResult=undefined;
    results[0]=c.vkCreateSemaphore(self.logical_device,&semaphore_info,null,&self.sem_image_available);
    results[1]=c.vkCreateSemaphore(self.logical_device,&semaphore_info,null,&self.sem_render_finished);
    results[2]=c.vkCreateFence(self.logical_device,&fence_info,null,&self.in_flight_fence);
    if(!std.mem.allEqual(c.VkResult,&results,c.VK_SUCCESS))
        return error.FailedToCreateAllSemaphores;
}
fn DebugUtilsMessengerCreateInfo_new() c.VkDebugUtilsMessengerCreateInfoEXT {
    return .{
        .sType=c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = 
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | 
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | 
            c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType =
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debug_fn,
        .pNext=null,
        .pUserData=null,
        .flags=0,
    };
}
fn VulkanHasVLSupport(available_validation_layers:[]c.VkLayerProperties,for_layer_name:[:0] const u8) std.mem.Allocator.Error!bool {
    for(available_validation_layers) |layer| {
        const layer_name=std.mem.sliceTo(&layer.layerName,0);
        if(std.mem.eql(u8,for_layer_name,layer_name)) return true;
    }
    return false;
}
fn AsVkInstancePFN(comptime fn_str:[:0]const u8,vk_i:c.VkInstance) std.meta.Child(@field(c,"PFN_"++fn_str)){
    const PFNOpt:type=@field(c,"PFN_"++fn_str);
    if(c.vkGetInstanceProcAddr(vk_i,fn_str)) |func|
        if(@as(PFNOpt,@ptrCast(func))) |func2|
            return func2;
    @panic("'PFN_"++fn_str++"' not found in vkGetInstanceProcAddr");
}
//Vulkan validation layer debug function.
fn debug_fn(msg_severity:c.VkDebugUtilsMessageSeverityFlagBitsEXT,msg_type:c.VkDebugUtilsMessageTypeFlagsEXT,p_callbackdata:[*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    _:?*anyopaque) callconv(.C) c.VkBool32 {
    std.debug.print("VL Message (type:{},severity:{}): {s}\n",.{msg_type,msg_severity,p_callbackdata.*.pMessage});
    return c.VK_FALSE;
}