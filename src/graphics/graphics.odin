package graphics

import "core:fmt"
import "core:log"
import "core:runtime"
import "core:c"
import "core:math"
import "core:mem"
import "core:container/intrusive/list"
import la "core:math/linalg"

import "vendor:glfw"
import vk "vendor:vulkan"
import "pkgs:vma"

import "builders"

RenderContext :: struct {
    instance:             vk.Instance,
    window:               glfw.WindowHandle,
    gpu:                  vk.PhysicalDevice,
    gpu_properties:       vk.PhysicalDeviceProperties,
    queues:               [QueueFamily]vk.Queue,
    queue_indices:        [QueueFamily]int,
    device:               vk.Device,
    surface:              vk.SurfaceKHR,
    swapchain:            Swapchain,
    render_pass:          vk.RenderPass,
    descriptor_pool:      vk.DescriptorPool,
    stage:                StagingPlatform,
    perframes:            []Perframe,
    semaphore_pool:       []SemaphoreLink,
    semaphore_list:       list.List,
    framebuffers:         []vk.Framebuffer,
    depth_image:          Image,

    scene:                Scene,
    camera_data:          CameraData,

    mat_cache:            MaterialCache,

    window_needs_resize:  bool,
}

WINDOW_HEIGHT :: 720
WINDOW_WIDTH :: 1280
WINDOW_TITLE :: "Hyoga"
OBJECT_COUNT :: 12

@private
g_time : f32 = 0

update :: proc(ctx: ^RenderContext) -> bool {
    index: u32
    result: vk.Result

    result = acquire_image(ctx, &index)
    if result == .SUBOPTIMAL_KHR || result == .ERROR_OUT_OF_DATE_KHR {
        resize(ctx)
    }

    result = draw(ctx, index)

    result = present_image(ctx, index)
    if result == .SUBOPTIMAL_KHR || result == .ERROR_OUT_OF_DATE_KHR {
        resize(ctx)
    }

    if ctx.window_needs_resize do resize(ctx)

    return result != .SUCCESS
}

acquire_image :: proc(using this: ^RenderContext, image: ^u32) -> vk.Result {
    assert(!list.is_empty(&semaphore_list))
    semaphore := container_of(list.pop_front(&semaphore_list), SemaphoreLink, "link")

    result := vk.AcquireNextImageKHR(
        device,
        swapchain.handle,
        max(u64),
        semaphore.semaphore,
        0,
        image,
    )

    if (result != .SUCCESS && result != .SUBOPTIMAL_KHR) {
        return result
    }

    // If we have outstanding fences for this swapchain image, wait for them to complete first.
    // After begin frame returns, it is safe to reuse or delete resources which
    // were used previously.
    //
    // We wait for fences which completes N frames earlier, so we do not stall,
    // waiting for all GPU work to complete before this returns.
    // Normally, this doesn't really block at all,
    // since we're waiting for old frames to have been completed, but just in case.

    if perframes[image^].in_flight_fence != 0 {
        fences := []vk.Fence{perframes[image^].in_flight_fence}
        vk.WaitForFences(device, 1, raw_data(fences), true, max(u64)) or_return
        vk.ResetFences(device, 1, raw_data(fences)) or_return
    }

    if perframes[image^].command_pool != 0 {
        vk.ResetCommandPool(device, perframes[image^].command_pool, {}) or_return
    }

    if perframes[image^].image_available != nil {
        list.push_front(&semaphore_list, &perframes[image^].image_available.link)
    }

    perframes[image^].image_available = semaphore

    return .SUCCESS
}

draw :: proc(this: ^RenderContext, index: u32) -> vk.Result {
    g_time += 1

    cmd := this.perframes[index].command_buffer

    begin_info := vk.CommandBufferBeginInfo {
        sType = .COMMAND_BUFFER_BEGIN_INFO,
        flags = {.ONE_TIME_SUBMIT},
    }

    vk.BeginCommandBuffer(cmd, &begin_info) or_return

    shadow_exec_shadow_pass(&this.scene, cmd, this.swapchain.extent, int(index), OBJECT_COUNT)
    
    clear_values := []vk.ClearValue {
        { color = { float32 = [4]f32{ 0.01, 0.01, 0.01, 1.0 }}},
        { depthStencil = { depth = 1 }},
    }

    rp_begin: vk.RenderPassBeginInfo = {
        sType = .RENDER_PASS_BEGIN_INFO,
        renderPass = this.render_pass,
        framebuffer = this.framebuffers[index],
        renderArea = {extent = this.swapchain.extent},
        clearValueCount = u32(len(clear_values)),
        pClearValues = raw_data(clear_values),
    }

    vk.CmdBeginRenderPass(cmd, &rp_begin, vk.SubpassContents.INLINE)

    viewport: vk.Viewport = {
        width    = f32(this.swapchain.extent.width),
        height   = f32(this.swapchain.extent.height),
        minDepth = 0, maxDepth = 1,
    }
    vk.CmdSetViewport(cmd, 0, 1, &viewport)

    scissor: vk.Rect2D = { extent = this.swapchain.extent }
    vk.CmdSetScissor(cmd, 0, 1, &scissor)

    scene_render(&this.scene, &this.perframes[index])
    
    vk.CmdEndRenderPass(cmd)
    
    vk.EndCommandBuffer(cmd) or_return

    wait_stage: vk.PipelineStageFlags = { .COLOR_ATTACHMENT_OUTPUT }

    submit_info: vk.SubmitInfo = {
        sType                = .SUBMIT_INFO,
        commandBufferCount   = 1,
        pCommandBuffers      = &cmd,
        waitSemaphoreCount   = 1,
        pWaitSemaphores      = &this.perframes[index].image_available.semaphore,
        pWaitDstStageMask    = &wait_stage,
        signalSemaphoreCount = 1,
        pSignalSemaphores    = &this.perframes[index].render_finished,
    }

    vk.QueueSubmit(this.queues[.GRAPHICS], 1, &submit_info, this.perframes[index].in_flight_fence)
    return .SUCCESS
}

present_image :: proc(using ctx: ^RenderContext, index: u32) -> vk.Result {
    i := index

    present_info: vk.PresentInfoKHR = {
        sType              = .PRESENT_INFO_KHR,
        swapchainCount     = 1,
        pSwapchains        = &swapchain.handle,
        pImageIndices      = &i,
        waitSemaphoreCount = 1,
        pWaitSemaphores    = &perframes[index].render_finished,
    }

    return vk.QueuePresentKHR(queues[.PRESENT], &present_info)
}

resize :: proc(this: ^RenderContext) -> bool {

    surface_properties: vk.SurfaceCapabilitiesKHR
    vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(this.gpu, this.surface, &surface_properties)
    if surface_properties.currentExtent == this.swapchain.extent do return false

    for x, y : i32; x == 0 && y == 0; {
        x, y = glfw.GetFramebufferSize(this.window)
        glfw.WaitEvents()
    }

    swapchain_destroy_framebuffers(this.device, this.framebuffers)

    this.swapchain = swapchain_create(this.device,
                                      this.gpu, 
                                      this.surface, 
                                      this.queue_indices,
                                      this.swapchain.handle)

    this.framebuffers = swapchain_create_framebuffers(this.device,
                                                      this.render_pass,
                                                      this.swapchain,
                                                      this.depth_image)

    this.window_needs_resize = false

    return true
}

init :: proc(this: ^RenderContext) {
    this.window = init_window(this)

    // Vulkan does not come loaded into Odin by default, 
    // so we need to begin by loading Vulkan's functions at runtime.
    // This can be achieved using glfw's GetInstanceProcAddress function.
    // the non-overloaded function is used to leverage auto_cast and avoid
    // funky rawptr type stuff.
    vk.load_proc_addresses_global(auto_cast glfw.GetInstanceProcAddress)
    
    extensions: [dynamic]cstring
    defer delete(extensions)
    append(&extensions, ..glfw.GetRequiredInstanceExtensions())
    this.instance = builders.create_instance(extensions[:])

    // Load the rest of Vulkan's functions.
    vk.load_proc_addresses(this.instance)
    
    this.gpu,
    this.gpu_properties,
    this.surface,
    this.queue_indices = gpu_create(this.instance, this.window)

    this.device, this.queues = device_create(this.gpu, this.queue_indices)

    this.swapchain = swapchain_create(this.device,
                                      this.gpu, 
                                      this.surface, 
                                      this.queue_indices)

    this.render_pass = builders.create_render_pass(this.device,
                                                   this.swapchain.format.format) 

    this.perframes = create_perframes(this.device, len(this.swapchain.images))

    this.descriptor_pool = descriptors_create_pool(this.device, 1000) 

    this.semaphore_pool, this.semaphore_list = create_sync_objects(this.device, int(this.swapchain.image_count) + 1)

    buffers_init({
        physicalDevice = this.gpu,
        instance = this.instance,
        device = this.device,
        vulkanApiVersion = vk.API_VERSION_1_3,
    },  this.queues[.TRANSFER], 
        this.gpu_properties)

    this.stage = buffers_create_staging(this.device, this.queues[.TRANSFER])

    mats_init(&this.mat_cache)

    scene_init(&this.scene, this)
    
    extent := vk.Extent3D {
        this.swapchain.extent.width, 
        this.swapchain.extent.height,
        1,
    }
    this.depth_image = buffers_create_image(this.device, extent)

    this.framebuffers = swapchain_create_framebuffers(this.device,
                                                      this.render_pass,
                                                      this.swapchain,
                                                      this.depth_image)
}

init_window :: proc(this: ^RenderContext) -> glfw.WindowHandle {
    glfw.SetErrorCallback(glfw_error_callback)
    glfw.Init()

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

    window := glfw.CreateWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE, nil, nil)
    glfw.SetWindowUserPointer(window, this);

    glfw.SetWindowSizeCallback(window, proc "c" (win: glfw.WindowHandle, w, h: c.int) {
        ctx := cast(^RenderContext)glfw.GetWindowUserPointer(win)
        ctx.window_needs_resize = true
    })

    if (!glfw.VulkanSupported()) {
        panic("Vulkan not supported!")
    }

    return window;
}

create_perframes :: proc(device: vk.Device, count: int) ->
(perframes: []Perframe) {
    perframes = make([]Perframe, count)

    for _, i in perframes {
        p := &perframes[i]
        p.index = uint(i)
        p.image_available = nil
        p.render_finished = builders.create_semaphore(device)
        p.in_flight_fence = builders.create_fence(device, { .SIGNALED })
        p.command_pool    = builders.create_command_pool(device, { .TRANSIENT, .RESET_COMMAND_BUFFER })
        p.command_buffer  = builders.create_command_buffer(device, p.command_pool)
    }

    return perframes
}

create_sync_objects :: proc(device: vk.Device, count: int) ->
(semaphores: []SemaphoreLink, sem_list: list.List) {
    semaphores = make([]SemaphoreLink, count)[0:count]
    for _, i in semaphores {
        semaphores[i] = { semaphore = builders.create_semaphore(device) }
        list.push_front(&sem_list, &semaphores[i].link)
    }
    return semaphores, sem_list
}

cleanup :: proc(this: ^RenderContext) {
    vk.DeviceWaitIdle(this.device)

    scene_shutdown(&this.scene)

    mats_shutdown(&this.mat_cache, this.device)

    buffers_destroy_staging(this.stage)

    vk.DestroyDescriptorPool(this.device, this.descriptor_pool, nil)

    swapchain_destroy_framebuffers(this.device, this.framebuffers)

    vk.DestroyRenderPass(this.device, this.render_pass, nil)

    buffers_destroy(this.device, this.depth_image)

    swapchain_destroy(this.device, this.swapchain)

    for sem in this.semaphore_pool do vk.DestroySemaphore(this.device, sem.semaphore, nil)
    delete(this.semaphore_pool)

    cleanup_perframes(this)

    buffers_shutdown()

    vk.DestroyDevice(this.device, nil)
    vk.DestroySurfaceKHR(this.instance, this.surface, nil)
    vk.DestroyInstance(this.instance, nil)

    glfw.DestroyWindow(this.window)
    glfw.Terminate()
}

cleanup_perframes :: proc(using ctx: ^RenderContext) {
    for perframe in perframes {
        vk.DestroyCommandPool(device, perframe.command_pool, nil)
        vk.DestroyFence(device, perframe.in_flight_fence, nil)
        vk.DestroySemaphore(device, perframe.render_finished, nil)
    }
    delete(perframes)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        glfw.SetWindowShouldClose(window, glfw.TRUE)
    }
}
