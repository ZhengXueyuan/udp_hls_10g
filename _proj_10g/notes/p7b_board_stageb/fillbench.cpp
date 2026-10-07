#include "p7b_pattern.h"
#include <ctime>
#include <vector>
#include <cstdio>
int main(){
  size_t N=1ull<<27; std::vector<uint8_t> b(1<<16); P7bPat p(0);
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  size_t done=0; while(done<N){ p.fill(b.data(), b.size()); done+=b.size(); }
  clock_gettime(CLOCK_MONOTONIC,&t1);
  double dt=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)*1e-9;
  printf("FILL %.3f GB in %.3f s = %.3f GB/s = %.2f Gbps\n", N/1e9, dt, N/1e9/dt, N*8.0/dt/1e9);
  return 0;
}
