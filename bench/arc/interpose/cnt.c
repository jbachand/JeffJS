#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <mach-o/dyld.h>
typedef struct { uintptr_t ra; uintptr_t ra1; uintptr_t ra2; uint64_t n[4]; } E;   // 0 retain 1 release 2 bridgeRetain 3 bridgeRelease
#define CAP (1<<20)
static E *tab; static uint64_t tot[4];
static inline void bump(uintptr_t ra,int k){
  void**fp=(void**)__builtin_frame_address(1); uintptr_t ra1=0; uintptr_t ra2=0; if(fp){ ra1=(uintptr_t)fp[1]; void**f2=(void**)fp[0]; if(f2) ra2=(uintptr_t)f2[1]; }

  if(!tab) return;
  uint64_t h=((ra*0x9E3779B97F4A7C15ull)^(ra1*0xC2B2AE3D27D4EB4Full)^(ra2*0x165667B19E3779F9ull))>>44; h&=CAP-1;
  while(1){ E*e=&tab[h]; if(e->ra==ra&&e->ra1==ra1&&e->ra2==ra2){e->n[k]++;break;} if(e->ra==0){e->ra=ra;e->ra1=ra1;e->ra2=ra2;e->n[k]=1;break;} h=(h+1)&(CAP-1);} tot[k]++;
}
extern void *swift_retain(void*); extern void swift_release(void*);
extern void *swift_bridgeObjectRetain(void*); extern void swift_bridgeObjectRelease(void*);
void *my_retain(void*o){ bump((uintptr_t)__builtin_return_address(0),0); return swift_retain(o);}
void my_release(void*o){ bump((uintptr_t)__builtin_return_address(0),1); swift_release(o);}
void *my_bretain(void*o){ bump((uintptr_t)__builtin_return_address(0),2); return swift_bridgeObjectRetain(o);}
void my_brelease(void*o){ bump((uintptr_t)__builtin_return_address(0),3); swift_bridgeObjectRelease(o);}
#define INTERPOSE(r,o) __attribute__((used)) static struct{const void*r_;const void*o_;} _ip_##o __attribute__((section("__DATA,__interpose"))) = {(const void*)r,(const void*)o}
INTERPOSE(my_retain,swift_retain); INTERPOSE(my_release,swift_release);
INTERPOSE(my_bretain,swift_bridgeObjectRetain); INTERPOSE(my_brelease,swift_bridgeObjectRelease);
#include <mach-o/loader.h>
static const void* exe_base(void){ for(uint32_t i=0;i<_dyld_image_count();i++){ const struct mach_header_64*h=(const struct mach_header_64*)_dyld_get_image_header(i); if(h->filetype==MH_EXECUTE) return h; } return 0; }
__attribute__((constructor)) static void init(void){ tab=calloc(CAP,sizeof(E)); }
__attribute__((destructor)) static void fini(void){
  FILE*f=fopen(getenv("CNT_OUT")?getenv("CNT_OUT"):"/dev/stderr","w");
  fprintf(f,"BASE %lx\n",(unsigned long)exe_base()); fprintf(f,"TOTAL %llu %llu %llu %llu\n",tot[0],tot[1],tot[2],tot[3]);
  for(size_t i=0;i<CAP;i++) if(tab[i].ra) fprintf(f,"%lx %lx %lx %llu %llu %llu %llu\n",tab[i].ra,tab[i].ra1,tab[i].ra2,tab[i].n[0],tab[i].n[1],tab[i].n[2],tab[i].n[3]);
  fclose(f);
}
