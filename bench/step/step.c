// Exact instruction profiles of jeffjs-cli without a debugger (lldb, sample and Instruments need Developer Tools
// access; this needs nothing). Injected with DYLD_INSERT_LIBRARIES: it puts a hardware breakpoint on one address
// in its own threads and single-steps through its own Mach exception port, counting executions per pc.
//
//   STEP_ADDR=<hex>    file vmaddr of the breakpoint (a function entry: `nm -n jeffjs-cli`)
//   STEP_OUT=<file>    "BASE <exe base>\nSTEPS n <why> ...\n<pc> <count>..." written when the run ends
//   STEP_BETWEEN=1     count everything between two hits of STEP_ADDR (bench/step/mp.sh: a JS file calls
//                      Number.isSafeInteger(1) before and after the code under test)
//   STEP_HIT=<k>       without STEP_BETWEEN: single-step the k-th invocation of the function until it returns
//   STEP_MIN=<n> STEP_END=<hex>  ... or the first invocation that runs n instructions of its own (function ends at STEP_END)
//   STEP_MAX=<n>       stop after n steps (default 3,000,000)
//   STEP_SEQ=<file>    also write the last 1M executed pcs in order (bench/step/seq.py prints one loop iteration)
//
// About 15 us per instruction. The process exits when the profile is written.
#include <mach/mach.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#pragma pack(push, 4)
typedef struct {
    mach_msg_header_t Head;
    mach_msg_body_t msgh_body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t NDR;
    exception_type_t exception;
    mach_msg_type_number_t codeCnt;
    int64_t code[2];
} exc_req_t;
typedef struct {
    mach_msg_header_t Head;
    NDR_record_t NDR;
    kern_return_t RetCode;
} exc_reply_t;
#pragma pack(pop)

typedef struct { uint64_t pc; uint32_t n, ep; } ent_t;
#define CAP (1u << 21)
static ent_t *tab;
static mach_port_t exc_port;
static uint64_t g_bp, g_base, g_ret, g_sp, g_steps, g_max = 3000000;
static long g_hit_target = 1, g_hits, g_stray;
static uint64_t g_last, g_min, g_fn_end, g_in_fn;
static uint32_t g_epoch = 1;
static int g_between;
#define RING (1u << 20)
static uint64_t *ring; static uint64_t g_ringn; static const char *g_seq_out; static uint64_t g_seq_at;
static int g_mode;   // 0 wait for breakpoint, 1 stepping over a skipped hit, 2 tracing, 3 done
static const char *g_out;

static const void *exe_base(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h->filetype == MH_EXECUTE) return h;
    }
    return 0;
}
static void set_debug(thread_t th, int bp_on, int ss_on) {
    arm_debug_state64_t ds; memset(&ds, 0, sizeof ds);
    if (bp_on) { ds.__bvr[0] = g_bp; ds.__bcr[0] = 0x1e5; }
    if (ss_on) ds.__mdscr_el1 = 1;
    kern_return_t kr = thread_set_state(th, ARM_DEBUG_STATE64, (thread_state_t)&ds, ARM_DEBUG_STATE64_COUNT);
    if (kr) { fprintf(stderr, "[step] thread_set_state failed %d\n", kr); }
}
static inline void bump(uint64_t pc) {
    if (ring) ring[g_ringn++ & (RING - 1)] = pc;
    uint64_t h = (pc * 0x9E3779B97F4A7C15ull) >> 43; h &= CAP - 1;
    for (;;) { ent_t *e = &tab[h]; if (e->pc == pc) { if (e->ep != g_epoch) { e->ep = g_epoch; e->n = 0; } e->n++; return; } if (!e->pc) { e->pc = pc; e->n = 1; e->ep = g_epoch; return; } h = (h + 1) & (CAP - 1); }
}
static void dump_and_exit(const char *why) {
    FILE *f = fopen(g_out ? g_out : "/dev/stderr", "w");
    fprintf(f, "BASE %llx\nSTEPS %llu %s hits %ld stray %ld infn %llu\n", (unsigned long long)g_base, (unsigned long long)g_steps, why, g_hits, g_stray, (unsigned long long)g_in_fn);
    for (size_t i = 0; i < CAP; i++) if (tab[i].pc && tab[i].ep == g_epoch) fprintf(f, "%llx %u\n", (unsigned long long)tab[i].pc, tab[i].n);
    fclose(f);
    if (ring && g_seq_out) {
        // the window [g_seq_at, g_seq_at + RING) of the executed pcs, in order (or the last RING if it ran past)
        FILE *q = fopen(g_seq_out, "w"); uint64_t n = g_ringn < RING ? g_ringn : RING, st = g_ringn - n;
        fprintf(q, "BASE %llx\n", (unsigned long long)g_base);
        for (uint64_t i = 0; i < n; i++) fprintf(q, "%llx\n", (unsigned long long)ring[(st + i) & (RING - 1)]);
        fclose(q);
    }
    _exit(0);
}
static kern_return_t handle(thread_t th) {
    arm_thread_state64_t ts; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(th, ARM_THREAD_STATE64, (thread_state_t)&ts, &cnt)) return KERN_FAILURE;
    uint64_t pc = __darwin_arm_thread_state64_get_pc(ts), sp = __darwin_arm_thread_state64_get_sp(ts), lr = __darwin_arm_thread_state64_get_lr(ts);
    int is_brk = (*(uint32_t *)pc & 0xffe0001f) == 0xd4200000;
    switch (g_mode) {
    case 0:
        if (pc != g_bp) {
            // A stray step exception (single-step still armed in the CPU from the state before the
            // last change) is harmless: re-assert the breakpoint. A real trap is someone else's.
            if (is_brk) return KERN_FAILURE;
            g_stray++; set_debug(th, 1, 0); return KERN_SUCCESS;
        }
        if (g_between) {
            if (++g_hits < g_hit_target) { g_mode = 1; set_debug(th, 0, 1); return KERN_SUCCESS; }
            g_mode = 2; g_steps = 0; g_last = pc; g_ret = 0; set_debug(th, 0, 1); return KERN_SUCCESS;   // marker: count from its first instruction's successor
        }
        if (++g_hits == g_hit_target || g_min) { g_mode = 2; g_ret = lr; g_sp = sp; bump(pc); g_steps = 1; g_in_fn = 1; g_last = pc; set_debug(th, 0, 1); }
        else { g_mode = 1; set_debug(th, 0, 1); }
        return KERN_SUCCESS;
    case 1:
        if (pc == g_bp) { g_stray++; set_debug(th, 0, 1); return KERN_SUCCESS; }   // no progress yet: step again
        g_mode = 0; set_debug(th, 1, 0); return KERN_SUCCESS;
    case 2:
        if (pc == g_last) { g_stray++; set_debug(th, 0, 1); return KERN_SUCCESS; } // no progress: not a new instruction
        if (g_between) {
            if (pc == g_bp) dump_and_exit("marker");
            if (g_steps >= g_max) dump_and_exit("max");
            if (is_brk) dump_and_exit("brk");
            bump(pc); g_steps++; g_last = pc;
            set_debug(th, 1, 1);
            return KERN_SUCCESS;
        }
        if ((pc == g_ret && sp == g_sp)) {
            if (g_min && (g_fn_end ? g_in_fn : g_steps) < g_min) { g_epoch++; g_mode = 0; set_debug(th, 1, 0); return KERN_SUCCESS; }   // too short: wait for the next invocation
            dump_and_exit("returned");
        }
        if (g_steps >= g_max) dump_and_exit("max");
        if (is_brk) dump_and_exit("brk");
        bump(pc); g_steps++; g_last = pc; if (pc >= g_bp && pc < g_fn_end) g_in_fn++;
        set_debug(th, 0, 1);
        return KERN_SUCCESS;
    default:
        return KERN_FAILURE;
    }
}
static void *server(void *arg) {
    (void)arg;
    for (;;) {
        union { exc_req_t r; char pad[2048]; } m;
        if (mach_msg(&m.r.Head, MACH_RCV_MSG, 0, sizeof m, exc_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL)) continue;
        thread_t th = m.r.thread.name;
        kern_return_t rc = handle(th);
        mach_port_deallocate(mach_task_self(), th);
        mach_port_deallocate(mach_task_self(), m.r.task.name);
        exc_reply_t rep; memset(&rep, 0, sizeof rep);
        rep.Head.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(m.r.Head.msgh_bits), 0);
        rep.Head.msgh_size = sizeof rep;
        rep.Head.msgh_remote_port = m.r.Head.msgh_remote_port;
        rep.Head.msgh_local_port = MACH_PORT_NULL;
        rep.Head.msgh_id = m.r.Head.msgh_id + 100;
        rep.NDR = NDR_record;
        rep.RetCode = rc;
        mach_msg(&rep.Head, MACH_SEND_MSG, sizeof rep, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return 0;
}
struct start { void *(*fn)(void *); void *arg; };
static void *thunk(void *p) {
    struct start s = *(struct start *)p; free(p);
    if (g_bp && g_mode == 0) { thread_t me = mach_thread_self(); set_debug(me, 1, 0); mach_port_deallocate(mach_task_self(), me); }
    return s.fn(s.arg);
}
int my_pthread_create(pthread_t *t, const pthread_attr_t *a, void *(*fn)(void *), void *arg) {
    struct start *s = malloc(sizeof *s); s->fn = fn; s->arg = arg;
    return pthread_create(t, a, thunk, s);
}
#define INTERPOSE(r,o) __attribute__((used)) static struct{const void*r_;const void*o_;} _ip_##o __attribute__((section("__DATA,__interpose"))) = {(const void*)r,(const void*)o}
INTERPOSE(my_pthread_create, pthread_create);

__attribute__((constructor)) static void init(void) {
    const char *a = getenv("STEP_ADDR"); if (!a) return;
    g_base = (uint64_t)exe_base();
    g_bp = strtoull(a, 0, 16) - 0x100000000ull + g_base;
    if (getenv("STEP_HIT")) g_hit_target = atol(getenv("STEP_HIT"));
    if (getenv("STEP_END")) g_fn_end = strtoull(getenv("STEP_END"), 0, 16) - 0x100000000ull + g_base;
    if (getenv("STEP_BETWEEN")) g_between = 1;
    if (getenv("STEP_SEQ")) { g_seq_out = getenv("STEP_SEQ"); ring = calloc(RING, 8); }
    if (getenv("STEP_MIN")) g_min = strtoull(getenv("STEP_MIN"), 0, 10);
    if (getenv("STEP_MAX")) g_max = strtoull(getenv("STEP_MAX"), 0, 10);
    g_out = getenv("STEP_OUT");
    tab = calloc(CAP, sizeof(ent_t));
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_port);
    mach_port_insert_right(mach_task_self(), exc_port, exc_port, MACH_MSG_TYPE_MAKE_SEND);
    kern_return_t kr = task_set_exception_ports(mach_task_self(), EXC_MASK_BREAKPOINT, exc_port, EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64);
    if (kr) { fprintf(stderr, "[step] task_set_exception_ports failed %d\n", kr); return; }
    pthread_t t; pthread_create(&t, 0, server, 0);
    thread_t me = mach_thread_self(); set_debug(me, 1, 0); mach_port_deallocate(mach_task_self(), me);
}
__attribute__((destructor)) static void fini(void) {
    if (g_bp && g_mode != 3) fprintf(stderr, "[step] process ended: mode %d, hits %ld, steps %llu, stray %ld\n", g_mode, g_hits, (unsigned long long)g_steps, g_stray);
}
