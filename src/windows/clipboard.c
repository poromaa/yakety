#include "../clipboard.h"
#include "../logging.h"
#include "../utils.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

#define PASTE_READ_DELAY_MS 100

typedef enum {
    CLIPBOARD_STORAGE_GLOBAL,
    CLIPBOARD_STORAGE_BITMAP,
    CLIPBOARD_STORAGE_PALETTE,
    CLIPBOARD_STORAGE_ENH_METAFILE,
    CLIPBOARD_STORAGE_METAFILE_PICT
} ClipboardStorage;

typedef struct {
    UINT format;
    HANDLE handle;
    ClipboardStorage storage;
} ClipboardEntry;

typedef struct {
    ClipboardEntry *entries;
    size_t count;
} ClipboardSnapshot;

extern HWND g_hwnd;

static bool open_clipboard_with_retry(HWND hwnd) {
    int elapsed_ms = 0;
    const int max_wait_ms = 1000;
    const int retry_delay_ms = 5;

    while (elapsed_ms < max_wait_ms) {
        if (OpenClipboard(hwnd)) {
            return true;
        }

        utils_sleep_ms(retry_delay_ms);
        elapsed_ms += retry_delay_ms;
    }

    log_error("Failed to open clipboard after %d ms", elapsed_ms);
    return false;
}

static HGLOBAL copy_global_handle(HANDLE source) {
    SIZE_T size = GlobalSize(source);
    if (size == 0) {
        return NULL;
    }

    const void *source_data = GlobalLock(source);
    if (!source_data) {
        return NULL;
    }

    HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!copy) {
        GlobalUnlock(source);
        return NULL;
    }

    void *copy_data = GlobalLock(copy);
    if (!copy_data) {
        GlobalFree(copy);
        GlobalUnlock(source);
        return NULL;
    }

    memcpy(copy_data, source_data, size);
    GlobalUnlock(copy);
    GlobalUnlock(source);
    return copy;
}

static HPALETTE copy_palette(HPALETTE source) {
    UINT entry_count = GetPaletteEntries(source, 0, 0, NULL);
    if (entry_count == 0) {
        return NULL;
    }

    SIZE_T size = sizeof(LOGPALETTE) + (entry_count - 1) * sizeof(PALETTEENTRY);
    LOGPALETTE *palette = (LOGPALETTE *) malloc(size);
    if (!palette) {
        return NULL;
    }

    palette->palVersion = 0x300;
    palette->palNumEntries = (WORD) entry_count;
    if (GetPaletteEntries(source, 0, entry_count, palette->palPalEntry) != entry_count) {
        free(palette);
        return NULL;
    }

    HPALETTE copy = CreatePalette(palette);
    free(palette);
    return copy;
}

static HGLOBAL copy_metafile_pict(HGLOBAL source) {
    METAFILEPICT *source_pict = (METAFILEPICT *) GlobalLock(source);
    if (!source_pict) {
        return NULL;
    }

    HMETAFILE metafile = CopyMetaFile(source_pict->hMF, NULL);
    if (!metafile) {
        GlobalUnlock(source);
        return NULL;
    }

    HGLOBAL copy = GlobalAlloc(GMEM_MOVEABLE, sizeof(METAFILEPICT));
    if (!copy) {
        DeleteMetaFile(metafile);
        GlobalUnlock(source);
        return NULL;
    }

    METAFILEPICT *copy_pict = (METAFILEPICT *) GlobalLock(copy);
    if (!copy_pict) {
        GlobalFree(copy);
        DeleteMetaFile(metafile);
        GlobalUnlock(source);
        return NULL;
    }

    *copy_pict = *source_pict;
    copy_pict->hMF = metafile;
    GlobalUnlock(copy);
    GlobalUnlock(source);
    return copy;
}

static void free_clipboard_entry(ClipboardEntry *entry) {
    if (!entry->handle) {
        return;
    }

    switch (entry->storage) {
    case CLIPBOARD_STORAGE_BITMAP:
    case CLIPBOARD_STORAGE_PALETTE:
        DeleteObject(entry->handle);
        break;
    case CLIPBOARD_STORAGE_ENH_METAFILE:
        DeleteEnhMetaFile((HENHMETAFILE) entry->handle);
        break;
    case CLIPBOARD_STORAGE_METAFILE_PICT: {
        METAFILEPICT *pict = (METAFILEPICT *) GlobalLock(entry->handle);
        if (pict) {
            DeleteMetaFile(pict->hMF);
            GlobalUnlock(entry->handle);
        }
        GlobalFree(entry->handle);
        break;
    }
    case CLIPBOARD_STORAGE_GLOBAL:
        GlobalFree(entry->handle);
        break;
    }

    entry->handle = NULL;
}

static void free_clipboard_snapshot(ClipboardSnapshot *snapshot) {
    for (size_t i = 0; i < snapshot->count; i++) {
        free_clipboard_entry(&snapshot->entries[i]);
    }
    free(snapshot->entries);
    snapshot->entries = NULL;
    snapshot->count = 0;
}

static bool copy_clipboard_entry(UINT format, HANDLE source, ClipboardEntry *entry) {
    entry->format = format;
    entry->handle = NULL;
    entry->storage = CLIPBOARD_STORAGE_GLOBAL;

    switch (format) {
    case CF_BITMAP:
    case CF_DSPBITMAP:
        entry->storage = CLIPBOARD_STORAGE_BITMAP;
        entry->handle = CopyImage(source, IMAGE_BITMAP, 0, 0, LR_CREATEDIBSECTION);
        break;
    case CF_PALETTE:
        entry->storage = CLIPBOARD_STORAGE_PALETTE;
        entry->handle = copy_palette((HPALETTE) source);
        break;
    case CF_ENHMETAFILE:
    case CF_DSPENHMETAFILE:
        entry->storage = CLIPBOARD_STORAGE_ENH_METAFILE;
        entry->handle = CopyEnhMetaFile((HENHMETAFILE) source, NULL);
        break;
    case CF_METAFILEPICT:
    case CF_DSPMETAFILEPICT:
        entry->storage = CLIPBOARD_STORAGE_METAFILE_PICT;
        entry->handle = copy_metafile_pict((HGLOBAL) source);
        break;
    default:
        entry->handle = copy_global_handle(source);
        break;
    }

    return entry->handle != NULL;
}

static bool capture_clipboard(ClipboardSnapshot *snapshot) {
    memset(snapshot, 0, sizeof(*snapshot));
    if (!open_clipboard_with_retry(g_hwnd)) {
        return false;
    }

    bool success = true;
    UINT format = 0;
    while (true) {
        SetLastError(ERROR_SUCCESS);
        format = EnumClipboardFormats(format);
        if (format == 0) {
            if (GetLastError() != ERROR_SUCCESS) {
                log_error("Failed to enumerate clipboard formats");
                success = false;
            }
            break;
        }

        HANDLE source = GetClipboardData(format);
        if (!source) {
            success = false;
            break;
        }

        ClipboardEntry *entries =
            (ClipboardEntry *) realloc(snapshot->entries, (snapshot->count + 1) * sizeof(ClipboardEntry));
        if (!entries) {
            success = false;
            break;
        }
        snapshot->entries = entries;

        if (!copy_clipboard_entry(format, source, &snapshot->entries[snapshot->count])) {
            log_error("Failed to preserve clipboard format %u", format);
            success = false;
            break;
        }
        snapshot->count++;
    }

    CloseClipboard();
    if (!success) {
        free_clipboard_snapshot(snapshot);
    }
    return success;
}

static bool set_clipboard_text(const char *text, DWORD *sequence_number) {
    *sequence_number = 0;
    int length = MultiByteToWideChar(CP_UTF8, 0, text, -1, NULL, 0);
    if (length == 0) {
        log_error("Failed to get wide string length");
        return false;
    }

    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (SIZE_T) length * sizeof(WCHAR));
    if (!memory) {
        log_error("Failed to allocate memory for clipboard");
        return false;
    }

    WCHAR *wide_text = (WCHAR *) GlobalLock(memory);
    if (!wide_text) {
        log_error("Failed to lock memory for clipboard");
        GlobalFree(memory);
        return false;
    }
    MultiByteToWideChar(CP_UTF8, 0, text, -1, wide_text, length);
    GlobalUnlock(memory);

    if (!open_clipboard_with_retry(g_hwnd)) {
        GlobalFree(memory);
        return false;
    }

    if (!EmptyClipboard()) {
        log_error("Failed to empty clipboard");
        CloseClipboard();
        GlobalFree(memory);
        return false;
    }

    bool success = SetClipboardData(CF_UNICODETEXT, memory) != NULL;
    if (!success) {
        log_error("Failed to set clipboard text");
        GlobalFree(memory);
    }

    CloseClipboard();
    *sequence_number = GetClipboardSequenceNumber();
    return success;
}

static bool restore_clipboard(ClipboardSnapshot *snapshot, DWORD temporary_sequence_number) {
    if (GetClipboardSequenceNumber() != temporary_sequence_number) {
        log_info("Clipboard changed during paste; keeping the newer contents");
        return true;
    }

    if (!open_clipboard_with_retry(g_hwnd)) {
        return false;
    }

    if (GetClipboardSequenceNumber() != temporary_sequence_number) {
        CloseClipboard();
        log_info("Clipboard changed during paste; keeping the newer contents");
        return true;
    }

    EmptyClipboard();
    bool success = true;
    for (size_t i = 0; i < snapshot->count; i++) {
        ClipboardEntry *entry = &snapshot->entries[i];
        if (SetClipboardData(entry->format, entry->handle)) {
            entry->handle = NULL;
        } else {
            log_error("Failed to restore clipboard format %u", entry->format);
            success = false;
        }
    }

    CloseClipboard();
    return success;
}

static bool send_paste_shortcut(void) {
    HWND foreground_window = GetForegroundWindow();
    char class_name[256] = {0};
    int class_name_length = GetClassNameA(foreground_window, class_name, sizeof(class_name));
    bool is_putty = class_name_length > 0 && strcmp(class_name, "PuTTY") == 0;

    INPUT inputs[4] = {0};
    if (is_putty) {
        log_info("Detected PuTTY, using Shift+Insert for paste");
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].ki.wVk = VK_SHIFT;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].ki.wVk = VK_INSERT;
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].ki.wVk = VK_INSERT;
        inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].ki.wVk = VK_SHIFT;
        inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
    } else {
        log_info("Using standard Ctrl+V");
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].ki.wVk = VK_CONTROL;
        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].ki.wVk = 'V';
        inputs[2].type = INPUT_KEYBOARD;
        inputs[2].ki.wVk = 'V';
        inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
        inputs[3].type = INPUT_KEYBOARD;
        inputs[3].ki.wVk = VK_CONTROL;
        inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
    }

    if (SendInput(4, inputs, sizeof(INPUT)) != 4) {
        log_error("Failed to send paste command");
        return false;
    }

    log_info("Paste command sent");
    return true;
}

bool clipboard_paste_text(const char *text) {
    if (!text || text[0] == '\0') {
        log_error("Invalid text for clipboard paste");
        return false;
    }

    ClipboardSnapshot snapshot;
    if (!capture_clipboard(&snapshot)) {
        log_error("Paste cancelled because the current clipboard could not be preserved");
        return false;
    }

    DWORD temporary_sequence_number = 0;
    if (!set_clipboard_text(text, &temporary_sequence_number)) {
        if (temporary_sequence_number != 0) {
            restore_clipboard(&snapshot, temporary_sequence_number);
        }
        free_clipboard_snapshot(&snapshot);
        return false;
    }

    bool pasted = send_paste_shortcut();
    if (pasted) {
        utils_sleep_ms(PASTE_READ_DELAY_MS);
    }

    bool restored = restore_clipboard(&snapshot, temporary_sequence_number);
    free_clipboard_snapshot(&snapshot);
    return pasted && restored;
}
