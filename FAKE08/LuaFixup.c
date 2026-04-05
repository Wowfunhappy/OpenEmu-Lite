// Arena save state fixup for ASLR.
// At save time: walk Lua structures, record (offset, value) for every C function pointer.
// At load time: for each recorded offset, write old_value + delta.
// Zero false positives because we only touch known C-function-pointer fields.

#define LUA_CORE
#define lstate_c

#include "lua.h"
#include "lobject.h"
#include "lstate.h"
#include "lfunc.h"
#include "ltable.h"

#include <stdio.h>
#include <string.h>

extern "C" void *lua_arena_base(void);
extern "C" size_t lua_arena_size(void);

typedef struct {
    uint32_t offset;
    // value is implicit — read from arena at save time, write new value at load time
} PtrOffset;

#define MAX_OFFSETS 65536

typedef struct {
    PtrOffset entries[MAX_OFFSETS];
    size_t count;
} OffsetSet;

static int in_arena(const void *p) {
    void *base = lua_arena_base();
    return base && p >= base && p < (char*)base + lua_arena_size();
}

static void record(OffsetSet *s, const void *ptr_location) {
    if (!in_arena(ptr_location)) return;
    if (s->count >= MAX_OFFSETS) return;
    uint32_t off = (uint32_t)((const char *)ptr_location - (const char *)lua_arena_base());
    // Deduplicate
    for (size_t i = 0; i < s->count; i++)
        if (s->entries[i].offset == off) return;
    s->entries[s->count++].offset = off;
}

// Record the offset of a TValue's function pointer if it's a light C function
static void record_tvalue(OffsetSet *s, const TValue *v) {
    if (ttype(v) == LUA_TLCF)
        record(s, &v->value_.f);
}

static void record_table(OffsetSet *s, Table *t) {
    // dummynode pointer (in data segment, not arena — but Table.node field IS in arena)
    if (t->node && !in_arena(t->node))
        record(s, &t->node);
    unsigned int i;
    if (t->array && in_arena(t->array))
        for (i = 0; i < t->sizearray; i++)
            record_tvalue(s, &t->array[i]);
    if (t->node && in_arena(t->node)) {
        unsigned int size = (unsigned int)sizenode(t);
        for (i = 0; i < size; i++) {
            record_tvalue(s, gval(&t->node[i]));
            record_tvalue(s, gkey(&t->node[i]));
        }
    }
}

static void record_closure(OffsetSet *s, Closure *cl) {
    if (cl->c.tt == LUA_TCCL) {
        record(s, &cl->c.f);
        int i;
        for (i = 0; i < cl->c.nupvalues; i++)
            record_tvalue(s, &cl->c.upvalue[i]);
    } else if (cl->l.tt == LUA_TLCL) {
        int i;
        for (i = 0; i < cl->l.nupvalues; i++) {
            UpVal *uv = cl->l.upvals[i];
            if (uv && uv->v == &uv->u.value)
                record_tvalue(s, &uv->u.value);
        }
    }
}

static void record_thread(OffsetSet *s, lua_State *th) {
    StkId p;
    StkId end = th->stack + th->stacksize;
    for (p = th->stack; p < end; p++)
        record_tvalue(s, p);
    CallInfo *ci;
    for (ci = &th->base_ci; ci != NULL; ci = ci->next) {
        if (!(ci->callstatus & CIST_LUA) && ci->u.c.k)
            record(s, &ci->u.c.k);
    }
}

static void record_gclist(OffsetSet *s, GCObject *list) {
    GCObject *o;
    for (o = list; o != NULL; o = gch(o)->next) {
        switch (gch(o)->tt) {
            case LUA_TTABLE: record_table(s, gco2t(o)); break;
            case LUA_TCCL:
            case LUA_TLCL: record_closure(s, gco2cl(o)); break;
            case LUA_TTHREAD: record_thread(s, gco2th(o)); break;
            case LUA_TPROTO: {
                Proto *p = gco2p(o);
                int i;
                for (i = 0; i < p->sizek; i++)
                    record_tvalue(s, &p->k[i]);
                break;
            }
            case LUA_TUPVAL: {
                UpVal *uv = (UpVal *)o;
                if (uv->v == &uv->u.value)
                    record_tvalue(s, &uv->u.value);
                break;
            }
            default: break;
        }
    }
}

extern "C" size_t lua_collect_ptr_offsets(lua_State *L, uint32_t *out, size_t max_out) {
    OffsetSet s;
    s.count = 0;

    global_State *g = G(L);

    // Allocator and panic
    record(&s, &g->frealloc);
    if (g->panic) record(&s, &g->panic);

    // All GC lists (linked via gch->next)
    record_gclist(&s, g->allgc);
    record_gclist(&s, g->finobj);
    record_gclist(&s, g->tobefnz);

    // Main thread
    record_thread(&s, g->mainthread);

    // Registry
    if (ttistable(&g->l_registry)) {
        record_table(&s, hvalue(&g->l_registry));
    }

    // Open upvalues
    UpVal *uv;
    for (uv = g->uvhead.u.l.next; uv != &g->uvhead; uv = uv->u.l.next)
        record_tvalue(&s, uv->v);

    // Copy out
    size_t n = s.count < max_out ? s.count : max_out;
    for (size_t i = 0; i < n; i++)
        out[i] = s.entries[i].offset;
    return n;
}

extern "C" void lua_apply_offset_fixup(const uint32_t *offsets, size_t count, ptrdiff_t delta) {
    void *base = lua_arena_base();
    if (!base || delta == 0) return;
    for (size_t i = 0; i < count; i++) {
        uintptr_t *p = (uintptr_t *)((char *)base + offsets[i]);
        *p += delta;
    }
}
