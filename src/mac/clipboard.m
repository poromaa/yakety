#include "../clipboard.h"
#include "../logging.h"
#include "../utils.h"
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#include <stdlib.h>

#define PASTEBOARD_RESTORE_DELAY_MS 250

typedef struct {
    NSArray *saved_items;
    NSInteger temporary_change_count;
} ClipboardRestoreContext;

static NSArray *snapshot_pasteboard(NSPasteboard *pasteboard) {
    NSMutableArray *saved_items = [NSMutableArray array];

    for (NSPasteboardItem *item in [pasteboard pasteboardItems]) {
        NSPasteboardItem *saved_item = [[NSPasteboardItem alloc] init];

        for (NSPasteboardType type in [item types]) {
            NSData *data = [item dataForType:type];
            if (!data || ![saved_item setData:data forType:type]) {
                log_error("Failed to preserve pasteboard type %s", [type UTF8String]);
                [saved_item release];
                return nil;
            }
        }

        [saved_items addObject:saved_item];
        [saved_item release];
    }

    return [saved_items copy];
}

static bool restore_pasteboard(NSPasteboard *pasteboard, NSArray *saved_items) {
    [pasteboard clearContents];
    if ([saved_items count] == 0) {
        return true;
    }
    return [pasteboard writeObjects:saved_items];
}

static void restore_pasteboard_after_paste(void *data) {
    ClipboardRestoreContext *context = (ClipboardRestoreContext *) data;

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        if ([pasteboard changeCount] == context->temporary_change_count) {
            if (restore_pasteboard(pasteboard, context->saved_items)) {
                log_info("Previous clipboard contents restored");
            } else {
                log_error("Failed to restore previous pasteboard contents");
            }
        } else {
            log_info("Clipboard changed during paste; keeping the newer contents");
        }

        [context->saved_items release];
        free(context);
    }
}

static bool post_paste_shortcut(void) {
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (!source) {
        log_error("Failed to create keyboard event source");
        return false;
    }

    CGEventRef cmd_down = CGEventCreateKeyboardEvent(source, kVK_Command, true);
    CGEventRef v_down = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, true);
    CGEventRef v_up = CGEventCreateKeyboardEvent(source, kVK_ANSI_V, false);
    CGEventRef cmd_up = CGEventCreateKeyboardEvent(source, kVK_Command, false);

    if (!cmd_down || !v_down || !v_up || !cmd_up) {
        log_error("Failed to create paste keyboard events");
        if (cmd_down)
            CFRelease(cmd_down);
        if (v_down)
            CFRelease(v_down);
        if (v_up)
            CFRelease(v_up);
        if (cmd_up)
            CFRelease(cmd_up);
        CFRelease(source);
        return false;
    }

    CGEventSetFlags(v_down, kCGEventFlagMaskCommand);
    CGEventSetFlags(v_up, kCGEventFlagMaskCommand);

    CGEventPost(kCGHIDEventTap, cmd_down);
    CGEventPost(kCGHIDEventTap, v_down);
    CGEventPost(kCGHIDEventTap, v_up);
    CGEventPost(kCGHIDEventTap, cmd_up);

    CFRelease(cmd_down);
    CFRelease(v_down);
    CFRelease(v_up);
    CFRelease(cmd_up);
    CFRelease(source);
    return true;
}

bool clipboard_paste_text(const char *text) {
    if (!text || text[0] == '\0') {
        log_error("Invalid text for clipboard paste");
        return false;
    }

    @autoreleasepool {
        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        NSArray *saved_items = snapshot_pasteboard(pasteboard);
        if (!saved_items) {
            log_error("Paste cancelled because the current pasteboard could not be preserved");
            return false;
        }

        NSString *string = [NSString stringWithUTF8String:text];
        if (!string) {
            log_error("Failed to convert text to UTF-8");
            [saved_items release];
            return false;
        }

        ClipboardRestoreContext *restore_context = malloc(sizeof(ClipboardRestoreContext));
        if (!restore_context) {
            log_error("Failed to allocate clipboard restore context");
            [saved_items release];
            return false;
        }
        restore_context->saved_items = saved_items;

        [pasteboard clearContents];
        if (![pasteboard setString:string forType:NSPasteboardTypeString]) {
            log_error("Failed to copy text to pasteboard");
            if (!restore_pasteboard(pasteboard, saved_items)) {
                log_error("Failed to restore previous pasteboard contents");
            }
            [saved_items release];
            free(restore_context);
            return false;
        }

        restore_context->temporary_change_count = [pasteboard changeCount];
        if (!post_paste_shortcut()) {
            if (!restore_pasteboard(pasteboard, saved_items)) {
                log_error("Failed to restore previous pasteboard contents");
            }
            [saved_items release];
            free(restore_context);
            return false;
        }

        // Returning from the hotkey callback lets macOS deliver Cmd+V before restoration.
        utils_execute_main_thread(PASTEBOARD_RESTORE_DELAY_MS, restore_pasteboard_after_paste, restore_context);
        return true;
    }
}
