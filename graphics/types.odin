package graphics

import vk "vendor:vulkan"
import "vendor:glfw"

MAX_FRAMES_IN_FLIGHT :: 2

Context :: struct
{
	debug_messenger: vk.DebugUtilsMessengerEXT,

	instance: vk.Instance,
  	device:   vk.Device,
	physical_device: vk.PhysicalDevice,
	swapchain: Swapchain,
	pipeline: Pipeline,
	queue_indices:   [QueueFamily]int,
	queues:   [QueueFamily]vk.Queue,
	surface:  vk.SurfaceKHR,
	window:   glfw.WindowHandle,
	command_pool: vk.CommandPool,
	command_buffers: [MAX_FRAMES_IN_FLIGHT]vk.CommandBuffer,
	vertex_buffer: Buffer,
	index_buffer: Buffer,
	
	image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	render_finished: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore,
	in_flight: [MAX_FRAMES_IN_FLIGHT]vk.Fence,
	
	curr_frame: u32,
	framebuffer_resized: bool,
}

Buffer :: struct
{
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	length: int,
	size:   vk.DeviceSize,
}

Pipeline :: struct
{
	handle: vk.Pipeline,
	render_pass: vk.RenderPass,
	layout: vk.PipelineLayout,
}

QueueFamily :: enum
{
	GRAPHICS,
	PRESENT,
}

Vertex :: struct
{
	pos: [2]f32,
	color: [3]f32,
}

DEVICE_EXTENSIONS := [?]cstring{
	"VK_KHR_swapchain",
};

VALIDATION_LAYERS := [?]cstring{"VK_LAYER_KHRONOS_validation"};