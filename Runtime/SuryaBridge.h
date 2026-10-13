#ifndef SURYA_BRIDGE_H
#define SURYA_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct surya_engine surya_engine;

// A chunk is borrowed for the duration of the callback. Token boundaries can
// split a UTF-8 character: accumulate bytes before decoding them in Swift.
// Called synchronously on the thread that calls surya_engine_recognize.
typedef void (*surya_token_callback)(const char *bytes, size_t byte_count, void *user_data);

// NULL indicates failure. *error is NULL on success, or an owned error string.
// use_gpu=true requires an available Metal backend (no silent CPU fallback).
surya_engine *surya_engine_create(
    const char *model_path,
    const char *projector_path,
    int32_t context_size,
    bool use_gpu,
    char **error);

// Synchronously OCR one PNG/JPEG image to Surya's raw full-page HTML.
// NULL indicates failure, cancellation, or truncated output. Partial streamed
// bytes must not be treated as a completed result. Each call clears KV/recurrent
// state. Only one recognition may run on a given engine at a time.
char *surya_engine_recognize(
    surya_engine *engine,
    const char *image_path,
    int32_t max_tokens,
    surya_token_callback callback,
    void *user_data,
    char **error);

// Cancel can be called from another thread, including the streaming callback.
// GPU work already submitted finishes before cancellation can be observed.
void surya_engine_cancel(surya_engine *engine);

// Call before scheduling a NEW operation. Do not reset while a prior operation
// is running; recognition deliberately does not reset this flag itself.
void surya_engine_reset_cancel(surya_engine *engine);

// Caller must first wait for all recognize/cancel/reset calls to finish.
void surya_engine_destroy(surya_engine *engine);

// Releases any returned result/error string. NULL is accepted.
void surya_string_free(char *string);

#ifdef __cplusplus
}
#endif

#endif
