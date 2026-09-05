#include "../clipboard.h"
#include "../logging.h"
#include "../utils.h"
#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>

#define PASTE_READ_DELAY_MS 100

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

        [pasteboard clearContents];
        if (![pasteboard setString:string forType:NSPasteboardTypeString]) {
            log_error("Failed to copy text to pasteboard");
            [pasteboard clearContents];
            if ([saved_items count] > 0) {
                [pasteboard writeObjects:saved_items];
            }
            [saved_items release];
            return false;
        }

        NSInteger temporary_change_count = [pasteboard changeCount];
        bool pasted = post_paste_shortcut();
        if (pasted) {
            // The target application reads the pasteboard asynchronously after the shortcut.
            utils_sleep_ms(PASTE_READ_DELAY_MS);
        }

        if ([pasteboard changeCount] == temporary_change_count) {
            [pasteboard clearContents];
            if ([saved_items count] > 0 && ![pasteboard writeObjects:saved_items]) {
                log_error("Failed to restore previous pasteboard contents");
                pasted = false;
            }
        } else {
            log_info("Clipboard changed during paste; keeping the newer contents");
        }

        [saved_items release];
        return pasted;
    }
}
