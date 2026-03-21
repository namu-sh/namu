#include "ghostty.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Stub implementations for Ghostty C API.
// Returns sensible defaults so the app can launch without the real library.

// --- Initialization ---
int ghostty_init(unsigned int argc, char** argv) {
    (void)argc; (void)argv;
    return GHOSTTY_SUCCESS;
}

// --- App lifecycle ---
// Return a non-NULL dummy pointer so Swift guards pass.
static int _dummy_app = 1;
static int _dummy_config = 1;
static int _dummy_surface = 1;

ghostty_app_t ghostty_app_new(ghostty_runtime_config_s* runtime_config, ghostty_config_t config) {
    (void)runtime_config; (void)config;
    return (ghostty_app_t)&_dummy_app;
}
void ghostty_app_free(ghostty_app_t app) { (void)app; }
void ghostty_app_tick(ghostty_app_t app) { (void)app; }
void ghostty_app_set_focus(ghostty_app_t app, bool focused) { (void)app; (void)focused; }
void ghostty_app_update_config(ghostty_app_t app, ghostty_config_t config) { (void)app; (void)config; }
void ghostty_app_set_color_scheme(ghostty_app_t app, ghostty_color_scheme_e scheme) { (void)app; (void)scheme; }

// --- Config ---
ghostty_config_t ghostty_config_new(void) { return (ghostty_config_t)&_dummy_config; }
void ghostty_config_free(ghostty_config_t config) { (void)config; }
void ghostty_config_load_default_files(ghostty_config_t config) { (void)config; }
void ghostty_config_load_recursive_files(ghostty_config_t config) { (void)config; }
void ghostty_config_load_file(ghostty_config_t config, const char* path) { (void)config; (void)path; }
void ghostty_config_finalize(ghostty_config_t config) { (void)config; }
bool ghostty_config_get(ghostty_config_t config, void* value, const char* key, unsigned int key_len) {
    (void)config; (void)value; (void)key; (void)key_len;
    return false;
}
ghostty_input_trigger_s ghostty_config_trigger(ghostty_config_t config, const char* action, unsigned int action_len) {
    (void)config; (void)action; (void)action_len;
    ghostty_input_trigger_s t;
    memset(&t, 0, sizeof(t));
    return t;
}
uint32_t ghostty_config_diagnostics_count(ghostty_config_t config) { (void)config; return 0; }
ghostty_diagnostic_s ghostty_config_get_diagnostic(ghostty_config_t config, uint32_t index) {
    (void)config; (void)index;
    ghostty_diagnostic_s d;
    memset(&d, 0, sizeof(d));
    return d;
}
ghostty_str_s ghostty_config_open_path(void) {
    ghostty_str_s s;
    memset(&s, 0, sizeof(s));
    return s;
}

// --- String ---
void ghostty_string_free(ghostty_str_s str) { (void)str; }

// --- Surface lifecycle ---
ghostty_surface_config_s ghostty_surface_config_new(void) {
    ghostty_surface_config_s cfg;
    memset(&cfg, 0, sizeof(cfg));
    return cfg;
}
ghostty_surface_t ghostty_surface_new(ghostty_app_t app, ghostty_surface_config_s* config) {
    (void)app; (void)config;
    return (ghostty_surface_t)&_dummy_surface;
}
void ghostty_surface_free(ghostty_surface_t surface) { (void)surface; }
void* ghostty_surface_userdata(ghostty_surface_t surface) { (void)surface; return NULL; }
ghostty_surface_config_s ghostty_surface_inherited_config(ghostty_surface_t surface, ghostty_surface_context_e context) {
    (void)surface; (void)context;
    ghostty_surface_config_s cfg;
    memset(&cfg, 0, sizeof(cfg));
    return cfg;
}
void ghostty_surface_update_config(ghostty_surface_t surface, ghostty_config_t config) { (void)surface; (void)config; }

// --- Surface display ---
void ghostty_surface_set_display_id(ghostty_surface_t surface, uint32_t display_id) { (void)surface; (void)display_id; }
void ghostty_surface_set_size(ghostty_surface_t surface, uint32_t width, uint32_t height) { (void)surface; (void)width; (void)height; }
void ghostty_surface_set_focus(ghostty_surface_t surface, bool focused) { (void)surface; (void)focused; }
void ghostty_surface_set_content_scale(ghostty_surface_t surface, double x, double y) { (void)surface; (void)x; (void)y; }
void ghostty_surface_set_occlusion(ghostty_surface_t surface, bool occluded) { (void)surface; (void)occluded; }
void ghostty_surface_draw(ghostty_surface_t surface) { (void)surface; }
void ghostty_surface_refresh(ghostty_surface_t surface) { (void)surface; }
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t surface) {
    (void)surface;
    ghostty_surface_size_s s;
    memset(&s, 0, sizeof(s));
    s.columns = 80; s.rows = 24;
    return s;
}

// --- Surface keyboard ---
bool ghostty_surface_key(ghostty_surface_t surface, ghostty_input_key_s key) { (void)surface; (void)key; return false; }
bool ghostty_surface_key_is_binding(ghostty_surface_t surface, ghostty_input_key_s key, ghostty_binding_flags_e* flags) {
    (void)surface; (void)key; (void)flags;
    return false;
}
ghostty_input_mods_e ghostty_surface_key_translation_mods(ghostty_surface_t surface, ghostty_input_mods_e mods) {
    (void)surface;
    return mods;
}
void ghostty_surface_preedit(ghostty_surface_t surface, const char* text, unsigned int len) { (void)surface; (void)text; (void)len; }
void ghostty_surface_ime_point(ghostty_surface_t surface, double* x, double* y, double* w, double* h) {
    (void)surface;
    if (x) *x = 0; if (y) *y = 0; if (w) *w = 10; if (h) *h = 16;
}
void ghostty_surface_text(ghostty_surface_t surface, const char* text, unsigned int len) { (void)surface; (void)text; (void)len; }

// --- Surface mouse ---
bool ghostty_surface_mouse_button(ghostty_surface_t surface, ghostty_input_mouse_state_e state, ghostty_input_mouse_button_e button, ghostty_input_mods_e mods) {
    (void)surface; (void)state; (void)button; (void)mods;
    return false;
}
void ghostty_surface_mouse_pos(ghostty_surface_t surface, double x, double y, ghostty_input_mods_e mods) {
    (void)surface; (void)x; (void)y; (void)mods;
}
void ghostty_surface_mouse_scroll(ghostty_surface_t surface, double dx, double dy, ghostty_input_scroll_mods_t mods) {
    (void)surface; (void)dx; (void)dy; (void)mods;
}
bool ghostty_surface_mouse_captured(ghostty_surface_t surface) { (void)surface; return false; }

// --- Surface selection ---
bool ghostty_surface_has_selection(ghostty_surface_t surface) { (void)surface; return false; }
bool ghostty_surface_read_selection(ghostty_surface_t surface, ghostty_text_s* text) { (void)surface; (void)text; return false; }
bool ghostty_surface_read_text(ghostty_surface_t surface, ghostty_selection_s selection, ghostty_text_s* text) {
    (void)surface; (void)selection; (void)text;
    return false;
}
void ghostty_surface_free_text(ghostty_surface_t surface, ghostty_text_s* text) { (void)surface; (void)text; }
bool ghostty_surface_clear_selection(ghostty_surface_t surface) { (void)surface; return false; }

// --- Surface clipboard ---
void ghostty_surface_complete_clipboard_request(ghostty_surface_t surface, const char* data, void* state, bool confirmed) {
    (void)surface; (void)data; (void)state; (void)confirmed;
}

// --- Surface splits ---
void ghostty_surface_split(ghostty_surface_t surface, ghostty_action_split_direction_e direction) { (void)surface; (void)direction; }
void ghostty_surface_split_focus(ghostty_surface_t surface, ghostty_action_goto_split_e direction) { (void)surface; (void)direction; }
void ghostty_surface_split_resize(ghostty_surface_t surface, ghostty_action_resize_split_direction_e direction, uint16_t amount) {
    (void)surface; (void)direction; (void)amount;
}
void ghostty_surface_split_equalize(ghostty_surface_t surface) { (void)surface; }

// --- Surface binding action ---
bool ghostty_surface_binding_action(ghostty_surface_t surface, const char* action, uintptr_t len) {
    (void)surface; (void)action; (void)len; return false;
}

// --- Surface process ---
bool ghostty_surface_process_exited(ghostty_surface_t surface) { (void)surface; return false; }
