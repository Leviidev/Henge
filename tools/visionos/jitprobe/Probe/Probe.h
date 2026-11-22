#include <stddef.h>
/* Waits for a debugger, runs the JIT steps, returns a report (static buffer). */
const char *probe_run(void);
/* Whether a debugger is attached now (CS_DEBUGGED). */
int probe_debugged(void);
