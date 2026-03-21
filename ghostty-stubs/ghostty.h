#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// ============================================================================
// Ghostty C API — Stub Header for Mosaic
// ============================================================================
// This is a stub header providing type and function declarations so the Swift
// code compiles against the Ghostty C API without the real xcframework.
// All functions are declared (not defined) — link-time stubs or a real library
// must provide the implementations.

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------------------------------------------------------
// Result code
// ----------------------------------------------------------------------------

#define GHOSTTY_SUCCESS 0

// ----------------------------------------------------------------------------
// Opaque handle types
// ----------------------------------------------------------------------------

typedef void* ghostty_app_t;
typedef void* ghostty_surface_t;
typedef void* ghostty_config_t;

// ----------------------------------------------------------------------------
// Enums
// ----------------------------------------------------------------------------

// Input action (key press/repeat/release)
typedef enum {
    GHOSTTY_ACTION_PRESS   = 0,
    GHOSTTY_ACTION_REPEAT  = 1,
    GHOSTTY_ACTION_RELEASE = 2,
} ghostty_input_action_e;

// Modifier keys (bitmask)
typedef enum {
    GHOSTTY_MODS_NONE  = 0,
    GHOSTTY_MODS_SHIFT = 1,
    GHOSTTY_MODS_CTRL  = 2,
    GHOSTTY_MODS_ALT   = 4,
    GHOSTTY_MODS_SUPER = 8,
    GHOSTTY_MODS_CAPS  = 16,
    GHOSTTY_MODS_NUM   = 32,
} ghostty_input_mods_e;

// Mouse button state
typedef enum {
    GHOSTTY_MOUSE_PRESS   = 0,
    GHOSTTY_MOUSE_RELEASE = 1,
} ghostty_input_mouse_state_e;

// Mouse buttons
typedef enum {
    GHOSTTY_MOUSE_LEFT   = 0,
    GHOSTTY_MOUSE_RIGHT  = 1,
    GHOSTTY_MOUSE_MIDDLE = 2,
    GHOSTTY_MOUSE_FOUR   = 3,
    GHOSTTY_MOUSE_FIVE   = 4,
    GHOSTTY_MOUSE_SIX    = 5,
    GHOSTTY_MOUSE_SEVEN  = 6,
    GHOSTTY_MOUSE_EIGHT  = 7,
    GHOSTTY_MOUSE_NINE   = 8,
    GHOSTTY_MOUSE_TEN    = 9,
    GHOSTTY_MOUSE_ELEVEN = 10,
} ghostty_input_mouse_button_e;

// Mouse scroll momentum phase
typedef enum {
    GHOSTTY_MOUSE_MOMENTUM_NONE       = 0,
    GHOSTTY_MOUSE_MOMENTUM_BEGAN      = 1,
    GHOSTTY_MOUSE_MOMENTUM_STATIONARY = 2,
    GHOSTTY_MOUSE_MOMENTUM_CHANGED    = 3,
    GHOSTTY_MOUSE_MOMENTUM_ENDED      = 4,
    GHOSTTY_MOUSE_MOMENTUM_CANCELLED  = 5,
    GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN  = 6,
} ghostty_input_mouse_momentum_e;

// Clipboard location
typedef enum {
    GHOSTTY_CLIPBOARD_STANDARD  = 0,
    GHOSTTY_CLIPBOARD_SELECTION = 1,
} ghostty_clipboard_e;

// Color scheme
typedef enum {
    GHOSTTY_COLOR_SCHEME_LIGHT = 0,
    GHOSTTY_COLOR_SCHEME_DARK  = 1,
} ghostty_color_scheme_e;

// Surface context
typedef enum {
    GHOSTTY_SURFACE_CONTEXT_WINDOW = 0,
    GHOSTTY_SURFACE_CONTEXT_TAB    = 1,
    GHOSTTY_SURFACE_CONTEXT_SPLIT  = 2,
} ghostty_surface_context_e;

// Split direction
typedef enum {
    GHOSTTY_SPLIT_RIGHT = 0,
    GHOSTTY_SPLIT_DOWN  = 1,
    GHOSTTY_SPLIT_LEFT  = 2,
    GHOSTTY_SPLIT_UP    = 3,
} ghostty_action_split_direction_e;

// Goto split direction
typedef enum {
    GHOSTTY_GOTO_SPLIT_PREVIOUS = 0,
    GHOSTTY_GOTO_SPLIT_NEXT     = 1,
    GHOSTTY_GOTO_SPLIT_TOP      = 2,
    GHOSTTY_GOTO_SPLIT_BOTTOM   = 3,
    GHOSTTY_GOTO_SPLIT_LEFT     = 4,
    GHOSTTY_GOTO_SPLIT_RIGHT    = 5,
} ghostty_action_goto_split_e;

// Resize split direction
typedef enum {
    GHOSTTY_RESIZE_SPLIT_UP    = 0,
    GHOSTTY_RESIZE_SPLIT_DOWN  = 1,
    GHOSTTY_RESIZE_SPLIT_LEFT  = 2,
    GHOSTTY_RESIZE_SPLIT_RIGHT = 3,
} ghostty_action_resize_split_direction_e;

// Binding flags (bitmask)
typedef enum {
    GHOSTTY_BINDING_FLAGS_CONSUMED   = 1,
    GHOSTTY_BINDING_FLAGS_ALL        = 2,
    GHOSTTY_BINDING_FLAGS_GLOBAL     = 4,
    GHOSTTY_BINDING_FLAGS_PERFORMABLE = 8,
} ghostty_binding_flags_e;

// Action tags for ghostty_action_s
typedef enum {
    GHOSTTY_ACTION_RING_BELL              = 0,
    GHOSTTY_ACTION_RELOAD_CONFIG          = 1,
    GHOSTTY_ACTION_CONFIG_CHANGE          = 2,
    GHOSTTY_ACTION_COLOR_CHANGE           = 3,
    GHOSTTY_ACTION_SET_TITLE              = 4,
    GHOSTTY_ACTION_PWD                    = 5,
    GHOSTTY_ACTION_DESKTOP_NOTIFICATION   = 6,
    GHOSTTY_ACTION_OPEN_URL               = 7,
    GHOSTTY_ACTION_OPEN_CONFIG            = 8,
    GHOSTTY_ACTION_QUIT                   = 9,
    GHOSTTY_ACTION_NEW_SPLIT              = 10,
    GHOSTTY_ACTION_GOTO_SPLIT             = 11,
    GHOSTTY_ACTION_RESIZE_SPLIT           = 12,
    GHOSTTY_ACTION_EQUALIZE_SPLITS        = 13,
    GHOSTTY_ACTION_CLOSE_SURFACE          = 14,
    GHOSTTY_ACTION_NEW_TAB                = 15,
    GHOSTTY_ACTION_NEW_WINDOW             = 16,
} ghostty_action_tag_e;

// Target tags
typedef enum {
    GHOSTTY_TARGET_APP     = 0,
    GHOSTTY_TARGET_SURFACE = 1,
} ghostty_target_tag_e;

// Platform tags
typedef enum {
    GHOSTTY_PLATFORM_MACOS = 0,
} ghostty_platform_tag_e;

// Point tags
typedef enum {
    GHOSTTY_POINT_VIEWPORT = 0,
    GHOSTTY_POINT_SCREEN   = 1,
} ghostty_point_tag_e;

// Point coordinate tags
typedef enum {
    GHOSTTY_POINT_COORD_TOP_LEFT     = 0,
    GHOSTTY_POINT_COORD_BOTTOM_RIGHT = 1,
} ghostty_point_coord_e;

// ----------------------------------------------------------------------------
// Scalar typedefs
// ----------------------------------------------------------------------------

typedef int32_t ghostty_input_scroll_mods_t;

// ----------------------------------------------------------------------------
// Structs
// ----------------------------------------------------------------------------

// Key input event
typedef struct {
    ghostty_input_action_e action;
    ghostty_input_mods_e   mods;
    ghostty_input_mods_e   consumed_mods;
    uint32_t               keycode;
    const char*            text;
    uint32_t               unshifted_codepoint;
    bool                   composing;
} ghostty_input_key_s;

// Input trigger (opaque struct for binding lookup)
typedef struct {
    uint32_t _opaque[8];
} ghostty_input_trigger_s;

// Config color (RGB)
typedef struct {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} ghostty_config_color_s;

// Config palette (256 colors)
typedef struct {
    ghostty_config_color_s colors[256];
} ghostty_config_palette_s;

// Config diagnostic
typedef struct {
    const char* message;
    int         severity;
} ghostty_diagnostic_s;

// String (for ghostty_config_open_path / ghostty_string_free)
typedef struct {
    const char* ptr;
    size_t      len;
} ghostty_str_s;

// Platform-specific: macOS
typedef struct {
    void* nsview;
} ghostty_platform_macos_s;

// Platform union
typedef union {
    ghostty_platform_macos_s macos;
} ghostty_platform_u;

// Environment variable key-value pair
typedef struct {
    const char* key;
    const char* value;
} ghostty_env_var_s;

// Surface configuration
typedef struct {
    ghostty_platform_tag_e  platform_tag;
    ghostty_platform_u      platform;
    void*                   userdata;
    double                  scale_factor;
    double                  font_size;
    const char*             working_directory;
    const char*             command;
    ghostty_env_var_s*      env_vars;
    int                     env_var_count;
    ghostty_surface_context_e context;
} ghostty_surface_config_s;

// Surface size
typedef struct {
    uint32_t columns;
    uint32_t rows;
    uint32_t width;
    uint32_t height;
    uint32_t cell_width;
    uint32_t cell_height;
} ghostty_surface_size_s;

// Text (for selection reading)
typedef struct {
    const char* text;
    size_t      text_len;
} ghostty_text_s;

// Point
typedef struct {
    ghostty_point_tag_e   tag;
    ghostty_point_coord_e coord;
    uint32_t              x;
    uint32_t              y;
} ghostty_point_s;

// Selection
typedef struct {
    ghostty_point_s top_left;
    ghostty_point_s bottom_right;
    bool            rectangle;
} ghostty_selection_s;

// Target
typedef struct {
    ghostty_target_tag_e tag;
    ghostty_surface_t    surface;
} ghostty_target_s;

// Clipboard content (for write_clipboard_cb)
typedef struct {
    const char* mime;
    const char* data;
    size_t      len;
} ghostty_clipboard_content_s;

// Action sub-structs (fields accessed in handleAction)
typedef struct {
    const char* title;
} ghostty_action_set_title_s;

typedef struct {
    const char* pwd;
} ghostty_action_pwd_s;

typedef struct {
    const char* title;
    const char* body;
} ghostty_action_desktop_notification_s;

typedef struct {
    const char* url;
} ghostty_action_open_url_s;

typedef struct {
    bool soft;
} ghostty_action_reload_config_s;

// Action union (accessed as action.action.<field>)
typedef union {
    ghostty_action_set_title_s              set_title;
    ghostty_action_pwd_s                    pwd;
    ghostty_action_desktop_notification_s   desktop_notification;
    ghostty_action_open_url_s               open_url;
    ghostty_action_reload_config_s          reload_config;
} ghostty_action_u;

// Action (tag + union)
typedef struct {
    ghostty_action_tag_e tag;
    ghostty_action_u     action;
} ghostty_action_s;

// ----------------------------------------------------------------------------
// Runtime config (callback function pointers)
// ----------------------------------------------------------------------------

typedef void (*ghostty_wakeup_cb_t)(void* userdata);

typedef bool (*ghostty_action_cb_t)(
    ghostty_app_t app,
    ghostty_target_s target,
    ghostty_action_s action
);

typedef void (*ghostty_read_clipboard_cb_t)(
    void* userdata,
    ghostty_clipboard_e location,
    void* state
);

typedef void (*ghostty_confirm_read_clipboard_cb_t)(
    void* userdata,
    const char* content,
    void* state,
    void* extra
);

typedef void (*ghostty_write_clipboard_cb_t)(
    void* userdata,
    ghostty_clipboard_e location,
    const ghostty_clipboard_content_s* content,
    size_t len,
    void* extra
);

typedef void (*ghostty_close_surface_cb_t)(
    void* userdata,
    void* extra
);

typedef struct {
    void*                               userdata;
    bool                                supports_selection_clipboard;
    ghostty_wakeup_cb_t                 wakeup_cb;
    ghostty_action_cb_t                 action_cb;
    ghostty_read_clipboard_cb_t         read_clipboard_cb;
    ghostty_confirm_read_clipboard_cb_t confirm_read_clipboard_cb;
    ghostty_write_clipboard_cb_t        write_clipboard_cb;
    ghostty_close_surface_cb_t          close_surface_cb;
} ghostty_runtime_config_s;

// ----------------------------------------------------------------------------
// Functions — Initialization
// ----------------------------------------------------------------------------

int ghostty_init(unsigned int argc, char** argv);

// ----------------------------------------------------------------------------
// Functions — App lifecycle
// ----------------------------------------------------------------------------

ghostty_app_t ghostty_app_new(
    ghostty_runtime_config_s* runtime_config,
    ghostty_config_t config
);
void ghostty_app_free(ghostty_app_t app);
void ghostty_app_tick(ghostty_app_t app);
void ghostty_app_set_focus(ghostty_app_t app, bool focused);
void ghostty_app_update_config(ghostty_app_t app, ghostty_config_t config);
void ghostty_app_set_color_scheme(ghostty_app_t app, ghostty_color_scheme_e scheme);

// ----------------------------------------------------------------------------
// Functions — Config
// ----------------------------------------------------------------------------

ghostty_config_t ghostty_config_new(void);
void ghostty_config_free(ghostty_config_t config);
void ghostty_config_load_default_files(ghostty_config_t config);
void ghostty_config_load_recursive_files(ghostty_config_t config);
void ghostty_config_load_file(ghostty_config_t config, const char* path);
void ghostty_config_finalize(ghostty_config_t config);
bool ghostty_config_get(
    ghostty_config_t config,
    void* value,
    const char* key,
    unsigned int key_len
);
ghostty_input_trigger_s ghostty_config_trigger(
    ghostty_config_t config,
    const char* action,
    unsigned int action_len
);
uint32_t ghostty_config_diagnostics_count(ghostty_config_t config);
ghostty_diagnostic_s ghostty_config_get_diagnostic(
    ghostty_config_t config,
    uint32_t index
);
ghostty_str_s ghostty_config_open_path(void);

// ----------------------------------------------------------------------------
// Functions — String
// ----------------------------------------------------------------------------

void ghostty_string_free(ghostty_str_s str);

// ----------------------------------------------------------------------------
// Functions — Surface lifecycle
// ----------------------------------------------------------------------------

ghostty_surface_config_s ghostty_surface_config_new(void);
ghostty_surface_t ghostty_surface_new(
    ghostty_app_t app,
    ghostty_surface_config_s* config
);
void ghostty_surface_free(ghostty_surface_t surface);
void* ghostty_surface_userdata(ghostty_surface_t surface);
ghostty_surface_config_s ghostty_surface_inherited_config(
    ghostty_surface_t surface,
    ghostty_surface_context_e context
);
void ghostty_surface_update_config(
    ghostty_surface_t surface,
    ghostty_config_t config
);

// ----------------------------------------------------------------------------
// Functions — Surface display
// ----------------------------------------------------------------------------

void ghostty_surface_set_display_id(ghostty_surface_t surface, uint32_t display_id);
void ghostty_surface_set_size(ghostty_surface_t surface, uint32_t width, uint32_t height);
void ghostty_surface_set_focus(ghostty_surface_t surface, bool focused);
void ghostty_surface_set_content_scale(ghostty_surface_t surface, double x, double y);
void ghostty_surface_set_occlusion(ghostty_surface_t surface, bool occluded);
void ghostty_surface_draw(ghostty_surface_t surface);
void ghostty_surface_refresh(ghostty_surface_t surface);
ghostty_surface_size_s ghostty_surface_size(ghostty_surface_t surface);

// ----------------------------------------------------------------------------
// Functions — Surface keyboard input
// ----------------------------------------------------------------------------

bool ghostty_surface_key(ghostty_surface_t surface, ghostty_input_key_s key);
bool ghostty_surface_key_is_binding(
    ghostty_surface_t surface,
    ghostty_input_key_s key,
    ghostty_binding_flags_e* flags
);
ghostty_input_mods_e ghostty_surface_key_translation_mods(
    ghostty_surface_t surface,
    ghostty_input_mods_e mods
);
void ghostty_surface_preedit(
    ghostty_surface_t surface,
    const char* text,
    unsigned int len
);
void ghostty_surface_ime_point(
    ghostty_surface_t surface,
    double* x,
    double* y,
    double* w,
    double* h
);
void ghostty_surface_text(
    ghostty_surface_t surface,
    const char* text,
    unsigned int len
);

// ----------------------------------------------------------------------------
// Functions — Surface mouse input
// ----------------------------------------------------------------------------

bool ghostty_surface_mouse_button(
    ghostty_surface_t surface,
    ghostty_input_mouse_state_e state,
    ghostty_input_mouse_button_e button,
    ghostty_input_mods_e mods
);
void ghostty_surface_mouse_pos(
    ghostty_surface_t surface,
    double x,
    double y,
    ghostty_input_mods_e mods
);
void ghostty_surface_mouse_scroll(
    ghostty_surface_t surface,
    double dx,
    double dy,
    ghostty_input_scroll_mods_t mods
);
bool ghostty_surface_mouse_captured(ghostty_surface_t surface);

// ----------------------------------------------------------------------------
// Functions — Surface selection / text
// ----------------------------------------------------------------------------

bool ghostty_surface_has_selection(ghostty_surface_t surface);
bool ghostty_surface_read_selection(ghostty_surface_t surface, ghostty_text_s* text);
bool ghostty_surface_read_text(
    ghostty_surface_t surface,
    ghostty_selection_s selection,
    ghostty_text_s* text
);
void ghostty_surface_free_text(ghostty_surface_t surface, ghostty_text_s* text);
bool ghostty_surface_clear_selection(ghostty_surface_t surface);

// ----------------------------------------------------------------------------
// Functions — Surface clipboard
// ----------------------------------------------------------------------------

void ghostty_surface_complete_clipboard_request(
    ghostty_surface_t surface,
    const char* data,
    void* state,
    bool confirmed
);

// ----------------------------------------------------------------------------
// Functions — Surface splits
// ----------------------------------------------------------------------------

void ghostty_surface_split(
    ghostty_surface_t surface,
    ghostty_action_split_direction_e direction
);
void ghostty_surface_split_focus(
    ghostty_surface_t surface,
    ghostty_action_goto_split_e direction
);
void ghostty_surface_split_resize(
    ghostty_surface_t surface,
    ghostty_action_resize_split_direction_e direction,
    uint16_t amount
);
void ghostty_surface_split_equalize(ghostty_surface_t surface);

// ----------------------------------------------------------------------------
// Functions — Surface binding action
// ----------------------------------------------------------------------------

bool ghostty_surface_binding_action(
    ghostty_surface_t surface,
    const char* action,
    uintptr_t action_len
);

// ----------------------------------------------------------------------------
// Functions — Surface process state
// ----------------------------------------------------------------------------

bool ghostty_surface_process_exited(ghostty_surface_t surface);

#ifdef __cplusplus
}
#endif
