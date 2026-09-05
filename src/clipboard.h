#ifndef CLIPBOARD_H
#define CLIPBOARD_H

#include <stdbool.h>

// Pastes text into the focused application without replacing the user's clipboard.
bool clipboard_paste_text(const char *text);

#endif // CLIPBOARD_H