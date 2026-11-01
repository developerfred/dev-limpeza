//! Directory walker. macOS uses a parallel getattrlistbulk walker; other systems use a portable
//! single-threaded one that reports apparent (not allocated) sizes.
const builtin = @import("builtin");

const impl = if (builtin.os.tag == .macos) @import("walker_macos.zig") else @import("walker_portable.zig");

pub const Found = impl.Found;
pub const Pool = impl.Pool;
pub const nowNs = impl.nowNs;
pub const exists = impl.exists;
pub const alloc = impl.alloc;
