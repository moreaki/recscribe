#pragma once

#include <stdexcept>
#include <string>
#include <vector>

namespace recscribe_probe {
struct BackendEvidence {
    std::string device_name, registry, device_type, backend_name;
};

inline bool metal_gpu(const BackendEvidence & item) {
    // GGML 0.27.0 identifies its Metal plugin registry as "MTL". Retain that
    // actual API identity; the user-facing technology name is not its key.
    return item.registry == "MTL" && (item.device_type == "gpu" || item.device_type == "igpu");
}

inline void valid_backend_fields(const BackendEvidence & item, bool selected) {
    if (item.device_name.empty() || item.device_name.size() > 128 || item.registry.empty() || item.registry.size() > 128 ||
        (item.device_type != "cpu" && item.device_type != "gpu" && item.device_type != "igpu" &&
         item.device_type != "accel" && item.device_type != "meta") ||
        (selected && (item.backend_name.empty() || item.backend_name.size() > 128))) {
        throw std::runtime_error("Missing or unbounded actual backend identity");
    }
}

inline void validate_backend_inventory(const std::vector<BackendEvidence> & devices, bool use_gpu) {
    if (devices.empty() || devices.size() > 32) throw std::runtime_error("No bounded GGML device inventory; load pinned backends before model initialization");
    bool cpu = false, first_gpu_seen = false, first_gpu_metal = false;
    for (const auto & device : devices) {
        valid_backend_fields(device, false);
        cpu = cpu || device.device_type == "cpu";
        if (!first_gpu_seen && (device.device_type == "gpu" || device.device_type == "igpu")) {
            first_gpu_seen = true; first_gpu_metal = metal_gpu(device);
        }
    }
    if (!cpu) throw std::runtime_error("Pinned CPU backend unavailable before model initialization");
    if (use_gpu && (!first_gpu_seen || !first_gpu_metal))
        throw std::runtime_error("Fixed GPU diagnostic requires the selected first GPU device to be Metal");
}

inline void validate_selected_backends(const std::vector<BackendEvidence> & backends, bool use_gpu) {
    if (backends.empty() || backends.size() > 32) throw std::runtime_error("No bounded selected backend state");
    bool cpu = false;
    for (const auto & backend : backends) {
        valid_backend_fields(backend, true);
        cpu = cpu || backend.device_type == "cpu";
    }
    if (!cpu) throw std::runtime_error("Selected CPU fallback backend is unavailable");
    if (use_gpu && !metal_gpu(backends.front()))
        throw std::runtime_error("Requested Metal GPU was not actually selected; refusing silent CPU mode");
}

inline void validate_site_backend(const BackendEvidence & backend) {
    valid_backend_fields(backend, true);
    // A requested Metal configuration legitimately permits pinned CPU node
    // fallback. Record placement; do not turn it into an all-GPU requirement.
    if (!metal_gpu(backend) && !(backend.registry == "CPU" && backend.device_type == "cpu"))
        throw std::runtime_error("LayerNorm observation used an unexpected backend");
}
} // namespace recscribe_probe
