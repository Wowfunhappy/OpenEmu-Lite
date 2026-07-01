#pragma once
#include <stddef.h>
#include <stdint.h>

struct lua_State;

#ifdef __cplusplus
extern "C" {
#endif

// Walk the restored Lua object graph and shift every C pointer captured in the
// arena (light C functions, C-closure functions, dummynode links, allocator/
// panic hooks) by `delta`. Only genuine pointer fields whose value falls inside
// the old plugin image range [plugin_lo, plugin_hi) are touched, so number
// values are never corrupted. Safe to call on a freshly restored arena.
void lua_fixup_arena_pointers(lua_State *L, ptrdiff_t delta,
                              uintptr_t plugin_lo, uintptr_t plugin_hi);

#ifdef __cplusplus
}
#endif
