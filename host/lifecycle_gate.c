#include "lifecycle_gate.h"

/* Shared by VM owners and standalone device tools. */
HvLifecycleGate hv_app_lifecycle = HV_LIFECYCLE_INITIALIZER;
HvLifecycleGate hv_cpu_lifecycle = HV_LIFECYCLE_INITIALIZER;
pthread_mutex_t hv_lifecycle_state_mu = PTHREAD_MUTEX_INITIALIZER;
