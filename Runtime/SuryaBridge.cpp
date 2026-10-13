#include "SuryaBridge.h"

#include <llama/ggml-backend.h>
#include <llama/ggml-metal.h>
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace {

template <typename T, void (*Free)(T *)>
using Owned = std::unique_ptr<T, decltype(Free)>;

// Verbatim training-time prompt, Surya commit a2363d3311773a2b6145a40458043211c50c52f4.
constexpr const char *ocr_prompt =
    "OCR this image to HTML. Each block is a div with data-label and data-bbox "
    "(x0 y0 x1 y1, normalized 0-1000).";

char *copy_string(const char *value, size_t count) noexcept {
    char *copy = static_cast<char *>(std::malloc(count + 1));
    if (copy != nullptr) {
        std::memcpy(copy, value, count);
        copy[count] = '\0';
    }
    return copy;
}

void set_error(char **error, const char *message) noexcept {
    if (error != nullptr) {
        *error = copy_string(message, std::strlen(message));
    }
}

void initialize_backend() {
    // Register the Metal backend linked into the XCFramework explicitly. The
    // registry deduplicates this if it was registered by the framework itself.
    // No dynamic plug-in search or external executable is involved.
    static std::once_flag flag;
    std::call_once(flag, [] {
        llama_backend_init();
        ggml_backend_register(ggml_backend_metal_reg());
        for (size_t index = 0; index < ggml_backend_reg_count(); ++index) {
            auto registry = ggml_backend_reg_get(index);
            std::fprintf(stderr, "[SuryaBridge] Registered backend: %s (%zu devices)\n",
                ggml_backend_reg_name(registry), ggml_backend_reg_dev_count(registry));
        }
    });
}

ggml_backend_dev_t metal_device() {
    // b11429 identifies this backend as "MTL", not "Metal". Match the actual
    // backend object instead of depending on a display-name spelling.
    const auto metal = ggml_backend_metal_reg();
    for (size_t index = 0; index < ggml_backend_dev_count(); ++index) {
        auto device = ggml_backend_dev_get(index);
        if (ggml_backend_dev_backend_reg(device) == metal) {
            return device;
        }
    }
    return nullptr;
}

std::string token_piece(const llama_vocab *vocab, llama_token token) {
    char buffer[256];
    int32_t count = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, true);
    if (count >= 0) {
        return std::string(buffer, static_cast<size_t>(count));
    }
    std::vector<char> larger(static_cast<size_t>(-count));
    count = llama_token_to_piece(vocab, token, larger.data(), static_cast<int32_t>(larger.size()), 0, true);
    if (count < 0) {
        throw std::runtime_error("Could not decode a generated token.");
    }
    return std::string(larger.data(), static_cast<size_t>(count));
}

} // namespace

struct surya_engine {
    std::atomic<bool> cancelled{false};
    std::mutex recognition_mutex;
    Owned<llama_model, llama_model_free> model{nullptr, llama_model_free};
    Owned<llama_context, llama_free> context{nullptr, llama_free};
    Owned<mtmd_context, mtmd_free> vision{nullptr, mtmd_free};

    void check_cancelled() const {
        if (cancelled.load(std::memory_order_relaxed)) {
            throw std::runtime_error("OCR cancelled.");
        }
    }
};

extern "C" surya_engine *surya_engine_create(
    const char *model_path,
    const char *projector_path,
    int32_t context_size,
    bool use_gpu,
    char **error) {
    if (error != nullptr) {
        *error = nullptr;
    }
    try {
        if (model_path == nullptr || model_path[0] == '\0' ||
            projector_path == nullptr || projector_path[0] == '\0') {
            throw std::runtime_error("Select both the Surya GGUF model and its vision projector.");
        }
        if (context_size < 2048 || context_size > 65536) {
            throw std::runtime_error("Context size must be between 2048 and 65536 tokens.");
        }
        initialize_backend();
        auto engine = std::make_unique<surya_engine>();
        auto device = use_gpu ? metal_device() : nullptr;
        if (use_gpu && device == nullptr) {
            throw std::runtime_error("Metal is unavailable. Check the bundled llama framework and run on a supported Mac.");
        }
        std::fprintf(stderr, "[SuryaBridge] In-process backend: %s\n",
            device != nullptr ? ggml_backend_dev_name(device) : "CPU (explicitly selected)");

        auto model_params = llama_model_default_params();
        ggml_backend_dev_t devices[] = {device, nullptr};
        model_params.n_gpu_layers = use_gpu ? -1 : 0;
        if (device != nullptr) {
            model_params.devices = devices;
        }
        model_params.load_mtp = false;
        engine->model.reset(llama_model_load_from_file(model_path, model_params));
        if (!engine->model) {
            throw std::runtime_error("Could not load the Surya GGUF model. Check that the download is complete.");
        }

        const int threads = static_cast<int>(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
        auto context_params = llama_context_default_params();
        context_params.n_ctx = static_cast<uint32_t>(context_size);
        context_params.n_batch = 512;
        context_params.n_ubatch = 512;
        context_params.n_seq_max = 1;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        context_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        context_params.offload_kqv = use_gpu;
        context_params.op_offload = use_gpu;
        context_params.abort_callback = [](void *data) -> bool {
            return static_cast<surya_engine *>(data)->cancelled.load(std::memory_order_relaxed);
        };
        context_params.abort_callback_data = engine.get();
        engine->context.reset(llama_init_from_model(engine->model.get(), context_params));
        if (!engine->context) {
            throw std::runtime_error("Could not create the inference context. Try a smaller context or free memory.");
        }

        auto vision_params = mtmd_context_params_default();
        vision_params.use_gpu = use_gpu;
        vision_params.device = device;
        vision_params.n_threads = threads;
        vision_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        vision_params.warmup = false;
        engine->vision.reset(mtmd_init_from_file(projector_path, engine->model.get(), vision_params));
        if (!engine->vision || !mtmd_support_vision(engine->vision.get())) {
            throw std::runtime_error("Could not load the Surya vision projector. Use the matching Surya 2 mmproj GGUF.");
        }
        return engine.release();
    } catch (const std::exception &exception) {
        set_error(error, exception.what());
    } catch (...) {
        set_error(error, "Unexpected native error while loading the model.");
    }
    return nullptr;
}

extern "C" char *surya_engine_recognize(
    surya_engine *engine,
    const char *image_path,
    int32_t max_tokens,
    surya_token_callback callback,
    void *user_data,
    char **error) {
    if (error != nullptr) {
        *error = nullptr;
    }
    try {
        if (engine == nullptr || image_path == nullptr || image_path[0] == '\0') {
            throw std::runtime_error("A loaded model and an image path are required.");
        }
        if (max_tokens <= 0 || max_tokens > 32768) {
            throw std::runtime_error("Maximum output must be between 1 and 32768 tokens.");
        }
        std::unique_lock<std::mutex> operation(engine->recognition_mutex, std::try_to_lock);
        if (!operation.owns_lock()) {
            throw std::runtime_error("This Surya engine is already processing an image.");
        }
        engine->check_cancelled();
        llama_memory_clear(llama_get_memory(engine->context.get()), true);

        auto loaded = mtmd_helper_bitmap_init_from_file(
            engine->vision.get(), image_path, false, mtmd_helper_init_opt_default());
        Owned<mtmd_bitmap, mtmd_bitmap_free> bitmap(loaded.bitmap, mtmd_bitmap_free);
        Owned<mtmd_helper_video, mtmd_helper_video_free> video(loaded.video_ctx, mtmd_helper_video_free);
        if (!bitmap || video || mtmd_bitmap_is_audio(bitmap.get())) {
            throw std::runtime_error("Could not open the page image. Supply a PNG or JPEG image.");
        }
        engine->check_cancelled();

        // The pinned Surya chat_template.jinja has this exact single-user
        // framing and NO thinking suffix. mtmd inserts vision_start/image
        // embeddings/vision_end at its media marker. Do not double-wrap it.
        std::string prompt = "<|im_start|>user\n";
        prompt += mtmd_default_marker();
        prompt += ocr_prompt;
        prompt += "<|im_end|>\n<|im_start|>assistant\n";
        const mtmd_input_text text{prompt.data(), prompt.size(), false, true};
        const mtmd_bitmap *bitmaps[] = {bitmap.get()};
        Owned<mtmd_input_chunks, mtmd_input_chunks_free> chunks(mtmd_input_chunks_init(), mtmd_input_chunks_free);
        if (!chunks || mtmd_tokenize(engine->vision.get(), chunks.get(), &text, bitmaps, 1) != 0) {
            throw std::runtime_error("Could not prepare the Surya image and prompt.");
        }
        const size_t input_tokens = mtmd_helper_get_n_tokens(chunks.get());
        const size_t context_tokens = llama_n_ctx(engine->context.get());
        if (input_tokens + static_cast<size_t>(max_tokens) > context_tokens) {
            throw std::runtime_error("The page and requested output exceed the context. Reduce image size/output limit or increase context size.");
        }
        std::fprintf(stderr, "[SuryaBridge] Page input: %zu tokens; output limit: %d; context: %zu\n",
            input_tokens, max_tokens, context_tokens);

        // Evaluate chunks individually so cancellation is checked between the
        // text prefill, image encoding, and trailing assistant prefix.
        llama_pos past = 0;
        const size_t chunk_count = mtmd_input_chunks_size(chunks.get());
        for (size_t index = 0; index < chunk_count; ++index) {
            engine->check_cancelled();
            const int32_t status = mtmd_helper_eval_chunk_single(
                engine->vision.get(), engine->context.get(), mtmd_input_chunks_get(chunks.get(), index),
                past, 0, static_cast<int32_t>(llama_n_batch(engine->context.get())),
                index + 1 == chunk_count, &past);
            engine->check_cancelled();
            if (status != 0) {
                throw std::runtime_error("Image encoding or prompt evaluation failed (native status " + std::to_string(status) + ").");
            }
        }

        Owned<llama_sampler, llama_sampler_free> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        Owned<llama_batch_ext, llama_batch_ext_free> batch(llama_batch_ext_init(engine->context.get()), llama_batch_ext_free);
        if (!sampler || !batch) {
            throw std::runtime_error("Could not allocate the token decoder.");
        }
        const llama_vocab *vocab = llama_model_get_vocab(engine->model.get());
        std::string output;
        for (int32_t generated = 0; generated < max_tokens; ++generated) {
            engine->check_cancelled();
            const llama_token token = llama_sampler_sample(sampler.get(), engine->context.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) {
                char *result = copy_string(output.data(), output.size());
                if (result == nullptr) {
                    throw std::bad_alloc();
                }
                return result;
            }
            std::string piece = token_piece(vocab, token);
            output += piece;
            if (callback != nullptr && !piece.empty()) {
                callback(piece.data(), piece.size(), user_data);
            }
            engine->check_cancelled();

            // Extended batches give text tokens the correct one-position
            // semantics even when the image used Qwen's multi-axis M-RoPE.
            llama_batch_ext_clear(batch.get());
            const int32_t entry = llama_batch_ext_add_token(batch.get(), 0, token);
            if (entry < 0 || !llama_batch_ext_set_pos(batch.get(), entry, &past) ||
                !llama_batch_ext_set_output_logits(batch.get(), entry, true)) {
                throw std::runtime_error("Could not prepare the next generated token.");
            }
            ++past;
            const int32_t status = llama_process(engine->context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get());
            engine->check_cancelled();
            if (status != 0) {
                throw std::runtime_error("Token decoding failed (native status " + std::to_string(status) + ").");
            }
        }
        throw std::runtime_error("OCR reached the output token limit before the end marker. The output is incomplete; increase the output limit.");
    } catch (const std::exception &exception) {
        set_error(error, exception.what());
    } catch (...) {
        set_error(error, "Unexpected native error during OCR.");
    }
    return nullptr;
}

extern "C" void surya_engine_cancel(surya_engine *engine) {
    if (engine != nullptr) {
        engine->cancelled.store(true, std::memory_order_relaxed);
    }
}

extern "C" void surya_engine_reset_cancel(surya_engine *engine) {
    if (engine != nullptr) {
        engine->cancelled.store(false, std::memory_order_relaxed);
    }
}

extern "C" void surya_engine_destroy(surya_engine *engine) {
    try {
        delete engine;
    } catch (...) {
        // No native exception may cross the Swift/C ABI boundary.
    }
}

extern "C" void surya_string_free(char *string) {
    std::free(string);
}
