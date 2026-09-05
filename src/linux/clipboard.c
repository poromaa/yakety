#include "../clipboard.h"
#include "../logging.h"
#include "../utils.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PASTE_READ_DELAY_MS 100

static int is_wayland = -1;

static int detect_wayland(void) {
    if (is_wayland < 0) {
        const char *wayland = getenv("WAYLAND_DISPLAY");
        is_wayland = wayland && wayland[0] != '\0';
        log_info("Display server: %s", is_wayland ? "Wayland" : "X11");
    }
    return is_wayland;
}

static bool command_exists(const char *command) {
    char check[256];
    snprintf(check, sizeof(check), "command -v %s >/dev/null 2>&1", command);
    return system(check) == 0;
}

static const char *clipboard_read_command(void) {
    if (detect_wayland()) {
        return command_exists("wl-paste") ? "wl-paste --no-newline 2>/dev/null" : NULL;
    }
    if (command_exists("xclip")) {
        return "xclip -selection clipboard -out 2>/dev/null";
    }
    if (command_exists("xsel")) {
        return "xsel --clipboard --output 2>/dev/null";
    }
    return NULL;
}

static const char *clipboard_write_command(void) {
    if (detect_wayland()) {
        return command_exists("wl-copy") ? "wl-copy 2>/dev/null" : NULL;
    }
    if (command_exists("xclip")) {
        return "xclip -selection clipboard -in 2>/dev/null";
    }
    if (command_exists("xsel")) {
        return "xsel --clipboard --input 2>/dev/null";
    }
    return NULL;
}

static bool read_clipboard_text(char **text) {
    *text = NULL;
    const char *command = clipboard_read_command();
    if (!command) {
        return false;
    }

    FILE *pipe = popen(command, "r");
    if (!pipe) {
        return false;
    }

    size_t length = 0;
    size_t capacity = 256;
    char *buffer = (char *) malloc(capacity);
    if (!buffer) {
        pclose(pipe);
        return false;
    }

    while (!feof(pipe)) {
        if (length + 128 + 1 > capacity) {
            capacity *= 2;
            char *larger_buffer = (char *) realloc(buffer, capacity);
            if (!larger_buffer) {
                free(buffer);
                pclose(pipe);
                return false;
            }
            buffer = larger_buffer;
        }

        length += fread(buffer + length, 1, capacity - length - 1, pipe);
        if (ferror(pipe)) {
            free(buffer);
            pclose(pipe);
            return false;
        }
    }

    int status = pclose(pipe);
    if (status != 0) {
        free(buffer);
        return false;
    }

    buffer[length] = '\0';
    *text = buffer;
    return true;
}

static bool write_clipboard_text(const char *text) {
    const char *command = clipboard_write_command();
    if (!command) {
        return false;
    }

    FILE *pipe = popen(command, "w");
    if (!pipe) {
        return false;
    }

    bool written = fputs(text, pipe) >= 0;
    return pclose(pipe) == 0 && written;
}

static char *shell_quote(const char *text) {
    size_t length = strlen(text);
    char *quoted = (char *) malloc(length * 4 + 3);
    if (!quoted) {
        return NULL;
    }

    char *destination = quoted;
    *destination++ = '\'';
    for (const char *source = text; *source; source++) {
        if (*source == '\'') {
            *destination++ = '\'';
            *destination++ = '\\';
            *destination++ = '\'';
            *destination++ = '\'';
        } else {
            *destination++ = *source;
        }
    }
    *destination++ = '\'';
    *destination = '\0';
    return quoted;
}

static int run_typing_command(const char *prefix, const char *quoted_text) {
    size_t command_length = strlen(prefix) + strlen(quoted_text) + strlen(" 2>/dev/null") + 1;
    char *command = (char *) malloc(command_length);
    if (!command) {
        return -1;
    }

    snprintf(command, command_length, "%s%s 2>/dev/null", prefix, quoted_text);
    int result = system(command);
    free(command);
    return result;
}

static int type_text_directly(const char *quoted_text) {
    int result = -1;
    if (detect_wayland()) {
        if (command_exists("wtype")) {
            result = run_typing_command("wtype ", quoted_text);
        }
        if (result != 0 && command_exists("ydotool")) {
            result = run_typing_command("ydotool type -- ", quoted_text);
        }
    } else if (command_exists("xdotool")) {
        result = run_typing_command("xdotool type --clearmodifiers -- ", quoted_text);
    }
    return result;
}

static int send_paste_shortcut(void) {
    if (detect_wayland() && command_exists("wtype")) {
        return system("wtype -M ctrl -k v -m ctrl 2>/dev/null");
    }
    if (!detect_wayland() && command_exists("xdotool")) {
        return system("xdotool key --clearmodifiers ctrl+v 2>/dev/null");
    }
    return -1;
}

static bool paste_via_clipboard(const char *text) {
    char *saved_text = NULL;
    if (!read_clipboard_text(&saved_text)) {
        log_error("Paste cancelled because the current clipboard could not be preserved");
        return false;
    }

    if (!write_clipboard_text(text)) {
        log_error("Failed to copy transcription to clipboard");
        free(saved_text);
        return false;
    }

    bool pasted = send_paste_shortcut() == 0;
    if (pasted) {
        utils_sleep_ms(PASTE_READ_DELAY_MS);
    }

    char *current_text = NULL;
    bool clipboard_read = read_clipboard_text(&current_text);
    bool clipboard_unchanged = clipboard_read && strcmp(current_text, text) == 0;
    bool restored = true;

    if (clipboard_unchanged) {
        restored = write_clipboard_text(saved_text);
        if (!restored) {
            log_error("Failed to restore previous clipboard contents");
        }
    } else {
        log_info("Clipboard changed during paste; keeping the newer contents");
    }

    free(current_text);
    free(saved_text);
    return pasted && restored;
}

bool clipboard_paste_text(const char *text) {
    if (!text || text[0] == '\0') {
        log_error("Invalid text for clipboard paste");
        return false;
    }

    char *quoted_text = shell_quote(text);
    if (!quoted_text) {
        log_error("Failed to allocate memory for text insertion");
        return false;
    }

    int result = type_text_directly(quoted_text);
    free(quoted_text);

    if (result == 0) {
        log_debug("Typed %zu characters without changing the clipboard", strlen(text));
        return true;
    }

    log_info("Typing tools not available, falling back to clipboard paste");
    return paste_via_clipboard(text);
}
