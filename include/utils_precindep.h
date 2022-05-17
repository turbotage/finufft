// Header for utils_precindep.cpp, a little library of array and timer stuff.
// Only the precision-independent routines here (get compiled once)

#ifndef UTILS_PRECINDEP_H
#define UTILS_PRECINDEP_H

#include "dataTypes.h"
// for CNTime...
#include <sys/time.h>

namespace finufft::utils {
  
  BIGINT next235even(BIGINT n);

  // jfm's timer class
  class CNTime {
  public:
    void start();
    double restart();
    double elapsedsec();
  private:
    struct timeval initial;
  };

  // openmp helpers
  int get_num_threads_parallel_block();
}
  
// thread-safe rand number generator for Windows platform
#ifdef _WIN32
#include <random>
int finufft::utils::rand_r(unsigned int *seedp);
#endif

#endif  // UTILS_PRECINDEP_H
