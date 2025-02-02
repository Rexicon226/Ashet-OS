//!
//! WARNING:
//!     THIS FILE CONTAINS A DSL THAT LOOKS LIKE ZIG BUT NEEDS TO BE
//!     PROCESSED BY `tools/abi-mapper.py` IN ORDER TO BE COMPILABLE!
//!

///////////////////////////////////////////////////////////
// Syscalls & IOPS

const syscalls = struct {
    /// All syscalls related to generic resource management.
    const resources = struct {
        /// Returns the type of the system resource.
        extern "syscall" fn get_type(SystemResource) SystemResource.Type;

        /// Returns the current owner of this resource.
        extern "syscall" fn get_owners(SystemResource, owners: ?[]Process) usize;

        /// Adds the process to the owners of this resource, so the process
        /// can safely access it without fear of having a use-after-free.
        extern "syscall" fn send_to_process(SystemResource, Process) void;

        /// Drops the ownership of the resource for the current process.
        /// If no owner remains, the resource will be destroyed and it's
        /// memory will be released.
        /// The handle must be assumed invalid for this process after
        /// this function returns.
        extern "syscall" fn release(SystemResource) void;

        /// Immediatly destroys the resource and releases its memory.
        ///
        /// NOTE: This will *always* destroy the resource, even if it's
        ///       also owned by another process.
        extern "syscall" fn destroy(SystemResource) void;
    };

    /// Syscalls related to processes
    const process = struct {
        /// Returns a pointer to the file name of the process.
        extern "syscall" fn get_file_name(?Process) [*:0]const u8;

        /// Returns the base address of the process.
        extern "syscall" fn get_base_address(?Process) usize;

        /// Returns the arguments that were passed to this process in `Spawn`.
        extern "syscall" fn get_arguments(?Process, argv: ?[]SpawnProcessArg) usize;

        /// Terminates the current process with the given exit code
        extern "syscall" fn terminate(exit_code: ExitCode) noreturn;

        /// Terminates a foreign process.
        /// If the current process is passed, this function will not return
        extern "syscall" fn kill(Process) void;

        const thread = struct {
            /// Returns control to the scheduler. Returns when the scheduler
            /// schedules the process again.
            extern "syscall" fn yield() void;

            /// Terminates the current thread.
            extern "syscall" fn exit(exit_code: ExitCode) noreturn;

            /// Waits for the thread to exit and returns its return code.
            extern "syscall" fn join(Thread) ExitCode;

            /// Spawns a new thread with `function` passing `arg` to it.
            /// If `stack_size` is not 0, will create a stack with the given size.
            extern "syscall" fn spawn(function: ThreadFunction, arg: ?*anyopaque, stack_size: usize) ?Thread;

            /// Kills the given thread with `exit_code`.
            extern "syscall" fn kill(Thread, exit_code: ExitCode) void;
        };

        const debug = struct {
            /// Writes to the system debug log.
            extern "syscall" fn write_log(log_level: LogLevel, message: []const u8) void;

            /// Stops the process and allows debugging.
            extern "syscall" fn breakpoint() void;
        };

        const memory = struct {
            /// Allocates memory
            extern "syscall" fn allocate(size: usize, ptr_align: u8) ?[*]u8;

            /// Returns memory to the systme.
            extern "syscall" fn release(mem: []u8, ptr_align: u8) void;
        };

        const monitor = struct {
            /// Queries all owned resources by a process.
            extern "syscall" fn enumerate_processes(processes: ?[]Process) usize;

            /// Queries all owned resources by a process.
            extern "syscall" fn query_owned_resources(Process, resources: ?[]*SystemResource) usize;

            /// Returns the total number of bytes the process takes up in RAM.
            extern "syscall" fn query_total_memory_usage(Process) usize;

            /// Returns the number of dynamically allocated bytes for this process.
            extern "syscall" fn query_dynamic_memory_usage(Process) usize;

            /// Returns the number of total memory objects this process has right now.
            extern "syscall" fn query_active_allocation_count(Process) usize;
        };
    };

    const clock = struct {
        /// Returns the time in nanoseconds since system startup.
        /// This clock is monotonically increasing.
        extern "syscall" fn monotonic() u64;
    };

    const time = struct {
        /// Get a calendar timestamp relative to UTC 1970-01-01.
        /// Precision of timing depends on the hardware.
        /// The return value is signed because it is possible to have a date that is
        /// before the epoch.
        extern "syscall" fn now() DateTime;
    };

    const video = struct {
        /// Returns a list of all video outputs.
        ///
        /// If `ids` is `null`, the total number of available outputs is returned,
        /// otherwise, up to `ids.len` elements are written into the provided array
        /// and the number of written elements is returned.
        extern "syscall" fn enumerate(ids: ?[]VideoOutputID) usize;

        /// Acquire exclusive access to a video output.
        extern "syscall" fn acquire(VideoOutputID) ?VideoOutput;

        /// Returns the current resolution
        extern "syscall" fn get_resolution(VideoOutput) Size;

        /// Returns a pointer to linear video memory, row-major.
        /// Pixels rows will have a stride of the current video buffer width.
        /// The first pixel in the memory is the top-left pixel.
        extern "syscall" fn get_video_memory(VideoOutput) [*]align(4) ColorIndex;

        /// Fetches a copy of the current color pallete.
        extern "syscall" fn get_palette(VideoOutput, *[palette_size]Color) void;

        /// Changes the current color palette.
        extern "syscall" fn set_palette(VideoOutput, *const [palette_size]Color) error{Unsupported};

        // /// Returns a pointer to the current palette. Changing this palette
        // /// will directly change the associated colors on the screen.
        // /// If `null` is returned, no direct access to the video palette is possible.
        //  fn get_palette_memory(*VideoOutput) ?*[palette_size]Color;

        // /// Changes the border color of the screen. Parameter is an index into
        // /// the palette.
        //  fn set_border(*VideoOutput, ColorIndex) void;

        // /// Returns the maximum possible screen resolution.
        //  fn get_max_resolution(*VideoOutput) Size;

        // /// Sets the screen resolution. Legal values are between 1×1 and the platform specific
        // /// maximum resolution returned by `video.getMaxResolution()`.
        // /// Everything out of bounds will be clamped into that range.
        //  fn change_resolution(*VideoOutput, u16, u16) void;

    };

    const network = struct {

        // getStatus: FnPtr(fn () NetworkStatus),
        // ping: FnPtr(fn ([*]Ping, usize) void),
        // TODO: Implement NIC-specific queries (mac, ips, names, ...)

        const dns = struct {
            // resolves the dns entry `host` for the given `service`.
            // - `host` is a legal dns entry
            // - `port` is either a port number
            // - `buffer` and `limit` define a structure where all resolved IPs can be stored.
            // Function returns the number of host entries found or 0 if the host name could not be resolved.
            //  fn @"resolve" (host: [*:0]const u8, port: u16, buffer: [*]EndPoint, limit: usize) usize;

        };

        const udp = struct {
            /// Creates a new UDP socket.
            extern "syscall" fn create_socket(out: *UdpSocket) error{SystemResources};
        };

        const tcp = struct {
            /// Creates a new TCP socket.
            extern "syscall" fn create_socket(out: *TcpSocket) error{SystemResources};
        };
    };

    const io = struct {
        /// Starts new I/O operations and returns completed ones.
        ///
        /// If `start_queue` is given, the kernel will schedule the events in the kernel.
        /// All events in this queue must not be freed until they are returned by this function
        /// at a later point.
        ///
        /// The function will optionally block based on the `wait` parameter.
        ///
        /// The return value is the HEAD element of a linked list of completed I/O events.
        extern "syscall" fn schedule_and_await(?*IOP, WaitIO) ?*IOP;

        /// Cancels a single I/O operation.
        extern "syscall" fn cancel(*IOP) void;
    };

    const fs = struct {
        /// Finds a file system by name
        extern "syscall" fn find_filesystem(name: []const u8) FileSystemId;
    };

    const service = struct {
        /// Registers a new service `uuid` in the system.
        /// Takes an array of function pointers that will be provided for IPC and a service name to be advertised.
        extern "syscall" fn create(svc: *Service, uuid: *const UUID, funcs: []const AbstractFunction, name: []const u8) error{
            AlreadyRegistered,
            SystemResources,
        };

        /// Enumerates all registered services.
        extern "syscall" fn enumerate(uuid: *const UUID, services: ?[]Service) usize;

        /// Returns the name of the service.
        extern "syscall" fn get_name(Service) [*:0]const u8;

        /// Returns the process that created this service.
        extern "syscall" fn get_process(Service) Process;

        /// Returns the functions registerd by the service.
        extern "syscall" fn get_functions(Service, funcs: ?[]const AbstractFunction) usize;
    };

    const draw = struct {
        // Fonts:

        /// Returns the font data for the given font name, if any.
        extern "syscall" fn get_system_font(font_name: []const u8, font: **Font) error{
            FileNotFound,
            SystemResources,
            OutOfMemory,
        };

        /// Creates a new custom font from the given data.
        extern "syscall" fn create_font(data: []const u8, font: **Font) error{
            InvalidData,
            SystemResources,
            OutOfMemory,
        };

        /// Returns true if the given font is a system-owned font.
        extern "syscall" fn is_system_font(*Font) bool;

        // Framebuffer management:

        /// Creates a new in-memory framebuffer that can be used for offscreen painting.
        extern "syscall" fn create_memory_framebuffer(size: Size) ?*Framebuffer;

        /// Creates a new framebuffer based off a video output. Can be used to output pixels
        /// to the screen.
        extern "syscall" fn create_video_framebuffer(*VideoOutput) ?*Framebuffer;

        /// Creates a new framebuffer that allows painting into a GUI window.
        extern "syscall" fn create_window_framebuffer(*Window) ?*Framebuffer;

        /// Creates a new framebuffer that allows painting into a widget.
        extern "syscall" fn create_widget_framebuffer(*Widget) ?*Framebuffer;

        /// Returns the type of a framebuffer object.
        extern "syscall" fn get_framebuffer_type(*Framebuffer) FramebufferType;

        /// Returns the size of a framebuffer object.
        extern "syscall" fn get_framebuffer_size(*Framebuffer) Size;

        /// Marks a portion of the framebuffer as changed and forces the OS to
        /// perform an update action if necessary.
        extern "syscall" fn invalidate_framebuffer(*Framebuffer, Rectangle) void;

        // Drawing:

        // TODO: fn annotate_text(*Framebuffer, area: Rectangle, text: []const u8) AnnotationError;

        // TODO: Insert render functions here
    };

    const gui = struct {
        extern "syscall" fn register_widget_type(out: *WidgetType, *const WidgetDescriptor) error{
            AlreadyRegistered,
            SystemResources,
        };

        // Window API:

        /// Spawns a new window.
        extern "syscall" fn create_window(window: *Window, desktop: Desktop, title: []const u8, min: Size, max: Size, startup: Size, flags: CreateWindowFlags) error{
            SystemResources,
            InvalidDimensions,
        };

        /// Resizes a window to the new size.
        extern "syscall" fn resize_window(Window, size: Size) void;

        /// Changes a window title.
        extern "syscall" fn set_window_title(Window, title: []const u8) void;

        /// Notifies the desktop that a window wants attention from the user.
        /// This could just pop the window to the front, make it blink, show a small notification, ...
        extern "syscall" fn mark_window_urgent(Window) void;

        // TODO: gui.app_menu

        // Widget API:

        /// Create a new widget identified by `uuid` on the given `window`.
        /// Position and size of the widget are undetermined at start and a call to `place_widget` should be performed on success.
        extern "syscall" fn create_widget(widget: *Widget, window: Window, uuid: *const UUID) error{
            SystemResources,
            WidgetNotFound,
        };

        /// Moves and resizes a widget in one.
        extern "syscall" fn place_widget(widget: Widget, position: Point, size: Size) void;

        /// Triggers the `control` event of the widget with the given `message` as a payload.
        extern "syscall" fn control_widget(widget: Widget, message: WidgetControlMessage) error{
            SystemResources,
        };

        /// Triggers the `widget_notify` event of the `Window` that owns `widget` with `event` as the payload.
        extern "syscall" fn notify_owner(widget: Widget, event: WidgetNotifyEvent) error{
            SystemResources,
        };

        /// Returns WidgetType-associated "opaque" data for this widget.
        ///
        /// This is meant as a convenience tool to store additional information per widget
        /// like internal state and such.
        ///
        /// The size of this must be known and cannot be queried.
        extern "syscall" fn get_widget_data(Widget) [*]align(16) u8;

        // Context Menu API:

        // TODO: gui.context_menu

        // Desktop Server API:

        /// Creates a new desktop with the given name.
        extern "syscall" fn create_desktop(
            desktop: *Desktop,
            /// User-visible name of the desktop.
            name: []const u8,
            descriptor: *const DesktopDescriptor,
        ) error{
            SystemResources,
        };

        // TODO: Function to get the "current"/"primary"/"associated" desktop server, how?

        /// Returns the name of the provided desktop.
        extern "syscall" fn get_desktop_name(Desktop) [*:0]const u8;

        /// Enumerates all available desktops.
        extern "syscall" fn enumerate_desktops(serverlist: ?[]Desktop) usize;

        /// Returns all windows for a desktop handle.
        extern "syscall" fn enumerate_desktop_windows(Desktop, window: ?[]Window) usize;

        /// Returns desktop-associated "opaque" data for this window.
        ///
        /// This is meant as a convenience tool to store additional information per window
        /// like position on the screen, orientation, alignment, ...
        ///
        /// The size of this must be known and cannot be queried.
        extern "syscall" fn get_desktop_data(Window) [*]align(16) u8;

        /// Notifies the system that a message box was confirmed by the user.
        ///
        /// **NOTE:** This function is meant to be implemented by a desktop server.
        /// Regular GUI applications should not use this function as they have no
        /// access to a `MessageBoxEvent.RequestID`.
        extern "syscall" fn notify_message_box(
            /// The desktop that completed the message box.
            source: Desktop,
            /// The request id that was passed in `MessageBoxEvent`.
            request_id: MessageBoxEvent.RequestID,
            /// The resulting button which the user clicked.
            result: MessageBoxResult,
        ) void;

        /// Posts an event into the window event queue so the window owner
        /// can handle the event.
        extern "syscall" fn post_window_event(
            window: Window,
            event_type: WindowEvent.Type,
            event: WindowEvent,
        ) error{SystemResources};

        /// Sends a notification to the provided `desktop`.
        extern "syscall" fn send_notification(
            /// Where to show the notification?
            desktop: Desktop,
            /// What text is displayed in the notification?
            message: []const u8,
            /// How urgent is the notification to the user?
            severity: NotificationSeverity,
        ) error{
            SystemResources,
        };

        const clipboard = struct {
            /// Sets the contents of the clip board.
            /// Takes a mime type as well as the value in the provided format.
            extern "syscall" fn set(desktop: Desktop, mime: []const u8, value: []const u8) error{
                SystemResources,
            };

            /// Returns the current type present in the clipboard, if any.
            extern "syscall" fn get_type(desktop: Desktop) ?[*:0]const u8;

            /// Returns the current clipboard value as the provided mime type.
            /// The os provides a conversion *if possible*, otherwise returns an error.
            /// The returned memory for `value` is owned by the process and must be freed with `ashet.process.memory.release`.
            extern "syscall" fn get_value(desktop: Desktop, mime: []const u8, value: *?[]const u8) error{
                ConversionFailed,
                OutOfMemory,
            };
        };
    };

    const shm = struct {
        /// Constructs a new shared memory object with `size` bytes of memory.
        /// Shared memory can be written by all processes without any memory protection.
        extern "syscall" fn create(*SharedMemory, size: usize) error{
            SystemResources,
        };

        /// Returns the number of bytes inside the given shared memory object.
        extern "syscall" fn get_length(SharedMemory) usize;

        /// Returns a pointer to the shared memory.
        extern "syscall" fn get_pointer(SharedMemory) [*]align(16) u8;
    };

    const pipe = struct {
        /// Spawns a new pipe with `fifo_length` elements of `object_size` bytes.
        /// If `fifo_length` is 0, the pipe is synchronous and can only send data
        /// if a `read` call is active. Otherwise, up to `fifo_length` elements can be
        /// stored in a FIFO.
        extern "syscall" fn create(*Pipe, object_size: usize, fifo_length: usize) error{
            SystemResources,
        };

        /// Returns the length of the pipe-internal FIFO in elements.
        extern "syscall" fn get_fifo_length(Pipe) usize;

        /// Returns the size of the objects stored in the pipe.
        extern "syscall" fn get_object_size(Pipe) usize;
    };

    const sync = struct {
        /// Creates a new `SyncEvent` object that can be used to synchronize
        /// different processes.
        extern "syscall" fn create_event(*SyncEvent) error{SystemResources};

        /// Completes one `WaitForEvent` IOP waiting for the given event.
        extern "syscall" fn notify_one(SyncEvent) void;

        /// Completes all `WaitForEvent` IOP waiting for the given event.
        extern "syscall" fn notify_all(SyncEvent) void;

        /// Creates a new mutual exclusion.
        extern "syscall" fn create_mutex(*Mutex) error{SystemResources};

        /// Tries to lock a mutex and returns if it was successful.
        extern "syscall" fn try_lock(Mutex) bool;

        /// Unlocks a mutual exclusion. Completes a single `Lock` IOP if it exists.
        extern "syscall" fn unlock(Mutex) void;
    };
};

/// This namespace contains the supported I/O operations of Ashet OS.
const io = struct {
    /// Sleeps until `clock.monotonic()` returns at least `timeout`.
    extern "iop" fn Timer(
        /// Monotonic timestamp in nanoseconds until the IOP completes.
        timeout: u64,
    ) error{}!void;

    const process = struct {
        /// Spawns a new process
        extern "iop" fn Spawn(
            /// Relative base directory for `path`.
            dir: Directory,
            /// File name of the executable relative to `dir`.
            path: []const u8,
            /// The arguments passed to the process.
            /// If a `SystemResource` is passed, it will receive the created process as a owning process.
            /// It is safe to release the resource in this process as soon as this IOP returns.
            argv: []SpawnProcessArg,
        ) error{
            SystemResources,
            FileNotFound,
        }!struct {
            /// Handle to the spawned process.
            process: Process,
        };
    };

    const input = struct {
        /// Waits for an input event and completes when any input was done.
        extern "iop" fn GetEvent() error{
            NonExclusiveAccess,
            InProgress,
        }!struct {
            /// Defines which element of `event` is active.
            event_type: InputEvent.Type,
            event: InputEvent,
        };
    };

    const pipe = struct {
        /// Writes elements from `data` into the given pipe.
        extern "iop" fn Write(
            pipe: Pipe,
            /// Pointer to the first element. Length defines how many elements are to be transferred.
            data: []const u8,
            /// Distance between each element in `data`. Can be different from the pipes element size
            /// to allow sparse data to be transferred.
            /// If `0`, it will use the `object_size` property of the pipe.
            stride: usize,
            /// Defines how the write should operate.
            mode: PipeMode,
        ) error{}!struct {
            /// Numbert of elements written into the pipe.
            count: usize,
        };

        /// Reads elements from a pipe into `buffer`.
        extern "iop" fn Read(
            pipe: Pipe,
            /// Points to the first element to be received.
            buffer: []u8,
            /// Distance between each element in `buffer`. Can be different from the pipes element size
            /// to allow sparse data to be transferred.
            /// If `0`, it will use the `object_size` property of the pipe.
            stride: usize,
            /// Defines how the read should operate.
            mode: PipeMode,
        ) error{}!struct {
            /// Number of elements read.
            count: usize,
        };
    };

    const network = struct {
        pub const udp = struct {
            extern "iop" fn Bind(socket: UdpSocket, bind_point: EndPoint) error{
                InvalidHandle,
                SystemResources,
                AddressInUse,
                IllegalValue,
            }!struct {
                bind_point: EndPoint,
            };

            extern "iop" fn Connect(
                socket: UdpSocket,
                target: EndPoint,
            ) error{
                InvalidHandle,
                SystemResources,
                AlreadyConnected,
                AlreadyConnecting,
                BufferError,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                OutOfMemory,
                Routing,
                Timeout,
            }!void;

            extern "iop" fn Disconnect(socket: UdpSocket) error{
                InvalidHandle,
                SystemResources,
                NotConnected,
            }!void;

            extern "iop" fn Send(
                socket: UdpSocket,
                data: []const u8,
            ) error{
                InvalidHandle,
                SystemResources,
                BufferError,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                NotConnected,
                OutOfMemory,
                Routing,
                Timeout,
            }!struct {
                bytes_sent: usize,
            };

            extern "iop" fn SendTo(
                socket: UdpSocket,
                receiver: EndPoint,
                data: []const u8,
            ) error{
                InvalidHandle,
                SystemResources,
                BufferError,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                OutOfMemory,
                Routing,
                Timeout,
            }!struct {
                bytes_sent: usize,
            };

            extern "iop" fn ReceiveFrom(
                socket: UdpSocket,
                buffer: []u8,
            ) error{
                InvalidHandle,
                SystemResources,
                BufferError,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                OutOfMemory,
                Routing,
                Timeout,
            }!struct {
                bytes_received: usize,
                sender: EndPoint,
            };
        };

        pub const tcp = struct {
            extern "iop" fn Bind(
                socket: TcpSocket,
                bind_point: EndPoint,
            ) error{
                InvalidHandle,
                SystemResources,
                AddressInUse,
                IllegalValue,
            }!struct {
                bind_point: EndPoint,
            };

            extern "iop" fn Connect(
                socket: TcpSocket,
                target: EndPoint,
            ) error{
                InvalidHandle,
                SystemResources,
                AlreadyConnected,
                AlreadyConnecting,
                BufferError,
                ConnectionAborted,
                ConnectionClosed,
                ConnectionReset,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                OutOfMemory,
                Routing,
                Timeout,
            }!void;

            extern "iop" fn Send(
                socket: TcpSocket,
                data: []const u8,
            ) error{
                InvalidHandle,
                SystemResources,
                BufferError,
                ConnectionAborted,
                ConnectionClosed,
                ConnectionReset,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                NotConnected,
                OutOfMemory,
                Routing,
                Timeout,
            }!struct {
                bytes_sent: usize,
            };

            extern "iop" fn Receive(
                socket: TcpSocket,
                buffer: []u8,
                /// if true, will read until `buffer.len` bytes arrived. otherwise will read until the end of a single packet
                read_all: bool,
            ) error{
                InvalidHandle,
                SystemResources,
                AlreadyConnected,
                AlreadyConnecting,
                BufferError,
                ConnectionAborted,
                ConnectionClosed,
                ConnectionReset,
                IllegalArgument,
                IllegalValue,
                InProgress,
                LowlevelInterfaceError,
                NotConnected,
                OutOfMemory,
                Routing,
                Timeout,
            }!struct {
                bytes_received: usize,
            };
        };
    };

    /// A file or directory on Ashet OS can be named with any legal UTF-8 sequence
    /// that does not contain `/` and `:`. It is recommended to only create file names
    /// that are actually typeable on the operating system tho.
    ///
    /// There are some special file names:
    /// - `.` is the "current directory" selector and does not add to the path.
    /// - `..` is the "parent directory" selector and navigates up in the directory hierarchy if possible.
    /// - Any sequence of upper case ASCII letters and digits (`A-Z`, `0-9`) that ends with `:` is a file system name. This name specifies
    ///   the root directory of a certain file system.
    ///
    /// Paths are either a relative or absolute addyessing of a file system entity.
    /// Paths are composed of a sequence of names, each name separated by `/`.
    /// A file system name is only legal as the first element of a path sequence, making the path an absolute path.
    ///
    /// There is a limit on how long a file/directory name can be, but there's no limit on how long a total
    /// path can be.
    ///
    /// Here are some examples for valid paths:
    /// - `example.txt`
    /// - `docs/wiki.txt`
    /// - `SYS:/apps/editor/code`
    /// - `USB0:/foo/../bar` (which is equivalent to `USB0:/bar`)
    ///
    /// The filesystem that is used to boot the OS from has an alias `SYS:` that is always a legal way to address this file system.
    pub const fs = struct {
        /// Flushes all open files to disk.
        extern "iop" fn Sync() error{DiskError}!void;

        /// Gets information about a file system.
        /// Also returns a `next` id that can be used to iterate over all filesystems.
        /// The `system` filesystem is guaranteed to be the first one.
        extern "iop" fn GetFilesystemInfo(fs: FileSystemId) error{
            DiskError,
            InvalidFileSystem,
        }!struct {
            info: FileSystemInfo,
            next: FileSystemId,
        };

        /// opens a directory on a filesystem
        extern "iop" fn OpenDrive(fs: FileSystemId, path: []const u8) error{
            DiskError,
            InvalidFileSystem,
            FileNotFound,
            NotADir,
            InvalidPath,
            SystemFdQuotaExceeded,
            SystemResources,
        }!struct {
            dir: Directory,
        };

        /// opens a directory relative to the given dir handle.
        extern "iop" fn OpenDir(dir: Directory, path: []const u8) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            NotADir,
            InvalidPath,
            SystemFdQuotaExceeded,
            SystemResources,
        }!struct {
            dir: Directory,
        };

        /// closes the directory handle
        extern "iop" fn CloseDir(dir: Directory) error{InvalidHandle}!struct {};

        /// resets the directory iterator to the starting point
        extern "iop" fn ResetDirEnumeration(dir: Directory) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!void;

        /// returns the info for the current file or "eof", and advances the iterator to the next entry if possible
        extern "iop" fn EnumerateDir(dir: Directory) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!struct {
            eof: bool,
            info: FileInfo,
        };

        /// deletes a file or directory by the given path.
        extern "iop" fn Delete(
            dir: Directory,
            path: []const u8,
            recurse: bool,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
        }!void;

        /// creates a new directory relative to dir. If `path` contains subdirectories, all
        /// directories are created.
        extern "iop" fn MkDir(
            dir: Directory,
            path: []const u8,
            mkopen: bool,
        ) error{
            DiskError,
            InvalidHandle,
            Exists,
            InvalidPath,
        }!struct {
            dir: Directory,
        };

        /// returns the type of the file/dir at path, also adds size and modification dates
        extern "iop" fn StatEntry(
            dir: Directory,
            path_ptr: [*]const u8,
            path_len: usize,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
        }!struct {
            info: FileInfo,
        };

        /// renames a file inside the same file system.
        /// NOTE: This is a cheap operation and does not require the copying of data.
        extern "iop" fn NearMove(
            src_dir: Directory,
            src_path: []const u8,
            dst_path: []const u8,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
            Exists,
        }!void;

        // GROUP: modification

        /// moves a file or directory between two unrelated directories. Can also move between different file systems.
        /// NOTE: This syscall might copy the data.
        extern "iop" fn FarMove(
            src_dir: Directory,
            src_path: []const u8,
            dst_dir: Directory,
            dst_path: []const u8,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
            Exists,
            NoSpaceLeft,
        }!void;

        /// copies a file or directory between two unrelated directories. Can also move between different file systems.
        extern "iop" fn Copy(
            src_dir: Directory,
            src_path: []const u8,
            dst_dir: Directory,
            dst_path: []const u8,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
            Exists,
            NoSpaceLeft,
        }!void;

        // // GROUP: file handling

        /// opens a file from the given directory.
        extern "iop" fn OpenFile(
            dir: Directory,
            path: []const u8,
            access: FileAccess,
            mode: FileMode,
        ) error{
            DiskError,
            InvalidHandle,
            FileNotFound,
            InvalidPath,
            Exists,
            NoSpaceLeft,
            SystemFdQuotaExceeded,
            SystemResources,
            WriteProtected,
            FileAlreadyExists,
        }!struct {
            handle: File,
        };

        /// closes the handle and flushes the file.
        extern "iop" fn CloseFile(file: File) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!void;

        /// makes sure this file is safely stored to mass storage device
        extern "iop" fn FlushFile(file: File) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!void;

        /// directly reads data from a given offset into the file. no streaming API to the kernel
        extern "iop" fn Read(
            file: File,
            offset: u64,
            buffer: []u8,
        ) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!struct {
            count: usize,
        };

        /// directly writes data to a given offset into the file. no streaming API to the kernel
        extern "iop" fn Write(
            file: File,
            offset: u64,
            buffer: []const u8,
        ) error{
            DiskError,
            InvalidHandle,
            NoSpaceLeft,
            SystemResources,
            WriteProtected,
        }!struct {
            count: usize,
        };

        /// allows us to get the current size of the file, modification dates, and so on
        extern "iop" fn StatFile(file: File) error{
            DiskError,
            InvalidHandle,
            SystemResources,
        }!struct {
            info: FileInfo,
        };

        /// Resizes the file to the given length in bytes. Can be also used to truncate a file to zero length.
        extern "iop" fn Resize(file: File, length: u64) error{
            DiskError,
            InvalidHandle,
            NoSpaceLeft,
            SystemResources,
        }!void;
    };

    const gui = struct {
        /// Waits for an event on the given `Window`, completing as soon as
        /// an event arrived.
        extern "iop" fn GetWindowEvent(window: Window) error{InProgress}!struct {
            event_type: WindowEvent.Type,
            event: WindowEvent,
        };

        /// Opens a message box popup window and prompts the user for response.
        extern "iop" fn ShowMessageBox(
            Desktop,
            message: []const u8,
            caption: []const u8,
            buttons: MessageBoxButtons,
            icon: MessageBoxIcon,
        ) error{}!struct {
            result: MessageBoxResult,
        };
    };

    const sync = struct {
        /// Waits for the given `SyncEvent` to be notified.
        extern "iop" fn WaitForEvent(SyncEvent) error{}!void;

        /// Locks a mutex. Will complete once the mutex is locked.
        extern "iop" fn Lock(Mutex) error{}!void;
    };
};

pub const Service = struct(SystemResource) {};

pub const SharedMemory = struct(SystemResource) {};

pub const Pipe = struct(SystemResource) {};

pub const Process = struct(SystemResource) {};

pub const Thread = struct(SystemResource) {};

pub const TcpSocket = struct(SystemResource) {};

pub const UdpSocket = struct(SystemResource) {};

pub const File = struct(SystemResource) {};

pub const Directory = struct(SystemResource) {};

pub const VideoOutput = struct(SystemResource) {};

pub const Font = struct(SystemResource) {};

/// A framebuffer is something that can be drawn on.
pub const Framebuffer = struct(SystemResource) {};

pub const Window = struct(SystemResource) {};

pub const Widget = struct(SystemResource) {};

pub const Desktop = struct(SystemResource) {};

pub const WidgetType = struct(SystemResource) {};

pub const SyncEvent = struct(SystemResource) {};

pub const Mutex = struct(SystemResource) {};

usingnamespace zig; // regular code beyond this

/// Constructor for generic asynchronous I/O oerations
pub const IOP = iops.Generic_IOP(IOP_Type);

/// Constructor for a generic, ABI passable error set.
pub const ErrorSet = @import("error_set.zig").UntypedErrorSet(Error);

///////////////////////////////////////////////////////////
// Imports:

const std = @import("std");
const iops = @import("iops.zig");
const abi = @This();

///////////////////////////////////////////////////////////
// Constants:

/// The maximum number of bytes in a file system identifier name.
/// This is chosen to be a power of two, and long enough to accommodate
/// typical file system names:
/// - `SYS`
/// - `USB0`
/// - `USB10`
/// - `PF0`
/// - `CF7`
pub const max_fs_name_len = 8;

/// The maximum number of bytes in a file system type name.
/// Chosen to be a power of two, and long enough to accomodate typical names:
/// - `FAT16`
/// - `FAT32`
/// - `exFAT`
/// - `NTFS`
/// - `ReiserFS`
/// - `ISO 9660`
/// - `btrfs`
/// - `AFFS`
pub const max_fs_type_len = 32;

/// The maximum number of bytes in a file name.
/// This is chosen to be a power of two, and reasonably long.
/// As some programs use sha256 checksums and 64 bytes are enough to store
/// a hex-encoded 256 bit sequence:
/// - `114ac2caf8fefad1116dbfb1bd68429f68e9e088b577c9b3f5a3ff0fe77ec886`
/// This should also enough for most reasonable file names in the wild.
pub const max_file_name_len = 120;

pub const palette_size = std.math.maxInt(@typeInfo(ColorIndex).Enum.tag_type) + 1;

///////////////////////////////////////////////////////////
// System resources:

/// Handle to an abstract system resource.
pub const SystemResource = opaque {
    /// Casts the resource into a concrete type. Fails, if the type does not match.
    pub fn cast(resource: *SystemResource, comptime t: Type) error{InvalidType}!*CastResult(t) {
        const actual = resource.get_type();
        if (actual != t)
            return error.InvalidType;
        return @ptrCast(resource);
    }

    fn CastResult(comptime t: Type) type {
        return __SystemResourceCastResult(t);
    }

    pub const Type = __SystemResourceType;
};

///////////////////////////////////////////////////////////
// Simple types:

pub const UUID = struct {
    bytes: [16]u8,

    /// Parses a UUID in the format
    /// `3ad20402-1711-4bbc-b6c3-ff8a1da068c6`
    /// and returns a pointer to it.
    ///
    /// You can generate UUIDs at
    /// https://www.uuidgenerator.net/version4
    pub fn constant(str: *const [36:0]u8) *const UUID {
        _ = str;
        unreachable;
    }
};

pub const MAC = [6]u8;

pub const AbstractFunction = fn () callconv(.C) void;

pub const ThreadFunction = *const fn (?*anyopaque) callconv(.C) u32;

/// A date-and-time type encoding the time point in question as a
/// Unix timestamp in milliseconds
pub const DateTime = enum(i64) {
    _,
};

/// Index into a color palette.
pub const ColorIndex = enum(u8) {
    _,

    pub fn get(val: u8) ColorIndex {
        return @as(ColorIndex, @enumFromInt(val));
    }

    pub fn index(c: ColorIndex) @typeInfo(ColorIndex).Enum.tag_type {
        return @intFromEnum(c);
    }

    pub fn shift(c: ColorIndex, offset: u8) ColorIndex {
        return get(index(c) +% offset);
    }
};

///////////////////////////////////////////////////////////
// Enumerations:

pub const PipeMode = enum(u8) {
    /// Completes immediatly even if no elements could be processed.
    nonblocking = 0,
    /// Returns when at least one element could be processed.
    at_least_one = 1,
    /// Returns only when all elements are processed.
    all = 2,
};

pub const NotificationSeverity = enum(u8) {
    /// Important information that require immediate action
    /// by the user.
    ///
    /// This should be handled with care and only for reall
    /// urgent situations like low battery power or
    /// unsufficient disk memory.
    attention = 0,

    /// This is a regular user notification, which should be used
    /// sparingly.
    ///
    /// Typical notifications of this kind are in the category of
    /// "download completed", "video fully rendered" or similar.
    information = 128,

    /// Silent notifications that might be informational, but do not
    /// require attention by the user at all.
    whisper = 255,
};

pub const IP_Type = enum(u8) { ipv4, ipv6 };

pub const WaitIO = enum(u32) {
    /// Don't wait for any I/O to complete.
    dont_block,

    /// Doesn't block the call, and guarantees that no event is returned by `scheduleAndAwait`.
    /// This can be used to enqueue new IOPs outside of the event loop.
    schedule_only,

    /// Wait for at least one I/O to complete operation.
    wait_one,

    /// Wait until all scheduled I/O operations have completed.
    wait_all,

    /// Returns whether the operation is blocking or not.
    pub fn isBlocking(wait: WaitIO) bool {
        return switch (wait) {
            .dont_block => false,
            .schedule_only => false,
            .wait_one => true,
            .wait_all => true,
        };
    }
};

/// Index of the systems video outputs.
pub const VideoOutputID = enum(u8) {
    /// The primary video output
    primary = 0,
    _,
};

pub const FontType = enum(u32) {
    bitmap = 0,
    vector = 1,
    _,
};

pub const FramebufferType = enum(u8) {
    /// A pure in-memory frame buffer used for off-screen rendering.
    memory = 0,

    /// A video device backed frame buffer. Can be used to paint on a screen
    /// directly.
    video = 1,

    /// A frame buffer provided by a window. These frame buffers
    /// may hold additional semantic information.
    window = 2,

    /// A frame buffer provided by a user interface element. These frame buffers
    /// may hold additional semantic information.
    widget = 3,
};

pub const MessageBoxIcon = enum(u8) {
    information = 0,
    question = 1,
    warning = 2,
    @"error" = 3,
};

pub const MessageBoxResult = enum(u8) {
    ok = @bitOffsetOf(MessageBoxButtons, "ok"),
    cancel = @bitOffsetOf(MessageBoxButtons, "cancel"),
    yes = @bitOffsetOf(MessageBoxButtons, "yes"),
    no = @bitOffsetOf(MessageBoxButtons, "no"),
    abort = @bitOffsetOf(MessageBoxButtons, "abort"),
    retry = @bitOffsetOf(MessageBoxButtons, "retry"),
    @"continue" = @bitOffsetOf(MessageBoxButtons, "continue"),
    ignore = @bitOffsetOf(MessageBoxButtons, "ignore"),
};

pub const ExitCode = enum(u32) {
    success = @as(u32, 0),
    failure = @as(u32, 1),

    killed = ~@as(u32, 0),

    _,
};

pub const LogLevel = enum(u8) {
    critical = 0,
    err = 1,
    warn = 2,
    notice = 3,
    debug = 4,
    _,
};

pub const FileSystemId = enum(u32) {
    /// This is the file system which the os has bootet from.
    system = 0,

    /// the filesystem isn't valid.
    invalid = ~@as(u32, 0),

    /// All other ids are unique file systems.
    _,
};

pub const FileAttributes = packed struct(u16) {
    directory: bool,
    reserved: u15 = 0,
};

pub const FileAccess = enum(u8) {
    read_only = 0,
    write_only = 1,
    read_write = 2,
};

pub const FileMode = enum(u8) {
    open_existing = 0, // opens file when it exists on disk
    open_always = 1, // creates file when it does not exist, or opens the file without truncation.
    create_new = 2, // creates file when there is no file with that name
    create_always = 3, // creates file when it does not exist, or opens the file and truncates it to zero length
};

pub const KeyCode = enum(u16) {
    escape = 1,
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    @"0",
    minus,
    equal,
    backspace,
    tab,
    q,
    w,
    e,
    r,
    t,
    y,
    u,
    i,
    o,
    p,
    left_brace,
    right_brace,
    @"return",
    ctrl_left,
    a,
    s,
    d,
    f,
    g,
    h,
    j,
    k,
    l,
    semicolon,
    apostrophe,
    grave,
    shift_left,
    backslash,
    z,
    x,
    c,
    v,
    b,
    n,
    m,
    comma,
    dot,
    slash,
    shift_right,
    kp_asterisk,
    alt,
    space,
    caps_lock,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    num_lock,
    scroll_lock,
    kp_7,
    kp_8,
    kp_9,
    kp_minus,
    kp_4,
    kp_5,
    kp_6,
    kp_plus,
    kp_1,
    kp_2,
    kp_3,
    kp_0,
    kp_dot,
    jp_zenkakuhankaku,
    @"102nd",
    f11,
    f12,
    jp_ro,
    jp_katakana,
    jp_hiragana,
    jp_henkan,
    jp_katakana_hiragana,
    jp_muhenkan,
    jp_kp_comma,
    kp_enter,
    ctrl_right,
    kp_slash,
    print,
    alt_graph,
    linefeed,
    home,
    up,
    page_up,
    left,
    right,
    end,
    down,
    page_down,
    insert,
    delete,
    meta,

    unknown = 0xFFFF,
};

pub const MouseButton = enum(u8) {
    none = 0,
    left = 1,
    right = 2,
    middle = 3,
    nav_previous = 4,
    nav_next = 5,
    wheel_down = 6,
    wheel_up = 7,
};

///////////////////////////////////////////////////////////
// Compound types:

pub const SpawnProcessArg = struct {
    pub const Type = enum(u8) {
        string = 0,
        resource = 1,
    };

    pub const String = struct {
        ptr: [*]const u8,
        len: usize,
    };

    type: Type,
    value: extern union {
        text: String,
        resource: *SystemResource,
    },
};

pub const CreateWindowFlags = packed struct(u32) {
    popup: bool = false,
    padding: u31 = 0,
};

pub const WidgetDescriptor = extern struct {
    uuid: UUID,

    /// Number of bytes allocated in a Widget for this widget type.
    /// See `get_widget_data` function for further information.
    data_size: usize,

    flags: Flags,

    // TODO: Fill this out

    // Event Handlers:

    handle_event: *const fn (Widget, *const WidgetEvent) callconv(.C) void,

    pub const Flags = packed struct(u32) {
        /// If `true`, the user can focus this widget with the mouse or keyboard.
        focusable: bool,

        /// If `true`, the user is able to open a context menu on this.
        context_menu: bool,

        /// If `true`, this widget is able to receive events with the mouse.
        /// If `false`, the widget is ignored in the position-to-widget resolution.
        hit_test_visible: bool,

        /// If `true`, the user is able to potentially drop data via Drag&Drop
        /// on this widget.
        allow_drop: bool,

        /// If `true`, the user can copy/cut/paste data from/into this widget.
        clipboard_sensitive: bool,

        _padding: u28 = 0,
    };
};

pub const WidgetControlMessage = extern struct {
    /// The widget-specific type of the control message.
    /// Could be something like `get_property`, `set_property`, `set_text`, ...
    type: u32,

    /// Generic parameters that can be passed to the widget.
    params: [4]usize,
};

pub const WidgetNotifyEvent = extern struct {
    widget: Widget,

    /// The widget-specific type of event.
    /// Could be something like `text_changed`, `clicked`, `checked_changed`, ...
    type: u32,

    /// Generic data associated with the event.
    data: [4]usize,
};

pub const WidgetEvent = extern union {
    mouse: MouseEvent,
    keyboard: KeyboardEvent,
    control: WidgetControlMessage,

    // TODO: Add event data

    pub const Type = enum(u16) {
        // lifecycle:

        /// The widget was created and attached to a window.
        create,

        /// The widget is in the process of being destroyed.
        /// After this event, the handle will be invalid.
        destroy,

        /// The creator of the widget wants to do something widget-specific.
        control,

        // basic input:

        /// The user clicked on the widget with the primary mouse button
        /// or pressed the return or space bar button on the keyboard.
        click,

        // keyboard input:

        /// A key was pressed on the keyboard.
        key_press,

        /// A key was released on the keyboard.
        key_release,

        // mouse specific extras:

        /// The mouse was moved inside the rectangle of the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_enter,

        /// The mouse was moved outside the rectangle of the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_leave,

        /// The mouse stopped for some time over the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_hover,

        /// A mouse button was pressed over the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_button_press,

        /// A mouse button was released over the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_button_release,

        /// The mouse was moved over the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        mouse_motion,

        /// A vertical or horizontal scroll wheel was scrolled over the widget.
        ///
        /// NOTE: This event can only happen when `hit_test_visible` was set
        /// in the widget creation flags.
        scroll,

        // drag&drop operations:

        /// The user dragged a payload into the rectangle of this widget.
        ///
        /// NOTE: This event can only happen when `allow_drop` was set in the
        /// widget creation flags.
        drag_enter,

        /// The user dragged a payload out of the rectangle of this widget.
        ///
        /// NOTE: This event can only happen when `allow_drop` was set in the
        /// widget type creation flags.
        drag_leave,

        /// The user dragged a payload over the rectangle of this widget.
        ///
        /// NOTE: This event can only happen when `allow_drop` was set in the
        /// widget type creation flags.
        drag_over,

        /// The user dropped a payload into this widget.
        ///
        /// NOTE: This event can only happen when `allow_drop` was set in the
        /// widget type creation flags.
        drag_drop,

        // clipboard operations:

        /// The user requested a clipboard copy operation, usually by pressing 'Ctrl-C'.
        ///
        /// NOTE: This event can only happen when `clipboard_sensitive` was set in
        /// the widget type creation flags.
        clipboard_copy,

        /// The user requested a clipboard paste operation, usually by pressing 'Ctrl-V'.
        ///
        /// NOTE: This event can only happen when `clipboard_sensitive` was set in
        /// the widget type creation flags.
        clipboard_paste,

        /// The user requested a clipboard cut operation, usually by pressing 'Ctrl-X'.
        ///
        /// NOTE: This event can only happen when `clipboard_sensitive` was set in
        /// the widget type creation flags.
        clipboard_cut,

        // widget specific:

        /// The widget was resized with a call to `place_widget`.
        ///
        /// NOTE: This event will not fire if the widget was only moved.
        resized,

        /// The widget should draw itself.
        paint,

        /// User pressed the "context menu" button or did a
        /// secondary mouse button click on the  widget.
        context_menu_request,

        /// The widget received focus via mouse or keyboard.
        focus_enter,

        /// The widget lost focus after receiving it.
        focus_leave,

        _,
    };
};

pub const WindowEvent = extern union {
    mouse: MouseEvent,
    keyboard: KeyboardEvent,
    widget_notify: WidgetNotifyEvent,

    pub const Type = enum(u16) {
        widget_notify,

        key_press,
        key_release,

        mouse_enter,
        mouse_leave,
        mouse_motion,
        mouse_button_press,
        mouse_button_release,

        /// The user requested the window to be closed.
        window_close,

        /// The window was minimized and is not visible anymore.
        window_minimize,

        /// The window was restored from minimized state.
        window_restore,

        /// The window is currently moving on the screen. Query `window.bounds` to get the new position.
        window_moving,

        /// The window was moved on the screen. Query `window.bounds` to get the new position.
        window_moved,

        /// The window size is currently changing. Query `window.bounds` to get the new size.
        window_resizing,

        /// The window size changed. Query `window.bounds` to get the new size.
        window_resized,
    };
};

pub const MessageBoxButtons = packed struct(u8) {
    pub const ok: MessageBoxButtons = .{ .ok = true };
    pub const ok_cancel: MessageBoxButtons = .{ .ok = true, .cancel = true };
    pub const yes_no: MessageBoxButtons = .{ .yes = true, .no = true };
    pub const yes_no_cancel: MessageBoxButtons = .{ .yes = true, .no = true, .cancel = true };
    pub const retry_cancel: MessageBoxButtons = .{ .retry = true, .cancel = true };
    pub const abort_retry_ignore: MessageBoxButtons = .{ .abort = true, .retry = true, .ignore = true };

    ok: bool = false,
    cancel: bool = false,
    yes: bool = false,
    no: bool = false,
    abort: bool = false,
    retry: bool = false,
    @"continue": bool = false,
    ignore: bool = false,
};

pub const DesktopDescriptor = extern struct {
    /// Number of bytes allocated in a Window for this desktop.
    /// See `get_desktop_data` function for further information.
    window_data_size: usize,

    /// A function pointer to the event handler of a desktop.
    /// The desktop will receive events via this function.
    handle_event: *const fn (Desktop, *const DesktopEvent) callconv(.C) void,
};

pub const DesktopEvent = extern union {
    create_window: Window,
    destroy_window: Window,

    show_notification: DesktopNotificationEvent,
    show_message_box: MessageBoxEvent,

    pub const Type = enum(u16) {
        // lifecycle management:

        /// A window was created on this desktop.
        create_window,

        /// A window was destroyed on this desktop.
        destroy_window,

        // user interaction:

        /// `send_notification` was called and the desktop user should display
        /// a notification.
        show_notification,

        /// `send_notification` was called and the desktop user should display
        /// a notification.
        show_message_box,

        _,
    };
};

pub const DesktopNotificationEvent = extern struct {
    /// The text of the notification.
    message_ptr: [*]const u8,

    /// Length of `message_ptr`.
    message_len: usize,

    /// The severity/importance of the notification.
    severity: NotificationSeverity,
};

pub const MessageBoxEvent = extern struct {
    /// The desktop-specific request id that must be passed into
    /// `notify_message_box` to finish the message box request.
    request_id: RequestID,

    /// Pointer to the content of the message box.
    message_ptr: [*]const u8,

    /// length of `message_ptr`.
    message_len: usize,

    /// Pointer to the caption of the message box.
    caption_ptr: [*]const u8,

    /// length of `caption_ptr`.
    caption_len: usize,

    /// Which buttons are presented to the user?
    buttons: MessageBoxButtons,

    /// Which icon is shown?
    icon: MessageBoxIcon,

    pub const RequestID = enum(u16) { _ };
};

/// A 16 bpp color value using RGB565 encoding.
pub const Color = packed struct(u16) {
    r: u5,
    g: u6,
    b: u5,

    pub fn toU16(c: Color) u16 {
        return @as(u16, @bitCast(c));
    }

    pub fn fromU16(u: u16) Color {
        return @as(Color, @bitCast(u));
    }

    pub fn fromRgb888(r: u8, g: u8, b: u8) Color {
        return Color{
            .r = @as(u5, @truncate(r >> 3)),
            .g = @as(u6, @truncate(g >> 2)),
            .b = @as(u5, @truncate(b >> 3)),
        };
    }

    pub fn toRgb32(color: Color) u32 {
        const exp = color.toRgb888();
        return @as(u32, exp.r) << 0 |
            @as(u32, exp.g) << 8 |
            @as(u32, exp.b) << 16;
    }

    pub fn toRgb888(color: Color) RGB888 {
        const src_r: u8 = color.r;
        const src_g: u8 = color.g;
        const src_b: u8 = color.b;

        // expand bits to form a linear range between 0…255
        return .{
            .r = (src_r << 3) | (src_r >> 2),
            .g = (src_g << 2) | (src_g >> 4),
            .b = (src_b << 3) | (src_b >> 2),
        };
    }

    pub const RGB888 = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };
};

pub const InputEvent = extern union {
    mouse: MouseEvent,
    keyboard: KeyboardEvent,

    pub const Type = enum(u8) {
        key_press = 0,
        key_release = 1,

        mouse_motion = 2,
        mouse_button_press = 3,
        mouse_button_release = 4,
    };
};

pub const MouseEvent = extern struct {
    x: i16,
    y: i16,
    dx: i16,
    dy: i16,
    button: MouseButton,
};

pub const KeyboardEvent = extern struct {
    /// The raw scancode for the key. Meaning depends on the layout,
    /// represents kinda the physical position on the keyboard.
    scancode: u32,

    /// The virtual key, independent of layout. Represents the logical
    /// function of the key.
    key: KeyCode,

    /// If set, the pressed key combination has a mapping that produces
    /// text input. UTF-8 encoded.
    text: ?[*:0]const u8,

    /// The key in this event was pressed or released
    pressed: bool,

    /// The modifier keys currently active
    modifiers: KeyboardModifiers,
};

pub const KeyboardModifiers = packed struct(u16) {
    shift: bool,
    alt: bool,
    ctrl: bool,
    shift_left: bool,
    shift_right: bool,
    ctrl_left: bool,
    ctrl_right: bool,
    alt_graph: bool,
    padding: u8 = 0,
};

pub const Point = extern struct {
    pub const zero = new(0, 0);

    x: i16,
    y: i16,

    pub fn new(x: i16, y: i16) Point {
        return Point{ .x = x, .y = y };
    }

    pub fn eql(a: Point, b: Point) bool {
        return (a.x == b.x) and (a.y == b.y);
    }

    pub fn manhattenDistance(a: Point, b: Point) u16 {
        return std.math.absCast(a.x - b.x) + std.math.absCast(a.y - b.y);
    }

    pub fn format(point: Point, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Point({},{})", .{
            point.x, point.y,
        });
    }
};

pub const Size = extern struct {
    pub const empty = new(0, 0);
    pub const max = new(std.math.maxInt(u16), std.math.maxInt(u16));

    width: u16,
    height: u16,

    pub fn new(w: u16, h: u16) Size {
        return Size{ .width = w, .height = h };
    }

    pub fn eql(a: Size, b: Size) bool {
        return (a.width == b.width) and (a.height == b.height);
    }

    pub fn format(size: Size, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Size({}x{})", .{
            size.width,
            size.height,
        });
    }
};

pub const Rectangle = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,

    pub fn new(pos: Point, siz: Size) Rectangle {
        return Rectangle{
            .x = pos.x,
            .y = pos.y,
            .width = siz.width,
            .height = siz.height,
        };
    }

    pub fn position(rect: Rectangle) Point {
        return Point{ .x = rect.x, .y = rect.y };
    }

    pub fn size(rect: Rectangle) Size {
        return Size{ .width = rect.width, .height = rect.height };
    }

    pub fn empty(rect: Rectangle) bool {
        return (rect.width == 0) and (rect.height == 0);
    }

    pub fn contains(rect: Rectangle, pt: Point) bool {
        return (pt.x >= rect.x) and
            (pt.x < rect.x + @as(u15, @intCast(rect.width))) and
            (pt.y >= rect.y) and
            (pt.y < rect.y + @as(u15, @intCast(rect.height)));
    }

    pub fn containsRectangle(boundary: Rectangle, region: Rectangle) bool {
        return boundary.contains(region.position()) and
            boundary.contains(Point.new(region.x + @as(u15, @intCast(region.width)) - 1, region.y + @as(u15, @intCast(region.height)) - 1));
    }

    pub fn intersects(a: Rectangle, b: Rectangle) bool {
        return a.x + @as(u15, @intCast(a.width)) >= b.x and
            a.y + @as(u15, @intCast(a.height)) >= b.y and
            a.x <= b.x + @as(u15, @intCast(b.width)) and
            a.y <= b.y + @as(u15, @intCast(b.height));
    }

    pub fn eql(a: Rectangle, b: Rectangle) bool {
        return a.size().eql(b.size()) and a.position().eql(b.position());
    }

    pub fn top(rect: Rectangle) i16 {
        return rect.y;
    }
    pub fn bottom(rect: Rectangle) i16 {
        return rect.y + @as(u15, @intCast(rect.height));
    }
    pub fn left(rect: Rectangle) i16 {
        return rect.x;
    }
    pub fn right(rect: Rectangle) i16 {
        return rect.x +| @as(u15, @intCast(rect.width));
    }

    pub fn shrink(rect: Rectangle, amount: u15) Rectangle {
        var copy = rect;
        copy.x +|= amount;
        copy.y +|= amount;
        copy.width -|= 2 * amount;
        copy.height -|= 2 * amount;
        return copy;
    }

    pub fn grow(rect: Rectangle, amount: u15) Rectangle {
        var copy = rect;
        copy.x -|= amount;
        copy.y -|= amount;
        copy.width +|= 2 * amount;
        copy.height +|= 2 * amount;
        return copy;
    }

    pub fn format(rect: Rectangle, fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("Rectangle({},{},{}x{})", .{
            rect.x,
            rect.y,
            rect.width,
            rect.height,
        });
    }
};

pub const FileSystemInfo = extern struct {
    id: FileSystemId, // system-unique id of this file system
    flags: Flags, // binary infos about the file system
    name: [max_fs_name_len]u8, // user addressable file system identifier ("USB0", ...)
    filesystem: [max_fs_type_len]u8, // string identifier of a file system driver ("FAT32", ...)

    pub const Flags = packed struct(u16) {
        system: bool, // is the system boot disk
        removable: bool, // the file system can be removed by the user
        read_only: bool, // the file system is mounted as read-only
        reserved: u13 = 0,
    };

    pub fn getName(fi: *const FileInfo) []const u8 {
        return std.mem.sliceTo(&fi.name, 0);
    }

    pub fn getFileSystem(fi: *const FileInfo) []const u8 {
        return std.mem.sliceTo(&fi.filesystem, 0);
    }
};

pub const FileInfo = extern struct {
    name: [max_file_name_len]u8,
    size: u64,
    attributes: FileAttributes,
    creation_date: DateTime,
    modified_date: DateTime,

    pub fn getName(fi: *const FileInfo) []const u8 {
        return std.mem.sliceTo(&fi.name, 0);
    }
};

pub const IP = extern struct {
    type: IP_Type,
    addr: extern union {
        v4: IPv4,
        v6: IPv6,
    },

    pub fn ipv4(addr: [4]u8) IP {
        return IP{ .type = .ipv4, .addr = .{ .v4 = .{ .addr = addr } } };
    }

    pub fn ipv6(addr: [16]u8, zone: u8) IP {
        return IP{ .type = .ipv6, .addr = .{ .v6 = .{ .addr = addr, .zone = zone } } };
    }

    pub fn format(ip: IP, comptime fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        switch (ip.type) {
            .ipv4 => try ip.addr.v4.format(fmt, opt, writer),
            .ipv6 => try ip.addr.v6.format(fmt, opt, writer),
        }
    }
};

pub const IPv4 = extern struct {
    addr: [4]u8 align(4),

    pub fn format(ip: IPv4, comptime fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        try writer.print("{}.{}.{}.{}", .{
            ip.addr[0],
            ip.addr[1],
            ip.addr[2],
            ip.addr[3],
        });
    }
};

pub const IPv6 = extern struct {
    addr: [16]u8 align(4),
    zone: u8,

    pub fn format(ip: IPv6, comptime fmt: []const u8, opt: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = opt;
        try writer.print("[{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}:{X:0>2}{X:0>2}/{}]", .{
            ip.addr[0],
            ip.addr[1],
            ip.addr[2],
            ip.addr[3],
            ip.addr[4],
            ip.addr[5],
            ip.addr[6],
            ip.addr[7],
            ip.addr[8],
            ip.addr[9],
            ip.addr[10],
            ip.addr[11],
            ip.addr[12],
            ip.addr[13],
            ip.addr[14],
            ip.addr[15],
            ip.zone,
        });
    }
};

pub const EndPoint = extern struct {
    ip: IP,
    port: u16,

    pub fn new(ip: IP, port: u16) EndPoint {
        return EndPoint{ .ip = ip, .port = port };
    }
};

///////////////////////////////////////////////////////////
// Callback types:

///////////////////////////////////////////////////////////
// Legacy:

// pub const NetworkStatus = enum(u8) {
//     disconnected = 0, // no cable is plugged in
//     mac_available = 1, // cable is plugged in and connected, no DHCP or static IP performed yet
//     ip_available = 2, // interface got at least one IP assigned
//     gateway_available = 3, // the gateway, if any, is reachable
// };

// pub const Ping = extern struct {
//     destination: IP, // who to ping
//     ttl: u16, // hops
//     timeout: u16, // ms, a minute timeout for ping is enough. if you have a higher ping, you have other problems
//     response: u16 = undefined, // response time in ms
// };
