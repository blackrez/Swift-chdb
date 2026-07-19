// Minimal C shim to ensure the C target produces an object file,
// which causes SwiftPM to invoke the linker with this target's
// library search paths and link directives for libchdb.
#include "chdb.h"
