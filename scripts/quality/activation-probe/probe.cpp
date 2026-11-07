// Offline research executable only. The pinned source is compiled into this TU
// so its private decoder scheduler can be observed without altering upstream or
// the public ABI. Do not link libwhisper as well.
#ifndef RECSCRIBE_WHISPER_SOURCE
#error "Build through the pinned diagnostic CMake target"
#endif
#include RECSCRIBE_WHISPER_SOURCE
#include "activation_stats.h"
#include "backend_policy.h"
#include "probe_inputs.h"

#include <cerrno>
#include <CommonCrypto/CommonDigest.h>
#include <csignal>
#include <filesystem>
#include <fcntl.h>
#include <iomanip>
#include <memory>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;
namespace rp = recscribe_probe;
static volatile std::sig_atomic_t interrupted = 0;
static void interrupt_handler(int) { interrupted = 1; }
static void require(bool value, const char * message) { if (!value) throw std::runtime_error(message); }

static std::string sha256(const std::vector<std::uint8_t> & bytes) {
    require(bytes.size() <= 16 * 1024, "Hash input exceeds diagnostic bound");
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.data(), CC_LONG(bytes.size()), result);
    std::ostringstream text;
    text << std::hex << std::setfill('0');
    for (const auto byte : result) text << std::setw(2) << unsigned(byte);
    return text.str();
}

static std::string json_string(const std::string & value) {
    std::ostringstream text;
    text << '"';
    for (const unsigned char c : value) {
        if (c == '"' || c == '\\') text << '\\' << char(c);
        else if (c < 0x20) text << "\\u" << std::hex << std::setfill('0') << std::setw(4) << unsigned(c) << std::dec;
        else text << char(c);
    }
    text << '"';
    return text.str();
}

static rp::BackendEvidence device_evidence(ggml_backend_dev_t device, ggml_backend_t backend = nullptr) {
    require(device != nullptr, "Actual GGML device identity is unavailable");
    const auto registry = ggml_backend_dev_backend_reg(device);
    require(registry != nullptr, "Actual GGML registry identity is unavailable");
    const auto kind = ggml_backend_dev_type(device);
    const char * type = kind == GGML_BACKEND_DEVICE_TYPE_CPU ? "cpu" :
        kind == GGML_BACKEND_DEVICE_TYPE_GPU ? "gpu" : kind == GGML_BACKEND_DEVICE_TYPE_IGPU ? "igpu" :
        kind == GGML_BACKEND_DEVICE_TYPE_ACCEL ? "accel" : kind == GGML_BACKEND_DEVICE_TYPE_META ? "meta" : "unknown";
    const char * name = ggml_backend_dev_name(device), * reg = ggml_backend_reg_name(registry);
    const char * selected = backend ? ggml_backend_name(backend) : "";
    require(name != nullptr && reg != nullptr && selected != nullptr, "Actual GGML backend names are unavailable");
    return {name, reg, type, selected};
}

static void append_backend(std::ostringstream & out, const rp::BackendEvidence & value) {
    out << "{\"device_name\":" << json_string(value.device_name) << ",\"registry\":" << json_string(value.registry)
        << ",\"device_type\":" << json_string(value.device_type) << ",\"backend_name\":" << json_string(value.backend_name) << '}';
}

static std::vector<rp::BackendEvidence> initialize_backends(bool use_gpu) {
    // Match the pinned official CLI caller's required dynamic registration.
    ggml_backend_load_all();
    const auto count = ggml_backend_dev_count();
    require(count > 0 && count <= 32, "GGML backend loading produced no bounded device inventory");
    std::vector<rp::BackendEvidence> devices;
    for (std::size_t i = 0; i < count; ++i) devices.push_back(device_evidence(ggml_backend_dev_get(i)));
    rp::validate_backend_inventory(devices, use_gpu);
    return devices;
}

struct Options {
    fs::path model, wav, reference, output, cancel;
    std::string language;
    int threads = 2;
    bool cpu = false;
};

static void nonsymlink_path(const fs::path & p, bool must_exist) {
    require(p.is_absolute(), "Paths must be absolute");
    fs::path current;
    for (const auto & part : p) {
        require(part != ".." && part != ".", "Path traversal is unavailable");
        current /= part;
        require(!fs::is_symlink(fs::symlink_status(current)), "Symlink paths are unavailable");
    }
    if (must_exist) require(fs::is_regular_file(p), "Input must be an existing regular file");
    else require(fs::is_directory(p.parent_path()), "Output parent must exist");
}

static Options options(int argc, char ** argv) {
    Options out;
    std::map<std::string, std::string> values;
    for (int i = 1; i < argc; ++i) {
        const std::string key = argv[i];
        if (key == "--cpu") { require(!out.cpu, "Duplicate option"); out.cpu = true; continue; }
        require(key == "--model" || key == "--wav" || key == "--reference" ||
            key == "--output" || key == "--cancel" || key == "--language" || key == "--threads", "Unknown option");
        require(i + 1 < argc && !values.count(key), "Missing or duplicate argument");
        values[key] = argv[++i];
    }
    for (const char * key : {"--model", "--wav", "--reference", "--output", "--language", "--cancel"})
        require(values.count(key) && !values[key].empty(), "Missing required argument");
    out.model = values["--model"]; out.wav = values["--wav"]; out.reference = values["--reference"];
    out.output = values["--output"]; out.cancel = values["--cancel"]; out.language = values["--language"];
    if (values.count("--threads")) {
        require(values["--threads"] == "1" || values["--threads"] == "2", "Use one or two threads");
        out.threads = values["--threads"] == "1" ? 1 : 2;
    }
    const std::vector<std::string> languages = {"de", "fr", "it", "en", "ar", "zh", "es", "pt"};
    require(std::find(languages.begin(), languages.end(), out.language) != languages.end(), "Use an explicit supported base language");
    for (const auto & p : {out.model, out.wav, out.reference}) nonsymlink_path(p, true);
    nonsymlink_path(out.output, false); nonsymlink_path(out.cancel, false);
    require(!fs::exists(out.output), "Refusing to overwrite diagnostic evidence");
    require(out.output != out.model && out.output != out.wav && out.output != out.reference &&
        out.output != out.cancel, "Output must be separate from inputs/cancellation");
    require(fs::file_size(out.model) <= 512ULL * 1024 * 1024, "Only smaller original models are supported");
    require(!std::getenv("ANEFORGE_ENCODER"), "ANEForge bypass is unavailable in this diagnostic");
    return out;
}

static std::vector<std::uint8_t> read_bounded(const fs::path & p, std::size_t maximum) {
    const auto size = fs::file_size(p);
    require(size <= maximum, "Input exceeds diagnostic byte bound");
    std::ifstream f(p, std::ios::binary);
    require(bool(f), "Cannot open diagnostic input");
    std::vector<std::uint8_t> b(std::size_t(size), 0);
    f.read(reinterpret_cast<char *>(b.data()), std::streamsize(b.size()));
    require(f.gcount() == std::streamsize(b.size()) && f.peek() == std::char_traits<char>::eof() && !f.bad(),
        "Input changed or cannot be read within its byte bound");
    return b;
}

struct Target {
    std::string site;
    const ggml_tensor * gamma;
    const ggml_tensor * beta;
    rp::ChannelStats stats;
    rp::BackendEvidence backend;
    Target(std::string name, const ggml_tensor * g, const ggml_tensor * b, int width)
        : site(std::move(name)), gamma(g), beta(b), stats(std::size_t(width)) {}
};

struct Probe {
    const Options & opt;
    std::int64_t deadline;
    std::vector<Target> targets;
    std::string error;
    ggml_backend_sched_t decoder_scheduler = nullptr;
    bool stopped() const {
        return interrupted || fs::exists(opt.cancel) || ggml_time_us() >= deadline;
    }
};

static bool abort_compute(void * data) {
    try { return static_cast<Probe *>(data)->stopped(); } catch (...) { return true; }
}

static bool observe(ggml_tensor * tensor, bool ask, void * data) {
    auto & probe = *static_cast<Probe *>(data);
    try {
        if (probe.stopped()) { if (!ask) probe.error = "Cancelled or timed out"; return false; }
        if (tensor->op != GGML_OP_ADD || !tensor->src[0] || !tensor->src[1]) return !ask;
        Target * selected = nullptr;
        for (auto & target : probe.targets) {
            if (tensor->src[1] == target.beta) { selected = &target; break; }
        }
        if (!selected) return !ask;
        // Match post-affine LayerNorm by exact original gamma/beta pointers,
        // never by a graph-name substring or approximate layer index.
        require(tensor->src[0]->op == GGML_OP_MUL &&
            (tensor->src[0]->src[0] == selected->gamma || tensor->src[0]->src[1] == selected->gamma),
            "Matched bias is not a post-affine LayerNorm output");
        if (ask) return true;
        const auto backend = ggml_backend_sched_get_tensor_backend(probe.decoder_scheduler, tensor);
        require(backend != nullptr, "LayerNorm scheduler backend is unavailable");
        selected->backend = device_evidence(ggml_backend_get_device(backend), backend);
        rp::validate_site_backend(selected->backend);
        require(tensor->type == GGML_TYPE_F32 && ggml_is_contiguous(tensor) &&
            tensor->ne[0] == std::int64_t(selected->stats.channels) && tensor->ne[1] > 0 &&
            tensor->ne[1] <= 64 && tensor->ne[2] == 1 && tensor->ne[3] == 1 &&
            ggml_nbytes(tensor) == selected->stats.channels * std::size_t(tensor->ne[1]) * sizeof(float),
            "Unexpected LayerNorm activation layout");
        std::vector<float> values(ggml_nelements(tensor));
        ggml_backend_tensor_get(tensor, values.data(), 0, ggml_nbytes(tensor));
        selected->stats.observe(values.data(), selected->stats.channels, std::size_t(tensor->ne[1]));
        return true;
    } catch (const std::exception & e) { probe.error = e.what(); return false; }
      catch (...) { probe.error = "Unknown diagnostic callback failure"; return false; }
}

static void append_values(std::ostringstream & out, const std::vector<double> & values) {
    out << '[';
    for (std::size_t i = 0; i < values.size(); ++i) { if (i) out << ','; out << values[i]; }
    out << ']';
}

static void exclusive_output(const fs::path & path, const std::string & bytes) {
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    require(fd >= 0, "Cannot create exclusive diagnostic output");
    std::size_t written = 0;
    while (written < bytes.size()) {
        const auto count = ::write(fd, bytes.data() + written, bytes.size() - written);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { ::close(fd); throw std::runtime_error("Cannot write diagnostic output"); }
        written += std::size_t(count);
    }
    const int sync_result = ::fsync(fd), close_result = ::close(fd);
    require(sync_result == 0 && close_result == 0, "Cannot finalize diagnostic output");
}

int main(int argc, char ** argv) {
    try {
        std::signal(SIGINT, interrupt_handler); std::signal(SIGTERM, interrupt_handler);
        if (argc == 2 && std::string(argv[1]) == "--inspect-backends") {
            const auto devices = initialize_backends(true);
            std::ostringstream out;
            out << "{\"schema_version\":\"whisper-probe-backend-inspection-v1\",\"status\":\"registered\","
                << "\"initializer\":\"ggml_backend_load_all\",\"metal_gpu_available\":true,\"available_devices\":[";
            for (std::size_t i = 0; i < devices.size(); ++i) { if (i) out << ','; append_backend(out, devices[i]); }
            out << "],\"model_loaded\":false,\"encoder_passes\":0,\"decoder_passes\":0}\n";
            std::printf("%s", out.str().c_str());
            return 0;
        }
        const auto opt = options(argc, argv);
        Probe probe{opt, ggml_time_us() + 120LL * 1000 * 1000, {}, {}, nullptr};
        require(!probe.stopped(), "Cancelled before model initialization");
        // The pinned official CLI initializes dynamically loaded GGML backends
        // before loading a model. The library entry point does not do so.
        const auto available_devices = initialize_backends(!opt.cpu);
        const auto audio = rp::pcm16_mono_16k(read_bounded(opt.wav, 2 * 1024 * 1024));
        const auto reference_bytes = read_bounded(opt.reference, 16 * 1024);
        require(rp::valid_utf8(reference_bytes), "Expected nonempty bounded UTF-8 development reference");
        const std::string reference(reference_bytes.begin(), reference_bytes.end());
        auto parameters = whisper_context_default_params();
        parameters.use_gpu = !opt.cpu; parameters.flash_attn = false; parameters.gpu_device = 0;
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(
            whisper_init_from_file_with_params(opt.model.c_str(), parameters), whisper_free);
        require(bool(ctx) && bool(ctx->state), "Cannot initialize diagnostic model/state");
        std::vector<rp::BackendEvidence> selected_backends;
        for (const auto backend : ctx->state->backends)
            selected_backends.push_back(device_evidence(ggml_backend_get_device(backend), backend));
        rp::validate_selected_backends(selected_backends, !opt.cpu);
        probe.decoder_scheduler = ctx->state->sched_decode.sched;
        require(probe.decoder_scheduler != nullptr, "Decoder scheduler is unavailable");
        const auto & h = ctx->model.hparams;
        require((h.n_text_state == 384 && h.n_text_head == 6 && h.n_text_layer == 4) ||
            (h.n_text_state == 512 && h.n_text_head == 8 && h.n_text_layer == 6) ||
            (h.n_text_state == 768 && h.n_text_head == 12 && h.n_text_layer == 12),
            "Expected original Tiny/Base/Small decoder geometry");
        require(h.n_vocab == 51865 && h.n_text_ctx == 448 && h.n_mels == 80 &&
            h.n_audio_state == h.n_text_state && h.n_audio_layer == h.n_text_layer &&
            h.n_audio_head == h.n_text_head && h.n_audio_ctx == 1500,
            "Expected multilingual smaller-model architecture");
        for (int layer = 0; layer < h.n_text_layer; ++layer) {
            const auto & l = ctx->model.layers_decoder[layer];
            const auto base = "decoder.blocks." + std::to_string(layer);
            probe.targets.emplace_back(base + ".attn_ln", l.attn_ln_0_w, l.attn_ln_0_b, h.n_text_state);
            probe.targets.emplace_back(base + ".cross_attn_ln", l.cross_attn_ln_0_w, l.cross_attn_ln_0_b, h.n_text_state);
            probe.targets.emplace_back(base + ".mlp_ln", l.mlp_ln_w, l.mlp_ln_b, h.n_text_state);
        }
        std::vector<whisper_token> reference_tokens(16 * 1024);
        const int total_tokens = whisper_tokenize(ctx.get(), reference.c_str(), reference_tokens.data(), int(reference_tokens.size()));
        require(total_tokens > 0 && total_tokens <= int(reference_tokens.size()), "Cannot tokenize bounded development reference");
        const int used_tokens = std::min(60, total_tokens);
        const int language_id = whisper_lang_id(opt.language.c_str());
        require(language_id >= 0, "Unknown explicit language");
        std::vector<whisper_token> tokens = {whisper_token_sot(ctx.get()), whisper_token_lang(ctx.get(), language_id),
            whisper_token_transcribe(ctx.get()), whisper_token_not(ctx.get())};
        tokens.insert(tokens.end(), reference_tokens.begin(), reference_tokens.begin() + used_tokens);
        const auto prefix_hash = sha256(rp::serialize_token_prefix(tokens));
        const auto reference_hash = sha256(reference_bytes);
        require(tokens.size() <= 64 && !probe.stopped(), "Invalid prefix or cancellation");
        require(whisper_pcm_to_mel(ctx.get(), audio.data(), int(audio.size()), opt.threads) == 0,
            "Cannot prepare log-mel input");
        require(!probe.stopped() && whisper_encode_internal(*ctx, *ctx->state, 0, opt.threads, abort_compute, &probe),
            "Encoder failed or cancelled");
        auto decode = [&]() {
            whisper_batch_prep_legacy(ctx->state->batch, tokens.data(), int(tokens.size()), 0, 0);
            // The legacy helper requests only the final position's logits.
            // Request every prefix position for a genuine full-prefix numeric
            // identity check, rather than comparing unobserved zero rows.
            for (std::size_t i = 0; i < tokens.size(); ++i) ctx->state->batch.logits[i] = 1;
            whisper_kv_cache_seq_rm(ctx->state->kv_self, 0, 0, -1);
            require(!probe.stopped() && whisper_decode_internal(*ctx, *ctx->state, ctx->state->batch,
                opt.threads, false, abort_compute, &probe), "Decoder failed or cancelled");
            const auto & logits = ctx->state->logits;
            require(logits.size() == tokens.size() * std::size_t(h.n_vocab), "Unexpected prefix logit count");
            for (const auto value : logits) require(std::isfinite(value), "Nonfinite prefix logits");
        };
        decode();
        const auto baseline = ctx->state->logits;
        ggml_backend_sched_set_eval_callback(ctx->state->sched_decode.sched, observe, &probe);
        decode();
        ggml_backend_sched_set_eval_callback(ctx->state->sched_decode.sched, nullptr, nullptr);
        require(probe.error.empty(), probe.error.c_str());
        for (const auto & target : probe.targets) require(target.stats.observations == 1 &&
            target.stats.count == tokens.size(), "Missing or incomplete LayerNorm target");
        const auto & measured = ctx->state->logits;
        const bool equal = std::memcmp(baseline.data(), measured.data(), baseline.size() * sizeof(float)) == 0;
        double max_abs_difference = 0;
        std::size_t argmax_mismatches = 0;
        for (std::size_t i = 0; i < baseline.size(); ++i)
            max_abs_difference = std::max(max_abs_difference, std::abs(double(baseline[i]) - measured[i]));
        for (std::size_t p = 0; p < tokens.size(); ++p) {
            const auto first = p * h.n_vocab, last = first + h.n_vocab;
            const auto a = std::max_element(baseline.begin() + first, baseline.begin() + last) - baseline.begin();
            const auto b = std::max_element(measured.begin() + first, measured.begin() + last) - measured.begin();
            argmax_mismatches += a != b;
        }
        std::ostringstream out;
        out << std::setprecision(17) << "{\"schema_version\":\"whisper-ln-activation-probe-v1\",\"status\":\""
            << (equal ? "complete" : "identity_failed") << "\",\"source_commit\":\"d1be6fde11ac6e0407606b4e42fe72d34add8037\","
            << "\"native_version\":\"1.9.5\",\"geometry\":{\"n_text_state\":" << h.n_text_state
            << ",\"n_text_layer\":" << h.n_text_layer << ",\"n_vocab\":" << h.n_vocab << "},"
            << "\"conditioning\":{\"method\":\"published-development-reference-prefix\",\"reference_tokens_total\":" << total_tokens
            << ",\"reference_tokens_used\":" << used_tokens << ",\"prefix_positions\":" << tokens.size()
            << ",\"prefix_sha256\":\"" << prefix_hash << "\",\"prefix_hash_encoding\":\"u32-le-token-ids-v1\""
            << ",\"reference_input_sha256\":\"" << reference_hash << "\""
            << ",\"source_audio_samples\":" << audio.size() << ",\"explicit_language\":\"" << opt.language
            << "\",\"threads\":" << opt.threads << ",\"use_gpu\":" << (opt.cpu ? "false" : "true")
            << ",\"flash_attention\":false,\"gpu_device\":0,\"encoder_passes\":1,\"decoder_passes\":2},"
            << "\"identity\":{\"bitwise_equal\":" << (equal ? "true" : "false")
            << ",\"max_abs_logit_difference\":" << max_abs_difference << ",\"argmax_mismatch_positions\":" << argmax_mismatches
            << ",\"compared_logits\":" << baseline.size() << "},\"backend_evidence\":{\"initializer\":\"ggml_backend_load_all\","
            << "\"selected_metal_gpu_verified\":" << (!opt.cpu ? "true" : "false") << ",\"available_devices\":[";
        for (std::size_t i = 0; i < available_devices.size(); ++i) { if (i) out << ','; append_backend(out, available_devices[i]); }
        out << "],\"selected_backends\":[";
        for (std::size_t i = 0; i < selected_backends.size(); ++i) { if (i) out << ','; append_backend(out, selected_backends[i]); }
        out << "]},\"targets\":[";
        for (std::size_t i = 0; i < probe.targets.size(); ++i) {
            const auto & target = probe.targets[i]; const auto & s = target.stats;
            if (i) out << ',';
            std::vector<double> means(s.channels), rms(s.channels);
            for (std::size_t c = 0; c < s.channels; ++c) { means[c] = s.sum_abs[c] / s.count; rms[c] = std::sqrt(s.sum_squares[c] / s.count); }
            out << "{\"site\":\"" << target.site << "\",\"channels\":" << s.channels
                << ",\"count\":" << s.count << ",\"observations\":" << s.observations << ",\"sum_abs\":";
            append_values(out, s.sum_abs); out << ",\"sum_squares\":"; append_values(out, s.sum_squares);
            out << ",\"max_abs\":"; append_values(out, s.max_abs); out << ",\"mean_abs\":"; append_values(out, means);
            out << ",\"rms\":"; append_values(out, rms); out << ",\"backend\":"; append_backend(out, target.backend); out << '}';
        }
        out << "]}\n";
        require(!probe.stopped(), "Cancelled before evidence publication");
        exclusive_output(opt.output, out.str());
        if (!equal) { std::fprintf(stderr, "Prefix logit identity failed; diagnostic evidence retained, not accepted\n"); return 3; }
        std::printf("Completed bounded activation observation with exact prefix logit identity\n");
        return 0;
    } catch (const std::exception & e) {
        std::fprintf(stderr, "Activation probe failed: %s\n", e.what());
        return 2;
    }
}
