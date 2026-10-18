//! Value types of the Ghostty GX configuration keys (`gx-*` in
//! `src/config/Config.zig`).

/// Valid values for `gx-window-material`.
pub const WindowMaterial = enum {
    solid,
    mica,
    acrylic,
    tabbed,
};

/// Valid values for `gx-open-config-ui`.
pub const OpenConfigUi = enum {
    settings,
    editor,
};

/// Valid values for `gx-prompt-cursor`.
pub const PromptCursor = enum {
    config,
    bar,
};
