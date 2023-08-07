package graphics

import "core:fmt"
import "core:runtime"
import "core:strings"
import sa "core:container/small_array"

import "vendor:glfw"
import vk "vendor:vulkan"

debug_messenger_callback :: proc "system" (
        messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
        messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
        pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
        pUserData: rawptr \
) -> b32 {
        context = runtime.default_context()

        fmt.printf("%v: %v:\n", messageSeverity, messageTypes)
        fmt.printf("\tmessageIDName   = <%v>\n", pCallbackData.pMessageIdName)
        fmt.printf("\tmessageIDNumber = <%v>\n", pCallbackData.messageIdNumber)
        fmt.printf("\tmessage         = <%v>\n", pCallbackData.pMessage)

        if 0 < pCallbackData.queueLabelCount {
                fmt.printf("\tQueue Labels: \n")
                for i in 0..<pCallbackData.queueLabelCount {
                        fmt.printf("\t\tlabelName = <%v>\n", pCallbackData.pQueueLabels[i].pLabelName)
                }
        }
        if 0 < pCallbackData.cmdBufLabelCount {
                fmt.printf("\tCommandBuffer Labels: \n")
                for i in 0..<pCallbackData.cmdBufLabelCount {
                        fmt.printf("\t\tlabelName = <%v>\n", pCallbackData.pCmdBufLabels[i].pLabelName)
                }
        }
        if 0 < pCallbackData.objectCount {
                fmt.printf("Objects:\n")
                for i in 0..<pCallbackData.objectCount {
                        fmt.printf("\t\tObject %d\n", pCallbackData.pObjects[i].objectType)
                        fmt.printf("\t\t\tobjectType   = %s\n", pCallbackData.pObjects[i].objectType)
                        fmt.printf("\t\t\tobjectHandle = %d\n", pCallbackData.pObjects[i].objectHandle)
                        if pCallbackData.pObjects[i].pObjectName != nil {
                                fmt.printf("\t\t\tobjectName   = <%v>\n", pCallbackData.pObjects[i].pObjectName)
                        }
                }
        }
        return true
}

error_check :: proc(result: vk.Result) {
        if (result != .SUCCESS) {
                fmt.panicf("VULKAN: %s\n", result)
        }
}

init :: proc() -> (ctx: Context) {
        using ctx;
        create_window(&ctx)


        // Vulkan does not come loaded into Odin by default, 
        // so we need to begin by loading Vulkan's functions at runtime.
        // This can be achieved using glfw's GetInstanceProcAddress function.
        // the non-overloaded function is used to leverage auto_cast and avoid
        // funky rawptr type stuff.
        vk.load_proc_addresses_global(auto_cast glfw.GetInstanceProcAddress);

        // In order to get debug information while creating the 
        // Vulkan instance, the DebugCreateInfo is passed as part of the
        // InstanceCreateInfo.
        debug_utils_info := debug_utils_messenger_create_info()

        // Create Instance
        result: vk.Result
        instance, result = init_vulkan_instance(&debug_utils_info)
        error_check(result)

        // Load the rest of Vulkan's functions.
        vk.load_proc_addresses(instance)

        init_debug_utils_messenger(&ctx, &debug_utils_info)

        physical_device, result = init_physical_device_and_surface(&ctx)
        error_check(result)

        result = init_logical_device(&ctx);
        error_check(result)

        swapchain, result = create_swapchain(&ctx);
        error_check(result)

        return ctx
}

cleanup :: proc(using ctx: ^Context) {
        cleanup_swapchain(ctx)
        vk.DestroySurfaceKHR(instance, surface, nil)
        vk.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
        vk.DestroyInstance(nil, nil)
        cleanup_window(ctx)
}

init_vulkan_instance :: proc(debug_create_info: ^vk.DebugUtilsMessengerCreateInfoEXT) ->
(instance: vk.Instance, result: vk.Result) {
        application_info: vk.ApplicationInfo = {
                sType = vk.StructureType.APPLICATION_INFO,
                pApplicationName = "Untitled",
                pEngineName = "Odinpi",
                apiVersion = vk.API_VERSION_1_3,
        }

        // Available Extensions
	count: u32
	vk.EnumerateInstanceExtensionProperties(nil, &count, nil) or_return
	extensions := make([]vk.ExtensionProperties, count)
        defer delete(extensions)
	vk.EnumerateInstanceExtensionProperties(nil, &count, raw_data(extensions)) or_return

        // Required Extensions
        required_extensions: [dynamic]cstring
        defer delete(required_extensions)
        glfw_required_extensions := glfw.GetRequiredInstanceExtensions()
        append(&required_extensions, ..glfw_required_extensions)
        append(&required_extensions, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

        for required_extension in required_extensions {
                found := false
                for extension in extensions {
                        e := extension
                        extension_name := cstring(raw_data(&e.extensionName))
                        if required_extension == extension_name {
                                found = true
                                break
                        }
                }
                fmt.assertf(found, "%s not found", required_extension)
        }

        // Enabled Layers
        layers := []cstring { "VK_LAYER_KHRONOS_validation" }

        fmt.print("Enabled Extensions: ")
        for extension in required_extensions do fmt.printf("%s ", extension); fmt.println()

        fmt.print("Enabled Layers: ")
        for layer in layers do fmt.printf("%s ", layer); fmt.println()

        instance_create_info: vk.InstanceCreateInfo = {
                sType = vk.StructureType.INSTANCE_CREATE_INFO,
                flags = nil,
                enabledExtensionCount = u32(len(required_extensions)),
                ppEnabledExtensionNames = raw_data(required_extensions),
                enabledLayerCount = u32(len(layers)),
                ppEnabledLayerNames = raw_data(layers),
                pApplicationInfo = &application_info,
                pNext = debug_create_info,
        }

        vk.CreateInstance(&instance_create_info, nil, &instance) or_return

        return instance, result
}

debug_utils_messenger_create_info :: proc() -> (debug_utils: vk.DebugUtilsMessengerCreateInfoEXT) {
        return {
                sType = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                messageSeverity = vk.DebugUtilsMessageSeverityFlagsEXT { .WARNING, .ERROR },
                messageType = vk.DebugUtilsMessageTypeFlagsEXT { .GENERAL, .PERFORMANCE, .VALIDATION },
                pfnUserCallback = debug_messenger_callback,
        }
}

init_debug_utils_messenger :: proc(using ctx: ^Context, debug_utils: ^vk.DebugUtilsMessengerCreateInfoEXT) {
        result := vk.CreateDebugUtilsMessengerEXT(instance, debug_utils, nil, &debug_messenger)
}

init_physical_device_and_surface :: proc(using ctx: ^Context) ->
(pd: vk.PhysicalDevice, result: vk.Result) {
        count: u32
        vk.EnumeratePhysicalDevices(instance, &count, nil) or_return
        devices := make([]vk.PhysicalDevice, count)
        defer delete(devices)
        vk.EnumeratePhysicalDevices(instance, &count, raw_data(devices)) or_return

        for gpu in devices {
                // Properties
                properties: vk.PhysicalDeviceProperties
                vk.GetPhysicalDeviceProperties(gpu, &properties)

                if surface != 0 {
                        vk.DestroySurfaceKHR(instance, surface, nil)
                }

                create_surface(ctx)

                // Locate a device with the GRAPHICS queue flag
                // as well as surface support.
                vk.GetPhysicalDeviceQueueFamilyProperties(gpu, &count, nil)
                queue_family_properties := make([]vk.QueueFamilyProperties, count)
                defer delete(queue_family_properties)
                vk.GetPhysicalDeviceQueueFamilyProperties(gpu, &count, raw_data(queue_family_properties))
                for queue, index in queue_family_properties {
                        supported: b32
                        vk.GetPhysicalDeviceSurfaceSupportKHR(gpu, u32(index), surface, &supported) or_return

                        if supported && .GRAPHICS in queue.queueFlags {
                                queue_indices[.GRAPHICS] = index
                                break;
                        }
                }
                fmt.printf("Enabled GPU: %s\n", cstring(raw_data(&properties.deviceName)))
                pd = gpu
                break
        }
        return pd, .SUCCESS
}

init_logical_device :: proc(using ctx: ^Context) -> vk.Result {
        count: u32
        vk.EnumerateDeviceExtensionProperties(physical_device, nil, &count, nil) or_return
        extensions := make([]vk.ExtensionProperties, count)
        defer delete(extensions)
        vk.EnumerateDeviceExtensionProperties(physical_device, nil, &count, raw_data(extensions)) or_return

        required_extensions := make([dynamic]cstring, 0, 2)
        defer delete(required_extensions)


        // If portability subset is found in device extensions,
        // it must be enabled.
        portability_found := false
        for extension in extensions {
                e := extension
                switch(cstring(raw_data(&e.extensionName))) {
                        case "VK_KHR_portability_subset":
                                portability_found = true
                                break

                }
        }

        if portability_found {
                append(&required_extensions, "VK_KHR_portability_subset")
        } 

        if swapchain_is_supported(physical_device) {
                append(&required_extensions, vk.KHR_SWAPCHAIN_EXTENSION_NAME)
        } else {
                fmt.panicf("Swapchain is not supported!\n")
        }

        // Unused
        queuePriority: f32 = 1

        queue_create_info : vk.DeviceQueueCreateInfo = {
                sType = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
                queueFamilyIndex = u32(queue_indices[.GRAPHICS]),
                queueCount = 1,
                pQueuePriorities = &queuePriority,
        }

        shader_features: vk.PhysicalDeviceShaderDrawParametersFeatures = {
                sType = .PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
                shaderDrawParameters = true,
        }

        device_create_info: vk.DeviceCreateInfo = {
                sType = .DEVICE_CREATE_INFO,
                enabledExtensionCount = u32(len(required_extensions)),
                ppEnabledExtensionNames = raw_data(required_extensions),
                queueCreateInfoCount = 1,
                pQueueCreateInfos = &queue_create_info,
                pNext = &shader_features,
        }
        vk.CreateDevice(physical_device, &device_create_info, nil, &device) or_return

        return .SUCCESS
}

init_allocator :: proc(using ctx: ^Context) -> vk.Result {
        /* To be implemented */
        return .SUCCESS
}


