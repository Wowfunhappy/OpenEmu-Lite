// Arena save-state pointer fixup for ASLR.
//
// The save state is a raw byte-image of the fixed-address Lua arena. The arena
// always maps at the same virtual address, so every pointer that lives INSIDE
// the arena stays valid across a restore. The exception is pointers that point
// OUT of the arena and INTO the plugin image: C function pointers (light C
// functions and C closures), the empty-table "dummynode" links, and the
// allocator/panic hooks. The plugin is loaded at a fresh ASLR address every
// launch, so those pointers all need to be shifted by `delta` (the difference
// between the plugin's old and new load address).
//
// We must NOT do this with a blind memory scan. z8lua numbers are 32-bit fix32
// values stored in the LOW 4 bytes of an 8-byte value slot (setnvalue only
// writes `.n`), leaving the upper 4 bytes untouched. Because the arena
// allocator recycles freed blocks without zeroing them, a number written into
// a slot that previously held a plugin pointer keeps that pointer's upper bytes
// (0x00000001) — so the full 8-byte word looks like 0x00000001_xxxxxxxx, an
// address inside the plugin's window. A scan would "fix" it and silently
// corrupt the number, breaking game logic a few seconds after the state loads.
//
// Instead we walk the live Lua object graph and shift ONLY the fields that
// genuinely hold C pointers. The restored arena is a byte-identical copy at the
// same base address, so all of its internal links are valid to traverse even
// before the pointers are fixed (we never traverse THROUGH a pointer we shift).

#define LUA_CORE
#define lstate_c

#include "lua.h"
#include "lobject.h"
#include "lstate.h"
#include "lfunc.h"
#include "ltable.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

extern "C" void *lua_arena_base(void);
extern "C" size_t lua_arena_size(void);

typedef struct {
    char      *base;
    size_t     size;
    ptrdiff_t  delta;
    uintptr_t  plugin_lo;   // old plugin image range [lo, hi): genuine pointers only
    uintptr_t  plugin_hi;
    uint8_t   *seen;        // one bit per 8-byte arena slot, guards against double-shift
} FixupCtx;

static int in_arena(FixupCtx *c, const void *p) {
    return p >= (void *)c->base && p < (void *)(c->base + c->size);
}

// Shift the pointer stored at `loc` by delta, at most once.
//
// Two guards keep this safe: callers only pass fields that are TYPED as C
// pointers (so number values are never touched — that would corrupt them),
// and we additionally require the CURRENT value to fall inside the old plugin
// image range. The range check matters because dead stack slots can carry a
// stale LUA_TLCF tag over a non-pointer payload; shifting that would corrupt
// memory. C-pointer fields are 8-byte aligned, so slot = offset/8 is unique.
static void fixptr(FixupCtx *c, void *loc) {
    if (!in_arena(c, loc)) return;
    uintptr_t val = *(uintptr_t *)loc;
    if (val < c->plugin_lo || val >= c->plugin_hi) return;  // not an old plugin pointer
    size_t slot = (size_t)((char *)loc - c->base) >> 3;
    if (slot >= (c->size >> 3)) return;
    uint8_t mask = (uint8_t)(1u << (slot & 7));
    if (c->seen[slot >> 3] & mask) return;   // already shifted
    c->seen[slot >> 3] |= mask;
    *(uintptr_t *)loc = val + (uintptr_t)c->delta;
}

// Shift a value slot if it holds a C pointer: a light C function or a light
// userdata (a raw C pointer that may point into the plugin image).
static void fix_tvalue(FixupCtx *c, const TValue *v) {
    int t = ttype(v);
    if (t == LUA_TLCF)
        fixptr(c, (void *)&v->value_.f);
    else if (t == LUA_TLIGHTUSERDATA)
        fixptr(c, (void *)&v->value_.p);
}

static void fix_table(FixupCtx *c, Table *t) {
    // Empty tables share a static dummynode in the plugin image; that link
    // must be shifted too.
    if (t->node && !in_arena(c, t->node))
        fixptr(c, &t->node);
    unsigned int i;
    if (t->array && in_arena(c, t->array))
        for (i = 0; i < (unsigned int)t->sizearray; i++)
            fix_tvalue(c, &t->array[i]);
    if (t->node && in_arena(c, t->node)) {
        unsigned int size = (unsigned int)sizenode(t);
        for (i = 0; i < size; i++) {
            fix_tvalue(c, gval(&t->node[i]));
            fix_tvalue(c, gkey(&t->node[i]));
        }
    }
}

static void fix_closure(FixupCtx *c, Closure *cl) {
    if (cl->c.tt == LUA_TCCL) {
        fixptr(c, &cl->c.f);
        int i;
        for (i = 0; i < cl->c.nupvalues; i++)
            fix_tvalue(c, &cl->c.upvalue[i]);
    } else if (cl->l.tt == LUA_TLCL) {
        int i;
        for (i = 0; i < cl->l.nupvalues; i++) {
            UpVal *uv = cl->l.upvals[i];
            if (uv && uv->v == &uv->u.value)
                fix_tvalue(c, &uv->u.value);
        }
    }
}

static void fix_thread(FixupCtx *c, lua_State *th) {
    // The debug/budget hook is a C function pointer into the plugin, and it is
    // (re)installed per-frame by the host on the main thread. A hook captured in
    // a saved thread — especially a suspended coroutine — points into the OLD
    // plugin image; if it fires during resume the VM jumps to a dead address.
    // Clear the hook state on every thread; the host re-arms it as needed.
    th->hook = NULL;
    th->hookmask = 0;
    th->hookcount = 0;

    StkId p;
    StkId end = th->stack + th->stacksize;
    for (p = th->stack; p < end; p++)
        fix_tvalue(c, p);
    CallInfo *ci;
    for (ci = &th->base_ci; ci != NULL; ci = ci->next) {
        if (!(ci->callstatus & CIST_LUA) && ci->u.c.k)
            fixptr(c, &ci->u.c.k);
    }
}

static void fix_gclist(FixupCtx *c, GCObject *list) {
    GCObject *o;
    for (o = list; o != NULL; o = gch(o)->next) {
        switch (gch(o)->tt) {
            case LUA_TTABLE: fix_table(c, gco2t(o)); break;
            case LUA_TCCL:
            case LUA_TLCL:   fix_closure(c, gco2cl(o)); break;
            case LUA_TTHREAD: fix_thread(c, gco2th(o)); break;
            case LUA_TPROTO: {
                Proto *p = gco2p(o);
                int i;
                for (i = 0; i < p->sizek; i++)
                    fix_tvalue(c, &p->k[i]);
                break;
            }
            case LUA_TUPVAL: {
                UpVal *uv = (UpVal *)o;
                if (uv->v == &uv->u.value)
                    fix_tvalue(c, &uv->u.value);
                break;
            }
            default: break;
        }
    }
}

// Walk the whole Lua state and shift every C pointer captured in the arena by
// `delta`. `plugin_lo`/`plugin_hi` bound the OLD plugin image; only values in
// that range are shifted. Safe to call on a freshly restored (not-yet-fixed)
// arena.
extern "C" void lua_fixup_arena_pointers(lua_State *L, ptrdiff_t delta,
                                         uintptr_t plugin_lo, uintptr_t plugin_hi) {
    if (!L || delta == 0 || plugin_hi <= plugin_lo) return;
    void *base = lua_arena_base();
    size_t size = lua_arena_size();
    if (!base || size == 0) return;

    size_t nslots = size >> 3;
    uint8_t *seen = (uint8_t *)calloc((nslots >> 3) + 1, 1);
    if (!seen) return;

    FixupCtx ctx;
    ctx.base = (char *)base;
    ctx.size = size;
    ctx.delta = delta;
    ctx.plugin_lo = plugin_lo;
    ctx.plugin_hi = plugin_hi;
    ctx.seen = seen;

    global_State *g = G(L);

    // Allocator and panic hook.
    fixptr(&ctx, &g->frealloc);
    if (g->panic) fixptr(&ctx, &g->panic);

    // All collectable objects.
    fix_gclist(&ctx, g->allgc);
    fix_gclist(&ctx, g->finobj);
    fix_gclist(&ctx, g->tobefnz);

    // Main thread (not part of allgc), registry, and open upvalues. These may
    // revisit objects already covered above; the `seen` bitmap prevents any
    // pointer from being shifted twice.
    fix_thread(&ctx, g->mainthread);
    if (ttistable(&g->l_registry))
        fix_table(&ctx, hvalue(&g->l_registry));
    UpVal *uv;
    for (uv = g->uvhead.u.l.next; uv != &g->uvhead; uv = uv->u.l.next)
        fix_tvalue(&ctx, uv->v);

    free(seen);
}
