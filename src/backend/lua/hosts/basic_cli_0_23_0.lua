-- LuaJIT host for basic-cli 0.23.0 (github.com/roc-lang/basic-cli, UPL-1.0),
-- a port of its Rust host (src/lib.rs at 2f835a2). The platform is a
-- downloaded package, so roc_luajit bundles this host and finds it by the
-- platform's source fingerprint (LuaHost.zig). Hosted functions the port does
-- not provide yet are absent, so a program using them fails to load with the
-- missing symbol's name.
--
-- Values follow the emitter's table ABI: Try is { 1, ok } or { 0, err }
-- (variants sorted by name). A single-variant union with a payload, such as
-- [StdoutErr(IOErr)], keeps its tag_union layout, so it is { 0, payload }
-- (the native glue unwraps it); one whose payload is zero-sized collapses to
-- `{}`, rt.ZST. Unit variants are { discriminant, rt.ZST }, except in a union
-- of exactly two unit variants, whose layout is Bool: discriminant 1 is true.
-- Hosted functions consume their arguments.
--
-- System calls go through the FFI to libc so errno, and with it the IOErr,
-- matches what Rust's std sees. File metadata uses Linux statx; other systems
-- are not ported yet.
local ffi = require("ffi")
local bit = require("bit")

ffi.cdef([[
typedef long ssize_t;
typedef unsigned long size_t;
typedef long off_t;
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int open(const char *path, int flags, ...);
int close(int fd);
off_t lseek(int fd, off_t offset, int whence);
int mkdir(const char *path, unsigned int mode);
int rmdir(const char *path);
int unlink(const char *path);
int link(const char *old, const char *new);
int rename(const char *old, const char *new);
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
ssize_t readlink(const char *path, char *buf, size_t size);
int symlink(const char *target, const char *linkpath);
typedef int pid_t;
typedef struct { uint64_t opaque[10]; } posix_spawn_file_actions_t;
typedef struct { uint64_t opaque[42]; } posix_spawnattr_t;
typedef struct { uint64_t opaque[16]; } sigset_t;
int pipe2(int fds[2], int flags);
int fcntl(int fd, int cmd, ...);
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
	const posix_spawnattr_t *attr, char *const argv[], char *const envp[]);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions);
int posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions, int fd, int newfd);
int posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *actions, int fd, const char *path, int flags, unsigned int mode);
int posix_spawn_file_actions_addchdir_np(posix_spawn_file_actions_t *actions, const char *path);
int posix_spawnattr_init(posix_spawnattr_t *attr);
int posix_spawnattr_destroy(posix_spawnattr_t *attr);
int posix_spawnattr_setflags(posix_spawnattr_t *attr, short flags);
int posix_spawnattr_setpgroup(posix_spawnattr_t *attr, pid_t pgroup);
int posix_spawnattr_setsigmask(posix_spawnattr_t *attr, const sigset_t *mask);
int posix_spawnattr_setsigdefault(posix_spawnattr_t *attr, const sigset_t *mask);
int sigemptyset(sigset_t *set);
int sigaddset(sigset_t *set, int sig);
pid_t waitpid(pid_t pid, int *status, int options);
int kill(pid_t pid, int sig);
struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
long syscall(long number, ...);
typedef unsigned int socklen_t;
struct sockaddr { unsigned short sa_family; char sa_data[14]; };
struct sockaddr_in { unsigned short sin_family; uint16_t sin_port; uint8_t sin_addr[4]; uint8_t sin_zero[8]; };
struct sockaddr_in6 { unsigned short sin6_family; uint16_t sin6_port; uint32_t sin6_flowinfo; uint8_t sin6_addr[16]; uint32_t sin6_scope_id; };
struct sockaddr_storage { unsigned short ss_family; char ss_padding[118]; uint64_t ss_align; };
struct addrinfo {
	int ai_flags; int ai_family; int ai_socktype; int ai_protocol; socklen_t ai_addrlen;
	struct sockaddr *ai_addr; char *ai_canonname; struct addrinfo *ai_next;
};
int getaddrinfo(const char *node, const char *service, const struct addrinfo *hints, struct addrinfo **res);
void freeaddrinfo(struct addrinfo *res);
int inet_pton(int af, const char *src, void *dst);
int socket(int domain, int type, int protocol);
int connect(int fd, const struct sockaddr *addr, socklen_t len);
int bind(int fd, const struct sockaddr *addr, socklen_t len);
int listen(int fd, int backlog);
int accept4(int fd, struct sockaddr *addr, socklen_t *len, int flags);
int getsockname(int fd, struct sockaddr *addr, socklen_t *len);
int getsockopt(int fd, int level, int name, void *value, socklen_t *len);
ssize_t recv(int fd, void *buf, size_t len, int flags);
ssize_t send(int fd, const void *buf, size_t len, int flags);
void *signal(int sig, void *handler);
int chmod(const char *path, unsigned int mode);
char *realpath(const char *path, char *resolved);
void free(void *ptr);
char *getenv(const char *name);
extern char **environ;
char *strerror(int errnum);
typedef struct DIR DIR;
struct dirent { uint64_t d_ino; int64_t d_off; unsigned short d_reclen; unsigned char d_type; char d_name[256]; };
DIR *opendir(const char *name);
struct dirent *readdir(DIR *dirp);
int closedir(DIR *dirp);
struct statx_timestamp { int64_t tv_sec; uint32_t tv_nsec; int32_t reserved; };
struct statx {
	uint32_t stx_mask; uint32_t stx_blksize; uint64_t stx_attributes;
	uint32_t stx_nlink; uint32_t stx_uid; uint32_t stx_gid; uint16_t stx_mode; uint16_t spare0;
	uint64_t stx_ino; uint64_t stx_size; uint64_t stx_blocks; uint64_t stx_attributes_mask;
	struct statx_timestamp stx_atime, stx_btime, stx_ctime, stx_mtime;
	uint32_t stx_rdev_major, stx_rdev_minor, stx_dev_major, stx_dev_minor;
	uint64_t spare2[14];
};
int statx(int dirfd, const char *path, int flags, unsigned int mask, struct statx *buf);
struct timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clock, struct timespec *tp);
int nanosleep(const struct timespec *req, struct timespec *rem);
struct gaicb {
	const char *ar_name;
	const char *ar_service;
	const struct addrinfo *ar_request;
	struct addrinfo *ar_result;
	int __return;
	int __glibc_reserved[5];
};
int getaddrinfo_a(int mode, struct gaicb *list[], int nitems, void *sevp);
int gai_suspend(const struct gaicb *const list[], int nitems, const struct timespec *timeout);
int gai_error(struct gaicb *req);
int gai_cancel(struct gaicb *req);
ssize_t getrandom(void *buf, size_t len, unsigned int flags);
int isatty(int fd);
int tcgetattr(int fd, void *termios);
int tcsetattr(int fd, int actions, const void *termios);
void cfmakeraw(void *termios);
]])
local C = ffi.C

local M = {}

local STDIN_BUFFER = 8192 -- Rust's BufReader capacity
local STDIN_BYTES_CHUNK = 16384 -- hosted_stdin_bytes reads at most this much
-- Bytes per list element natively, which list capacities follow.
local OS_STR_WIDTH = 32 -- a NativeOsStr/NativePath: 24-byte payload, tag, alignment
local STR_WIDTH = 24
local ENV_PAIR_WIDTH = 2 * OS_STR_WIDTH

-- Linux constants.
local O_RDONLY, O_CLOEXEC = 0, 0x80000
local O_WRONLY, O_CREAT, O_TRUNC = 1, 0x40, 0x200
local MODE_BITS = 4095 -- 0o7777: permission, setuid, setgid and sticky bits
local TEMP_DIR_MODE = 448 -- 0o700, as tempfile creates them
local TEMP_RANDOM_CHARS = 6 -- tempfile's default random name length
local ALPHANUMERIC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local SEEK_SET, SEEK_CUR, SEEK_END = 0, 1, 2
local AT_FDCWD, AT_SYMLINK_NOFOLLOW = -100, 0x100
local STATX_BASIC_STATS, STATX_BTIME = 0x7ff, 0x800
local S_IFMT, S_IFDIR, S_IFREG, S_IFLNK = 0xf000, 0x4000, 0x8000, 0xa000
local CLOCK_REALTIME, CLOCK_MONOTONIC = 0, 1
local EINTR, EEXIST, EINVAL = 4, 17, 22
local ENOENT, EAGAIN, EACCES, ENOTDIR = 2, 11, 13, 20
-- Processes (glibc on Linux).
local SIGKILL, SIGPIPE = 9, 13
local SIG_IGN = 1
local WNOHANG = 1
local F_GETFL, F_SETFL, O_NONBLOCK = 3, 4, 0x800
local POLLIN, POLLOUT = 1, 4
local SYS_PIDFD_OPEN = 434
local POSIX_SPAWN_SETPGROUP, POSIX_SPAWN_SETSIGDEF, POSIX_SPAWN_SETSIGMASK = 0x2, 0x4, 0x8
local DEFAULT_PATH = "/bin:/usr/bin" -- execvp's search path when PATH is unset
local PIPE_CHUNK = 8192 -- process_service.rs reads output in 8 KiB chunks
local CMD_RUN_RESULT_WIDTH = 64 -- CmdRunResult natively: two lists, two I32s, a U8
-- Sockets (Linux), in one table: M.run stays under LuaJIT's limit of 60
-- upvalues per function.
local NET = {
	AF_INET = 2, AF_INET6 = 10, SOCK_STREAM = 1, SOCK_NONBLOCK = 0x800, SOL_SOCKET = 1, SO_ERROR = 4,
	MSG_NOSIGNAL = 0x4000, EINPROGRESS = 115,
	LISTEN_BACKLOG = 128, -- socket2 listen(128) in basic-cli's listener.rs
	TCP_BUFFER = 8192, -- BufReader<TcpStream>'s default capacity
}
-- std::io::ErrorKind for an errno (std's decode_error_kind), by Debug name.
NET.ERRNO_ERROR_KIND = {
	[1] = "PermissionDenied", [2] = "NotFound", [4] = "Interrupted", [7] = "ArgumentListTooLong",
	[11] = "WouldBlock", [12] = "OutOfMemory", [13] = "PermissionDenied", [16] = "ResourceBusy",
	[17] = "AlreadyExists", [18] = "CrossesDevices", [20] = "NotADirectory", [21] = "IsADirectory",
	[22] = "InvalidInput", [26] = "ExecutableFileBusy", [27] = "FileTooLarge", [28] = "StorageFull",
	[29] = "NotSeekable", [30] = "ReadOnlyFilesystem", [31] = "TooManyLinks", [32] = "BrokenPipe",
	[35] = "Deadlock", [36] = "InvalidFilename", [38] = "Unsupported", [39] = "DirectoryNotEmpty",
	[40] = "FilesystemLoop", [95] = "Unsupported", [98] = "AddrInUse", [99] = "AddrNotAvailable",
	[100] = "NetworkDown", [101] = "NetworkUnreachable", [103] = "ConnectionAborted",
	[104] = "ConnectionReset", [107] = "NotConnected", [110] = "TimedOut", [111] = "ConnectionRefused",
	[113] = "HostUnreachable", [116] = "StaleNetworkFileHandle", [122] = "QuotaExceeded",
}
-- tcp.rs to_tcp_connect_err / to_tcp_stream_err: these kinds cross as
-- "ErrorKind::<kind>" (WouldBlock as TimedOut); any other kind as its name.
NET.CONNECT_ERROR_KINDS = {
	PermissionDenied = true, AddrInUse = true, AddrNotAvailable = true, ConnectionRefused = true,
	Interrupted = true, TimedOut = true, Unsupported = true,
}
NET.STREAM_ERROR_KINDS = {
	PermissionDenied = true, ConnectionRefused = true, ConnectionReset = true, Interrupted = true,
	TimedOut = true, OutOfMemory = true, BrokenPipe = true,
}
local TERMIOS_BYTES = 128 -- at least sizeof(struct termios) on every libc

-- IOErr variants (IOErr.roc, sorted by name as the glue numbers them).
local IOERR = {
	AlreadyExists = 0, BrokenPipe = 1, Interrupted = 2, IsADirectory = 3, NotADirectory = 4,
	NotFound = 5, Other = 6, OutOfMemory = 7, PermissionDenied = 8, Unsupported = 9,
}
-- std::io::ErrorKind for the errno values IOErr names (std's decode_error_kind).
local ERRNO_KIND = {
	[1] = "PermissionDenied", [2] = "NotFound", [4] = "Interrupted", [12] = "OutOfMemory",
	[13] = "PermissionDenied", [17] = "AlreadyExists", [20] = "NotADirectory", [21] = "IsADirectory",
	[32] = "BrokenPipe", [38] = "Unsupported", [95] = "Unsupported",
}

function M.run(app, argv)
	-- As basic-cli's host does: I/O effects return BrokenPipe instead of the
	-- process dying; spawned children get SIGPIPE's default back.
	C.signal(SIGPIPE, ffi.cast("void *", SIG_IGN))
	local rt
	local ZST
	local function ok(v) return { 1, v } end
	local function err(v) return { 0, v } end

	-- Errors are { kind, message } until they become an IOErr value: kind
	-- names an IOErr variant; Other carries Rust's Display text.
	local function os_error(errno)
		return { ERRNO_KIND[errno] or "Other", ("%s (os error %d)"):format(ffi.string(C.strerror(errno)), errno) }
	end
	local function last_error() return os_error(ffi.errno()) end
	local function ioerr(e)
		if e[1] == "Other" then return { IOERR.Other, e[2] } end
		return { IOERR[e[1]], ZST }
	end
	-- An IOErr inside a single-variant wrapper ([StdoutErr(IOErr)] and the like).
	local function wrapped(e) return { 0, ioerr(e) } end
	local function write_result(file, ...)
		local done, _, errno = file:write(...)
		if done then return ok(ZST) end
		return err(wrapped(os_error(errno or 5)))
	end

	-- NativeOsStr / NativePath ([UnixBytes(List(U8)), Utf8(Str), WindowsU16s(...)]).
	local UNIX_BYTES, UTF8 = 0, 1
	local function from_native(v)
		if v[1] == UNIX_BYTES then
			local s = rt.list_bytes(v[2])
			rt.L.decref(v[2], nil)
			return s
		elseif v[1] == UTF8 then
			return v[2]
		end
		rt.L.decref(v[2], nil)
		return nil, { "Unsupported" }
	end
	local function to_native(s) return { UNIX_BYTES, rt.str_to_utf8(s) } end
	local function list_of(items, width)
		if #items == 0 then return (rt.L.empty()) end
		return (rt.L.literal(width, items, #items))
	end

	-- U128 from an exact uint64: eight 16-bit limbs, least significant first.
	local function u128(x)
		x = ffi.cast("uint64_t", x)
		local limbs = {}
		for i = 1, 4 do
			limbs[i] = tonumber(bit.band(x, 0xffff))
			x = bit.rshift(x, 16)
		end
		for i = 5, 8 do limbs[i] = 0 end
		return limbs
	end
	local function nanos(sec, nsec) return (u128(ffi.cast("uint64_t", sec) * 1000000000ULL + nsec)) end

	-- Linux statx; `follow` = false for symlink_metadata.
	local function stat(path, follow, mask)
		local buf = ffi.new("struct statx")
		if C.statx(AT_FDCWD, path, follow and 0 or AT_SYMLINK_NOFOLLOW, mask or STATX_BASIC_STATS, buf) ~= 0 then
			return nil, last_error()
		end
		return buf
	end
	local function file_kind(st)
		local fmt = bit.band(st.stx_mode, S_IFMT)
		if fmt == S_IFLNK then return "SymLink" end
		if fmt == S_IFDIR then return "Dir" end
		if fmt == S_IFREG then return "File" end
		return "Other"
	end
	local function is_dir(path)
		local st = stat(path, true)
		return st ~= nil and bit.band(st.stx_mode, S_IFMT) == S_IFDIR
	end

	-- Path::join and Path::parent for byte paths.
	local function join(dir, name)
		if dir == "" then return name end
		if dir:sub(-1) == "/" then return dir .. name end
		return dir .. "/" .. name
	end
	local function parent(path)
		local trimmed = path:gsub("/+$", "")
		if trimmed == "" then return nil end -- "/" has no parent
		local cut = trimmed:match("^(.*)/[^/]*$")
		if cut == nil then return "" end
		if cut == "" then return "/" end
		return (cut:gsub("/+$", ""))
	end

	-- A single read(2), retried on EINTR.
	local function sys_read(fd, cbuf, max)
		while true do
			local n = tonumber(C.read(fd, cbuf, max))
			if n >= 0 then return n end
			local errno = ffi.errno()
			if errno ~= EINTR then return nil, os_error(errno) end
		end
	end

	-- fs::read_dir as paths joined to `dir`, in readdir order.
	local function read_dir(dir)
		local d = C.opendir(dir)
		if d == nil then return nil, last_error() end
		local entries = {}
		while true do
			ffi.errno(0)
			local entry = C.readdir(d)
			if entry == nil then
				local errno = ffi.errno()
				C.closedir(d)
				if errno ~= 0 then return nil, os_error(errno) end
				return entries
			end
			local name = ffi.string(entry.d_name)
			if name ~= "." and name ~= ".." then entries[#entries + 1] = join(dir, name) end
		end
	end

	-- fs::remove_dir_all: a symlink is removed itself; directories are emptied
	-- depth first without following links.
	local function remove_dir_all(path)
		local st, e = stat(path, false)
		if not st then return nil, e end
		if file_kind(st) == "SymLink" then
			if C.unlink(path) ~= 0 then return nil, last_error() end
			return true
		end
		local function remove_tree(dir)
			local entries, e2 = read_dir(dir)
			if not entries then return nil, e2 end
			for _, child in ipairs(entries) do
				local cst, e3 = stat(child, false)
				if not cst then return nil, e3 end
				if file_kind(cst) == "Dir" then
					local done, e4 = remove_tree(child)
					if not done then return nil, e4 end
				elseif C.unlink(child) ~= 0 then
					return nil, last_error()
				end
			end
			if C.rmdir(dir) ~= 0 then return nil, last_error() end
			return true
		end
		return remove_tree(path)
	end

	-- DirBuilder::create_dir_all.
	local function create_dir_all(path)
		if path == "" then return true end
		if C.mkdir(path, 511) == 0 then return true end
		local e = last_error()
		if e[1] ~= "NotFound" then
			if is_dir(path) then return true end
			return nil, e
		end
		local up = parent(path)
		if up == nil then return nil, { "Other", "failed to create whole tree" } end
		local done, e2 = create_dir_all(up)
		if not done then return nil, e2 end
		if C.mkdir(path, 511) == 0 or is_dir(path) then return true end
		return nil, last_error()
	end

	-- Whole-file reads and writes (fs::read, fs::write).
	local function read_file(path)
		local fd = C.open(path, bit.bor(O_RDONLY, O_CLOEXEC))
		if fd < 0 then return nil, last_error() end
		local cbuf = ffi.new("uint8_t[?]", 65536)
		local parts = {}
		while true do
			local n, e = sys_read(fd, cbuf, 65536)
			if not n then
				C.close(fd)
				return nil, e
			end
			if n == 0 then break end
			parts[#parts + 1] = ffi.string(cbuf, n)
		end
		C.close(fd)
		return table.concat(parts)
	end
	local function write_file(path, bytes)
		local f, _, errno = io.open(path, "wb")
		if not f then return nil, os_error(errno) end
		local done, _, werrno = f:write(bytes)
		local closed, _, cerrno = f:close()
		if not done then return nil, os_error(werrno) end
		if not closed then return nil, os_error(cerrno) end
		return true
	end
	local function utf8_valid(s)
		return (rt.str_from_utf8(rt.str_to_utf8(s), function() return true end, function() return false end))
	end

	-- Rust's stdout is line buffered whatever it writes to; stderr is not
	-- buffered.
	io.stdout:setvbuf("line")
	io.stderr:setvbuf("no")

	-- stdin through a buffer like Rust's BufReader: lines come from the
	-- buffer, refilled by one read(2) of up to STDIN_BUFFER bytes; byte reads
	-- return what is buffered, or bypass the buffer with a read(2) of up to
	-- STDIN_BYTES_CHUNK bytes when it is empty.
	local stdin_buf = ""
	local raw = ffi.new("uint8_t[?]", STDIN_BYTES_CHUNK)
	local function read_raw(max)
		local n, e = sys_read(0, raw, max)
		if not n then return nil, e end
		return ffi.string(raw, n)
	end

	-- File readers: BufReader<File> over a raw fd. A FileReader is a
	-- Box(U64) whose value names an entry here.
	local readers, next_reader = {}, 1
	local function reader_fill(r)
		if r.pos > #r.buf then
			local cbuf = ffi.new("uint8_t[?]", r.cap)
			local n, e = sys_read(r.fd, cbuf, r.cap)
			if not n then return nil, e end
			r.buf, r.pos = ffi.string(cbuf, n), 1
		end
		return true
	end
	-- BufReader::read: buffered bytes first; an empty buffer and a request at
	-- least as large as it reads straight from the file.
	local function reader_read(r, count)
		if r.pos > #r.buf and count >= r.cap then
			local cbuf = ffi.new("uint8_t[?]", count)
			local n, e = sys_read(r.fd, cbuf, count)
			if not n then return nil, e end
			return ffi.string(cbuf, n)
		end
		local filled, e = reader_fill(r)
		if not filled then return nil, e end
		local chunk = r.buf:sub(r.pos, r.pos + count - 1)
		r.pos = r.pos + #chunk
		return chunk
	end
	local function reader_of(handle) return readers[handle.v] end
	-- A hosted function that consumes its handle: the handle is released after
	-- the operation, as basic-cli's resources.rs does, so a final release (and
	-- the box's drop) cannot interrupt it.
	local function releasing(f)
		return function(handle, ...)
			local result = f(handle, ...)
			rt.box_decref(handle, nil)
			return result
		end
	end

	local hosted = {}

	-- Standard streams -------------------------------------------------------
	function hosted.hosted_stdout_line(s) return (write_result(io.stdout, s, "\n")) end
	function hosted.hosted_stdout_write(s)
		local r = write_result(io.stdout, s)
		io.stdout:flush()
		return r
	end
	function hosted.hosted_stdout_write_bytes(l)
		local r = write_result(io.stdout, rt.list_bytes(l))
		rt.L.decref(l, nil)
		io.stdout:flush()
		return r
	end
	function hosted.hosted_stderr_line(s) return (write_result(io.stderr, s, "\n")) end
	function hosted.hosted_stderr_write(s) return (write_result(io.stderr, s)) end
	function hosted.hosted_stderr_write_bytes(l)
		local r = write_result(io.stderr, rt.list_bytes(l))
		rt.L.decref(l, nil)
		return r
	end
	-- Try(Str, [EndOfFile, StdinErr(IOErr)]): EndOfFile = 0, StdinErr = 1.
	function hosted.hosted_stdin_line()
		while true do
			local newline = stdin_buf:find("\n", 1, true)
			if newline then
				local line = stdin_buf:sub(1, newline - 1)
				stdin_buf = stdin_buf:sub(newline + 1)
				line = line:gsub("\r$", "")
				return ok(line)
			end
			local chunk, e = read_raw(STDIN_BUFFER)
			if not chunk then return err({ 1, ioerr(e) }) end
			if #chunk == 0 then
				if #stdin_buf == 0 then return err({ 0, ZST }) end
				local line = stdin_buf:gsub("\r$", "")
				stdin_buf = ""
				return ok(line)
			end
			stdin_buf = stdin_buf .. chunk
		end
	end
	-- Try(List(U8), [EndOfFile, StdinErr(IOErr)]).
	function hosted.hosted_stdin_bytes()
		local bytes
		if #stdin_buf > 0 then
			bytes = stdin_buf:sub(1, STDIN_BYTES_CHUNK)
			stdin_buf = stdin_buf:sub(STDIN_BYTES_CHUNK + 1)
		else
			local e
			bytes, e = read_raw(STDIN_BYTES_CHUNK)
			if not bytes then return err({ 1, ioerr(e) }) end
			if #bytes == 0 then return err({ 0, ZST }) end
		end
		return ok(rt.str_to_utf8(bytes))
	end
	-- Try(List(U8), [StdinErr(IOErr)]).
	function hosted.hosted_stdin_read_to_end()
		local parts = { stdin_buf }
		stdin_buf = ""
		while true do
			local chunk, e = read_raw(STDIN_BYTES_CHUNK)
			if not chunk then return err(wrapped(e)) end
			if #chunk == 0 then break end
			parts[#parts + 1] = chunk
		end
		return ok(rt.str_to_utf8(table.concat(parts)))
	end

	-- Environment ------------------------------------------------------------
	-- Try(NativeOsStr, [EnvErr(IOErr), VarNotFound(NativeOsStr)]).
	function hosted.hosted_env_var(name)
		local key, e = from_native(name)
		if key and (key == "" or key:find("[%z=]")) then
			e = { "Other", "environment variable names cannot be empty or contain nul bytes or '='" }
			key = nil
		end
		if not key then return err({ 0, ioerr(e) }) end
		local value = C.getenv(key)
		if value == nil then return err({ 1, to_native(key) }) end
		return ok(to_native(ffi.string(value)))
	end
	-- Try(NativePath, [CwdUnavailable]).
	function hosted.hosted_env_cwd()
		local cbuf = ffi.new("char[?]", 4096)
		if C.getcwd(cbuf, 4096) == nil then return err(ZST) end
		return ok(to_native(ffi.string(cbuf)))
	end
	-- Try(NativePath, [ExePathUnavailable]): this process's executable.
	function hosted.hosted_env_exe_path()
		local cbuf = ffi.new("char[?]", 4096)
		local n = tonumber(C.readlink("/proc/self/exe", cbuf, 4096))
		if n < 0 then return err(ZST) end
		return ok(to_native(ffi.string(cbuf, n)))
	end
	-- Try(NativeOsStr, [ProgramNameUnavailable]): argv[0], here the program file.
	function hosted.hosted_env_program_name()
		if arg == nil or arg[0] == nil then return err(ZST) end
		return ok(to_native(arg[0]))
	end
	-- std::env::temp_dir: $TMPDIR, else /tmp.
	function hosted.hosted_env_temp_dir()
		local tmp = C.getenv("TMPDIR")
		return (to_native(tmp ~= nil and ffi.string(tmp) or "/tmp"))
	end
	-- { arch : [AARCH64, ARM, OTHER(Str), X64, X86], os : [LINUX, MACOS, OTHER(Str), WINDOWS] }.
	function hosted.hosted_env_platform()
		local arch = ({ arm64 = { 0, ZST }, arm = { 1, ZST }, x64 = { 3, ZST }, x86 = { 4, ZST } })[jit.arch] or { 2, jit.arch }
		local os_tag = ({ Linux = { 0, ZST }, OSX = { 1, ZST }, Windows = { 3, ZST } })[jit.os] or { 2, jit.os:lower() }
		return { arch, os_tag }
	end
	-- List((NativeOsStr, NativeOsStr)) in environ order.
	function hosted.hosted_env_dict()
		local pairs_ = {}
		local i = 0
		while C.environ[i] ~= nil do
			local entry = ffi.string(C.environ[i])
			local name, value = entry:match("^([^=]*)=(.*)$")
			if name and name ~= "" then pairs_[#pairs_ + 1] = { to_native(name), to_native(value) } end
			i = i + 1
		end
		return (list_of(pairs_, ENV_PAIR_WIDTH))
	end
	-- Try({}, IOErr).
	function hosted.hosted_env_set_cwd(path)
		local p, e = from_native(path)
		if not p then return err(ioerr(e)) end
		if C.chdir(p) ~= 0 then return err(ioerr(last_error())) end
		return ok(ZST)
	end

	-- Directories -------------------------------------------------------------
	-- Try({}, [DirErr(IOErr)]) and Try(List(NativePath), [DirErr(IOErr)]).
	local function dir_op(op)
		return function(path)
			local p, e = from_native(path)
			if not p then return err(wrapped(e)) end
			local done, e2 = op(p)
			if not done then return err(wrapped(e2)) end
			return ok(ZST)
		end
	end
	hosted.hosted_dir_create = dir_op(function(p)
		if C.mkdir(p, 511) ~= 0 then return nil, last_error() end
		return true
	end)
	hosted.hosted_dir_create_all = dir_op(create_dir_all)
	hosted.hosted_dir_delete_empty = dir_op(function(p)
		if C.rmdir(p) ~= 0 then return nil, last_error() end
		return true
	end)
	hosted.hosted_dir_delete_all = dir_op(remove_dir_all)
	function hosted.hosted_dir_list(path)
		local p, e = from_native(path)
		if not p then return err(wrapped(e)) end
		local entries, e2 = read_dir(p)
		if not entries then return err(wrapped(e2)) end
		for i, entry in ipairs(entries) do entries[i] = to_native(entry) end
		return ok(list_of(entries, OS_STR_WIDTH))
	end
	-- Try([Dir, File, Other, SymLink], IOErr), from symlink_metadata.
	function hosted.hosted_path_type(path)
		local p, e = from_native(path)
		if not p then return err(ioerr(e)) end
		local st, e2 = stat(p, false)
		if not st then return err(ioerr(e2)) end
		return ok({ ({ Dir = 0, File = 1, Other = 2, SymLink = 3 })[file_kind(st)], ZST })
	end

	-- Paths: copies, absolute and canonical forms, temporary directories -------
	-- A port of basic-cli's src/filesystem.rs and Rust's std::path::absolute.
	local function invalid(message) return { "Other", message } end
	local function current_dir()
		local cbuf = ffi.new("char[?]", 4096)
		if C.getcwd(cbuf, 4096) == nil then return nil, last_error() end
		return ffi.string(cbuf)
	end
	-- Path::components of a byte path: "/" for a leading root, then the
	-- non-empty parts; interior "." parts are dropped, a leading one kept.
	local function components(path)
		local parts = {}
		if path:sub(1, 1) == "/" then parts[1] = "/" end
		for part in path:gmatch("[^/]+") do
			if part ~= "." or (#parts == 0 and path:sub(1, 2) == "./") then parts[#parts + 1] = part end
		end
		return parts
	end
	-- PathBuf::push of one component (a root replaces the path).
	local function push(base, part)
		if part == "/" then return "/" end
		if base == "" then return part end
		if base:sub(-1) == "/" then return base .. part end
		return base .. "/" .. part
	end
	-- PathBuf::pop.
	local function pop(path)
		local up = parent(path)
		if up == nil then return path end
		return up
	end
	-- Path::starts_with, component by component.
	local function starts_with(path, base)
		local a, b = components(path), components(base)
		if #b > #a then return false end
		for i = 1, #b do
			if a[i] ~= b[i] then return false end
		end
		return true
	end
	-- std::path::absolute on Unix: the working directory joined to a relative
	-- path, components normalized except "..", a leading "//" (not "///") and a
	-- trailing "/" kept, symlinks not resolved.
	local function absolute(path)
		if path == "" then return nil, invalid("cannot make an empty path absolute") end
		local stripped = path
		if path == "." then
			stripped = ""
		elseif path:sub(1, 2) == "./" then
			stripped = path:gsub("^%./+", "")
		end
		local parts = components(stripped)
		local normalized, first = nil, 1
		if path:sub(1, 1) == "/" then
			if path:sub(1, 2) == "//" and path:sub(1, 3) ~= "///" then
				normalized, first = "//", 2
			else
				normalized = ""
			end
		else
			local e
			normalized, e = current_dir()
			if not normalized then return nil, e end
		end
		for i = first, #parts do normalized = push(normalized, parts[i]) end
		if path:sub(-1) == "/" and normalized:sub(-1) ~= "/" then normalized = normalized .. "/" end
		return normalized
	end
	-- fs::canonicalize, by realpath(3).
	local function canonicalize(path)
		local resolved = C.realpath(path, nil)
		if resolved == nil then return nil, last_error() end
		local s = ffi.string(resolved)
		C.free(resolved)
		return s
	end
	-- prospective_canonical: canonicalize the existing ancestors, links
	-- included, without requiring the leaf to exist.
	local function prospective_canonical(path)
		local real, e = canonicalize(path)
		if real then return real end
		if e[1] ~= "NotFound" then return nil, e end
		local abs, e2 = absolute(path)
		if not abs then return nil, e2 end
		local resolved = ""
		for _, part in ipairs(components(abs)) do
			if part == ".." then
				resolved = pop(resolved)
			elseif part ~= "." then
				resolved = push(resolved, part)
				local r, e3 = canonicalize(resolved)
				if r then
					resolved = r
				elseif e3[1] ~= "NotFound" then
					return nil, e3
				end
			end
		end
		return resolved
	end
	local function same_file(a, b)
		return a.stx_ino == b.stx_ino and a.stx_dev_major == b.stx_dev_major and a.stx_dev_minor == b.stx_dev_minor
	end
	-- write(2) until every byte is written.
	local function write_all(fd, bytes)
		local cbuf, done = ffi.cast("const uint8_t *", bytes), 0
		while done < #bytes do
			local n = tonumber(C.write(fd, cbuf + done, #bytes - done))
			if n < 0 then
				local errno = ffi.errno()
				if errno ~= EINTR then return nil, os_error(errno) end
			else
				done = done + n
			end
		end
		return true
	end
	-- fs::copy: the destination is created with the source's permissions,
	-- truncated, and given those permissions again if it existed.
	local function fs_copy(source, destination, mode)
		local input = C.open(source, bit.bor(O_RDONLY, O_CLOEXEC))
		if input < 0 then return nil, last_error() end
		local output = C.open(destination, bit.bor(O_WRONLY, O_CREAT, O_TRUNC, O_CLOEXEC), ffi.cast("unsigned int", mode))
		if output < 0 then
			local e = last_error()
			C.close(input)
			return nil, e
		end
		local function finish(done, e)
			C.close(input)
			C.close(output)
			return done, e
		end
		if C.chmod(destination, mode) ~= 0 then return finish(nil, last_error()) end
		local cbuf = ffi.new("uint8_t[?]", 65536)
		while true do
			local n, e = sys_read(input, cbuf, 65536)
			if not n then return finish(nil, e) end
			if n == 0 then return finish(true) end
			local done, e2 = write_all(output, ffi.string(cbuf, n))
			if not done then return finish(nil, e2) end
		end
	end
	-- A CopyFailure ({ destination, error, operation, source }) as an Err.
	local function copy_failure(operation, source, destination, e)
		return err({ to_native(destination), ioerr(e), operation, to_native(source) })
	end
	local function copy_file(source, destination)
		local function run()
			local st, e = stat(source, true)
			if not st then return nil, e end
			if file_kind(st) ~= "File" then return nil, invalid("source is not a regular file") end
			local dst, e2 = stat(destination, true)
			if dst then
				if file_kind(dst) ~= "File" then return nil, invalid("destination is not a regular file") end
				if same_file(st, dst) then return nil, invalid("source and destination identify the same file") end
			elseif e2[1] ~= "NotFound" then
				return nil, e2
			end
			return fs_copy(source, destination, bit.band(st.stx_mode, MODE_BITS))
		end
		local done, e = run()
		if not done then return copy_failure("copy_file", source, destination, e) end
		return ok(ZST)
	end
	-- copy_tree: a directory copied depth first in readdir order; links are
	-- recreated (preserve) or followed, with a cycle check on the resolved
	-- ancestors; directory permissions are applied after their children.
	local function copy_tree(source, destination, preserve, merge, ancestors)
		local resolved, e = canonicalize(source)
		if not resolved then return copy_failure("resolve_source", source, destination, e) end
		local resolved_destination, e2 = prospective_canonical(destination)
		if not resolved_destination then return copy_failure("resolve_destination", source, destination, e2) end
		if starts_with(resolved_destination, resolved) then
			return copy_failure("copy_dir", source, destination, invalid("destination is inside source"))
		end
		if ancestors[resolved] then
			return copy_failure("copy_dir", source, destination, invalid("symbolic link cycle"))
		end
		ancestors[resolved] = true
		local function run()
			local st, e3 = stat(source, true)
			if not st then return copy_failure("metadata", source, destination, e3) end
			if file_kind(st) ~= "Dir" then return copy_failure("copy_dir", source, destination, { "NotADirectory" }) end
			local up = parent(destination)
			if up ~= nil and up ~= "" then
				local made, e4 = create_dir_all(up)
				if not made then return copy_failure("create_parent_dirs", source, destination, e4) end
			end
			if C.mkdir(destination, 511) ~= 0 then
				local e5 = last_error()
				if not (merge and e5[1] == "AlreadyExists") then return copy_failure("create_dir", source, destination, e5) end
				local dst, e6 = stat(destination, false)
				if not dst then return copy_failure("metadata", source, destination, e6) end
				if file_kind(dst) ~= "Dir" then return copy_failure("create_dir", source, destination, { "NotADirectory" }) end
			end
			local entries, e7 = read_dir(source)
			if not entries then return copy_failure("read_dir", source, destination, e7) end
			for _, src in ipairs(entries) do
				local dst = join(destination, src:match("[^/]*$"))
				local link, e8 = stat(src, false)
				if not link then return copy_failure("metadata", src, dst, e8) end
				if file_kind(link) == "SymLink" and preserve then
					local cbuf = ffi.new("char[?]", 4096)
					local n = tonumber(C.readlink(src, cbuf, 4096))
					if n < 0 or C.symlink(ffi.string(cbuf, n), dst) ~= 0 then
						return copy_failure("copy_symlink", src, dst, last_error())
					end
				else
					local target, e9 = stat(src, true)
					if not target then return copy_failure("metadata", src, dst, e9) end
					local r
					if file_kind(target) == "Dir" then
						r = copy_tree(src, dst, preserve, merge, ancestors)
					else
						r = copy_file(src, dst)
					end
					if r[1] == 0 then return r end
				end
			end
			if C.chmod(destination, bit.band(st.stx_mode, MODE_BITS)) ~= 0 then
				return copy_failure("set_permissions", source, destination, last_error())
			end
			return ok(ZST)
		end
		local result = run()
		ancestors[resolved] = nil
		return result
	end
	local function copy_dir(source, destination, preserve, merge)
		local src, e = canonicalize(source)
		if not src then return copy_failure("resolve_source", source, destination, e) end
		local dst, e2 = prospective_canonical(destination)
		if not dst then return copy_failure("resolve_destination", source, destination, e2) end
		if starts_with(dst, src) or starts_with(src, dst) then
			return copy_failure("copy_dir", source, destination, invalid("source and destination trees overlap"))
		end
		return copy_tree(source, destination, preserve, merge, {})
	end
	-- Both paths of a copy, or a decode_path failure that hands the original
	-- values back.
	local function native_bytes(v)
		if v[1] == UNIX_BYTES then return rt.list_bytes(v[2]) end
		if v[1] == UTF8 then return v[2] end
		return nil
	end
	local function release_native(v)
		if v[1] ~= UTF8 then rt.L.decref(v[2], nil) end
	end
	local function copy_paths(source, destination, f)
		local s, d = native_bytes(source), native_bytes(destination)
		if s == nil or d == nil then
			return err({ destination, ioerr({ "Unsupported" }), "decode_path", source })
		end
		release_native(source)
		release_native(destination)
		return f(s, d)
	end
	-- Try({}, CopyFailure).
	function hosted.hosted_path_copy(source, destination)
		return copy_paths(source, destination, copy_file)
	end
	-- CopyOptions { destination : [Merge, RequireNew], symlinks : [Follow, Preserve] }:
	-- both fields are two-variant unions, so booleans (Merge and Follow false).
	function hosted.hosted_path_copy_dir(source, destination, options)
		return copy_paths(source, destination, function(s, d)
			return copy_dir(s, d, options[2], not options[1])
		end)
	end
	-- Try(NativePath, IOErr).
	local function path_result(f)
		return function(path)
			local p, e = from_native(path)
			if p then p, e = f(p) end
			if not p then return err(ioerr(e)) end
			return ok(to_native(p))
		end
	end
	hosted.hosted_path_absolute = path_result(absolute)
	hosted.hosted_path_canonicalize = path_result(canonicalize)
	-- tempfile's Builder::tempdir_in: a relative parent is joined to the
	-- working directory; the name is the prefix and six random alphanumeric
	-- characters, retried while it already exists; mode 0o700.
	local function create_temp_dir(dir, prefix)
		if prefix:find("[/\\:%z]") or prefix == "." or prefix == ".." then
			return nil, invalid("temporary directory prefix must be a filename component")
		end
		if dir:sub(1, 1) ~= "/" then
			local cwd, e = current_dir()
			if not cwd then return nil, e end
			dir = join(cwd, dir)
		end
		local random = ffi.new("uint8_t[?]", TEMP_RANDOM_CHARS)
		while true do
			if C.getrandom(random, TEMP_RANDOM_CHARS, 0) ~= TEMP_RANDOM_CHARS then return nil, last_error() end
			local chars = {}
			for i = 0, TEMP_RANDOM_CHARS - 1 do
				local k = random[i] % #ALPHANUMERIC + 1
				chars[#chars + 1] = ALPHANUMERIC:sub(k, k)
			end
			local path = join(dir, prefix .. table.concat(chars))
			if C.mkdir(path, TEMP_DIR_MODE) == 0 then return path end
			if ffi.errno() ~= EEXIST then return nil, last_error() end
		end
	end
	-- Try(NativePath, IOErr).
	function hosted.hosted_env_create_temp_dir(parent_path, prefix)
		return path_result(function(p) return create_temp_dir(p, prefix) end)(parent_path)
	end

	-- Files --------------------------------------------------------------------
	-- Try(_, [FileErr(IOErr)]) results.
	local function file_result(value, e)
		if value == nil then return err(wrapped(e)) end
		return ok(value)
	end
	local function with_path(path, f)
		local p, e = from_native(path)
		if not p then return err(wrapped(e)) end
		return f(p)
	end
	function hosted.hosted_file_read_bytes(path)
		return with_path(path, function(p)
			local bytes, e = read_file(p)
			if not bytes then return err(wrapped(e)) end
			return ok(rt.str_to_utf8(bytes))
		end)
	end
	function hosted.hosted_file_read_utf8(path)
		return with_path(path, function(p)
			local bytes, e = read_file(p)
			if bytes and not utf8_valid(bytes) then bytes, e = nil, { "Other", "stream did not contain valid UTF-8" } end
			return file_result(bytes, e)
		end)
	end
	function hosted.hosted_file_write_bytes(path, l)
		local bytes = rt.list_bytes(l)
		rt.L.decref(l, nil)
		return with_path(path, function(p)
			local done, e = write_file(p, bytes)
			return file_result(done and ZST, e)
		end)
	end
	function hosted.hosted_file_write_utf8(path, s)
		return with_path(path, function(p)
			local done, e = write_file(p, s)
			return file_result(done and ZST, e)
		end)
	end
	function hosted.hosted_file_delete(path)
		return with_path(path, function(p)
			if C.unlink(p) ~= 0 then return err(wrapped(last_error())) end
			return ok(ZST)
		end)
	end
	local function two_paths(op)
		return function(a, b)
			local pa, ea = from_native(a)
			local pb, eb = from_native(b)
			if not pa then return err(wrapped(ea)) end
			if not pb then return err(wrapped(eb)) end
			if op(pa, pb) ~= 0 then return err(wrapped(last_error())) end
			return ok(ZST)
		end
	end
	hosted.hosted_file_hard_link = two_paths(function(a, b) return C.link(a, b) end)
	hosted.hosted_file_rename = two_paths(function(a, b) return C.rename(a, b) end)
	-- Metadata (fs::metadata follows symlinks).
	local function with_stat(path, mask, f)
		return with_path(path, function(p)
			local st, e = stat(p, true, mask)
			if not st then return err(wrapped(e)) end
			return f(st)
		end)
	end
	function hosted.hosted_file_size_in_bytes(path)
		return with_stat(path, nil, function(st) return ok(rt.norm_u64(st.stx_size)) end)
	end
	local function permission_bit(mask)
		return function(path)
			return with_stat(path, nil, function(st) return ok(bit.band(st.stx_mode, mask) ~= 0) end)
		end
	end
	hosted.hosted_file_is_executable = permission_bit(73) -- 0o111
	hosted.hosted_file_is_readable = permission_bit(256) -- 0o400
	hosted.hosted_file_is_writable = permission_bit(128) -- 0o200
	function hosted.hosted_file_time_accessed(path)
		return with_stat(path, nil, function(st) return ok(nanos(st.stx_atime.tv_sec, st.stx_atime.tv_nsec)) end)
	end
	function hosted.hosted_file_time_modified(path)
		return with_stat(path, nil, function(st) return ok(nanos(st.stx_mtime.tv_sec, st.stx_mtime.tv_nsec)) end)
	end
	-- Metadata::created: the birth time, which not every filesystem records.
	function hosted.hosted_file_time_created(path)
		return with_stat(path, bit.bor(STATX_BASIC_STATS, STATX_BTIME), function(st)
			if bit.band(st.stx_mask, STATX_BTIME) == 0 then return err(wrapped({ "Unsupported" })) end
			return ok(nanos(st.stx_btime.tv_sec, st.stx_btime.tv_nsec))
		end)
	end

	-- File readers (Box(U64) handles) -----------------------------------------
	function hosted.hosted_file_open_reader(path, capacity)
		return with_path(path, function(p)
			local fd = C.open(p, bit.bor(O_RDONLY, O_CLOEXEC))
			if fd < 0 then return err(wrapped(last_error())) end
			local id = next_reader
			next_reader = next_reader + 1
			readers[id] = { fd = fd, cap = capacity == 0 and 8192 or tonumber(capacity), buf = "", pos = 1 }
			-- Freeing the last reference closes the file.
			return ok({ rc = 1, v = id, drop = function(k)
				C.close(readers[k].fd)
				readers[k] = nil
			end })
		end)
	end
	-- BufRead::read_until(b'\n').
	function hosted.hosted_file_read_line(handle)
		local r = reader_of(handle)
		local parts = {}
		while true do
			local filled, e = reader_fill(r)
			if not filled then return err(wrapped(e)) end
			if r.pos > #r.buf then break end
			local newline = r.buf:find("\n", r.pos, true)
			local stop = newline or #r.buf
			parts[#parts + 1] = r.buf:sub(r.pos, stop)
			r.pos = stop + 1
			if newline then break end
		end
		return ok(rt.str_to_utf8(table.concat(parts)))
	end
	function hosted.hosted_file_read_up_to(handle, count)
		local r = reader_of(handle)
		count = tonumber(count)
		if count == 0 then return ok(rt.L.empty()) end
		local bytes, e = reader_read(r, count)
		if not bytes then return err(wrapped(e)) end
		return ok(rt.str_to_utf8(bytes))
	end
	-- Try(List(U8), [FileErr(IOErr), FileUnexpectedEOF]): FileErr = 0.
	function hosted.hosted_file_read_exactly(handle, count)
		local r = reader_of(handle)
		count = tonumber(count)
		local parts, got = {}, 0
		while got < count do
			local bytes, e = reader_read(r, count - got)
			if not bytes then return err({ 0, ioerr(e) }) end
			if #bytes == 0 then return err({ 1, ZST }) end
			parts[#parts + 1] = bytes
			got = got + #bytes
		end
		return ok(rt.str_to_utf8(table.concat(parts)))
	end
	-- Seek::stream_position: the file offset less what is still buffered.
	local function reader_position(r)
		local at = C.lseek(r.fd, 0, SEEK_CUR)
		if at < 0 then return nil, last_error() end
		return tonumber(at) - (#r.buf - r.pos + 1)
	end
	function hosted.hosted_file_reader_position(handle)
		local r = reader_of(handle)
		local at, e = reader_position(r)
		return file_result(at, e)
	end
	-- [Current(I64), End(I64), Start(U64)]: BufReader::seek discards the
	-- buffer; Current counts from the logical position.
	function hosted.hosted_file_reader_seek(handle, from)
		local r = reader_of(handle)
		local whence, offset = ({ [0] = SEEK_CUR, [1] = SEEK_END, [2] = SEEK_SET })[from[1]], from[2]
		if whence == SEEK_CUR then offset = offset - (#r.buf - r.pos + 1) end
		local at = C.lseek(r.fd, offset, whence)
		r.buf, r.pos = "", 1
		if at < 0 then return err(wrapped(last_error())) end
		return ok(rt.norm_u64(ffi.cast("uint64_t", at)))
	end

	for _, name in ipairs({ "hosted_file_read_line", "hosted_file_read_up_to", "hosted_file_read_exactly",
		"hosted_file_reader_position", "hosted_file_reader_seek" }) do
		hosted[name] = releasing(hosted[name])
	end

	-- Clocks, randomness, sleep, locale, terminal ------------------------------
	function hosted.hosted_utc_now()
		local ts = ffi.new("struct timespec")
		C.clock_gettime(CLOCK_REALTIME, ts)
		if ts.tv_sec < 0 then return err(ZST) end
		return ok(nanos(ts.tv_sec, ts.tv_nsec))
	end
	-- Nanoseconds since the first call (Instant::elapsed from a lazy origin).
	local monotonic_origin
	function hosted.hosted_monotonic_now()
		local ts = ffi.new("struct timespec")
		C.clock_gettime(CLOCK_MONOTONIC, ts)
		local now = ffi.cast("uint64_t", ts.tv_sec) * 1000000000ULL + ts.tv_nsec
		monotonic_origin = monotonic_origin or now
		return (rt.norm_u64(now - monotonic_origin))
	end
	function hosted.hosted_sleep_millis(millis)
		local ms = ffi.cast("uint64_t", millis)
		local req = ffi.new("struct timespec", { tv_sec = tonumber(ms / 1000ULL), tv_nsec = tonumber(ms % 1000ULL) * 1000000 })
		local rem = ffi.new("struct timespec")
		while C.nanosleep(req, rem) ~= 0 and ffi.errno() == EINTR do req.tv_sec, req.tv_nsec = rem.tv_sec, rem.tv_nsec end
		return ZST
	end
	local function random_bytes(n)
		local cbuf = ffi.new("uint8_t[?]", n)
		local got = 0
		while got < n do
			local r = tonumber(C.getrandom(cbuf + got, n - got, 0))
			if r < 0 then
				local errno = ffi.errno()
				if errno ~= EINTR then return nil, os_error(errno) end
			else
				got = got + r
			end
		end
		return cbuf
	end
	-- Try(U32 / U64, [RandomErr(IOErr)]): native-endian bytes from getrandom.
	function hosted.hosted_random_seed_u32()
		local cbuf, e = random_bytes(4)
		if not cbuf then return err(wrapped(e)) end
		return ok(tonumber(ffi.cast("uint32_t*", cbuf)[0]))
	end
	function hosted.hosted_random_seed_u64()
		local cbuf, e = random_bytes(8)
		if not cbuf then return err(wrapped(e)) end
		return ok(rt.norm_u64(ffi.cast("uint64_t*", cbuf)[0]))
	end
	-- sys_locale's order (LANGUAGE's list, then LC_ALL, LC_MESSAGES, LANG),
	-- each POSIX locale cut at '.' or '@' with '_' as '-', then basic-cli's
	-- normalize_locale: C/POSIX and malformed BCP 47 tags dropped, duplicates
	-- (ignoring case) dropped.
	local function locale_is_valid(locale)
		local subtags = {}
		for part in (locale .. "-"):gmatch("([^-]*)-") do subtags[#subtags + 1] = part end
		local language = subtags[1]
		if language == nil or language == "" then return false end
		for _, s in ipairs(subtags) do
			if s == "" or #s > 8 or s:find("[^%w]") then return false end
		end
		local special = #language == 1 and (language:lower() == "x" or language:lower() == "i")
		if not special and (#language < 2 or #language > 8 or language:find("[^%a]")) then return false end
		if special and #subtags == 1 then return false end
		for index = 2, #subtags do
			local s = subtags[index]
			if #s == 1 and index == #subtags then return false end
			if s:lower() == "x" then return index < #subtags end
		end
		return true
	end
	local function locales()
		local raw = {}
		local function add(value)
			local locale = value:match("^[^.@]*"):gsub("_", "-")
			for _, existing in ipairs(raw) do
				if existing == locale then return end
			end
			raw[#raw + 1] = locale
		end
		local language = C.getenv("LANGUAGE")
		if language ~= nil and ffi.string(language) ~= "" then
			for part in (ffi.string(language) .. ":"):gmatch("([^:]*):") do add(part) end
		end
		for _, name in ipairs({ "LC_ALL", "LC_MESSAGES", "LANG" }) do
			local value = C.getenv(name)
			if value ~= nil and ffi.string(value) ~= "" then add(ffi.string(value)) end
		end
		local out = {}
		for _, locale in ipairs(raw) do
			local base = locale:match("^%s*(.-)%s*$"):match("^[^.@]*")
			if base:upper() ~= "C" and base:upper() ~= "POSIX" then
				local normalized = base:gsub("_", "-")
				if locale_is_valid(normalized) then
					local seen = false
					for _, existing in ipairs(out) do
						if existing:lower() == normalized:lower() then seen = true end
					end
					if not seen then out[#out + 1] = normalized end
				end
			end
		end
		return out
	end
	function hosted.hosted_locale_all() return (list_of(locales(), STR_WIDTH)) end
	-- Try(Str, [NotAvailable]).
	function hosted.hosted_locale_get()
		local first = locales()[1]
		if first == nil then return err(ZST) end
		return ok(first)
	end
	-- Processes ----------------------------------------------------------------
	-- A port of basic-cli's cmd.rs and process_service.rs. Rust supervises each
	-- child on a service thread; here one poll(2) loop (pump) does that work
	-- for every live child whenever a host call has to wait: it drains output
	-- pipes into captures or events (or forwards them), feeds automatic stdin,
	-- notices exits through pidfds and enforces deadlines and limits. Results,
	-- limits and error values follow the Rust service; only when output is
	-- drained differs, since nothing runs while Roc code does.
	local children, next_child, live = {}, 1, {}

	local function now_ms()
		local ts = ffi.new("struct timespec")
		C.clock_gettime(CLOCK_MONOTONIC, ts)
		return tonumber(ts.tv_sec) * 1000 + tonumber(ts.tv_nsec) / 1e6
	end
	local function close_fd(fd)
		if fd and fd >= 0 then C.close(fd) end
	end
	local function set_nonblocking(fd)
		local flags = C.fcntl(fd, F_GETFL)
		C.fcntl(fd, F_SETFL, ffi.cast("int", bit.bor(flags, O_NONBLOCK)))
	end
	local function new_pipe()
		local fds = ffi.new("int[2]")
		if C.pipe2(fds, O_CLOEXEC) ~= 0 then return nil, last_error() end
		return fds[0], fds[1]
	end

	-- A Roc List(NativeOsStr) as Lua strings (cmd.rs take_arg_list: the
	-- first undecodable element is the error).
	local function native_list(l)
		local values, first_error = {}, nil
		for k = 0, l[3] - 1 do
			local v = rt.L.get_unsafe(l, k)
			local s = native_bytes(v)
			if s == nil then first_error = first_error or { "Unsupported" } else values[#values + 1] = s end
		end
		rt.L.decref(l, nil)
		if first_error then return nil, first_error end
		return values
	end
	local function has_nul(s) return s:find("%z") ~= nil end
	local NUL_ERROR = { "Other", "nul byte found in provided data" }

	-- The child's environment as "name=value" strings, or nil to inherit ours.
	-- Like std's CommandEnv, a cleared or modified environment is sorted by
	-- name; later settings of a name win.
	local function child_environment(clear, pairs_list)
		if not clear and #pairs_list == 0 then return nil end
		local vars, names = {}, {}
		local function set(name, value)
			if vars[name] == nil then names[#names + 1] = name end
			vars[name] = value
		end
		if not clear then
			local i = 0
			while C.environ[i] ~= nil do
				local entry = ffi.string(C.environ[i])
				local eq = entry:find("=", 2, true)
				if eq then set(entry:sub(1, eq - 1), entry:sub(eq + 1)) end
				i = i + 1
			end
		end
		for i = 1, #pairs_list - 1, 2 do set(pairs_list[i], pairs_list[i + 1]) end
		table.sort(names)
		local env = {}
		for _, name in ipairs(names) do env[#env + 1] = name .. "=" .. vars[name] end
		return env, vars.PATH
	end

	local function cstring_array(strings)
		local arr = ffi.new("char *[?]", #strings + 1)
		local keep = {}
		for i, s in ipairs(strings) do
			keep[i] = ffi.new("char[?]", #s + 1, s)
			arr[i - 1] = keep[i]
		end
		return arr, keep
	end

	-- Decode a Host.Cmd record (fields in alphabetical order) into a spawn
	-- configuration; capture_default turns Default (0) streams into a null
	-- stdin and captured output, as cmd.rs command_config does.
	local function command_config(cmd, capture_default)
		local stdin_bytes = rt.list_bytes(cmd[11])
		rt.L.decref(cmd[11], nil)
		local program, e = from_native(cmd[9])
		local args, e2 = native_list(cmd[1])
		local envs, e3 = native_list(cmd[4])
		local cwd, e4 = native_list(cmd[3])
		local first = e or e2 or e4 or e3
		if first then return nil, first end
		local function mode(m, default)
			m = tonumber(m)
			if capture_default and m == 0 then return default end
			return m
		end
		return {
			program = program, args = args, envs = envs, cwd = cwd[1], clear_envs = cmd[2],
			stdin_mode = mode(cmd[12], 2), stdout_mode = mode(cmd[13], 3), stderr_mode = mode(cmd[10], 3),
			input = stdin_bytes, timeout_ms = tonumber(cmd[14]), output_limit = tonumber(cmd[7]),
			pending_limit = tonumber(cmd[8]), manage_tree = cmd[5], merge_stderr = cmd[6],
		}
	end

	local function is_piped(mode) return mode >= 3 and mode <= 5 end

	-- posix_spawn the configured command. Returns a child record, or nil and
	-- an error. A bare program name is searched for on the child's PATH, as
	-- std::process::Command does, trying each directory like execvp.
	local function spawn(config)
		local strings = { config.program }
		for _, a in ipairs(config.args) do strings[#strings + 1] = a end
		for _, s in ipairs(strings) do
			if has_nul(s) then return nil, NUL_ERROR end
		end
		for _, s in ipairs(config.envs) do
			if has_nul(s) then return nil, NUL_ERROR end
		end
		if config.cwd and has_nul(config.cwd) then return nil, NUL_ERROR end
		local env, child_path = child_environment(config.clear_envs, config.envs)
		if env == nil then
			local p = C.getenv("PATH")
			child_path = p ~= nil and ffi.string(p) or nil
		end

		local actions = ffi.new("posix_spawn_file_actions_t")
		local attr = ffi.new("posix_spawnattr_t")
		C.posix_spawn_file_actions_init(actions)
		C.posix_spawnattr_init(attr)
		local parent_fds, child_fds = {}, {}
		local function cleanup(keep_parent)
			C.posix_spawn_file_actions_destroy(actions)
			C.posix_spawnattr_destroy(attr)
			for _, fd in ipairs(child_fds) do close_fd(fd) end
			if not keep_parent then
				for _, fd in ipairs(parent_fds) do close_fd(fd) end
			end
		end
		local function pipe_for(child_end_is_read)
			local r, w = new_pipe()
			if not r then return nil, w end
			if child_end_is_read then
				parent_fds[#parent_fds + 1], child_fds[#child_fds + 1] = w, r
				return r, w
			end
			parent_fds[#parent_fds + 1], child_fds[#child_fds + 1] = r, w
			return w, r
		end

		local child = {
			readers = {}, output = { stdout = {}, stderr = {}, used = 0, failure = 0 },
			events = {}, event_first = 1, event_last = 0, pending = 0,
			stdout_mode = config.stdout_mode, stderr_mode = config.stderr_mode,
			output_limit = config.output_limit, pending_limit = config.pending_limit,
			group = config.manage_tree,
		}
		-- stdin
		local sm = config.stdin_mode
		if sm == 2 then
			C.posix_spawn_file_actions_addopen(actions, 0, "/dev/null", O_RDONLY, 0)
		elseif sm == 3 or sm == 4 then
			local child_end, parent_end = pipe_for(true)
			if not child_end then
				cleanup()
				return nil, parent_end
			end
			C.posix_spawn_file_actions_adddup2(actions, child_end, 0)
			set_nonblocking(parent_end)
			if sm == 3 then
				child.auto = { fd = parent_end, data = config.input, off = 0 }
			else
				child.stdin_fd = parent_end
			end
		end
		-- stdout and stderr; merged streams share one pipe, preserving the
		-- kernel's write order.
		local function output(fd, mode, stream)
			if mode == 2 then
				C.posix_spawn_file_actions_addopen(actions, fd, "/dev/null", O_WRONLY, 0)
			elseif is_piped(mode) then
				local child_end, parent_end = pipe_for(false)
				if not child_end then return nil, parent_end end
				C.posix_spawn_file_actions_adddup2(actions, child_end, fd)
				child.readers[#child.readers + 1] = { fd = parent_end, stream = stream, mode = mode }
			end
			return true
		end
		local ok_, oe
		if config.merge_stderr and config.stdout_mode ~= 2 then
			local child_end, parent_end = pipe_for(false)
			if not child_end then
				cleanup()
				return nil, parent_end
			end
			C.posix_spawn_file_actions_adddup2(actions, child_end, 1)
			C.posix_spawn_file_actions_adddup2(actions, child_end, 2)
			child.readers[1] = { fd = parent_end, stream = 1, mode = config.stdout_mode }
			ok_ = true
		else
			ok_, oe = output(1, config.stdout_mode, 1)
			if ok_ then
				ok_, oe = output(2, config.merge_stderr and 2 or config.stderr_mode, 2)
			end
		end
		if not ok_ then
			cleanup()
			return nil, oe
		end
		if config.cwd then C.posix_spawn_file_actions_addchdir_np(actions, config.cwd) end

		-- std::process gives the child an empty signal mask and SIGPIPE's
		-- default disposition (the host ignores SIGPIPE).
		local mask, defaults = ffi.new("sigset_t"), ffi.new("sigset_t")
		C.sigemptyset(mask)
		C.sigemptyset(defaults)
		C.sigaddset(defaults, SIGPIPE)
		C.posix_spawnattr_setsigmask(attr, mask)
		C.posix_spawnattr_setsigdefault(attr, defaults)
		local flags = bit.bor(POSIX_SPAWN_SETSIGMASK, POSIX_SPAWN_SETSIGDEF)
		if config.manage_tree then
			flags = bit.bor(flags, POSIX_SPAWN_SETPGROUP)
			C.posix_spawnattr_setpgroup(attr, 0)
		end
		C.posix_spawnattr_setflags(attr, flags)

		local argv, argv_keep = cstring_array(strings)
		local envp, envp_keep
		if env then
			envp, envp_keep = cstring_array(env)
		else
			envp = C.environ
		end
		local candidates = {}
		if config.program:find("/", 1, true) then
			candidates[1] = config.program
		else
			for dir in ((child_path or DEFAULT_PATH) .. ":"):gmatch("([^:]*):") do
				candidates[#candidates + 1] = join(dir == "" and "." or dir, config.program)
			end
		end
		local pid = ffi.new("pid_t[1]")
		local errno, saw_eacces = ENOENT, false
		for _, path in ipairs(candidates) do
			errno = C.posix_spawn(pid, path, actions, attr, argv, envp)
			if errno == 0 then break end
			if errno == EACCES then saw_eacces = true end
			if errno ~= ENOENT and errno ~= ENOTDIR and errno ~= EACCES then break end
		end
		-- The argument and environment strings stay referenced until here.
		argv_keep, envp_keep = nil, nil
		if errno ~= 0 then
			if (errno == ENOENT or errno == ENOTDIR) and saw_eacces then errno = EACCES end
			cleanup()
			return nil, os_error(errno)
		end
		cleanup(true)
		child.pid = pid[0]
		child.pidfd = tonumber(C.syscall(ffi.cast("long", SYS_PIDFD_OPEN), ffi.cast("long", child.pid), ffi.cast("long", 0)))
		if config.timeout_ms ~= 0 then child.deadline = now_ms() + config.timeout_ms end
		for _, r in ipairs(child.readers) do set_nonblocking(r.fd) end
		if child.auto and #child.auto.data == 0 then
			close_fd(child.auto.fd)
			child.auto = nil
		end
		live[child] = true
		return child
	end

	-- Request termination (KillOnDrop / process_wrap's start_kill): the whole
	-- process group for a managed tree, else the child if not yet reaped.
	local function cancel(c)
		if c.done or c.killing then return end
		c.killing = true
		if c.group then
			C.kill(-c.pid, SIGKILL)
		elseif not c.status then
			C.kill(c.pid, SIGKILL)
		end
	end
	local function report_error(c, e)
		c.error = c.error or e
		cancel(c)
	end
	local function close_reader(r)
		close_fd(r.fd)
		r.fd = nil
	end
	-- The child is reaped and its output drained or abandoned: record the
	-- status and release every descriptor.
	local function finalize(c)
		for _, r in ipairs(c.readers) do close_reader(r) end
		if c.auto then close_fd(c.auto.fd) end
		c.auto = nil
		close_fd(c.stdin_fd)
		c.stdin_fd = nil
		close_fd(c.pidfd)
		c.pidfd = nil
		local status = c.status
		local signal = bit.band(status, 0x7f)
		if signal == 0 then
			c.exit_code, c.signal = bit.band(bit.rshift(status, 8), 0xff), 0
		else
			c.exit_code, c.signal = -1, signal
		end
		c.done = true
		live[c] = nil
	end
	local function reap(c)
		if c.status then return end
		local st = ffi.new("int[1]")
		if C.waitpid(c.pid, st, WNOHANG) == c.pid then c.status = st[0] end
	end

	-- Bytes read from a child's pipe (process_service.rs pump).
	local function deliver(c, r, bytes)
		local count, mode = #bytes, r.mode
		if mode == 4 then
			local keep = math.min(count, math.max(0, c.pending_limit - c.pending))
			if keep ~= 0 then
				-- A queue with explicit ends: popped slots become nil.
				c.event_last = c.event_last + 1
				c.events[c.event_last] = { stream = r.stream, bytes = bytes:sub(1, keep) }
				c.pending = c.pending + keep
			end
			if keep ~= count then
				c.output.failure = 2
				cancel(c)
			end
		elseif mode == 3 or mode == 5 then
			local out = c.output
			local keep = math.min(count, math.max(0, c.output_limit - out.used))
			local into = r.stream == 1 and out.stdout or out.stderr
			into[#into + 1] = bytes:sub(1, keep)
			out.used = out.used + keep
			if keep ~= count then
				out.failure = 2
				cancel(c)
			end
		end
		if mode == 5 or mode == 1 or mode == 0 then
			local file = r.stream == 1 and io.stdout or io.stderr
			local done, _, errno = file:write(bytes)
			if not done then report_error(c, os_error(errno or 5)) end
		end
	end

	local chunk = ffi.new("uint8_t[?]", PIPE_CHUNK)
	-- One round of supervision: wait up to timeout_ms (nil: until something
	-- happens) for any live child's descriptors, or for extra_fd to become
	-- writable, then act on what is ready. Returns whether extra_fd is.
	local function pump(timeout_ms, extra_fd)
		local t = now_ms()
		local wait = timeout_ms
		for c in pairs(live) do
			if c.deadline and not c.killing then
				if t >= c.deadline then
					c.output.failure = 1
					cancel(c)
				else
					wait = math.min(wait or math.huge, c.deadline - t)
				end
			end
		end
		local slots = {}
		for c in pairs(live) do
			if not c.status then slots[#slots + 1] = { c = c, fd = c.pidfd, events = POLLIN, kind = "exit" } end
			for _, r in ipairs(c.readers) do
				if r.fd then slots[#slots + 1] = { c = c, fd = r.fd, events = POLLIN, kind = "read", r = r } end
			end
			if c.auto then slots[#slots + 1] = { c = c, fd = c.auto.fd, events = POLLOUT, kind = "input" } end
		end
		if extra_fd then slots[#slots + 1] = { fd = extra_fd, events = POLLOUT, kind = "extra" } end
		local extra_ready = false
		if #slots > 0 then
			local fds = ffi.new("struct pollfd[?]", #slots)
			for i, s in ipairs(slots) do
				fds[i - 1].fd, fds[i - 1].events = s.fd, s.events
			end
			local ms = -1
			if wait and wait ~= math.huge then ms = math.max(0, math.ceil(wait)) end
			local n = C.poll(fds, #slots, ms)
			if n > 0 then
				for i, s in ipairs(slots) do
					if fds[i - 1].revents ~= 0 then
						local c = s.c
						if s.kind == "exit" then
							reap(c)
						elseif s.kind == "read" and s.r.fd then
							local got = tonumber(C.read(s.r.fd, chunk, PIPE_CHUNK))
							if got > 0 then
								deliver(c, s.r, ffi.string(chunk, got))
							elseif got == 0 then
								close_reader(s.r)
							else
								local errno = ffi.errno()
								if errno ~= EAGAIN and errno ~= EINTR then
									close_reader(s.r)
									report_error(c, os_error(errno))
								end
							end
						elseif s.kind == "input" and c.auto then
							local a = c.auto
							local ptr = ffi.cast("const uint8_t *", a.data)
							local wrote = tonumber(C.write(a.fd, ptr + a.off, #a.data - a.off))
							if wrote >= 0 then
								a.off = a.off + wrote
								if a.off >= #a.data then
									close_fd(a.fd)
									c.auto = nil
								end
							else
								local errno = ffi.errno()
								if errno ~= EAGAIN and errno ~= EINTR then
									close_fd(a.fd)
									c.auto = nil
									report_error(c, os_error(errno))
								end
							end
						elseif s.kind == "extra" then
							extra_ready = true
						end
					end
				end
			end
		end
		-- Completion: reaped, with every reader at end of file and automatic
		-- input written; a cancelled child completes once reaped.
		for c in pairs(live) do
			if c.killing then reap(c) end
			if c.status then
				local open = c.auto ~= nil
				for _, r in ipairs(c.readers) do open = open or r.fd ~= nil end
				if c.killing or not open then finalize(c) end
			end
		end
		return extra_ready
	end
	local function wait_done(c)
		while not c.done do pump(nil) end
	end

	-- CmdRunResult { exit_code, failure, signal, stderr_bytes, stdout_bytes }.
	local function run_output(c)
		return {
			c.exit_code, c.output.failure, c.signal,
			rt.str_to_utf8(table.concat(c.output.stderr)), rt.str_to_utf8(table.concat(c.output.stdout)),
		}
	end
	local function child_result(c)
		if c.error then return nil, c.error end
		return c
	end
	local INCOMPLETE = { [1] = "Process execution timed out", [2] = "Process output limit exceeded" }
	local function incomplete_reason(failure) return INCOMPLETE[failure] or "Process was killed by signal" end

	local function run_config(cmd, capture_default)
		local config, e = command_config(cmd, capture_default)
		if not config then return nil, e end
		local c, e2 = spawn(config)
		if not c then return nil, e2 end
		wait_done(c)
		return child_result(c)
	end
	-- Try(I32, IOErr).
	function hosted.hosted_cmd_host_exec_exit_code(cmd)
		local c, e = run_config(cmd, false)
		if not c then return err(ioerr(e)) end
		if c.output.failure == 0 and c.signal == 0 then return ok(c.exit_code) end
		return err(ioerr({ "Other", incomplete_reason(c.output.failure) }))
	end
	-- Try(CmdOutputSuccess, [FailedToGetExitCode(IOErr), NonZeroExitCode(CmdOutputFailure)]).
	function hosted.hosted_cmd_host_exec_output(cmd)
		local c, e = run_config(cmd, true)
		if not c then return err({ 0, ioerr(e) }) end
		if c.output.failure ~= 0 or c.signal ~= 0 then
			return err({ 0, ioerr({ "Other", incomplete_reason(c.output.failure) }) })
		end
		local stderr = rt.str_to_utf8(table.concat(c.output.stderr))
		local stdout = rt.str_to_utf8(table.concat(c.output.stdout))
		if c.exit_code == 0 then return ok({ stderr, stdout }) end
		return err({ 1, { c.exit_code, stderr, stdout } })
	end
	-- Try(CmdRunResult, IOErr).
	function hosted.hosted_cmd_run(cmd)
		local c, e = run_config(cmd, true)
		if not c then return err(ioerr(e)) end
		return ok(run_output(c))
	end
	-- Try(Child, IOErr): a Child is a Box(U64) naming an entry of `children`.
	function hosted.hosted_cmd_spawn(cmd)
		local config, e = command_config(cmd, false)
		if not config then return err(ioerr(e)) end
		local c, e2 = spawn(config)
		if not c then return err(ioerr(e2)) end
		local id = next_child
		next_child = next_child + 1
		children[id] = c
		-- Freeing the last reference terminates the child (Drop for Child).
		return ok({ rc = 1, v = id, drop = function(k)
			cancel(children[k])
			children[k] = nil
		end })
	end

	local CLOSED = { "BrokenPipe" } -- process_service.rs closed_error
	-- The handle is released after the operation (cmd.rs with_child).
	local function with_child(handle, f)
		local result = f(children[handle.v])
		rt.box_decref(handle, nil)
		return result
	end
	local function unit_result(done, e)
		if not done then return err(ioerr(e)) end
		return ok(ZST)
	end
	local function close_stdin(c)
		if c.closed then return nil, CLOSED end
		close_fd(c.stdin_fd)
		c.stdin_fd = nil
		return true
	end
	-- Try(U32, IOErr).
	function hosted.hosted_child_pid(handle)
		return with_child(handle, function(c)
			if c.closed then return err(ioerr(CLOSED)) end
			return ok(c.pid)
		end)
	end
	-- Try(CmdRunResult, IOErr): closes piped stdin, then waits.
	function hosted.hosted_child_wait(handle)
		return with_child(handle, function(c)
			local done, e = close_stdin(c)
			if not done then return err(ioerr(e)) end
			wait_done(c)
			if c.error then return err(ioerr(c.error)) end
			return ok(run_output(c))
		end)
	end
	-- Try(List(CmdRunResult), IOErr): [] while running.
	function hosted.hosted_child_try_wait(handle)
		return with_child(handle, function(c)
			if c.closed then return err(ioerr(CLOSED)) end
			pump(0)
			if not c.done then return ok(list_of({}, CMD_RUN_RESULT_WIDTH)) end
			if c.error then return err(ioerr(c.error)) end
			return ok(list_of({ run_output(c) }, CMD_RUN_RESULT_WIDTH))
		end)
	end
	-- Try({}, IOErr).
	function hosted.hosted_child_kill(handle)
		return with_child(handle, function(c)
			if c.closed then return err(ioerr(CLOSED)) end
			cancel(c)
			return ok(ZST)
		end)
	end
	-- Try({}, IOErr): terminate and reap; repeated closes succeed.
	function hosted.hosted_child_close(handle)
		return with_child(handle, function(c)
			if c.closed then return ok(ZST) end
			cancel(c)
			wait_done(c)
			c.closed = true
			if c.error then return err(ioerr(c.error)) end
			return ok(ZST)
		end)
	end
	-- Try({}, IOErr).
	function hosted.hosted_child_close_stdin(handle)
		return with_child(handle, function(c) return unit_result(close_stdin(c)) end)
	end
	-- Try({}, IOErr): every byte within timeout_ms, else TimedOut.
	function hosted.hosted_child_write(handle, l, timeout)
		local bytes = rt.list_bytes(l)
		rt.L.decref(l, nil)
		return with_child(handle, function(c)
			if c.closed or not c.stdin_fd then return err(ioerr(CLOSED)) end
			local deadline = now_ms() + tonumber(timeout)
			local ptr, off = ffi.cast("const uint8_t *", bytes), 0
			while off < #bytes do
				local wrote = tonumber(C.write(c.stdin_fd, ptr + off, #bytes - off))
				if wrote >= 0 then
					off = off + wrote
				else
					local errno = ffi.errno()
					if errno == EAGAIN then
						local remaining = deadline - now_ms()
						if remaining <= 0 then return err(ioerr({ "Other", "Child stdin write timed out" })) end
						pump(remaining, c.stdin_fd)
					elseif errno ~= EINTR then
						return err(ioerr(os_error(errno)))
					end
				end
			end
			return ok(ZST)
		end)
	end
	-- Try(ChildEvent { bytes, stream }, IOErr): the next chunk of at most
	-- max_bytes, stream 0 with no bytes once output is drained.
	function hosted.hosted_child_read(handle, max_bytes, timeout)
		return with_child(handle, function(c)
			if c.closed then return err(ioerr(CLOSED)) end
			local max = tonumber(max_bytes)
			if max == 0 then return err(ioerr({ "Other", "Read size must be positive" })) end
			local deadline = now_ms() + tonumber(timeout)
			pump(0)
			while true do
				local event = c.events[c.event_first]
				if event then
					local bytes = event.bytes
					if #bytes > max then
						event.bytes = bytes:sub(max + 1)
						bytes = bytes:sub(1, max)
					else
						c.events[c.event_first] = nil
						c.event_first = c.event_first + 1
					end
					c.pending = c.pending - #bytes
					return ok({ rt.str_to_utf8(bytes), event.stream })
				end
				if c.done then
					if c.error then return err(ioerr(c.error)) end
					return ok({ rt.str_to_utf8(""), 0 })
				end
				local remaining = deadline - now_ms()
				if remaining <= 0 then return err(ioerr({ "Other", "Child output read timed out" })) end
				pump(remaining)
			end
		end)
	end
	-- process_service::shutdown: terminate and reap every live child.
	local function shutdown_children()
		for c in pairs(live) do cancel(c) end
		while next(live) do pump(nil) end
	end

	-- TCP ------------------------------------------------------------------------
	-- A port of basic-cli's tcp.rs and listener.rs. Sockets stay non-blocking
	-- and every deadline is a poll(2) timeout, the counterpart of the Rust
	-- host's SO_RCVTIMEO/SO_SNDTIMEO and tokio timeouts. Errors cross to Roc as
	-- strings: "ErrorKind::<kind>" for the kinds Tcp.roc names, std's
	-- ErrorKind name for any other, "UnexpectedEof", "LimitExceeded" or
	-- "ListenerClosed". Name lookup is bounded by the operation's deadline, as the Rust
	-- host's resolver thread is (lookup).
	local AF_INET, AF_INET6, SOCK_STREAM, SOCK_NONBLOCK = NET.AF_INET, NET.AF_INET6, NET.SOCK_STREAM, NET.SOCK_NONBLOCK
	local SOL_SOCKET, SO_ERROR, MSG_NOSIGNAL, EINPROGRESS = NET.SOL_SOCKET, NET.SO_ERROR, NET.MSG_NOSIGNAL, NET.EINPROGRESS
	local LISTEN_BACKLOG, TCP_BUFFER = NET.LISTEN_BACKLOG, NET.TCP_BUFFER
	local ERRNO_ERROR_KIND, CONNECT_ERROR_KINDS, STREAM_ERROR_KINDS = NET.ERRNO_ERROR_KIND, NET.CONNECT_ERROR_KINDS, NET.STREAM_ERROR_KINDS
	local function kind_of(errno) return ERRNO_ERROR_KIND[errno] or "Uncategorized" end
	local function connect_error(kind)
		if kind == "WouldBlock" then kind = "TimedOut" end
		if CONNECT_ERROR_KINDS[kind] then return "ErrorKind::" .. kind end
		return kind
	end
	local function stream_error(kind)
		if kind == "WouldBlock" then kind = "TimedOut" end
		if STREAM_ERROR_KINDS[kind] then return "ErrorKind::" .. kind end
		return kind
	end
	-- deadline_from_timeout: a zero timeout has already expired.
	local function deadline_of(timeout)
		timeout = tonumber(timeout)
		if timeout == 0 then return nil, "TimedOut" end
		return now_ms() + timeout
	end
	-- Wait until fd is ready for `events` or the deadline passes.
	local function wait_fd(fd, events, deadline)
		local pfd = ffi.new("struct pollfd[1]")
		pfd[0].fd, pfd[0].events = fd, events
		while true do
			local remaining = deadline - now_ms()
			if remaining <= 0 then return nil, "TimedOut" end
			local n = C.poll(pfd, 1, math.ceil(remaining))
			if n > 0 then return true end
			if n < 0 and ffi.errno() ~= EINTR then return nil, kind_of(ffi.errno()) end
		end
	end

	-- glibc's asynchronous getaddrinfo: in libc since glibc 2.34, in libanl
	-- before that (looked up in that order, on first use).
	local GAI_NOWAIT, EAI_INPROGRESS = 1, -100
	local gai
	local function gai_lib()
		if not gai then
			gai = pcall(function() return C.getaddrinfo_a end) and C or ffi.load("libanl.so.1")
		end
		return gai
	end
	-- Lookups still running when their deadline passed and that could not be
	-- cancelled: glibc writes their results later, so their request blocks
	-- stay referenced (basic-cli likewise leaves its resolver thread running).
	local abandoned = {}
	-- getaddrinfo bounded by the deadline, as basic-cli's resolve_with_deadline
	-- bounds its resolver thread: TimedOut when no answer came in time.
	-- Returns the addrinfo list (for freeaddrinfo) or nil and an error kind.
	local function lookup(host, hints, deadline)
		local lib = gai_lib()
		local name = ffi.new("char[?]", #host + 1, host)
		local req = ffi.new("struct gaicb")
		req.ar_name, req.ar_request = name, hints
		local list = ffi.new("struct gaicb *[1]", { req })
		-- A failed lookup is std's Uncategorized error ("failed to lookup
		-- address information").
		if lib.getaddrinfo_a(GAI_NOWAIT, list, 1, nil) ~= 0 then return nil, "Uncategorized" end
		local ts = ffi.new("struct timespec")
		while true do
			local state = lib.gai_error(req)
			if state == 0 then return req.ar_result end
			if state ~= EAI_INPROGRESS then return nil, "Uncategorized" end
			local remaining = deadline - now_ms()
			if remaining <= 0 then
				lib.gai_cancel(req)
				if lib.gai_error(req) == EAI_INPROGRESS then
					abandoned[#abandoned + 1] = { req, name, hints, list }
				elseif req.ar_result ~= nil then
					C.freeaddrinfo(req.ar_result)
				end
				return nil, "TimedOut"
			end
			ts.tv_sec = math.floor(remaining / 1000)
			ts.tv_nsec = math.floor(remaining % 1000 * 1000000)
			-- Its status is not trusted: glibc 2.42 returns EAI_SYSTEM (errno 0)
			-- when the timeout expires, not the documented EAI_AGAIN. The
			-- request's own state and the deadline decide.
			lib.gai_suspend(ffi.cast("const struct gaicb *const *", list), 1, ts)
		end
	end

	-- Socket addresses for host and port: an IP literal as itself, else a
	-- deadline-bounded getaddrinfo with std's hints (any family, stream
	-- sockets), in its order.
	local function resolve(host, port, deadline)
		local addresses = {}
		local function add(family, raw)
			local sa
			if family == AF_INET then
				sa = ffi.new("struct sockaddr_in")
				ffi.copy(sa.sin_addr, raw, 4)
				sa.sin_family = AF_INET
				sa.sin_port = bit.bor(bit.lshift(bit.band(port, 0xff), 8), bit.rshift(port, 8))
			else
				sa = ffi.new("struct sockaddr_in6")
				ffi.copy(sa.sin6_addr, raw, 16)
				sa.sin6_family = AF_INET6
				sa.sin6_port = bit.bor(bit.lshift(bit.band(port, 0xff), 8), bit.rshift(port, 8))
			end
			addresses[#addresses + 1] = { family = family, sa = sa, len = ffi.sizeof(sa) }
		end
		local raw = ffi.new("uint8_t[16]")
		if C.inet_pton(AF_INET, host, raw) == 1 then
			add(AF_INET, raw)
			return addresses
		end
		if C.inet_pton(AF_INET6, host, raw) == 1 then
			add(AF_INET6, raw)
			return addresses
		end
		if has_nul(host) then return nil, "InvalidInput" end
		local hints = ffi.new("struct addrinfo")
		hints.ai_socktype = SOCK_STREAM
		local first, e = lookup(host, hints, deadline)
		if not first then return nil, e end
		local ai = first
		while ai ~= nil do
			if ai.ai_family == AF_INET then
				add(AF_INET, ffi.cast("struct sockaddr_in *", ai.ai_addr).sin_addr)
			elseif ai.ai_family == AF_INET6 then
				add(AF_INET6, ffi.cast("struct sockaddr_in6 *", ai.ai_addr).sin6_addr)
			end
			ai = ai.ai_next
		end
		C.freeaddrinfo(first)
		return addresses
	end

	-- TcpStream::connect_timeout: a non-blocking connect, then poll for
	-- writability and read SO_ERROR.
	local function connect_one(address, deadline)
		local fd = C.socket(address.family, bit.bor(SOCK_STREAM, O_CLOEXEC, SOCK_NONBLOCK), 0)
		if fd < 0 then return nil, kind_of(ffi.errno()) end
		if C.connect(fd, ffi.cast("struct sockaddr *", address.sa), address.len) ~= 0 then
			local errno = ffi.errno()
			if errno ~= EINPROGRESS then
				C.close(fd)
				return nil, kind_of(errno)
			end
			local ready, e = wait_fd(fd, POLLOUT, deadline)
			if not ready then
				C.close(fd)
				return nil, e
			end
			local soerr, len = ffi.new("int[1]"), ffi.new("socklen_t[1]", 4)
			C.getsockopt(fd, SOL_SOCKET, SO_ERROR, soerr, len)
			if soerr[0] ~= 0 then
				C.close(fd)
				return nil, kind_of(soerr[0])
			end
		end
		return fd
	end

	-- Stream state: the socket and BufReader's buffer.
	local streams, next_stream = {}, 1
	local function box_stream(fd)
		local id = next_stream
		next_stream = next_stream + 1
		streams[id] = { fd = fd, buf = "", pos = 1 }
		-- Freeing the last reference closes the socket.
		return { rc = 1, v = id, drop = function(k)
			C.close(streams[k].fd)
			streams[k] = nil
		end }
	end
	local recv_chunk = ffi.new("uint8_t[?]", TCP_BUFFER)
	-- One recv of up to max bytes once readable: the bytes ("" at end of
	-- file) or nil and an error kind.
	local function recv_some(fd, max, deadline)
		while true do
			local ready, e = wait_fd(fd, POLLIN, deadline)
			if not ready then return nil, e end
			local n = tonumber(C.recv(fd, recv_chunk, max, 0))
			if n >= 0 then return ffi.string(recv_chunk, n) end
			local errno = ffi.errno()
			if errno ~= EAGAIN and errno ~= EINTR then return nil, kind_of(errno) end
		end
	end
	-- BufReader::fill_buf: the buffered bytes, refilled by one recv when empty.
	local function fill(s, deadline)
		if s.pos > #s.buf then
			local bytes, e = recv_some(s.fd, TCP_BUFFER, deadline)
			if not bytes then return nil, e end
			s.buf, s.pos = bytes, 1
		end
		return true
	end
	local function consume(s, n)
		local bytes = s.buf:sub(s.pos, s.pos + n - 1)
		s.pos = s.pos + n
		return bytes
	end
	local function with_stream(handle, f)
		local result = f(streams[handle.v])
		rt.box_decref(handle, nil)
		return result
	end
	local function read_result(bytes, kind)
		if bytes then return ok(rt.str_to_utf8(bytes)) end
		return err(kind)
	end

	-- Try(TcpStream, Str).
	function hosted.hosted_tcp_connect(host, port, timeout)
		local deadline, e = deadline_of(timeout)
		if not deadline then return err(connect_error(e)) end
		local addresses, e2 = resolve(host, tonumber(port), deadline)
		if not addresses then return err(connect_error(e2)) end
		local last = "AddrNotAvailable" -- "hostname resolved to no TCP addresses"
		for _, address in ipairs(addresses) do
			if deadline - now_ms() <= 0 then return err(connect_error("TimedOut")) end
			local fd, e3 = connect_one(address, deadline)
			if fd then return ok(box_stream(fd)) end
			last = e3
		end
		return err(connect_error(last))
	end
	-- Try(List(U8), Str): what one buffer fill provides, at most count bytes.
	function hosted.hosted_tcp_read_up_to(handle, count, timeout)
		return with_stream(handle, function(s)
			local deadline, e = deadline_of(timeout)
			if not deadline then return err(stream_error(e)) end
			count = tonumber(count)
			if count == 0 then return ok(rt.str_to_utf8("")) end
			local filled, e2 = fill(s, deadline)
			if not filled then return err(stream_error(e2)) end
			return ok(rt.str_to_utf8(consume(s, math.min(count, #s.buf - s.pos + 1))))
		end)
	end
	-- Try(List(U8), Str): exactly count bytes, or "UnexpectedEof". Reads
	-- go through the buffer, or straight to the socket for a full-sized
	-- chunk when it is empty (BufReader::read).
	function hosted.hosted_tcp_read_exactly(handle, count, timeout)
		return with_stream(handle, function(s)
			local deadline, e = deadline_of(timeout)
			if not deadline then return err(stream_error(e)) end
			count = tonumber(count)
			local parts, got = {}, 0
			while got < count do
				local want = math.min(count - got, TCP_BUFFER)
				local bytes
				if s.pos > #s.buf and want >= TCP_BUFFER then
					local e2
					bytes, e2 = recv_some(s.fd, want, deadline)
					if not bytes then return err(stream_error(e2)) end
				else
					local filled, e2 = fill(s, deadline)
					if not filled then return err(stream_error(e2)) end
					bytes = consume(s, math.min(want, #s.buf - s.pos + 1))
				end
				if #bytes == 0 then return err("UnexpectedEof") end
				parts[#parts + 1] = bytes
				got = got + #bytes
			end
			return ok(rt.str_to_utf8(table.concat(parts)))
		end)
	end
	-- Try(List(U8), Str): through the delimiter (included), at most
	-- max_bytes, else "LimitExceeded"; whatever arrived before end of file.
	function hosted.hosted_tcp_read_until(handle, delim, max_bytes, timeout)
		return with_stream(handle, function(s)
			local deadline, e = deadline_of(timeout)
			if not deadline then return err(stream_error(e)) end
			local limit = tonumber(max_bytes)
			local byte = string.char(tonumber(delim))
			local parts, got = {}, 0
			while true do
				if got >= limit then return err("LimitExceeded") end
				local filled, e2 = fill(s, deadline)
				if not filled then return err(stream_error(e2)) end
				local available = #s.buf - s.pos + 1
				local allowed = math.min(limit - got, available)
				local at = s.buf:find(byte, s.pos, true)
				if at and at < s.pos + allowed then
					parts[#parts + 1] = consume(s, at - s.pos + 1)
					return ok(rt.str_to_utf8(table.concat(parts)))
				end
				parts[#parts + 1] = consume(s, allowed)
				got = got + allowed
				if allowed < available then return err("LimitExceeded") end
				if allowed == 0 then return ok(rt.str_to_utf8(table.concat(parts))) end
			end
		end)
	end
	-- Try({}, Str): every byte before the deadline.
	function hosted.hosted_tcp_write(handle, l, timeout)
		local bytes = rt.list_bytes(l)
		rt.L.decref(l, nil)
		return with_stream(handle, function(s)
			local deadline, e = deadline_of(timeout)
			if not deadline then return err(stream_error(e)) end
			local ptr, off = ffi.cast("const uint8_t *", bytes), 0
			while off < #bytes do
				local ready, e2 = wait_fd(s.fd, POLLOUT, deadline)
				if not ready then return err(stream_error(e2)) end
				local n = tonumber(C.send(s.fd, ptr + off, #bytes - off, MSG_NOSIGNAL))
				if n > 0 then
					off = off + n
				elseif n == 0 then
					return err(stream_error("WriteZero"))
				else
					local errno = ffi.errno()
					if errno ~= EAGAIN and errno ~= EINTR then return err(stream_error(kind_of(errno))) end
				end
			end
			return ok(ZST)
		end)
	end

	-- Listeners: a socket bound and listening (socket2: no SO_REUSEADDR),
	-- or closed.
	local listeners, next_listener = {}, 1
	local function listener_error(kind)
		if kind == "ListenerClosed" then return "ListenerClosed" end
		return connect_error(kind)
	end
	local function with_listener(handle, f)
		local result = f(listeners[handle.v])
		rt.box_decref(handle, nil)
		return result
	end
	-- Try(TcpListener, Str).
	function hosted.hosted_tcp_listen(host, port, timeout)
		local deadline, e = deadline_of(timeout)
		if not deadline then return err(listener_error(e)) end
		local addresses, e2 = resolve(host, tonumber(port), deadline)
		if not addresses then return err(listener_error(e2)) end
		local last = "AddrNotAvailable"
		for _, address in ipairs(addresses) do
			if deadline - now_ms() <= 0 then return err(listener_error("TimedOut")) end
			local fd = C.socket(address.family, bit.bor(SOCK_STREAM, O_CLOEXEC, SOCK_NONBLOCK), 0)
			if fd < 0 then
				last = kind_of(ffi.errno())
			elseif C.bind(fd, ffi.cast("struct sockaddr *", address.sa), address.len) ~= 0
				or C.listen(fd, LISTEN_BACKLOG) ~= 0 then
				last = kind_of(ffi.errno())
				C.close(fd)
			else
				local id = next_listener
				next_listener = next_listener + 1
				listeners[id] = { fd = fd }
				return ok({ rc = 1, v = id, drop = function(k)
					close_fd(listeners[k].fd)
					listeners[k] = nil
				end })
			end
		end
		return err(listener_error(last))
	end
	-- Try(U16, Str).
	function hosted.hosted_tcp_local_port(handle)
		return with_listener(handle, function(l)
			if not l.fd then return err("ListenerClosed") end
			local sa, len = ffi.new("struct sockaddr_storage"), ffi.new("socklen_t[1]", ffi.sizeof("struct sockaddr_storage"))
			if C.getsockname(l.fd, ffi.cast("struct sockaddr *", sa), len) ~= 0 then
				return err(listener_error(kind_of(ffi.errno())))
			end
			local p = ffi.cast("struct sockaddr_in *", sa).sin_port -- same offset in sockaddr_in6
			return ok(bit.bor(bit.lshift(bit.band(p, 0xff), 8), bit.rshift(p, 8)))
		end)
	end
	-- Try(TcpStream, Str).
	function hosted.hosted_tcp_accept(handle, timeout)
		return with_listener(handle, function(l)
			local deadline, e = deadline_of(timeout)
			if not deadline then return err(listener_error(e)) end
			if not l.fd then return err("ListenerClosed") end
			while true do
				local ready, e2 = wait_fd(l.fd, POLLIN, deadline)
				if not ready then return err(listener_error(e2)) end
				local fd = C.accept4(l.fd, nil, nil, bit.bor(O_CLOEXEC, SOCK_NONBLOCK))
				if fd >= 0 then return ok(box_stream(fd)) end
				local errno = ffi.errno()
				if errno ~= EAGAIN and errno ~= EINTR then return err(listener_error(kind_of(errno))) end
			end
		end)
	end
	-- Try({}, Str): closes the socket; later uses report ListenerClosed.
	function hosted.hosted_tcp_listener_close(handle)
		return with_listener(handle, function(l)
			close_fd(l.fd)
			l.fd = nil
			return ok(ZST)
		end)
	end

	-- HTTP ---------------------------------------------------------------------
	-- A port of basic-cli's http.rs (hyper 1, HTTP/1.1 only, no proxy, no
	-- redirects) over libcurl through the FFI, loaded on first use:
	-- $ROC_LUAJIT_LIBCURL (the project flake sets it), else the system's
	-- libcurl. curl is configured to put on the wire what hyper does: the
	-- caller's headers plus `Content-Type: text/plain` when none is given, no
	-- default Accept or Expect header, no body (and no Content-Length) when the
	-- body is empty. Response header names come back lowercase, grouped by name
	-- in first-seen order (hyper's HeaderMap iteration), and a value that is not
	-- visible ASCII reads as "" (HeaderValue::to_str, unwrap_or_default).
	-- Differences: curl trusts the system's CA store where basic-cli bundles
	-- webpki roots, and failures map to hyper's messages by phase ("client
	-- error (Connect)" before a connection exists, "client error
	-- (SendRequest)" after) rather than hyper's exact error.
	local curl
	local CURL = {
		URL = 10002, HTTPHEADER = 10023, CUSTOMREQUEST = 10036, POSTFIELDS = 10015, PROXY = 10004,
		POSTFIELDSIZE_LARGE = 30120, WRITEFUNCTION = 20011, HEADERFUNCTION = 20079,
		TIMEOUT_MS = 155, NOSIGNAL = 99, HTTP_VERSION = 84, HTTP_VERSION_1_1 = 2, NOBODY = 44, HTTPGET = 80,
		INFO_RESPONSE_CODE = 0x200002, OPERATION_TIMEDOUT = 28,
		-- Codes for failures before a connection exists (resolve, connect, TLS).
		CONNECT_PHASE = { [5] = true, [6] = true, [7] = true, [35] = true, [51] = true, [53] = true, [54] = true,
			[58] = true, [59] = true, [60] = true, [66] = true, [77] = true, [80] = true, [83] = true, [90] = true, [91] = true },
	}
	local curl_sink -- { body = {...}, lines = {...}, done_head = bool } of the request in flight
	local curl_write, curl_header
	local function curl_lib()
		if curl then return curl end
		ffi.cdef([[
			typedef void CURL;
			struct curl_slist;
			CURL *curl_easy_init(void);
			void curl_easy_cleanup(CURL *handle);
			int curl_easy_setopt(CURL *handle, int option, ...);
			int curl_easy_perform(CURL *handle);
			int curl_easy_getinfo(CURL *handle, int info, ...);
			struct curl_slist *curl_slist_append(struct curl_slist *list, const char *string);
			void curl_slist_free_all(struct curl_slist *list);
		]])
		local candidates = {}
		local configured = os.getenv("ROC_LUAJIT_LIBCURL")
		if configured and configured ~= "" then candidates[1] = configured end
		candidates[#candidates + 1] = "libcurl.so.4"
		candidates[#candidates + 1] = "curl"
		for _, name in ipairs(candidates) do
			local loaded, lib = pcall(ffi.load, name)
			if loaded then
				curl = lib
				break
			end
		end
		if not curl then error("roc_luajit: the basic-cli LuaJIT host needs libcurl for Http; set ROC_LUAJIT_LIBCURL to its path", 0) end
		curl_write = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", function(data, size, n)
			local bytes = tonumber(size * n)
			local body = curl_sink.body
			body[#body + 1] = ffi.string(data, bytes)
			return bytes
		end)
		curl_header = ffi.cast("size_t (*)(char *, size_t, size_t, void *)", function(data, size, n)
			local bytes = tonumber(size * n)
			local line = ffi.string(data, bytes):gsub("\r?\n$", "")
			if line:match("^HTTP/%d") then
				curl_sink.lines, curl_sink.done_head = {}, false -- a new response (after 1xx)
			elseif line == "" then
				curl_sink.done_head = true
			else
				local lines = curl_sink.lines
				lines[#lines + 1] = line
			end
			return bytes
		end)
		return curl
	end

	-- RFC 9110 token characters (hyper's method and header-name check).
	local function is_token(s)
		return #s > 0 and not s:find("[^%w!#$%%&'*+%-.^_`|~]")
	end
	local HTTP_METHODS = { [0] = "CONNECT", "DELETE", false, "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE" }
	local function visible_ascii(v) return not v:find("[^\t\32-\126]") end
	-- Response header lines -> { {name, value} ... } in hyper's iteration order.
	local function response_headers(lines)
		local order, values = {}, {}
		for _, line in ipairs(lines) do
			local name, value = line:match("^([^:]+):[ \t]*(.-)[ \t]*$")
			if name then
				name = name:lower()
				if not values[name] then
					values[name] = {}
					order[#order + 1] = name
				end
				local list = values[name]
				list[#list + 1] = visible_ascii(value) and value or ""
			end
		end
		local items = {}
		for _, name in ipairs(order) do
			for _, value in ipairs(values[name]) do items[#items + 1] = { name, value } end
		end
		return items
	end
	-- InternalHttp.TransportErr [BadBody, NetworkError, Other(List(U8)), Timeout].
	local function http_other(message) return err({ 2, rt.str_to_utf8(message) }) end

	-- Try(ResponseToAndFromHost, TransportErr) for RequestToAndFromHost
	-- { body, headers, method, method_ext, timeout_ms, uri }.
	function hosted.hosted_http_send_request(request)
		local body, header_list, method_tag, method_ext, timeout_ms, uri = request[1], request[2], request[3], request[4], request[5], request[6]
		local method = HTTP_METHODS[tonumber(method_tag)]
		if method == false then method = is_token(method_ext) and method_ext or nil end
		if not method then return http_other("invalid HTTP method") end
		local headers, has = {}, {}
		for k = 0, header_list[3] - 1 do
			local h = rt.L.get_unsafe(header_list, k)
			local name, value = h[1], h[2]
			if not is_token(name) then return http_other("invalid HTTP header name") end
			if value:find("[%z\1-\8\10-\31\127]") then return http_other("failed to parse header value") end
			has[name:lower()] = true
			headers[#headers + 1] = value == "" and (name .. ";") or (name .. ": " .. value)
		end
		if not has["content-type"] then headers[#headers + 1] = "Content-Type: text/plain" end
		if not has["accept"] then headers[#headers + 1] = "Accept:" end
		if not has["expect"] then headers[#headers + 1] = "Expect:" end

		local lib = curl_lib()
		local handle = lib.curl_easy_init()
		if handle == nil then return http_other("client error (Connect)") end
		local slist = nil
		for _, line in ipairs(headers) do slist = lib.curl_slist_append(slist, line) end
		local payload = rt.list_bytes(body)
		local long = function(v) return ffi.cast("long", v) end
		lib.curl_easy_setopt(handle, CURL.URL, uri)
		lib.curl_easy_setopt(handle, CURL.PROXY, "")
		lib.curl_easy_setopt(handle, CURL.NOSIGNAL, long(1))
		lib.curl_easy_setopt(handle, CURL.HTTP_VERSION, long(CURL.HTTP_VERSION_1_1))
		lib.curl_easy_setopt(handle, CURL.HTTPHEADER, slist)
		lib.curl_easy_setopt(handle, CURL.WRITEFUNCTION, curl_write)
		lib.curl_easy_setopt(handle, CURL.HEADERFUNCTION, curl_header)
		if method == "HEAD" then
			lib.curl_easy_setopt(handle, CURL.NOBODY, long(1))
		elseif method == "GET" and #payload == 0 then
			lib.curl_easy_setopt(handle, CURL.HTTPGET, long(1))
		else
			lib.curl_easy_setopt(handle, CURL.CUSTOMREQUEST, method)
			if #payload > 0 then
				lib.curl_easy_setopt(handle, CURL.POSTFIELDSIZE_LARGE, ffi.cast("int64_t", #payload))
				lib.curl_easy_setopt(handle, CURL.POSTFIELDS, payload)
			end
		end
		local timeout = tonumber(timeout_ms)
		if timeout > 0 then lib.curl_easy_setopt(handle, CURL.TIMEOUT_MS, long(timeout)) end

		curl_sink = { body = {}, lines = {}, done_head = false }
		local rc = lib.curl_easy_perform(handle)
		local sink = curl_sink
		curl_sink = nil
		local code = ffi.new("long[1]")
		lib.curl_easy_getinfo(handle, CURL.INFO_RESPONSE_CODE, code)
		lib.curl_easy_cleanup(handle)
		lib.curl_slist_free_all(slist)
		if rc ~= 0 then
			if rc == CURL.OPERATION_TIMEDOUT and timeout > 0 then return err({ 3, ZST }) end
			if sink.done_head then return err({ 0, ZST }) end -- the body failed after the head
			return http_other(CURL.CONNECT_PHASE[rc] and "client error (Connect)" or "client error (SendRequest)")
		end
		local items = response_headers(sink.lines)
		return ok({ rt.str_to_utf8(table.concat(sink.body)), list_of(items, 48), tonumber(code[0]) })
	end

	-- SQLite -------------------------------------------------------------------
	-- A port of basic-cli's sqlite.rs over libsqlite3 through the FFI, loaded
	-- on first use: $ROC_LUAJIT_LIBSQLITE3 (the project flake sets it), else
	-- the system's libsqlite3. Connections are cached per path like the Rust
	-- host's ConnectionCache: `:memory:` stays pinned, at most 16 other idle
	-- connections stay open (least recently used evicted), and a statement
	-- keeps its connection alive. Text columns decode lossily as Roc's
	-- Str.from_utf8_lossy does (the Rust host uses String::from_utf8_lossy).
	local sqlite
	local function sqlite_lib()
		if sqlite then return sqlite end
		ffi.cdef([[
			typedef struct sqlite3 sqlite3;
			typedef struct sqlite3_stmt sqlite3_stmt;
			int sqlite3_open_v2(const char *filename, sqlite3 **db, int flags, const char *vfs);
			int sqlite3_close_v2(sqlite3 *db);
			const char *sqlite3_errstr(int code);
			const char *sqlite3_errmsg(sqlite3 *db);
			int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int bytes, sqlite3_stmt **stmt, const char **tail);
			int sqlite3_finalize(sqlite3_stmt *stmt);
			int sqlite3_clear_bindings(sqlite3_stmt *stmt);
			int sqlite3_bind_parameter_index(sqlite3_stmt *stmt, const char *name);
			int sqlite3_bind_int64(sqlite3_stmt *stmt, int index, int64_t value);
			int sqlite3_bind_double(sqlite3_stmt *stmt, int index, double value);
			int sqlite3_bind_text64(sqlite3_stmt *stmt, int index, const char *text, uint64_t bytes, void (*destructor)(void *), unsigned char encoding);
			int sqlite3_bind_blob64(sqlite3_stmt *stmt, int index, const void *blob, uint64_t bytes, void (*destructor)(void *));
			int sqlite3_bind_null(sqlite3_stmt *stmt, int index);
			int sqlite3_column_count(sqlite3_stmt *stmt);
			const char *sqlite3_column_name(sqlite3_stmt *stmt, int column);
			int sqlite3_column_type(sqlite3_stmt *stmt, int column);
			int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int column);
			double sqlite3_column_double(sqlite3_stmt *stmt, int column);
			const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int column);
			const void *sqlite3_column_blob(sqlite3_stmt *stmt, int column);
			int sqlite3_column_bytes(sqlite3_stmt *stmt, int column);
			int sqlite3_step(sqlite3_stmt *stmt);
			int sqlite3_reset(sqlite3_stmt *stmt);
		]])
		local candidates = {}
		local configured = os.getenv("ROC_LUAJIT_LIBSQLITE3")
		if configured and configured ~= "" then candidates[1] = configured end
		candidates[#candidates + 1] = "libsqlite3.so.0"
		candidates[#candidates + 1] = "sqlite3"
		for _, name in ipairs(candidates) do
			local loaded, lib = pcall(ffi.load, name)
			if loaded then
				sqlite = lib
				return sqlite
			end
		end
		error("roc_luajit: the basic-cli LuaJIT host needs libsqlite3 for Sqlite; set ROC_LUAJIT_LIBSQLITE3 to its path", 0)
	end
	local SQLITE = {
		OK = 0, ERROR = 1, CANTOPEN = 14, ROW = 100, DONE = 101,
		INTEGER = 1, FLOAT = 2, TEXT = 3, BLOB = 4,
		OPEN_FLAGS = 0x2 + 0x4 + 0x8000, -- READWRITE | CREATE | NOMUTEX
		UTF8 = 1, MAX_CACHED = 16,
	}
	local SQLITE_TRANSIENT = ffi.cast("void (*)(void *)", -1)
	-- SqliteValue [Bytes(List(U8)), Integer(I64), Null, Real(F64), String(Str)].
	local VALUE_BYTES, VALUE_INTEGER, VALUE_NULL, VALUE_REAL, VALUE_STRING = 0, 1, 2, 3, 4

	-- SqliteError { code : I64, message : Str } as an Err.
	local function sqlite_err(code, message) return err({ code, message }) end
	local function errmsg(db, code)
		local lib = sqlite_lib()
		local message = ffi.string(lib.sqlite3_errstr(code))
		if db ~= nil then
			local detailed = lib.sqlite3_errmsg(db)
			if detailed ~= nil then message = ffi.string(detailed) end
		end
		return message
	end

	-- The connection cache: path -> { db, statements, kept, last_used }.
	local connections, clock = {}, 0
	local function close_if_unused(path)
		local c = connections[path]
		if c and not c.kept and c.statements == 0 then
			sqlite_lib().sqlite3_close_v2(c.db)
			connections[path] = nil
		end
	end
	local function evict()
		while true do
			local count, oldest = 0, nil
			for path, c in pairs(connections) do
				if path ~= ":memory:" and c.kept then
					count = count + 1
					if not oldest or c.last_used < connections[oldest].last_used then oldest = path end
				end
			end
			if count <= SQLITE.MAX_CACHED then return end
			connections[oldest].kept = false
			close_if_unused(oldest)
		end
	end
	local function connection(path)
		clock = clock + 1
		local c = connections[path]
		if not c then
			local lib = sqlite_lib()
			local out = ffi.new("sqlite3 *[1]")
			local code = lib.sqlite3_open_v2(path, out, SQLITE.OPEN_FLAGS, nil)
			if code ~= SQLITE.OK then
				local message = errmsg(out[0], code)
				if out[0] ~= nil then lib.sqlite3_close_v2(out[0]) end
				return nil, code, message
			end
			c = { db = out[0], statements = 0 }
			connections[path] = c
		end
		c.kept, c.last_used = true, clock
		evict()
		return c
	end

	local statements, next_statement = {}, 1
	local function with_statement(handle, f)
		local result = f(statements[handle.v])
		rt.box_decref(handle, nil)
		return result
	end
	local function statement_error(s, code) return sqlite_err(code, errmsg(connections[s.path].db, code)) end

	-- Try(SqliteStmt, SqliteError).
	function hosted.hosted_sqlite_prepare(path_value, query)
		local path = native_bytes(path_value)
		if path == nil then
			return sqlite_err(SQLITE.CANTOPEN, "Windows database paths are not supported on this host")
		end
		release_native(path_value)
		if has_nul(path) then return sqlite_err(SQLITE.ERROR, "database path contained an interior nul byte") end
		local c, code, message = connection(path)
		if not c then return sqlite_err(code, message) end
		local lib = sqlite_lib()
		local out = ffi.new("sqlite3_stmt *[1]")
		local rc = lib.sqlite3_prepare_v2(c.db, query, #query, out, nil)
		if rc ~= SQLITE.OK then
			local msg = errmsg(c.db, rc)
			if out[0] ~= nil then lib.sqlite3_finalize(out[0]) end
			return sqlite_err(rc, msg)
		end
		c.statements = c.statements + 1
		local id = next_statement
		next_statement = next_statement + 1
		statements[id] = { stmt = out[0], path = path }
		-- Freeing the last reference finalizes the statement.
		return ok({ rc = 1, v = id, drop = function(k)
			local s = statements[k]
			lib.sqlite3_finalize(s.stmt)
			statements[k] = nil
			local owner = connections[s.path]
			owner.statements = owner.statements - 1
			close_if_unused(s.path)
		end })
	end
	-- Try({}, SqliteError): clears old bindings, then binds each { name, value }.
	function hosted.hosted_sqlite_bind(handle, bindings)
		return with_statement(handle, function(s)
			local lib = sqlite_lib()
			local cleared = lib.sqlite3_clear_bindings(s.stmt)
			if cleared ~= SQLITE.OK then return statement_error(s, cleared) end
			for k = 0, bindings[3] - 1 do
				local binding = rt.L.get_unsafe(bindings, k)
				local name, value = binding[1], binding[2]
				if has_nul(name) then
					rt.L.decref(bindings, nil)
					return sqlite_err(SQLITE.ERROR, "binding name contained an interior nul byte")
				end
				local index = lib.sqlite3_bind_parameter_index(s.stmt, name)
				if index == 0 then
					rt.L.decref(bindings, nil)
					return sqlite_err(SQLITE.ERROR, "unknown parameter: " .. name)
				end
				local tag, payload, rc = value[1], value[2], nil
				if tag == VALUE_INTEGER then
					rc = lib.sqlite3_bind_int64(s.stmt, index, payload)
				elseif tag == VALUE_REAL then
					rc = lib.sqlite3_bind_double(s.stmt, index, payload)
				elseif tag == VALUE_STRING then
					rc = lib.sqlite3_bind_text64(s.stmt, index, payload, #payload, SQLITE_TRANSIENT, SQLITE.UTF8)
				elseif tag == VALUE_BYTES then
					local bytes = rt.list_bytes(payload)
					rc = lib.sqlite3_bind_blob64(s.stmt, index, bytes, #bytes, SQLITE_TRANSIENT)
				else
					rc = lib.sqlite3_bind_null(s.stmt, index)
				end
				if rc ~= SQLITE.OK then
					rt.L.decref(bindings, nil)
					return statement_error(s, rc)
				end
			end
			-- Only the list reference is released: Roc keeps the fields it owns.
			rt.L.decref(bindings, nil)
			return ok(ZST)
		end)
	end
	-- List(Str).
	function hosted.hosted_sqlite_columns(handle)
		return with_statement(handle, function(s)
			local lib = sqlite_lib()
			local names = {}
			for i = 0, math.max(lib.sqlite3_column_count(s.stmt), 0) - 1 do
				local raw = lib.sqlite3_column_name(s.stmt, i)
				names[#names + 1] = raw == nil and "" or rt.str_from_utf8_lossy(rt.str_to_utf8(ffi.string(raw)))
			end
			return (list_of(names, STR_WIDTH))
		end)
	end
	-- Try(SqliteValue, SqliteError).
	function hosted.hosted_sqlite_column_value(handle, column)
		return with_statement(handle, function(s)
			local lib = sqlite_lib()
			local count = math.max(lib.sqlite3_column_count(s.stmt), 0)
			local i = tonumber(column)
			if i >= count then
				return sqlite_err(SQLITE.ERROR, ("column index out of range: %d of %d"):format(i, count))
			end
			local kind = lib.sqlite3_column_type(s.stmt, i)
			if kind == SQLITE.INTEGER then
				return ok({ VALUE_INTEGER, rt.norm_i64(lib.sqlite3_column_int64(s.stmt, i)) })
			elseif kind == SQLITE.FLOAT then
				return ok({ VALUE_REAL, lib.sqlite3_column_double(s.stmt, i) })
			elseif kind == SQLITE.TEXT then
				local text = lib.sqlite3_column_text(s.stmt, i)
				local bytes = text == nil and "" or ffi.string(text, math.max(lib.sqlite3_column_bytes(s.stmt, i), 0))
				return ok({ VALUE_STRING, rt.str_from_utf8_lossy(rt.str_to_utf8(bytes)) })
			elseif kind == SQLITE.BLOB then
				local blob = lib.sqlite3_column_blob(s.stmt, i)
				local bytes = blob == nil and "" or ffi.string(blob, math.max(lib.sqlite3_column_bytes(s.stmt, i), 0))
				return ok({ VALUE_BYTES, rt.str_to_utf8(bytes) })
			end
			return ok({ VALUE_NULL, ZST })
		end)
	end
	-- Try(Bool, SqliteError): true for a row, false when done.
	function hosted.hosted_sqlite_step(handle)
		return with_statement(handle, function(s)
			local rc = sqlite_lib().sqlite3_step(s.stmt)
			if rc == SQLITE.ROW then return ok(true) end
			if rc == SQLITE.DONE then return ok(false) end
			return statement_error(s, rc)
		end)
	end
	-- Try({}, SqliteError).
	function hosted.hosted_sqlite_reset(handle)
		return with_statement(handle, function(s)
			local rc = sqlite_lib().sqlite3_reset(s.stmt)
			if rc == SQLITE.OK then return ok(ZST) end
			return statement_error(s, rc)
		end)
	end

	-- crossterm's raw mode on the controlling terminal: stdin when it is a
	-- terminal, else /dev/tty; the original settings are restored on disable.
	local saved_termios, tty_fd
	function hosted.hosted_tty_enable_raw_mode()
		if saved_termios then return ZST end
		local fd = C.isatty(0) == 1 and 0 or C.open("/dev/tty", 2)
		if fd < 0 then return ZST end
		local original = ffi.new("uint8_t[?]", TERMIOS_BYTES)
		if C.tcgetattr(fd, original) ~= 0 then return ZST end
		local raw_mode = ffi.new("uint8_t[?]", TERMIOS_BYTES)
		ffi.copy(raw_mode, original, TERMIOS_BYTES)
		C.cfmakeraw(raw_mode)
		if C.tcsetattr(fd, 0, raw_mode) == 0 then saved_termios, tty_fd = original, fd end
		return ZST
	end
	function hosted.hosted_tty_disable_raw_mode()
		if saved_termios then
			C.tcsetattr(tty_fd, 0, saved_termios)
			saved_termios = nil
		end
		return ZST
	end

	local program = app(hosted)
	rt = program.rt
	ZST = rt.ZST
	-- roc_dbg / roc_expect_failed print and make a successful exit status 1.
	local debug_or_expect = false
	rt.on_dbg = function(message)
		debug_or_expect = true
		io.stderr:write("[ROC DBG] ", message, "\n")
	end
	rt.on_expect_failed = function(message)
		debug_or_expect = true
		io.stderr:write("[ROC EXPECT] ", message, "\n")
	end

	-- main_for_host! receives the arguments after argv[0] as UnixBytes OsStrs.
	local args = {}
	for i = 1, #argv do args[i] = to_native(argv[i]) end
	local done, status, failure = rt.call_entry(program.entrypoints.roc_main, list_of(args, OS_STR_WIDTH))
	io.stdout:flush()
	if done then shutdown_children() end
	if failure == "stack_overflow" then
		io.stderr:write("[ROC CRASHED] stack overflow\n")
		os.exit(1)
	end
	if not done then
		io.stderr:write("[ROC CRASHED] ", status, "\n")
		os.exit(1)
	end
	if debug_or_expect and status == 0 then status = 1 end
	os.exit(status)
end

return M
