//! The build options the Lua platform's native host modules read (builtins,
//! host_alloc, tracy), fixed for a release host; build.zig generates the
//! compiler's own. Used by build-host only.
pub const debug = false;
pub const trace_refcount = false;
pub const debug_gpa_stack_trace_frames: usize = 0;
pub const enable_tracy = false;
pub const enable_tracy_allocation = false;
pub const enable_tracy_callstack = false;
pub const tracy_callstack_depth: u32 = 0;
