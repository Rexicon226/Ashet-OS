const std = @import("std");
const ashet = @import("../main.zig");
const log = std.log.scoped(.random);

const Blake2s256 = std.crypto.hash.blake2.Blake2s256;
const ChaCha = std.Random.ChaCha;

var pool: Pool = undefined;
var crng: Crng = undefined;

const Pool = struct {
    hash: Blake2s256,
    init_bits: usize,
};

const Crng = struct {
    key: [32]u8,
    generation: usize,
    phase: Phase,

    fn reseed(c: *Crng) void {
        var key: [32]u8 = undefined;
        extract_entropy((&key).ptr, 32);
        @memcpy(&c.key, &key);
        c.generation +%= 1;
    }

    fn draw(c: *Crng, dst: []u8) void {
        var state = ChaCha.init(c.key);
        state.fill(dst);
    }
};

const Phase = enum {
    empty,
    early,
    ready,
};

const Block = extern struct {
    seed: [32]u64,
    counter: u16,
};

const TimerState = struct {
    entropy: u64,
    samples_per_bit: u32,
};

pub fn initialize() void {
    const clock = get_hw_entropy();
    const hash = std.crypto.hash.blake2.Blake2s256.init(
        .{ .key = std.mem.asBytes(&clock) },
    );
    pool = .{ .hash = hash, .init_bits = 0 };
}

/// This function is not crypto-graphically safe unless `wait_for_entropy` was
/// called before-hand.
pub fn get_random_bytes(buf: [*]u8, len: usize) void {
    if (len == 0) return;
    // a reseed incase the caller didn't use wait_for_entropy before-hand
    crng.reseed();
    crng.draw(buf[0..len]);
}

/// This function blocks until there is enough credited entropy in the pool to extract
/// a full ChaCha key.
pub fn wait_for_entropy() void {
    while (crng.phase != .ready) {
        generate_timing_entropy();
        log.debug("generating entropy, crng phase: {s}", .{@tagName(crng.phase)});
    }
}

pub fn crng_ready() bool {
    return crng.phase == .ready;
}

const HZ = 1000;
const NUM_TRIAL_SAMPLES = 8192;
const MAX_SAMPLES_PER_BIT = HZ / 15;
const POOL_BITS = Blake2s256.digest_length * 8;

fn generate_timing_entropy() void {
    var state: TimerState align(128) = undefined;

    var last = get_hw_entropy();
    var num_different: u32 = 0;
    for (0..NUM_TRIAL_SAMPLES) |_| {
        state.entropy = get_hw_entropy();
        if (state.entropy != last) num_different += 1;
        last = state.entropy;
    }
    state.samples_per_bit = @divFloor(NUM_TRIAL_SAMPLES, num_different + 1);
    if (state.samples_per_bit > MAX_SAMPLES_PER_BIT) return;

    // do some operations where it's unlikely the CPU can predict what's going to happen
    var dummy: u32 = 0;
    while (dummy < @max(10, get_hw_entropy() % 100)) {
        pool.hash.update(std.mem.asBytes(&state.entropy));
        credit_bits(1); // we've created one entropy bit
        dummy += 1;
        state.entropy = get_hw_entropy();
    }
    pool.hash.update(std.mem.asBytes(&state.entropy));
}

/// Increases the amount of entropy bits we think we have in the pool
/// and potentially update the phase of the pool.
fn credit_bits(bits: usize) void {
    if (crng.phase == .ready) return;

    // there cannot be more entropy bits in the pool than bits in the hash of the pool
    const amount = @min(bits, POOL_BITS);
    const old = pool.init_bits;
    const new = @min(old + amount, POOL_BITS);
    pool.init_bits = new;

    if (old < POOL_BITS and new >= POOL_BITS) {
        crng.reseed();
        crng.phase = .ready;
    } else if (old < POOL_BITS / 2 and new >= POOL_BITS / 2) {
        if (crng.phase == .empty) {
            extract_entropy((&crng.key).ptr, 32);
            crng.phase = .early;
        }
    }
}

/// Removes entropy from the pool via writing random bytes to
/// `ptr`. The amount of entropy it will remove might be
/// overfitted to the provided `len`.
///
/// This function assumes that the entropy pool has enough
/// randomness.
fn extract_entropy(ptr: [*]u8, len: usize) void {
    var seed: [Blake2s256.digest_length]u8 = undefined;
    var next: [Blake2s256.digest_length]u8 = undefined;
    var block: Block = undefined;

    {
        var i: u32 = 0;
        while (i < 32) : (i += 1) {
            if (ashet.platform.get_rdseed()) |long| {
                block.seed[i] = long;
                i += 1;
            }
            block.seed[i] = get_hw_entropy();
        }
    }

    pool.hash.final(&seed);

    block.counter = 0;
    Blake2s256.hash(std.mem.asBytes(&block), &next, .{ .key = &seed });
    pool.hash = Blake2s256.init(.{ .key = &next });

    var l = len;
    var buf = ptr;
    while (l > 0) {
        const i = @min(len, Blake2s256.digest_length);
        block.counter += 1;
        var temp: [Blake2s256.digest_length]u8 = undefined;
        Blake2s256.hash(std.mem.asBytes(&block), &temp, .{ .key = &seed });
        @memcpy(ptr, temp[0..i]);
        l -= i;
        buf = buf[i..];
    }
}

fn get_hw_entropy() u64 {
    return ashet.platform.get_clock();
}
