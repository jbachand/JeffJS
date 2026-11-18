// symlib: print the dyld symbol for each hex address on stdin (shared-cache addresses are the same in every process until reboot).
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
int main(void){ char line[128]; while(fgets(line,sizeof line,stdin)){ unsigned long long a=strtoull(line,0,16); Dl_info i; if(dladdr((void*)a,&i)&&i.dli_sname) printf("%llx %s\n",a,i.dli_sname); else printf("%llx ?\n",a);} return 0; }
