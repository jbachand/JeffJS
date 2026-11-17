// In-process PC sampler (no task_for_pid needed): a thread suspends the main thread every SAMPLE_US
// microseconds, reads its pc and its caller (lr / frame chain), resumes it. Writes "BASE <exe>\nSAMPLES n\n<pc> <count>"
// to SAMPLE_OUT at exit. DYLD_INSERT_LIBRARIES=libsample.dylib SAMPLE_OUT=x.smp <cli> <js>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
typedef struct { uint64_t pc; uint64_t n; } ent_t;
#define CAP (1u << 20)
static ent_t *tab, *tab2; static thread_t g_main; static uint64_t g_n, g_base, g_end; static useconds_t g_us = 500; static volatile int g_stop;
static const struct mach_header_64 *exe_hdr(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) { const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i); if (h->filetype == MH_EXECUTE) return h; }
    return 0;
}
static inline void bump(ent_t *t, uint64_t pc) { uint64_t h = (pc * 0x9E3779B97F4A7C15ull) >> 44; h &= CAP - 1; for (;;) { ent_t *e = &t[h]; if (e->pc == pc) { e->n++; return; } if (!e->pc) { e->pc = pc; e->n = 1; return; } h = (h + 1) & (CAP - 1); } }
static void *sampler(void *a) {
    (void)a;
    while (!g_stop) {
        usleep(g_us);
        if (thread_suspend(g_main)) continue;
        arm_thread_state64_t ts; mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        if (!thread_get_state(g_main, ARM_THREAD_STATE64, (thread_state_t)&ts, &cnt)) {
            uint64_t pc = __darwin_arm_thread_state64_get_pc(ts);
            bump(tab, pc); g_n++;
            // first frame inside the executable (the engine function a library call was made from)
            uint64_t in = pc;
            if (!(pc >= g_base && pc < g_end)) {
                in = __darwin_arm_thread_state64_get_lr(ts);
                uint64_t fp = __darwin_arm_thread_state64_get_fp(ts);
                for (int d = 0; d < 48 && !(in >= g_base && in < g_end); d++) {
                    if (fp < 0x1000 || (fp & 7)) { in = 0; break; }
                    vm_size_t got = 0; uint64_t pair[2];
                    if (vm_read_overwrite(mach_task_self(), fp, 16, (vm_address_t)pair, &got) || got != 16) { in = 0; break; }
                    in = pair[1] & 0x0000ffffffffffffull; fp = pair[0];
                }
            }
            bump(tab2, in ? in : 1);
        }
        thread_resume(g_main);
    }
    return 0;
}
__attribute__((constructor)) static void init(void) {
    if (!getenv("SAMPLE_OUT")) return;
    if (getenv("SAMPLE_US")) g_us = (useconds_t)atoi(getenv("SAMPLE_US"));
    const struct mach_header_64 *h = exe_hdr(); g_base = (uint64_t)h; g_end = g_base + 0x4000000;
    tab = calloc(CAP, sizeof(ent_t)); tab2 = calloc(CAP, sizeof(ent_t));
    g_main = mach_thread_self();
    pthread_t t; pthread_create(&t, 0, sampler, 0);
}
__attribute__((destructor)) static void fini(void) {
    if (!tab) return; g_stop = 1;
    FILE *f = fopen(getenv("SAMPLE_OUT"), "w");
    fprintf(f, "BASE %llx\nSAMPLES %llu\n", (unsigned long long)g_base, (unsigned long long)g_n);
    for (size_t i = 0; i < CAP; i++) if (tab[i].pc) {
        fprintf(f, "L %llx %llu", (unsigned long long)tab[i].pc, (unsigned long long)tab[i].n);
        if (!(tab[i].pc >= g_base && tab[i].pc < g_end)) { Dl_info di; if (dladdr((void *)tab[i].pc, &di) && di.dli_sname) fprintf(f, " %s", di.dli_sname); else fprintf(f, " ?"); }
        fprintf(f, "\n");
    }
    for (size_t i = 0; i < CAP; i++) if (tab2[i].pc) fprintf(f, "E %llx %llu\n", (unsigned long long)tab2[i].pc, (unsigned long long)tab2[i].n);
    fclose(f);
}
