#include "activation_stats.h"
#include "backend_policy.h"
#include "probe_inputs.h"
#include <cassert>
#include <limits>

template<class F> static void rejects(F f) {
    bool failed = false;
    try { f(); } catch (const std::runtime_error &) { failed = true; }
    assert(failed);
}

int main() {
    using recscribe_probe::BackendEvidence;
    const BackendEvidence cpu{"CPU", "CPU", "cpu", "CPU"};
    const BackendEvidence metal{"MTL0", "MTL", "gpu", "Metal"};
    const BackendEvidence cuda{"CUDA0", "CUDA", "gpu", "CUDA"};
    using recscribe_probe::validate_backend_inventory;
    using recscribe_probe::validate_selected_backends;
    using recscribe_probe::validate_site_backend;
    rejects([&] { validate_backend_inventory({}, true); });
    rejects([&] { validate_backend_inventory({cpu}, true); });
    rejects([&] { validate_backend_inventory({metal}, true); });
    rejects([&] { validate_backend_inventory({cuda, metal, cpu}, true); });
    validate_backend_inventory({cpu}, false);
    validate_backend_inventory({metal, cpu}, true);
    auto display_name = metal; display_name.registry = "Metal";
    rejects([&] { validate_backend_inventory({display_name, cpu}, true); });
    auto integrated = metal; integrated.device_type = "igpu";
    validate_backend_inventory({integrated, cpu}, true); // Upstream also accepts IGPU.
    rejects([&] { validate_selected_backends({cpu}, true); });
    rejects([&] { validate_selected_backends({metal}, true); });
    validate_selected_backends({metal, cpu}, true);
    validate_site_backend(cpu); // Legitimate CPU placement in Metal mode.
    validate_site_backend(metal);
    rejects([&] { validate_site_backend(cuda); });
    auto unnamed = metal; unnamed.backend_name.clear();
    rejects([&] { validate_selected_backends({unnamed, cpu}, true); });
    using recscribe_probe::ChannelStats;
    ChannelStats s(3);
    const float values[] = {-2, 0, 3, 4, -5, 0};
    s.observe(values, 3, 2);
    assert(s.count == 2 && s.observations == 1);
    assert((s.sum_abs == std::vector<double>{6, 5, 3}));
    assert((s.sum_squares == std::vector<double>{20, 25, 9}));
    assert((s.max_abs == std::vector<double>{4, 5, 3}));
    rejects([&] { s.observe(values, 3, 2); }); // Duplicate callback is not more data.
    rejects([&] { ChannelStats invalid(0); });
    rejects([&] { ChannelStats invalid(1281); });
    ChannelStats clean(3);
    rejects([&] { clean.observe(values, 2, 2); });
    rejects([&] { clean.observe(values, 3, 0); });
    rejects([&] { clean.observe(values, 3, 65); });
    rejects([&] { clean.observe(nullptr, 3, 2); });
    const float invalid[] = {1, std::numeric_limits<float>::infinity(), 2};
    rejects([&] { clean.observe(invalid, 3, 1); });
    assert(clean.count == 0 && clean.observations == 0);
    assert((clean.sum_abs == std::vector<double>{0, 0, 0}));
    ChannelStats extremes(1);
    const float largest[] = {std::numeric_limits<float>::max()};
    extremes.observe(largest, 1, 1);
    assert(std::isfinite(extremes.sum_squares[0])); // Accumulate F32 in double.

    using recscribe_probe::valid_utf8;
    assert(valid_utf8({'a', 0xc3, 0xa4, 0xe4, 0xb8, 0xad}));
    assert(!valid_utf8({}));
    assert(!valid_utf8({'a', 0, 'b'}));
    assert(!valid_utf8({0xc0, 0xaf})); // Overlong.
    assert(!valid_utf8({0xed, 0xa0, 0x80})); // Surrogate.
    assert(!valid_utf8({0xf4, 0x90, 0x80, 0x80})); // Beyond Unicode.
    assert(!valid_utf8({0xe4, 0xb8})); // Truncated.
    using recscribe_probe::serialize_token_prefix;
    assert((serialize_token_prefix({1, 0x1234, 51864}) ==
        std::vector<std::uint8_t>{1,0,0,0, 0x34,0x12,0,0, 0x98,0xca,0,0}));
    rejects([&] { serialize_token_prefix({}); });
    rejects([&] { serialize_token_prefix({-1}); });
    rejects([&] { serialize_token_prefix({51865}); });
    rejects([&] { serialize_token_prefix(std::vector<std::int32_t>(65, 1)); });
    std::vector<std::uint8_t> wav = {
        'R','I','F','F', 40,0,0,0, 'W','A','V','E',
        'f','m','t',' ', 16,0,0,0, 1,0, 1,0,
        0x80,0x3e,0,0, 0,0x7d,0,0, 2,0, 16,0,
        'd','a','t','a', 4,0,0,0, 0,0x80, 0xff,0x7f
    };
    using recscribe_probe::pcm16_mono_16k;
    const auto pcm = pcm16_mono_16k(wav);
    assert(pcm.size() == 2 && pcm[0] == -1.0f && pcm[1] == 32767.0f / 32768);
    auto wrong = wav; wrong[22] = 2; // Stereo rejected, never silently mixed.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[24] = 0x44; // Wrong sample rate.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[20] = 3; // Float format.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong.pop_back();
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[40] = 3; // Partial sample/trailing chunk bytes.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[40] = 100; // Truncated data.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[36] = 'J'; // Missing data.
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong[12] = 'J'; // Missing format.
    rejects([&] { pcm16_mono_16k(wrong); });
    // Duplicate format/audio chunks cannot silently replace the original.
    const auto set_size = [](std::vector<std::uint8_t> & bytes) {
        const auto size = bytes.size() - 8;
        for (int i = 0; i < 4; ++i) bytes[4 + i] = (size >> (8 * i)) & 0xff;
    };
    wrong = wav; wrong.insert(wrong.end(), wav.begin() + 12, wav.begin() + 36); set_size(wrong);
    rejects([&] { pcm16_mono_16k(wrong); });
    wrong = wav; wrong.insert(wrong.end(), wav.begin() + 36, wav.end()); set_size(wrong);
    rejects([&] { pcm16_mono_16k(wrong); });
}
