#pragma once

#include <cstdint>

void oeSetInputState(uint8_t kDown, uint8_t kHeld, int16_t mouseX, int16_t mouseY, uint8_t mouseBtns);

// Queue one devkit-keyboard key (a PICO-8 key string, e.g. "a", "\r", "\b").
// scanInput() surfaces one queued key per call, matching the one-key-per-
// _update_buttons() consumption model of stat(30)/stat(31).
void oePushKeyboardKey(const char* key);
